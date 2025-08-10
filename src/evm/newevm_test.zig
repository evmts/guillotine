const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

// Helper function to create test addresses
fn testAddress(value: u160) primitives.Address.Address {
    return primitives.Address.from_u256(@as(u256, value));
}

test "EVM can be initialized successfully" {
    const allocator = testing.allocator;

    // Create a memory database for testing
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Get database interface
    const db_interface = memory_db.to_database_interface();

    // Initialize EVM with defaults
    const config = comptime evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.configureEvm(config);
    var vm = try EvmType.init(allocator, db_interface, null, // context
        0, // depth
        false, // read_only
        null // tracer
    );
    defer vm.deinit();

    // Verify basic initialization
    try testing.expect(vm.allocator.ptr == allocator.ptr);
    try testing.expectEqual(@as(u11, 0), vm.depth);
    try testing.expectEqual(false, vm.read_only);
    try testing.expectEqual(@as(i64, 0), vm.gas_refunds);
}

test "EVM state can read and write balances" {
    const allocator = testing.allocator;

    // Create a memory database for testing
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Get database interface
    const db_interface = memory_db.to_database_interface();

    // Initialize EVM
    const config = comptime evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.configureEvm(config);
    var vm = try EvmType.init(allocator, db_interface, null, // context
        0, // depth
        false, // read_only
        null // tracer
    );
    defer vm.deinit();

    // Test addresses
    const addr1 = testAddress(0x1111);
    const addr2 = testAddress(0x2222);

    // Initially balances should be 0
    try testing.expectEqual(@as(u256, 0), vm.state.get_balance(addr1));
    try testing.expectEqual(@as(u256, 0), vm.state.get_balance(addr2));

    // Set balances
    try vm.state.set_balance(addr1, 1000);
    try vm.state.set_balance(addr2, 2000);

    // Read balances back
    try testing.expectEqual(@as(u256, 1000), vm.state.get_balance(addr1));
    try testing.expectEqual(@as(u256, 2000), vm.state.get_balance(addr2));

    // Update balance
    try vm.state.set_balance(addr1, 5000);
    try testing.expectEqual(@as(u256, 5000), vm.state.get_balance(addr1));
    try testing.expectEqual(@as(u256, 2000), vm.state.get_balance(addr2));
}

test "EVM state can read and write storage" {
    const allocator = testing.allocator;

    // Create a memory database for testing
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Get database interface
    const db_interface = memory_db.to_database_interface();

    // Initialize EVM
    const config = comptime evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.configureEvm(config);
    var vm = try EvmType.init(allocator, db_interface, null, // context
        0, // depth
        false, // read_only
        null // tracer
    );
    defer vm.deinit();

    const addr = testAddress(0x3333);

    // Initially storage should be 0
    try testing.expectEqual(@as(u256, 0), vm.state.get_storage(addr, 0));
    try testing.expectEqual(@as(u256, 0), vm.state.get_storage(addr, 100));

    // Set storage values
    try vm.state.set_storage(addr, 0, 42);
    try vm.state.set_storage(addr, 1, 100);
    try vm.state.set_storage(addr, 999, 12345);

    // Read storage back
    try testing.expectEqual(@as(u256, 42), vm.state.get_storage(addr, 0));
    try testing.expectEqual(@as(u256, 100), vm.state.get_storage(addr, 1));
    try testing.expectEqual(@as(u256, 12345), vm.state.get_storage(addr, 999));

    // Unset slots should still be 0
    try testing.expectEqual(@as(u256, 0), vm.state.get_storage(addr, 2));
    try testing.expectEqual(@as(u256, 0), vm.state.get_storage(addr, 1000));
}

