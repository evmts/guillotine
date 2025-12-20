/// Unit tests for storage opcode handlers (SLOAD, SSTORE, TLOAD, TSTORE)
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
    is_static: bool,
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
        is_static,
    );
}

// ============================================================================
// SLOAD Tests
// ============================================================================

test "SLOAD: basic load from storage" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x54}; // SLOAD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Setup: Set storage slot 0 to value 42
    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");
    try evm.storage.set(address, 0, 42);

    // Push key onto stack
    try frame.pushStack(0);

    const initial_gas = frame.gas_remaining;

    // Execute SLOAD
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.sload(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 42), frame.stack.items[0]);

    // Verify gas consumed (cold access = 2100 in Cancun)
    try testing.expectEqual(@as(i64, 2100), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "SLOAD: read empty slot returns zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x54}; // SLOAD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Push key onto stack (slot not set, should return 0)
    try frame.pushStack(123);

    // Execute SLOAD
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.sload(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "SLOAD: cold access cost (Berlin+)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BERLIN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x54}; // SLOAD
    var frame = try createTestFrame(allocator, evm, bytecode, .BERLIN, 1_000_000, false);
    defer frame.deinit();

    try frame.pushStack(0);
    const initial_gas = frame.gas_remaining;

    // Execute SLOAD (first access = cold)
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.sload(&frame);

    // Verify cold access cost (2100 gas)
    try testing.expectEqual(@as(i64, GasConstants.ColdSloadCost), initial_gas - frame.gas_remaining);
}

test "SLOAD: warm access cost (Berlin+)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BERLIN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x54}; // SLOAD
    var frame = try createTestFrame(allocator, evm, bytecode, .BERLIN, 1_000_000, false);
    defer frame.deinit();

    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");

    // First access to warm the slot
    _ = try evm.accessStorageSlot(address, 0);

    try frame.pushStack(0);
    const initial_gas = frame.gas_remaining;

    // Execute SLOAD (second access = warm)
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.sload(&frame);

    // Verify warm access cost (100 gas)
    try testing.expectEqual(@as(i64, GasConstants.WarmStorageReadCost), initial_gas - frame.gas_remaining);
}

test "SLOAD: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x54}; // SLOAD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // No stack items (need 1)

    // Execute SLOAD with empty stack
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    const result = StorageHandlers.sload(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "SLOAD: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x54}; // SLOAD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 100, false); // Only 100 gas
    defer frame.deinit();

    try frame.pushStack(0);

    // Execute SLOAD with insufficient gas (need 2100, have 100)
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    const result = StorageHandlers.sload(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// SSTORE Tests
// ============================================================================

test "SSTORE: basic store to storage" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x55}; // SSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Setup: key=0, value=42
    try frame.pushStack(0); // key
    try frame.pushStack(42); // value

    const initial_gas = frame.gas_remaining;

    // Execute SSTORE
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.sstore(&frame);

    // Verify storage was updated
    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");
    const stored_value = try evm.storage.get(address, 0);
    try testing.expectEqual(@as(u256, 42), stored_value);

    // Verify gas consumed (cold + set: 2100 + 20000 = 22100 in Cancun)
    const expected_gas = GasConstants.ColdSloadCost + GasConstants.SstoreSetGas;
    try testing.expectEqual(@as(i64, expected_gas), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "SSTORE: static call violation" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x55}; // SSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, true); // is_static=true
    defer frame.deinit();

    try frame.pushStack(0); // key
    try frame.pushStack(42); // value

    // Execute SSTORE in static context
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    const result = StorageHandlers.sstore(&frame);

    // Verify error
    try testing.expectError(error.StaticCallViolation, result);
}

test "SSTORE: sentry gas check (Istanbul+)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .ISTANBUL);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x55}; // SSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .ISTANBUL, 2300, false); // Exactly 2300 gas
    defer frame.deinit();

    try frame.pushStack(0); // key
    try frame.pushStack(42); // value

    // Execute SSTORE with exactly 2300 gas (should fail, needs > 2300)
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    const result = StorageHandlers.sstore(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

test "SSTORE: sentry gas check passes with sufficient gas" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .ISTANBUL);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x55}; // SSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .ISTANBUL, 1_000_000, false);
    defer frame.deinit();

    try frame.pushStack(0); // key
    try frame.pushStack(42); // value

    // Execute SSTORE with sufficient gas (should succeed)
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.sstore(&frame);

    // Verify storage was updated
    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");
    const stored_value = try evm.storage.get(address, 0);
    try testing.expectEqual(@as(u256, 42), stored_value);
}

