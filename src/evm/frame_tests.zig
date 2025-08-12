const std = @import("std");
const testing = std.testing;
const Frame = @import("frame.zig").Frame;
const ChainRules = @import("frame.zig").ChainRules;
const Hardfork = @import("hardforks/hardfork.zig").Hardfork;
const primitives = @import("primitives");
const Stack = @import("stack/stack.zig");
const Memory = @import("memory/memory.zig");
const AccessList = @import("access_list.zig").AccessList;
const CallJournal = @import("call_frame_stack.zig").CallJournal;
const CodeAnalysis = @import("analysis.zig");
const Host = @import("host.zig").Host;
const MemoryDatabase = @import("state/memory_database.zig").MemoryDatabase;
const SelfDestruct = @import("self_destruct.zig").SelfDestruct;

// Helper to create test addresses
fn testAddress(value: u32) primitives.Address.Address {
    var addr = primitives.Address.ZERO;
    addr[16] = @intCast(value >> 24);
    addr[17] = @intCast(value >> 16);
    addr[18] = @intCast(value >> 8);
    addr[19] = @intCast(value);
    return addr;
}

// ============================================================================
// Frame Structure Tests
// ============================================================================

test "Frame memory layout optimization verification" {
    // Verify that Frame struct fields are ordered for cache efficiency
    // This test documents the expected memory layout

    const frame_size = @sizeOf(Frame);
    const cache_line_size = 64; // Typical cache line size

    // Frame should be reasonably sized
    try testing.expect(frame_size < 1024);

    // Verify field offsets match expected hot/cold grouping
    const stack_offset = @offsetOf(Frame, "stack");
    const gas_offset = @offsetOf(Frame, "gas_remaining");
    const memory_offset = @offsetOf(Frame, "memory");

    // Hot fields should be in first cache lines
    try testing.expect(stack_offset < cache_line_size);
    try testing.expect(gas_offset < cache_line_size);
    try testing.expect(memory_offset < cache_line_size * 2);
}

test "Frame initialization with all parameters" {
    const allocator = testing.allocator;

    // Create all required components
    var stack = try Stack.init(allocator);
    defer stack.deinit();

    var memory = try Memory.init(allocator);
    defer memory.deinit();

    var access_list = AccessList.init(allocator);
    defer access_list.deinit();

    var journal = try CallJournal.init(allocator);
    defer journal.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    var host = try allocator.create(Host);
    defer allocator.destroy(host);
    host.* = Host.init(allocator, memory_db.to_database_interface());
    defer host.deinit();

    var self_destruct = SelfDestruct.init(allocator);
    defer self_destruct.deinit();


    const bytecode = &[_]u8{ 0x60, 0x01 }; // PUSH1 1
    var analysis = try CodeAnalysis.analyze(allocator, bytecode);
    defer analysis.deinit(allocator);

    const input = &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };

    var frame = try Frame.init(100_000, // gas_remaining
        true, // static_call
        5, // call_depth
        testAddress(0x1234), // contract_address
        testAddress(0x5678), // caller
        1000, // value
        &analysis, &access_list, &journal, host, 42, // snapshot_id
        memory_db.to_database_interface(), Frame.chainRulesForHardfork(.CANCUN), &self_destruct, input, allocator, false, // is_create_call
        true // is_delegate_call
    );
    defer frame.deinit();

    // Verify all fields are properly initialized
    try testing.expectEqual(@as(u64, 100_000), frame.gas_remaining);
    try testing.expectEqual(true, frame.is_static);
    try testing.expectEqual(@as(u10, 5), frame.depth);
    try testing.expectEqual(testAddress(0x1234), frame.contract_address);
    try testing.expectEqual(testAddress(0x5678), frame.caller);
    try testing.expectEqual(@as(u256, 1000), frame.value);
    try testing.expectEqual(@as(u32, 42), frame.snapshot_id);
    try testing.expectEqual(true, frame.is_delegate);
    try testing.expectEqualSlices(u8, input, frame.input);
}

