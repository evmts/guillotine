/// Unit tests for log opcode handlers (LOG0-LOG4)
const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;
const Hardfork = primitives.Hardfork;
const Address = primitives.Address.Address;
const evm_mod = @import("../evm.zig");
const Evm = evm_mod.Evm(.{});
const Frame = @import("../frame.zig").Frame(.{});
const call_result = @import("../call_result.zig");

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
// LOG0 Tests
// ============================================================================

test "LOG0: basic log with data" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xa0}; // LOG0
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Write "Hello" to memory at offset 0
    const hello = "Hello";
    for (hello, 0..) |byte, i| {
        try frame.writeMemory(@intCast(i), byte);
    }

    // Setup: offset=0, length=5
    try frame.pushStack(5); // length
    try frame.pushStack(0); // offset

    const initial_gas = frame.gas_remaining;
    const initial_logs = evm.logs.items.len;

    // Execute LOG0
    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));
    try LogHandlers.log(&frame, 0xa0);

    // Verify gas consumed: 375 (base) + 0 (topics) + 8*5 (data) = 415
    const expected_gas_cost = GasConstants.LogGas + (5 * GasConstants.LogDataGas);
    try testing.expectEqual(@as(i64, expected_gas_cost), initial_gas - frame.gas_remaining);

    // Verify log was created
    try testing.expectEqual(initial_logs + 1, evm.logs.items.len);
    const log = evm.logs.items[initial_logs];
    try testing.expectEqual(@as(usize, 0), log.topics.len);
    try testing.expectEqual(@as(usize, 5), log.data.len);
    try testing.expectEqualSlices(u8, hello, log.data);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "LOG0: zero-size log" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xa0}; // LOG0
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Setup: offset=0, length=0
    try frame.pushStack(0); // length
    try frame.pushStack(0); // offset

    const initial_gas = frame.gas_remaining;
    const initial_logs = evm.logs.items.len;

    // Execute LOG0
    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));
    try LogHandlers.log(&frame, 0xa0);

    // Verify gas consumed: 375 (base only, no data cost, no memory expansion)
    try testing.expectEqual(@as(i64, GasConstants.LogGas), initial_gas - frame.gas_remaining);

    // Verify log was created with empty data
    try testing.expectEqual(initial_logs + 1, evm.logs.items.len);
    const log = evm.logs.items[initial_logs];
    try testing.expectEqual(@as(usize, 0), log.topics.len);
    try testing.expectEqual(@as(usize, 0), log.data.len);
}

test "LOG0: memory expansion cost" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xa0}; // LOG0
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Setup: offset=0, length=100 (will expand memory)
    try frame.pushStack(100); // length
    try frame.pushStack(0); // offset

    const initial_gas = frame.gas_remaining;
    const initial_memory_size = frame.memory_size;

    // Execute LOG0
    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));
    try LogHandlers.log(&frame, 0xa0);

    // Verify memory was expanded (100 bytes = 4 words, rounds to 128 bytes)
    try testing.expect(frame.memory_size > initial_memory_size);
    try testing.expectEqual(@as(u32, 128), frame.memory_size);

    // Verify gas includes memory expansion cost
    const log_cost = GasConstants.LogGas + (100 * GasConstants.LogDataGas);
    const total_consumed = initial_gas - frame.gas_remaining;
    try testing.expect(total_consumed > log_cost); // Should include memory expansion
}

test "LOG0: static call restriction" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xa0}; // LOG0
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, true); // is_static = true
    defer frame.deinit();

    // Setup
    try frame.pushStack(0); // length
    try frame.pushStack(0); // offset

    // Execute LOG0 in static context should fail
    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));
    const result = LogHandlers.log(&frame, 0xa0);

    try testing.expectError(error.StaticCallViolation, result);
}

test "LOG0: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xa0}; // LOG0
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Only push 1 value (need 2: offset and length)
    try frame.pushStack(0);

    // Execute LOG0 with insufficient stack
    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));
    const result = LogHandlers.log(&frame, 0xa0);

    try testing.expectError(error.StackUnderflow, result);
}

test "LOG0: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xa0}; // LOG0
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 100, false); // Low gas
    defer frame.deinit();

    // Setup
    try frame.pushStack(0); // length
    try frame.pushStack(0); // offset

    // Execute LOG0 with insufficient gas (need 375, have 100)
    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));
    const result = LogHandlers.log(&frame, 0xa0);

    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// LOG1 Tests
// ============================================================================