test "SSTORE: cold storage access (Berlin+)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BERLIN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x55}; // SSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .BERLIN, 1_000_000, false);
    defer frame.deinit();

    try frame.pushStack(0); // key
    try frame.pushStack(42); // value (0 -> non-zero = SET)

    const initial_gas = frame.gas_remaining;

    // Execute SSTORE (cold access)
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.sstore(&frame);

    // Verify gas cost includes cold access
    // Berlin+: cold (2100) + set (20000 - 2100) = 20000 total
    const gas_used = initial_gas - frame.gas_remaining;
    try testing.expect(gas_used >= GasConstants.ColdSloadCost);
}

test "SSTORE: warm storage access (Berlin+)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BERLIN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x55}; // SSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .BERLIN, 1_000_000, false);
    defer frame.deinit();

    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");

    // Pre-warm the storage slot
    _ = try evm.accessStorageSlot(address, 0);

    // Set initial value
    try evm.storage.set(address, 0, 10);

    try frame.pushStack(0); // key
    try frame.pushStack(20); // value (10 -> 20 = UPDATE, warm)

    const initial_gas = frame.gas_remaining;

    // Execute SSTORE (warm access)
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.sstore(&frame);

    // Verify gas cost is less than cold (warm update)
    const gas_used = initial_gas - frame.gas_remaining;
    try testing.expect(gas_used < GasConstants.ColdSloadCost + GasConstants.SstoreSetGas);
}

test "SSTORE: original storage tracking" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x55}; // SSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");

    // Set initial storage value
    try evm.storage.set(address, 0, 100);

    // First SSTORE: should track original value (100)
    try frame.pushStack(0); // key
    try frame.pushStack(200); // value

    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.sstore(&frame);

    // Verify original value is tracked
    const original = evm.storage.getOriginal(address, 0);
    try testing.expectEqual(@as(u256, 100), original);

    // Verify current value is updated
    const current = try evm.storage.get(address, 0);
    try testing.expectEqual(@as(u256, 200), current);
}

test "SSTORE: set zero to non-zero (SET operation)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x55}; // SSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Storage slot starts at 0, set to non-zero (SET)
    try frame.pushStack(5); // key
    try frame.pushStack(99); // value (0 -> 99 = SET)

    const initial_gas = frame.gas_remaining;

    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.sstore(&frame);

    // Verify gas includes SET cost (20000)
    const gas_used = initial_gas - frame.gas_remaining;
    try testing.expect(gas_used >= GasConstants.SstoreSetGas);
}

test "SSTORE: update non-zero to non-zero (UPDATE operation)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x55}; // SSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");

    // Set initial non-zero value
    try evm.storage.set(address, 5, 100);

    try frame.pushStack(5); // key
    try frame.pushStack(200); // value (100 -> 200 = UPDATE)

    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.sstore(&frame);

    // Verify storage was updated
    const current = try evm.storage.get(address, 5);
    try testing.expectEqual(@as(u256, 200), current);
}

test "SSTORE: clear storage (non-zero to zero)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x55}; // SSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");

    // Set initial non-zero value
    try evm.storage.set(address, 7, 500);

    const initial_refund = evm.gas_refund;

    try frame.pushStack(7); // key
    try frame.pushStack(0); // value (500 -> 0 = CLEAR)

    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.sstore(&frame);

    // Verify storage was cleared
    const current = try evm.storage.get(address, 7);
    try testing.expectEqual(@as(u256, 0), current);

    // Verify refund was added (EIP-3529: 4800 gas refund for clearing)
    try testing.expect(evm.gas_refund > initial_refund);
}

test "SSTORE: refund calculation (London+)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .LONDON);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x55}; // SSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .LONDON, 1_000_000, false);
    defer frame.deinit();

    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");

    // Set initial value
    try evm.storage.set(address, 0, 100);

    const initial_refund = evm.gas_refund;

    // Clear storage (100 -> 0)
    try frame.pushStack(0); // key
    try frame.pushStack(0); // value

    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.sstore(&frame);

    // Verify refund was added (EIP-3529: 4800 for clearing)
    const refund_delta = evm.gas_refund - initial_refund;
    try testing.expectEqual(@as(u64, GasConstants.SstoreRefundGas), refund_delta);
}

test "SSTORE: restore to original value refund (London+)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .LONDON);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x55}; // SSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .LONDON, 1_000_000, false);
    defer frame.deinit();

    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");

    // Set original value
    try evm.storage.set(address, 0, 50);

    // First SSTORE: change to different value
    {
        var frame1 = try createTestFrame(allocator, evm, bytecode, .LONDON, 1_000_000, false);
        defer frame1.deinit();
        try frame1.pushStack(0); // key
        try frame1.pushStack(100); // value (50 -> 100)

        const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame1));
        try StorageHandlers.sstore(&frame1);
    }

    const initial_refund = evm.gas_refund;

    // Second SSTORE: restore to original value (100 -> 50)
    try frame.pushStack(0); // key
    try frame.pushStack(50); // value (restore to original)

    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.sstore(&frame);

    // Verify refund was added for restoring to original
    const refund_delta = evm.gas_refund - initial_refund;
    // London+: refund for restoring to original non-zero value
    const expected_refund = GasConstants.SstoreResetGas - GasConstants.ColdSloadCost - GasConstants.WarmStorageReadCost;
    try testing.expectEqual(@as(u64, expected_refund), refund_delta);
}

