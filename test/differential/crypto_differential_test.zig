const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const CallParams = evm.Host.CallParams;
const CallResult = evm.CallResult;

// Import REVM wrapper from module
const revm_wrapper = @import("revm");

// Updated to new API - migration in progress, tests not run yet

test "KECCAK256 opcode hashes empty data" {
    const allocator = testing.allocator;

    // PUSH32 0 (length), PUSH32 0 (offset), KECCAK256, MSTORE, RETURN
    // Hash empty data and return the hash
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (length)
        0x60, 0x00, // PUSH1 0 (offset)
        0x20, // KECCAK256
        0x60, 0x00, // PUSH1 0 (memory offset for return)
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

        // Compare byte-by-byte for hash
        for (revm_result.output, 0..) |byte, i| {
            try testing.expectEqual(byte, guillotine_result.output.?[i]);
        }

        std.debug.print("KECCAK256 empty test: Hashes match\n", .{});
        std.debug.print("REVM hash: ", .{});
        for (revm_result.output) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("\n", .{});
        std.debug.print("Guillotine hash: ", .{});
        for (guillotine_result.output.?) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("\n", .{});
    } else {
        // If either failed, print debug info
        std.debug.print("REVM success: {}, Guillotine status: {s}\n", .{ revm_succeeded, @tagName(guillotine_result.status) });
        if (guillotine_result.err) |err| {
            std.debug.print("Guillotine error: {}\n", .{err});
        }
        // For KECCAK256, we expect this to succeed
        try testing.expect(false);
    }
}

test "KECCAK256 opcode hashes test data" {
    const allocator = testing.allocator;

    // Store test data "abc" in memory, then hash it
    // PUSH32 0x616263 (hex for "abc"), PUSH32 0, MSTORE
    // PUSH32 3 (length), PUSH32 29 (offset for last 3 bytes), KECCAK256, MSTORE (at 32), RETURN
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0x61, 0x62, 0x63, 0x00, 0x00, 0x00, 0x00, 0x00, // "abc" in the last 3 bytes (32 bytes total)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE (store at memory[0])
        0x60, 0x03, // PUSH1 3 (length of "abc")
        0x60, 0x1D, // PUSH1 29 (offset to get last 3 bytes: 32-3=29)
        0x20, // KECCAK256
        0x60, 0x20, // PUSH1 32 (memory offset for return)
        0x52, // MSTORE (store hash at memory[32])
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x20, // PUSH1 32 (offset)
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

        // Compare byte-by-byte for hash
        for (revm_result.output, 0..) |byte, i| {
            try testing.expectEqual(byte, guillotine_result.output.?[i]);
        }

        std.debug.print("KECCAK256 abc test: Hashes match\n", .{});
        std.debug.print("REVM hash: ", .{});
        for (revm_result.output) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("\n", .{});
        std.debug.print("Guillotine hash: ", .{});
        for (guillotine_result.output.?) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("\n", .{});
    } else {
        // If either failed, print debug info
        std.debug.print("REVM success: {}, Guillotine status: {s}\n", .{ revm_succeeded, @tagName(guillotine_result.status) });
        if (guillotine_result.err) |err| {
            std.debug.print("Guillotine error: {}\n", .{err});
        }
        // For KECCAK256, we expect this to succeed
        try testing.expect(false);
    }
}

test "KECCAK256 opcode hashes 32-byte data" {
    const allocator = testing.allocator;

    // Store 32 bytes of data in memory, then hash it
    // PUSH32 (32 bytes of test data), PUSH32 0, MSTORE
    // PUSH32 32 (length), PUSH32 0 (offset), KECCAK256, MSTORE (at 32), RETURN
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, // 32 bytes of test data
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20,
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE (store at memory[0])
        0x60, 0x20, // PUSH1 32 (length)
        0x60, 0x00, // PUSH1 0 (offset)
        0x20, // KECCAK256
        0x60, 0x20, // PUSH1 32 (memory offset for return)
        0x52, // MSTORE (store hash at memory[32])
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x20, // PUSH1 32 (offset)
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

        // Compare byte-by-byte for hash
        for (revm_result.output, 0..) |byte, i| {
            try testing.expectEqual(byte, guillotine_result.output.?[i]);
        }

        std.debug.print("KECCAK256 32-byte test: Hashes match\n", .{});
        std.debug.print("REVM hash: ", .{});
        for (revm_result.output) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("\n", .{});
        std.debug.print("Guillotine hash: ", .{});
        for (guillotine_result.output.?) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("\n", .{});
    } else {
        // If either failed, print debug info
        std.debug.print("REVM success: {}, Guillotine status: {s}\n", .{ revm_succeeded, @tagName(guillotine_result.status) });
        if (guillotine_result.err) |err| {
            std.debug.print("Guillotine error: {}\n", .{err});
        }
        // For KECCAK256, we expect this to succeed
        try testing.expect(false);
    }
}