test "Frame.chainRulesForHardfork generates correct rules" {
    // Test each hardfork generates appropriate chain rules
    const hardforks = [_]Hardfork{
        .FRONTIER,
        .HOMESTEAD,
        .BYZANTIUM,
        .CONSTANTINOPLE,
        .PETERSBURG,
        .ISTANBUL,
        .BERLIN,
        .LONDON,
        .MERGE,
        .SHANGHAI,
        .CANCUN,
    };

    for (hardforks) |hardfork| {
        const rules = Frame.chainRulesForHardfork(hardfork);

        // Verify progressive feature enablement
        if (hardfork == .FRONTIER) {
            try testing.expectEqual(false, rules.is_homestead);
            try testing.expectEqual(false, rules.is_byzantium);
        }

        if (@intFromEnum(hardfork) >= @intFromEnum(Hardfork.HOMESTEAD)) {
            try testing.expectEqual(true, rules.is_homestead);
        }

        if (@intFromEnum(hardfork) >= @intFromEnum(Hardfork.BYZANTIUM)) {
            try testing.expectEqual(true, rules.is_byzantium);
        }

        if (@intFromEnum(hardfork) >= @intFromEnum(Hardfork.LONDON)) {
            try testing.expectEqual(true, rules.is_london);
            try testing.expectEqual(true, rules.is_eip1559); // Base fee
        }

        if (@intFromEnum(hardfork) >= @intFromEnum(Hardfork.SHANGHAI)) {
            try testing.expectEqual(true, rules.is_shanghai);
            try testing.expectEqual(true, rules.is_eip3855); // PUSH0
        }

        if (@intFromEnum(hardfork) >= @intFromEnum(Hardfork.CANCUN)) {
            try testing.expectEqual(true, rules.is_cancun);
            try testing.expectEqual(true, rules.is_eip4844); // Blob transactions
            try testing.expectEqual(true, rules.is_eip1153); // Transient storage
        }
    }
}

test "Frame hardfork detection from chain rules" {
    const allocator = testing.allocator;

    // Create minimal frame components
    var stack = try Stack.init(allocator);
    defer stack.deinit();

    var memory = try Memory.init(allocator);
    defer memory.deinit();

    var access_list = AccessList.init(allocator);
    defer access_list.deinit();

    var journal = try CallJournal.init(allocator);
    defer journal.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    var host = try allocator.create(Host);
    defer allocator.destroy(host);
    host.* = Host.init(allocator, memory_db.to_database_interface());
    defer host.deinit();

    const bytecode = &[_]u8{0x00}; // STOP
    var analysis = try CodeAnalysis.analyze(allocator, bytecode);
    defer analysis.deinit(allocator);

    // Test different chain rules configurations
    const test_cases = [_]struct {
        rules: ChainRules,
        expected_hardfork: Hardfork,
    }{
        .{
            .rules = Frame.chainRulesForHardfork(.FRONTIER),
            .expected_hardfork = .FRONTIER,
        },
        .{
            .rules = Frame.chainRulesForHardfork(.LONDON),
            .expected_hardfork = .LONDON,
        },
        .{
            .rules = Frame.chainRulesForHardfork(.CANCUN),
            .expected_hardfork = .CANCUN,
        },
    };

    for (test_cases) |tc| {
        var frame = try Frame.init(100_000, false, 0, testAddress(0x1000), testAddress(0x2000), 0, &analysis, &access_list, &journal, host, 0, memory_db.to_database_interface(), tc.rules, null, &[_]u8{}, allocator, false, false);
        defer frame.deinit();

        try testing.expectEqual(tc.expected_hardfork, frame.hardfork);
    }
}

test "Frame gas consumption" {
    const allocator = testing.allocator;

    var stack = try Stack.init(allocator);
    defer stack.deinit();

    var memory = try Memory.init(allocator);
    defer memory.deinit();

    var access_list = AccessList.init(allocator);
    defer access_list.deinit();

    var journal = try CallJournal.init(allocator);
    defer journal.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    var host = try allocator.create(Host);
    defer allocator.destroy(host);
    host.* = Host.init(allocator, memory_db.to_database_interface());
    defer host.deinit();

    const bytecode = &[_]u8{0x00};
    var analysis = try CodeAnalysis.analyze(allocator, bytecode);
    defer analysis.deinit(allocator);

    var frame = try Frame.init(1000, // Initial gas
        false, 0, testAddress(0x1000), testAddress(0x2000), 0, &analysis, &access_list, &journal, host, 0, memory_db.to_database_interface(), Frame.chainRulesForHardfork(.LONDON), null, &[_]u8{}, allocator, false, false);
    defer frame.deinit();

    // Test gas consumption
    const initial_gas = frame.gas_remaining;
    try testing.expectEqual(@as(u64, 1000), initial_gas);

    // Simulate consuming gas
    frame.gas_remaining -= 100;
    try testing.expectEqual(@as(u64, 900), frame.gas_remaining);

    // Simulate gas exhaustion
    frame.gas_remaining = 0;
    try testing.expectEqual(@as(u64, 0), frame.gas_remaining);
}

