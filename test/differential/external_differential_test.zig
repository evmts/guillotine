const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const CallParams = evm.CallParams;
const CallResult = evm.CallResult;

// Import REVM wrapper from module
const revm_wrapper = @import("revm");

test "EXTCODESIZE opcode - get size of deployed contract" {
    const allocator = testing.allocator;

    // First deploy a contract with known bytecode at a specific address
    const deployed_code = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xF3, // RETURN
    };

    // Contract that queries EXTCODESIZE of the deployed contract
    // PUSH20 target_address, EXTCODESIZE, MSTORE, RETURN
    var bytecode = [_]u8{0} ** 200;
    var pos: usize = 0;
    
    // PUSH20 0x3333333333333333333333333333333333333333 (target address)
    bytecode[pos] = 0x73; // PUSH20
    pos += 1;
    @memcpy(bytecode[pos..pos+20], &[_]u8{0x33} ** 20);
    pos += 20;
    
    // EXTCODESIZE
    bytecode[pos] = 0x3B;
    pos += 1;
    
    // Store result in memory and return
    bytecode[pos] = 0x60; // PUSH1
    pos += 1;
    bytecode[pos] = 0x00; // 0 (memory offset)
    pos += 1;
    bytecode[pos] = 0x52; // MSTORE
    pos += 1;
    bytecode[pos] = 0x60; // PUSH1
    pos += 1;
    bytecode[pos] = 0x20; // 32 (size)
    pos += 1;
    bytecode[pos] = 0x60; // PUSH1
    pos += 1;
    bytecode[pos] = 0x00; // 0 (offset)
    pos += 1;
    bytecode[pos] = 0xF3; // RETURN
    pos += 1;

    const actual_bytecode = bytecode[0..pos];

    // Execute on REVM - inline all setup
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const revm_contract_address = try Address.from_hex("0x2222222222222222222222222222222222222222");
    const revm_target_address = try Address.from_hex("0x3333333333333333333333333333333333333333");

    // Set balance for deployer
    try revm_vm.setBalance(revm_deployer, 10000000);

    // Deploy the target contract first
    try revm_vm.setCode(revm_target_address, &deployed_code);
    
    // Set the bytecode as contract code
    try revm_vm.setCode(revm_contract_address, actual_bytecode);

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
    const target_address = Address.from_u256(0x3333333333333333333333333333333333333333);

    // Deploy the target contract first
    try vm_instance.state.set_code(target_address, &deployed_code);
    
    // Set the code for the contract address in EVM state
    try vm_instance.state.set_code(contract_address, actual_bytecode);

    // Execute using new call API
    const call_params = CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };

    const guillotine_result = try vm_instance.call(call_params);
    defer if (guillotine_result.output) |output| allocator.free(output);

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
        try testing.expectEqual(@as(u256, deployed_code.len), revm_value);
    } else {
        // If either failed, print debug info
        std.debug.print("REVM success: {}, Guillotine success: {}\n", .{ revm_succeeded, guillotine_result.success });
        // For EXTCODESIZE, we expect this to succeed
        try testing.expect(false);
    }
}