test "SSTORE: pre-Istanbul simple gas rules" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x55}; // SSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000, false);
    defer frame.deinit();

    // Pre-Istanbul: 0 -> non-zero = 20000, otherwise 5000
    try frame.pushStack(0); // key
    try frame.pushStack(42); // value (0 -> 42 = SET)

    const initial_gas = frame.gas_remaining;

    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.sstore(&frame);

    // Verify SET gas cost (20000)
    const gas_used = initial_gas - frame.gas_remaining;
    try testing.expectEqual(@as(i64, GasConstants.SstoreSetGas), gas_used);
}

test "SSTORE: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x55}; // SSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Only push 1 value (need 2: key + value)
    try frame.pushStack(0);

    // Execute SSTORE with insufficient stack
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    const result = StorageHandlers.sstore(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// TLOAD Tests (EIP-1153, Cancun+)
// ============================================================================

test "TLOAD: basic load from transient storage" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5c}; // TLOAD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Setup: Set transient storage slot 0 to value 99
    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");
    try evm.storage.setTransient(address, 0, 99);

    // Push key onto stack
    try frame.pushStack(0);

    const initial_gas = frame.gas_remaining;

    // Execute TLOAD
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.tload(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 99), frame.stack.items[0]);

    // Verify gas consumed (always warm: 100 gas)
    try testing.expectEqual(@as(i64, GasConstants.TLoadGas), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "TLOAD: read empty slot returns zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5c}; // TLOAD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Push key for unset slot
    try frame.pushStack(999);

    // Execute TLOAD
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.tload(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "TLOAD: invalid before Cancun" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .SHANGHAI);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5c}; // TLOAD
    var frame = try createTestFrame(allocator, evm, bytecode, .SHANGHAI, 1_000_000, false);
    defer frame.deinit();

    try frame.pushStack(0);

    // Execute TLOAD before Cancun
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    const result = StorageHandlers.tload(&frame);

    // Verify error
    try testing.expectError(error.InvalidOpcode, result);
}

test "TLOAD: always warm access cost" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5c}; // TLOAD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    try frame.pushStack(12345);

    const initial_gas = frame.gas_remaining;

    // Execute TLOAD (always warm, never cold)
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.tload(&frame);

    // Verify warm cost (100 gas, not 2100)
    try testing.expectEqual(@as(i64, GasConstants.TLoadGas), initial_gas - frame.gas_remaining);
    try testing.expectEqual(@as(i64, 100), initial_gas - frame.gas_remaining);
}

test "TLOAD: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5c}; // TLOAD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // No stack items (need 1)

    // Execute TLOAD with empty stack
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    const result = StorageHandlers.tload(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "TLOAD: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5c}; // TLOAD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 50, false); // Only 50 gas
    defer frame.deinit();

    try frame.pushStack(0);

    // Execute TLOAD with insufficient gas (need 100, have 50)
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    const result = StorageHandlers.tload(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// TSTORE Tests (EIP-1153, Cancun+)
// ============================================================================

test "TSTORE: basic store to transient storage" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5d}; // TSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Setup: key=5, value=123
    try frame.pushStack(5); // key
    try frame.pushStack(123); // value

    const initial_gas = frame.gas_remaining;

    // Execute TSTORE
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.tstore(&frame);

    // Verify transient storage was updated
    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");
    const stored_value = evm.storage.getTransient(address, 5);
    try testing.expectEqual(@as(u256, 123), stored_value);

    // Verify gas consumed (always warm: 100 gas)
    try testing.expectEqual(@as(i64, GasConstants.TStoreGas), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "TSTORE: static call violation" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5d}; // TSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, true); // is_static=true
    defer frame.deinit();

    try frame.pushStack(0); // key
    try frame.pushStack(42); // value

    // Execute TSTORE in static context
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    const result = StorageHandlers.tstore(&frame);

    // Verify error
    try testing.expectError(error.StaticCallViolation, result);
}

test "TSTORE: invalid before Cancun" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .SHANGHAI);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5d}; // TSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .SHANGHAI, 1_000_000, false);
    defer frame.deinit();

    try frame.pushStack(0); // key
    try frame.pushStack(42); // value

    // Execute TSTORE before Cancun
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    const result = StorageHandlers.tstore(&frame);

    // Verify error
    try testing.expectError(error.InvalidOpcode, result);
}