test "Frame depth tracking" {
    const allocator = testing.allocator;

    var stack = try Stack.init(allocator);
    defer stack.deinit();

    var memory = try Memory.init(allocator);
    defer memory.deinit();

    var access_list = AccessList.init(allocator);
    defer access_list.deinit();

    var journal = try CallJournal.init(allocator);
    defer journal.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    var host = try allocator.create(Host);
    defer allocator.destroy(host);
    host.* = Host.init(allocator, memory_db.to_database_interface());
    defer host.deinit();

    const bytecode = &[_]u8{0x00};
    var analysis = try CodeAnalysis.analyze(allocator, bytecode);
    defer analysis.deinit(allocator);

    // Test different depth values
    const depths = [_]u10{ 0, 1, 10, 100, 512, 1023 };

    for (depths) |depth| {
        var frame = try Frame.init(100_000, false, depth, testAddress(0x1000), testAddress(0x2000), 0, &analysis, &access_list, &journal, host, 0, memory_db.to_database_interface(), Frame.chainRulesForHardfork(.LONDON), null, &[_]u8{}, allocator, false, false);
        defer frame.deinit();

        try testing.expectEqual(depth, frame.depth);
    }
}

test "Frame static call restrictions" {
    const allocator = testing.allocator;

    var stack = try Stack.init(allocator);
    defer stack.deinit();

    var memory = try Memory.init(allocator);
    defer memory.deinit();

    var access_list = AccessList.init(allocator);
    defer access_list.deinit();

    var journal = try CallJournal.init(allocator);
    defer journal.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    var host = try allocator.create(Host);
    defer allocator.destroy(host);
    host.* = Host.init(allocator, memory_db.to_database_interface());
    defer host.deinit();

    const bytecode = &[_]u8{0x00};
    var analysis = try CodeAnalysis.analyze(allocator, bytecode);
    defer analysis.deinit(allocator);

    // Create static call frame
    var static_frame = try Frame.init(100_000, true, // static call
        0, testAddress(0x1000), testAddress(0x2000), 0, // value must be 0 for static calls
        &analysis, &access_list, &journal, host, 0, memory_db.to_database_interface(), Frame.chainRulesForHardfork(.LONDON), null, &[_]u8{}, allocator, false, false);
    defer static_frame.deinit();

    try testing.expectEqual(true, static_frameis_static);
    try testing.expectEqual(@as(u256, 0), static_frame.value);

    // Create non-static frame
    var normal_frame = try Frame.init(100_000, false, // not static
        0, testAddress(0x3000), testAddress(0x4000), 1000, // can have value
        &analysis, &access_list, &journal, host, 0, memory_db.to_database_interface(), Frame.chainRulesForHardfork(.LONDON), null, &[_]u8{}, allocator, false, false);
    defer normal_frame.deinit();

    try testing.expectEqual(false, normal_frameis_static);
    try testing.expectEqual(@as(u256, 1000), normal_frame.value);
}

test "Frame block context" {
    const allocator = testing.allocator;

    var stack = try Stack.init(allocator);
    defer stack.deinit();

    var memory = try Memory.init(allocator);
    defer memory.deinit();

    var access_list = AccessList.init(allocator);
    defer access_list.deinit();

    var journal = try CallJournal.init(allocator);
    defer journal.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create host with custom block info
    var host = try allocator.create(Host);
    defer allocator.destroy(host);
    host.* = Host.init(allocator, memory_db.to_database_interface());
    defer host.deinit();

    // Set custom block info in host
    host.block_info = .{
        .number = 12345678,
        .timestamp = 1234567890,
        .difficulty = 0xDEADBEEF,
        .gas_limit = 30_000_000,
        .coinbase = testAddress(0xC01BA5E),
        .base_fee = 1_000_000_000, // 1 gwei
        .blob_base_fee = 100_000_000, // 0.1 gwei
    };

    const bytecode = &[_]u8{0x00};
    var analysis = try CodeAnalysis.analyze(allocator, bytecode);
    defer analysis.deinit(allocator);

    var frame = try Frame.init(100_000, false, 0, testAddress(0x1000), testAddress(0x2000), 0, &analysis, &access_list, &journal, host, 0, memory_db.to_database_interface(), Frame.chainRulesForHardfork(.CANCUN), null, &[_]u8{}, allocator, false, false);
    defer frame.deinit();

    // Verify block context is properly set
    try testing.expectEqual(@as(u64, 12345678), frame.block_number);
    try testing.expectEqual(@as(u64, 1234567890), frame.block_timestamp);
    try testing.expectEqual(@as(u256, 0xDEADBEEF), frame.block_difficulty);
    try testing.expectEqual(@as(u64, 30_000_000), frame.block_gas_limit);
    try testing.expectEqual(testAddress(0xC01BA5E), frame.block_coinbase);
    try testing.expectEqual(@as(u256, 1_000_000_000), frame.block_base_fee);
    try testing.expectEqual(@as(?u256, 100_000_000), frame.block_blob_base_fee);
}

