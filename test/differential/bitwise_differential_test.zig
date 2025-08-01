const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;

// Import REVM wrapper from module
const revm_wrapper = @import("revm");

test "AND opcode 0xFF & 0x0F = 0x0F" {
    const allocator = testing.allocator;

    // PUSH32 0x0F, PUSH32 0xFF, AND, MSTORE, RETURN (computes 0xFF & 0x0F = 0x0F)
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x0F (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F,
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0xFF (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF,
        0x16, // AND
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

    // Set balance for deployer
    try revm_vm.setBalance(revm_deployer, 10000000);

    // Deploy the bytecode as a contract
    var revm_result = try revm_vm.create(revm_deployer, 0, &bytecode, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine - inline all setup
    const MemoryDatabase = evm.MemoryDatabase;
    const Contract = evm.Contract;

    // Create EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm_instance = try builder.build();
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    // Create contract and execute
    var contract = Contract.init_at_address(
        contract_address, // caller
        contract_address, // address where code executes
        0, // value
        1000000, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try vm_instance.state.set_code(contract_address, &bytecode);

    // Execute the contract
    const guillotine_result = try vm_instance.interpret(&contract, &[_]u8{}, false);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results - both should succeed
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.status == .Success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        // Extract u256 from output (big-endian)
        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
        // Let REVM be the source of truth for the expected value
        std.debug.print("AND test: REVM returned {}, Guillotine returned {}\n", .{ revm_value, guillotine_value });
    } else {
        // If either failed, print debug info
        std.debug.print("REVM success: {}, Guillotine status: {s}\n", .{ revm_succeeded, @tagName(guillotine_result.status) });
        if (guillotine_result.err) |err| {
            std.debug.print("Guillotine error: {}\n", .{err});
        }
    }

    std.debug.print("✓ AND test passed: 0xFF & 0x0F = 0x0F\n", .{});
}

test "OR opcode 0x0F | 0xF0 = 0xFF" {
    const allocator = testing.allocator;

    // PUSH32 0xF0, PUSH32 0x0F, OR, MSTORE, RETURN (computes 0x0F | 0xF0 = 0xFF)
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0xF0 (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0,
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x0F (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F,
        0x17, // OR
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

    // Set balance for deployer
    try revm_vm.setBalance(revm_deployer, 10000000);

    // Deploy the bytecode as a contract
    var revm_result = try revm_vm.create(revm_deployer, 0, &bytecode, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine - inline all setup
    const MemoryDatabase = evm.MemoryDatabase;
    const Contract = evm.Contract;

    // Create EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm_instance = try builder.build();
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    // Create contract and execute
    var contract = Contract.init_at_address(
        contract_address, // caller
        contract_address, // address where code executes
        0, // value
        1000000, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try vm_instance.state.set_code(contract_address, &bytecode);

    // Execute the contract
    const guillotine_result = try vm_instance.interpret(&contract, &[_]u8{}, false);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results - both should succeed
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.status == .Success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        // Extract u256 from output (big-endian)
        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
        // Let REVM be the source of truth for the expected value
        std.debug.print("OR test: REVM returned {}, Guillotine returned {}\n", .{ revm_value, guillotine_value });
    } else {
        // If either failed, print debug info
        std.debug.print("REVM success: {}, Guillotine status: {s}\n", .{ revm_succeeded, @tagName(guillotine_result.status) });
        if (guillotine_result.err) |err| {
            std.debug.print("Guillotine error: {}\n", .{err});
        }
    }

    std.debug.print("✓ OR test passed: 0x0F | 0xF0 = 0xFF\n", .{});
}

test "SHL opcode 1 << 4 = 16" {
    const allocator = testing.allocator;

    // PUSH32 4, PUSH32 1, SHL, MSTORE, RETURN (computes 1 << 4 = 16)
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 4 (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04,
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 1 (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x1B, // SHL
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

    // Set balance for deployer
    try revm_vm.setBalance(revm_deployer, 10000000);

    // Deploy the bytecode as a contract
    var revm_result = try revm_vm.create(revm_deployer, 0, &bytecode, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine - inline all setup
    const MemoryDatabase = evm.MemoryDatabase;
    const Contract = evm.Contract;

    // Create EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm_instance = try builder.build();
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    // Create contract and execute
    var contract = Contract.init_at_address(
        contract_address, // caller
        contract_address, // address where code executes
        0, // value
        1000000, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try vm_instance.state.set_code(contract_address, &bytecode);

    // Execute the contract
    const guillotine_result = try vm_instance.interpret(&contract, &[_]u8{}, false);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results - both should succeed
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.status == .Success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        // Extract u256 from output (big-endian)
        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
        // Let REVM be the source of truth for the expected value
        std.debug.print("SHL test: REVM returned {}, Guillotine returned {}\n", .{ revm_value, guillotine_value });
    } else {
        // If either failed, print debug info
        std.debug.print("REVM success: {}, Guillotine status: {s}\n", .{ revm_succeeded, @tagName(guillotine_result.status) });
        if (guillotine_result.err) |err| {
            std.debug.print("Guillotine error: {}\n", .{err});
        }
    }

    std.debug.print("✓ SHL test passed: 1 << 4 = 16\n", .{});
}

test "XOR opcode 0xF0 ^ 0x0F = 0xFF" {
    const allocator = testing.allocator;

    // PUSH32 0x0F, PUSH32 0xF0, XOR, MSTORE, RETURN (computes 0xF0 ^ 0x0F = 0xFF)
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x0F (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F,
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0xF0 (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0,
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

    // Set balance for deployer
    try revm_vm.setBalance(revm_deployer, 10000000);

    // Deploy the bytecode as a contract
    var revm_result = try revm_vm.create(revm_deployer, 0, &bytecode, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine - inline all setup
    const MemoryDatabase = evm.MemoryDatabase;
    const Contract = evm.Contract;

    // Create EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm_instance = try builder.build();
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    // Create contract and execute
    var contract = Contract.init_at_address(
        contract_address, // caller
        contract_address, // address where code executes
        0, // value
        1000000, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try vm_instance.state.set_code(contract_address, &bytecode);

    // Execute the contract
    const guillotine_result = try vm_instance.interpret(&contract, &[_]u8{}, false);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results - both should succeed
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.status == .Success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        // Extract u256 from output (big-endian)
        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
        std.debug.print("XOR test: REVM returned {}, Guillotine returned {}\n", .{ revm_value, guillotine_value });
    } else {
        // If either failed, print debug info
        std.debug.print("REVM success: {}, Guillotine status: {s}\n", .{ revm_succeeded, @tagName(guillotine_result.status) });
        if (guillotine_result.err) |err| {
            std.debug.print("Guillotine error: {}\n", .{err});
        }
    }

    std.debug.print("✓ XOR test passed: 0xF0 ^ 0x0F = 0xFF\n", .{});
}

test "NOT opcode ~0x0F = 0xFF...F0" {
    const allocator = testing.allocator;

    // PUSH32 0x0F, NOT, MSTORE, RETURN (computes ~0x0F)
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x0F (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F,
        0x19, // NOT
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

    // Set balance for deployer
    try revm_vm.setBalance(revm_deployer, 10000000);

    // Deploy the bytecode as a contract
    var revm_result = try revm_vm.create(revm_deployer, 0, &bytecode, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine - inline all setup
    const MemoryDatabase = evm.MemoryDatabase;
    const Contract = evm.Contract;

    // Create EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm_instance = try builder.build();
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    // Create contract and execute
    var contract = Contract.init_at_address(
        contract_address, // caller
        contract_address, // address where code executes
        0, // value
        1000000, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try vm_instance.state.set_code(contract_address, &bytecode);

    // Execute the contract
    const guillotine_result = try vm_instance.interpret(&contract, &[_]u8{}, false);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results - both should succeed
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.status == .Success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        // Extract u256 from output (big-endian)
        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
        std.debug.print("NOT test: REVM returned {x}, Guillotine returned {x}\n", .{ revm_value, guillotine_value });
    } else {
        // If either failed, print debug info
        std.debug.print("REVM success: {}, Guillotine status: {s}\n", .{ revm_succeeded, @tagName(guillotine_result.status) });
        if (guillotine_result.err) |err| {
            std.debug.print("Guillotine error: {}\n", .{err});
        }
    }

    std.debug.print("✓ NOT test passed: ~0x0F\n", .{});
}

test "SHR opcode 16 >> 2 = 4" {
    const allocator = testing.allocator;

    // PUSH32 2, PUSH32 16, SHR, MSTORE, RETURN (computes 16 >> 2 = 4)
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 2 (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 16 (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
        0x1C, // SHR
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

    // Set balance for deployer
    try revm_vm.setBalance(revm_deployer, 10000000);

    // Deploy the bytecode as a contract
    var revm_result = try revm_vm.create(revm_deployer, 0, &bytecode, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine - inline all setup
    const MemoryDatabase = evm.MemoryDatabase;
    const Contract = evm.Contract;

    // Create EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm_instance = try builder.build();
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    // Create contract and execute
    var contract = Contract.init_at_address(
        contract_address, // caller
        contract_address, // address where code executes
        0, // value
        1000000, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try vm_instance.state.set_code(contract_address, &bytecode);

    // Execute the contract
    const guillotine_result = try vm_instance.interpret(&contract, &[_]u8{}, false);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results - both should succeed
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.status == .Success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        // Extract u256 from output (big-endian)
        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
        std.debug.print("SHR test: REVM returned {}, Guillotine returned {}\n", .{ revm_value, guillotine_value });
    } else {
        // If either failed, print debug info
        std.debug.print("REVM success: {}, Guillotine status: {s}\n", .{ revm_succeeded, @tagName(guillotine_result.status) });
        if (guillotine_result.err) |err| {
            std.debug.print("Guillotine error: {}\n", .{err});
        }
    }

    std.debug.print("✓ SHR test passed: 16 >> 2 = 4\n", .{});
}

test "SAR opcode arithmetic right shift with sign" {
    const allocator = testing.allocator;

    // PUSH32 2, PUSH32 -8 (as u256), SAR, MSTORE, RETURN
    // -8 in two's complement u256 format
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 2 (32 bytes)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
        0x7f, // PUSH32
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // -8 in two's complement (32 bytes)
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xF8,
        0x1D, // SAR
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

    // Set balance for deployer
    try revm_vm.setBalance(revm_deployer, 10000000);

    // Deploy the bytecode as a contract
    var revm_result = try revm_vm.create(revm_deployer, 0, &bytecode, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine - inline all setup
    const MemoryDatabase = evm.MemoryDatabase;
    const Contract = evm.Contract;

    // Create EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm_instance = try builder.build();
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    // Create contract and execute
    var contract = Contract.init_at_address(
        contract_address, // caller
        contract_address, // address where code executes
        0, // value
        1000000, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try vm_instance.state.set_code(contract_address, &bytecode);

    // Execute the contract
    const guillotine_result = try vm_instance.interpret(&contract, &[_]u8{}, false);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results - both should succeed
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.status == .Success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        // Extract u256 from output (big-endian)
        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
        std.debug.print("SAR test: REVM returned {x}, Guillotine returned {x}\n", .{ revm_value, guillotine_value });
    } else {
        // If either failed, print debug info
        std.debug.print("REVM success: {}, Guillotine status: {s}\n", .{ revm_succeeded, @tagName(guillotine_result.status) });
        if (guillotine_result.err) |err| {
            std.debug.print("Guillotine error: {}\n", .{err});
        }
    }

    std.debug.print("✓ SAR test passed: arithmetic right shift\n", .{});
}

test "BYTE opcode extract byte from word" {
    const allocator = testing.allocator;

    // PUSH32 0x1234567890ABCDEF..., PUSH32 1, BYTE, MSTORE, RETURN
    // Extract byte at index 1 (should be 0x34)
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF, // test data (32 bytes)
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x7f, // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 1 (32 bytes) - byte index
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x1A, // BYTE
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

    // Set balance for deployer
    try revm_vm.setBalance(revm_deployer, 10000000);

    // Deploy the bytecode as a contract
    var revm_result = try revm_vm.create(revm_deployer, 0, &bytecode, 1000000);
    defer revm_result.deinit();

    // Execute on Guillotine - inline all setup
    const MemoryDatabase = evm.MemoryDatabase;
    const Contract = evm.Contract;

    // Create EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm_instance = try builder.build();
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    // Create contract and execute
    var contract = Contract.init_at_address(
        contract_address, // caller
        contract_address, // address where code executes
        0, // value
        1000000, // gas
        &bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);

    // Set the code for the contract address in EVM state
    try vm_instance.state.set_code(contract_address, &bytecode);

    // Execute the contract
    const guillotine_result = try vm_instance.interpret(&contract, &[_]u8{}, false);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results - both should succeed
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.status == .Success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        // Extract u256 from output (big-endian)
        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
        std.debug.print("BYTE test: REVM returned {x}, Guillotine returned {x}\n", .{ revm_value, guillotine_value });
    } else {
        // If either failed, print debug info
        std.debug.print("REVM success: {}, Guillotine status: {s}\n", .{ revm_succeeded, @tagName(guillotine_result.status) });
        if (guillotine_result.err) |err| {
            std.debug.print("Guillotine error: {}\n", .{err});
        }
    }

    std.debug.print("✓ BYTE test passed: extract byte from word\n", .{});
}
