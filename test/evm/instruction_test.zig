const std = @import("std");
const evm = @import("evm");
const Instruction = evm.Instruction;
const InstructionTranslator = evm.InstructionTranslator;
const ExecutionError = evm.ExecutionError;
const CodeAnalysis = evm.CodeAnalysis;
const JumpTable = evm.JumpTable;
const Hardfork = evm.Hardfork;

// Dummy opcode function for testing
fn test_opcode(pc: usize, interpreter: anytype, state: anytype) ExecutionError.Error!evm.execution.ExecutionResult {
    _ = pc;
    _ = interpreter;
    _ = state;
    return .{};
}

test "Instruction struct creation" {
    const inst = Instruction{
        .opcode_fn = test_opcode,
        .arg = .none,
    };
    try std.testing.expect(inst.opcode_fn == test_opcode);
    try std.testing.expect(inst.arg == .none);
}

test "Instruction with block metrics" {
    const metrics = evm.Instruction.BlockMetrics{
        .gas_cost = 3,
        .stack_req = 2,
        .stack_max = 1,
    };

    const inst = Instruction{
        .opcode_fn = test_opcode,
        .arg = .{ .block_metrics = metrics },
    };

    try std.testing.expectEqual(@as(u32, 3), inst.arg.block_metrics.gas_cost);
    try std.testing.expectEqual(@as(i16, 2), inst.arg.block_metrics.stack_req);
    try std.testing.expectEqual(@as(i16, 1), inst.arg.block_metrics.stack_max);
}

test "Instruction with push value" {
    const inst = Instruction{
        .opcode_fn = test_opcode,
        .arg = .{ .push_value = 42 },
    };

    try std.testing.expectEqual(@as(u256, 42), inst.arg.push_value);
}

test "Instruction with gas cost" {
    const inst = Instruction{
        .opcode_fn = test_opcode,
        .arg = .{ .gas_cost = 21000 },
    };

    try std.testing.expectEqual(@as(u32, 21000), inst.arg.gas_cost);
}

test "Instruction.execute implementation exists" {
    // The execute method is implemented and has the correct signature
    // Full testing requires a real Frame which has complex dependencies
    
    const inst = Instruction{
        .opcode_fn = test_opcode,
        .arg = .none,
    };
    
    // Basic sanity check that our test instruction is valid
    try std.testing.expect(inst.opcode_fn == test_opcode);
    try std.testing.expect(inst.arg == .none);
}

test "InstructionTranslator initialization" {
    const allocator = std.testing.allocator;
    
    const bytecode = &[_]u8{0x00};
    const analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, bytecode);
    defer analysis.deinit(allocator);
    
    var instructions: [10]Instruction = undefined;
    
    const jump_table = JumpTable.init_from_hardfork(.CANCUN);
    
    const translator = InstructionTranslator.init(
        allocator,
        bytecode,
        &analysis,
        &instructions,
        &jump_table,
    );
    
    try std.testing.expectEqual(@as(usize, 0), translator.instruction_count);
    try std.testing.expectEqual(bytecode.len, translator.code.len);
}

test "translate STOP opcode" {
    const allocator = std.testing.allocator;
    
    // Simple bytecode with just STOP (0x00)
    const bytecode = &[_]u8{0x00};
    
    // Create a basic code analysis
    const analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, bytecode);
    defer analysis.deinit(allocator);
    
    // Create instruction buffer
    var instructions: [10]Instruction = undefined;
    
    // Create jump table
    const jump_table = JumpTable.init_from_hardfork(.CANCUN);
    
    // Create translator
    var translator = InstructionTranslator.init(
        allocator,
        bytecode,
        &analysis,
        &instructions,
        &jump_table,
    );
    
    // Translate bytecode
    const count = try translator.translate_bytecode();
    
    // Verify we got one instruction
    try std.testing.expectEqual(@as(usize, 1), count);
    
    // Verify the instruction is for STOP
    try std.testing.expect(instructions[0].arg == .none);
    
    // Verify the opcode function is correct (it should be control.op_stop)
    const execution = @import("evm").execution;
    try std.testing.expect(instructions[0].opcode_fn == execution.control.op_stop);
}

