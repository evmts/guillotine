/// Unit tests for block context opcode handlers
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
        .block_number = 1000,
        .block_timestamp = 1609459200, // 2021-01-01 00:00:00 UTC
        .block_difficulty = 2000000000000000,
        .block_prevrandao = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef,
        .block_coinbase = try Address.fromHex("0x5a0b54d5dc17e0aadc383d2db43b0a0d3e029c4c"),
        .block_gas_limit = 10_000_000,
        .block_base_fee = 7,
        .blob_base_fee = 1,
        .block_hashes = &[_][32]u8{},
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
    // Set balance for SELFBALANCE tests
    try evm.balances.put(address, 123456789);
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
// BLOCKHASH Tests (0x40)
// ============================================================================

test "BLOCKHASH: happy path - recent block" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    // Create block_hashes array with 256 blocks
    var block_hashes: [256][32]u8 = undefined;
    for (&block_hashes, 0..) |*hash, i| {
        // Fill with test pattern
        @memset(hash, @as(u8, @intCast(i)));
    }
    evm.block_context.block_hashes = &block_hashes;

    const bytecode = &[_]u8{0x40}; // BLOCKHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Request hash for block 999 (current is 1000, so offset 1)
    try frame.pushStack(999);
    const initial_gas = frame.gas_remaining;

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.blockhash(&frame);

    // Verify result is from block_hashes (index 255 = most recent)
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    // Expected: hash filled with 255 (most recent block)
    var expected: u256 = 0;
    for (0..32) |_| {
        expected = (expected << 8) | 255;
    }
    try testing.expectEqual(expected, frame.stack.items[0]);

    // Verify gas consumed (GasExtStep = 20)
    try testing.expectEqual(@as(i64, 20), initial_gas - frame.gas_remaining);
    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "BLOCKHASH: out of range - block too old" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x40}; // BLOCKHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Request block 743 (current is 1000, so diff = 257, beyond 256 limit)
    try frame.pushStack(743);

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.blockhash(&frame);

    // Verify result is 0 (out of range)
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "BLOCKHASH: out of range - future block" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x40}; // BLOCKHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Request block 1000 (current block)
    try frame.pushStack(1000);

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.blockhash(&frame);

    // Verify result is 0 (current or future blocks return 0)
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "BLOCKHASH: out of range - block greater than current" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x40}; // BLOCKHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Request block 1001 (future block)
    try frame.pushStack(1001);

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.blockhash(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "BLOCKHASH: boundary - exactly 256 blocks back" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    // Create block_hashes array
    var block_hashes: [256][32]u8 = undefined;
    for (&block_hashes, 0..) |*hash, i| {
        @memset(hash, @as(u8, @intCast(i)));
    }
    evm.block_context.block_hashes = &block_hashes;

    const bytecode = &[_]u8{0x40}; // BLOCKHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Request block 744 (current is 1000, so diff = 256 - at boundary)
    try frame.pushStack(744);

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.blockhash(&frame);

    // Verify result is from block_hashes[0] (oldest available)
    var expected: u256 = 0;
    for (0..32) |_| {
        expected = (expected << 8) | 0;
    }
    try testing.expectEqual(expected, frame.stack.items[0]);
}

test "BLOCKHASH: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x40}; // BLOCKHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Don't push any values
    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    const result = BlockHandlers.blockhash(&frame);

    try testing.expectError(error.StackUnderflow, result);
}

test "BLOCKHASH: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x40}; // BLOCKHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 19); // Only 19 gas (need 20)
    defer frame.deinit();

    try frame.pushStack(999);

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    const result = BlockHandlers.blockhash(&frame);

    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// COINBASE Tests (0x41)
// ============================================================================

test "COINBASE: happy path" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x41}; // COINBASE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.coinbase(&frame);

    // Verify result matches block_coinbase as u256
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    const expected = Address.toU256(evm.block_context.block_coinbase);
    try testing.expectEqual(expected, frame.stack.items[0]);

    // Verify gas consumed (GasQuickStep = 2)
    try testing.expectEqual(@as(i64, 2), initial_gas - frame.gas_remaining);
    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "COINBASE: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x41}; // COINBASE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1); // Only 1 gas (need 2)
    defer frame.deinit();

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    const result = BlockHandlers.coinbase(&frame);

    try testing.expectError(error.OutOfGas, result);
}

