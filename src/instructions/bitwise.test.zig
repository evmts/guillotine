/// Tests for shared bitwise instruction implementations
/// Phase 1.3 - Bitwise operations (9 opcodes)
const std = @import("std");
const testing = std.testing;
const Frame = @import("Frame.zig");
const bitwise = @import("bitwise.zig");

// Test helper to create a frame
fn makeFrame(allocator: std.mem.Allocator) !Frame {
    return try Frame.init(allocator);
}

// AND tests
test "AND: 0xFF & 0x0F = 0x0F" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(0xFF);
    try frame.stack.push(0x0F);

    const Instruction = bitwise.AndInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0x0F), try frame.stack.pop());
}

test "AND: all bits set & 0 = 0" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(std.math.maxInt(u256));
    try frame.stack.push(0);

    const Instruction = bitwise.AndInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// OR tests
test "OR: 0xF0 | 0x0F = 0xFF" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(0xF0);
    try frame.stack.push(0x0F);

    const Instruction = bitwise.OrInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0xFF), try frame.stack.pop());
}

test "OR: 0 | 0 = 0" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(0);
    try frame.stack.push(0);

    const Instruction = bitwise.OrInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// XOR tests
test "XOR: 0xFF ^ 0x0F = 0xF0" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(0xFF);
    try frame.stack.push(0x0F);

    const Instruction = bitwise.XorInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0xF0), try frame.stack.pop());
}

test "XOR: value ^ value = 0" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(0x12345);
    try frame.stack.push(0x12345);

    const Instruction = bitwise.XorInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// NOT tests
test "NOT: ~0 = max" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(0);

    const Instruction = bitwise.NotInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(std.math.maxInt(u256), try frame.stack.pop());
}

test "NOT: ~max = 0" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(std.math.maxInt(u256));

    const Instruction = bitwise.NotInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// BYTE tests
test "BYTE: extract byte 0 from 0x1234" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(0); // byte index 0 (leftmost)
    try frame.stack.push(0x12340000000000000000000000000000000000000000000000000000000000000);

    const Instruction = bitwise.ByteInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0x12), try frame.stack.pop());
}

test "BYTE: extract byte 31 from value" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(31); // byte index 31 (rightmost)
    try frame.stack.push(0xFF);

    const Instruction = bitwise.ByteInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0xFF), try frame.stack.pop());
}

test "BYTE: out of bounds returns 0" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(32); // out of bounds
    try frame.stack.push(0x12345);

    const Instruction = bitwise.ByteInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// SHL tests (Constantinople+)
test "SHL: 1 << 8 = 256" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(8); // shift amount
    try frame.stack.push(1); // value

    const Instruction = bitwise.ShlInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 256), try frame.stack.pop());
}

test "SHL: shift >= 256 returns 0" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(256); // shift amount >= 256
    try frame.stack.push(0xFF);

    const Instruction = bitwise.ShlInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// SHR tests (Constantinople+)
test "SHR: 256 >> 8 = 1" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(8); // shift amount
    try frame.stack.push(256); // value

    const Instruction = bitwise.ShrInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "SHR: shift >= 256 returns 0" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(256); // shift amount >= 256
    try frame.stack.push(0xFF);

    const Instruction = bitwise.ShrInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// SAR tests (Constantinople+)
test "SAR: arithmetic right shift positive" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(8); // shift amount
    try frame.stack.push(256); // positive value

    const Instruction = bitwise.SarInstruction(Frame);
    try Instruction.run(&frame);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "SAR: arithmetic right shift negative" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    // Negative number (sign bit set)
    const negative: u256 = @bitCast(@as(i256, -256));

    try frame.stack.push(8); // shift amount
    try frame.stack.push(negative);

    const Instruction = bitwise.SarInstruction(Frame);
    try Instruction.run(&frame);

    // Should preserve sign (all 1s in upper bits)
    const result = try frame.stack.pop();
    const result_signed = @as(i256, @bitCast(result));
    try testing.expect(result_signed == -1);
}

test "SAR: large shift on negative returns all 1s" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    const negative: u256 = @bitCast(@as(i256, -1));

    try frame.stack.push(300); // shift >= 256
    try frame.stack.push(negative);

    const Instruction = bitwise.SarInstruction(Frame);
    try Instruction.run(&frame);

    // Negative shifted >= 256 bits should be all 1s (i.e., -1)
    try testing.expectEqual(std.math.maxInt(u256), try frame.stack.pop());
}

test "SAR: large shift on positive returns 0" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(300); // shift >= 256
    try frame.stack.push(0x7FFFFFFF);

    const Instruction = bitwise.SarInstruction(Frame);
    try Instruction.run(&frame);

    // Positive shifted >= 256 bits should be 0
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}
