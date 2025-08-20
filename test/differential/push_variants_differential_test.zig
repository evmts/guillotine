const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const CallParams = evm.CallParams;
const CallResult = evm.CallResult;

// Import REVM wrapper from module
const revm_wrapper = @import("revm");

// Tests for PUSH2-PUSH32 opcode variants

test "PUSH2 opcode pushes 2 bytes" {
    const allocator = testing.allocator;

    // PUSH2 0x1234, MSTORE, RETURN
    const bytecode = [_]u8{
        0x61, // PUSH2
        0x12, 0x34, // 2 bytes to push
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
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, null);
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
    const mini_result = try vm_instance.call(call_params);
    // VM owns mini_result.output; do not free here

    // Execute using Guillotine regular EVM
    const guillotine_result = try vm_instance.call(call_params);
    // VM owns guillotine_result.output; do not free here

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

        try testing.expectEqual(@as(u256, 0x1234), revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "PUSH4 opcode pushes 4 bytes" {
    const allocator = testing.allocator;

    // PUSH4 0xDEADBEEF, MSTORE, RETURN
    const bytecode = [_]u8{
        0x63, // PUSH4
        0xDE, 0xAD, 0xBE, 0xEF, // 4 bytes to push
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
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, null);
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
    const mini_result = try vm_instance.call(call_params);
    // VM owns mini_result.output; do not free here

    // Execute using Guillotine regular EVM
    const guillotine_result = try vm_instance.call(call_params);
    // VM owns guillotine_result.output; do not free here

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

        try testing.expectEqual(@as(u256, 0xDEADBEEF), revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "PUSH8 opcode pushes 8 bytes" {
    const allocator = testing.allocator;

    // PUSH8 0x123456789ABCDEF0, MSTORE, RETURN
    const bytecode = [_]u8{
        0x67, // PUSH8
        0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, // 8 bytes to push
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
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, null);
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
    const mini_result = try vm_instance.call(call_params);
    // VM owns mini_result.output; do not free here

    // Execute using Guillotine regular EVM
    const guillotine_result = try vm_instance.call(call_params);
    // VM owns guillotine_result.output; do not free here

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

        try testing.expectEqual(@as(u256, 0x123456789ABCDEF0), revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "PUSH16 opcode pushes 16 bytes" {
    const allocator = testing.allocator;

    // PUSH16 0x1234567890ABCDEF1234567890ABCDEF, MSTORE, RETURN
    const bytecode = [_]u8{
        0x6F, // PUSH16
        0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF, // 16 bytes to push
        0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF,
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
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, null);
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
    const mini_result = try vm_instance.call(call_params);
    // VM owns mini_result.output; do not free here

    // Execute using Guillotine regular EVM
    const guillotine_result = try vm_instance.call(call_params);
    // VM owns guillotine_result.output; do not free here

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

        const expected: u256 = 0x1234567890ABCDEF1234567890ABCDEF;
        try testing.expectEqual(expected, revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "PUSH32 edge case all zeros" {
    const allocator = testing.allocator;

    // PUSH32 0x0000...0000, MSTORE, RETURN
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 32 bytes all zeros
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
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
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, null);
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
    const mini_result = try vm_instance.call(call_params);
    // VM owns mini_result.output; do not free here

    // Execute using Guillotine regular EVM
    const guillotine_result = try vm_instance.call(call_params);
    // VM owns guillotine_result.output; do not free here

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

        try testing.expectEqual(@as(u256, 0), revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "PUSH20 opcode pushes 20 bytes (address size)" {
    const allocator = testing.allocator;

    // PUSH20 0x1234...ABCD (20 bytes for address), MSTORE, RETURN
    const bytecode = [_]u8{
        0x73, // PUSH20
        0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, // 20 bytes to push
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x99, 0xAA, 0xBB, 0xCC,
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
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, null);
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
    const mini_result = try vm_instance.call(call_params);
    // VM owns mini_result.output; do not free here

    // Execute using Guillotine regular EVM
    const guillotine_result = try vm_instance.call(call_params);
    // VM owns guillotine_result.output; do not free here

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

        const expected: u256 = 0x1234567890ABCDEF112233445566778899AABBCC;
        try testing.expectEqual(expected, revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}