test "COINBASE: works on Shanghai with warm access (EIP-3651)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .SHANGHAI);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x41}; // COINBASE
    var frame = try createTestFrame(allocator, evm, bytecode, .SHANGHAI, 1_000_000);
    defer frame.deinit();

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.coinbase(&frame);

    // Verify result is correct (warm access is tested in access_list tests)
    const expected = Address.toU256(evm.block_context.block_coinbase);
    try testing.expectEqual(expected, frame.stack.items[0]);
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

// ============================================================================
// TIMESTAMP Tests (0x42)
// ============================================================================

test "TIMESTAMP: happy path" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x42}; // TIMESTAMP
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.timestamp(&frame);

    // Verify result matches block_timestamp
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 1609459200), frame.stack.items[0]);

    // Verify gas consumed (GasQuickStep = 2)
    try testing.expectEqual(@as(i64, 2), initial_gas - frame.gas_remaining);
    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "TIMESTAMP: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x42}; // TIMESTAMP
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1); // Only 1 gas (need 2)
    defer frame.deinit();

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    const result = BlockHandlers.timestamp(&frame);

    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// NUMBER Tests (0x43)
// ============================================================================

test "NUMBER: happy path" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x43}; // NUMBER
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.number(&frame);

    // Verify result matches block_number
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 1000), frame.stack.items[0]);

    // Verify gas consumed (GasQuickStep = 2)
    try testing.expectEqual(@as(i64, 2), initial_gas - frame.gas_remaining);
    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "NUMBER: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x43}; // NUMBER
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1); // Only 1 gas (need 2)
    defer frame.deinit();

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    const result = BlockHandlers.number(&frame);

    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// DIFFICULTY/PREVRANDAO Tests (0x44)
// ============================================================================

test "DIFFICULTY: pre-Merge returns block_difficulty" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .LONDON);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x44}; // DIFFICULTY
    var frame = try createTestFrame(allocator, evm, bytecode, .LONDON, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.difficulty(&frame);

    // Verify result is block_difficulty (pre-Merge)
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 2000000000000000), frame.stack.items[0]);

    // Verify gas consumed (GasQuickStep = 2)
    try testing.expectEqual(@as(i64, 2), initial_gas - frame.gas_remaining);
    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "DIFFICULTY: post-Merge returns prevrandao" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .MERGE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x44}; // DIFFICULTY (actually PREVRANDAO post-Merge)
    var frame = try createTestFrame(allocator, evm, bytecode, .MERGE, 1_000_000);
    defer frame.deinit();

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.difficulty(&frame);

    // Verify result is prevrandao (post-Merge)
    try testing.expectEqual(@as(u256, 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef), frame.stack.items[0]);
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "DIFFICULTY: Cancun returns prevrandao" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x44}; // DIFFICULTY (actually PREVRANDAO post-Merge)
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.difficulty(&frame);

    // Verify result is prevrandao (Cancun is post-Merge)
    try testing.expectEqual(@as(u256, 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef), frame.stack.items[0]);
}

test "DIFFICULTY: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x44}; // DIFFICULTY
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1); // Only 1 gas (need 2)
    defer frame.deinit();

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    const result = BlockHandlers.difficulty(&frame);

    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// GASLIMIT Tests (0x45)
// ============================================================================

test "GASLIMIT: happy path" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x45}; // GASLIMIT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.gaslimit(&frame);

    // Verify result matches block_gas_limit
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 10_000_000), frame.stack.items[0]);

    // Verify gas consumed (GasQuickStep = 2)
    try testing.expectEqual(@as(i64, 2), initial_gas - frame.gas_remaining);
    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "GASLIMIT: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x45}; // GASLIMIT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1); // Only 1 gas (need 2)
    defer frame.deinit();

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    const result = BlockHandlers.gaslimit(&frame);

    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// CHAINID Tests (0x46) - EIP-1344, Istanbul+
// ============================================================================

