/// Advanced interpreter instruction stream implementation.
///
/// This module implements the EVMOne-style instruction stream architecture where
/// bytecode is transformed into a linear array of instructions with embedded metadata.
/// Each instruction contains a function pointer and optional arguments, enabling
/// direct dispatch without switch statements.
///
/// ## Design
///
/// The instruction stream approach provides several benefits:
/// - Function pointer dispatch eliminates switch overhead
/// - Linear memory layout improves cache efficiency
/// - BEGINBLOCK instructions are seamlessly integrated
/// - Jump targets are pre-resolved to instruction indices
///
/// ## Example
///
/// Bytecode:
/// ```
/// PUSH1 0x02
/// PUSH1 0x03
/// ADD
/// ```
///
/// Becomes instruction stream:
/// ```
/// [BEGINBLOCK{gas:9, stack_req:0, stack_max:2}]
/// [PUSH1{value:2}]
/// [PUSH1{value:3}]
/// [ADD{}]
/// ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const ExecutionError = @import("../execution/execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const Vm = @import("../evm.zig");
const opcode = @import("../opcodes/opcode.zig");
const Operation = @import("../opcodes/operation.zig");
const BlockMetadata = @import("../frame/code_analysis.zig").BlockMetadata;
const CodeAnalysis = @import("../frame/code_analysis.zig");
const JumpAnalysis = @import("../frame/jump_analysis.zig").JumpAnalysis;
const primitives = @import("primitives");
const EvmLog = @import("../state/evm_log.zig");
const log = @import("../log.zig");
const superinstructions = @import("superinstructions.zig");
const memory_expansion_analysis = @import("memory_expansion_analysis.zig");
const memory_optimized_ops = @import("memory_optimized_ops.zig");
const BlobGasMarket = @import("../blob/blob_gas_market.zig").BlobGasMarket;