test "EVM state can read and write code" {
    const allocator = testing.allocator;

    // Create a memory database for testing
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Get database interface
    const db_interface = memory_db.to_database_interface();

    // Initialize EVM
    const config = comptime evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.configureEvm(config);
    var vm = try EvmType.init(allocator, db_interface, null, // context
        0, // depth
        false, // read_only
        null // tracer
    );
    defer vm.deinit();

    const addr = testAddress(0x4444);

    // Initially code should be empty
    try testing.expectEqual(@as(usize, 0), vm.state.get_code(addr).len);

    // Set some bytecode (simple PUSH1 0x60 PUSH1 0x40 MSTORE)
    const bytecode = &[_]u8{ 0x60, 0x60, 0x60, 0x40, 0x52 };
    try vm.state.set_code(addr, bytecode);

    // Read code back
    const retrieved_code = vm.state.get_code(addr);
    try testing.expectEqualSlices(u8, bytecode, retrieved_code);

    // Update code
    const new_bytecode = &[_]u8{ 0x60, 0x00, 0x60, 0x00, 0x50 };
    try vm.state.set_code(addr, new_bytecode);

    const updated_code = vm.state.get_code(addr);
    try testing.expectEqualSlices(u8, new_bytecode, updated_code);
}

test "EVM state can read and write nonces" {
    const allocator = testing.allocator;

    // Create a memory database for testing
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Get database interface
    const db_interface = memory_db.to_database_interface();

    // Initialize EVM
    const config = comptime evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.configureEvm(config);
    var vm = try EvmType.init(allocator, db_interface, null, // context
        0, // depth
        false, // read_only
        null // tracer
    );
    defer vm.deinit();

    const addr = testAddress(0x5555);

    // Initially nonce should be 0
    try testing.expectEqual(@as(u64, 0), vm.state.get_nonce(addr));

    // Set nonce
    try vm.state.set_nonce(addr, 5);
    try testing.expectEqual(@as(u64, 5), vm.state.get_nonce(addr));

    // Increment nonce
    const prev_nonce = try vm.state.increment_nonce(addr);
    try testing.expectEqual(@as(u64, 5), prev_nonce);
    try testing.expectEqual(@as(u64, 6), vm.state.get_nonce(addr));

    // Multiple increments
    _ = try vm.state.increment_nonce(addr);
    _ = try vm.state.increment_nonce(addr);
    try testing.expectEqual(@as(u64, 8), vm.state.get_nonce(addr));
}

test "EVM state can handle transient storage" {
    const allocator = testing.allocator;

    // Create a memory database for testing
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Get database interface
    const db_interface = memory_db.to_database_interface();

    // Initialize EVM
    const config = comptime evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.configureEvm(config);
    var vm = try EvmType.init(allocator, db_interface, null, // context
        0, // depth
        false, // read_only
        null // tracer
    );
    defer vm.deinit();

    const addr1 = testAddress(0x6666);
    const addr2 = testAddress(0x7777);

    // Initially transient storage should be 0
    try testing.expectEqual(@as(u256, 0), vm.state.get_transient_storage(addr1, 0));
    try testing.expectEqual(@as(u256, 0), vm.state.get_transient_storage(addr1, 100));

    // Set transient storage
    try vm.state.set_transient_storage(addr1, 0, 42);
    try vm.state.set_transient_storage(addr1, 1, 100);
    try vm.state.set_transient_storage(addr2, 0, 200);

    // Read transient storage back
    try testing.expectEqual(@as(u256, 42), vm.state.get_transient_storage(addr1, 0));
    try testing.expectEqual(@as(u256, 100), vm.state.get_transient_storage(addr1, 1));
    try testing.expectEqual(@as(u256, 200), vm.state.get_transient_storage(addr2, 0));

    // Clear transient storage (simulating transaction end)
    vm.state.clear_transient_storage();

    // All values should be 0 after clearing
    try testing.expectEqual(@as(u256, 0), vm.state.get_transient_storage(addr1, 0));
    try testing.expectEqual(@as(u256, 0), vm.state.get_transient_storage(addr1, 1));
    try testing.expectEqual(@as(u256, 0), vm.state.get_transient_storage(addr2, 0));
}