test "EXTCODESIZE opcode - non-existent contract returns 0" {
    const allocator = testing.allocator;

    // Contract that queries EXTCODESIZE of a non-existent contract
    // PUSH20 target_address, EXTCODESIZE, MSTORE, RETURN
    var bytecode = [_]u8{0} ** 200;
    var pos: usize = 0;
    
    // PUSH20 0x4444444444444444444444444444444444444444 (non-existent address)
    bytecode[pos] = 0x73; // PUSH20
    pos += 1;
    @memcpy(bytecode[pos..pos+20], &[_]u8{0x44} ** 20);
    pos += 20;
    
    // EXTCODESIZE
    bytecode[pos] = 0x3B;
    pos += 1;
    
    // Store result in memory and return
    bytecode[pos] = 0x60; // PUSH1
    pos += 1;
    bytecode[pos] = 0x00; // 0 (memory offset)
    pos += 1;
    bytecode[pos] = 0x52; // MSTORE
    pos += 1;
    bytecode[pos] = 0x60; // PUSH1
    pos += 1;
    bytecode[pos] = 0x20; // 32 (size)
    pos += 1;
    bytecode[pos] = 0x60; // PUSH1
    pos += 1;
    bytecode[pos] = 0x00; // 0 (offset)
    pos += 1;
    bytecode[pos] = 0xF3; // RETURN
    pos += 1;

    const actual_bytecode = bytecode[0..pos];

    // Execute on REVM - inline all setup
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const revm_contract_address = try Address.from_hex("0x2222222222222222222222222222222222222222");

    // Set balance for deployer
    try revm_vm.setBalance(revm_deployer, 10000000);

    // Set the bytecode as contract code
    try revm_vm.setCode(revm_contract_address, actual_bytecode);

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
    try vm_instance.state.set_code(contract_address, actual_bytecode);

    // Execute using new call API
    const call_params = CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };

    const guillotine_result = try vm_instance.call(call_params);
    defer if (guillotine_result.output) |output| allocator.free(output);

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
        try testing.expectEqual(@as(u256, 0), revm_value); // Non-existent contract should return 0
    } else {
        // If either failed, print debug info
        std.debug.print("REVM success: {}, Guillotine success: {}\n", .{ revm_succeeded, guillotine_result.success });
        // For EXTCODESIZE of non-existent contract, we expect this to succeed
        try testing.expect(false);
    }
}

test "EXTCODECOPY opcode - copy contract code to memory" {
    const allocator = testing.allocator;

    // First deploy a contract with known bytecode at a specific address
    const deployed_code = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xF3, // RETURN
    };

    // Contract that copies external code and returns it
    // PUSH1 codeSize, PUSH1 codeOffset, PUSH1 memOffset, PUSH20 address, EXTCODECOPY, RETURN
    var bytecode = [_]u8{0} ** 200;
    var pos: usize = 0;
    
    // PUSH1 10 (size to copy)
    bytecode[pos] = 0x60;
    pos += 1;
    bytecode[pos] = 0x0A;
    pos += 1;
    
    // PUSH1 0 (code offset)
    bytecode[pos] = 0x60;
    pos += 1;
    bytecode[pos] = 0x00;
    pos += 1;
    
    // PUSH1 0 (memory offset)
    bytecode[pos] = 0x60;
    pos += 1;
    bytecode[pos] = 0x00;
    pos += 1;
    
    // PUSH20 0x3333333333333333333333333333333333333333 (target address)
    bytecode[pos] = 0x73; // PUSH20
    pos += 1;
    @memcpy(bytecode[pos..pos+20], &[_]u8{0x33} ** 20);
    pos += 20;
    
    // EXTCODECOPY
    bytecode[pos] = 0x3C;
    pos += 1;
    
    // Return the copied data
    bytecode[pos] = 0x60; // PUSH1
    pos += 1;
    bytecode[pos] = 0x0A; // 10 (size)
    pos += 1;
    bytecode[pos] = 0x60; // PUSH1
    pos += 1;
    bytecode[pos] = 0x00; // 0 (offset)
    pos += 1;
    bytecode[pos] = 0xF3; // RETURN
    pos += 1;

    const actual_bytecode = bytecode[0..pos];

    // Execute on REVM - inline all setup
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const revm_contract_address = try Address.from_hex("0x2222222222222222222222222222222222222222");
    const revm_target_address = try Address.from_hex("0x3333333333333333333333333333333333333333");

    // Set balance for deployer
    try revm_vm.setBalance(revm_deployer, 10000000);

    // Deploy the target contract first
    try revm_vm.setCode(revm_target_address, &deployed_code);
    
    // Set the bytecode as contract code
    try revm_vm.setCode(revm_contract_address, actual_bytecode);

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
    const target_address = Address.from_u256(0x3333333333333333333333333333333333333333);

    // Deploy the target contract first
    try vm_instance.state.set_code(target_address, &deployed_code);
    
    // Set the code for the contract address in EVM state
    try vm_instance.state.set_code(contract_address, actual_bytecode);

    // Execute using new call API
    const call_params = CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };

    const guillotine_result = try vm_instance.call(call_params);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results - both should succeed
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 10);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 10);

        // Compare the copied bytes
        try testing.expectEqualSlices(u8, revm_result.output, guillotine_result.output.?);
        try testing.expectEqualSlices(u8, deployed_code[0..10], revm_result.output);
    } else {
        // If either failed, print debug info
        std.debug.print("REVM success: {}, Guillotine success: {}\n", .{ revm_succeeded, guillotine_result.success });
        // For EXTCODECOPY, we expect this to succeed
        try testing.expect(false);
    }
}