/// Function pointer type for instruction execution.
pub const InstructionFn = *const fn (instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction;

/// Packed instruction argument (8 bytes)
pub const InstructionArg = packed union {
    /// No argument
    none: u64,
    
    /// Small push value (PUSH1-8) stored inline
    small_push: u64,
    
    /// Index into push_values array for large pushes (PUSH9-32)
    push_index: u32,
    
    /// Pointer to block metadata
    block_ptr: *const BlockMetadata,
    
    /// Jump target instruction index
    jump_target: u32,
    
    /// Generic data (PC for PC opcode, opcode for generic handler, etc.)
    data: u64,
};

/// A single instruction in the stream (16 bytes total)
pub const Instruction = struct {
    /// Function to execute this instruction (8 bytes)
    fn_ptr: InstructionFn,
    
    /// Instruction-specific argument (8 bytes)
    arg: InstructionArg,
    
    comptime {
        // Ensure instruction is exactly 16 bytes
        std.debug.assert(@sizeOf(Instruction) == 16);
    }
};

/// Advanced execution state (replaces Frame for instruction execution).
pub const AdvancedExecutionState = struct {
    /// Stack (same as Frame)
    stack: *Stack,
    
    /// Memory (reference to Frame's memory)
    memory: *@import("../memory/memory.zig").Memory,
    
    /// Gas remaining
    gas_left: *i64, // Signed for easier underflow detection
    
    /// VM instance for state access
    vm: *Vm,
    
    /// Current frame for context
    frame: *Frame,
    
    /// Exit status (set when execution should stop)
    exit_status: ?ExecutionError.Error = null,
    
    /// Reference to push values array (for large pushes)
    push_values: []const u256,
};

/// Result of instruction stream generation.
pub const InstructionStream = struct {
    /// Linear array of instructions
    instructions: []Instruction,
    
    /// Maps PC to instruction index
    pc_to_instruction: []u32,
    
    /// Storage for large push values (PUSH9-32)
    push_values: []u256,
    
    /// Allocator used for this stream
    allocator: Allocator,
    
    pub fn deinit(self: *InstructionStream) void {
        self.allocator.free(self.instructions);
        self.allocator.free(self.pc_to_instruction);
        self.allocator.free(self.push_values);
    }
};

/// Helper to get next instruction pointer.
pub inline fn next_instruction(instr: *const Instruction) ?*const Instruction {
    const next_ptr = @intFromPtr(instr) + @sizeOf(Instruction);
    return @as(*const Instruction, @ptrFromInt(next_ptr));
}

/// Calculate blob fee from excess blob gas according to EIP-4844.
/// This function implements the blob gas fee calculation for the BLOBBASEFEE opcode.
fn calc_blob_fee(excess_blob_gas: u64) u256 {
    return BlobGasMarket.calculate_blob_base_fee_from_excess_gas(excess_blob_gas);
}

/// Generate instruction stream from bytecode.
pub fn generate_instruction_stream(
    allocator: Allocator,
    bytecode: []const u8,
    analysis: *const CodeAnalysis,
) !InstructionStream {
    log.debug("Generating instruction stream for bytecode of length {}", .{bytecode.len});
    var instructions = std.ArrayList(Instruction).init(allocator);
    defer instructions.deinit();
    
    var pc_to_instruction = try allocator.alloc(u32, bytecode.len);
    errdefer allocator.free(pc_to_instruction);
    
    var push_values = std.ArrayList(u256).init(allocator);
    defer push_values.deinit();
    
    // Initialize all to invalid
    @memset(pc_to_instruction, std.math.maxInt(u32));
    
    // Run memory expansion analysis if enabled
    const memory_blocks = if (analysis.block_count > 0) blk: {
        const blocks = try memory_expansion_analysis.analyze_memory_expansion(allocator, bytecode, analysis.block_start_positions);
        break :blk blocks;
    } else null;
    defer if (memory_blocks) |blocks| {
        for (blocks) |*block| {
            block.accesses.deinit();
        }
        allocator.free(blocks);
    };
    
    var pc: usize = 0;
    var current_block: u16 = 0;
    
    while (pc < bytecode.len) {
        const instr_idx = @as(u32, @intCast(instructions.items.len));
        pc_to_instruction[pc] = instr_idx;
        
        // Check if we're at a block boundary
        if (analysis.block_starts.isSetUnchecked(pc)) {
            // Insert BEGINBLOCK instruction
            const block_meta = &analysis.block_metadata[current_block];
            try instructions.append(.{
                .fn_ptr = &opx_beginblock,
                .arg = .{ .block_ptr = block_meta },
            });
            current_block += 1;
        }
        
        // Check for superinstruction patterns before processing individual opcodes
        if (superinstructions.match_pattern(bytecode, pc)) |match| {
            const pattern = match.pattern;
            
            // Build superinstruction based on pattern type
            const super_instr = switch (pattern.super_op) {
                .PUSH_PUSH_ADD, .PUSH_PUSH_SUB, .PUSH_PUSH_MUL, .PUSH_PUSH_DIV,
                .PUSH_PUSH_EQ, .PUSH_PUSH_LT, .PUSH_PUSH_GT, .PUSH_PUSH_AND => blk: {
                    // Extract two push values and pack them
                    const values = superinstructions.extract_push_values(bytecode, pc, 2);
                    // For now, limit to small values that fit in u32 each
                    const v1 = if (values.v1 > std.math.maxInt(u32)) std.math.maxInt(u32) else @as(u32, @intCast(values.v1));
                    const v2 = if (values.v2 > std.math.maxInt(u32)) std.math.maxInt(u32) else @as(u32, @intCast(values.v2));
                    const packed_value = (@as(u64, v2) << 32) | v1;
                    break :blk Instruction{
                        .fn_ptr = pattern.fn_ptr,
                        .arg = .{ .data = packed_value },
                    };
                },
                .DUP_PUSH_EQ => blk: {
                    // Extract push value after DUP
                    const values = superinstructions.extract_push_values(bytecode, pc + 1, 1);
                    break :blk Instruction{
                        .fn_ptr = pattern.fn_ptr,
                        .arg = .{ .small_push = @as(u64, @intCast(values.v1)) },
                    };
                },
                .PUSH_MLOAD, .PUSH_MSTORE => blk: {
                    // Extract offset value
                    const values = superinstructions.extract_push_values(bytecode, pc, 1);
                    break :blk Instruction{
                        .fn_ptr = pattern.fn_ptr,
                        .arg = .{ .small_push = @as(u64, @intCast(values.v1)) },
                    };
                },
                .ISZERO_PUSH_JUMPI => blk: {
                    // Extract jump destination from PUSH
                    const values = superinstructions.extract_push_values(bytecode, pc + 1, 1);
                    break :blk Instruction{
                        .fn_ptr = pattern.fn_ptr,
                        .arg = .{ .jump_target = @as(u32, @intCast(values.v1)) },
                    };
                },
                .DUP_ISZERO => Instruction{
                    .fn_ptr = pattern.fn_ptr,
                    .arg = .{ .none = 0 },
                },
            };
            
            try instructions.append(super_instr);
            pc += match.length;
            continue;
        }
        
        const op = bytecode[pc];
        const op_enum = @as(opcode.Enum, @enumFromInt(op));
        
        const instruction = switch (op_enum) {
            // Control flow
            .STOP => Instruction{
                .fn_ptr = &op_stop,
                .arg = .{ .none = 0 },
            },
            .JUMP => Instruction{
                .fn_ptr = &op_jump,
                .arg = .{ .none = 0 },
            },
            .JUMPI => Instruction{
                .fn_ptr = &op_jumpi,
                .arg = .{ .none = 0 },
            },
            .JUMPDEST => Instruction{
                .fn_ptr = &op_jumpdest,
                .arg = .{ .none = 0 },
            },
            .RETURN => Instruction{
                .fn_ptr = &op_return,
                .arg = .{ .none = 0 },
            },
            .REVERT => Instruction{
                .fn_ptr = &op_revert,
                .arg = .{ .none = 0 },
            },
            
            // Stack operations
            .POP => Instruction{
                .fn_ptr = &op_pop,
                .arg = .{ .none = 0 },
            },
            .MLOAD => blk: {
                // Check if we have pre-calculated memory expansion cost
                if (memory_blocks) |blocks| {
                    if (current_block < blocks.len) {
                        if (blocks[current_block].accesses.get(pc)) |access| {
                            if (access.expansion_cost) |cost| {
                                // Use optimized version with pre-calculated cost
                                break :blk Instruction{
                                    .fn_ptr = &memory_optimized_ops.op_mload_precalc,
                                    .arg = .{ .data = cost },
                                };
                            }
                        }
                    }
                }
                // Fall back to regular MLOAD
                break :blk Instruction{
                    .fn_ptr = &op_mload,
                    .arg = .{ .none = 0 },
                };
            },
            .MSTORE => blk: {
                // Check if we have pre-calculated memory expansion cost
                if (memory_blocks) |blocks| {
                    if (current_block < blocks.len) {
                        if (blocks[current_block].accesses.get(pc)) |access| {
                            if (access.expansion_cost) |cost| {
                                // Use optimized version with pre-calculated cost
                                break :blk Instruction{
                                    .fn_ptr = &memory_optimized_ops.op_mstore_precalc,
                                    .arg = .{ .data = cost },
                                };
                            }
                        }
                    }
                }
                // Fall back to regular MSTORE
                break :blk Instruction{
                    .fn_ptr = &op_mstore,
                    .arg = .{ .none = 0 },
                };
            },
            
            // Arithmetic
            .ADD => Instruction{
                .fn_ptr = &op_add,
                .arg = .{ .none = 0 },
            },
            .SUB => Instruction{
                .fn_ptr = &op_sub,
                .arg = .{ .none = 0 },
            },
            .MUL => Instruction{
                .fn_ptr = &op_mul,
                .arg = .{ .none = 0 },
            },
            .DIV => Instruction{
                .fn_ptr = &op_div,
                .arg = .{ .none = 0 },
            },
            .SDIV => Instruction{
                .fn_ptr = &op_sdiv,
                .arg = .{ .none = 0 },
            },
            .MOD => Instruction{
                .fn_ptr = &op_mod,
                .arg = .{ .none = 0 },
            },
            .SMOD => Instruction{
                .fn_ptr = &op_smod,
                .arg = .{ .none = 0 },
            },
            .ADDMOD => Instruction{
                .fn_ptr = &op_addmod,
                .arg = .{ .none = 0 },
            },
            .MULMOD => Instruction{
                .fn_ptr = &op_mulmod,
                .arg = .{ .none = 0 },
            },
            .EXP => Instruction{
                .fn_ptr = &op_exp,
                .arg = .{ .none = 0 },
            },
            .SIGNEXTEND => Instruction{
                .fn_ptr = &op_signextend,
                .arg = .{ .none = 0 },
            },
            
            // PUSH operations
            .PUSH0 => Instruction{
                .fn_ptr = &op_push,
                .arg = .{ .small_push = 0 },
            },
            .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8,
            .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16,
            .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24,
            .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => blk: {
                const n = @intFromEnum(op_enum) - @intFromEnum(opcode.Enum.PUSH1) + 1;
                const bytes = bytecode[pc + 1..][0..n];
                var value: u256 = 0;
                for (bytes) |byte| {
                    value = (value << 8) | byte;
                }
                
                // Store small pushes inline, large pushes in separate array
                if (n <= 8) {
                    break :blk Instruction{
                        .fn_ptr = &op_push,
                        .arg = .{ .small_push = @as(u64, @intCast(value)) },
                    };
                } else {
                    const push_idx = @as(u32, @intCast(push_values.items.len));
                    try push_values.append(value);
                    break :blk Instruction{
                        .fn_ptr = &op_push_large,
                        .arg = .{ .push_index = push_idx },
                    };
                }
            },
            
            // DUP operations
            .DUP1, .DUP2, .DUP3, .DUP4, .DUP5, .DUP6, .DUP7, .DUP8,
            .DUP9, .DUP10, .DUP11, .DUP12, .DUP13, .DUP14, .DUP15, .DUP16 => Instruction{
                .fn_ptr = &op_dup,
                .arg = .{ .data = @intFromEnum(op_enum) - @intFromEnum(opcode.Enum.DUP1) + 1 },
            },
            
            // SWAP operations
            .SWAP1, .SWAP2, .SWAP3, .SWAP4, .SWAP5, .SWAP6, .SWAP7, .SWAP8,
            .SWAP9, .SWAP10, .SWAP11, .SWAP12, .SWAP13, .SWAP14, .SWAP15, .SWAP16 => Instruction{
                .fn_ptr = &op_swap,
                .arg = .{ .data = @intFromEnum(op_enum) - @intFromEnum(opcode.Enum.SWAP1) + 1 },
            },
            
            // Comparison operations
            .LT => Instruction{
                .fn_ptr = &op_lt,
                .arg = .{ .none = 0 },
            },
            .GT => Instruction{
                .fn_ptr = &op_gt,
                .arg = .{ .none = 0 },
            },
            .SLT => Instruction{
                .fn_ptr = &op_slt,
                .arg = .{ .none = 0 },
            },
            .SGT => Instruction{
                .fn_ptr = &op_sgt,
                .arg = .{ .none = 0 },
            },
            .EQ => Instruction{
                .fn_ptr = &op_eq,
                .arg = .{ .none = 0 },
            },
            .ISZERO => Instruction{
                .fn_ptr = &op_iszero,
                .arg = .{ .none = 0 },
            },
            
            // Bitwise operations
            .AND => Instruction{
                .fn_ptr = &op_and,
                .arg = .{ .none = 0 },
            },
            .OR => Instruction{
                .fn_ptr = &op_or,
                .arg = .{ .none = 0 },
            },
            .XOR => Instruction{
                .fn_ptr = &op_xor,
                .arg = .{ .none = 0 },
            },
            .NOT => Instruction{
                .fn_ptr = &op_not,
                .arg = .{ .none = 0 },
            },
            .BYTE => Instruction{
                .fn_ptr = &op_byte,
                .arg = .{ .none = 0 },
            },
            .SHL => Instruction{
                .fn_ptr = &op_shl,
                .arg = .{ .none = 0 },
            },
            .SHR => Instruction{
                .fn_ptr = &op_shr,
                .arg = .{ .none = 0 },
            },
            .SAR => Instruction{
                .fn_ptr = &op_sar,
                .arg = .{ .none = 0 },
            },
            
            // Hashing
            .KECCAK256 => Instruction{
                .fn_ptr = &op_keccak256,
                .arg = .{ .none = 0 },
            },
            
            // Environmental information
            .ADDRESS => Instruction{
                .fn_ptr = &op_address,
                .arg = .{ .none = 0 },
            },
            .BALANCE => Instruction{
                .fn_ptr = &op_balance,
                .arg = .{ .none = 0 },
            },
            .ORIGIN => Instruction{
                .fn_ptr = &op_origin,
                .arg = .{ .none = 0 },
            },
            .CALLER => Instruction{
                .fn_ptr = &op_caller,
                .arg = .{ .none = 0 },
            },
            .CALLVALUE => Instruction{
                .fn_ptr = &op_callvalue,
                .arg = .{ .none = 0 },
            },
            .CALLDATALOAD => Instruction{
                .fn_ptr = &op_calldataload,
                .arg = .{ .none = 0 },
            },
            .CALLDATASIZE => Instruction{
                .fn_ptr = &op_calldatasize,
                .arg = .{ .none = 0 },
            },
            .CALLDATACOPY => Instruction{
                .fn_ptr = &op_calldatacopy,
                .arg = .{ .none = 0 },
            },
            .CODESIZE => Instruction{
                .fn_ptr = &op_codesize,
                .arg = .{ .none = 0 },
            },
            .CODECOPY => Instruction{
                .fn_ptr = &op_codecopy,
                .arg = .{ .none = 0 },
            },
            .EXTCODESIZE => Instruction{
                .fn_ptr = &op_extcodesize,
                .arg = .{ .none = 0 },
            },
            .EXTCODECOPY => Instruction{
                .fn_ptr = &op_extcodecopy,
                .arg = .{ .none = 0 },
            },
            .RETURNDATASIZE => Instruction{
                .fn_ptr = &op_returndatasize,
                .arg = .{ .none = 0 },
            },
            .RETURNDATACOPY => Instruction{
                .fn_ptr = &op_returndatacopy,
                .arg = .{ .none = 0 },
            },
            .EXTCODEHASH => Instruction{
                .fn_ptr = &op_extcodehash,
                .arg = .{ .none = 0 },
            },
            .SELFBALANCE => Instruction{
                .fn_ptr = &op_selfbalance,
                .arg = .{ .none = 0 },
            },
            
            // Block information
            .BLOCKHASH => Instruction{
                .fn_ptr = &op_blockhash,
                .arg = .{ .none = 0 },
            },
            .COINBASE => Instruction{
                .fn_ptr = &op_coinbase,
                .arg = .{ .none = 0 },
            },
            .TIMESTAMP => Instruction{
                .fn_ptr = &op_timestamp,
                .arg = .{ .none = 0 },
            },
            .NUMBER => Instruction{
                .fn_ptr = &op_number,
                .arg = .{ .none = 0 },
            },
            .PREVRANDAO => Instruction{
                .fn_ptr = &op_prevrandao,
                .arg = .{ .none = 0 },
            },
            .GASLIMIT => Instruction{
                .fn_ptr = &op_gaslimit,
                .arg = .{ .none = 0 },
            },
            .CHAINID => Instruction{
                .fn_ptr = &op_chainid,
                .arg = .{ .none = 0 },
            },
            .BASEFEE => Instruction{
                .fn_ptr = &op_basefee,
                .arg = .{ .none = 0 },
            },
            .BLOBHASH => Instruction{
                .fn_ptr = &op_blobhash,
                .arg = .{ .none = 0 },
            },
            .BLOBBASEFEE => Instruction{
                .fn_ptr = &op_blobbasefee,
                .arg = .{ .none = 0 },
            },
            .GASPRICE => Instruction{
                .fn_ptr = &op_gasprice,
                .arg = .{ .none = 0 },
            },
            
            // Memory operations
            .MSTORE8 => Instruction{
                .fn_ptr = &op_mstore8,
                .arg = .{ .none = 0 },
            },
            .MSIZE => Instruction{
                .fn_ptr = &op_msize,
                .arg = .{ .none = 0 },
            },
            .MCOPY => Instruction{
                .fn_ptr = &op_mcopy,
                .arg = .{ .none = 0 },
            },
            
            // Storage operations
            .SLOAD => Instruction{
                .fn_ptr = &op_sload,
                .arg = .{ .none = 0 },
            },
            .SSTORE => Instruction{
                .fn_ptr = &op_sstore,
                .arg = .{ .none = 0 },
            },
            .TLOAD => Instruction{
                .fn_ptr = &op_tload,
                .arg = .{ .none = 0 },
            },
            .TSTORE => Instruction{
                .fn_ptr = &op_tstore,
                .arg = .{ .none = 0 },
            },
            
            // Gas opcode
            .GAS => Instruction{
                .fn_ptr = &op_gas,
                .arg = .{ .none = 0 },
            },
            
            // PC opcode
            .PC => Instruction{
                .fn_ptr = &op_pc,
                .arg = .{ .data = pc },
            },
            
            // Logging operations
            .LOG0, .LOG1, .LOG2, .LOG3, .LOG4 => Instruction{
                .fn_ptr = &op_log,
                .arg = .{ .data = opcode.get_log_topic_count(op) },
            },
            
            // System operations  
            .CREATE => Instruction{
                .fn_ptr = &op_create,
                .arg = .{ .none = 0 },
            },
            .CREATE2 => Instruction{
                .fn_ptr = &op_create2,
                .arg = .{ .none = 0 },
            },
            .CALL => Instruction{
                .fn_ptr = &op_call,
                .arg = .{ .none = 0 },
            },
            .CALLCODE => Instruction{
                .fn_ptr = &op_callcode,
                .arg = .{ .none = 0 },
            },
            .DELEGATECALL => Instruction{
                .fn_ptr = &op_delegatecall,
                .arg = .{ .none = 0 },
            },
            .STATICCALL => Instruction{
                .fn_ptr = &op_staticcall,
                .arg = .{ .none = 0 },
            },
            .RETURNDATALOAD => Instruction{
                .fn_ptr = &op_returndataload,
                .arg = .{ .none = 0 },
            },
            .INVALID => Instruction{
                .fn_ptr = &op_invalid,
                .arg = .{ .none = 0 },
            },
            .SELFDESTRUCT => Instruction{
                .fn_ptr = &op_selfdestruct,
                .arg = .{ .none = 0 },
            },
            
            // Extended operations (EOF) - not implemented yet
            .EXTCALL => Instruction{
                .fn_ptr = &op_extcall,
                .arg = .{ .none = 0 },
            },
            .EXTDELEGATECALL => Instruction{
                .fn_ptr = &op_extdelegatecall,
                .arg = .{ .none = 0 },
            },
            .EXTSTATICCALL => Instruction{
                .fn_ptr = &op_extstaticcall,
                .arg = .{ .none = 0 },
            },
        };
        
        try instructions.append(instruction);
        
        // Advance PC
        const bytes_consumed = if (opcode.is_push(op)) 
            1 + opcode.get_push_size(op)
        else 
            1;
        pc += bytes_consumed;
    }
    
    return InstructionStream{
        .instructions = try instructions.toOwnedSlice(),
        .pc_to_instruction = pc_to_instruction,
        .push_values = try push_values.toOwnedSlice(),
        .allocator = allocator,
    };
}

// ============================================================================
// Instruction Implementations
// ============================================================================

/// BEGINBLOCK - validate gas and stack for entire block.
fn opx_beginblock(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const block = instr.arg.block_ptr.*;
    
    // Check gas
    state.gas_left.* -= @as(i64, @intCast(block.gas_cost));
    if (state.gas_left.* < 0) {
        state.exit_status = ExecutionError.Error.OutOfGas;
        return null;
    }
    
    // Check stack
    const stack_size = @as(i16, @intCast(state.stack.size()));
    if (stack_size < block.stack_req) {
        state.exit_status = ExecutionError.Error.StackUnderflow;
        return null;
    }
    if (stack_size + block.stack_max > Stack.CAPACITY) {
        state.exit_status = ExecutionError.Error.StackOverflow;
        return null;
    }
    
    // Store block cost for GAS opcode correction
    state.frame.current_block_cost = block.gas_cost;
    
    return next_instruction(instr); // Continue to next instruction
}

/// STOP - halt execution.
fn op_stop(_: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.exit_status = ExecutionError.Error.STOP;
    return null;
}

/// ADD - addition.
fn op_add(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const a = state.stack.pop_unsafe();
    const b = state.stack.pop_unsafe();
    state.stack.append_unsafe(a +% b);
    return next_instruction(instr);
}

/// SUB - subtraction.
fn op_sub(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const a = state.stack.pop_unsafe();
    const b = state.stack.pop_unsafe();
    state.stack.append_unsafe(a -% b);
    return next_instruction(instr);
}

/// MUL - multiplication.
fn op_mul(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const a = state.stack.pop_unsafe();
    const b = state.stack.pop_unsafe();
    state.stack.append_unsafe(a *% b);
    return next_instruction(instr);
}

/// DIV - division.
fn op_div(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const a = state.stack.pop_unsafe();
    const b = state.stack.pop_unsafe();
    state.stack.append_unsafe(if (b == 0) 0 else a / b);
    return next_instruction(instr);
}

/// POP - remove top stack item.
fn op_pop(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    _ = state.stack.pop_unsafe();
    return next_instruction(instr);
}

/// PUSH - push immediate value (small, inline).
fn op_push(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack.append_unsafe(instr.arg.small_push);
    return next_instruction(instr);
}

/// PUSH - push immediate value (large, from push_values array).
fn op_push_large(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const value = state.push_values[instr.arg.push_index];
    state.stack.append_unsafe(value);
    return next_instruction(instr);
}

/// DUP - duplicate stack item.
fn op_dup(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const n = @as(u8, @intCast(instr.arg.data));
    state.stack.dup_unsafe(n);
    return next_instruction(instr);
}

/// SWAP - swap stack items.
fn op_swap(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const n = @as(u8, @intCast(instr.arg.data));
    state.stack.swap_unsafe(n);
    return next_instruction(instr);
}

/// MLOAD - load from memory.
fn op_mload(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const offset = state.stack.pop_unsafe();
    const data = state.memory.get_u256(@intCast(offset)) catch {
        state.exit_status = ExecutionError.Error.OutOfMemory;
        return null;
    };
    state.stack.append_unsafe(data);
    return next_instruction(instr);
}

/// MSTORE - store to memory.
fn op_mstore(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const offset = state.stack.pop_unsafe();
    const value = state.stack.pop_unsafe();
    state.memory.set_u256(@intCast(offset), value) catch {
        state.exit_status = ExecutionError.Error.OutOfMemory;
        return null;
    };
    return next_instruction(instr);
}

/// JUMP - unconditional jump.
fn op_jump(_: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const dest = state.stack.pop_unsafe();
    
    // Validate jump destination at runtime
    if (dest > std.math.maxInt(usize)) {
        state.exit_status = ExecutionError.Error.InvalidJump;
        return null;
    }
    
    state.frame.pc = @intCast(dest);
    
    // Return null to exit instruction stream and re-enter at new location
    return null;
}

/// JUMPI - conditional jump.
fn op_jumpi(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const dest = state.stack.pop_unsafe();
    const condition = state.stack.pop_unsafe();
    
    if (condition != 0) {
        // Validate jump destination at runtime
        if (dest > std.math.maxInt(usize)) {
            state.exit_status = ExecutionError.Error.InvalidJump;
            return null;
        }
        
        state.frame.pc = @intCast(dest);
        return null; // Re-enter at jump target
    }
    
    return next_instruction(instr); // Continue to next instruction
}

/// JUMPDEST - mark valid jump destination (no-op).
fn op_jumpdest(instr: *const Instruction, _: *AdvancedExecutionState) ?*const Instruction {
    return next_instruction(instr);
}

/// RETURN - return from execution.
fn op_return(_: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const offset = state.stack.pop_unsafe();
    const size = state.stack.pop_unsafe();
    
    if (size > 0) {
        const mem_data = state.memory.get_slice(@intCast(offset), @intCast(size)) catch {
            state.exit_status = ExecutionError.Error.OutOfMemory;
            return null;
        };
        const data = state.vm.allocator.alloc(u8, @intCast(size)) catch {
            state.exit_status = ExecutionError.Error.OutOfMemory;
            return null;
        };
        @memcpy(data, mem_data);
        state.frame.output = data;
    }
    
    state.exit_status = ExecutionError.Error.STOP;
    return null;
}

/// REVERT - revert execution.
fn op_revert(_: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const offset = state.stack.pop_unsafe();
    const size = state.stack.pop_unsafe();
    
    if (size > 0) {
        const mem_data = state.memory.get_slice(@intCast(offset), @intCast(size)) catch {
            state.exit_status = ExecutionError.Error.OutOfMemory;
            return null;
        };
        const data = state.vm.allocator.alloc(u8, @intCast(size)) catch {
            state.exit_status = ExecutionError.Error.OutOfMemory;
            return null;
        };
        @memcpy(data, mem_data);
        state.frame.output = data;
    }
    
    state.exit_status = ExecutionError.Error.REVERT;
    return null;
}

/// LT - less than comparison.
fn op_lt(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const a = state.stack.pop_unsafe();
    const b = state.stack.pop_unsafe();
    state.stack.append_unsafe(if (a < b) 1 else 0);
    return next_instruction(instr);
}

/// GT - greater than comparison.
fn op_gt(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const a = state.stack.pop_unsafe();
    const b = state.stack.pop_unsafe();
    state.stack.append_unsafe(if (a > b) 1 else 0);
    return next_instruction(instr);
}

/// EQ - equality comparison.
fn op_eq(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const a = state.stack.pop_unsafe();
    const b = state.stack.pop_unsafe();
    state.stack.append_unsafe(if (a == b) 1 else 0);
    return next_instruction(instr);
}

/// ISZERO - check if value is zero.
fn op_iszero(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const a = state.stack.pop_unsafe();
    state.stack.append_unsafe(if (a == 0) 1 else 0);
    return next_instruction(instr);
}

/// AND - bitwise AND.
fn op_and(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const a = state.stack.pop_unsafe();
    const b = state.stack.pop_unsafe();
    state.stack.append_unsafe(a & b);
    return next_instruction(instr);
}

/// OR - bitwise OR.
fn op_or(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const a = state.stack.pop_unsafe();
    const b = state.stack.pop_unsafe();
    state.stack.append_unsafe(a | b);
    return next_instruction(instr);
}

/// XOR - bitwise XOR.
fn op_xor(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const a = state.stack.pop_unsafe();
    const b = state.stack.pop_unsafe();
    state.stack.append_unsafe(a ^ b);
    return next_instruction(instr);
}

/// NOT - bitwise NOT.
fn op_not(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const a = state.stack.pop_unsafe();
    state.stack.append_unsafe(~a);
    return next_instruction(instr);
}

/// ADDRESS - get address of current account.
fn op_address(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const addr = primitives.Address.to_u256(state.frame.contract.address);
    state.stack.append_unsafe(addr);
    return next_instruction(instr);
}

/// CALLER - get caller address.
fn op_caller(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const caller = primitives.Address.to_u256(state.frame.contract.caller);
    state.stack.append_unsafe(caller);
    return next_instruction(instr);
}

/// CALLVALUE - get call value.
fn op_callvalue(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack.append_unsafe(state.frame.contract.value);
    return next_instruction(instr);
}

/// CALLDATASIZE - get size of call data.
fn op_calldatasize(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack.append_unsafe(@as(u256, state.frame.input.len));
    return next_instruction(instr);
}

/// CALLDATALOAD - load call data.
fn op_calldataload(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const offset = state.stack.pop_unsafe();
    
    var data: [32]u8 = [_]u8{0} ** 32;
    if (offset < state.frame.input.len) {
        const remaining = state.frame.input.len - @as(usize, @intCast(offset));
        const copy_len = @min(32, remaining);
        @memcpy(data[0..copy_len], state.frame.input[@intCast(offset)..][0..copy_len]);
    }
    
    state.stack.append_unsafe(std.mem.readInt(u256, &data, .big));
    return next_instruction(instr);
}

/// CALLDATACOPY - copy call data to memory.
fn op_calldatacopy(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const dest_offset = state.stack.pop_unsafe();
    const src_offset = state.stack.pop_unsafe();
    const size = state.stack.pop_unsafe();
    
    if (size > 0) {
        const dest = @as(usize, @intCast(dest_offset));
        const src = @as(usize, @intCast(src_offset));
        const len = @as(usize, @intCast(size));
        
        // Gas cost for memory expansion
        const memory_cost = state.memory.get_expansion_cost(dest + len);
        
        state.gas_left.* -= @as(i64, @intCast(memory_cost));
        if (state.gas_left.* < 0) {
            state.exit_status = ExecutionError.Error.OutOfGas;
            return null;
        }
        
        // Copy data
        state.memory.set_data_bounded(dest, state.frame.input, src, len) catch {
            state.exit_status = ExecutionError.Error.OutOfMemory;
            return null;
        };
    }
    
    return next_instruction(instr);
}

/// BLOCKHASH - get block hash.
fn op_blockhash(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    _ = state.stack.pop_unsafe();
    
    // For now, return zero (proper implementation would query state)
    state.stack.append_unsafe(0);
    return next_instruction(instr);
}

/// COINBASE - get block coinbase.
fn op_coinbase(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const coinbase = primitives.Address.to_u256(state.vm.context.block_coinbase);
    state.stack.append_unsafe(coinbase);
    return next_instruction(instr);
}

/// ORIGIN - get transaction originator.
fn op_origin(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const origin = primitives.Address.to_u256(state.vm.context.tx_origin);
    state.stack.append_unsafe(origin);
    return next_instruction(instr);
}

/// TIMESTAMP - get block timestamp.
fn op_timestamp(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack.append_unsafe(@as(u256, state.vm.context.block_timestamp));
    return next_instruction(instr);
}

/// NUMBER - get block number.
fn op_number(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack.append_unsafe(@as(u256, state.vm.context.block_number));
    return next_instruction(instr);
}

/// GASLIMIT - get block gas limit.
fn op_gaslimit(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack.append_unsafe(@as(u256, state.vm.context.block_gas_limit));
    return next_instruction(instr);
}

/// GASPRICE - get gas price.
fn op_gasprice(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack.append_unsafe(state.vm.context.gas_price);
    return next_instruction(instr);
}

/// MSTORE8 - store byte to memory.
fn op_mstore8(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const offset = state.stack.pop_unsafe();
    const value = state.stack.pop_unsafe();
    
    const byte_value = @as(u8, @truncate(value));
    const bytes = [_]u8{byte_value};
    state.memory.set_data(@intCast(offset), &bytes) catch {
        state.exit_status = ExecutionError.Error.OutOfMemory;
        return null;
    };
    
    return next_instruction(instr);
}

/// MSIZE - get memory size.
fn op_msize(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const size = state.memory.size();
    state.stack.append_unsafe(@as(u256, size));
    return next_instruction(instr);
}

/// GAS - get remaining gas (with block correction).
fn op_gas(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    // Add back the current block's cost since it was deducted upfront
    const gas_available = @as(u64, @intCast(state.gas_left.*)) + state.frame.current_block_cost;
    state.stack.append_unsafe(@as(u256, gas_available));
    return next_instruction(instr);
}

/// PC - get program counter.
fn op_pc(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack.append_unsafe(@as(u256, instr.arg.data));
    return next_instruction(instr);
}

/// SDIV - signed division.
fn op_sdiv(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const a = state.stack.pop_unsafe();
    const b = state.stack.pop_unsafe();
    const a_signed = @as(i256, @bitCast(a));
    const b_signed = @as(i256, @bitCast(b));
    const result = if (b == 0) 0 else @as(u256, @bitCast(@divTrunc(a_signed, b_signed)));
    state.stack.append_unsafe(result);
    return next_instruction(instr);
}

/// MOD - modulo.
fn op_mod(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const a = state.stack.pop_unsafe();
    const b = state.stack.pop_unsafe();
    state.stack.append_unsafe(if (b == 0) 0 else a % b);
    return next_instruction(instr);
}

/// SMOD - signed modulo.
fn op_smod(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const a = state.stack.pop_unsafe();
    const b = state.stack.pop_unsafe();
    const a_signed = @as(i256, @bitCast(a));
    const b_signed = @as(i256, @bitCast(b));
    const result = if (b == 0) 0 else @as(u256, @bitCast(@rem(a_signed, b_signed)));
    state.stack.append_unsafe(result);
    return next_instruction(instr);
}

/// ADDMOD - addition modulo.
fn op_addmod(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const a = state.stack.pop_unsafe();
    const b = state.stack.pop_unsafe();
    const n = state.stack.pop_unsafe();
    if (n == 0) {
        state.stack.append_unsafe(0);
    } else {
        const sum = std.math.add(u512, a, b) catch unreachable;
        state.stack.append_unsafe(@intCast(sum % n));
    }
    return next_instruction(instr);
}

/// MULMOD - multiplication modulo.
fn op_mulmod(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const a = state.stack.pop_unsafe();
    const b = state.stack.pop_unsafe();
    const n = state.stack.pop_unsafe();
    if (n == 0) {
        state.stack.append_unsafe(0);
    } else {
        const product = std.math.mul(u512, a, b) catch unreachable;
        state.stack.append_unsafe(@intCast(product % n));
    }
    return next_instruction(instr);
}

/// EXP - exponentiation.
fn op_exp(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const base = state.stack.pop_unsafe();
    const exponent = state.stack.pop_unsafe();
    
    // Fast path for common cases
    if (exponent == 0) {
        state.stack.append_unsafe(1);
    } else if (exponent == 1) {
        state.stack.append_unsafe(base);
    } else if (base == 0) {
        state.stack.append_unsafe(0);
    } else if (base == 1) {
        state.stack.append_unsafe(1);
    } else {
        // General case - use exponentiation by squaring
        var result: u256 = 1;
        var b = base;
        var e = exponent;
        while (e > 0) {
            if (e & 1 == 1) {
                result *%= b;
            }
            b *%= b;
            e >>= 1;
        }
        state.stack.append_unsafe(result);
    }
    return next_instruction(instr);
}

/// SIGNEXTEND - sign extend.
fn op_signextend(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const byte_size = state.stack.pop_unsafe();
    const value = state.stack.pop_unsafe();
    
    if (byte_size >= 31) {
        state.stack.append_unsafe(value);
    } else {
        const bit_size = (byte_size + 1) * 8;
        const sign_bit = @as(u256, 1) << @intCast(bit_size - 1);
        const mask = sign_bit - 1;
        const result = if ((value & sign_bit) != 0) value | ~mask else value & mask;
        state.stack.append_unsafe(result);
    }
    return next_instruction(instr);
}

/// SLT - signed less than comparison.
fn op_slt(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const a = state.stack.pop_unsafe();
    const b = state.stack.pop_unsafe();
    const a_signed = @as(i256, @bitCast(a));
    const b_signed = @as(i256, @bitCast(b));
    state.stack.append_unsafe(if (a_signed < b_signed) 1 else 0);
    return next_instruction(instr);
}

/// SGT - signed greater than comparison.
fn op_sgt(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const a = state.stack.pop_unsafe();
    const b = state.stack.pop_unsafe();
    const a_signed = @as(i256, @bitCast(a));
    const b_signed = @as(i256, @bitCast(b));
    state.stack.append_unsafe(if (a_signed > b_signed) 1 else 0);
    return next_instruction(instr);
}

/// BYTE - get byte from word.
fn op_byte(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const byte_index = state.stack.pop_unsafe();
    const value = state.stack.pop_unsafe();
    
    if (byte_index >= 32) {
        state.stack.append_unsafe(0);
    } else {
        const shift = @as(u8, @intCast((31 - byte_index) * 8));
        const byte = (value >> shift) & 0xFF;
        state.stack.append_unsafe(byte);
    }
    return next_instruction(instr);
}

/// SHL - shift left.
fn op_shl(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const shift = state.stack.pop_unsafe();
    const value = state.stack.pop_unsafe();
    
    if (shift >= 256) {
        state.stack.append_unsafe(0);
    } else {
        state.stack.append_unsafe(value << @intCast(shift));
    }
    return next_instruction(instr);
}

/// SHR - logical shift right.
fn op_shr(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const shift = state.stack.pop_unsafe();
    const value = state.stack.pop_unsafe();
    
    if (shift >= 256) {
        state.stack.append_unsafe(0);
    } else {
        state.stack.append_unsafe(value >> @intCast(shift));
    }
    return next_instruction(instr);
}

/// SAR - arithmetic shift right.
fn op_sar(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const shift = state.stack.pop_unsafe();
    const value = state.stack.pop_unsafe();
    
    if (shift >= 256) {
        // Sign extend
        const sign_bit = value >> 255;
        state.stack.append_unsafe(if (sign_bit == 1) std.math.maxInt(u256) else 0);
    } else {
        const value_signed = @as(i256, @bitCast(value));
        const result = value_signed >> @intCast(shift);
        state.stack.append_unsafe(@bitCast(result));
    }
    return next_instruction(instr);
}

/// KECCAK256 - compute Keccak-256 hash.
fn op_keccak256(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const offset = state.stack.pop_unsafe();
    const size = state.stack.pop_unsafe();
    
    if (size > 0) {
        const data = state.memory.get_slice(@intCast(offset), @intCast(size)) catch {
            state.exit_status = ExecutionError.Error.OutOfMemory;
            return null;
        };
        
        var hash: [32]u8 = undefined;
        // TODO: Implement actual Keccak-256 hashing
        // For now, just use the data to avoid unused variable warning
        _ = data;
        @memset(&hash, 0);
        
        state.stack.append_unsafe(std.mem.readInt(u256, &hash, .big));
    } else {
        // Keccak256 of empty data
        const empty_hash = [_]u8{0xc5} ** 32; // Placeholder
        state.stack.append_unsafe(std.mem.readInt(u256, &empty_hash, .big));
    }
    
    return next_instruction(instr);
}

/// BALANCE - get balance of account.
fn op_balance(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const addr = state.stack.pop_unsafe();
    
    // Convert u256 to address
    var addr_bytes: primitives.Address.Address = undefined;
    const addr_slice = std.mem.asBytes(&addr);
    @memcpy(&addr_bytes, addr_slice[12..32]);
    
    // Get balance from state
    const account = state.vm.state.database.get_account(addr_bytes) catch return null;
    const balance = if (account) |acc| acc.balance else 0;
    
    state.stack.append_unsafe(balance);
    return next_instruction(instr);
}

/// CODESIZE - get size of code.
fn op_codesize(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack.append_unsafe(@as(u256, state.frame.contract.input.len));
    return next_instruction(instr);
}

/// CODECOPY - copy code to memory.
fn op_codecopy(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const dest_offset = state.stack.pop_unsafe();
    const src_offset = state.stack.pop_unsafe();
    const size = state.stack.pop_unsafe();
    
    if (size > 0) {
        const dest = @as(usize, @intCast(dest_offset));
        const src = @as(usize, @intCast(src_offset));
        const len = @as(usize, @intCast(size));
        
        // Gas cost for memory expansion
        const memory_cost = state.memory.get_expansion_cost(dest + len);
        
        state.gas_left.* -= @as(i64, @intCast(memory_cost));
        if (state.gas_left.* < 0) {
            state.exit_status = ExecutionError.Error.OutOfGas;
            return null;
        }
        
        // Copy data
        state.memory.set_data_bounded(dest, state.frame.contract.input, src, len) catch {
            state.exit_status = ExecutionError.Error.OutOfMemory;
            return null;
        };
    }
    
    return next_instruction(instr);
}

/// EXTCODESIZE - get external code size.
fn op_extcodesize(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const addr = state.stack.pop_unsafe();
    
    // Convert u256 to address
    var addr_bytes: primitives.Address.Address = undefined;
    const addr_slice = std.mem.asBytes(&addr);
    @memcpy(&addr_bytes, addr_slice[12..32]);
    
    // Get code size from database
    const account = state.vm.state.database.get_account(addr_bytes) catch return null;
    const account_info = account orelse return null;
    const code_hash = account_info.code_hash;
    
    const crypto = @import("crypto");
    if (std.mem.eql(u8, &code_hash, &crypto.EMPTY_KECCAK256) or std.mem.eql(u8, &code_hash, &crypto.ZERO_HASH)) {
        state.stack.append_unsafe(0);
    } else {
        const code = state.vm.state.database.get_code(code_hash) catch &[_]u8{};
        state.stack.append_unsafe(@as(u256, code.len));
    }
    
    return next_instruction(instr);
}

/// EXTCODECOPY - copy external code to memory.
fn op_extcodecopy(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const addr = state.stack.pop_unsafe();
    const dest_offset = state.stack.pop_unsafe();
    const src_offset = state.stack.pop_unsafe();
    const size = state.stack.pop_unsafe();
    
    // Convert u256 to address
    var addr_bytes: primitives.Address.Address = undefined;
    const addr_slice = std.mem.asBytes(&addr);
    @memcpy(&addr_bytes, addr_slice[12..32]);
    
    // Get code from database
    const account = state.vm.state.database.get_account(addr_bytes) catch return null;
    const account_info = account orelse return null;
    const code_hash = account_info.code_hash;
    const crypto = @import("crypto");
    const code = if (std.mem.eql(u8, &code_hash, &crypto.EMPTY_KECCAK256) or std.mem.eql(u8, &code_hash, &crypto.ZERO_HASH))
        &[_]u8{}
    else
        state.vm.state.database.get_code(code_hash) catch &[_]u8{};
    
    if (size > 0) {
        const dest = @as(usize, @intCast(dest_offset));
        const src = @as(usize, @intCast(src_offset));
        const len = @as(usize, @intCast(size));
        
        // Gas cost for memory expansion
        const memory_cost = state.memory.get_expansion_cost(dest + len);
        
        state.gas_left.* -= @as(i64, @intCast(memory_cost));
        if (state.gas_left.* < 0) {
            state.exit_status = ExecutionError.Error.OutOfGas;
            return null;
        }
        
        // Copy data
        state.memory.set_data_bounded(dest, code, src, len) catch {
            state.exit_status = ExecutionError.Error.OutOfMemory;
            return null;
        };
    }
    
    return next_instruction(instr);
}

/// RETURNDATASIZE - get return data size.
fn op_returndatasize(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack.append_unsafe(@as(u256, state.frame.return_data.size()));
    return next_instruction(instr);
}

/// RETURNDATACOPY - copy return data to memory.
fn op_returndatacopy(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const dest_offset = state.stack.pop_unsafe();
    const src_offset = state.stack.pop_unsafe();
    const size = state.stack.pop_unsafe();
    
    // Check bounds
    if (src_offset > state.frame.return_data.size() or 
        size > state.frame.return_data.size() - src_offset) {
        state.exit_status = ExecutionError.Error.ReturnDataOutOfBounds;
        return null;
    }
    
    if (size > 0) {
        const dest = @as(usize, @intCast(dest_offset));
        const src = @as(usize, @intCast(src_offset));
        const len = @as(usize, @intCast(size));
        
        // Gas cost for memory expansion
        const memory_cost = state.memory.get_expansion_cost(dest + len);
        
        state.gas_left.* -= @as(i64, @intCast(memory_cost));
        if (state.gas_left.* < 0) {
            state.exit_status = ExecutionError.Error.OutOfGas;
            return null;
        }
        
        // Copy data
        state.memory.set_data_bounded(dest, state.frame.return_data.get(), src, len) catch {
            state.exit_status = ExecutionError.Error.OutOfMemory;
            return null;
        };
    }
    
    return next_instruction(instr);
}

/// EXTCODEHASH - get external code hash.
fn op_extcodehash(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const addr = state.stack.pop_unsafe();
    
    // Convert u256 to address
    var addr_bytes: primitives.Address.Address = undefined;
    const addr_slice = std.mem.asBytes(&addr);
    @memcpy(&addr_bytes, addr_slice[12..32]);
    
    // Get code hash from database
    const account = state.vm.state.database.get_account(addr_bytes) catch return null;
    const account_info = account orelse return null;
    state.stack.append_unsafe(std.mem.readInt(u256, &account_info.code_hash, .big));
    
    return next_instruction(instr);
}

/// SELFBALANCE - get balance of current account.
fn op_selfbalance(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const account = state.vm.state.database.get_account(state.frame.contract.address) catch return null;
    const balance = if (account) |acc| acc.balance else 0;
    state.stack.append_unsafe(balance);
    return next_instruction(instr);
}

/// PREVRANDAO - get previous RANDAO value.
fn op_prevrandao(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack.append_unsafe(state.vm.context.block_difficulty);
    return next_instruction(instr);
}

/// CHAINID - get chain ID.
fn op_chainid(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack.append_unsafe(state.vm.context.chain_id);
    return next_instruction(instr);
}

/// BASEFEE - get base fee.
fn op_basefee(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack.append_unsafe(state.vm.context.block_base_fee);
    return next_instruction(instr);
}

/// BLOBHASH - get blob hash.
fn op_blobhash(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const index = state.stack.pop_unsafe();
    
    if (state.vm.context.blob_hashes.len > 0) {
        if (index < state.vm.context.blob_hashes.len) {
            const hash = state.vm.context.blob_hashes[@intCast(index)];
            state.stack.append_unsafe(hash);
        } else {
            state.stack.append_unsafe(0);
        }
    } else {
        state.stack.append_unsafe(0);
    }
    
    return next_instruction(instr);
}

/// BLOBBASEFEE - get blob base fee.
fn op_blobbasefee(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const excess_blob_gas = 0; // TODO: Add excess_blob_gas to context
    const blob_fee = calc_blob_fee(excess_blob_gas);
    state.stack.append_unsafe(@as(u256, blob_fee));
    return next_instruction(instr);
}

/// MCOPY - copy memory.
fn op_mcopy(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const dest_offset = state.stack.pop_unsafe();
    const src_offset = state.stack.pop_unsafe();
    const size = state.stack.pop_unsafe();
    
    if (size > 0) {
        const dest = @as(usize, @intCast(dest_offset));
        const src = @as(usize, @intCast(src_offset));
        const len = @as(usize, @intCast(size));
        
        // Read from source and write to destination
        const data = state.memory.get_slice(src, len) catch {
            state.exit_status = ExecutionError.Error.OutOfMemory;
            return null;
        };
        state.memory.set_data(dest, data) catch {
            state.exit_status = ExecutionError.Error.OutOfMemory;
            return null;
        };
    }
    
    return next_instruction(instr);
}

/// SLOAD - load from storage.
fn op_sload(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const key = state.stack.pop_unsafe();
    
    const value = state.vm.state.database.get_storage(state.frame.contract.address, key) catch 0;
    state.stack.append_unsafe(value);
    return next_instruction(instr);
}

/// SSTORE - store to storage.
fn op_sstore(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const key = state.stack.pop_unsafe();
    const value = state.stack.pop_unsafe();
    
    // Check if in static call
    if (state.frame.is_static) {
        state.exit_status = ExecutionError.Error.StaticStateChange;
        return null;
    }
    
    // Store to database with journaling
    state.vm.state.database.set_storage(state.frame.contract.address, key, value) catch {};
    
    return next_instruction(instr);
}

/// TLOAD - load from transient storage.
fn op_tload(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const key = state.stack.pop_unsafe();
    
    const value = state.vm.state.get_transient_storage(state.frame.contract.address, key);
    state.stack.append_unsafe(value);
    return next_instruction(instr);
}

/// TSTORE - store to transient storage.
fn op_tstore(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const key = state.stack.pop_unsafe();
    const value = state.stack.pop_unsafe();
    
    // Check if in static call
    if (state.frame.is_static) {
        state.exit_status = ExecutionError.Error.StaticStateChange;
        return null;
    }
    
    state.vm.state.set_transient_storage(state.frame.contract.address, key, value) catch {
        state.exit_status = ExecutionError.Error.OutOfMemory;
        return null;
    };
    
    return next_instruction(instr);
}

/// LOG - emit log event.
fn op_log(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const topic_count = @as(u8, @intCast(instr.arg.data));
    const offset = state.stack.pop_unsafe();
    const size = state.stack.pop_unsafe();
    
    // Check if in static call
    if (state.frame.is_static) {
        state.exit_status = ExecutionError.Error.StaticStateChange;
        return null;
    }
    
    // Pop topics
    var topics = std.ArrayList(u256).init(state.vm.allocator);
    defer topics.deinit();
    
    var i: u8 = 0;
    while (i < topic_count) : (i += 1) {
        const topic = state.stack.pop_unsafe();
        topics.append(topic) catch {
            state.exit_status = ExecutionError.Error.OutOfMemory;
            return null;
        };
    }
    
    // Get log data from memory
    const data = if (size > 0) blk: {
        const log_data = state.memory.get_slice(@intCast(offset), @intCast(size)) catch {
            state.exit_status = ExecutionError.Error.OutOfMemory;
            return null;
        };
        break :blk state.vm.allocator.dupe(u8, log_data) catch {
            state.exit_status = ExecutionError.Error.OutOfMemory;
            return null;
        };
    } else &[_]u8{};
    
    // Emit log via VM
    const topics_slice = topics.toOwnedSlice() catch {
        state.exit_status = ExecutionError.Error.OutOfMemory;
        return null;
    };
    defer state.vm.allocator.free(topics_slice);
    
    state.vm.emit_log(state.frame.contract.address, topics_slice, data) catch {
        state.exit_status = ExecutionError.Error.OutOfMemory;
        return null;
    };
    
    return next_instruction(instr);
}

/// CREATE - create new contract.
fn op_create(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const value = state.stack.pop_unsafe();
    const offset = state.stack.pop_unsafe();
    const size = state.stack.pop_unsafe();
    
    // Check if in static call
    if (state.frame.is_static) {
        state.exit_status = ExecutionError.Error.StaticStateChange;
        return null;
    }
    
    // Get init code from memory
    const init_code = if (size > 0) 
        state.memory.get_slice(@intCast(offset), @intCast(size)) catch {
            state.exit_status = ExecutionError.Error.OutOfMemory;
            return null;
        }
    else
        &[_]u8{};
    
    // For now, push zero address (would create contract in real implementation)
    _ = value;
    _ = init_code;
    state.stack.append_unsafe(0);
    
    return next_instruction(instr);
}

/// CREATE2 - create new contract with deterministic address.
fn op_create2(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const value = state.stack.pop_unsafe();
    const offset = state.stack.pop_unsafe();
    const size = state.stack.pop_unsafe();
    const salt = state.stack.pop_unsafe();
    
    // Check if in static call
    if (state.frame.is_static) {
        state.exit_status = ExecutionError.Error.StaticStateChange;
        return null;
    }
    
    // Get init code from memory
    const init_code = if (size > 0) 
        state.memory.get_slice(@intCast(offset), @intCast(size)) catch {
            state.exit_status = ExecutionError.Error.OutOfMemory;
            return null;
        }
    else
        &[_]u8{};
    
    // For now, push zero address (would create contract in real implementation)
    _ = value;
    _ = init_code;
    _ = salt;
    state.stack.append_unsafe(0);
    
    return next_instruction(instr);
}

/// CALL - message call to another contract.
fn op_call(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const gas = state.stack.pop_unsafe();
    const addr = state.stack.pop_unsafe();
    const value = state.stack.pop_unsafe();
    const args_offset = state.stack.pop_unsafe();
    const args_size = state.stack.pop_unsafe();
    const ret_offset = state.stack.pop_unsafe();
    const ret_size = state.stack.pop_unsafe();
    
    // Check if value transfer in static call
    if (state.frame.is_static and value != 0) {
        state.exit_status = ExecutionError.Error.StaticStateChange;
        return null;
    }
    
    // For now, push success (would execute call in real implementation)
    _ = gas;
    _ = addr;
    _ = args_offset;
    _ = args_size;
    _ = ret_offset;
    _ = ret_size;
    state.stack.append_unsafe(1);
    
    return next_instruction(instr);
}

/// CALLCODE - message call with current code.
fn op_callcode(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const gas = state.stack.pop_unsafe();
    const addr = state.stack.pop_unsafe();
    const value = state.stack.pop_unsafe();
    const args_offset = state.stack.pop_unsafe();
    const args_size = state.stack.pop_unsafe();
    const ret_offset = state.stack.pop_unsafe();
    const ret_size = state.stack.pop_unsafe();
    
    // For now, push success (would execute call in real implementation)
    _ = gas;
    _ = addr;
    _ = value;
    _ = args_offset;
    _ = args_size;
    _ = ret_offset;
    _ = ret_size;
    state.stack.append_unsafe(1);
    
    return next_instruction(instr);
}

/// DELEGATECALL - delegate call.
fn op_delegatecall(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const gas = state.stack.pop_unsafe();
    const addr = state.stack.pop_unsafe();
    const args_offset = state.stack.pop_unsafe();
    const args_size = state.stack.pop_unsafe();
    const ret_offset = state.stack.pop_unsafe();
    const ret_size = state.stack.pop_unsafe();
    
    // For now, push success (would execute call in real implementation)
    _ = gas;
    _ = addr;
    _ = args_offset;
    _ = args_size;
    _ = ret_offset;
    _ = ret_size;
    state.stack.append_unsafe(1);
    
    return next_instruction(instr);
}

/// STATICCALL - static message call.
fn op_staticcall(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const gas = state.stack.pop_unsafe();
    const addr = state.stack.pop_unsafe();
    const args_offset = state.stack.pop_unsafe();
    const args_size = state.stack.pop_unsafe();
    const ret_offset = state.stack.pop_unsafe();
    const ret_size = state.stack.pop_unsafe();
    
    // For now, push success (would execute call in real implementation)
    _ = gas;
    _ = addr;
    _ = args_offset;
    _ = args_size;
    _ = ret_offset;
    _ = ret_size;
    state.stack.append_unsafe(1);
    
    return next_instruction(instr);
}

/// RETURNDATALOAD - load return data.
fn op_returndataload(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const offset = state.stack.pop_unsafe();
    
    // Check bounds
    if (offset + 32 > state.frame.return_data.size()) {
        state.exit_status = ExecutionError.Error.ReturnDataOutOfBounds;
        return null;
    }
    
    var data: [32]u8 = [_]u8{0} ** 32;
    @memcpy(&data, state.frame.return_data.get()[@intCast(offset)..][0..32]);
    
    state.stack.append_unsafe(std.mem.readInt(u256, &data, .big));
    return next_instruction(instr);
}

/// INVALID - invalid opcode.
fn op_invalid(_: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.exit_status = ExecutionError.Error.InvalidOpcode;
    return null;
}

/// SELFDESTRUCT - destroy contract.
fn op_selfdestruct(_: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const beneficiary_u256 = state.stack.pop_unsafe();
    
    // Check if in static call
    if (state.frame.is_static) {
        state.exit_status = ExecutionError.Error.WriteProtection;
        return null;
    }
    
    // Convert u256 to address using the same logic as system.zig
    const beneficiary_address = primitives.Address.from_u256(beneficiary_u256);
    
    // Mark contract for destruction with recipient (same as system.zig)
    state.vm.state.mark_for_destruction(state.frame.contract.address, beneficiary_address) catch {
        state.exit_status = ExecutionError.Error.OutOfMemory;
        return null;
    };
    
    // SELFDESTRUCT halts execution immediately
    state.exit_status = ExecutionError.Error.STOP;
    return null;
}

/// EXTCALL - extended call (EOF).
fn op_extcall(_: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    // EOF not implemented
    state.exit_status = ExecutionError.Error.InvalidOpcode;
    return null;
}

/// EXTDELEGATECALL - extended delegate call (EOF).
fn op_extdelegatecall(_: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    // EOF not implemented
    state.exit_status = ExecutionError.Error.InvalidOpcode;
    return null;
}

/// EXTSTATICCALL - extended static call (EOF).
fn op_extstaticcall(_: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    // EOF not implemented
    state.exit_status = ExecutionError.Error.InvalidOpcode;
    return null;
}

// Tests
test "instruction stream generation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Simple bytecode: PUSH1 0x02, PUSH1 0x03, ADD, STOP
    const bytecode = [_]u8{ 0x60, 0x02, 0x60, 0x03, 0x01, 0x00 };
    
    // Create mock analysis
    var analysis = CodeAnalysis{
        .jumpdest_analysis = undefined,
        .jumpdest_bitmap = undefined,
        .block_starts = try @import("../frame/bitvec.zig").BitVec(u64).init(allocator, bytecode.len),
        .block_count = 1,
        .block_metadata = try allocator.alloc(BlockMetadata, 1),
        .has_dynamic_jumps = false,
        .max_stack_depth = 2,
        .pc_to_block = try allocator.alloc(u16, bytecode.len),
        .block_start_positions = try allocator.alloc(usize, 1),
        .jump_analysis = null,
    };
    defer analysis.deinit(allocator);
    
    // Mark block start
    analysis.block_starts.setBit(0);
    analysis.block_metadata[0] = .{
        .gas_cost = 9,
        .stack_req = 0,
        .stack_max = 2,
    };
    analysis.block_start_positions[0] = 0;
    @memset(analysis.pc_to_block, 0);
    
    var stream = try generate_instruction_stream(allocator, &bytecode, &analysis);
    defer stream.deinit();
    
    // Should have BEGINBLOCK + 4 instructions
    try testing.expectEqual(@as(usize, 5), stream.instructions.len);
    
    // First should be BEGINBLOCK
    try testing.expectEqual(&opx_beginblock, stream.instructions[0].fn_ptr);
    
    // Then PUSH1 0x02
    try testing.expectEqual(&op_push, stream.instructions[1].fn_ptr);
    try testing.expectEqual(@as(u64, 2), stream.instructions[1].arg.small_push);
    
    // Then PUSH1 0x03
    try testing.expectEqual(&op_push, stream.instructions[2].fn_ptr);
    try testing.expectEqual(@as(u64, 3), stream.instructions[2].arg.small_push);
    
    // Then ADD
    try testing.expectEqual(&op_add, stream.instructions[3].fn_ptr);
    
    // Finally STOP
    try testing.expectEqual(&op_stop, stream.instructions[4].fn_ptr);
}

test "calc_blob_fee function" {
    const testing = std.testing;
    
    // Test with zero excess blob gas - should return minimum fee (1)
    const fee_zero = calc_blob_fee(0);
    try testing.expectEqual(@as(u256, 1), fee_zero);
    
    // Test with some excess blob gas - should be greater than minimum
    const fee_nonzero = calc_blob_fee(1000);
    try testing.expect(fee_nonzero >= 1);
    
    // Test that increasing excess blob gas increases fee
    const fee_low = calc_blob_fee(1000);
    const fee_high = calc_blob_fee(10000);
    try testing.expect(fee_high >= fee_low);
}