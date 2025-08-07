const std = @import("std");
const limits = @import("constants/code_analysis_limits.zig");
const StaticBitSet = std.bit_set.StaticBitSet;
const DynamicBitSet = std.DynamicBitSet;
const Instruction = @import("instruction.zig").Instruction;
const Opcode = @import("opcodes/opcode.zig");
const JumpTable = @import("jump_table/jump_table.zig");
const instruction_limits = @import("constants/instruction_limits.zig");

/// Optimized code analysis for EVM bytecode execution.
/// Contains only the essential data needed during execution.
const CodeAnalysis = @This();

/// Heap-allocated null-terminated instruction stream for execution.
/// Must be freed by caller using deinit().
instructions: [*]?Instruction,

/// Heap-allocated bitmap marking all valid JUMPDEST positions in the bytecode.
/// Required for JUMP/JUMPI validation during execution.
jumpdest_bitmap: DynamicBitSet,

/// Allocator used for the instruction array (needed for cleanup)
allocator: std.mem.Allocator,

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
        const empty_instructions = try allocator.alloc(?Instruction, 1);
        empty_instructions[0] = null;
        return CodeAnalysis{
            .instructions = @ptrCast(empty_instructions.ptr),
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

        // Get operation for stack tracking
        const operation_ptr = jump_table.get_operation(op);
        const stack_inputs = @as(i16, @intCast(operation_ptr.min_stack));
        const stack_outputs: i16 = if (operation_ptr.max_stack > operation_ptr.min_stack) 1 else 0;

        // Update stack depth
        stack_depth = stack_depth - stack_inputs + stack_outputs;

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
    // Find the length by looking for null terminator
    var len: usize = 0;
    while (self.instructions[len] != null) : (len += 1) {}
    len += 1; // Include null terminator

    // Free the instruction array
    const instructions_slice = @as([*]?Instruction, @ptrCast(self.instructions))[0..len];
    self.allocator.free(instructions_slice);

    // Free the bitmap
    self.jumpdest_bitmap.deinit();
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

/// Convert bytecode to null-terminated instruction stream.
fn codeToInstructions(allocator: std.mem.Allocator, code: []const u8, jump_table: *const JumpTable, jumpdest_bitmap: *const DynamicBitSet) ![*:null]Instruction {
    // Allocate instruction array with space for null terminator
    const instructions = try allocator.alloc(?Instruction, instruction_limits.MAX_INSTRUCTIONS + 1);
    errdefer allocator.free(instructions);

    var pc: usize = 0;
    var instruction_count: usize = 0;

    while (pc < code.len) {
        if (instruction_count >= instruction_limits.MAX_INSTRUCTIONS) {
            return error.InstructionLimitExceeded;
        }

        const opcode_byte = code[pc];

        const opcode = std.meta.intToEnum(Opcode.Enum, opcode_byte) catch {
            // Invalid opcode - add it as a regular instruction
            instructions[instruction_count] = Instruction{
                .opcode_fn = jump_table.execute_funcs[opcode_byte],
                .arg = .{ .gas_cost = @intCast(jump_table.constant_gas[opcode_byte]) },
            };
            instruction_count += 1;
            pc += 1;
            continue;
        };

        switch (opcode) {
            .STOP => {
                instructions[instruction_count] = Instruction{
                    .opcode_fn = jump_table.execute_funcs[opcode_byte],
                    .arg = .{ .gas_cost = @intCast(jump_table.constant_gas[opcode_byte]) },
                };
                instruction_count += 1;
                pc += 1;
            },
            .PUSH0 => {
                // TODO: Add EIP-3855 (Shanghai) validation during bytecode analysis
                // if (!chain_rules.is_eip3855) {
                //     // Treat PUSH0 as INVALID opcode if EIP-3855 not enabled
                //     instructions[instruction_count] = Instruction{
                //         .opcode_fn = jump_table.execute_funcs[@intFromEnum(Opcode.Enum.INVALID)],
                //         .arg = .none,
                //     };
                // } else {
                instructions[instruction_count] = Instruction{
                    .opcode_fn = jump_table.execute_funcs[opcode_byte],
                    .arg = .{ .push_value = 0 },
                };
                // }
                instruction_count += 1;
                pc += 1;
            },
            .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8, .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => {
                // Calculate how many bytes to read
                const push_size = Opcode.get_push_size(opcode_byte);

                // Make sure we have enough bytes
                if (pc + 1 + push_size > code.len) {
                    // If not enough bytes, pad with zeros (EVM behavior)
                    var value: u256 = 0;
                    const available = code.len - (pc + 1);
                    if (available > 0) {
                        // Read what we can
                        const bytes_to_read = @min(push_size, available);
                        var i: usize = 0;
                        while (i < bytes_to_read) : (i += 1) {
                            value = (value << 8) | code[pc + 1 + i];
                        }
                        // Shift left for any missing bytes
                        const missing_bytes = push_size - bytes_to_read;
                        if (missing_bytes > 0) {
                            value = value << (8 * missing_bytes);
                        }
                    }
                    instructions[instruction_count] = Instruction{
                        .opcode_fn = jump_table.execute_funcs[opcode_byte],
                        .arg = .{ .push_value = value },
                    };
                    instruction_count += 1;
                    pc = code.len; // End of code
                } else {
                    // Read the push value from bytecode
                    var value: u256 = 0;
                    var i: usize = 0;
                    while (i < push_size) : (i += 1) {
                        value = (value << 8) | code[pc + 1 + i];
                    }

                    const opcode_fn = jump_table.execute_funcs[opcode_byte];
                    instructions[instruction_count] = Instruction{
                        .opcode_fn = opcode_fn,
                        .arg = .{ .push_value = value },
                    };
                    instruction_count += 1;
                    pc += 1 + push_size;
                }
            },
            // All other opcodes - no special args
            else => {
                // Check if it's an undefined opcode
                if (jump_table.undefined_flags[opcode_byte]) {
                    // Treat undefined opcodes as INVALID
                    const invalid_opcode = @intFromEnum(Opcode.Enum.INVALID);
                    instructions[instruction_count] = Instruction{
                        .opcode_fn = jump_table.execute_funcs[invalid_opcode],
                        .arg = .{ .gas_cost = @intCast(jump_table.constant_gas[invalid_opcode]) },
                    };
                    instruction_count += 1;
                    pc += 1;
                } else {
                    // TODO: Add EIP validation for specific opcodes during bytecode analysis:
                    // Check opcode_byte and validate against chain rules:
                    // if (opcode_byte == @intFromEnum(Opcode.Enum.BASEFEE) and !chain_rules.is_eip3198) {
                    //     // Treat BASEFEE as INVALID if EIP-3198 not enabled
                    //     const invalid_opcode = @intFromEnum(Opcode.Enum.INVALID);
                    //     instructions[instruction_count] = Instruction{
                    //         .opcode_fn = jump_table.execute_funcs[invalid_opcode],
                    //         .arg = .{ .gas_cost = @intCast(jump_table.constant_gas[invalid_opcode]) },
                    //     };
                    // } else if (opcode_byte == @intFromEnum(Opcode.Enum.MCOPY) and !chain_rules.is_eip5656) {
                    //     // Treat MCOPY as INVALID if EIP-5656 not enabled
                    //     const invalid_opcode = @intFromEnum(Opcode.Enum.INVALID);
                    //     instructions[instruction_count] = Instruction{
                    //         .opcode_fn = jump_table.execute_funcs[invalid_opcode],
                    //         .arg = .{ .gas_cost = @intCast(jump_table.constant_gas[invalid_opcode]) },
                    //     };
                    // } else {
                    const opcode_fn = jump_table.execute_funcs[opcode_byte];
                    instructions[instruction_count] = Instruction{
                        .opcode_fn = opcode_fn,
                        .arg = .{ .gas_cost = @intCast(jump_table.constant_gas[opcode_byte]) },
                    };
                    // }
                    instruction_count += 1;
                    pc += 1;
                }
            },
        }
    }

    // Null-terminate the instruction stream
    instructions[instruction_count] = null;

    // Convert to slice of non-nullable instructions for jump target resolution
    var non_null_instructions = try allocator.alloc(Instruction, instruction_count);
    errdefer allocator.free(non_null_instructions);

    for (0..instruction_count) |i| {
        non_null_instructions[i] = instructions[i].?; // Safe because we know they're not null
    }

    // Resolve jump targets after initial translation
    resolveJumpTargets(code, non_null_instructions, jumpdest_bitmap) catch {
        // If we can't resolve jumps, it's still OK - runtime will handle it
    };

    // Copy back the resolved instructions
    for (0..instruction_count) |i| {
        instructions[i] = non_null_instructions[i];
    }

    allocator.free(non_null_instructions);

    // Resize array to actual size + null terminator
    const final_instructions = try allocator.realloc(instructions, instruction_count + 1);
    return @ptrCast(final_instructions.ptr);
}

/// Resolve jump targets in the instruction stream.
/// This creates direct pointers from JUMP/JUMPI instructions to their target instructions.
fn resolveJumpTargets(code: []const u8, instructions: []Instruction, jumpdest_bitmap: *const DynamicBitSet) !void {
    // Build a map from PC to instruction index using fixed array
    // Initialize with sentinel value (MAX_INSTRUCTIONS means "not mapped")
    var pc_to_instruction: [limits.MAX_CONTRACT_SIZE]u16 = undefined;
    @memset(&pc_to_instruction, std.math.maxInt(u16));

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
                        if (target_idx != std.math.maxInt(u16)) {
                            // Update the JUMP/JUMPI with the target pointer
                            instructions[inst_idx].arg = .{ .jump_target = &instructions[target_idx] };
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
