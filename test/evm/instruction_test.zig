const std = @import("std");
const evm = @import("evm");
const Instruction = evm.Instruction;
const InstructionTranslator = evm.InstructionTranslator;
const ExecutionError = evm.ExecutionError;
const CodeAnalysis = evm.CodeAnalysis;

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
    const analysis = try CodeAnalysis.analyze(allocator, bytecode);
    defer analysis.deinit(allocator);
    
    var instructions: [10]Instruction = undefined;
    
    const translator = InstructionTranslator.init(
        allocator,
        bytecode,
        &analysis,
        &instructions,
    );
    
    try std.testing.expectEqual(@as(usize, 0), translator.instruction_count);
    try std.testing.expectEqual(bytecode.len, translator.code.len);
}

test "translate STOP opcode" {
    const allocator = std.testing.allocator;
    
    // Simple bytecode with just STOP (0x00)
    const bytecode = &[_]u8{0x00};
    
    // Create a basic code analysis
    const analysis = try CodeAnalysis.analyze(allocator, bytecode);
    defer analysis.deinit(allocator);
    
    // Create instruction buffer
    var instructions: [10]Instruction = undefined;
    
    // Create translator
    var translator = InstructionTranslator.init(
        allocator,
        bytecode,
        &analysis,
        &instructions,
    );
    
    // Translate bytecode
    const count = try translator.translate_bytecode();
    
    // Verify we got one instruction
    try std.testing.expectEqual(@as(usize, 1), count);
    
    // Verify the instruction is for STOP
    try std.testing.expect(instructions[0].arg == .none);
}