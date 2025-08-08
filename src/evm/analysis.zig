const std = @import("std");
const limits = @import("constants/code_analysis_limits.zig");
const StaticBitSet = std.bit_set.StaticBitSet;
const DynamicBitSet = std.DynamicBitSet;
const Instruction = @import("instruction.zig").Instruction;
const BlockInfo = @import("instruction.zig").BlockInfo;
const JumpType = @import("instruction.zig").JumpType;
const JumpTarget = @import("instruction.zig").JumpTarget;
const DynamicGas = @import("instruction.zig").DynamicGas;
const DynamicGasFunc = @import("instruction.zig").DynamicGasFunc;
const Opcode = @import("opcodes/opcode.zig");
const JumpTable = @import("jump_table/jump_table.zig");
const instruction_limits = @import("constants/instruction_limits.zig");
const ExecutionError = @import("execution/execution_error.zig");
const execution = @import("execution/package.zig");
const Frame = @import("frame.zig").Frame;
const Log = @import("log.zig");
const stack_height_changes = @import("opcodes/stack_height_changes.zig");
const dynamic_gas = @import("gas/dynamic_gas.zig");

/// Optimized code analysis for EVM bytecode execution.
/// Contains only the essential data needed during execution.
const CodeAnalysis = @This();

/// Heap-allocated instruction stream for execution.
/// Must be freed by caller using deinit().
instructions: []Instruction,

/// Heap-allocated bitmap marking all valid JUMPDEST positions in the bytecode.
/// Required for JUMP/JUMPI validation during execution.
jumpdest_bitmap: DynamicBitSet,

/// Allocator used for the instruction array (needed for cleanup)
allocator: std.mem.Allocator,

/// Handler for opcodes that should never be executed directly.
/// Used for JUMP, JUMPI, and PUSH opcodes that are handled inline by the interpreter.
/// This function should never be called - if it is, there's a bug in the analysis or interpreter.
pub fn UnreachableHandler(frame: *anyopaque) ExecutionError.Error!void {
    _ = frame;
    Log.err("UnreachableHandler called - this indicates a bug where an opcode marked for inline handling was executed through the jump table", .{});
    unreachable;
}

/// Handler for BEGINBLOCK instructions that validates an entire basic block upfront.
/// This performs gas and stack validation for all instructions in the block in one operation,
/// eliminating the need for per-instruction validation during execution.
/// 
/// The block information (gas cost, stack requirements) is stored in the instruction's arg.block_info.
/// This handler must be called before executing any instructions in the basic block.
pub fn BeginBlockHandler(frame: *anyopaque) ExecutionError.Error!void {
    const actual_frame = @as(*Frame, @ptrCast(@alignCast(frame)));
    // TODO: BeginBlockHandler needs to be redesigned since Frame doesn't have current_instruction
    // For now, just consume a small amount of gas as a placeholder
    // const current_instruction = @as(*const Instruction, @ptrCast(actual_frame.current_instruction));
    // const block = current_instruction.arg.block_info;
    const placeholder_gas = 1; // Placeholder gas cost
    
    // Single gas check for entire block - eliminates per-opcode gas validation
    if (actual_frame.gas_remaining < placeholder_gas) {
        return ExecutionError.Error.OutOfGas;
    }
    actual_frame.gas_remaining -= placeholder_gas;
    
    // TODO: Stack validation also needs the block info
    // Single stack validation for entire block - eliminates per-opcode stack checks
    // const stack_size = @as(u16, @intCast(actual_frame.stack.len()));
    // if (stack_size < block.stack_req) {
    //     return ExecutionError.Error.StackUnderflow;
    // }
    // if (stack_size + block.stack_max_growth > 1024) {
    //     return ExecutionError.Error.StackOverflow;
    // }
    
    // Log.debug("BeginBlock: gas_cost={}, stack_req={}, stack_max_growth={}, current_stack={}", .{
    //     block.gas_cost, block.stack_req, block.stack_max_growth, stack_size
    // });
    Log.debug("BeginBlock: placeholder implementation consuming {} gas", .{placeholder_gas});
}