test "EXTCODECOPY opcode - copy beyond code length pads with zeros" {
    const allocator = testing.allocator;

    // First deploy a small contract
    const deployed_code = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x00, // STOP
    };

    // Contract that copies more bytes than exist in the target code
    var bytecode = [_]u8{0} ** 200;
    var pos: usize = 0;
    
    // PUSH1 32 (size to copy - more than deployed_code.len)
    bytecode[pos] = 0x60;
    pos += 1;
    bytecode[pos] = 0x20;
    pos += 1;
    
    // PUSH1 0 (code offset)
    bytecode[pos] = 0x60;
    pos += 1;
    bytecode[pos] = 0x00;
    pos += 1;
    
    // PUSH1 0 (memory offset)
    bytecode[pos] = 0x60;
    pos += 1;
    bytecode[pos] = 0x00;
    pos += 1;
    
    // PUSH20 0x3333333333333333333333333333333333333333 (target address)
    bytecode[pos] = 0x73; // PUSH20
    pos += 1;
    @memcpy(bytecode[pos..pos+20], &[_]u8{0x33} ** 20);
    pos += 20;
    
    // EXTCODECOPY
    bytecode[pos] = 0x3C;
    pos += 1;
    
    // Return the copied data
    bytecode[pos] = 0x60; // PUSH1
    pos += 1;
    bytecode[pos] = 0x20; // 32 (size)
    pos += 1;
    bytecode[pos] = 0x60; // PUSH1
    pos += 1;
    bytecode[pos] = 0x00; // 0 (offset)
    pos += 1;
    bytecode[pos] = 0xF3; // RETURN
    pos += 1;

    const actual_bytecode = bytecode[0..pos];

    // Execute on REVM - inline all setup
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const revm_contract_address = try Address.from_hex("0x2222222222222222222222222222222222222222");
    const revm_target_address = try Address.from_hex("0x3333333333333333333333333333333333333333");

    // Set balance for deployer
    try revm_vm.setBalance(revm_deployer, 10000000);

    // Deploy the target contract first
    try revm_vm.setCode(revm_target_address, &deployed_code);
    
    // Set the bytecode as contract code
    try revm_vm.setCode(revm_contract_address, actual_bytecode);

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
    const target_address = Address.from_u256(0x3333333333333333333333333333333333333333);

    // Deploy the target contract first
    try vm_instance.state.set_code(target_address, &deployed_code);
    
    // Set the code for the contract address in EVM state
    try vm_instance.state.set_code(contract_address, actual_bytecode);

    // Execute using new call API
    const call_params = CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };

    const guillotine_result = try vm_instance.call(call_params);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results - both should succeed
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        // Compare the copied bytes
        try testing.expectEqualSlices(u8, revm_result.output, guillotine_result.output.?);
        
        // Check that first bytes match deployed code
        try testing.expectEqualSlices(u8, deployed_code[0..], revm_result.output[0..deployed_code.len]);
        
        // Check that remaining bytes are zero-padded
        for (revm_result.output[deployed_code.len..]) |byte| {
            try testing.expectEqual(@as(u8, 0), byte);
        }
    } else {
        // If either failed, print debug info
        std.debug.print("REVM success: {}, Guillotine success: {}\n", .{ revm_succeeded, guillotine_result.success });
        // For EXTCODECOPY with padding, we expect this to succeed
        try testing.expect(false);
    }
}