test "CHAINID: happy path on Istanbul+" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .ISTANBUL);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x46}; // CHAINID
    var frame = try createTestFrame(allocator, evm, bytecode, .ISTANBUL, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.chainid(&frame);

    // Verify result matches chain_id
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);

    // Verify gas consumed (GasQuickStep = 2)
    try testing.expectEqual(@as(i64, 2), initial_gas - frame.gas_remaining);
    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "CHAINID: works on Cancun" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x46}; // CHAINID
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.chainid(&frame);

    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);
}

test "CHAINID: invalid opcode before Istanbul" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x46}; // CHAINID
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    const result = BlockHandlers.chainid(&frame);

    try testing.expectError(error.InvalidOpcode, result);
}

test "CHAINID: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .ISTANBUL);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x46}; // CHAINID
    var frame = try createTestFrame(allocator, evm, bytecode, .ISTANBUL, 1); // Only 1 gas (need 2)
    defer frame.deinit();

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    const result = BlockHandlers.chainid(&frame);

    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// SELFBALANCE Tests (0x47) - EIP-1884, Istanbul+
// ============================================================================

test "SELFBALANCE: happy path on Istanbul+" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .ISTANBUL);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x47}; // SELFBALANCE
    var frame = try createTestFrame(allocator, evm, bytecode, .ISTANBUL, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.selfbalance(&frame);

    // Verify result matches balance of current address
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 123456789), frame.stack.items[0]);

    // Verify gas consumed (GasFastStep = 5)
    try testing.expectEqual(@as(i64, 5), initial_gas - frame.gas_remaining);
    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "SELFBALANCE: works on Cancun" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x47}; // SELFBALANCE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.selfbalance(&frame);

    try testing.expectEqual(@as(u256, 123456789), frame.stack.items[0]);
}

test "SELFBALANCE: zero balance" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .ISTANBUL);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x47}; // SELFBALANCE
    var frame = try createTestFrame(allocator, evm, bytecode, .ISTANBUL, 1_000_000);
    defer frame.deinit();

    // Override balance to 0
    try evm.balances.put(frame.address, 0);

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.selfbalance(&frame);

    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "SELFBALANCE: invalid opcode before Istanbul" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x47}; // SELFBALANCE
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    const result = BlockHandlers.selfbalance(&frame);

    try testing.expectError(error.InvalidOpcode, result);
}

test "SELFBALANCE: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .ISTANBUL);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x47}; // SELFBALANCE
    var frame = try createTestFrame(allocator, evm, bytecode, .ISTANBUL, 4); // Only 4 gas (need 5)
    defer frame.deinit();

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    const result = BlockHandlers.selfbalance(&frame);

    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// BASEFEE Tests (0x48) - EIP-3198, London+
// ============================================================================

test "BASEFEE: happy path on London+" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .LONDON);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x48}; // BASEFEE
    var frame = try createTestFrame(allocator, evm, bytecode, .LONDON, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.basefee(&frame);

    // Verify result matches block_base_fee
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 7), frame.stack.items[0]);

    // Verify gas consumed (GasQuickStep = 2)
    try testing.expectEqual(@as(i64, 2), initial_gas - frame.gas_remaining);
    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "BASEFEE: works on Cancun" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x48}; // BASEFEE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.basefee(&frame);

    try testing.expectEqual(@as(u256, 7), frame.stack.items[0]);
}

test "BASEFEE: invalid opcode before London" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BERLIN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x48}; // BASEFEE
    var frame = try createTestFrame(allocator, evm, bytecode, .BERLIN, 1_000_000);
    defer frame.deinit();

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    const result = BlockHandlers.basefee(&frame);

    try testing.expectError(error.InvalidOpcode, result);
}

test "BASEFEE: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .LONDON);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x48}; // BASEFEE
    var frame = try createTestFrame(allocator, evm, bytecode, .LONDON, 1); // Only 1 gas (need 2)
    defer frame.deinit();

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    const result = BlockHandlers.basefee(&frame);

    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// BLOBHASH Tests (0x49) - EIP-4844, Cancun+
// ============================================================================

