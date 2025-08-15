const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const CallParams = evm.CallParams;
const CallResult = evm.CallResult;

// Import REVM wrapper from module
const revm_wrapper = @import("revm");

// Tests for call operation edge cases
// Tests: CALL, DELEGATECALL, STATICCALL, CALLCODE, gas allocation, value transfer

test "CALL with insufficient gas for base cost" {
    const allocator = testing.allocator;

    // Call with very limited gas (less than base cost)
    const bytecode = [_]u8{
        0x60, 0x64, // PUSH1 100 (gas - not enough for base cost)
        0x5F, // PUSH0 (retSize)
        0x5F, // PUSH0 (retOffset)
        0x5F, // PUSH0 (argSize)
        0x5F, // PUSH0 (argOffset)
        0x5F, // PUSH0 (value)
        0x5F, // PUSH0 (address)
        0xF1, // CALL
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE (store result)
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    // Execute on REVM - inline all setup
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const revm_contract_address = try Address.from_hex("0x2222222222222222222222222222222222222222");

    // Set balance for deployer
    try revm_vm.setBalance(revm_deployer, 10000000);

    // Set the bytecode as contract code (like Guillotine does)
    try revm_vm.setCode(revm_contract_address, &bytecode);

    // Call the contract to execute the bytecode
    var revm_result = try revm_vm.call(revm_deployer, revm_contract_address, 0, &[_]u8{}, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine - inline all setup
    const MemoryDatabase = evm.MemoryDatabase;

    // Create EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    // Set the code for the contract address in EVM state
    try vm_instance.state.set_code(contract_address, &bytecode);

    // Execute using new call API
    const call_params = CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };

    // Execute using mini EVM (after REVM, before Guillotine)
    const mini_result = try vm_instance.call_mini(call_params);
    defer if (mini_result.output) |output| allocator.free(output);

    // Execute using Guillotine regular EVM
    const guillotine_result = try vm_instance.call(call_params);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results - all three should succeed (CALL should fail but not revert)
    const revm_succeeded = revm_result.success;
    const mini_succeeded = mini_result.success;
    const guillotine_succeeded = guillotine_result.success;

    try testing.expect(revm_succeeded == mini_succeeded);
    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and mini_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(mini_result.output != null);
        try testing.expect(mini_result.output.?.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        // Extract u256 from output (big-endian)
        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const mini_value = std.mem.readInt(u256, mini_result.output.?[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        // CALL should push 0 (failure) to stack due to insufficient gas
        try testing.expectEqual(@as(u256, 0), revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "DELEGATECALL preserves msg.sender and msg.value" {
    const allocator = testing.allocator;

    // Callee contract that returns msg.sender and msg.value
    const callee_bytecode = [_]u8{
        0x33, // CALLER (msg.sender)
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x34, // CALLVALUE (msg.value)
        0x60, 0x20, // PUSH1 32
        0x52, // MSTORE
        0x60, 0x40, // PUSH1 64 (return size)
        0x60, 0x00, // PUSH1 0 (return offset)
        0xF3, // RETURN
    };

    // Caller contract that uses DELEGATECALL
    const caller_bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (retSize)
        0x60, 0x00, // PUSH1 0 (retOffset)
        0x60, 0x00, // PUSH1 0 (argSize)
        0x60, 0x00, // PUSH1 0 (argOffset)
        0x73, // PUSH20 (callee address)
        0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33,
        0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33,
        0x33, 0x33, 0x33, 0x33,
        0x62, 0x01, 0x00, 0x00, // PUSH3 65536 (gas)
        0xF4, // DELEGATECALL
        0x50, // POP (discard success)
        0x60, 0x40, // PUSH1 64 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xF3, // RETURN
    };

    // Execute on REVM - inline all setup
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const revm_caller_address = try Address.from_hex("0x2222222222222222222222222222222222222222");
    const revm_callee_address = try Address.from_hex("0x3333333333333333333333333333333333333333");

    // Set balance for deployer
    try revm_vm.setBalance(revm_deployer, 10000000);

    // Set the bytecodes
    try revm_vm.setCode(revm_caller_address, &caller_bytecode);
    try revm_vm.setCode(revm_callee_address, &callee_bytecode);

    // Call the contract with value
    var revm_result = try revm_vm.call(revm_deployer, revm_caller_address, 1234, &[_]u8{}, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine - inline all setup
    const MemoryDatabase = evm.MemoryDatabase;

    // Create EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm_instance.deinit();

    const caller_address = Address.from_u256(0x2222222222222222222222222222222222222222);
    const callee_address = Address.from_u256(0x3333333333333333333333333333333333333333);
    const deployer_address = Address.from_u256(0x1111111111111111111111111111111111111111);

    // Set the codes
    try vm_instance.state.set_code(caller_address, &caller_bytecode);
    try vm_instance.state.set_code(callee_address, &callee_bytecode);

    // Execute using new call API with value
    const call_params = CallParams{ .call = .{
        .caller = deployer_address,
        .to = caller_address,
        .value = 1234,
        .input = &[_]u8{},
        .gas = 1000000,
    } };

    // Execute using mini EVM (after REVM, before Guillotine)
    const mini_result = try vm_instance.call_mini(call_params);
    defer if (mini_result.output) |output| allocator.free(output);

    // Execute using Guillotine regular EVM
    const guillotine_result = try vm_instance.call(call_params);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results - all three should succeed
    const revm_succeeded = revm_result.success;
    const mini_succeeded = mini_result.success;
    const guillotine_succeeded = guillotine_result.success;

    try testing.expect(revm_succeeded == mini_succeeded);
    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and mini_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 64);
        try testing.expect(mini_result.output != null);
        try testing.expect(mini_result.output.?.len == 64);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 64);

        // Extract sender and value from output
        const revm_sender = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const revm_value = std.mem.readInt(u256, revm_result.output[32..64], .big);
        
        const mini_sender = std.mem.readInt(u256, mini_result.output.?[0..32], .big);
        const mini_value = std.mem.readInt(u256, mini_result.output.?[32..64], .big);
        
        const guillotine_sender = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[32..64], .big);

        // DELEGATECALL should preserve original sender (deployer) and value (1234)
        const expected_sender = @as(u256, 0x1111111111111111111111111111111111111111);
        const expected_value = @as(u256, 1234);

        try testing.expectEqual(expected_sender, revm_sender);
        try testing.expectEqual(expected_value, revm_value);
        try testing.expectEqual(revm_sender, mini_sender);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_sender, guillotine_sender);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "STATICCALL prevents state modifications" {
    const allocator = testing.allocator;

    // Callee contract that tries to SSTORE
    const callee_bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x01, // PUSH1 0x01
        0x55, // SSTORE (should fail in static context)
        0x60, 0x01, // PUSH1 1 (success)
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Caller contract that uses STATICCALL
    const caller_bytecode = [_]u8{
        0x60, 0x20, // PUSH1 32 (retSize)
        0x60, 0x00, // PUSH1 0 (retOffset)
        0x60, 0x00, // PUSH1 0 (argSize)
        0x60, 0x00, // PUSH1 0 (argOffset)
        0x73, // PUSH20 (callee address)
        0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33,
        0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33,
        0x33, 0x33, 0x33, 0x33,
        0x62, 0x01, 0x00, 0x00, // PUSH3 65536 (gas)
        0xFA, // STATICCALL
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE (store result)
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Execute on REVM - inline all setup
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const revm_caller_address = try Address.from_hex("0x2222222222222222222222222222222222222222");
    const revm_callee_address = try Address.from_hex("0x3333333333333333333333333333333333333333");

    // Set balance for deployer
    try revm_vm.setBalance(revm_deployer, 10000000);

    // Set the bytecodes
    try revm_vm.setCode(revm_caller_address, &caller_bytecode);
    try revm_vm.setCode(revm_callee_address, &callee_bytecode);

    // Call the contract
    var revm_result = try revm_vm.call(revm_deployer, revm_caller_address, 0, &[_]u8{}, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine - inline all setup
    const MemoryDatabase = evm.MemoryDatabase;

    // Create EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm_instance.deinit();

    const caller_address = Address.from_u256(0x2222222222222222222222222222222222222222);
    const callee_address = Address.from_u256(0x3333333333333333333333333333333333333333);
    const deployer_address = Address.from_u256(0x1111111111111111111111111111111111111111);

    // Set the codes
    try vm_instance.state.set_code(caller_address, &caller_bytecode);
    try vm_instance.state.set_code(callee_address, &callee_bytecode);

    // Execute using new call API
    const call_params = CallParams{ .call = .{
        .caller = deployer_address,
        .to = caller_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };

    // Execute using mini EVM (after REVM, before Guillotine)
    const mini_result = try vm_instance.call_mini(call_params);
    defer if (mini_result.output) |output| allocator.free(output);

    // Execute using Guillotine regular EVM
    const guillotine_result = try vm_instance.call(call_params);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results - all three should succeed
    const revm_succeeded = revm_result.success;
    const mini_succeeded = mini_result.success;
    const guillotine_succeeded = guillotine_result.success;

    try testing.expect(revm_succeeded == mini_succeeded);
    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and mini_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(mini_result.output != null);
        try testing.expect(mini_result.output.?.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        // Extract u256 from output (big-endian)
        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const mini_value = std.mem.readInt(u256, mini_result.output.?[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        // STATICCALL should return 0 (failure) because SSTORE is not allowed
        try testing.expectEqual(@as(u256, 0), revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "CALL with value transfer to non-existent account" {
    const allocator = testing.allocator;

    // Call non-existent account with value
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (retSize)
        0x60, 0x00, // PUSH1 0 (retOffset)
        0x60, 0x00, // PUSH1 0 (argSize)
        0x60, 0x00, // PUSH1 0 (argOffset)
        0x60, 0x64, // PUSH1 100 (value in wei)
        0x73, // PUSH20 (non-existent address)
        0x99, 0x99, 0x99, 0x99, 0x99, 0x99, 0x99, 0x99,
        0x99, 0x99, 0x99, 0x99, 0x99, 0x99, 0x99, 0x99,
        0x99, 0x99, 0x99, 0x99,
        0x62, 0x01, 0x00, 0x00, // PUSH3 65536 (gas)
        0xF1, // CALL
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE (store result)
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Execute on REVM - inline all setup
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const revm_contract_address = try Address.from_hex("0x2222222222222222222222222222222222222222");

    // Set balance for deployer and contract
    try revm_vm.setBalance(revm_deployer, 10000000);
    try revm_vm.setBalance(revm_contract_address, 10000);

    // Set the bytecode as contract code
    try revm_vm.setCode(revm_contract_address, &bytecode);

    // Call the contract
    var revm_result = try revm_vm.call(revm_deployer, revm_contract_address, 0, &[_]u8{}, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine - inline all setup
    const MemoryDatabase = evm.MemoryDatabase;

    // Create EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    // Set the code and balance
    try vm_instance.state.set_code(contract_address, &bytecode);
    try vm_instance.state.set_balance(contract_address, 10000);

    // Execute using new call API
    const call_params = CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };

    // Execute using mini EVM (after REVM, before Guillotine)
    const mini_result = try vm_instance.call_mini(call_params);
    defer if (mini_result.output) |output| allocator.free(output);

    // Execute using Guillotine regular EVM
    const guillotine_result = try vm_instance.call(call_params);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results - all three should succeed
    const revm_succeeded = revm_result.success;
    const mini_succeeded = mini_result.success;
    const guillotine_succeeded = guillotine_result.success;

    try testing.expect(revm_succeeded == mini_succeeded);
    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and mini_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(mini_result.output != null);
        try testing.expect(mini_result.output.?.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        // Extract u256 from output (big-endian)
        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const mini_value = std.mem.readInt(u256, mini_result.output.?[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        // CALL should succeed (1) when transferring to non-existent account
        try testing.expectEqual(@as(u256, 1), revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "CALL with exact gas allocation" {
    const allocator = testing.allocator;

    // Callee that uses specific amount of gas
    const callee_bytecode = [_]u8{
        // Do some operations to consume gas
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x01, // ADD
        0x60, 0x03, // PUSH1 3
        0x02, // MUL
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Caller that allocates exact amount of gas
    const caller_bytecode = [_]u8{
        0x60, 0x20, // PUSH1 32 (retSize)
        0x60, 0x00, // PUSH1 0 (retOffset)
        0x60, 0x00, // PUSH1 0 (argSize)
        0x60, 0x00, // PUSH1 0 (argOffset)
        0x60, 0x00, // PUSH1 0 (value)
        0x73, // PUSH20 (callee address)
        0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33,
        0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33,
        0x33, 0x33, 0x33, 0x33,
        0x61, 0x27, 0x10, // PUSH2 10000 (exact gas amount)
        0xF1, // CALL
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE (store result)
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Execute on REVM - inline all setup
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const revm_caller_address = try Address.from_hex("0x2222222222222222222222222222222222222222");
    const revm_callee_address = try Address.from_hex("0x3333333333333333333333333333333333333333");

    // Set balance for deployer
    try revm_vm.setBalance(revm_deployer, 10000000);

    // Set the bytecodes
    try revm_vm.setCode(revm_caller_address, &caller_bytecode);
    try revm_vm.setCode(revm_callee_address, &callee_bytecode);

    // Call the contract
    var revm_result = try revm_vm.call(revm_deployer, revm_caller_address, 0, &[_]u8{}, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine - inline all setup
    const MemoryDatabase = evm.MemoryDatabase;

    // Create EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm_instance.deinit();

    const caller_address = Address.from_u256(0x2222222222222222222222222222222222222222);
    const callee_address = Address.from_u256(0x3333333333333333333333333333333333333333);
    const deployer_address = Address.from_u256(0x1111111111111111111111111111111111111111);

    // Set the codes
    try vm_instance.state.set_code(caller_address, &caller_bytecode);
    try vm_instance.state.set_code(callee_address, &callee_bytecode);

    // Execute using new call API
    const call_params = CallParams{ .call = .{
        .caller = deployer_address,
        .to = caller_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };

    // Execute using mini EVM (after REVM, before Guillotine)
    const mini_result = try vm_instance.call_mini(call_params);
    defer if (mini_result.output) |output| allocator.free(output);

    // Execute using Guillotine regular EVM
    const guillotine_result = try vm_instance.call(call_params);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results - all three should succeed
    const revm_succeeded = revm_result.success;
    const mini_succeeded = mini_result.success;
    const guillotine_succeeded = guillotine_result.success;

    try testing.expect(revm_succeeded == mini_succeeded);
    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and mini_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(mini_result.output != null);
        try testing.expect(mini_result.output.?.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        // Extract u256 from output (big-endian)
        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const mini_value = std.mem.readInt(u256, mini_result.output.?[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        // CALL should succeed (1)
        try testing.expectEqual(@as(u256, 1), revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "CALLCODE modifies caller's storage" {
    const allocator = testing.allocator;

    // Callee contract that stores value
    const callee_bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42 (value)
        0x60, 0x01, // PUSH1 0x01 (key)
        0x55, // SSTORE
        0x60, 0x01, // PUSH1 1 (success)
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Caller contract that uses CALLCODE then loads from storage
    const caller_bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (retSize)
        0x60, 0x00, // PUSH1 0 (retOffset)
        0x60, 0x00, // PUSH1 0 (argSize)
        0x60, 0x00, // PUSH1 0 (argOffset)
        0x60, 0x00, // PUSH1 0 (value)
        0x73, // PUSH20 (callee address)
        0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33,
        0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33,
        0x33, 0x33, 0x33, 0x33,
        0x62, 0x01, 0x00, 0x00, // PUSH3 65536 (gas)
        0xF2, // CALLCODE
        0x50, // POP (discard result)
        0x60, 0x01, // PUSH1 0x01 (key)
        0x54, // SLOAD (should load value stored by CALLCODE)
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Execute on REVM - inline all setup
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const revm_caller_address = try Address.from_hex("0x2222222222222222222222222222222222222222");
    const revm_callee_address = try Address.from_hex("0x3333333333333333333333333333333333333333");

    // Set balance for deployer
    try revm_vm.setBalance(revm_deployer, 10000000);

    // Set the bytecodes
    try revm_vm.setCode(revm_caller_address, &caller_bytecode);
    try revm_vm.setCode(revm_callee_address, &callee_bytecode);

    // Call the contract
    var revm_result = try revm_vm.call(revm_deployer, revm_caller_address, 0, &[_]u8{}, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine - inline all setup
    const MemoryDatabase = evm.MemoryDatabase;

    // Create EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm_instance.deinit();

    const caller_address = Address.from_u256(0x2222222222222222222222222222222222222222);
    const callee_address = Address.from_u256(0x3333333333333333333333333333333333333333);
    const deployer_address = Address.from_u256(0x1111111111111111111111111111111111111111);

    // Set the codes
    try vm_instance.state.set_code(caller_address, &caller_bytecode);
    try vm_instance.state.set_code(callee_address, &callee_bytecode);

    // Execute using new call API
    const call_params = CallParams{ .call = .{
        .caller = deployer_address,
        .to = caller_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };

    // Execute using mini EVM (after REVM, before Guillotine)
    const mini_result = try vm_instance.call_mini(call_params);
    defer if (mini_result.output) |output| allocator.free(output);

    // Execute using Guillotine regular EVM
    const guillotine_result = try vm_instance.call(call_params);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results - all three should succeed
    const revm_succeeded = revm_result.success;
    const mini_succeeded = mini_result.success;
    const guillotine_succeeded = guillotine_result.success;

    try testing.expect(revm_succeeded == mini_succeeded);
    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and mini_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(mini_result.output != null);
        try testing.expect(mini_result.output.?.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        // Extract u256 from output (big-endian)
        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const mini_value = std.mem.readInt(u256, mini_result.output.?[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        // CALLCODE should have stored 0x42 in caller's storage
        try testing.expectEqual(@as(u256, 0x42), revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}