test "EXTCODEHASH opcode - get hash of deployed contract code" {
    const allocator = testing.allocator;

    // First deploy a contract with known bytecode at a specific address
    const deployed_code = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xF3, // RETURN
    };

    // Contract that queries EXTCODEHASH of the deployed contract
    // PUSH20 target_address, EXTCODEHASH, MSTORE, RETURN
    var bytecode = [_]u8{0} ** 200;
    var pos: usize = 0;
    
    // PUSH20 0x3333333333333333333333333333333333333333 (target address)
    bytecode[pos] = 0x73; // PUSH20
    pos += 1;
    @memcpy(bytecode[pos..pos+20], &[_]u8{0x33} ** 20);
    pos += 20;
    
    // EXTCODEHASH
    bytecode[pos] = 0x3F;
    pos += 1;
    
    // Store result in memory and return
    bytecode[pos] = 0x60; // PUSH1
    pos += 1;
    bytecode[pos] = 0x00; // 0 (memory offset)
    pos += 1;
    bytecode[pos] = 0x52; // MSTORE
    pos += 1;
    bytecode[pos] = 0x60; // PUSH1
    pos += 1;
    bytecode[pos] = 0x20; // 32 (size)
    pos += 1;
    bytecode[pos] = 0x60; // PUSH1
    pos += 1;
    bytecode[pos] = 0x00; // 0 (offset)
    pos += 1;
    bytecode[pos] = 0xF3; // RETURN
    pos += 1;

    const actual_bytecode = bytecode[0..pos];

    // Execute on REVM - inline all setup
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const revm_contract_address = try Address.from_hex("0x2222222222222222222222222222222222222222");
    const revm_target_address = try Address.from_hex("0x3333333333333333333333333333333333333333");

    // Set balance for deployer
    try revm_vm.setBalance(revm_deployer, 10000000);

    // Deploy the target contract first
    try revm_vm.setCode(revm_target_address, &deployed_code);
    
    // Set the bytecode as contract code
    try revm_vm.setCode(revm_contract_address, actual_bytecode);

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
    const target_address = Address.from_u256(0x3333333333333333333333333333333333333333);

    // Deploy the target contract first
    try vm_instance.state.set_code(target_address, &deployed_code);
    
    // Set the code for the contract address in EVM state
    try vm_instance.state.set_code(contract_address, actual_bytecode);

    // Execute using new call API
    const call_params = CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };

    const guillotine_result = try vm_instance.call(call_params);
    defer if (guillotine_result.output) |output| allocator.free(output);

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
        
        // Verify it's not zero (should be actual hash)
        try testing.expect(revm_value != 0);
    } else {
        // If either failed, print debug info
        std.debug.print("REVM success: {}, Guillotine success: {}\n", .{ revm_succeeded, guillotine_result.success });
        // For EXTCODEHASH, we expect this to succeed
        try testing.expect(false);
    }
}

test "EXTCODEHASH opcode - non-existent account returns 0" {
    const allocator = testing.allocator;

    // Contract that queries EXTCODEHASH of a non-existent contract
    // PUSH20 target_address, EXTCODEHASH, MSTORE, RETURN
    var bytecode = [_]u8{0} ** 200;
    var pos: usize = 0;
    
    // PUSH20 0x4444444444444444444444444444444444444444 (non-existent address)
    bytecode[pos] = 0x73; // PUSH20
    pos += 1;
    @memcpy(bytecode[pos..pos+20], &[_]u8{0x44} ** 20);
    pos += 20;
    
    // EXTCODEHASH
    bytecode[pos] = 0x3F;
    pos += 1;
    
    // Store result in memory and return
    bytecode[pos] = 0x60; // PUSH1
    pos += 1;
    bytecode[pos] = 0x00; // 0 (memory offset)
    pos += 1;
    bytecode[pos] = 0x52; // MSTORE
    pos += 1;
    bytecode[pos] = 0x60; // PUSH1
    pos += 1;
    bytecode[pos] = 0x20; // 32 (size)
    pos += 1;
    bytecode[pos] = 0x60; // PUSH1
    pos += 1;
    bytecode[pos] = 0x00; // 0 (offset)
    pos += 1;
    bytecode[pos] = 0xF3; // RETURN
    pos += 1;

    const actual_bytecode = bytecode[0..pos];

    // Execute on REVM - inline all setup
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const revm_contract_address = try Address.from_hex("0x2222222222222222222222222222222222222222");

    // Set balance for deployer
    try revm_vm.setBalance(revm_deployer, 10000000);

    // Set the bytecode as contract code
    try revm_vm.setCode(revm_contract_address, actual_bytecode);

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
    try vm_instance.state.set_code(contract_address, actual_bytecode);

    // Execute using new call API
    const call_params = CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };

    const guillotine_result = try vm_instance.call(call_params);
    defer if (guillotine_result.output) |output| allocator.free(output);

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
        try testing.expectEqual(@as(u256, 0), revm_value); // Non-existent account should return 0
    } else {
        // If either failed, print debug info
        std.debug.print("REVM success: {}, Guillotine success: {}\n", .{ revm_succeeded, guillotine_result.success });
        // For EXTCODEHASH of non-existent account, we expect this to succeed
        try testing.expect(false);
    }
}

