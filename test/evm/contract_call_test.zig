const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const CallParams = @import("evm").CallParams;

test "contract call: empty contract returns success" {
    const allocator = testing.allocator;

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = primitives.Address.from_u256(0x1111);
    const empty_contract = primitives.Address.from_u256(0x2222);

    // Set up caller with balance
    try evm.state.set_balance(caller, 1000000);

    // Call empty contract (no code)
    const call_params = CallParams{ .call = .{
        .caller = caller,
        .to = empty_contract,
        .value = 0,
        .input = &.{},
        .gas = 100000,
    }};
    const result = try evm.call(call_params);
    defer if (result.output.len > 0) allocator.free(result.output);

    try testing.expect(result.success);
    try testing.expectEqual(@as(u64, 100000), result.gas_left); // No gas consumed
    try testing.expect(result.output.len == 0);
}

test "contract call: value transfer to empty contract" {
    const allocator = testing.allocator;

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = primitives.Address.from_u256(0x1111);
    const recipient = primitives.Address.from_u256(0x2222);
    const transfer_amount: u256 = 1000;

    // Set up caller with balance
    try evm.state.set_balance(caller, 10000);

    // Call with value transfer
    const call_params = CallParams{ .call = .{
        .caller = caller,
        .to = recipient,
        .value = transfer_amount,
        .input = &.{},
        .gas = 100000,
    }};
    const result = try evm.call(call_params);
    defer if (result.output.len > 0) allocator.free(result.output);

    try testing.expect(result.success);
    try testing.expectEqual(@as(u256, 9000), evm.state.get_balance(caller));
    try testing.expectEqual(@as(u256, 1000), evm.state.get_balance(recipient));
}

test "contract call: insufficient balance for value transfer" {
    const allocator = testing.allocator;

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = primitives.Address.from_u256(0x1111);
    const recipient = primitives.Address.from_u256(0x2222);

    // Caller has insufficient balance
    try evm.state.set_balance(caller, 500);

    // Try to transfer more than balance
    const call_params = CallParams{ .call = .{
        .caller = caller,
        .to = recipient,
        .value = 1000, // more than caller has
        .input = &.{},
        .gas = 100000,
    }};
    const result = try evm.call(call_params);
    defer if (result.output.len > 0) allocator.free(result.output);

    try testing.expect(!result.success);
    try testing.expectEqual(@as(u64, 100000), result.gas_left); // Gas not consumed
    try testing.expectEqual(@as(u256, 500), evm.state.get_balance(caller)); // Balance unchanged
    try testing.expectEqual(@as(u256, 0), evm.state.get_balance(recipient));
}

test "contract call: static call cannot transfer value" {
    const allocator = testing.allocator;

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = primitives.Address.from_u256(0x1111);
    const recipient = primitives.Address.from_u256(0x2222);

    try evm.state.set_balance(caller, 10000);

    // Static call with value should fail - use staticcall variant
    const call_params = CallParams{ .staticcall = .{
        .caller = caller,
        .to = recipient,
        .input = &.{},
        .gas = 100000,
    }};
    const result = try evm.call(call_params);
    defer if (result.output.len > 0) allocator.free(result.output);

    try testing.expect(!result.success);
    try testing.expectEqual(@as(u64, 100000), result.gas_left);
}

test "contract call: simple contract execution" {
    const allocator = testing.allocator;

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    const deployer = primitives.Address.from_u256(0x1111);
    const caller = primitives.Address.from_u256(0x2222);

    try vm.state.set_balance(deployer, 1000000);
    try vm.state.set_balance(caller, 1000000);

    // Deploy a simple contract that returns 42
    const init_code = &[_]u8{
        // Constructor: copy runtime code and return
        0x60, 0x0d, // PUSH1 13 (size)
        0x60, 0x0c, // PUSH1 12 (offset)
        0x60, 0x00, // PUSH1 0 (dest)
        0x39, // CODECOPY
        0x60, 0x0d, // PUSH1 13 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN

        // Runtime code: return 42
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN
    };

    const create_result = try vm.create_contract(deployer, 0, init_code, 1000000);
    defer if (create_result.output) |output| allocator.free(output);

    try testing.expect(create_result.success);

    // Call the deployed contract
    const call_result = try vm.call_contract(caller, create_result.address, 0, &.{}, 100000, false);
    defer if (call_result.output) |output| allocator.free(output);

    try testing.expect(call_result.success);
    try testing.expect(call_result.gas_left < 100000); // Some gas was used
    try testing.expect(call_result.output != null);

    if (call_result.output) |output| {
        try testing.expectEqual(@as(usize, 32), output.len);
        // Check the value is 42
        var value: u256 = 0;
        for (output) |byte| {
            value = (value << 8) | byte;
        }
        try testing.expectEqual(@as(u256, 0x42), value);
    }
}

