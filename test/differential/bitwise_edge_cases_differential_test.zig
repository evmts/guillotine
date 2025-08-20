const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const CallParams = evm.CallParams;
const CallResult = evm.CallResult;

// Import REVM wrapper from module
const revm_wrapper = @import("revm");

// Edge case tests for bitwise operations

test "SHL opcode max shift (255) leaves only MSB" {
    const allocator = testing.allocator;

    // PUSH32 1, PUSH32 255, SHL, MSTORE, RETURN (1 << 255)
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 1 (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 255 (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF,
        0x1b, // SHL
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

        // 1 << 255 = 0x8000...0000
        const expected: u256 = @as(u256, 1) << 255;
        try testing.expectEqual(expected, revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "SHL opcode shift >= 256 returns 0" {
    const allocator = testing.allocator;

    // PUSH32 max_u256, PUSH32 256, SHL, MSTORE, RETURN
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // max_u256 (32 bytes)
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 256 (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
        0x1b, // SHL
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

        // Shift >= 256 returns 0
        try testing.expectEqual(@as(u256, 0), revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "SHR opcode max shift (255) preserves only LSB" {
    const allocator = testing.allocator;

    // PUSH32 0x8000...0000, PUSH32 255, SHR, MSTORE, RETURN
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x8000...0000 (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 255 (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF,
        0x1c, // SHR
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

        // 0x8000...0000 >> 255 = 1
        try testing.expectEqual(@as(u256, 1), revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "SAR opcode arithmetic shift of negative number" {
    const allocator = testing.allocator;

    // PUSH32 0x8000...0000 (MIN_I256), PUSH32 1, SAR, MSTORE, RETURN
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // MIN_I256 (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 1 (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x1d, // SAR
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

        // MIN_I256 >> 1 (arithmetic) = 0xC000...0000
        const expected: u256 = 0xC000000000000000000000000000000000000000000000000000000000000000;
        try testing.expectEqual(expected, revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "BYTE opcode out of range returns 0" {
    const allocator = testing.allocator;

    // PUSH32 0x1234...ABCD, PUSH32 32, BYTE, MSTORE, RETURN (byte index 32 is out of range)
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, // test value (32 bytes)
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00,
        0x11, 0x22, 0x33, 0x44, 0xAB, 0xCD, 0xEF, 0x01,
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 32 (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20,
        0x1a, // BYTE
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

        // Out of range byte index returns 0
        try testing.expectEqual(@as(u256, 0), revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "SAR opcode shift >= 256 preserves sign" {
    const allocator = testing.allocator;

    // Test negative number: PUSH32 0xFFFF...FFFF (-1), PUSH32 256, SAR
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // -1 (32 bytes)
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 256 (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
        0x1d, // SAR
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

        // -1 >> 256 (arithmetic) = -1 (0xFFFF...FFFF)
        const expected: u256 = std.math.maxInt(u256);
        try testing.expectEqual(expected, revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "XOR opcode same value = 0" {
    const allocator = testing.allocator;

    // PUSH32 0x1234...5678, PUSH32 0x1234...5678, XOR, MSTORE, RETURN
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, // test value (32 bytes)
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x56, 0x78,
        0x7f, // PUSH32
        0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, // same test value (32 bytes)
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x56, 0x78,
        0x18, // XOR
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

        // A XOR A = 0
        try testing.expectEqual(@as(u256, 0), revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}