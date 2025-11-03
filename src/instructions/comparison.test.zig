/// Tests for shared comparison instruction implementations
/// Phase 1.4 - Comparison operations (6 opcodes)
const std = @import("std");
const testing = std.testing;
const Frame = @import("Frame.zig");
const comparison = @import("comparison.zig");

// Test helper to create a frame
fn makeFrame(allocator: std.mem.Allocator) !Frame {
    return try Frame.init(allocator);
}

// LT tests (less than, unsigned)
test "LT: 5 < 10 = true" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(5);
    try frame.stack.push(10);

    const Instruction = comparison.LtInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "LT: 10 < 5 = false" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(10);
    try frame.stack.push(5);

    const Instruction = comparison.LtInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "LT: 5 < 5 = false" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(5);
    try frame.stack.push(5);

    const Instruction = comparison.LtInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// GT tests (greater than, unsigned)
test "GT: 10 > 5 = true" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(10);
    try frame.stack.push(5);

    const Instruction = comparison.GtInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "GT: 5 > 10 = false" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(5);
    try frame.stack.push(10);

    const Instruction = comparison.GtInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "GT: 5 > 5 = false" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(5);
    try frame.stack.push(5);

    const Instruction = comparison.GtInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// SLT tests (signed less than)
test "SLT: -1 < 1 = true" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    const neg_one: u256 = @bitCast(@as(i256, -1));
    try frame.stack.push(neg_one);
    try frame.stack.push(1);

    const Instruction = comparison.SltInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "SLT: 1 < -1 = false" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    const neg_one: u256 = @bitCast(@as(i256, -1));
    try frame.stack.push(1);
    try frame.stack.push(neg_one);

    const Instruction = comparison.SltInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// SGT tests (signed greater than)
test "SGT: 1 > -1 = true" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    const neg_one: u256 = @bitCast(@as(i256, -1));
    try frame.stack.push(1);
    try frame.stack.push(neg_one);

    const Instruction = comparison.SgtInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "SGT: -1 > 1 = false" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    const neg_one: u256 = @bitCast(@as(i256, -1));
    try frame.stack.push(neg_one);
    try frame.stack.push(1);

    const Instruction = comparison.SgtInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// EQ tests (equality)
test "EQ: 42 == 42 = true" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(42);
    try frame.stack.push(42);

    const Instruction = comparison.EqInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "EQ: 42 == 43 = false" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(42);
    try frame.stack.push(43);

    const Instruction = comparison.EqInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "EQ: 0 == 0 = true" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(0);
    try frame.stack.push(0);

    const Instruction = comparison.EqInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

// ISZERO tests
test "ISZERO: 0 == true" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(0);

    const Instruction = comparison.IszeroInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "ISZERO: 1 == false" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(1);

    const Instruction = comparison.IszeroInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "ISZERO: max == false" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(std.math.maxInt(u256));

    const Instruction = comparison.IszeroInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}