test "translate PUSH0 opcode" {
    const allocator = std.testing.allocator;
    
    // PUSH0 (0x5F) - EIP-3855
    const bytecode = &[_]u8{0x5F};
    
    // Create a basic code analysis
    const analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, bytecode);
    defer analysis.deinit(allocator);
    
    // Create instruction buffer
    var instructions: [10]Instruction = undefined;
    
    // Create jump table
    const jump_table = JumpTable.init_from_hardfork(.CANCUN);
    
    // Create translator
    var translator = InstructionTranslator.init(
        allocator,
        bytecode,
        &analysis,
        &instructions,
        &jump_table,
    );
    
    // Translate bytecode
    const count = try translator.translate_bytecode();
    
    // Verify we got one instruction
    try std.testing.expectEqual(@as(usize, 1), count);
    
    // Verify the instruction has a push value of 0
    try std.testing.expect(instructions[0].arg == .push_value);
    try std.testing.expectEqual(@as(u256, 0), instructions[0].arg.push_value);
    
    // Verify the opcode function is correct (it should be stack.op_push0)
    const execution = @import("evm").execution;
    try std.testing.expect(instructions[0].opcode_fn == execution.stack.op_push0);
}

test "translate PUSH1 opcode" {
    const allocator = std.testing.allocator;
    
    // PUSH1 0x42 (0x60 0x42)
    const bytecode = &[_]u8{ 0x60, 0x42 };
    
    // Create a basic code analysis
    const analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, bytecode);
    defer analysis.deinit(allocator);
    
    // Create instruction buffer
    var instructions: [10]Instruction = undefined;
    
    // Create jump table
    const jump_table = JumpTable.init_from_hardfork(.CANCUN);
    
    // Create translator
    var translator = InstructionTranslator.init(
        allocator,
        bytecode,
        &analysis,
        &instructions,
        &jump_table,
    );
    
    // Translate bytecode
    const count = try translator.translate_bytecode();
    
    // Verify we got one instruction
    try std.testing.expectEqual(@as(usize, 1), count);
    
    // Verify the instruction has a push value
    try std.testing.expect(instructions[0].arg == .push_value);
    try std.testing.expectEqual(@as(u256, 0x42), instructions[0].arg.push_value);
    
    // Verify the opcode function is correct (it should be stack.op_push1)
    const execution = @import("evm").execution;
    try std.testing.expect(instructions[0].opcode_fn == execution.stack.op_push1);
}

test "translate PUSH32 opcode" {
    const allocator = std.testing.allocator;
    
    // PUSH32 with max value (0x7F followed by 32 bytes of 0xFF)
    var bytecode: [33]u8 = undefined;
    bytecode[0] = 0x7F; // PUSH32
    @memset(bytecode[1..], 0xFF);
    
    // Create a basic code analysis
    const analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, &bytecode);
    defer analysis.deinit(allocator);
    
    // Create instruction buffer
    var instructions: [10]Instruction = undefined;
    
    // Create jump table
    const jump_table = JumpTable.init_from_hardfork(.CANCUN);
    
    // Create translator
    var translator = InstructionTranslator.init(
        allocator,
        &bytecode,
        &analysis,
        &instructions,
        &jump_table,
    );
    
    // Translate bytecode
    const count = try translator.translate_bytecode();
    
    // Verify we got one instruction
    try std.testing.expectEqual(@as(usize, 1), count);
    
    // Verify the instruction has a push value of max u256
    try std.testing.expect(instructions[0].arg == .push_value);
    const max_u256: u256 = std.math.maxInt(u256);
    try std.testing.expectEqual(max_u256, instructions[0].arg.push_value);
}

test "translate PUSH with truncated data" {
    const allocator = std.testing.allocator;
    
    // PUSH4 but only 2 bytes available - should pad with zeros
    const bytecode = &[_]u8{ 0x63, 0xAB, 0xCD }; // PUSH4 with only 2 bytes
    
    // Create a basic code analysis
    const analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, bytecode);
    defer analysis.deinit(allocator);
    
    // Create instruction buffer
    var instructions: [10]Instruction = undefined;
    
    // Create jump table
    const jump_table = JumpTable.init_from_hardfork(.CANCUN);
    
    // Create translator
    var translator = InstructionTranslator.init(
        allocator,
        bytecode,
        &analysis,
        &instructions,
        &jump_table,
    );
    
    // Translate bytecode
    const count = try translator.translate_bytecode();
    
    // Verify we got one instruction
    try std.testing.expectEqual(@as(usize, 1), count);
    
    // Verify the instruction has a push value of 0xABCD0000 (padded with zeros)
    try std.testing.expect(instructions[0].arg == .push_value);
    try std.testing.expectEqual(@as(u256, 0xABCD0000), instructions[0].arg.push_value);
}