/// Block analysis structure used during instruction stream generation.
/// Tracks the accumulated requirements for a basic block during analysis.
const BlockAnalysis = struct {
    /// Total static gas cost accumulated for all instructions in the block
    gas_cost: u32 = 0,
    /// Stack height requirement relative to block start
    stack_req: i16 = 0,
    /// Maximum stack growth during block execution
    stack_max_growth: i16 = 0,
    /// Current stack change from block start
    stack_change: i16 = 0,
    /// Index of the BEGINBLOCK instruction that starts this block
    begin_block_index: usize,
    
    /// Initialize a new block analysis at the given instruction index
    fn init(begin_index: usize) BlockAnalysis {
        return BlockAnalysis{
            .begin_block_index = begin_index,
        };
    }
    
    /// Close the current block by producing compressed information about the block
    fn close(self: *const BlockAnalysis) BlockInfo {
        return BlockInfo{
            .gas_cost = self.gas_cost,
            .stack_req = @intCast(@max(0, self.stack_req)),
            .stack_max_growth = @intCast(@max(0, self.stack_max_growth)),
        };
    }
    
    /// Update stack tracking for an operation
    fn updateStackTracking(self: *BlockAnalysis, opcode: u8, min_stack: u32) void {
        // Get the precise net stack change from the lookup table
        const net_change = stack_height_changes.get_stack_height_change(opcode);
        
        // min_stack tells us how many items the operation pops
        const stack_inputs = @as(i16, @intCast(min_stack));
        
        // Calculate requirement relative to block start
        const current_stack_req = stack_inputs - self.stack_change;
        self.stack_req = @max(self.stack_req, current_stack_req);
        
        // Update stack change using the precise net change
        self.stack_change += net_change;
        self.stack_max_growth = @max(self.stack_max_growth, self.stack_change);
    }
};

/// Main public API: Analyzes bytecode and returns optimized CodeAnalysis with instruction stream.
/// The caller must call deinit() to free the instruction array.
/// TODO: Add chain_rules parameter to validate EIP-specific opcodes during analysis:
/// - EIP-3855 (PUSH0): Reject PUSH0 in pre-Shanghai contracts
/// - EIP-5656 (MCOPY): Reject MCOPY in pre-Cancun contracts
/// - EIP-3198 (BASEFEE): Reject BASEFEE in pre-London contracts
pub fn from_code(allocator: std.mem.Allocator, code: []const u8, jump_table: *const JumpTable) !CodeAnalysis {
    if (code.len > limits.MAX_CONTRACT_SIZE) {
        return error.CodeTooLarge;
    }

    // Create temporary analysis data that will be discarded
    var code_segments = try createCodeBitmap(allocator, code);
    defer code_segments.deinit();
    var jumpdest_bitmap = try DynamicBitSet.initEmpty(allocator, code.len);
    errdefer jumpdest_bitmap.deinit();

    if (code.len == 0) {
        // For empty code, just create empty instruction array
        const empty_instructions = try allocator.alloc(Instruction, 0);
        return CodeAnalysis{
            .instructions = empty_instructions,
            .jumpdest_bitmap = jumpdest_bitmap,
            .allocator = allocator,
        };
    }

    // First pass: identify JUMPDESTs and contract properties
    var i: usize = 0;
    var loop_iterations: u32 = 0;
    const max_iterations = limits.MAX_CONTRACT_SIZE * 2; // Safety check
    while (i < code.len) {
        // Safety check to prevent infinite loops
        loop_iterations += 1;
        if (loop_iterations > max_iterations) {
            return error.InstructionLimitExceeded;
        }

        const op = code[i];

        // Mark JUMPDEST positions
        if (op == @intFromEnum(Opcode.Enum.JUMPDEST) and code_segments.isSet(i)) {
            jumpdest_bitmap.set(i);
        }

        // Handle opcodes that affect contract properties - skip invalid opcodes
        const maybe_opcode = std.meta.intToEnum(Opcode.Enum, op) catch {
            // Invalid opcode, skip it but MUST increment i to avoid infinite loop
            i += 1;
            continue;
        };
        switch (maybe_opcode) {
            .JUMP, .JUMPI => {},
            .SELFDESTRUCT => {},
            .CREATE, .CREATE2 => {},
            else => {},
        }

        // Advance PC
        if (Opcode.is_push(op)) {
            const push_bytes = Opcode.get_push_size(op);
            i += 1 + push_bytes;
        } else {
            i += 1;
        }
    }

    // Simple stack depth analysis
    var stack_depth: i16 = 0;
    i = 0;
    loop_iterations = 0;
    while (i < code.len) {
        loop_iterations += 1;
        if (loop_iterations > max_iterations) {
            return error.InstructionLimitExceeded;
        }

        const op = code[i];

        // Skip non-code bytes (PUSH data)
        if (!code_segments.isSet(i)) {
            i += 1;
            continue;
        }

        // Get precise stack height change from lookup table
        const net_change = stack_height_changes.get_stack_height_change(op);
        
        // Update stack depth
        stack_depth = stack_depth + net_change;

        // Track max stack depth (for potential future use)
        _ = @as(u16, @intCast(@max(0, stack_depth)));

        // Advance PC
        if (Opcode.is_push(op)) {
            const push_bytes = Opcode.get_push_size(op);
            i += 1 + push_bytes;
        } else {
            i += 1;
        }
    }

    // Convert to instruction stream using temporary data
    const instructions = try codeToInstructions(allocator, code, jump_table, &jumpdest_bitmap);

    return CodeAnalysis{
        .instructions = instructions,
        .jumpdest_bitmap = jumpdest_bitmap,
        .allocator = allocator,
    };
}