test "LOG1: basic log with one topic" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xa1}; // LOG1
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Write data to memory
    const data = "Test";
    for (data, 0..) |byte, i| {
        try frame.writeMemory(@intCast(i), byte);
    }

    // Setup: offset=0, length=4, topic1=0xDEADBEEF
    try frame.pushStack(0xDEADBEEF); // topic1
    try frame.pushStack(4); // length
    try frame.pushStack(0); // offset

    const initial_gas = frame.gas_remaining;
    const initial_logs = evm.logs.items.len;

    // Execute LOG1
    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));
    try LogHandlers.log(&frame, 0xa1);

    // Verify gas consumed: 375 (base) + 375*1 (1 topic) + 8*4 (data) = 782
    const expected_gas_cost = GasConstants.LogGas + GasConstants.LogTopicGas + (4 * GasConstants.LogDataGas);
    try testing.expectEqual(@as(i64, expected_gas_cost), initial_gas - frame.gas_remaining);

    // Verify log was created with 1 topic
    try testing.expectEqual(initial_logs + 1, evm.logs.items.len);
    const log = evm.logs.items[initial_logs];
    try testing.expectEqual(@as(usize, 1), log.topics.len);
    try testing.expectEqual(@as(u256, 0xDEADBEEF), log.topics[0]);
    try testing.expectEqual(@as(usize, 4), log.data.len);
    try testing.expectEqualSlices(u8, data, log.data);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "LOG1: topic count validation" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xa1}; // LOG1
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Setup
    try frame.pushStack(0x123456); // topic1
    try frame.pushStack(0); // length
    try frame.pushStack(0); // offset

    const initial_logs = evm.logs.items.len;

    // Execute LOG1
    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));
    try LogHandlers.log(&frame, 0xa1);

    // Verify exactly 1 topic
    try testing.expectEqual(initial_logs + 1, evm.logs.items.len);
    const log = evm.logs.items[initial_logs];
    try testing.expectEqual(@as(usize, 1), log.topics.len);
}

test "LOG1: stack underflow on topics" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xa1}; // LOG1
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Only push offset and length (missing topic)
    try frame.pushStack(0); // length
    try frame.pushStack(0); // offset

    // Execute LOG1 with insufficient stack (need 3 items)
    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));
    const result = LogHandlers.log(&frame, 0xa1);

    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// LOG2 Tests
// ============================================================================

test "LOG2: basic log with two topics" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xa2}; // LOG2
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Setup: offset=0, length=0, topic1=0xAAA, topic2=0xBBB
    try frame.pushStack(0xBBB); // topic2
    try frame.pushStack(0xAAA); // topic1
    try frame.pushStack(0); // length
    try frame.pushStack(0); // offset

    const initial_gas = frame.gas_remaining;
    const initial_logs = evm.logs.items.len;

    // Execute LOG2
    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));
    try LogHandlers.log(&frame, 0xa2);

    // Verify gas consumed: 375 (base) + 375*2 (2 topics) + 0 (no data) = 1125
    const expected_gas_cost = GasConstants.LogGas + (2 * GasConstants.LogTopicGas);
    try testing.expectEqual(@as(i64, expected_gas_cost), initial_gas - frame.gas_remaining);

    // Verify log was created with 2 topics in correct order
    try testing.expectEqual(initial_logs + 1, evm.logs.items.len);
    const log = evm.logs.items[initial_logs];
    try testing.expectEqual(@as(usize, 2), log.topics.len);
    try testing.expectEqual(@as(u256, 0xAAA), log.topics[0]);
    try testing.expectEqual(@as(u256, 0xBBB), log.topics[1]);
}

test "LOG2: gas cost with data and topics" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xa2}; // LOG2
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Setup: offset=0, length=10, topic1=1, topic2=2
    try frame.pushStack(2); // topic2
    try frame.pushStack(1); // topic1
    try frame.pushStack(10); // length
    try frame.pushStack(0); // offset

    const initial_gas = frame.gas_remaining;

    // Execute LOG2
    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));
    try LogHandlers.log(&frame, 0xa2);

    // Verify gas consumed: 375 (base) + 375*2 (topics) + 8*10 (data) = 1205
    const expected_gas_cost = GasConstants.LogGas + (2 * GasConstants.LogTopicGas) + (10 * GasConstants.LogDataGas);
    const gas_consumed = initial_gas - frame.gas_remaining;
    try testing.expect(gas_consumed >= expected_gas_cost); // May include memory expansion
}

// ============================================================================
// LOG3 Tests
// ============================================================================

