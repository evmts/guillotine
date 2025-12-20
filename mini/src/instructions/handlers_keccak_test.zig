/// Unit tests for Keccak256 (SHA3) opcode handler
const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;
const Hardfork = primitives.Hardfork;
const Address = primitives.Address.Address;
const evm_mod = @import("../evm.zig");
const Evm = evm_mod.Evm(.{});
const Frame = @import("../frame.zig").Frame(.{});

// Helper to create a test EVM instance
fn createTestEvm(allocator: std.mem.Allocator, hardfork: Hardfork) !*Evm {
    const evm = try allocator.create(Evm);
    const block_context = evm_mod.BlockContext{
        .chain_id = 1,
        .block_number = 1,
        .block_timestamp = 1000,
        .block_difficulty = 0,
        .block_prevrandao = 0,
        .block_coinbase = try Address.fromHex("0x0000000000000000000000000000000000000000"),
        .block_gas_limit = 10_000_000,
        .block_base_fee = 1,
        .blob_base_fee = 1,
    };
    evm.* = try Evm.init(allocator, null, hardfork, block_context, null);
    return evm;
}

// Helper to create a test frame
fn createTestFrame(
    allocator: std.mem.Allocator,
    evm: *Evm,
    bytecode: []const u8,
    hardfork: Hardfork,
    gas: i64,
) !Frame {
    const caller = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");
    return try Frame.init(
        allocator,
        bytecode,
        gas,
        caller,
        address,
        0, // value
        &.{}, // calldata
        @ptrCast(evm),
        hardfork,
        false, // is_static
    );
}

// ============================================================================
// KECCAK256 (SHA3) Tests
// ============================================================================

