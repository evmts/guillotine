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
const Log = @import("../log.zig");

/// Function pointer type for instruction execution.
pub const InstructionFn = *const fn (instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction;

/// Arguments for different instruction types.
pub const InstructionArgument = union {
    /// No arguments (most opcodes)
    none: void,
    
    /// PUSH instructions carry immediate value
    push: struct {
        value: u256,
        bytes: u8, // Number of bytes pushed (1-32)
    },
    
    /// BEGINBLOCK carries block metadata
    block: BlockMetadata,
    
    /// Jump instructions may carry pre-resolved target
    jump: struct {
        target_instr: u32, // Instruction index, not PC
        is_static: bool,   // Whether jump target is constant
    },
};

/// A single instruction in the stream.
pub const Instruction = struct {
    /// Function to execute this instruction
    fn_ptr: InstructionFn,
    
    /// Instruction-specific arguments
    arg: InstructionArgument,
    
    /// Original PC for debugging/tracing
    pc: u32,
    
    /// Opcode for debugging/tracing
    opcode: u8,
};

/// Advanced execution state (replaces Frame for instruction execution).
pub const AdvancedExecutionState = struct {
    /// Stack (same as Frame)
    stack: *Stack,
    
    /// Memory (reference to Frame's memory)
    memory: *@import("../memory/memory.zig"),
    
    /// Gas remaining
    gas_left: *i64, // Signed for easier underflow detection
    
    /// VM instance for state access
    vm: *Vm,
    
    /// Current frame for context
    frame: *Frame,
    
    /// Exit status (set when execution should stop)
    exit_status: ?ExecutionError.Error = null,
};

/// Result of instruction stream generation.
pub const InstructionStream = struct {
    /// Linear array of instructions
    instructions: []Instruction,
    
    /// Maps PC to instruction index
    pc_to_instruction: []u32,
    
    /// Allocator used for this stream
    allocator: Allocator,
    
    pub fn deinit(self: *InstructionStream) void {
        self.allocator.free(self.instructions);
        self.allocator.free(self.pc_to_instruction);
    }
};

/// Helper to get next instruction pointer.
inline fn next_instruction(instr: *const Instruction) ?*const Instruction {
    const next_ptr = @intFromPtr(instr) + @sizeOf(Instruction);
    return @as(*const Instruction, @ptrFromInt(next_ptr));
}

/// Generate instruction stream from bytecode.
pub fn generate_instruction_stream(
    allocator: Allocator,
    bytecode: []const u8,
    analysis: *const CodeAnalysis,
) !InstructionStream {
    Log.debug("Generating instruction stream for bytecode of length {}", .{bytecode.len});
    var instructions = std.ArrayList(Instruction).init(allocator);
    defer instructions.deinit();
    
    var pc_to_instruction = try allocator.alloc(u32, bytecode.len);
    errdefer allocator.free(pc_to_instruction);
    
    // Initialize all to invalid
    @memset(pc_to_instruction, std.math.maxInt(u32));
    
    var pc: usize = 0;
    var current_block: u16 = 0;
    
    while (pc < bytecode.len) {
        const instr_idx = @as(u32, @intCast(instructions.items.len));
        pc_to_instruction[pc] = instr_idx;
        
        // Check if we're at a block boundary
        if (analysis.block_starts.isSetUnchecked(pc)) {
            // Insert BEGINBLOCK instruction
            const block_meta = analysis.block_metadata[current_block];
            try instructions.append(.{
                .fn_ptr = &opx_beginblock,
                .arg = .{ .block = block_meta },
                .pc = @intCast(pc),
                .opcode = @intFromEnum(opcode.Enum.JUMPDEST), // Reuse JUMPDEST as BEGINBLOCK
            });
            current_block += 1;
        }
        
        const op = bytecode[pc];
        const op_enum = @as(opcode.Enum, @enumFromInt(op));
        
        const instruction = switch (op_enum) {
            // Control flow
            .STOP => Instruction{
                .fn_ptr = &op_stop,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .JUMP => blk: {
                // Check if we have jump analysis for static optimization
                if (analysis.jump_analysis) |jump_analysis| {
                    if (jump_analysis.get_jump_info(pc)) |jump_info| {
                        if (jump_info.jump_type == .static and jump_info.destination != null and jump_info.is_valid) {
                            // Pre-resolve static jump to instruction index
                            const dest_pc = @as(usize, @intCast(jump_info.destination.?));
                            break :blk Instruction{
                                .fn_ptr = &op_jump_static,
                                .arg = .{ .jump = .{
                                    .target_instr = 0, // Will be resolved in second pass
                                    .is_static = true,
                                } },
                                .pc = @intCast(pc),
                                .opcode = op,
                            };
                        }
                    }
                }
                break :blk Instruction{
                    .fn_ptr = &op_jump,
                    .arg = .none,
                    .pc = @intCast(pc),
                    .opcode = op,
                };
            },
            .JUMPI => blk: {
                // Check if we have jump analysis for static optimization
                if (analysis.jump_analysis) |jump_analysis| {
                    if (jump_analysis.get_jump_info(pc)) |jump_info| {
                        if (jump_info.jump_type == .static and jump_info.destination != null and jump_info.is_valid) {
                            // Pre-resolve static jump to instruction index
                            const dest_pc = @as(usize, @intCast(jump_info.destination.?));
                            break :blk Instruction{
                                .fn_ptr = &op_jumpi_static,
                                .arg = .{ .jump = .{
                                    .target_instr = 0, // Will be resolved in second pass
                                    .is_static = true,
                                } },
                                .pc = @intCast(pc),
                                .opcode = op,
                            };
                        }
                    }
                }
                break :blk Instruction{
                    .fn_ptr = &op_jumpi,
                    .arg = .none,
                    .pc = @intCast(pc),
                    .opcode = op,
                };
            },
            .JUMPDEST => Instruction{
                .fn_ptr = &op_jumpdest,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .RETURN => Instruction{
                .fn_ptr = &op_return,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .REVERT => Instruction{
                .fn_ptr = &op_revert,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            
            // Stack operations
            .POP => Instruction{
                .fn_ptr = &op_pop,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .MLOAD => Instruction{
                .fn_ptr = &op_mload,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .MSTORE => Instruction{
                .fn_ptr = &op_mstore,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            
            // Arithmetic
            .ADD => Instruction{
                .fn_ptr = &op_add,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .SUB => Instruction{
                .fn_ptr = &op_sub,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .MUL => Instruction{
                .fn_ptr = &op_mul,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .DIV => Instruction{
                .fn_ptr = &op_div,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            
            // PUSH operations
            .PUSH0 => Instruction{
                .fn_ptr = &op_push,
                .arg = .{ .push = .{ .value = 0, .bytes = 0 } },
                .pc = @intCast(pc),
                .opcode = op,
            },
            .PUSH1...opcode.Enum.PUSH32 => |push_op| blk: {
                const n = @intFromEnum(push_op) - @intFromEnum(opcode.Enum.PUSH1) + 1;
                const bytes = bytecode[pc + 1..][0..n];
                var value: u256 = 0;
                for (bytes) |byte| {
                    value = (value << 8) | byte;
                }
                break :blk Instruction{
                    .fn_ptr = &op_push,
                    .arg = .{ .push = .{ .value = value, .bytes = @intCast(n) } },
                    .pc = @intCast(pc),
                    .opcode = op,
                };
            },
            
            // DUP operations
            .DUP1...opcode.Enum.DUP16 => Instruction{
                .fn_ptr = &op_dup,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            
            // SWAP operations
            .SWAP1...opcode.Enum.SWAP16 => Instruction{
                .fn_ptr = &op_swap,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            
            // Comparison operations
            .LT => Instruction{
                .fn_ptr = &op_lt,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .GT => Instruction{
                .fn_ptr = &op_gt,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .EQ => Instruction{
                .fn_ptr = &op_eq,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .ISZERO => Instruction{
                .fn_ptr = &op_iszero,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            
            // Bitwise operations
            .AND => Instruction{
                .fn_ptr = &op_and,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .OR => Instruction{
                .fn_ptr = &op_or,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .XOR => Instruction{
                .fn_ptr = &op_xor,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .NOT => Instruction{
                .fn_ptr = &op_not,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            
            // Environmental information
            .ADDRESS => Instruction{
                .fn_ptr = &op_address,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .CALLER => Instruction{
                .fn_ptr = &op_caller,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .CALLVALUE => Instruction{
                .fn_ptr = &op_callvalue,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .CALLDATASIZE => Instruction{
                .fn_ptr = &op_calldatasize,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .CALLDATALOAD => Instruction{
                .fn_ptr = &op_calldataload,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .CALLDATACOPY => Instruction{
                .fn_ptr = &op_calldatacopy,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            
            // Block information
            .BLOCKHASH => Instruction{
                .fn_ptr = &op_blockhash,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .COINBASE => Instruction{
                .fn_ptr = &op_coinbase,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .TIMESTAMP => Instruction{
                .fn_ptr = &op_timestamp,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .NUMBER => Instruction{
                .fn_ptr = &op_number,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .GASLIMIT => Instruction{
                .fn_ptr = &op_gaslimit,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .GASPRICE => Instruction{
                .fn_ptr = &op_gasprice,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            
            // Memory operations
            .MSTORE8 => Instruction{
                .fn_ptr = &op_mstore8,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            .MSIZE => Instruction{
                .fn_ptr = &op_msize,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            
            // Gas opcode
            .GAS => Instruction{
                .fn_ptr = &op_gas,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            
            // PC opcode
            .PC => Instruction{
                .fn_ptr = &op_pc,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
            
            // Default: use generic handler
            else => Instruction{
                .fn_ptr = &op_generic,
                .arg = .none,
                .pc = @intCast(pc),
                .opcode = op,
            },
        };
        
        try instructions.append(instruction);
        
        // Advance PC
        const bytes_consumed = Operation.OPCODE_INFO_TABLE[@intFromEnum(op_enum)].bytes_consumed;
        pc += bytes_consumed;
    }
    
    // Second pass: resolve static jump targets to instruction indices
    if (analysis.jump_analysis) |jump_analysis| {
        for (instructions.items, 0..instructions.items.len) |*instr, idx| {
            if (instr.opcode == @intFromEnum(opcode.Enum.JUMP) or 
                instr.opcode == @intFromEnum(opcode.Enum.JUMPI)) {
                if (instr.arg == .jump and instr.arg.jump.is_static) {
                    // Get the static destination from jump analysis
                    if (jump_analysis.get_jump_info(instr.pc)) |jump_info| {
                        if (jump_info.destination) |dest| {
                            const dest_pc = @as(usize, @intCast(dest));
                            if (dest_pc < pc_to_instruction.len) {
                                const target_idx = pc_to_instruction[dest_pc];
                                if (target_idx != std.math.maxInt(u32)) {
                                    instr.arg = .{ .jump = .{
                                        .target_instr = target_idx,
                                        .is_static = true,
                                    } };
                                    Log.debug("Resolved static jump at PC {} to instruction index {}", .{instr.pc, target_idx});
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    return InstructionStream{
        .instructions = try instructions.toOwnedSlice(),
        .pc_to_instruction = pc_to_instruction,
        .allocator = allocator,
    };
}

// ============================================================================
// Instruction Implementations
// ============================================================================

/// BEGINBLOCK - validate gas and stack for entire block.
fn opx_beginblock(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const block = instr.arg.block;
    
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
fn op_stop(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    _ = instr;
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

/// PUSH - push immediate value.
fn op_push(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack.append_unsafe(instr.arg.push.value);
    return next_instruction(instr);
}

/// DUP - duplicate stack item.
fn op_dup(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const n = instr.opcode - @intFromEnum(opcode.Enum.DUP1) + 1;
    state.stack.dup_unsafe(n);
    return next_instruction(instr);
}

/// SWAP - swap stack items.
fn op_swap(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const n = instr.opcode - @intFromEnum(opcode.Enum.SWAP1) + 1;
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
fn op_jump(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
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

/// JUMP - static unconditional jump (pre-resolved).
fn op_jump_static(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    // Pop the destination from stack (for compatibility)
    _ = state.stack.pop_unsafe();
    
    // Use pre-resolved instruction index
    const target_idx = instr.arg.jump.target_instr;
    
    // Get base of instruction array
    const base_ptr = @intFromPtr(instr) - @intFromPtr(instr);
    _ = base_ptr;
    
    // For now, set PC and re-enter (will optimize later)
    const dest_pc = state.frame.contract.code[instr.pc];
    state.frame.pc = dest_pc;
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

/// JUMPI - static conditional jump (pre-resolved).
fn op_jumpi_static(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const dest = state.stack.pop_unsafe();
    const condition = state.stack.pop_unsafe();
    
    if (condition != 0) {
        // Use pre-resolved instruction index
        const target_idx = instr.arg.jump.target_instr;
        _ = target_idx;
        
        // For now, set PC and re-enter (will optimize later)
        state.frame.pc = @intCast(dest);
        return null;
    }
    
    return next_instruction(instr); // Continue to next instruction
}

/// JUMPDEST - mark valid jump destination (no-op).
fn op_jumpdest(instr: *const Instruction, _: *AdvancedExecutionState) ?*const Instruction {
    return next_instruction(instr);
}

/// RETURN - return from execution.
fn op_return(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    _ = instr;
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
fn op_revert(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    _ = instr;
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
    const addr = primitives.U256.from_le_bytes(state.frame.contract.target_address.data ++ [_]u8{0} ** 12);
    state.stack.append_unsafe(addr);
    return next_instruction(instr);
}

/// CALLER - get caller address.
fn op_caller(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const caller = primitives.U256.from_le_bytes(state.frame.msg_sender.data ++ [_]u8{0} ** 12);
    state.stack.append_unsafe(caller);
    return next_instruction(instr);
}

/// CALLVALUE - get call value.
fn op_callvalue(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack.append_unsafe(state.frame.value);
    return next_instruction(instr);
}

/// CALLDATASIZE - get size of call data.
fn op_calldatasize(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack.append_unsafe(@as(u256, state.frame.calldata.len));
    return next_instruction(instr);
}

/// CALLDATALOAD - load call data.
fn op_calldataload(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const offset = state.stack.pop_unsafe();
    
    var data: [32]u8 = [_]u8{0} ** 32;
    if (offset < state.frame.calldata.len) {
        const remaining = state.frame.calldata.len - @as(usize, @intCast(offset));
        const copy_len = @min(32, remaining);
        @memcpy(data[0..copy_len], state.frame.calldata[@intCast(offset)..][0..copy_len]);
    }
    
    state.stack.append_unsafe(primitives.U256.from_be_bytes(data));
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
        const memory_cost = state.memory.expansion_cost(dest + len) catch {
            state.exit_status = ExecutionError.Error.OutOfGas;
            return null;
        };
        
        state.gas_left.* -= @as(i64, @intCast(memory_cost));
        if (state.gas_left.* < 0) {
            state.exit_status = ExecutionError.Error.OutOfGas;
            return null;
        }
        
        // Copy data
        state.memory.set_data(dest, src, len, state.frame.calldata) catch {
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
    const coinbase = primitives.U256.from_le_bytes(state.vm.env.block.coinbase.data ++ [_]u8{0} ** 12);
    state.stack.append_unsafe(coinbase);
    return next_instruction(instr);
}

/// TIMESTAMP - get block timestamp.
fn op_timestamp(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack.append_unsafe(@as(u256, state.vm.env.block.timestamp));
    return next_instruction(instr);
}

/// NUMBER - get block number.
fn op_number(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack.append_unsafe(@as(u256, state.vm.env.block.number));
    return next_instruction(instr);
}

/// GASLIMIT - get block gas limit.
fn op_gaslimit(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack.append_unsafe(@as(u256, state.vm.env.block.gas_limit));
    return next_instruction(instr);
}

/// GASPRICE - get gas price.
fn op_gasprice(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack.append_unsafe(state.vm.env.tx.gas_price);
    return next_instruction(instr);
}

/// MSTORE8 - store byte to memory.
fn op_mstore8(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const offset = state.stack.pop_unsafe();
    const value = state.stack.pop_unsafe();
    
    state.memory.set_byte(@intCast(offset), @truncate(value)) catch {
        state.exit_status = ExecutionError.Error.OutOfMemory;
        return null;
    };
    
    return next_instruction(instr);
}

/// MSIZE - get memory size.
fn op_msize(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const size = state.memory.len();
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
    state.stack.append_unsafe(@as(u256, instr.pc));
    return next_instruction(instr);
}

/// Generic handler for unimplemented opcodes.
fn op_generic(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    // Fall back to regular execution
    const interpreter: Operation.Interpreter = state.vm;
    const frame_state: Operation.State = state.frame;
    
    // Temporarily convert gas back to unsigned
    state.frame.gas_remaining = @intCast(state.gas_left.*);
    
    const result = state.vm.table.execute(state.frame.pc, interpreter, frame_state, instr.opcode) catch |err| {
        state.exit_status = err;
        return null;
    };
    
    // Update gas
    state.gas_left.* = @intCast(state.frame.gas_remaining);
    
    // Check if PC changed (control flow)
    const old_pc = instr.pc;
    if (state.frame.pc != old_pc) {
        return null; // Re-enter at new PC
    }
    
    return next_instruction(instr);
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
    try testing.expectEqual(@as(u8, @intFromEnum(opcode.Enum.JUMPDEST)), stream.instructions[0].opcode);
    try testing.expectEqual(@as(u32, 9), stream.instructions[0].arg.block.gas_cost);
    
    // Then PUSH1 0x02
    try testing.expectEqual(@as(u8, 0x60), stream.instructions[1].opcode);
    try testing.expectEqual(@as(u256, 2), stream.instructions[1].arg.push.value);
    
    // Then PUSH1 0x03
    try testing.expectEqual(@as(u8, 0x60), stream.instructions[2].opcode);
    try testing.expectEqual(@as(u256, 3), stream.instructions[2].arg.push.value);
    
    // Then ADD
    try testing.expectEqual(@as(u8, 0x01), stream.instructions[3].opcode);
    
    // Finally STOP
    try testing.expectEqual(@as(u8, 0x00), stream.instructions[4].opcode);
}