test "BLOBHASH: happy path - valid index" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    // Set up blob versioned hashes
    var blob_hashes: [3][32]u8 = undefined;
    for (&blob_hashes, 0..) |*hash, i| {
        @memset(hash, @as(u8, @intCast(i + 1)));
    }
    evm.blob_versioned_hashes = &blob_hashes;

    const bytecode = &[_]u8{0x49}; // BLOBHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Request blob hash at index 1
    try frame.pushStack(1);
    const initial_gas = frame.gas_remaining;

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.blobhash(&frame);

    // Verify result is blob hash at index 1 (filled with 2s)
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    var expected: u256 = 0;
    for (0..32) |_| {
        expected = (expected << 8) | 2;
    }
    try testing.expectEqual(expected, frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);
    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "BLOBHASH: index 0" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    var blob_hashes: [3][32]u8 = undefined;
    for (&blob_hashes, 0..) |*hash, i| {
        @memset(hash, @as(u8, @intCast(i + 10)));
    }
    evm.blob_versioned_hashes = &blob_hashes;

    const bytecode = &[_]u8{0x49}; // BLOBHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    try frame.pushStack(0);

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.blobhash(&frame);

    // Verify result is blob hash at index 0 (filled with 10s)
    var expected: u256 = 0;
    for (0..32) |_| {
        expected = (expected << 8) | 10;
    }
    try testing.expectEqual(expected, frame.stack.items[0]);
}

test "BLOBHASH: out of bounds returns zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    var blob_hashes: [3][32]u8 = undefined;
    for (&blob_hashes, 0..) |*hash, i| {
        @memset(hash, @as(u8, @intCast(i + 1)));
    }
    evm.blob_versioned_hashes = &blob_hashes;

    const bytecode = &[_]u8{0x49}; // BLOBHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Request index 3 (out of bounds)
    try frame.pushStack(3);

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.blobhash(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "BLOBHASH: no blob hashes returns zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    // No blob hashes set (empty slice)
    const bytecode = &[_]u8{0x49}; // BLOBHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    try frame.pushStack(0);

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.blobhash(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "BLOBHASH: very large index returns zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    var blob_hashes: [3][32]u8 = undefined;
    for (&blob_hashes, 0..) |*hash, i| {
        @memset(hash, @as(u8, @intCast(i + 1)));
    }
    evm.blob_versioned_hashes = &blob_hashes;

    const bytecode = &[_]u8{0x49}; // BLOBHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Request very large index (beyond usize range)
    try frame.pushStack(std.math.maxInt(u256));

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.blobhash(&frame);

    // Verify result is 0 (index too large to cast to usize)
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "BLOBHASH: invalid opcode before Cancun" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .SHANGHAI);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x49}; // BLOBHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .SHANGHAI, 1_000_000);
    defer frame.deinit();

    try frame.pushStack(0);

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    const result = BlockHandlers.blobhash(&frame);

    try testing.expectError(error.InvalidOpcode, result);
}

test "BLOBHASH: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x49}; // BLOBHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Don't push any values
    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    const result = BlockHandlers.blobhash(&frame);

    try testing.expectError(error.StackUnderflow, result);
}

test "BLOBHASH: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x49}; // BLOBHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 2); // Only 2 gas (need 3)
    defer frame.deinit();

    try frame.pushStack(0);

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    const result = BlockHandlers.blobhash(&frame);

    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// BLOBBASEFEE Tests (0x4a) - EIP-7516, Cancun+
// ============================================================================

test "BLOBBASEFEE: happy path on Cancun+" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x4a}; // BLOBBASEFEE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    try BlockHandlers.blobbasefee(&frame);

    // Verify result matches blob_base_fee
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);

    // Verify gas consumed (GasQuickStep = 2)
    try testing.expectEqual(@as(i64, 2), initial_gas - frame.gas_remaining);
    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "BLOBBASEFEE: invalid opcode before Cancun" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .SHANGHAI);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x4a}; // BLOBBASEFEE
    var frame = try createTestFrame(allocator, evm, bytecode, .SHANGHAI, 1_000_000);
    defer frame.deinit();

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    const result = BlockHandlers.blobbasefee(&frame);

    try testing.expectError(error.InvalidOpcode, result);
}

test "BLOBBASEFEE: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x4a}; // BLOBBASEFEE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1); // Only 1 gas (need 2)
    defer frame.deinit();

    const BlockHandlers = @import("handlers_block.zig").Handlers(@TypeOf(frame));
    const result = BlockHandlers.blobbasefee(&frame);

    try testing.expectError(error.OutOfGas, result);
}
