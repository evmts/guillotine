const std = @import("std");
const evm = @import("evm");

test "resolve jump targets in instruction stream" {
    const allocator = std.testing.allocator;

    // Create bytecode with a simple jump:
    // PUSH1 0x08, JUMP, INVALID, INVALID, INVALID, JUMPDEST, PUSH1 0x42, STOP
    const bytecode = &[_]u8{
        0x60, 0x08, // PUSH1 0x08 (jump to position 8)
        0x56, // JUMP
        0xFE, // INVALID (should be skipped)
        0xFE, // INVALID (should be skipped)
        0xFE, // INVALID (should be skipped)
        0x5B, // JUMPDEST (at position 8)
        0x60, 0x42, // PUSH1 0x42
        0x00, // STOP
    };

    // Analyze bytecode
    var analysis = try evm.CodeAnalysis.analyze_bytecode_blocks(allocator, bytecode);
    defer analysis.deinit(allocator);

    // Create instruction buffer
    var instructions: [20]evm.Instruction = undefined;

    // Create jump table
    const jump_table = evm.JumpTable.init_from_hardfork(.CANCUN);

    // Translate bytecode to instructions
    var translator = evm.InstructionTranslator.init(
        allocator,
        bytecode,
        &analysis,
        &instructions,
        &jump_table,
    );

    const instruction_count = try translator.translate_bytecode();

    // Add null terminator
    instructions[instruction_count] = .{
        .opcode_fn = null,
        .arg = .none,
    };

    // Now resolve jump targets
    try resolve_jump_targets(&instructions, instruction_count, bytecode, &analysis);

    // Verify that the JUMP instruction has been updated with a jump target
    try std.testing.expect(instructions[1].arg == .jump_target);

    // The target should point to instruction at index 3 (JUMPDEST)
    // Instructions are: PUSH1, JUMP, PUSH1, STOP
    // So JUMPDEST maps to instruction index 2
    const target = instructions[1].arg.jump_target;
    try std.testing.expect(target == &instructions[2]);
}

test "resolve conditional jump targets" {
    const allocator = std.testing.allocator;

    // Create bytecode with conditional jump:
    // PUSH1 1, PUSH1 0x08, JUMPI, PUSH1 0, STOP, JUMPDEST, PUSH1 42, STOP
    const bytecode = &[_]u8{
        0x60, 0x01, // PUSH1 1 (condition)
        0x60, 0x08, // PUSH1 0x08 (jump destination)
        0x57, // JUMPI
        0x60, 0x00, // PUSH1 0 (not reached if jump taken)
        0x00, // STOP
        0x5B, // JUMPDEST (at position 8)
        0x60, 0x2A, // PUSH1 42
        0x00, // STOP
    };

    // Analyze bytecode
    var analysis = try evm.CodeAnalysis.analyze_bytecode_blocks(allocator, bytecode);
    defer analysis.deinit(allocator);

    // Create instruction buffer
    var instructions: [20]evm.Instruction = undefined;

    // Create jump table
    const jump_table = evm.JumpTable.init_from_hardfork(.CANCUN);

    // Translate bytecode to instructions
    var translator = evm.InstructionTranslator.init(
        allocator,
        bytecode,
        &analysis,
        &instructions,
        &jump_table,
    );

    const instruction_count = try translator.translate_bytecode();

    // Add null terminator
    instructions[instruction_count] = .{
        .opcode_fn = null,
        .arg = .none,
    };

    // Resolve jump targets
    try resolve_jump_targets(&instructions, instruction_count, bytecode, &analysis);

    // Verify that the JUMPI instruction has been updated with a jump target
    try std.testing.expect(instructions[2].arg == .jump_target);
}

test "multiple jumps to same destination" {
    const allocator = std.testing.allocator;

    // Create bytecode with multiple jumps to same JUMPDEST:
    // PUSH1 0x0C, JUMP, INVALID, PUSH1 0x0C, JUMP, INVALID, JUMPDEST, STOP
    const bytecode = &[_]u8{
        0x60, 0x0C, // PUSH1 0x0C
        0x56, // JUMP
        0xFE, // INVALID
        0x60, 0x0C, // PUSH1 0x0C
        0x56, // JUMP
        0xFE, // INVALID
        0x5B, // JUMPDEST (at position 0x0C = 12)
        0x00, // STOP
    };

    // Analyze bytecode
    var analysis = try evm.CodeAnalysis.analyze_bytecode_blocks(allocator, bytecode);
    defer analysis.deinit(allocator);

    // Create instruction buffer
    var instructions: [20]evm.Instruction = undefined;

    // Create jump table
    const jump_table = evm.JumpTable.init_from_hardfork(.CANCUN);

    // Translate bytecode to instructions
    var translator = evm.InstructionTranslator.init(
        allocator,
        bytecode,
        &analysis,
        &instructions,
        &jump_table,
    );

    const instruction_count = try translator.translate_bytecode();

    // Add null terminator
    instructions[instruction_count] = .{
        .opcode_fn = null,
        .arg = .none,
    };

    // Resolve jump targets
    try resolve_jump_targets(&instructions, instruction_count, bytecode, &analysis);

    // Both JUMP instructions should point to the same JUMPDEST
    try std.testing.expect(instructions[1].arg == .jump_target);
    try std.testing.expect(instructions[3].arg == .jump_target);
    try std.testing.expect(instructions[1].arg.jump_target == instructions[3].arg.jump_target);
}

// Helper function to resolve jump targets in instruction stream
fn resolve_jump_targets(
    instructions: []evm.Instruction,
    instruction_count: usize,
    bytecode: []const u8,
    analysis: *const evm.CodeAnalysis,
) !void {
    // First pass: build a map from PC to instruction index
    var pc_to_instruction = std.AutoHashMap(usize, usize).init(std.testing.allocator);
    defer pc_to_instruction.deinit();

    var pc: usize = 0;
    var inst_idx: usize = 0;

    while (inst_idx < instruction_count) : (inst_idx += 1) {
        try pc_to_instruction.put(pc, inst_idx);

        // Calculate PC advancement
        const opcode_byte = bytecode[pc];
        if (opcode_byte >= 0x60 and opcode_byte <= 0x7F) {
            // PUSH instruction
            const push_size = opcode_byte - 0x5F;
            pc += 1 + push_size;
        } else {
            pc += 1;
        }
    }

    // Second pass: update JUMP and JUMPI instructions with targets
    pc = 0;
    inst_idx = 0;

    while (inst_idx < instruction_count) : (inst_idx += 1) {
        const opcode_byte = bytecode[pc];

        if (opcode_byte == 0x56 or opcode_byte == 0x57) { // JUMP or JUMPI
            // The target address should be on the stack (from previous PUSH)
            // For this simple implementation, we'll look at the previous instruction
            if (inst_idx > 0 and instructions[inst_idx - 1].arg == .push_value) {
                const target_pc = instructions[inst_idx - 1].arg.push_value;

                // Check if the target is a JUMPDEST opcode
                if (bytecode[@intCast(target_pc)] == 0x5B) {
                    // Find the instruction index for this PC
                    if (pc_to_instruction.get(@intCast(target_pc))) |target_idx| {
                        // Update the JUMP/JUMPI instruction with the target
                        instructions[inst_idx].arg = .{ .jump_target = &instructions[target_idx] };
                    }
                }
            }
        }

        // Calculate PC advancement
        if (opcode_byte >= 0x60 and opcode_byte <= 0x7F) {
            // PUSH instruction
            const push_size = opcode_byte - 0x5F;
            pc += 1 + push_size;
        } else {
            pc += 1;
        }
    }
}
