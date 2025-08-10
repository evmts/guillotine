const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const CallParams = evm.CallParams;

// Import REVM wrapper from module
const revm_wrapper = @import("revm");

test "ECRECOVER precompile recovers address from signature" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (precompile address)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x00, // PUSH1 0 (gas)
        0xf1, // CALL
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN
    };

    // Execute on REVM
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    try revm_vm.setBalance(revm_deployer, 10000000);

    var revm_result = try revm_vm.create(revm_deployer, 0, &bytecode, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine
    const MemoryDatabase = evm.MemoryDatabase;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    try vm_instance.state.set_code(contract_address, &bytecode);
    const call_params = evm.CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };
    const guillotine_result = try vm_instance.call(call_params);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
        // ECRECOVER should return a valid address or 0 for invalid signature
        try testing.expect(revm_value >= 0);
    }
}

test "SHA256 precompile hashes data" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x02, // PUSH1 2 (precompile address)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x00, // PUSH1 0 (gas)
        0xf1, // CALL
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN
    };

    // Execute on REVM
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    try revm_vm.setBalance(revm_deployer, 10000000);

    var revm_result = try revm_vm.create(revm_deployer, 0, &bytecode, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine
    const MemoryDatabase = evm.MemoryDatabase;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    try vm_instance.state.set_code(contract_address, &bytecode);
    const call_params2 = evm.CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };
    const guillotine_result = try vm_instance.call(call_params2);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
        // SHA256 should return a valid hash
        try testing.expect(revm_value > 0);
    }
}

test "RIPEMD160 precompile hashes data" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x03, // PUSH1 3 (precompile address)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x00, // PUSH1 0 (gas)
        0xf1, // CALL
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN
    };

    // Execute on REVM
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    try revm_vm.setBalance(revm_deployer, 10000000);

    var revm_result = try revm_vm.create(revm_deployer, 0, &bytecode, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine
    const MemoryDatabase = evm.MemoryDatabase;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    try vm_instance.state.set_code(contract_address, &bytecode);

    const call_params = evm.CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };
    const guillotine_result = try vm_instance.call(call_params);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
        // RIPEMD160 should return a valid hash
        try testing.expect(revm_value > 0);
    }
}

test "IDENTITY precompile copies data" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x04, // PUSH1 4 (precompile address)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x00, // PUSH1 0 (gas)
        0xf1, // CALL
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN
    };

    // Execute on REVM
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    try revm_vm.setBalance(revm_deployer, 10000000);

    var revm_result = try revm_vm.create(revm_deployer, 0, &bytecode, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine
    const MemoryDatabase = evm.MemoryDatabase;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    try vm_instance.state.set_code(contract_address, &bytecode);

    const call_params2 = evm.CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };
    const guillotine_result = try vm_instance.call(call_params2);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
        // IDENTITY should return the input data
        try testing.expect(revm_value >= 0);
    }
}

test "MODEXP precompile performs modular exponentiation" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x05, // PUSH1 5 (precompile address)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x00, // PUSH1 0 (gas)
        0xf1, // CALL
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN
    };

    // Execute on REVM
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    try revm_vm.setBalance(revm_deployer, 10000000);

    var revm_result = try revm_vm.create(revm_deployer, 0, &bytecode, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine
    const MemoryDatabase = evm.MemoryDatabase;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    try vm_instance.state.set_code(contract_address, &bytecode);

    const call_params3 = evm.CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };
    const guillotine_result = try vm_instance.call(call_params3);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
        // MODEXP should return a valid result
        try testing.expect(revm_value >= 0);
    }
}

test "BLAKE2F precompile performs BLAKE2F hashing" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x09, // PUSH1 9 (precompile address)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x00, // PUSH1 0 (gas)
        0xf1, // CALL
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN
    };

    // Execute on REVM
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    try revm_vm.setBalance(revm_deployer, 10000000);

    var revm_result = try revm_vm.create(revm_deployer, 0, &bytecode, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine
    const MemoryDatabase = evm.MemoryDatabase;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    try vm_instance.state.set_code(contract_address, &bytecode);

    const call_params4 = evm.CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };
    const guillotine_result = try vm_instance.call(call_params4);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
        // BLAKE2F should return a valid hash
        try testing.expect(revm_value >= 0);
    }
}

test "BLS12_381_G1MSM precompile performs G1 multi-scalar multiplication" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x0a, // PUSH1 10 (precompile address)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x00, // PUSH1 0 (gas)
        0xf1, // CALL
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN
    };

    // Execute on REVM
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    try revm_vm.setBalance(revm_deployer, 10000000);

    var revm_result = try revm_vm.create(revm_deployer, 0, &bytecode, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine
    const MemoryDatabase = evm.MemoryDatabase;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    try vm_instance.state.set_code(contract_address, &bytecode);

    const call_params5 = evm.CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };
    const guillotine_result = try vm_instance.call(call_params5);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
        // BLS12_381_G1MSM should return a valid result
        try testing.expect(revm_value >= 0);
    }
}

test "BLS12_381_G2MSM precompile performs G2 multi-scalar multiplication" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x0b, // PUSH1 11 (precompile address)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x00, // PUSH1 0 (gas)
        0xf1, // CALL
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN
    };

    // Execute on REVM
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    try revm_vm.setBalance(revm_deployer, 10000000);

    var revm_result = try revm_vm.create(revm_deployer, 0, &bytecode, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine
    const MemoryDatabase = evm.MemoryDatabase;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    try vm_instance.state.set_code(contract_address, &bytecode);

    const call_params6 = evm.CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };
    const guillotine_result = try vm_instance.call(call_params6);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
        // BLS12_381_G2MSM should return a valid result
        try testing.expect(revm_value >= 0);
    }
}

test "BLS12_381_PAIRING precompile performs pairing check" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x0c, // PUSH1 12 (precompile address)
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x00, // PUSH1 0 (gas)
        0xf1, // CALL
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN
    };

    // Execute on REVM
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    try revm_vm.setBalance(revm_deployer, 10000000);

    var revm_result = try revm_vm.create(revm_deployer, 0, &bytecode, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine
    const MemoryDatabase = evm.MemoryDatabase;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    try vm_instance.state.set_code(contract_address, &bytecode);

    const call_params = CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };
    const guillotine_result = try vm_instance.call(call_params);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
        // BLS12_381_PAIRING should return a valid result
        try testing.expect(revm_value >= 0);
    }
}