test "LOG3: basic log with three topics" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xa3}; // LOG3
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Setup: offset=0, length=0, topic1=0x111, topic2=0x222, topic3=0x333
    try frame.pushStack(0x333); // topic3
    try frame.pushStack(0x222); // topic2
    try frame.pushStack(0x111); // topic1
    try frame.pushStack(0); // length
    try frame.pushStack(0); // offset

    const initial_gas = frame.gas_remaining;
    const initial_logs = evm.logs.items.len;

    // Execute LOG3
    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));
    try LogHandlers.log(&frame, 0xa3);

    // Verify gas consumed: 375 (base) + 375*3 (3 topics) = 1500
    const expected_gas_cost = GasConstants.LogGas + (3 * GasConstants.LogTopicGas);
    try testing.expectEqual(@as(i64, expected_gas_cost), initial_gas - frame.gas_remaining);

    // Verify log was created with 3 topics in correct order
    try testing.expectEqual(initial_logs + 1, evm.logs.items.len);
    const log = evm.logs.items[initial_logs];
    try testing.expectEqual(@as(usize, 3), log.topics.len);
    try testing.expectEqual(@as(u256, 0x111), log.topics[0]);
    try testing.expectEqual(@as(u256, 0x222), log.topics[1]);
    try testing.expectEqual(@as(u256, 0x333), log.topics[2]);
}

test "LOG3: static call restriction" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xa3}; // LOG3
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, true); // is_static = true
    defer frame.deinit();

    // Setup
    try frame.pushStack(3); // topic3
    try frame.pushStack(2); // topic2
    try frame.pushStack(1); // topic1
    try frame.pushStack(0); // length
    try frame.pushStack(0); // offset

    // Execute LOG3 in static context should fail
    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));
    const result = LogHandlers.log(&frame, 0xa3);

    try testing.expectError(error.StaticCallViolation, result);
}

// ============================================================================
// LOG4 Tests
// ============================================================================

test "LOG4: basic log with four topics" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xa4}; // LOG4
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Setup: offset=0, length=0, topic1-4
    try frame.pushStack(0x444); // topic4
    try frame.pushStack(0x333); // topic3
    try frame.pushStack(0x222); // topic2
    try frame.pushStack(0x111); // topic1
    try frame.pushStack(0); // length
    try frame.pushStack(0); // offset

    const initial_gas = frame.gas_remaining;
    const initial_logs = evm.logs.items.len;

    // Execute LOG4
    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));
    try LogHandlers.log(&frame, 0xa4);

    // Verify gas consumed: 375 (base) + 375*4 (4 topics) = 1875
    const expected_gas_cost = GasConstants.LogGas + (4 * GasConstants.LogTopicGas);
    try testing.expectEqual(@as(i64, expected_gas_cost), initial_gas - frame.gas_remaining);

    // Verify log was created with 4 topics in correct order
    try testing.expectEqual(initial_logs + 1, evm.logs.items.len);
    const log = evm.logs.items[initial_logs];
    try testing.expectEqual(@as(usize, 4), log.topics.len);
    try testing.expectEqual(@as(u256, 0x111), log.topics[0]);
    try testing.expectEqual(@as(u256, 0x222), log.topics[1]);
    try testing.expectEqual(@as(u256, 0x333), log.topics[2]);
    try testing.expectEqual(@as(u256, 0x444), log.topics[3]);
}

test "LOG4: maximum topics with data" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xa4}; // LOG4
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Write data to memory
    const data = "MaxTopics";
    for (data, 0..) |byte, i| {
        try frame.writeMemory(@intCast(i), byte);
    }

    // Setup
    try frame.pushStack(0xFFFFFFFF); // topic4
    try frame.pushStack(0xEEEEEEEE); // topic3
    try frame.pushStack(0xDDDDDDDD); // topic2
    try frame.pushStack(0xCCCCCCCC); // topic1
    try frame.pushStack(9); // length
    try frame.pushStack(0); // offset

    const initial_gas = frame.gas_remaining;
    const initial_logs = evm.logs.items.len;

    // Execute LOG4
    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));
    try LogHandlers.log(&frame, 0xa4);

    // Verify gas consumed: 375 (base) + 375*4 (4 topics) + 8*9 (data) = 1947
    const expected_gas_cost = GasConstants.LogGas + (4 * GasConstants.LogTopicGas) + (9 * GasConstants.LogDataGas);
    const gas_consumed = initial_gas - frame.gas_remaining;
    try testing.expect(gas_consumed >= expected_gas_cost); // May include memory expansion

    // Verify log content
    try testing.expectEqual(initial_logs + 1, evm.logs.items.len);
    const log = evm.logs.items[initial_logs];
    try testing.expectEqual(@as(usize, 4), log.topics.len);
    try testing.expectEqualSlices(u8, data, log.data);
}

test "LOG4: stack underflow on topics" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xa4}; // LOG4
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Only push offset, length, and 3 topics (missing 1 topic)
    try frame.pushStack(3); // topic3
    try frame.pushStack(2); // topic2
    try frame.pushStack(1); // topic1
    try frame.pushStack(0); // length
    try frame.pushStack(0); // offset

    // Execute LOG4 with insufficient stack (need 6 items)
    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));
    const result = LogHandlers.log(&frame, 0xa4);

    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// Log Accumulation Tests
