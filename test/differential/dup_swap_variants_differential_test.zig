const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const CallParams = evm.CallParams;
const CallResult = evm.CallResult;

// Import REVM wrapper from module
const revm_wrapper = @import("revm");

// Tests for DUP2-DUP16 and SWAP2-SWAP16 opcode variants

test "DUP2 opcode duplicates second stack element" {
    const allocator = testing.allocator;

    // PUSH1 0x11, PUSH1 0x22, DUP2, MSTORE, RETURN
    // Stack: [0x11, 0x22] -> DUP2 -> [0x11, 0x22, 0x11]
    const bytecode = [_]u8{
        0x60, 0x11, // PUSH1 0x11
        0x60, 0x22, // PUSH1 0x22
        0x81, // DUP2
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

        // DUP2 should duplicate 0x11
        try testing.expectEqual(@as(u256, 0x11), revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "DUP16 opcode duplicates 16th stack element" {
    const allocator = testing.allocator;

    // Push 16 different values, DUP16, MSTORE, RETURN
    // DUP16 should duplicate the 16th element (0x01)
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 0x01 (16th from top after all pushes)
        0x60, 0x02, // PUSH1 0x02
        0x60, 0x03, // PUSH1 0x03
        0x60, 0x04, // PUSH1 0x04
        0x60, 0x05, // PUSH1 0x05
        0x60, 0x06, // PUSH1 0x06
        0x60, 0x07, // PUSH1 0x07
        0x60, 0x08, // PUSH1 0x08
        0x60, 0x09, // PUSH1 0x09
        0x60, 0x0A, // PUSH1 0x0A
        0x60, 0x0B, // PUSH1 0x0B
        0x60, 0x0C, // PUSH1 0x0C
        0x60, 0x0D, // PUSH1 0x0D
        0x60, 0x0E, // PUSH1 0x0E
        0x60, 0x0F, // PUSH1 0x0F
        0x60, 0x10, // PUSH1 0x10 (top of stack)
        0x8F, // DUP16
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

        // DUP16 should duplicate 0x01
        try testing.expectEqual(@as(u256, 0x01), revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "SWAP2 opcode swaps 1st and 3rd stack elements" {
    const allocator = testing.allocator;

    // PUSH1 0x11, PUSH1 0x22, PUSH1 0x33, SWAP2, MSTORE, RETURN
    // Stack: [0x11, 0x22, 0x33] -> SWAP2 -> [0x33, 0x22, 0x11]
    const bytecode = [_]u8{
        0x60, 0x11, // PUSH1 0x11
        0x60, 0x22, // PUSH1 0x22
        0x60, 0x33, // PUSH1 0x33
        0x91, // SWAP2
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

        // After SWAP2, top of stack is 0x11
        try testing.expectEqual(@as(u256, 0x11), revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "SWAP16 opcode swaps 1st and 17th stack elements" {
    const allocator = testing.allocator;

    // Push 17 values, SWAP16, then return the top value
    // SWAP16 should swap top (0x11) with 17th (0x01)
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 0x01 (will be 17th from top)
        0x60, 0x02, // PUSH1 0x02
        0x60, 0x03, // PUSH1 0x03
        0x60, 0x04, // PUSH1 0x04
        0x60, 0x05, // PUSH1 0x05
        0x60, 0x06, // PUSH1 0x06
        0x60, 0x07, // PUSH1 0x07
        0x60, 0x08, // PUSH1 0x08
        0x60, 0x09, // PUSH1 0x09
        0x60, 0x0A, // PUSH1 0x0A
        0x60, 0x0B, // PUSH1 0x0B
        0x60, 0x0C, // PUSH1 0x0C
        0x60, 0x0D, // PUSH1 0x0D
        0x60, 0x0E, // PUSH1 0x0E
        0x60, 0x0F, // PUSH1 0x0F
        0x60, 0x10, // PUSH1 0x10
        0x60, 0x11, // PUSH1 0x11 (top of stack)
        0x9F, // SWAP16
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

        // After SWAP16, top of stack should be 0x01
        try testing.expectEqual(@as(u256, 0x01), revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "DUP8 opcode duplicates 8th stack element" {
    const allocator = testing.allocator;

    // Push 8 different values, DUP8, MSTORE, RETURN
    const bytecode = [_]u8{
        0x60, 0xAA, // PUSH1 0xAA (8th from top after all pushes)
        0x60, 0x02, // PUSH1 0x02
        0x60, 0x03, // PUSH1 0x03
        0x60, 0x04, // PUSH1 0x04
        0x60, 0x05, // PUSH1 0x05
        0x60, 0x06, // PUSH1 0x06
        0x60, 0x07, // PUSH1 0x07
        0x60, 0x08, // PUSH1 0x08 (top of stack)
        0x87, // DUP8
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

        // DUP8 should duplicate 0xAA
        try testing.expectEqual(@as(u256, 0xAA), revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}

test "SWAP8 opcode swaps 1st and 9th stack elements" {
    const allocator = testing.allocator;

    // Push 9 values, SWAP8, then return the top value
    const bytecode = [_]u8{
        0x60, 0xBB, // PUSH1 0xBB (will be 9th from top)
        0x60, 0x02, // PUSH1 0x02
        0x60, 0x03, // PUSH1 0x03
        0x60, 0x04, // PUSH1 0x04
        0x60, 0x05, // PUSH1 0x05
        0x60, 0x06, // PUSH1 0x06
        0x60, 0x07, // PUSH1 0x07
        0x60, 0x08, // PUSH1 0x08
        0x60, 0x09, // PUSH1 0x09 (top of stack)
        0x97, // SWAP8
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

        // After SWAP8, top of stack should be 0xBB
        try testing.expectEqual(@as(u256, 0xBB), revm_value);
        try testing.expectEqual(revm_value, mini_value);
        try testing.expectEqual(revm_value, guillotine_value);
    }
}