test "KECCAK256: empty data hash" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x20}; // KECCAK256/SHA3
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: hash empty data (offset=0, size=0)
    try frame.pushStack(0); // size
    try frame.pushStack(0); // offset

    const initial_gas = frame.gas_remaining;

    // Execute KECCAK256
    const KeccakHandlers = @import("handlers_keccak.zig").Handlers(@TypeOf(frame));
    try KeccakHandlers.sha3(&frame);

    // Verify result - Keccak-256("") = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    const expected_hash: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    try testing.expectEqual(expected_hash, frame.stack.items[0]);

    // Verify gas consumed: base cost (30) + word cost (0 words * 6) = 30
    const expected_gas = GasConstants.Keccak256Gas; // 30
    try testing.expectEqual(@as(i64, expected_gas), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "KECCAK256: single byte hash" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x20}; // KECCAK256/SHA3
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Write 0xFF to memory at offset 0
    try frame.writeMemory(0, 0xFF);

    // Setup: hash 1 byte at offset 0
    try frame.pushStack(1); // size
    try frame.pushStack(0); // offset

    const initial_gas = frame.gas_remaining;

    // Execute KECCAK256
    const KeccakHandlers = @import("handlers_keccak.zig").Handlers(@TypeOf(frame));
    try KeccakHandlers.sha3(&frame);

    // Verify result on stack
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);

    // Compute expected hash: Keccak-256(0xFF)
    var hash_bytes: [32]u8 = undefined;
    const data = [_]u8{0xFF};
    std.crypto.hash.sha3.Keccak256.hash(&data, &hash_bytes, .{});
    const expected_hash = std.mem.readInt(u256, &hash_bytes, .big);
    try testing.expectEqual(expected_hash, frame.stack.items[0]);

    // Verify gas consumed: base (30) + (1 byte = 1 word rounded up) * 6 = 30 + 6 = 36
    const expected_gas = GasConstants.Keccak256Gas + GasConstants.Keccak256WordGas;
    try testing.expectEqual(@as(i64, expected_gas), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "KECCAK256: 32 bytes (1 word)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x20}; // KECCAK256/SHA3
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Write 32 bytes of data to memory
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        try frame.writeMemory(i, @intCast(i & 0xFF));
    }

    // Setup: hash 32 bytes at offset 0
    try frame.pushStack(32); // size
    try frame.pushStack(0); // offset

    const initial_gas = frame.gas_remaining;

    // Execute KECCAK256
    const KeccakHandlers = @import("handlers_keccak.zig").Handlers(@TypeOf(frame));
    try KeccakHandlers.sha3(&frame);

    // Verify result on stack
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);

    // Compute expected hash
    var data: [32]u8 = undefined;
    i = 0;
    while (i < 32) : (i += 1) {
        data[i] = @intCast(i & 0xFF);
    }
    var hash_bytes: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&data, &hash_bytes, .{});
    const expected_hash = std.mem.readInt(u256, &hash_bytes, .big);
    try testing.expectEqual(expected_hash, frame.stack.items[0]);

    // Verify gas consumed: base (30) + 1 word * 6 = 36
    const expected_gas = GasConstants.Keccak256Gas + GasConstants.Keccak256WordGas;
    try testing.expectEqual(@as(i64, expected_gas), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "KECCAK256: 64 bytes (2 words)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x20}; // KECCAK256/SHA3
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Write 64 bytes of data to memory
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        try frame.writeMemory(i, @intCast(i & 0xFF));
    }

    // Setup: hash 64 bytes at offset 0
    try frame.pushStack(64); // size
    try frame.pushStack(0); // offset

    const initial_gas = frame.gas_remaining;

    // Execute KECCAK256
    const KeccakHandlers = @import("handlers_keccak.zig").Handlers(@TypeOf(frame));
    try KeccakHandlers.sha3(&frame);

    // Verify result on stack
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);

    // Verify gas consumed: base (30) + 2 words * 6 = 42
    const expected_gas = GasConstants.Keccak256Gas + (2 * GasConstants.Keccak256WordGas);
    try testing.expectEqual(@as(i64, expected_gas), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "KECCAK256: 33 bytes (2 words rounded up)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x20}; // KECCAK256/SHA3
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Write 33 bytes of data to memory
    var i: u32 = 0;
    while (i < 33) : (i += 1) {
        try frame.writeMemory(i, 0xAA);
    }

    // Setup: hash 33 bytes at offset 0
    try frame.pushStack(33); // size
    try frame.pushStack(0); // offset

    const initial_gas = frame.gas_remaining;

    // Execute KECCAK256
    const KeccakHandlers = @import("handlers_keccak.zig").Handlers(@TypeOf(frame));
    try KeccakHandlers.sha3(&frame);

    // Verify gas consumed: base (30) + ceil(33/32) * 6 = 30 + 2*6 = 42
    const expected_gas = GasConstants.Keccak256Gas + (2 * GasConstants.Keccak256WordGas);
    try testing.expectEqual(@as(i64, expected_gas), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "KECCAK256: large data (10 words)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x20}; // KECCAK256/SHA3
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Write 320 bytes (10 words) of data to memory
    var i: u32 = 0;
    while (i < 320) : (i += 1) {
        try frame.writeMemory(i, @intCast(i & 0xFF));
    }

    // Setup: hash 320 bytes at offset 0
    try frame.pushStack(320); // size
    try frame.pushStack(0); // offset

    const initial_gas = frame.gas_remaining;

    // Execute KECCAK256
    const KeccakHandlers = @import("handlers_keccak.zig").Handlers(@TypeOf(frame));
    try KeccakHandlers.sha3(&frame);

    // Verify result on stack
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);

    // Verify gas consumed: base (30) + 10 words * 6 = 90
    const expected_gas = GasConstants.Keccak256Gas + (10 * GasConstants.Keccak256WordGas);
    try testing.expectEqual(@as(i64, expected_gas), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "KECCAK256: deterministic output" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x20}; // KECCAK256/SHA3

    // First execution
    var frame1 = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame1.deinit();

    // Write test data
    try frame1.writeMemory(0, 0xDE);
    try frame1.writeMemory(1, 0xAD);
    try frame1.writeMemory(2, 0xBE);
    try frame1.writeMemory(3, 0xEF);

    try frame1.pushStack(4);
    try frame1.pushStack(0);

    const KeccakHandlers = @import("handlers_keccak.zig").Handlers(@TypeOf(frame1));
    try KeccakHandlers.sha3(&frame1);
    const hash1 = frame1.stack.items[0];

    // Second execution with same data
    var frame2 = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame2.deinit();

    try frame2.writeMemory(0, 0xDE);
    try frame2.writeMemory(1, 0xAD);
    try frame2.writeMemory(2, 0xBE);
    try frame2.writeMemory(3, 0xEF);

    try frame2.pushStack(4);
    try frame2.pushStack(0);

    try KeccakHandlers.sha3(&frame2);
    const hash2 = frame2.stack.items[0];

    // Verify hashes are identical
    try testing.expectEqual(hash1, hash2);
}