/// Clean up allocated instruction array and bitmap.
/// Must be called by the caller to prevent memory leaks.
pub fn deinit(self: *CodeAnalysis) void {
    // Free the instruction array (now a slice)
    self.allocator.free(self.instructions);

    // Free the bitmap
    self.jumpdest_bitmap.deinit();
}

/// Get the dynamic gas function for a specific opcode
fn getDynamicGasFunction(opcode: Opcode.Enum) ?DynamicGasFunc {
    return switch (opcode) {
        .CALL => dynamic_gas.call_dynamic_gas,
        .CALLCODE => dynamic_gas.callcode_dynamic_gas,
        .DELEGATECALL => dynamic_gas.delegatecall_dynamic_gas,
        .STATICCALL => dynamic_gas.staticcall_dynamic_gas,
        .CREATE => dynamic_gas.create_dynamic_gas,
        .CREATE2 => dynamic_gas.create2_dynamic_gas,
        .SSTORE => dynamic_gas.sstore_dynamic_gas,
        .GAS => dynamic_gas.gas_dynamic_gas,
        else => null,
    };
}

/// Creates a code bitmap that marks which bytes are opcodes vs data.
fn createCodeBitmap(allocator: std.mem.Allocator, code: []const u8) !DynamicBitSet {
    std.debug.assert(code.len <= limits.MAX_CONTRACT_SIZE);

    var bitmap = try DynamicBitSet.initFull(allocator, code.len);
    errdefer bitmap.deinit();

    var i: usize = 0;
    while (i < code.len) {
        const op = code[i];

        // If the opcode is a PUSH, mark pushed bytes as data (not code)
        if (Opcode.is_push(op)) {
            const push_bytes = Opcode.get_push_size(op);
            var j: usize = 1;
            while (j <= push_bytes and i + j < code.len) : (j += 1) {
                bitmap.unset(i + j);
            }
            i += 1 + push_bytes;
        } else {
            i += 1;
        }
    }

    return bitmap;
}