test "EXTCODEHASH opcode - empty account with balance returns keccak256('')" {
    const allocator = testing.allocator;

    // Contract that queries EXTCODEHASH of an account with balance but no code
    // PUSH20 target_address, EXTCODEHASH, MSTORE, RETURN
    var bytecode = [_]u8{0} ** 200;
    var pos: usize = 0;
    
    // PUSH20 0x5555555555555555555555555555555555555555 (account with balance)
    bytecode[pos] = 0x73; // PUSH20
    pos += 1;
    @memcpy(bytecode[pos..pos+20], &[_]u8{0x55} ** 20);
    pos += 20;
    
    // EXTCODEHASH
    bytecode[pos] = 0x3F;
    pos += 1;
    
    // Store result in memory and return
    bytecode[pos] = 0x60; // PUSH1
    pos += 1;
    bytecode[pos] = 0x00; // 0 (memory offset)
    pos += 1;
    bytecode[pos] = 0x52; // MSTORE
    pos += 1;
    bytecode[pos] = 0x60; // PUSH1
    pos += 1;
    bytecode[pos] = 0x20; // 32 (size)
    pos += 1;
    bytecode[pos] = 0x60; // PUSH1
    pos += 1;
    bytecode[pos] = 0x00; // 0 (offset)
    pos += 1;
    bytecode[pos] = 0xF3; // RETURN
    pos += 1;

    const actual_bytecode = bytecode[0..pos];

    // Execute on REVM - inline all setup
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const revm_contract_address = try Address.from_hex("0x2222222222222222222222222222222222222222");
    const revm_target_address = try Address.from_hex("0x5555555555555555555555555555555555555555");

    // Set balance for deployer
    try revm_vm.setBalance(revm_deployer, 10000000);
    
    // Set balance for target address (but no code)
    try revm_vm.setBalance(revm_target_address, 1000);

    // Set the bytecode as contract code
    try revm_vm.setCode(revm_contract_address, actual_bytecode);

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
    const target_address = Address.from_u256(0x5555555555555555555555555555555555555555);

    // Set balance for target address (but no code)
    try vm_instance.state.set_balance(target_address, 1000);

    // Set the code for the contract address in EVM state
    try vm_instance.state.set_code(contract_address, actual_bytecode);

    // Execute using new call API
    const call_params = CallParams{ .call = .{
        .caller = contract_address,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };

    const guillotine_result = try vm_instance.call(call_params);
    defer if (guillotine_result.output) |output| allocator.free(output);

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
        
        // For an account with balance but no code, EXTCODEHASH should return keccak256('')
        // which is: 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
        const expected_hash: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        try testing.expectEqual(expected_hash, revm_value);
    } else {
        // If either failed, print debug info
        std.debug.print("REVM success: {}, Guillotine success: {}\n", .{ revm_succeeded, guillotine_result.success });
        // For EXTCODEHASH of empty account with balance, we expect this to succeed
        try testing.expect(false);
    }
}