test "Frame CREATE context" {
    const allocator = testing.allocator;

    var stack = try Stack.init(allocator);
    defer stack.deinit();

    var memory = try Memory.init(allocator);
    defer memory.deinit();

    var access_list = AccessList.init(allocator);
    defer access_list.deinit();

    var journal = try CallJournal.init(allocator);
    defer journal.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    var host = try allocator.create(Host);
    defer allocator.destroy(host);
    host.* = Host.init(allocator, memory_db.to_database_interface());
    defer host.deinit();

    const init_code = &[_]u8{ 0x60, 0x00, 0x60, 0x00, 0xF3 }; // Return empty code
    var analysis = try CodeAnalysis.analyze(allocator, init_code);
    defer analysis.deinit(allocator);


    var frame = try Frame.init(500_000, false, 0, testAddress(0xFFFF), // Contract being created
        testAddress(0x5000), // Creator
        10000, // Value being sent
        &analysis, &access_list, &journal, host, 0, memory_db.to_database_interface(), Frame.chainRulesForHardfork(.LONDON), null, &[_]u8{}, allocator, true, // is_create_call
        false);
    defer frame.deinit();

    try testing.expectEqual(true, frame.is_create);
    try testing.expectEqual(false, frame.is_delegate);
}

test "Frame DELEGATECALL context" {
    const allocator = testing.allocator;

    var stack = try Stack.init(allocator);
    defer stack.deinit();

    var memory = try Memory.init(allocator);
    defer memory.deinit();

    var access_list = AccessList.init(allocator);
    defer access_list.deinit();

    var journal = try CallJournal.init(allocator);
    defer journal.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    var host = try allocator.create(Host);
    defer allocator.destroy(host);
    host.* = Host.init(allocator, memory_db.to_database_interface());
    defer host.deinit();

    const bytecode = &[_]u8{0x00};
    var analysis = try CodeAnalysis.analyze(allocator, bytecode);
    defer analysis.deinit(allocator);

    var frame = try Frame.init(100_000, false, 1, testAddress(0x6000), // Storage context
        testAddress(0x7000), // Original caller preserved
        5000, // Original value preserved
        &analysis, &access_list, &journal, host, 0, memory_db.to_database_interface(), Frame.chainRulesForHardfork(.LONDON), null, &[_]u8{}, allocator, false, true // is_delegate_call
    );
    defer frame.deinit();

    try testing.expectEqual(false, frame.is_create);
    try testing.expectEqual(true, frame.is_delegate);
}

test "Frame memory and stack access" {
    const allocator = testing.allocator;

    var stack = try Stack.init(allocator);
    defer stack.deinit();

    var memory = try Memory.init(allocator);
    defer memory.deinit();

    var access_list = AccessList.init(allocator);
    defer access_list.deinit();

    var journal = try CallJournal.init(allocator);
    defer journal.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    var host = try allocator.create(Host);
    defer allocator.destroy(host);
    host.* = Host.init(allocator, memory_db.to_database_interface());
    defer host.deinit();

    const bytecode = &[_]u8{0x00};
    var analysis = try CodeAnalysis.analyze(allocator, bytecode);
    defer analysis.deinit(allocator);

    var frame = try Frame.init(100_000, false, 0, testAddress(0x1000), testAddress(0x2000), 0, &analysis, &access_list, &journal, host, 0, memory_db.to_database_interface(), Frame.chainRulesForHardfork(.LONDON), null, &[_]u8{}, allocator, false, false);
    defer frame.deinit();

    // Test stack operations through frame
    try frame.stack.append(42);
    try frame.stack.append(100);

    const top = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 100), top);

    const next = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 42), next);

    // Test memory operations through frame
    const test_data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    try frame.memory.write(0, &test_data);

    var read_buffer: [4]u8 = undefined;
    try frame.memory.read(0, &read_buffer);

    try testing.expectEqualSlices(u8, &test_data, &read_buffer);
}

test "Frame cleanup and deinitialization" {
    const allocator = testing.allocator;

    // Create and immediately clean up a frame
    {
        var stack = try Stack.init(allocator);
        defer stack.deinit();

        var memory = try Memory.init(allocator);
        defer memory.deinit();

        var access_list = AccessList.init(allocator);
        defer access_list.deinit();

        var journal = try CallJournal.init(allocator);
        defer journal.deinit();

        var memory_db = MemoryDatabase.init(allocator);
        defer memory_db.deinit();

        var host = try allocator.create(Host);
        defer allocator.destroy(host);
        host.* = Host.init(allocator, memory_db.to_database_interface());
        defer host.deinit();

        const bytecode = &[_]u8{0x00};
        var analysis = try CodeAnalysis.analyze(allocator, bytecode);
        defer analysis.deinit(allocator);

        var frame = try Frame.init(100_000, false, 0, testAddress(0x1000), testAddress(0x2000), 0, &analysis, &access_list, &journal, host, 0, memory_db.to_database_interface(), Frame.chainRulesForHardfork(.LONDON), null, &[_]u8{}, allocator, false, false);

        // Frame cleanup happens here
        frame.deinit();
    }

    // No memory leaks should occur
}