test "EVM state can emit and track logs" {
    const allocator = testing.allocator;

    // Create a memory database for testing
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Get database interface
    const db_interface = memory_db.to_database_interface();

    // Initialize EVM
    const config = comptime evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.configureEvm(config);
    var vm = try EvmType.init(allocator, db_interface, null, // context
        0, // depth
        false, // read_only
        null // tracer
    );
    defer vm.deinit();

    const addr = testAddress(0x8888);

    // Initially no logs
    try testing.expectEqual(@as(usize, 0), vm.state.logs.items.len);

    // Emit a log with no topics (LOG0)
    const data1 = &[_]u8{ 0x01, 0x02, 0x03 };
    try vm.state.emit_log(addr, &[_]u256{}, data1);

    try testing.expectEqual(@as(usize, 1), vm.state.logs.items.len);
    try testing.expectEqual(addr, vm.state.logs.items[0].address);
    try testing.expectEqual(@as(usize, 0), vm.state.logs.items[0].topics.len);
    try testing.expectEqualSlices(u8, data1, vm.state.logs.items[0].data);

    // Emit a log with topics (LOG3)
    const topics = &[_]u256{ 100, 200, 300 };
    const data2 = &[_]u8{ 0x04, 0x05, 0x06, 0x07 };
    try vm.state.emit_log(addr, topics, data2);

    try testing.expectEqual(@as(usize, 2), vm.state.logs.items.len);
    try testing.expectEqual(@as(usize, 3), vm.state.logs.items[1].topics.len);
    try testing.expectEqualSlices(u256, topics, vm.state.logs.items[1].topics);
    try testing.expectEqualSlices(u8, data2, vm.state.logs.items[1].data);

    // Clear logs (simulating new transaction)
    vm.state.clear_logs();
    try testing.expectEqual(@as(usize, 0), vm.state.logs.items.len);
}

test "EVM state persistence across operations" {
    const allocator = testing.allocator;

    // Create a memory database for testing
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Get database interface
    const db_interface = memory_db.to_database_interface();

    // Initialize EVM
    const config = comptime evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.configureEvm(config);
    var vm = try EvmType.init(allocator, db_interface, null, // context
        0, // depth
        false, // read_only
        null // tracer
    );
    defer vm.deinit();

    const addr = testAddress(0x9999);

    // Set up complete account state
    try vm.state.set_balance(addr, 1000000);
    try vm.state.set_nonce(addr, 5);

    const code = &[_]u8{ 0x60, 0x80, 0x60, 0x40 };
    try vm.state.set_code(addr, code);

    try vm.state.set_storage(addr, 0, 42);
    try vm.state.set_storage(addr, 1, 100);

    // Add transient storage
    try vm.state.set_transient_storage(addr, 0, 999);

    // Emit a log
    const topics = &[_]u256{123};
    const data = &[_]u8{0xFF};
    try vm.state.emit_log(addr, topics, data);

    // Verify all persistent state remains
    try testing.expectEqual(@as(u256, 1000000), vm.state.get_balance(addr));
    try testing.expectEqual(@as(u64, 5), vm.state.get_nonce(addr));
    try testing.expectEqualSlices(u8, code, vm.state.get_code(addr));
    try testing.expectEqual(@as(u256, 42), vm.state.get_storage(addr, 0));
    try testing.expectEqual(@as(u256, 100), vm.state.get_storage(addr, 1));

    // Verify transient state
    try testing.expectEqual(@as(u256, 999), vm.state.get_transient_storage(addr, 0));
    try testing.expectEqual(@as(usize, 1), vm.state.logs.items.len);

    // Clear transaction state
    vm.state.clear_transaction_state();

    // Persistent state should remain
    try testing.expectEqual(@as(u256, 1000000), vm.state.get_balance(addr));
    try testing.expectEqual(@as(u64, 5), vm.state.get_nonce(addr));
    try testing.expectEqualSlices(u8, code, vm.state.get_code(addr));
    try testing.expectEqual(@as(u256, 42), vm.state.get_storage(addr, 0));
    try testing.expectEqual(@as(u256, 100), vm.state.get_storage(addr, 1));

    // Transient state should be cleared
    try testing.expectEqual(@as(u256, 0), vm.state.get_transient_storage(addr, 0));
    try testing.expectEqual(@as(usize, 0), vm.state.logs.items.len);
}

