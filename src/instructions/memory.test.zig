/// Tests for memory instruction implementations
/// Phase 3 - Test memory operations
const std = @import("std");
const testing = std.testing;
const Frame = @import("Frame.zig");
const memory = @import("memory.zig");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

// Test helper
fn makeFrame(allocator: std.mem.Allocator) !Frame {
    return try Frame.initFull(
        allocator,
        &[_]u8{},
        1000000, // gas
        Address.zero(),
        Address.zero(),
        0,
        &[_]u8{},
        .CANCUN,
    );
}

// MLOAD opcode (0x51)
test "MLOAD: loads 32-byte word from memory" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    // Write some bytes to memory
    try frame.writeMemory(0, 0xaa);
    try frame.writeMemory(1, 0xbb);
    try frame.writeMemory(31, 0xff);

    // Load from offset 0
    try frame.stack.push(0);
    try memory.MloadInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    // First byte (0xaa) should be in MSB position
    const expected = (@as(u256, 0xaa) << 248) | (@as(u256, 0xbb) << 240) | (@as(u256, 0xff) << 0);
    try testing.expectEqual(expected, result);
}

test "MLOAD: reads uninitialized memory as zeros" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    // Load from offset 100 (uninitialized)
    try frame.stack.push(100);
    try memory.MloadInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

test "MLOAD: expands memory size" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try testing.expectEqual(@as(u32, 0), frame.memory_size);

    // Load from offset 0 (reads 32 bytes)
    try frame.stack.push(0);
    try memory.MloadInstruction(Frame).run(&frame);

    // Memory should be expanded to 32 bytes (1 word)
    try testing.expectEqual(@as(u32, 32), frame.memory_size);
}

// MSTORE opcode (0x52)
test "MSTORE: stores 32-byte word to memory" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    // Store 0x123456... at offset 0
    const value: u256 = 0x123456789abcdef0;
    try frame.stack.push(value);
    try frame.stack.push(0); // offset
    try memory.MstoreInstruction(Frame).run(&frame);

    // Verify bytes (big-endian)
    try testing.expectEqual(@as(u8, 0x00), frame.readMemory(0)); // MSB = 0x00 (upper bytes of u256)
    try testing.expectEqual(@as(u8, 0x12), frame.readMemory(24)); // 0x12 starts here
    try testing.expectEqual(@as(u8, 0x34), frame.readMemory(25));
    try testing.expectEqual(@as(u8, 0xf0), frame.readMemory(31)); // LSB
}

test "MSTORE: expands memory size" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try testing.expectEqual(@as(u32, 0), frame.memory_size);

    // Store at offset 64 (writes 32 bytes)
    try frame.stack.push(0x42);
    try frame.stack.push(64); // offset
    try memory.MstoreInstruction(Frame).run(&frame);

    // Memory should be expanded to 96 bytes (3 words: 0-31, 32-63, 64-95)
    try testing.expectEqual(@as(u32, 96), frame.memory_size);
}

// MSTORE8 opcode (0x53)
test "MSTORE8: stores single byte to memory" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    // Store 0x42 at offset 5
    try frame.stack.push(0x42);
    try frame.stack.push(5); // offset
    try memory.Mstore8Instruction(Frame).run(&frame);

    try testing.expectEqual(@as(u8, 0x42), frame.readMemory(5));
    try testing.expectEqual(@as(u8, 0x00), frame.readMemory(4)); // Adjacent bytes should be 0
    try testing.expectEqual(@as(u8, 0x00), frame.readMemory(6));
}

test "MSTORE8: truncates value to single byte" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    // Store 0x123456 at offset 0 (should truncate to 0x56)
    try frame.stack.push(0x123456);
    try frame.stack.push(0); // offset
    try memory.Mstore8Instruction(Frame).run(&frame);

    try testing.expectEqual(@as(u8, 0x56), frame.readMemory(0));
}

// MSIZE opcode (0x59)
test "MSIZE: returns 0 for empty memory" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    try memory.MsizeInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

test "MSIZE: returns word-aligned size after MSTORE" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    // Store at offset 0 (expands to 32 bytes)
    try frame.stack.push(0x42);
    try frame.stack.push(0);
    try memory.MstoreInstruction(Frame).run(&frame);

    try memory.MsizeInstruction(Frame).run(&frame);
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 32), result);
}

test "MSIZE: returns word-aligned size after MSTORE8" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    // Store at offset 5 (expands to 32 bytes, word-aligned)
    try frame.stack.push(0x42);
    try frame.stack.push(5);
    try memory.Mstore8Instruction(Frame).run(&frame);

    try memory.MsizeInstruction(Frame).run(&frame);
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 32), result);
}

// MCOPY opcode (0x5e) - Cancun+
test "MCOPY: copies memory within same region" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    // Write source data
    try frame.writeMemory(0, 0xaa);
    try frame.writeMemory(1, 0xbb);
    try frame.writeMemory(2, 0xcc);

    // Copy 3 bytes from offset 0 to offset 10
    try frame.stack.push(3); // length
    try frame.stack.push(0); // src
    try frame.stack.push(10); // dest
    try memory.McopyInstruction(Frame).run(&frame);

    // Verify destination
    try testing.expectEqual(@as(u8, 0xaa), frame.readMemory(10));
    try testing.expectEqual(@as(u8, 0xbb), frame.readMemory(11));
    try testing.expectEqual(@as(u8, 0xcc), frame.readMemory(12));
}