/// Convert bytecode to null-terminated instruction stream with block-based optimization.
/// This implementation follows evmone's advanced analysis approach by:
/// 1. Injecting BEGINBLOCK instructions at basic block boundaries
/// 2. Pre-calculating gas and stack requirements for entire blocks
/// 3. Eliminating per-instruction validation during execution
fn codeToInstructions(allocator: std.mem.Allocator, code: []const u8, jump_table: *const JumpTable, jumpdest_bitmap: *const DynamicBitSet) ![]Instruction {
    // Allocate instruction array with extra space for BEGINBLOCK instructions
    const instructions = try allocator.alloc(Instruction, instruction_limits.MAX_INSTRUCTIONS + 1);
    errdefer allocator.free(instructions);

    var pc: usize = 0;
    var instruction_count: usize = 0;

    // Start first block with BEGINBLOCK instruction
    instructions[instruction_count] = Instruction{
        .opcode_fn = BeginBlockHandler,
        .arg = .{ .block_info = BlockInfo{} }, // Will be filled when block closes
    };
    var block = BlockAnalysis.init(instruction_count);
    instruction_count += 1;

    while (pc < code.len) {
        if (instruction_count >= instruction_limits.MAX_INSTRUCTIONS) {
            return error.InstructionLimitExceeded;
        }

        const opcode_byte = code[pc];
        const opcode = std.meta.intToEnum(Opcode.Enum, opcode_byte) catch {
            // Invalid opcode - accumulate in block and create instruction
            const operation = jump_table.get_operation(opcode_byte);
            block.gas_cost += @intCast(operation.constant_gas);
            block.updateStackTracking(opcode_byte, operation.min_stack);
            
            instructions[instruction_count] = Instruction{
                .opcode_fn = operation.execute,
                .arg = .none, // No individual gas cost - handled by BEGINBLOCK
            };
            instruction_count += 1;
            pc += 1;
            continue;
        };

        // Handle basic block boundaries and special opcodes
        switch (opcode) {
            .JUMPDEST => {
                // Close current block and start new one
                instructions[block.begin_block_index].arg.block_info = block.close();
                
                // Start new block with BEGINBLOCK
                instructions[instruction_count] = Instruction{
                    .opcode_fn = BeginBlockHandler,
                    .arg = .{ .block_info = BlockInfo{} },
                };
                block = BlockAnalysis.init(instruction_count);
                instruction_count += 1;
                
                // Add the JUMPDEST instruction to the new block
                const operation = jump_table.get_operation(opcode_byte);
                block.gas_cost += @intCast(operation.constant_gas);
                block.updateStackTracking(opcode_byte, operation.min_stack);
                
                instructions[instruction_count] = Instruction{
                    .opcode_fn = operation.execute,
                    .arg = .none,
                };
                instruction_count += 1;
                pc += 1;
            },
            
            // Terminating instructions - end current block
            .JUMP, .STOP, .RETURN, .REVERT, .SELFDESTRUCT => {
                const operation = jump_table.get_operation(opcode_byte);
                block.gas_cost += @intCast(operation.constant_gas);
                block.updateStackTracking(opcode_byte, operation.min_stack);
                
                if (opcode == .JUMP) {
                    instructions[instruction_count] = Instruction{
                        .opcode_fn = UnreachableHandler, // Handled inline by interpreter
                        .arg = .none, // Will be filled with .jump_target during resolveJumpTargets
                    };
                } else {
                    instructions[instruction_count] = Instruction{
                        .opcode_fn = operation.execute,
                        .arg = .none,
                    };
                }
                instruction_count += 1;
                pc += 1;
                
                // Close current block
                instructions[block.begin_block_index].arg.block_info = block.close();
                
                // Skip dead code until next JUMPDEST
                while (pc < code.len and code[pc] != @intFromEnum(Opcode.Enum.JUMPDEST)) {
                    if (Opcode.is_push(code[pc])) {
                        const push_bytes = Opcode.get_push_size(code[pc]);
                        pc += 1 + push_bytes;
                    } else {
                        pc += 1;
                    }
                }
            },
            
            .JUMPI => {
                const operation = jump_table.get_operation(opcode_byte);
                block.gas_cost += @intCast(operation.constant_gas);
                block.updateStackTracking(opcode_byte, operation.min_stack);
                
                instructions[instruction_count] = Instruction{
                    .opcode_fn = UnreachableHandler, // Handled inline by interpreter
                    .arg = .none, // Will be filled with .jump_target during resolveJumpTargets
                };
                instruction_count += 1;
                pc += 1;
                
                // Close current block and start new one (for fall-through path)
                instructions[block.begin_block_index].arg.block_info = block.close();
                instructions[instruction_count] = Instruction{
                    .opcode_fn = BeginBlockHandler,
                    .arg = .{ .block_info = BlockInfo{} },
                };
                block = BlockAnalysis.init(instruction_count);
                instruction_count += 1;
            },
            
            // PUSH operations - handled inline by interpreter
            .PUSH0 => {
                const operation = jump_table.get_operation(opcode_byte);
                block.gas_cost += @intCast(operation.constant_gas);
                block.updateStackTracking(opcode_byte, operation.min_stack);
                
                instructions[instruction_count] = Instruction{
                    .opcode_fn = UnreachableHandler,
                    .arg = .{ .push_value = 0 },
                };
                instruction_count += 1;
                pc += 1;
            },
            
            .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8, .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => {
                const operation = jump_table.get_operation(opcode_byte);
                block.gas_cost += @intCast(operation.constant_gas);
                block.updateStackTracking(opcode_byte, operation.min_stack);
                
                const push_size = Opcode.get_push_size(opcode_byte);
                var value: u256 = 0;
                
                // Read push value with bounds checking
                if (pc + 1 + push_size <= code.len) {
                    var i: usize = 0;
                    while (i < push_size) : (i += 1) {
                        value = (value << 8) | code[pc + 1 + i];
                    }
                    pc += 1 + push_size;
                } else {
                    // Handle truncated PUSH at end of code
                    const available = code.len - (pc + 1);
                    if (available > 0) {
                        const bytes_to_read = @min(push_size, available);
                        var i: usize = 0;
                        while (i < bytes_to_read) : (i += 1) {
                            value = (value << 8) | code[pc + 1 + i];
                        }
                        const missing_bytes = push_size - bytes_to_read;
                        if (missing_bytes > 0) {
                            value = value << (8 * missing_bytes);
                        }
                    }
                    pc = code.len; // End of code
                }
                
                instructions[instruction_count] = Instruction{
                    .opcode_fn = UnreachableHandler,
                    .arg = .{ .push_value = value },
                };
                instruction_count += 1;
            },
            
            // Special opcodes that need individual gas tracking for dynamic calculations
            .GAS, .CALL, .CALLCODE, .DELEGATECALL, .STATICCALL, .CREATE, .CREATE2, .SSTORE => {
                const operation = jump_table.get_operation(opcode_byte);
                // Don't accumulate static gas in block - it will be handled individually
                block.updateStackTracking(opcode_byte, operation.min_stack);
                
                instructions[instruction_count] = Instruction{
                    .opcode_fn = operation.execute,
                    .arg = .{ 
                        .dynamic_gas = DynamicGas{
                            .static_cost = @intCast(operation.constant_gas),
                            .gas_fn = getDynamicGasFunction(opcode),
                        },
                    },
                };
                instruction_count += 1;
                pc += 1;
            },
            
            // Regular opcodes - accumulate in block
            else => {
                const operation = jump_table.get_operation(opcode_byte);
                
                if (operation.undefined) {
                    // Treat undefined opcodes as INVALID
                    const invalid_operation = jump_table.get_operation(@intFromEnum(Opcode.Enum.INVALID));
                    block.gas_cost += @intCast(invalid_operation.constant_gas);
                    block.updateStackTracking(@intFromEnum(Opcode.Enum.INVALID), invalid_operation.min_stack);
                    
                    instructions[instruction_count] = Instruction{
                        .opcode_fn = invalid_operation.execute,
                        .arg = .none,
                    };
                } else {
                    block.gas_cost += @intCast(operation.constant_gas);
                    block.updateStackTracking(opcode_byte, operation.min_stack);
                    
                    instructions[instruction_count] = Instruction{
                        .opcode_fn = operation.execute,
                        .arg = .none, // No individual gas cost - handled by BEGINBLOCK
                    };
                }
                instruction_count += 1;
                pc += 1;
            },
        }
    }

    // Close final block
    instructions[block.begin_block_index].arg.block_info = block.close();

    // Ensure the last instruction terminates execution
    if (instruction_count < instruction_limits.MAX_INSTRUCTIONS) {
        const stop_operation = jump_table.get_operation(@intFromEnum(Opcode.Enum.STOP));
        instructions[instruction_count] = Instruction{
            .opcode_fn = stop_operation.execute,
            .arg = .none,
        };
        instruction_count += 1;
    }

    // No terminator needed for slices

    // Resolve jump targets after initial translation
    resolveJumpTargets(allocator, code, instructions[0..instruction_count], jumpdest_bitmap) catch {
        // If we can't resolve jumps, it's still OK - runtime will handle it
    };

    // Resize array to actual size (no null terminator needed for slices)
    const final_instructions = try allocator.realloc(instructions, instruction_count);
    return final_instructions;
}

