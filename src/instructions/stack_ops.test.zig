/// Tests for shared stack operation instruction implementations
/// Phase 1.5 - Stack operations (48 opcodes: POP, PUSH0-PUSH32, DUP1-DUP16, SWAP1-SWAP16)
const std = @import("std");
const testing = std.testing;
const Frame = @import("Frame.zig");
const stack_ops = @import("stack_ops.zig");

// Test helper to create a frame
fn makeFrame(allocator: std.mem.Allocator) !Frame {
    return try Frame.init(allocator);
}

// Test helper to create a frame with bytecode
fn makeFrameWithBytecode(allocator: std.mem.Allocator, bytecode: []const u8, pc: u32) !Frame {
    return try Frame.initWithBytecode(allocator, bytecode, pc);
}

// POP tests
test "POP: removes top stack item" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(100);
    try frame.stack.push(200);

    const Instruction = stack_ops.PopInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(usize, 1), frame.stack.len());
    try testing.expectEqual(@as(u256, 100), try frame.stack.pop());
}

test "POP: underflow on empty stack" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    const Instruction = stack_ops.PopInstruction(Frame);
    const result = Instruction.run(&frame);

    try testing.expectError(error.StackUnderflow, result);
}

// PUSH tests
test "PUSH0: pushes 0" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    const Instruction = stack_ops.PushInstruction(Frame, 0);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "PUSH1: pushes single byte" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{ 0x60, 0x42 }; // PUSH1 0x42
    var frame = try makeFrameWithBytecode(allocator, &bytecode, 0);
    defer frame.deinit(allocator);

    const Instruction = stack_ops.PushInstruction(Frame, 1);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0x42), try frame.stack.pop());
}

test "PUSH2: pushes two bytes" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{ 0x61, 0x12, 0x34 }; // PUSH2 0x1234
    var frame = try makeFrameWithBytecode(allocator, &bytecode, 0);
    defer frame.deinit(allocator);

    const Instruction = stack_ops.PushInstruction(Frame, 2);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0x1234), try frame.stack.pop());
}

test "PUSH32: pushes 32 bytes" {
    const allocator = testing.allocator;
    var bytecode: [33]u8 = undefined;
    bytecode[0] = 0x7f; // PUSH32
    @memset(bytecode[1..], 0xFF); // All FFs
    var frame = try makeFrameWithBytecode(allocator, &bytecode, 0);
    defer frame.deinit(allocator);

    const Instruction = stack_ops.PushInstruction(Frame, 32);
    try Instruction.run(&frame);

    try testing.expectEqual(std.math.maxInt(u256), try frame.stack.pop());
}

test "PUSH: invalid (not enough bytes)" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{ 0x60 }; // PUSH1 but no data
    var frame = try makeFrameWithBytecode(allocator, &bytecode, 0);
    defer frame.deinit(allocator);

    const Instruction = stack_ops.PushInstruction(Frame, 1);
    const result = Instruction.run(&frame);

    try testing.expectError(error.InvalidPush, result);
}

// DUP tests
test "DUP1: duplicates top item" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(42);

    const Instruction = stack_ops.DupInstruction(Frame, 1);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(usize, 2), frame.stack.len());
    try testing.expectEqual(@as(u256, 42), try frame.stack.pop());
    try testing.expectEqual(@as(u256, 42), try frame.stack.pop());
}

test "DUP2: duplicates second item" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(10);
    try frame.stack.push(20);

    const Instruction = stack_ops.DupInstruction(Frame, 2);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(usize, 3), frame.stack.len());
    try testing.expectEqual(@as(u256, 10), try frame.stack.pop()); // Duplicated 10
    try testing.expectEqual(@as(u256, 20), try frame.stack.pop());
    try testing.expectEqual(@as(u256, 10), try frame.stack.pop());
}

test "DUP16: duplicates 16th item" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    // Push 16 items
    var i: u256 = 1;
    while (i <= 16) : (i += 1) {
        try frame.stack.push(i);
    }

    const Instruction = stack_ops.DupInstruction(Frame, 16);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(usize, 17), frame.stack.len());
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop()); // Duplicated item 1
}

test "DUP: underflow" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(10);

    const Instruction = stack_ops.DupInstruction(Frame, 2); // Try to dup second item
    const result = Instruction.run(&frame);

    try testing.expectError(error.StackUnderflow, result);
}

// SWAP tests
test "SWAP1: swaps top two items" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(10);
    try frame.stack.push(20);

    const Instruction = stack_ops.SwapInstruction(Frame, 1);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(usize, 2), frame.stack.len());
    try testing.expectEqual(@as(u256, 10), try frame.stack.pop());
    try testing.expectEqual(@as(u256, 20), try frame.stack.pop());
}

test "SWAP2: swaps top with third" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(10);
    try frame.stack.push(20);
    try frame.stack.push(30);

    const Instruction = stack_ops.SwapInstruction(Frame, 2);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(usize, 3), frame.stack.len());
    try testing.expectEqual(@as(u256, 10), try frame.stack.pop());
    try testing.expectEqual(@as(u256, 20), try frame.stack.pop());
    try testing.expectEqual(@as(u256, 30), try frame.stack.pop());
}

test "SWAP16: swaps top with 17th" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    // Push 17 items (1 to 17)
    var i: u256 = 1;
    while (i <= 17) : (i += 1) {
        try frame.stack.push(i);
    }

    const Instruction = stack_ops.SwapInstruction(Frame, 16);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(usize, 17), frame.stack.len());
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop()); // Was 17th, now top
    // Verify middle items unchanged
    var j: u256 = 16;
    while (j >= 2) : (j -= 1) {
        try testing.expectEqual(j, try frame.stack.pop());
    }
    try testing.expectEqual(@as(u256, 17), try frame.stack.pop()); // Was top, now 17th
}

test "SWAP: underflow" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(10);

    const Instruction = stack_ops.SwapInstruction(Frame, 1); // Need 2 items for SWAP1
    const result = Instruction.run(&frame);

    try testing.expectError(error.StackUnderflow, result);
}