test "MCOPY: handles overlapping regions" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    // Write source data
    try frame.writeMemory(0, 0x11);
    try frame.writeMemory(1, 0x22);
    try frame.writeMemory(2, 0x33);
    try frame.writeMemory(3, 0x44);

    // Copy 3 bytes from offset 0 to offset 1 (overlapping forward)
    try frame.stack.push(3); // length
    try frame.stack.push(0); // src
    try frame.stack.push(1); // dest
    try memory.McopyInstruction(Frame).run(&frame);

    // Should copy via temp buffer
    try testing.expectEqual(@as(u8, 0x11), frame.readMemory(0)); // Original
    try testing.expectEqual(@as(u8, 0x11), frame.readMemory(1)); // Copied
    try testing.expectEqual(@as(u8, 0x22), frame.readMemory(2)); // Copied
    try testing.expectEqual(@as(u8, 0x33), frame.readMemory(3)); // Copied
}

test "MCOPY: zero-length copy charges gas but does nothing" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    const gas_before = frame.gas_remaining;

    // Copy 0 bytes
    try frame.stack.push(0); // length
    try frame.stack.push(0); // src
    try frame.stack.push(0); // dest
    try memory.McopyInstruction(Frame).run(&frame);

    // Gas should be consumed (even if 0)
    const gas_after = frame.gas_remaining;
    try testing.expect(gas_after <= gas_before);
}

test "MCOPY: fails before Cancun hardfork" {
    const allocator = testing.allocator;
    var frame = try Frame.initFull(
        allocator,
        &[_]u8{},
        1000000,
        Address.zero(),
        Address.zero(),
        0,
        &[_]u8{},
        .LONDON, // Pre-Cancun
    );
    defer frame.deinit(allocator);

    try frame.stack.push(3); // length
    try frame.stack.push(0); // src
    try frame.stack.push(10); // dest

    const result = memory.McopyInstruction(Frame).run(&frame);
    try testing.expectError(error.InvalidOpcode, result);
}

// KECCAK256 opcode (0x20)
test "KECCAK256: hashes empty data" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    // Hash 0 bytes from offset 0
    try frame.stack.push(0); // size
    try frame.stack.push(0); // offset
    try memory.Keccak256Instruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    // Keccak-256("") = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
    const expected: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    try testing.expectEqual(expected, result);
}

test "KECCAK256: hashes single byte" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    // Write 0x00 to memory
    try frame.writeMemory(0, 0x00);

    // Hash 1 byte from offset 0
    try frame.stack.push(1); // size
    try frame.stack.push(0); // offset
    try memory.Keccak256Instruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    // Keccak-256(0x00) = 0xbc36789e7a1e281436464229828f817d6612f7b477d66591ff96a9e064bcc98a
    const expected: u256 = 0xbc36789e7a1e281436464229828f817d6612f7b477d66591ff96a9e064bcc98a;
    try testing.expectEqual(expected, result);
}

test "KECCAK256: hashes multiple bytes" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    // Write "abc" to memory
    try frame.writeMemory(0, 'a');
    try frame.writeMemory(1, 'b');
    try frame.writeMemory(2, 'c');

    // Hash 3 bytes from offset 0
    try frame.stack.push(3); // size
    try frame.stack.push(0); // offset
    try memory.Keccak256Instruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    // Keccak-256("abc") = 0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45
    const expected: u256 = 0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45;
    try testing.expectEqual(expected, result);
}

// Integration: Mixed memory operations
test "Memory: MSTORE then MLOAD" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    const value: u256 = 0xdeadbeefcafebabe;

    // MSTORE
    try frame.stack.push(value);
    try frame.stack.push(0); // offset
    try memory.MstoreInstruction(Frame).run(&frame);

    // MLOAD
    try frame.stack.push(0); // offset
    try memory.MloadInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    try testing.expectEqual(value, result);
}

test "Memory: MSTORE8 sequence then MLOAD" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    // Write bytes individually
    try frame.stack.push(0xaa);
    try frame.stack.push(0);
    try memory.Mstore8Instruction(Frame).run(&frame);

    try frame.stack.push(0xbb);
    try frame.stack.push(1);
    try memory.Mstore8Instruction(Frame).run(&frame);

    try frame.stack.push(0xcc);
    try frame.stack.push(2);
    try memory.Mstore8Instruction(Frame).run(&frame);

    // Read back as word
    try frame.stack.push(0);
    try memory.MloadInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    const expected = (@as(u256, 0xaa) << 248) | (@as(u256, 0xbb) << 240) | (@as(u256, 0xcc) << 232);
    try testing.expectEqual(expected, result);
}

test "Memory: MSTORE, MCOPY, MLOAD" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator);
    defer frame.deinit(allocator);

    const value: u256 = 0x123456789abcdef0;

    // MSTORE at offset 0
    try frame.stack.push(value);
    try frame.stack.push(0);
    try memory.MstoreInstruction(Frame).run(&frame);

    // MCOPY from 0 to 32 (copy 32 bytes)
    try frame.stack.push(32); // length
    try frame.stack.push(0); // src
    try frame.stack.push(32); // dest
    try memory.McopyInstruction(Frame).run(&frame);

    // MLOAD from offset 32
    try frame.stack.push(32);
    try memory.MloadInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    try testing.expectEqual(value, result);
}
