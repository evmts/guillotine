const std = @import("std");
const testing = std.testing;
const Evm = @import("evm.zig");
const Frame = @import("frame.zig").Frame;
const ChainRules = @import("frame.zig").ChainRules;
const JumpTable = @import("jump_table/jump_table.zig");
const MemoryDatabase = @import("state/memory_database.zig").MemoryDatabase;
const primitives = @import("primitives");
const Hardfork = @import("hardforks/hardfork.zig").Hardfork;
const CallParams = @import("host.zig").CallParams;
const Host = @import("host.zig").Host;
const AccessList = @import("access_list.zig").AccessList;
const CallJournal = @import("call_frame_stack.zig").CallJournal;
const CodeAnalysis = @import("analysis.zig");
const Stack = @import("stack/stack.zig");
const Memory = @import("memory/memory.zig");

// Helper function to create test addresses
fn testAddress(value: u32) primitives.Address.Address {
    var addr = primitives.Address.ZERO;
    addr[16] = @intCast(value >> 24);
    addr[17] = @intCast(value >> 16);
    addr[18] = @intCast(value >> 8);
    addr[19] = @intCast(value);
    return addr;
}

// ============================================================================
// EVM Initialization Tests
// ============================================================================

test "Evm.init creates valid instance with defaults" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Test basic initialization
    try testing.expect(evm.allocator.ptr == allocator.ptr);
    try testing.expectEqual(@as(u11, 0), evm.depth);
    try testing.expectEqual(false, evm.read_only);
}

test "Evm.init with custom hardfork configuration" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    // Test different hardfork configurations
    const hardforks = [_]Hardfork{ .FRONTIER, .BERLIN, .LONDON, .SHANGHAI, .CANCUN };

    for (hardforks) |hardfork| {
        const jump_table = JumpTable.init(hardfork);
        const chain_rules = Frame.chainRulesForHardfork(hardfork);

        var evm = try Evm.Evm.init(allocator, db_interface, jump_table, chain_rules, null, 0, false, null);
        defer evm.deinit();

        try testing.expect(evm.table.hardfork == hardfork);
    }
}

// ============================================================================
// Frame-based Execution Tests
// ============================================================================

test "Frame initialization with minimal parameters" {
    const allocator = testing.allocator;

    // Create required components
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

    // Create simple bytecode for analysis
    const bytecode = &[_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01 }; // PUSH1 1, PUSH1 2, ADD
    var analysis = try CodeAnalysis.analyze(allocator, bytecode);
    defer analysis.deinit(allocator);

    // Initialize frame
    var frame = try Frame.init(100_000, // gas
        false, // static call
        0, // call depth
        testAddress(0x1000), // contract address
        testAddress(0x2000), // caller
        0, // value
        &analysis, &access_list, &journal, host, 0, // snapshot id
        memory_db.to_database_interface(), Frame.chainRulesForHardfork(.LONDON), null, // self destruct
        null, // created contracts
        &[_]u8{}, // input
        allocator, null, // next frame
        false, // is create
        false // is delegate
    );
    defer frame.deinit();

    // Verify frame initialization
    try testing.expectEqual(@as(u64, 100_000), frame.gas_remaining);
    try testing.expectEqual(false, frame.hot_flags.is_static);
    try testing.expectEqual(@as(u10, 0), frame.hot_flags.depth);
    try testing.expectEqual(testAddress(0x1000), frame.contract_address);
    try testing.expectEqual(testAddress(0x2000), frame.caller);
}

test "Frame execution with simple bytecode" {
    const allocator = testing.allocator;

    // Setup EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Create and deploy simple contract
    const bytecode = &[_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xF3, // RETURN
    };

    const contract_addr = testAddress(0x3000);
    try evm.state.set_code(contract_addr, bytecode);

    // Create frame for execution
    var stack = try Stack.init(allocator);
    defer stack.deinit();

    var memory = try Memory.init(allocator);
    defer memory.deinit();

    var analysis = try CodeAnalysis.analyze(allocator, bytecode);
    defer analysis.deinit(allocator);

    var host = try allocator.create(Host);
    defer allocator.destroy(host);
    host.* = Host.init(allocator, db_interface);
    defer host.deinit();

    var frame = try Frame.init(100_000, // gas
        false, // static call
        0, // call depth
        contract_addr, testAddress(0x4000), // caller
        0, // value
        &analysis, &evm.access_list, &evm.journal, host, 0, // snapshot id
        db_interface, Frame.chainRulesForHardfork(.LONDON), null, // self destruct
        null, // created contracts
        &[_]u8{}, // input
        allocator, null, // next frame
        false, // is create
        false // is delegate
    );
    defer frame.deinit();

    // Frame is ready for execution
    try testing.expect(frame.gas_remaining > 0);
    try testing.expect(frame.analysis.code.len == bytecode.len);
}