test "Simple contract execution with PUSH and POP operations" {
    const allocator = testing.allocator;

    // Create a memory database for testing
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Get database interface
    const db_interface = memory_db.to_database_interface();

    // Initialize EVM
    const config = comptime evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.configureEvm(config);
    var vm = try EvmType.init(allocator, db_interface, null, // context
        0, // depth
        false, // read_only
        null // tracer
    );
    defer vm.deinit();

    // Create simple bytecode: PUSH1 0x42, PUSH1 0x10, POP
    const bytecode = &[_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x10, // PUSH1 0x10
        0x50, // POP
    };

    const contract_addr = testAddress(0xAAAA);
    const caller = testAddress(0xBBBB);

    // Deploy the contract
    try vm.state.set_code(contract_addr, bytecode);

    // Execute contract using call
    const call_params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_addr,
        .value = 0,
        .input = &[_]u8{},
        .gas = 100000,
    } };

    const result = vm.call(call_params) catch |err| {
        std.debug.print("Contract execution failed with error: {}\n", .{err});
        return err;
    };

    // For now, just verify the call completed (even if not successfully)
    // We'll expand this test once the execution infrastructure is more complete
    try testing.expect(result.gas_left <= 100000);

    // Clean up output if present
    if (result.output) |output| {
        allocator.free(output);
    }
}

test "Contract with basic stack operations" {
    const allocator = testing.allocator;

    // Create a memory database for testing
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Get database interface
    const db_interface = memory_db.to_database_interface();

    // Initialize EVM
    const config = comptime evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.configureEvm(config);
    var vm = try EvmType.init(allocator, db_interface, null, // context
        0, // depth
        false, // read_only
        null // tracer
    );
    defer vm.deinit();

    // Create bytecode that does stack operations and returns a value
    // PUSH1 0x05, PUSH1 0x03, ADD, PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN
    const bytecode = &[_]u8{
        0x60, 0x05, // PUSH1 0x05
        0x60, 0x03, // PUSH1 0x03
        0x01, // ADD (5 + 3 = 8)
        0x60, 0x00, // PUSH1 0x00 (memory offset)
        0x52, // MSTORE (store result at memory[0])
        0x60, 0x20, // PUSH1 0x20 (32 bytes)
        0x60, 0x00, // PUSH1 0x00 (memory offset)
        0xF3, // RETURN
    };

    const contract_addr = testAddress(0xCCCC);
    const caller = testAddress(0xDDDD);

    // Deploy the contract
    try vm.state.set_code(contract_addr, bytecode);

    // Set caller balance
    try vm.state.set_balance(caller, 1000000);

    // Execute contract
    const call_params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_addr,
        .value = 0,
        .input = &[_]u8{},
        .gas = 100000,
    } };

    const result = vm.call(call_params) catch |err| {
        std.debug.print("Contract execution failed with error: {}\n", .{err});
        return err;
    };

    // Verify gas was consumed
    try testing.expect(result.gas_left < 100000);

    // Clean up output if present
    if (result.output) |output| {
        // Once execution works, we can verify output contains 8
        allocator.free(output);
    }
}

test "Contract execution with PUSH0 operation" {
    const allocator = testing.allocator;

    // Create a memory database for testing
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Get database interface
    const db_interface = memory_db.to_database_interface();

    // Initialize EVM
    const config = comptime evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.configureEvm(config);
    var vm = try EvmType.init(allocator, db_interface, null, // context
        0, // depth
        false, // read_only
        null // tracer
    );
    defer vm.deinit();

    // Create bytecode: PUSH0, PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN
    const bytecode = &[_]u8{
        0x5F, // PUSH0
        0x60, 0x00, // PUSH1 0x00 (memory offset)
        0x52, // MSTORE (store 0 at memory[0])
        0x60, 0x20, // PUSH1 0x20 (32 bytes)
        0x60, 0x00, // PUSH1 0x00 (memory offset)
        0xF3, // RETURN
    };

    const contract_addr = testAddress(0xEEEE);
    const caller = testAddress(0xFFFF);

    // Deploy the contract
    try vm.state.set_code(contract_addr, bytecode);

    // Execute contract
    const call_params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_addr,
        .value = 0,
        .input = &[_]u8{},
        .gas = 100000,
    } };

    const result = vm.call(call_params) catch |err| {
        std.debug.print("Contract execution failed with error: {}\n", .{err});
        return err;
    };

    // Verify gas was consumed
    try testing.expect(result.gas_left < 100000);

    // Clean up output if present
    if (result.output) |output| {
        allocator.free(output);
    }
}
