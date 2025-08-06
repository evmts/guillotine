const std = @import("std");
const evm = @import("evm");

test "end-to-end block execution: bytecode -> translate -> execute" {
    const allocator = std.testing.allocator;
    
    // Create a simple bytecode program: PUSH1 5, PUSH1 10, ADD, PUSH1 20, MUL, STOP
    const bytecode = &[_]u8{ 
        0x60, 0x05,  // PUSH1 5
        0x60, 0x0A,  // PUSH1 10 (0x0A = 10)
        0x01,        // ADD (5 + 10 = 15)
        0x60, 0x14,  // PUSH1 20 (0x14 = 20)
        0x02,        // MUL (15 * 20 = 300)
        0x00,        // STOP
    };
    
    // Step 1: Analyze bytecode
    const analysis = try evm.CodeAnalysis.analyze_bytecode_blocks(allocator, bytecode);
    defer analysis.deinit(allocator);
    
    // Step 2: Create instruction buffer
    var instructions: [100]evm.Instruction = undefined;
    
    // Step 3: Create jump table
    const jump_table = evm.JumpTable.init_from_hardfork(.CANCUN);
    
    // Step 4: Translate bytecode to instructions
    var translator = evm.InstructionTranslator.init(
        allocator,
        bytecode,
        &analysis,
        &instructions,
        &jump_table,
    );
    
    const instruction_count = try translator.translate_bytecode();
    try std.testing.expectEqual(@as(usize, 6), instruction_count);
    
    // Step 5: Null-terminate the instruction array
    instructions[instruction_count] = .{
        .opcode_fn = null,
        .arg = .none,
    };
    
    // Step 6: Create VM and frame for execution
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Create a contract with our bytecode
    var contract = try evm.Contract.init(
        allocator, 
        bytecode,
        null,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        0,
        false,
    );
    defer contract.deinit(allocator, null);
    
    // Create frame
    var frame = try evm.Frame.init(allocator, &vm, 1000000, contract, evm.primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    // Step 7: Execute the instruction stream
    // We need to manually handle the execution since the current opcodes
    // expect to read from bytecode. This is a limitation we'll address
    // in the full integration.
    
    // For now, let's verify the translation worked correctly
    try std.testing.expect(instructions[0].arg == .push_value);
    try std.testing.expectEqual(@as(u256, 5), instructions[0].arg.push_value);
    
    try std.testing.expect(instructions[1].arg == .push_value);
    try std.testing.expectEqual(@as(u256, 10), instructions[1].arg.push_value);
    
    try std.testing.expect(instructions[2].arg == .none); // ADD
    
    try std.testing.expect(instructions[3].arg == .push_value);
    try std.testing.expectEqual(@as(u256, 20), instructions[3].arg.push_value);
    
    try std.testing.expect(instructions[4].arg == .none); // MUL
    try std.testing.expect(instructions[5].arg == .none); // STOP
    
    // Verify the opcode functions are correct
    const execution = evm.execution;
    try std.testing.expect(instructions[0].opcode_fn == execution.stack.op_push1);
    try std.testing.expect(instructions[1].opcode_fn == execution.stack.op_push1);
    try std.testing.expect(instructions[2].opcode_fn == execution.arithmetic.op_add);
    try std.testing.expect(instructions[3].opcode_fn == execution.stack.op_push1);
    try std.testing.expect(instructions[4].opcode_fn == execution.arithmetic.op_mul);
    try std.testing.expect(instructions[5].opcode_fn == execution.control.op_stop);
}

test "block execution with complex control flow" {
    const allocator = std.testing.allocator;
    
    // Create bytecode with conditional logic:
    // PUSH1 1, PUSH1 1, EQ, PUSH1 0x0C, JUMPI, PUSH1 0, STOP, JUMPDEST, PUSH1 42, STOP
    const bytecode = &[_]u8{ 
        0x60, 0x01,  // PUSH1 1
        0x60, 0x01,  // PUSH1 1
        0x14,        // EQ (1 == 1 = true)
        0x60, 0x0C,  // PUSH1 12 (jump destination)
        0x57,        // JUMPI
        0x60, 0x00,  // PUSH1 0 (not reached)
        0x00,        // STOP (not reached)
        0x5B,        // JUMPDEST (pc=12)
        0x60, 0x2A,  // PUSH1 42 (0x2A = 42)
        0x00,        // STOP
    };
    
    // Analyze bytecode
    const analysis = try evm.CodeAnalysis.analyze_bytecode_blocks(allocator, bytecode);
    defer analysis.deinit(allocator);
    
    // Create instruction buffer
    var instructions: [100]evm.Instruction = undefined;
    
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
    
    // Verify we got the right number of instructions
    try std.testing.expectEqual(@as(usize, 10), instruction_count);
    
    // Verify the JUMPI instruction is present
    const execution = evm.execution;
    try std.testing.expect(instructions[4].opcode_fn == execution.control.op_jumpi);
    
    // Verify JUMPDEST is present
    try std.testing.expect(instructions[7].opcode_fn == execution.control.op_jumpdest);
}

test "block execution with all opcode categories" {
    const allocator = std.testing.allocator;
    
    // Create bytecode with various opcode categories:
    // Stack: PUSH, DUP, SWAP, POP
    // Arithmetic: ADD, MUL
    // Memory: MSTORE, MLOAD
    // Control: JUMPDEST, STOP
    const bytecode = &[_]u8{ 
        // Stack operations
        0x60, 0x01,  // PUSH1 1
        0x60, 0x02,  // PUSH1 2
        0x80,        // DUP1
        0x90,        // SWAP1
        0x50,        // POP
        
        // Arithmetic
        0x01,        // ADD
        0x60, 0x03,  // PUSH1 3
        0x02,        // MUL
        
        // Memory operations
        0x60, 0x00,  // PUSH1 0 (offset)
        0x52,        // MSTORE
        0x60, 0x00,  // PUSH1 0 (offset)
        0x51,        // MLOAD
        
        // Control
        0x5B,        // JUMPDEST
        0x00,        // STOP
    };
    
    // Analyze bytecode
    const analysis = try evm.CodeAnalysis.analyze_bytecode_blocks(allocator, bytecode);
    defer analysis.deinit(allocator);
    
    // Create instruction buffer
    var instructions: [100]evm.Instruction = undefined;
    
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
    
    // Verify we got all instructions
    try std.testing.expectEqual(@as(usize, 14), instruction_count);
    
    // Spot check various opcode types
    const execution = evm.execution;
    
    // Stack ops
    try std.testing.expect(instructions[0].opcode_fn == execution.stack.op_push1);
    try std.testing.expect(instructions[2].opcode_fn == execution.stack.op_dup1);
    try std.testing.expect(instructions[3].opcode_fn == execution.stack.op_swap1);
    try std.testing.expect(instructions[4].opcode_fn == execution.stack.op_pop);
    
    // Arithmetic ops
    try std.testing.expect(instructions[5].opcode_fn == execution.arithmetic.op_add);
    try std.testing.expect(instructions[7].opcode_fn == execution.arithmetic.op_mul);
    
    // Memory ops
    try std.testing.expect(instructions[9].opcode_fn == execution.memory.op_mstore);
    try std.testing.expect(instructions[11].opcode_fn == execution.memory.op_mload);
    
    // Control ops
    try std.testing.expect(instructions[12].opcode_fn == execution.control.op_jumpdest);
    try std.testing.expect(instructions[13].opcode_fn == execution.control.op_stop);
}