// ============================================================================
// Call-based Execution Tests
// ============================================================================

test "Evm.call with simple contract" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Deploy simple contract that returns 42
    const bytecode = &[_]u8{
        0x60, 0x2A, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    const contract_addr = testAddress(0x5000);
    const caller_addr = testAddress(0x6000);

    try evm.state.set_code(contract_addr, bytecode);
    try evm.state.set_balance(caller_addr, 1_000_000);

    // Execute call
    const call_params = CallParams{ .call = .{
        .caller = caller_addr,
        .to = contract_addr,
        .value = 0,
        .input = &[_]u8{},
        .gas = 100_000,
    } };

    const result = evm.call(call_params) catch |err| {
        std.debug.print("Call failed with error: {}\n", .{err});
        return err;
    };

    // Verify execution
    try testing.expect(result.gas_left < 100_000); // Some gas was consumed

    if (result.output) |output| {
        defer allocator.free(output);
        try testing.expectEqual(@as(usize, 32), output.len);
        // Check that the returned value is 42
        var expected = [_]u8{0} ** 32;
        expected[31] = 42;
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

test "Dynamic runtime JUMP works (no immediate PUSH)" {
    const allocator = testing.allocator;
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Contract: PUSH1 5; DUP1; JUMP; JUMPDEST; PUSH1 0x2A; PUSH1 0; MSTORE; PUSH1 32; PUSH1 0; RETURN
    const contract_code = &[_]u8{ 0x60, 0x05, 0x80, 0x56, 0x5B, 0x60, 0x2A, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xF3 };
    const addr = testAddress(0x6000);
    try evm.state.set_code(addr, contract_code);

    const call_params = CallParams{ .call = .{ .caller = testAddress(0x5000), .to = addr, .value = 0, .input = &[_]u8{}, .gas = 100_000 } };
    const result = try evm.call(call_params);
    try testing.expect(result.gas_left < 100_000);
    if (result.output) |output| {
        defer allocator.free(output);
        try testing.expectEqual(@as(usize, 32), output.len);
        try testing.expectEqual(@as(u8, 0x2A), output[31]);
    } else {
        return error.TestExpectedEqual;
    }
}

test "Evm.call with CREATE operation" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const creator_addr = testAddress(0x7000);

    // Fund the creator
    try evm.state.set_balance(creator_addr, 10_000_000);

    // Simple init code that deploys a contract returning 100
    const init_code = &[_]u8{
        // Constructor: store runtime code in memory
        0x60, 0x0A, // PUSH1 10 (size of runtime code)
        0x60, 0x0C, // PUSH1 12 (offset of runtime code)
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x39, // CODECOPY
        0x60, 0x0A, // PUSH1 10 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xF3, // RETURN
        // Runtime code (10 bytes)
        0x60, 0x64, // PUSH1 100
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Execute CREATE via call
    const call_params = CallParams{ .create = .{
        .caller = creator_addr,
        .value = 0,
        .init_code = init_code,
        .gas = 500_000,
    } };

    const result = evm.call(call_params) catch |err| {
        std.debug.print("CREATE failed with error: {}\n", .{err});
        return err;
    };

    // Verify contract was created
    try testing.expect(result.gas_left < 500_000);

    if (result.output) |output| {
        defer allocator.free(output);
        // Output should be the deployed contract address (20 bytes)
        try testing.expectEqual(@as(usize, 20), output.len);
    }
}

// ============================================================================
// State Management Tests
// ============================================================================

test "Evm state persistence across calls" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Deploy storage contract (SSTORE and SLOAD)
    const storage_contract = &[_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00
        0x55, // SSTORE (store 0x42 at slot 0)
        0x60, 0x00, // PUSH1 0x00
        0x54, // SLOAD (load from slot 0)
        0x60, 0x00, // PUSH1 0x00
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xF3, // RETURN
    };

    const contract_addr = testAddress(0x8000);
    const caller_addr = testAddress(0x9000);

    try evm.state.set_code(contract_addr, storage_contract);
    try evm.state.set_balance(caller_addr, 1_000_000);

    // First call - stores value
    const call_params = CallParams{ .call = .{
        .caller = caller_addr,
        .to = contract_addr,
        .value = 0,
        .input = &[_]u8{},
        .gas = 100_000,
    } };

    const result1 = try evm.call(call_params);
    if (result1.output) |output| {
        defer allocator.free(output);
    }

    // Check storage was persisted
    const stored_value = try evm.state.get_storage(contract_addr, 0);
    try testing.expectEqual(@as(u256, 0x42), stored_value);

    // Second call should read the same value
    const result2 = try evm.call(call_params);
    if (result2.output) |output| {
        defer allocator.free(output);
        var expected = [_]u8{0} ** 32;
        expected[31] = 0x42;
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

// ============================================================================
// Access List Tests
// ============================================================================

test "Evm access list tracking" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const test_addr = testAddress(0xA000);
    const storage_key: u256 = 0x1234;

    // Initially cold
    try testing.expectEqual(false, evm.access_list.is_address_warm(test_addr));
    try testing.expectEqual(false, evm.access_list.is_storage_warm(test_addr, storage_key));

    // Access address
    _ = evm.access_list.access_address(test_addr);
    try testing.expectEqual(true, evm.access_list.is_address_warm(test_addr));

    // Access storage
    _ = evm.access_list.access_storage_slot(test_addr, storage_key);
    try testing.expectEqual(true, evm.access_list.is_storage_warm(test_addr, storage_key));
}

// ============================================================================
// Gas Management Tests
// ============================================================================

test "Evm gas consumption tracking" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Deploy contract with expensive operations
    const expensive_contract = &[_]u8{
        // Loop storing values
        0x60, 0x0A, // PUSH1 10 (loop counter)
        0x60, 0x00, // PUSH1 0 (slot)
        // Loop start (offset 4)
        0x5B, // JUMPDEST
        0x80, // DUP1
        0x81, // DUP2
        0x55, // SSTORE
        0x60, 0x01, // PUSH1 1
        0x01, // ADD (increment slot)
        0x60, 0x01, // PUSH1 1
        0x82, // DUP3
        0x03, // SUB (decrement counter)
        0x80, // DUP1
        0x60, 0x04, // PUSH1 4 (jump target)
        0x57, // JUMPI (jump if counter > 0)
        0x50, // POP
        0x50, // POP
        0x00, // STOP
    };

    const contract_addr = testAddress(0xB000);
    const caller_addr = testAddress(0xC000);

    try evm.state.set_code(contract_addr, expensive_contract);
    try evm.state.set_balance(caller_addr, 10_000_000);

    // Execute with limited gas
    const call_params = CallParams{ .call = .{
        .caller = caller_addr,
        .to = contract_addr,
        .value = 0,
        .input = &[_]u8{},
        .gas = 200_000,
    } };

    const result = try evm.call(call_params);

    // Verify significant gas consumption
    const gas_used = 200_000 - result.gas_left;
    try testing.expect(gas_used > 50_000); // Should use substantial gas for storage

    if (result.output) |output| {
        allocator.free(output);
    }
}

// ============================================================================
// Edge Cases and Error Handling
// ============================================================================

test "Evm handles stack underflow gracefully" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Contract with stack underflow
    const bad_contract = &[_]u8{
        0x01, // ADD without any values on stack - should fail
    };

    const contract_addr = testAddress(0xD000);
    const caller_addr = testAddress(0xE000);

    try evm.state.set_code(contract_addr, bad_contract);
    try evm.state.set_balance(caller_addr, 1_000_000);

    const call_params = CallParams{ .call = .{
        .caller = caller_addr,
        .to = contract_addr,
        .value = 0,
        .input = &[_]u8{},
        .gas = 100_000,
    } };

    // Should handle error gracefully
    const result = evm.call(call_params) catch |err| {
        // Expected to fail with stack underflow
        try testing.expect(err == error.StackUnderflow);
        return;
    };

    // If it didn't error, verify it failed
    try testing.expect(result.success == false);

    if (result.output) |output| {
        allocator.free(output);
    }
}