test "translate multiple opcodes sequence" {
    const allocator = std.testing.allocator;
    
    // PUSH1 0x05, PUSH1 0x10, STOP
    const bytecode = &[_]u8{ 0x60, 0x05, 0x60, 0x10, 0x00 };
    
    // Create a basic code analysis
    const analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, bytecode);
    defer analysis.deinit(allocator);
    
    // Create instruction buffer
    var instructions: [10]Instruction = undefined;
    
    // Create jump table
    const jump_table = JumpTable.init_from_hardfork(.CANCUN);
    
    // Create translator
    var translator = InstructionTranslator.init(
        allocator,
        bytecode,
        &analysis,
        &instructions,
        &jump_table,
    );
    
    // Translate bytecode
    const count = try translator.translate_bytecode();
    
    // Verify we got three instructions
    try std.testing.expectEqual(@as(usize, 3), count);
    
    // Verify first PUSH1
    try std.testing.expect(instructions[0].arg == .push_value);
    try std.testing.expectEqual(@as(u256, 0x05), instructions[0].arg.push_value);
    
    // Verify second PUSH1
    try std.testing.expect(instructions[1].arg == .push_value);
    try std.testing.expectEqual(@as(u256, 0x10), instructions[1].arg.push_value);
    
    // Verify STOP
    try std.testing.expect(instructions[2].arg == .none);
    const execution = @import("evm").execution;
    try std.testing.expect(instructions[2].opcode_fn == execution.control.op_stop);
}

test "translate ADD opcode" {
    const allocator = std.testing.allocator;
    
    // PUSH1 0x05, PUSH1 0x10, ADD (0x01)
    const bytecode = &[_]u8{ 0x60, 0x05, 0x60, 0x10, 0x01 };
    
    // Create a basic code analysis
    const analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, bytecode);
    defer analysis.deinit(allocator);
    
    // Create instruction buffer
    var instructions: [10]Instruction = undefined;
    
    // Create jump table
    const jump_table = JumpTable.init_from_hardfork(.CANCUN);
    
    // Create translator
    var translator = InstructionTranslator.init(
        allocator,
        bytecode,
        &analysis,
        &instructions,
        &jump_table,
    );
    
    // Translate bytecode
    const count = try translator.translate_bytecode();
    
    // Verify we got three instructions (2 PUSH + 1 ADD)
    try std.testing.expectEqual(@as(usize, 3), count);
    
    // Verify PUSH1 0x05
    try std.testing.expect(instructions[0].arg == .push_value);
    try std.testing.expectEqual(@as(u256, 0x05), instructions[0].arg.push_value);
    
    // Verify PUSH1 0x10
    try std.testing.expect(instructions[1].arg == .push_value);
    try std.testing.expectEqual(@as(u256, 0x10), instructions[1].arg.push_value);
    
    // Verify ADD
    try std.testing.expect(instructions[2].arg == .none);
    const execution = @import("evm").execution;
    try std.testing.expect(instructions[2].opcode_fn == execution.arithmetic.op_add);
}

test "translate arithmetic sequence" {
    const allocator = std.testing.allocator;
    
    // PUSH1 0x20, PUSH1 0x10, SUB, PUSH1 0x02, MUL
    const bytecode = &[_]u8{ 0x60, 0x20, 0x60, 0x10, 0x03, 0x60, 0x02, 0x02 };
    
    // Create a basic code analysis
    const analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, bytecode);
    defer analysis.deinit(allocator);
    
    // Create instruction buffer
    var instructions: [10]Instruction = undefined;
    
    // Create jump table
    const jump_table = JumpTable.init_from_hardfork(.CANCUN);
    
    // Create translator
    var translator = InstructionTranslator.init(
        allocator,
        bytecode,
        &analysis,
        &instructions,
        &jump_table,
    );
    
    // Translate bytecode
    const count = try translator.translate_bytecode();
    
    // Verify we got five instructions
    try std.testing.expectEqual(@as(usize, 5), count);
    
    // Verify SUB
    try std.testing.expect(instructions[2].arg == .none);
    const execution = @import("evm").execution;
    try std.testing.expect(instructions[2].opcode_fn == execution.arithmetic.op_sub);
    
    // Verify MUL
    try std.testing.expect(instructions[4].arg == .none);
    try std.testing.expect(instructions[4].opcode_fn == execution.arithmetic.op_mul);
}

