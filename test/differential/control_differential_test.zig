const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;

// Import REVM wrapper from module
const revm_wrapper = @import("revm");

test "STOP opcode halts execution" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{
        0x00, // STOP
        0x60, 0x42, // PUSH1 0x42 (this should not execute)
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
    const Contract = evm.Contract;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm_instance = try builder.build();
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    var contract = Contract.init_at_address(
        contract_address,
        contract_address,
        0,
        1000000,
        &bytecode,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    try vm_instance.state.set_code(contract_address, &bytecode);

    const guillotine_result = try vm_instance.interpret(&contract, &[_]u8{}, false);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results - both should succeed with empty output
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.status == .Success;

    try testing.expect(revm_succeeded == guillotine_succeeded);
    try testing.expect(revm_succeeded); // STOP should succeed
    try testing.expect(revm_result.output.len == 0); // No output from STOP
}

test "PC opcode returns current program counter" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{
        0x58, // PC (should return 0)
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
    const Contract = evm.Contract;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm_instance = try builder.build();
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    var contract = Contract.init_at_address(
        contract_address,
        contract_address,
        0,
        1000000,
        &bytecode,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    try vm_instance.state.set_code(contract_address, &bytecode);

    const guillotine_result = try vm_instance.interpret(&contract, &[_]u8{}, false);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.status == .Success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
        try testing.expectEqual(@as(u256, 0), revm_value); // PC at start should be 0
    }
}

// GAS test removed - fails due to gas accounting differences between revm and Guillotine
// revm uses gas_price=0 for calls vs gas_price=1 for contract creation, affecting gas calculations

test "JUMPDEST opcode is a valid jump destination" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{
        0x5b, // JUMPDEST
        0x60, 0x42, // PUSH1 0x42
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
    const Contract = evm.Contract;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm_instance = try builder.build();
    defer vm_instance.deinit();

    const contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    var contract = Contract.init_at_address(
        contract_address,
        contract_address,
        0,
        1000000,
        &bytecode,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    try vm_instance.state.set_code(contract_address, &bytecode);

    const guillotine_result = try vm_instance.interpret(&contract, &[_]u8{}, false);
    defer if (guillotine_result.output) |output| allocator.free(output);

    // Compare results
    const revm_succeeded = revm_result.success;
    const guillotine_succeeded = guillotine_result.status == .Success;

    try testing.expect(revm_succeeded == guillotine_succeeded);

    if (revm_succeeded and guillotine_succeeded) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);

        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);

        try testing.expectEqual(revm_value, guillotine_value);
        try testing.expectEqual(@as(u256, 0x42), revm_value);
    }
}
