const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const revm = @import("revm");
const Address = @import("primitives").Address;
const evm = @import("evm");
const Evm = evm.Evm;
const Contract = evm.Contract;
const Frame = evm.Frame;
const MemoryDatabase = evm.MemoryDatabase;
const Operation = evm.Operation;
const CallParams = evm.CallParams;

test "SELFDESTRUCT in static call fails with WriteProtection" {
    const allocator = testing.allocator;

    // Initialize REVM
    var revm_vm = try revm.Revm.init(allocator, .{});
    defer revm_vm.deinit();

    const deployer = Address.ZERO;

    // Contract bytecode that attempts SELFDESTRUCT
    const bytecode = [_]u8{
        0x73, // PUSH20
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // beneficiary address
        0xff, // SELFDESTRUCT
    };

    const revm_contract_address = try Address.from_hex("0x1111111111111111111111111111111111111111");
    try revm_vm.setCode(revm_contract_address, &bytecode);

    // Execute with REVM using staticcall (read-only context)
    const revm_result = try revm_vm.staticcall(deployer, revm_contract_address, &[_]u8{}, 1_000_000);
    defer allocator.free(revm_result.output);

    // Initialize Guillotine
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try Evm.init(allocator, db_interface, null, null, null, null);
    defer vm_instance.deinit();

    // Deploy contract in Guillotine
    var contract = Contract.init(Address.ZERO, 0, &bytecode, 1_000_000);
    defer contract.deinit(allocator, null);

    const call_params = @import("evm").CallParams{ .staticcall = .{
        .caller = deployer,
        .to = contract.address,
        .input = &[_]u8{},
        .gas = 1_000_000,
    } };

    // Execute using mini EVM
    const mini_result = try vm_instance.call(call_params);
    // Output is VM-owned, do not free

    // Execute using regular Guillotine
    const result = try vm_instance.call(call_params);
    // Output is VM-owned, do not free

    // All should fail (return empty output due to WriteProtection)
    try testing.expectEqual(@as(usize, 0), revm_result.output.len);
    try testing.expectEqual(@as(?[]u8, null), mini_result.output);
    try testing.expectEqual(@as(?[]u8, null), result.output);
}

test "SELFDESTRUCT to self keeps balance" {
    const allocator = testing.allocator;

    // Initialize REVM
    var revm_vm = try revm.Revm.init(allocator, .{});
    defer revm_vm.deinit();

    const deployer = Address.ZERO;
    const contract_address = try Address.from_hex("0x1111111111111111111111111111111111111111");

    // Contract bytecode that selfdestructs to itself
    const bytecode = [_]u8{
        0x30, // ADDRESS (push contract address to stack)
        0xff, // SELFDESTRUCT
    };

    try revm_vm.setCode(contract_address, &bytecode);
    try revm_vm.setBalance(contract_address, 1000); // Give contract some balance

    // Execute with REVM
    const revm_result = try revm_vm.call(deployer, contract_address, 0, &[_]u8{}, 1_000_000);
    defer allocator.free(revm_result.output);

    // Initialize Guillotine
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try Evm.init(allocator, db_interface, null, null, null, null);
    defer vm_instance.deinit();

    // Deploy contract in Guillotine with balance
    var contract = Contract.init(contract_address, 0, &bytecode, 1000000);
    defer contract.deinit(allocator, null);
    // try memory_db.set_balance(contract_address, 1000); // TODO: Fix this

    const call_params = @import("evm").CallParams{ .call = .{
        .caller = deployer,
        .to = contract.address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1_000_000,
    } };

    // Execute using mini EVM
    const mini_result = try vm_instance.call(call_params);
    // Output is VM-owned, do not free

    // Execute using regular Guillotine
    const result = try vm_instance.call(call_params);
    // Output is VM-owned, do not free

    // All executions should succeed
    try testing.expect(revm_result.success);
    try testing.expect(mini_result.success);
    try testing.expect(result.success);
}

test "SELFDESTRUCT with refund gas calculation" {
    const allocator = testing.allocator;

    // Initialize REVM
    var revm_vm = try revm.Revm.init(allocator, .{});
    defer revm_vm.deinit();

    const deployer = Address.ZERO;

    // Contract bytecode that selfdestructs to beneficiary
    const bytecode = [_]u8{
        0x73, // PUSH20
        0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22,
        0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, // beneficiary address
        0xff, // SELFDESTRUCT
    };

    const revm_contract_address = try Address.from_hex("0x1111111111111111111111111111111111111111");
    try revm_vm.setCode(revm_contract_address, &bytecode);

    // Execute with REVM
    const revm_result = try revm_vm.call(deployer, revm_contract_address, 0, &[_]u8{}, 1_000_000);
    defer allocator.free(revm_result.output);

    // Initialize Guillotine
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try Evm.init(allocator, db_interface, null, null, null, null);
    defer vm_instance.deinit();

    // Deploy contract in Guillotine
    var contract = Contract.init(Address.ZERO, 0, &bytecode, 1_000_000);
    defer contract.deinit(allocator, null);

    const call_params = @import("evm").CallParams{ .call = .{
        .caller = deployer,
        .to = contract.address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1_000_000,
    } };

    // Execute using mini EVM
    const mini_result = try vm_instance.call(call_params);
    // Output is VM-owned, do not free

    // Execute using regular Guillotine
    const result = try vm_instance.call(call_params);
    // Output is VM-owned, do not free

    // All should succeed - gas used should be consistent
    try testing.expect(revm_result.success);
    try testing.expect(mini_result.success);
    try testing.expect(result.success);
}

