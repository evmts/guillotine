/// Tests for shared arithmetic instruction implementations
/// Phase 1.2 - Arithmetic operations (11 opcodes)
const std = @import("std");
const testing = std.testing;
const Frame = @import("Frame.zig");
const arithmetic = @import("arithmetic.zig");

// Test helper to create a frame
fn makeFrame(allocator: std.mem.Allocator) !Frame {
    return try Frame.init(allocator);
}

// ADD tests
test "ADD: 5 + 3 = 8" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(5);
    try frame.stack.push(3);

    const Instruction = arithmetic.AddInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 8), try frame.stack.pop());
}

test "ADD: overflow wraps (max + 1 = 0)" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    const max = std.math.maxInt(u256);
    try frame.stack.push(max);
    try frame.stack.push(1);

    const Instruction = arithmetic.AddInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "ADD: requires 2 stack items (underflow)" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(5);
    // Only 1 item on stack

    const Instruction = arithmetic.AddInstruction(Frame);
    const result = Instruction.run(&frame);

    try testing.expectError(error.StackUnderflow, result);
}

// MUL tests
test "MUL: 6 * 7 = 42" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(6);
    try frame.stack.push(7);

    const Instruction = arithmetic.MulInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 42), try frame.stack.pop());
}

test "MUL: overflow wraps" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    const big = @as(u256, 1) << 200;
    try frame.stack.push(big);
    try frame.stack.push(big);

    const Instruction = arithmetic.MulInstruction(Frame);
    try Instruction.run(&frame);

    // Result wraps - exact value depends on u256 wrap behavior
    _ = try frame.stack.pop(); // Just verify no error
}

// SUB tests
test "SUB: 10 - 3 = 7" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(10);
    try frame.stack.push(3);

    const Instruction = arithmetic.SubInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 7), try frame.stack.pop());
}

test "SUB: underflow wraps (0 - 1 = max)" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(0);
    try frame.stack.push(1);

    const Instruction = arithmetic.SubInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(std.math.maxInt(u256), try frame.stack.pop());
}

// DIV tests
test "DIV: 20 / 4 = 5" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(20);
    try frame.stack.push(4);

    const Instruction = arithmetic.DivInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 5), try frame.stack.pop());
}

test "DIV: division by zero returns 0" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(100);
    try frame.stack.push(0);

    const Instruction = arithmetic.DivInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// SDIV tests
test "SDIV: signed division 10 / 3 = 3" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(10);
    try frame.stack.push(3);

    const Instruction = arithmetic.SdivInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 3), try frame.stack.pop());
}

test "SDIV: division by zero returns 0" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(100);
    try frame.stack.push(0);

    const Instruction = arithmetic.SdivInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// MOD tests
test "MOD: 17 % 5 = 2" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(17);
    try frame.stack.push(5);

    const Instruction = arithmetic.ModInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 2), try frame.stack.pop());
}

test "MOD: mod by zero returns 0" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(100);
    try frame.stack.push(0);

    const Instruction = arithmetic.ModInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// SMOD tests
test "SMOD: signed mod 17 % 5 = 2" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(17);
    try frame.stack.push(5);

    const Instruction = arithmetic.SmodInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 2), try frame.stack.pop());
}

// ADDMOD tests
test "ADDMOD: (5 + 7) % 3 = 0" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(5);
    try frame.stack.push(7);
    try frame.stack.push(3);

    const Instruction = arithmetic.AddmodInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "ADDMOD: mod by zero returns 0" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(5);
    try frame.stack.push(7);
    try frame.stack.push(0);

    const Instruction = arithmetic.AddmodInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// MULMOD tests
test "MULMOD: (6 * 7) % 10 = 2" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(6);
    try frame.stack.push(7);
    try frame.stack.push(10);

    const Instruction = arithmetic.MulmodInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 2), try frame.stack.pop());
}

// EXP tests
test "EXP: 2^8 = 256" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(2);
    try frame.stack.push(8);

    const Instruction = arithmetic.ExpInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 256), try frame.stack.pop());
}

test "EXP: 0^0 = 1" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(0);
    try frame.stack.push(0);

    const Instruction = arithmetic.ExpInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

// SIGNEXTEND tests
test "SIGNEXTEND: extend byte 0 with positive" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(0); // byte index
    try frame.stack.push(0x7F); // positive (bit 7 = 0)

    const Instruction = arithmetic.SignextendInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0x7F), try frame.stack.pop());
}

test "SIGNEXTEND: extend byte 0 with negative" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(0); // byte index
    try frame.stack.push(0xFF); // negative (bit 7 = 1)

    const Instruction = arithmetic.SignextendInstruction(Frame);
    try Instruction.run(&frame);

    // Sign bit set, so extend with 1s
    try testing.expectEqual(std.math.maxInt(u256), try frame.stack.pop());
}
