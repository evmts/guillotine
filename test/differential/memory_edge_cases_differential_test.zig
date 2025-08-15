const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const CallParams = evm.CallParams;
const CallResult = evm.CallResult;

// Import REVM wrapper from module
const revm_wrapper = @import("revm");

// Tests for memory operations edge cases
// Tests: MLOAD, MSTORE, MSTORE8, MCOPY, memory expansion costs

test "MSTORE at large offset triggers memory expansion" {
    const allocator = testing.allocator;

    // PUSH32 large_offset, PUSH1 0x42, MSTORE, MSIZE, RETURN
    const bytecode = [_]u8{
        0x7F, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // offset = 0x1000 (4096)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
        0x60, 0x42, // PUSH1 0x42 (value to store)
        0x52, // MSTORE
        0x59, // MSIZE (get memory size)
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE (store msize at offset 0)
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

        // Memory should be expanded to at least 0x1020 (4128) bytes
        try testing.expect(revm_value >= 0x1020);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "MLOAD from uninitialized memory returns zero" {
    const allocator = testing.allocator;

    // PUSH2 offset, MLOAD, RETURN (load from offset 0x100)
    const bytecode = [_]u8{
        0x61, 0x01, 0x00, // PUSH2 0x0100 (offset 256)
        0x51, // MLOAD
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

        // Uninitialized memory should return 0
        try testing.expectEqual(@as(u256, 0), revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "MSTORE8 stores single byte correctly" {
    const allocator = testing.allocator;

    // Store 0xFF at offset 10, then load the full 32 bytes
    const bytecode = [_]u8{
        0x60, 0xFF, // PUSH1 0xFF (value)
        0x60, 0x0A, // PUSH1 0x0A (offset 10)
        0x53, // MSTORE8
        0x60, 0x00, // PUSH1 0 (offset)
        0x51, // MLOAD (load 32 bytes from offset 0)
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

        // Check that byte at offset 10 is 0xFF
        try testing.expectEqual(@as(u8, 0xFF), revm_result.output[10]);
        try testing.expectEqual(@as(u8, 0xFF), mini_result.output.?[10]);
        try testing.expectEqual(@as(u8, 0xFF), guillotine_result.output.?[10]);

        // Check other bytes are zero
        for (0..10) |i| {
            try testing.expectEqual(@as(u8, 0), revm_result.output[i]);
        }
        for (11..32) |i| {
            try testing.expectEqual(@as(u8, 0), revm_result.output[i]);
        }
    }
}

test "MCOPY opcode copies memory correctly" {
    const allocator = testing.allocator;

    // Store pattern, then copy it to another location
    const bytecode = [_]u8{
        // Store 0xDEADBEEF at offset 0
        0x63, 0xDE, 0xAD, 0xBE, 0xEF, // PUSH4 0xDEADBEEF
        0x60, 0x00, // PUSH1 0 (offset)
        0x52, // MSTORE
        // Copy 32 bytes from offset 0 to offset 32
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (source offset)
        0x60, 0x20, // PUSH1 32 (dest offset)
        0x5E, // MCOPY
        // Load from offset 32 and return
        0x60, 0x20, // PUSH1 32 (offset)
        0x51, // MLOAD
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

        // Should have copied 0xDEADBEEF
        try testing.expectEqual(@as(u256, 0xDEADBEEF), revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "MCOPY overlapping regions copies correctly" {
    const allocator = testing.allocator;

    // Test overlapping memory copy (similar to memmove behavior)
    const bytecode = [_]u8{
        // Store pattern at offset 0
        0x7F, // PUSH32
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x60, 0x00, // PUSH1 0 (offset)
        0x52, // MSTORE
        // Copy 24 bytes from offset 0 to offset 8 (overlapping)
        0x60, 0x18, // PUSH1 24 (size)
        0x60, 0x00, // PUSH1 0 (source offset)
        0x60, 0x08, // PUSH1 8 (dest offset)
        0x5E, // MCOPY
        // Load from offset 8 and return
        0x60, 0x08, // PUSH1 8 (offset)
        0x51, // MLOAD
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

        // Compare exact bytes
        try testing.expectEqualSlices(u8, revm_result.output, mini_result.output.?);
        try testing.expectEqualSlices(u8, revm_result.output, guillotine_result.output.?);
    }
}

test "Memory expansion gas cost edge case" {
    const allocator = testing.allocator;

    // Test that runs out of gas due to memory expansion
    const bytecode = [_]u8{
        0x7F, // PUSH32
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // Very large offset
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x60, 0x42, // PUSH1 0x42
        0x52, // MSTORE (should fail due to gas)
        0x60, 0x01, // PUSH1 1 (should not reach here)
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    // Execute on REVM with limited gas
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const revm_contract_address = try Address.from_hex("0x2222222222222222222222222222222222222222");

    // Set balance for deployer
    try revm_vm.setBalance(revm_deployer, 10000000);

    // Set the bytecode as contract code (like Guillotine does)
    try revm_vm.setCode(revm_contract_address, &bytecode);

    // Call with limited gas
    var revm_result = try revm_vm.call(revm_deployer, revm_contract_address, 0, &[_]u8{}, 10000);
    defer revm_result.deinit();

    // Execute on Guillotine
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

    // Execute using new call API with limited gas
    const call_params = CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 10000,
    } };

    // Execute using mini EVM (after REVM, before Guillotine)
    const mini_result = try vm_instance.call_mini(call_params);
    defer if (mini_result.output) |output| allocator.free(output);

    // Execute using Guillotine regular EVM
    const guillotine_result = try vm_instance.call(call_params);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // All should fail due to out of gas
    try testing.expect(!revm_result.success);
    try testing.expect(!mini_result.success);
    try testing.expect(!guillotine_result.success);

    // Gas should be consumed
    try testing.expect(revm_result.gas_used > 0);
    try testing.expect(mini_result.gas_left < 10000);
    try testing.expect(guillotine_result.gas_left < 10000);
}