test "KECCAK256: different data produces different hash" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x20}; // KECCAK256/SHA3

    // First execution
    var frame1 = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame1.deinit();

    try frame1.writeMemory(0, 0xDE);
    try frame1.writeMemory(1, 0xAD);

    try frame1.pushStack(2);
    try frame1.pushStack(0);

    const KeccakHandlers = @import("handlers_keccak.zig").Handlers(@TypeOf(frame1));
    try KeccakHandlers.sha3(&frame1);
    const hash1 = frame1.stack.items[0];

    // Second execution with different data
    var frame2 = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame2.deinit();

    try frame2.writeMemory(0, 0xBE);
    try frame2.writeMemory(1, 0xEF);

    try frame2.pushStack(2);
    try frame2.pushStack(0);

    try KeccakHandlers.sha3(&frame2);
    const hash2 = frame2.stack.items[0];

    // Verify hashes are different
    try testing.expect(hash1 != hash2);
}

test "KECCAK256: non-zero offset" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x20}; // KECCAK256/SHA3
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Write data starting at offset 10
    try frame.writeMemory(10, 0x01);
    try frame.writeMemory(11, 0x02);
    try frame.writeMemory(12, 0x03);

    // Setup: hash 3 bytes at offset 10
    try frame.pushStack(3); // size
    try frame.pushStack(10); // offset

    const initial_gas = frame.gas_remaining;

    // Execute KECCAK256
    const KeccakHandlers = @import("handlers_keccak.zig").Handlers(@TypeOf(frame));
    try KeccakHandlers.sha3(&frame);

    // Verify result on stack
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);

    // Compute expected hash
    const data = [_]u8{ 0x01, 0x02, 0x03 };
    var hash_bytes: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&data, &hash_bytes, .{});
    const expected_hash = std.mem.readInt(u256, &hash_bytes, .big);
    try testing.expectEqual(expected_hash, frame.stack.items[0]);

    // Verify gas consumed: base (30) + 1 word * 6 = 36
    const expected_gas = GasConstants.Keccak256Gas + GasConstants.Keccak256WordGas;
    try testing.expectEqual(@as(i64, expected_gas), initial_gas - frame.gas_remaining);
}

test "KECCAK256: memory expansion cost" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x20}; // KECCAK256/SHA3
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Don't pre-write memory - let KECCAK256 expand it
    // Setup: hash 32 bytes at offset 0
    try frame.pushStack(32); // size
    try frame.pushStack(0); // offset

    const initial_gas = frame.gas_remaining;
    const initial_memory_size = frame.memory_size;

    // Execute KECCAK256
    const KeccakHandlers = @import("handlers_keccak.zig").Handlers(@TypeOf(frame));
    try KeccakHandlers.sha3(&frame);

    // Verify memory expanded
    try testing.expect(frame.memory_size >= 32);

    // Verify gas includes memory expansion cost
    const keccak_base_gas = GasConstants.Keccak256Gas + GasConstants.Keccak256WordGas; // 30 + 6
    const gas_used = initial_gas - frame.gas_remaining;
    try testing.expect(gas_used >= keccak_base_gas);

    // If memory was expanded, we should have paid more than base cost
    if (initial_memory_size < 32) {
        try testing.expect(gas_used > keccak_base_gas);
    }
}