test "contract call: gas consumption tracking" {
    const allocator = testing.allocator;

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    const deployer = primitives.Address.from_u256(0x1111);
    const caller = primitives.Address.from_u256(0x2222);

    try vm.state.set_balance(deployer, 1000000);
    try vm.state.set_balance(caller, 1000000);

    // Deploy a contract that does some operations
    const init_code = &[_]u8{
        // Constructor
        0x60, 0x18, // PUSH1 24 (size)
        0x60, 0x0c, // PUSH1 12 (offset)
        0x60, 0x00, // PUSH1 0
        0x39, // CODECOPY
        0x60, 0x18, // PUSH1 24 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN

        // Runtime: do some operations then return
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x01, // ADD
        0x60, 0x03, // PUSH1 3
        0x02, // MUL
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN
    };

    const create_result = try vm.create_contract(deployer, 0, init_code, 1000000);
    defer if (create_result.output) |output| allocator.free(output);

    try testing.expect(create_result.success);

    // Call with specific gas amount
    const initial_gas: u64 = 50000;
    const call_result = try vm.call_contract(caller, create_result.address, 0, &.{}, initial_gas, false);
    defer if (call_result.output) |output| allocator.free(output);

    try testing.expect(call_result.success);

    const gas_used = initial_gas - call_result.gas_left;
    // Should use more than just intrinsic gas (100)
    try testing.expect(gas_used > 100);
    // But less than 1000 (reasonable for simple operations)
    try testing.expect(gas_used < 1000);

    // Check computation result (1 + 2) * 3 = 9
    if (call_result.output) |output| {
        var value: u256 = 0;
        for (output) |byte| {
            value = (value << 8) | byte;
        }
        try testing.expectEqual(@as(u256, 9), value);
    }
}

test "contract call: revert handling" {
    const allocator = testing.allocator;

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    const deployer = primitives.Address.from_u256(0x1111);
    const caller = primitives.Address.from_u256(0x2222);

    try vm.state.set_balance(deployer, 1000000);
    try vm.state.set_balance(caller, 1000000);

    // Deploy a contract that reverts with data
    const init_code = &[_]u8{
        // Constructor
        0x60, 0x0e, // PUSH1 14 (size of runtime code)
        0x60, 0x0c, // PUSH1 12 (offset)
        0x60, 0x00, // PUSH1 0
        0x39, // CODECOPY
        0x60, 0x0e, // PUSH1 14 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN

        // Runtime: store error code then revert
        0x61, 0xde, 0xad, // PUSH2 0xDEAD
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x02, // PUSH1 2 (size)
        0x60, 0x1e, // PUSH1 30 (offset - last 2 bytes of word)
        0xfd, // REVERT
    };

    const create_result = try vm.create_contract(deployer, 0, init_code, 1000000);
    defer if (create_result.output) |output| allocator.free(output);

    try testing.expect(create_result.success);

    // Call the reverting contract
    const initial_gas: u64 = 50000;
    const call_result = try vm.call_contract(caller, create_result.address, 0, &.{}, initial_gas, false);
    defer if (call_result.output) |output| allocator.free(output);

    try testing.expect(!call_result.success);

    // Gas should be partially consumed (not all)
    const gas_used = initial_gas - call_result.gas_left;
    try testing.expect(gas_used > 100); // More than intrinsic
    try testing.expect(gas_used < initial_gas); // Not all consumed

    // Check revert data
    try testing.expect(call_result.output != null);
    if (call_result.output) |output| {
        try testing.expectEqual(@as(usize, 2), output.len);
        try testing.expectEqual(@as(u8, 0xde), output[0]);
        try testing.expectEqual(@as(u8, 0xad), output[1]);
    }
}