/// Resolve jump targets in the instruction stream.
/// This creates direct pointers from JUMP/JUMPI instructions to their target instructions.
fn resolveJumpTargets(allocator: std.mem.Allocator, code: []const u8, instructions: []Instruction, jumpdest_bitmap: *const DynamicBitSet) !void {
    // Build a map from PC to instruction index using dynamic allocation
    // Initialize with sentinel value (MAX_INSTRUCTIONS means "not mapped")
    var pc_to_instruction = try allocator.alloc(u16, code.len);
    defer allocator.free(pc_to_instruction);
    @memset(pc_to_instruction, std.math.maxInt(u16));

    var pc: usize = 0;
    var inst_idx: usize = 0;

    // First pass: map PC to instruction indices
    while (inst_idx < instructions.len) : (inst_idx += 1) {
        if (pc < pc_to_instruction.len) {
            pc_to_instruction[pc] = @intCast(inst_idx);
        }

        // Calculate PC advancement based on the original bytecode
        if (pc >= code.len) break;

        const opcode_byte = code[pc];
        if (opcode_byte >= 0x60 and opcode_byte <= 0x7F) {
            // PUSH instruction
            const push_size = opcode_byte - 0x5F;
            pc += 1 + push_size;
        } else {
            pc += 1;
        }
    }

    // Second pass: update JUMP and JUMPI instructions
    pc = 0;
    inst_idx = 0;

    while (inst_idx < instructions.len) : (inst_idx += 1) {
        if (pc >= code.len) break;

        const opcode_byte = code[pc];

        if (opcode_byte == 0x56 or opcode_byte == 0x57) { // JUMP or JUMPI
            // Look for the target address in the previous PUSH instruction
            if (inst_idx > 0 and instructions[inst_idx - 1].arg == .push_value) {
                const target_pc = instructions[inst_idx - 1].arg.push_value;

                // Check if it's within bounds and is a valid jumpdest
                if (target_pc < code.len and jumpdest_bitmap.isSet(@intCast(target_pc))) {
                    // Find the instruction index for this PC
                    if (target_pc < pc_to_instruction.len) {
                        const target_idx = pc_to_instruction[@intCast(target_pc)];
                        if (target_idx != std.math.maxInt(u16) and target_idx < instructions.len) {
                            // Determine jump type based on opcode
                            const jump_type: JumpType = if (opcode_byte == 0x56) .jump else .jumpi;
                            
                            // Update the JUMP/JUMPI with the target pointer and type
                            instructions[inst_idx].arg = .{ .jump_target = JumpTarget{
                                .instruction = &instructions[target_idx],
                                .jump_type = jump_type,
                            }};
                        }
                    }
                }
            }
        }

        // Calculate PC advancement
        if (opcode_byte >= 0x60 and opcode_byte <= 0x7F) {
            const push_size = opcode_byte - 0x5F;
            pc += 1 + push_size;
        } else {
            pc += 1;
        }
    }
}

test "from_code basic functionality" {
    const allocator = std.testing.allocator;

    // Simple bytecode: PUSH1 0x01, STOP
    const code = &[_]u8{ 0x60, 0x01, 0x00 };

    const table = JumpTable.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    // Verify we got instructions
    try std.testing.expect(analysis.instructions[0] != null);
    try std.testing.expect(analysis.instructions[1] != null);
    try std.testing.expect(analysis.instructions[2] == null); // null terminator

}

test "from_code with jumpdest" {
    const allocator = std.testing.allocator;

    // Bytecode: JUMPDEST, PUSH1 0x01, STOP
    const code = &[_]u8{ 0x5B, 0x60, 0x01, 0x00 };

    const table = JumpTable.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, code, &table);
    defer analysis.deinit();

    // Verify jumpdest is marked
    try std.testing.expect(analysis.jumpdest_bitmap.isSet(0));
    try std.testing.expect(!analysis.jumpdest_bitmap.isSet(1));
}