// ============================================================================

test "Multiple logs accumulate correctly" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{ 0xa0, 0xa1, 0xa2 }; // LOG0, LOG1, LOG2
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));

    // Execute LOG0
    try frame.pushStack(0); // length
    try frame.pushStack(0); // offset
    try LogHandlers.log(&frame, 0xa0);
    try testing.expectEqual(@as(usize, 1), evm.logs.items.len);

    // Execute LOG1
    try frame.pushStack(0x111); // topic1
    try frame.pushStack(0); // length
    try frame.pushStack(0); // offset
    try LogHandlers.log(&frame, 0xa1);
    try testing.expectEqual(@as(usize, 2), evm.logs.items.len);

    // Execute LOG2
    try frame.pushStack(0x222); // topic2
    try frame.pushStack(0x111); // topic1
    try frame.pushStack(0); // length
    try frame.pushStack(0); // offset
    try LogHandlers.log(&frame, 0xa2);
    try testing.expectEqual(@as(usize, 3), evm.logs.items.len);

    // Verify log contents
    try testing.expectEqual(@as(usize, 0), evm.logs.items[0].topics.len);
    try testing.expectEqual(@as(usize, 1), evm.logs.items[1].topics.len);
    try testing.expectEqual(@as(usize, 2), evm.logs.items[2].topics.len);
}

test "Log address matches frame address" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xa0}; // LOG0
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    const expected_address = try Address.fromHex("0x2222222222222222222222222222222222222222");

    // Setup and execute
    try frame.pushStack(0); // length
    try frame.pushStack(0); // offset

    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));
    try LogHandlers.log(&frame, 0xa0);

    // Verify log address matches frame address
    const log = evm.logs.items[0];
    try testing.expect(log.address.equals(expected_address));
}

// ============================================================================
// Edge Cases
// ============================================================================

test "LOG0: large data size gas calculation" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xa0}; // LOG0
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    const data_size: u32 = 1000;

    // Setup
    try frame.pushStack(data_size); // length
    try frame.pushStack(0); // offset

    const initial_gas = frame.gas_remaining;

    // Execute LOG0
    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));
    try LogHandlers.log(&frame, 0xa0);

    // Verify gas: 375 (base) + 8*1000 (data) + memory expansion
    const log_cost = GasConstants.LogGas + (@as(u64, data_size) * GasConstants.LogDataGas);
    const gas_consumed = initial_gas - frame.gas_remaining;
    try testing.expect(gas_consumed >= log_cost);
}

test "LOG4: gas cost precision" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xa4}; // LOG4
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Setup with specific data size
    const data_size: u32 = 17;
    try frame.pushStack(4); // topic4
    try frame.pushStack(3); // topic3
    try frame.pushStack(2); // topic2
    try frame.pushStack(1); // topic1
    try frame.pushStack(data_size); // length
    try frame.pushStack(0); // offset

    const initial_gas = frame.gas_remaining;

    // Execute LOG4
    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));
    try LogHandlers.log(&frame, 0xa4);

    // Verify precise gas calculation
    // 375 (base) + 375*4 (topics) + 8*17 (data) = 1875 + 136 = 2011 (plus memory expansion)
    const expected_base = GasConstants.LogGas + (4 * GasConstants.LogTopicGas) + (@as(u64, data_size) * GasConstants.LogDataGas);
    const gas_consumed = initial_gas - frame.gas_remaining;
    try testing.expect(gas_consumed >= expected_base);
}

test "LOG1: PC increments correctly" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xa1}; // LOG1
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Setup
    try frame.pushStack(0x123); // topic1
    try frame.pushStack(0); // length
    try frame.pushStack(0); // offset

    try testing.expectEqual(@as(u32, 0), frame.pc);

    // Execute LOG1
    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));
    try LogHandlers.log(&frame, 0xa1);

    // Verify PC incremented by 1
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "LOG operations preserve memory beyond logged region" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xa0}; // LOG0
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000, false);
    defer frame.deinit();

    // Write data to memory
    try frame.writeMemory(0, 0xAA);
    try frame.writeMemory(1, 0xBB);
    try frame.writeMemory(2, 0xCC);
    try frame.writeMemory(10, 0xDD);

    // Log only first 2 bytes
    try frame.pushStack(2); // length
    try frame.pushStack(0); // offset

    const LogHandlers = @import("handlers_log.zig").Handlers(@TypeOf(frame));
    try LogHandlers.log(&frame, 0xa0);

    // Verify memory outside logged region is preserved
    try testing.expectEqual(@as(u8, 0xCC), frame.readMemory(2));
    try testing.expectEqual(@as(u8, 0xDD), frame.readMemory(10));
}