test "contract call: input data passing" {
    const allocator = testing.allocator;

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    const deployer = primitives.Address.from_u256(0x1111);
    const caller = primitives.Address.from_u256(0x2222);

    try vm.state.set_balance(deployer, 1000000);
    try vm.state.set_balance(caller, 1000000);

    // Deploy a contract that returns calldata
    const init_code = &[_]u8{
        // Constructor
        0x60, 0x15, // PUSH1 21 (size)
        0x60, 0x0c, // PUSH1 12 (offset)
        0x60, 0x00, // PUSH1 0
        0x39, // CODECOPY
        0x60, 0x15, // PUSH1 21 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN

        // Runtime: copy calldata to memory and return it
        0x36, // CALLDATASIZE
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (dest)
        0x37, // CALLDATACOPY
        0x36, // CALLDATASIZE (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN
    };

    const create_result = try vm.create_contract(deployer, 0, init_code, 1000000);
    defer if (create_result.output) |output| allocator.free(output);

    try testing.expect(create_result.success);

    // Call with input data
    const input_data = &[_]u8{ 0x11, 0x22, 0x33, 0x44 };
    const call_result = try vm.call_contract(caller, create_result.address, 0, input_data, 100000, false);
    defer if (call_result.output) |output| allocator.free(output);

    try testing.expect(call_result.success);

    // Check output matches input
    try testing.expect(call_result.output != null);
    if (call_result.output) |output| {
        try testing.expectEqualSlices(u8, input_data, output);
    }
}

test "contract call: call depth limit" {
    const allocator = testing.allocator;

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    const caller = primitives.Address.from_u256(0x1111);
    const contract = primitives.Address.from_u256(0x2222);

    try vm.state.set_balance(caller, 1000000);

    // Set depth to maximum (1023)
    vm.depth = 1023;

    // This call should succeed (depth becomes 1024)
    const result1 = try vm.call_contract(caller, contract, 0, &.{}, 100000, false);
    defer if (result1.output) |output| allocator.free(output);

    try testing.expect(result1.success);

    // Reset VM for next test
    vm.depth = 1024;

    // This call should fail (would exceed depth limit)
    const result2 = try vm.call_contract(caller, contract, 0, &.{}, 100000, false);
    defer if (result2.output) |output| allocator.free(output);

    try testing.expect(!result2.success);
    try testing.expectEqual(@as(u64, 100000), result2.gas_left); // No gas consumed
}

test "contract call: value transfer rollback on failure" {
    const allocator = testing.allocator;

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    const deployer = primitives.Address.from_u256(0x1111);
    const caller = primitives.Address.from_u256(0x2222);

    try vm.state.set_balance(deployer, 1000000);
    try vm.state.set_balance(caller, 1000000);

    // Deploy a contract that always reverts
    const init_code = &[_]u8{
        // Constructor
        0x60, 0x05, // PUSH1 5 (size)
        0x60, 0x0c, // PUSH1 12 (offset)
        0x60, 0x00, // PUSH1 0
        0x39, // CODECOPY
        0x60, 0x05, // PUSH1 5 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN

        // Runtime: always revert
        0x60, 0x00, // PUSH1 0 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xfd, // REVERT
    };

    const create_result = try vm.create_contract(deployer, 0, init_code, 1000000);
    defer if (create_result.output) |output| allocator.free(output);

    try testing.expect(create_result.success);

    const initial_caller_balance = vm.state.get_balance(caller);
    const initial_contract_balance = vm.state.get_balance(create_result.address);

    // Call with value - should fail and rollback
    const call_result = try vm.call_contract(caller, create_result.address, 5000, // value
        &.{}, 100000, false);
    defer if (call_result.output) |output| allocator.free(output);

    try testing.expect(!call_result.success);

    // Balances should be unchanged
    try testing.expectEqual(initial_caller_balance, vm.state.get_balance(caller));
    try testing.expectEqual(initial_contract_balance, vm.state.get_balance(create_result.address));
}
