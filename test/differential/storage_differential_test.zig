const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;

// Import REVM wrapper from module
const revm_wrapper = @import("revm");

test "SSTORE then SLOAD storage operations" {
    const allocator = testing.allocator;

    // PUSH32 0x42, PUSH32 0x00, SSTORE, PUSH32 0x00, SLOAD, MSTORE, RETURN
    // Store 0x42 at storage slot 0, then load from slot 0 and return it
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x42 (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x42,
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x00 (32 bytes) - storage slot
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x55, // SSTORE (store value to storage)
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x00 (32 bytes) - storage slot
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x54, // SLOAD (load value from storage)
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
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

    // Execute the contract using call API
    const call_params = evm.CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };
    const guillotine_result = try vm_instance.call(call_params);
    // VM owns guillotine_result.output; do not free here

    // Compare results - both should succeed
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        // Extract u256 from output (big-endian)
        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
    } else {
        // If either failed, print debug info
        // Error details not available in new API
        // For SSTORE/SLOAD, we expect this to succeed
        try testing.expect(false);
    }
}

test "SLOAD from empty storage slot returns 0" {
    const allocator = testing.allocator;

    // PUSH32 0x99, SLOAD, MSTORE, RETURN
    // Load from empty storage slot 0x99 (should return 0)
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x99 (32 bytes) - storage slot
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x99,
        0x54, // SLOAD (load value from storage)
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
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

    // Execute the contract using call API
    const call_params2 = evm.CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };
    const guillotine_result = try vm_instance.call(call_params2);
    // VM owns guillotine_result.output; do not free here

    // Compare results - both should succeed
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        // Extract u256 from output (big-endian)
        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
    } else {
        // If either failed, print debug info
        // Error details not available in new API
        // For SLOAD empty slot, we expect this to succeed
        try testing.expect(false);
    }
}

test "TSTORE then TLOAD transient storage operations" {
    const allocator = testing.allocator;

    // PUSH32 0x123, PUSH32 0x01, TSTORE, PUSH32 0x01, TLOAD, MSTORE, RETURN
    // Store 0x123 at transient slot 1, then load from slot 1 and return it
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x123 (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x23,
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x01 (32 bytes) - transient slot
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x5D, // TSTORE (store value to transient storage)
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x01 (32 bytes) - transient slot
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x5C, // TLOAD (load value from transient storage)
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
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

    // Execute the contract using call API
    const call_params3 = evm.CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };
    const guillotine_result = try vm_instance.call(call_params3);
    // VM owns guillotine_result.output; do not free here

    // Compare results - both should succeed
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        // Extract u256 from output (big-endian)
        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
    } else {
        // If either failed, print debug info
        // Error details not available in new API
        // For TSTORE/TLOAD, we expect this to succeed
        try testing.expect(false);
    }
}