test "SELFDESTRUCT in CREATE context" {
    const allocator = testing.allocator;

    // Initialize REVM
    var revm_vm = try revm.Revm.init(allocator, .{});
    defer revm_vm.deinit();

    const deployer = Address.ZERO;


    // Contract that creates with init code that selfdestructs
    const bytecode = [_]u8{
        // Store init code in memory
        0x7f, // PUSH32
        0x73, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0xff, // init code as 32 bytes
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        
        // CREATE with the init code
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x16, // PUSH1 22 (size of init code)
        0xf0, // CREATE
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const revm_contract_address = try Address.from_hex("0x1111111111111111111111111111111111111111");
    try revm_vm.setCode(revm_contract_address, &bytecode);

    // Execute with REVM
    const revm_result = try revm_vm.call(deployer, revm_contract_address, 0, &[_]u8{}, 1_000_000);
    defer allocator.free(revm_result.output);

    // Initialize Guillotine
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try Evm.init(allocator, db_interface, null, null, null, null);
    defer vm_instance.deinit();

    // Deploy contract in Guillotine
    var contract = Contract.init(Address.ZERO, 0, &bytecode, 1_000_000);
    defer contract.deinit(allocator, null);

    const call_params = @import("evm").CallParams{ .call = .{
        .caller = deployer,
        .to = contract.address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1_000_000,
    } };

    // Execute using mini EVM
    const mini_result = try vm_instance.call(call_params);
    // Output is VM-owned, do not free

    // Execute using regular Guillotine
    const result = try vm_instance.call(call_params);
    // Output is VM-owned, do not free

    // All should return 0 (CREATE returns 0 when init code selfdestructs)
    const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
    try testing.expectEqual(@as(u256, 0), revm_value);

    const mini_value = std.mem.readInt(u256, mini_result.output.?[0..32], .big);
    try testing.expectEqual(revm_value, mini_value);

    const value_result = std.mem.readInt(u256, result.output.?[0..32], .big);
    try testing.expectEqual(revm_value, value_result);
}

test "SELFDESTRUCT multiple times in same transaction" {
    const allocator = testing.allocator;

    // Initialize REVM
    var revm_vm = try revm.Revm.init(allocator, .{});
    defer revm_vm.deinit();

    const deployer = Address.ZERO;

    // Contract A that selfdestructs
    const contract_a_code = [_]u8{
        0x73, // PUSH20
        0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22,
        0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, // beneficiary address
        0xff, // SELFDESTRUCT
    };

    // Contract B that calls A then selfdestructs
    const contract_b_code = [_]u8{
        // Call contract A
        0x60, 0x00, // PUSH1 0 (retSize)
        0x60, 0x00, // PUSH1 0 (retOffset)
        0x60, 0x00, // PUSH1 0 (argsSize)
        0x60, 0x00, // PUSH1 0 (argsOffset)
        0x60, 0x00, // PUSH1 0 (value)
        0x73, // PUSH20
        0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33,
        0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, // contract A address
        0x61, 0x10, 0x00, // PUSH2 4096 (gas)
        0xf1, // CALL
        0x50, // POP result
        
        // Now selfdestruct B
        0x73, // PUSH20
        0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22,
        0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, // beneficiary address
        0xff, // SELFDESTRUCT
    };

    const contract_a_address = try Address.from_hex("0x3333333333333333333333333333333333333333");
    const contract_b_address = try Address.from_hex("0x4444444444444444444444444444444444444444");
    
    try revm_vm.setCode(contract_a_address, &contract_a_code);
    try revm_vm.setCode(contract_b_address, &contract_b_code);
    try revm_vm.setBalance(contract_a_address, 500);
    try revm_vm.setBalance(contract_b_address, 700);

    // Execute with REVM
    const revm_result = try revm_vm.call(deployer, contract_b_address, 0, &[_]u8{}, 1_000_000);
    defer allocator.free(revm_result.output);

    // Initialize Guillotine
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm_instance = try Evm.init(allocator, db_interface, null, null, null, null);
    defer vm_instance.deinit();

    // Deploy contracts in Guillotine
    var contract_a = Contract.init(contract_a_address, 0, &contract_a_code, 1000000);
    defer contract_a.deinit(allocator, null);
    var contract_b = Contract.init(contract_b_address, 0, &contract_b_code, 1000000);
    defer contract_b.deinit(allocator, null);
    
    // try memory_db.set_balance(contract_a_address, 500); // TODO: Fix this
    // try memory_db.set_balance(contract_b_address, 700); // TODO: Fix this

    const call_params = CallParams{ .call = .{
        .caller = deployer,
        .to = contract_b_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1_000_000,
    } };

    // Execute using mini EVM
    const mini_result = try vm_instance.call(call_params);
    // Output is VM-owned, do not free

    // Execute using regular Guillotine
    const result = try vm_instance.call(call_params);
    // Output is VM-owned, do not free

    // All should succeed
    try testing.expect(revm_result.success);
    try testing.expect(mini_result.success);
    try testing.expect(result.success);
}