test "TSTORE: always warm access cost" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5d}; // TSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    try frame.pushStack(999); // key
    try frame.pushStack(888); // value

    const initial_gas = frame.gas_remaining;

    // Execute TSTORE (always warm, never cold)
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.tstore(&frame);

    // Verify warm cost (100 gas, not 2100)
    try testing.expectEqual(@as(i64, GasConstants.TStoreGas), initial_gas - frame.gas_remaining);
    try testing.expectEqual(@as(i64, 100), initial_gas - frame.gas_remaining);
}

test "TSTORE: no refunds" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5d}; // TSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");

    // Set initial transient value
    try evm.storage.setTransient(address, 0, 100);

    const initial_refund = evm.gas_refund;

    // Clear transient storage (100 -> 0)
    try frame.pushStack(0); // key
    try frame.pushStack(0); // value

    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.tstore(&frame);

    // Verify NO refund was added (transient storage doesn't give refunds)
    try testing.expectEqual(initial_refund, evm.gas_refund);
}

test "TSTORE: overwrite existing value" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5d}; // TSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");

    // Set initial transient value
    try evm.storage.setTransient(address, 7, 500);

    // Overwrite with new value
    try frame.pushStack(7); // key
    try frame.pushStack(999); // new value

    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    try StorageHandlers.tstore(&frame);

    // Verify transient storage was updated
    const stored_value = evm.storage.getTransient(address, 7);
    try testing.expectEqual(@as(u256, 999), stored_value);
}

test "TSTORE: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5d}; // TSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Only push 1 value (need 2: key + value)
    try frame.pushStack(0);

    // Execute TSTORE with insufficient stack
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    const result = StorageHandlers.tstore(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "TSTORE: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5d}; // TSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 50, false); // Only 50 gas
    defer frame.deinit();

    try frame.pushStack(0); // key
    try frame.pushStack(42); // value

    // Execute TSTORE with insufficient gas (need 100, have 50)
    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame));
    const result = StorageHandlers.tstore(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// Cross-opcode Integration Tests
// ============================================================================

test "SLOAD/SSTORE: round-trip storage" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{ 0x55, 0x54 }; // SSTORE, SLOAD
    var frame1 = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame1.deinit();

    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame1));

    // SSTORE: key=10, value=777
    try frame1.pushStack(10);
    try frame1.pushStack(777);
    try StorageHandlers.sstore(&frame1);

    // SLOAD: key=10
    var frame2 = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame2.deinit();
    try frame2.pushStack(10);
    try StorageHandlers.sload(&frame2);

    // Verify round-trip
    try testing.expectEqual(@as(u256, 777), frame2.stack.items[0]);
}

test "TLOAD/TSTORE: round-trip transient storage" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{ 0x5d, 0x5c }; // TSTORE, TLOAD
    var frame1 = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame1.deinit();

    const StorageHandlers = @import("handlers_storage.zig").Handlers(@TypeOf(frame1));

    // TSTORE: key=20, value=555
    try frame1.pushStack(20);
    try frame1.pushStack(555);
    try StorageHandlers.tstore(&frame1);

    // TLOAD: key=20
    var frame2 = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame2.deinit();
    try frame2.pushStack(20);
    try StorageHandlers.tload(&frame2);

    // Verify round-trip
    try testing.expectEqual(@as(u256, 555), frame2.stack.items[0]);
}

test "SSTORE/TSTORE: persistent vs transient isolation" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{ 0x55, 0x5d, 0x54, 0x5c }; // SSTORE, TSTORE, SLOAD, TLOAD
    const StorageHandlers = @import("handlers_storage.zig").Handlers(Frame);

    // SSTORE: key=0, value=100 (persistent)
    var frame1 = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame1.deinit();
    try frame1.pushStack(0);
    try frame1.pushStack(100);
    try StorageHandlers.sstore(&frame1);

    // TSTORE: key=0, value=200 (transient, same key)
    var frame2 = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame2.deinit();
    try frame2.pushStack(0);
    try frame2.pushStack(200);
    try StorageHandlers.tstore(&frame2);

    // SLOAD: key=0 (should get persistent value)
    var frame3 = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame3.deinit();
    try frame3.pushStack(0);
    try StorageHandlers.sload(&frame3);
    try testing.expectEqual(@as(u256, 100), frame3.stack.items[0]);

    // TLOAD: key=0 (should get transient value)
    var frame4 = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame4.deinit();
    try frame4.pushStack(0);
    try StorageHandlers.tload(&frame4);
    try testing.expectEqual(@as(u256, 200), frame4.stack.items[0]);
}