test "Evm handles out of gas correctly" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Infinite loop contract
    const infinite_loop = &[_]u8{
        0x5B, // JUMPDEST
        0x60, 0x00, // PUSH1 0
        0x56, // JUMP
    };

    const contract_addr = testAddress(0xF000);
    const caller_addr = testAddress(0x1111);

    try evm.state.set_code(contract_addr, infinite_loop);
    try evm.state.set_balance(caller_addr, 1_000_000);

    const call_params = CallParams{
        .call = .{
            .caller = caller_addr,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 1000, // Very limited gas
        },
    };

    const result = evm.call(call_params) catch |err| {
        // Should run out of gas
        try testing.expect(err == error.OutOfGas);
        return;
    };

    // Should have consumed all gas
    try testing.expectEqual(@as(u64, 0), result.gas_left);

    if (result.output) |output| {
        allocator.free(output);
    }
}

// ============================================================================
// Memory Management Tests
// ============================================================================

test "Evm proper cleanup on multiple calls" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const simple_contract = &[_]u8{0x00}; // STOP
    const contract_addr = testAddress(0x2222);
    const caller_addr = testAddress(0x3333);

    try evm.state.set_code(contract_addr, simple_contract);
    try evm.state.set_balance(caller_addr, 10_000_000);

    // Execute multiple calls
    for (0..10) |_| {
        const call_params = CallParams{ .call = .{
            .caller = caller_addr,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 21_000,
        } };

        const result = try evm.call(call_params);

        if (result.output) |output| {
            allocator.free(output);
        }
    }

    // No memory leaks should occur
}