test "KECCAK256: stack underflow on missing offset" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x20}; // KECCAK256/SHA3
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Push only size, missing offset
    try frame.pushStack(10); // offset (but no size)

    // Execute KECCAK256 with insufficient stack
    const KeccakHandlers = @import("handlers_keccak.zig").Handlers(@TypeOf(frame));
    const result = KeccakHandlers.sha3(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "KECCAK256: stack underflow on empty stack" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x20}; // KECCAK256/SHA3
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Empty stack - need 2 values

    // Execute KECCAK256 with insufficient stack
    const KeccakHandlers = @import("handlers_keccak.zig").Handlers(@TypeOf(frame));
    const result = KeccakHandlers.sha3(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "KECCAK256: out of gas on base cost" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x20}; // KECCAK256/SHA3
    // Give less gas than base cost (30)
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 29);
    defer frame.deinit();

    try frame.pushStack(0); // offset
    try frame.pushStack(0); // size

    // Execute KECCAK256 with insufficient gas
    const KeccakHandlers = @import("handlers_keccak.zig").Handlers(@TypeOf(frame));
    const result = KeccakHandlers.sha3(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

test "KECCAK256: out of gas on word cost" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x20}; // KECCAK256/SHA3
    // Give base cost but not enough for word cost (30 + 6*10 = 90 needed)
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 35);
    defer frame.deinit();

    // Setup: hash 320 bytes (10 words)
    try frame.pushStack(320); // size
    try frame.pushStack(0); // offset

    // Execute KECCAK256 with insufficient gas
    const KeccakHandlers = @import("handlers_keccak.zig").Handlers(@TypeOf(frame));
    const result = KeccakHandlers.sha3(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

test "KECCAK256: known value - hello world" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x20}; // KECCAK256/SHA3
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Write "hello" to memory
    const hello = "hello";
    var i: u32 = 0;
    while (i < hello.len) : (i += 1) {
        try frame.writeMemory(i, hello[i]);
    }

    // Setup: hash "hello"
    try frame.pushStack(5); // size
    try frame.pushStack(0); // offset

    // Execute KECCAK256
    const KeccakHandlers = @import("handlers_keccak.zig").Handlers(@TypeOf(frame));
    try KeccakHandlers.sha3(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);

    // Compute expected hash for "hello"
    var hash_bytes: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(hello, &hash_bytes, .{});
    const expected_hash = std.mem.readInt(u256, &hash_bytes, .big);
    try testing.expectEqual(expected_hash, frame.stack.items[0]);
}

test "KECCAK256: PC increment verification" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x20}; // KECCAK256/SHA3
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Initial PC should be 0
    try testing.expectEqual(@as(u32, 0), frame.pc);

    try frame.pushStack(0); // offset
    try frame.pushStack(0); // size

    // Execute KECCAK256
    const KeccakHandlers = @import("handlers_keccak.zig").Handlers(@TypeOf(frame));
    try KeccakHandlers.sha3(&frame);

    // PC should be incremented by 1
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "KECCAK256: all hardforks support" {
    const allocator = testing.allocator;

    // Test that KECCAK256 works across all hardforks
    const hardforks = [_]Hardfork{ .FRONTIER, .HOMESTEAD, .ISTANBUL, .BERLIN, .LONDON, .SHANGHAI, .CANCUN };

    for (hardforks) |hardfork| {
        var evm = try createTestEvm(allocator, hardfork);
        defer {
            evm.deinit();
            allocator.destroy(evm);
        }

        const bytecode = &[_]u8{0x20}; // KECCAK256/SHA3
        var frame = try createTestFrame(allocator, evm, bytecode, hardfork, 1_000_000);
        defer frame.deinit();

        try frame.pushStack(0); // offset
        try frame.pushStack(0); // size

        // Execute KECCAK256
        const KeccakHandlers = @import("handlers_keccak.zig").Handlers(@TypeOf(frame));
        try KeccakHandlers.sha3(&frame);

        // Verify empty hash works in all hardforks
        const expected_hash: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        try testing.expectEqual(expected_hash, frame.stack.items[0]);
    }
}