test "translate comprehensive opcode sequence" {
    const allocator = std.testing.allocator;
    
    // Complex sequence with various opcodes:
    // PUSH1 0x10, DUP1, MSTORE, PUSH1 0x20, MLOAD, ADD, POP, JUMPDEST, STOP
    const bytecode = &[_]u8{ 
        0x60, 0x10,  // PUSH1 0x10
        0x80,        // DUP1
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 0x20
        0x51,        // MLOAD
        0x01,        // ADD
        0x50,        // POP
        0x5B,        // JUMPDEST
        0x00,        // STOP
    };
    
    // Create a basic code analysis
    const analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, bytecode);
    defer analysis.deinit(allocator);
    
    // Create instruction buffer
    var instructions: [20]Instruction = undefined;
    
    // Create jump table
    const jump_table = JumpTable.init_from_hardfork(.CANCUN);
    
    // Create translator
    var translator = InstructionTranslator.init(
        allocator,
        bytecode,
        &analysis,
        &instructions,
        &jump_table,
    );
    
    // Translate bytecode
    const count = try translator.translate_bytecode();
    
    // Verify we got the right number of instructions
    try std.testing.expectEqual(@as(usize, 9), count);
    
    // Spot check a few opcodes
    const execution = @import("evm").execution;
    
    // Check DUP1
    try std.testing.expect(instructions[1].arg == .none);
    try std.testing.expect(instructions[1].opcode_fn == execution.stack.op_dup1);
    
    // Check MSTORE
    try std.testing.expect(instructions[2].arg == .none);
    try std.testing.expect(instructions[2].opcode_fn == execution.memory.op_mstore);
    
    // Check POP
    try std.testing.expect(instructions[6].arg == .none);
    try std.testing.expect(instructions[6].opcode_fn == execution.stack.op_pop);
    
    // Check JUMPDEST
    try std.testing.expect(instructions[7].arg == .none);
    try std.testing.expect(instructions[7].opcode_fn == execution.control.op_jumpdest);
}

test "translate JUMP and JUMPI opcodes" {
    const allocator = std.testing.allocator;
    
    // PUSH1 0x08, JUMP, PUSH1 0x00, PUSH1 0x00, REVERT, JUMPDEST, STOP
    const bytecode = &[_]u8{ 
        0x60, 0x08,  // PUSH1 0x08
        0x56,        // JUMP
        0x60, 0x00,  // PUSH1 0x00
        0x60, 0x00,  // PUSH1 0x00
        0xFD,        // REVERT
        0x5B,        // JUMPDEST
        0x00,        // STOP
    };
    
    // Create a basic code analysis
    const analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, bytecode);
    defer analysis.deinit(allocator);
    
    // Create instruction buffer
    var instructions: [20]Instruction = undefined;
    
    // Create jump table
    const jump_table = JumpTable.init_from_hardfork(.CANCUN);
    
    // Create translator
    var translator = InstructionTranslator.init(
        allocator,
        bytecode,
        &analysis,
        &instructions,
        &jump_table,
    );
    
    // Translate bytecode
    const count = try translator.translate_bytecode();
    
    // Verify we got the right number of instructions
    try std.testing.expectEqual(@as(usize, 7), count);
    
    // Verify JUMP
    try std.testing.expect(instructions[1].arg == .none); // Will be updated with jump target in phase 2
    const execution = @import("evm").execution;
    try std.testing.expect(instructions[1].opcode_fn == execution.control.op_jump);
    
    // Verify REVERT
    try std.testing.expect(instructions[4].arg == .none);
    try std.testing.expect(instructions[4].opcode_fn == execution.control.op_revert);
}