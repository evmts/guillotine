const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const CallParams = evm.Host.CallParams;
const CallResult = evm.CallResult;
// Updated to new API - migration in progress, tests not run yet
const opcodes = evm.opcodes;
const ExecutionError = evm.ExecutionError;
const Address = evm.Address;
const MemoryDatabase = evm.MemoryDatabase;
const Contract = evm.Contract;
const Frame = evm.Frame;
const Operation = evm.Operation;

// Test contract creation workflow
test "Integration: contract creation and initialization" {
    const allocator = testing.allocator;

    // Create database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const contract_address = Address.from_u256(0x3333333333333333333333333333333333333333);
    const alice_address = Address.from_u256(0x1111111111111111111111111111111111111111);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Create simple init code that stores a value and returns runtime code
    // PUSH1 0x42 PUSH1 0x00 SSTORE   (store 0x42 at slot 0)
    // PUSH1 0x0a PUSH1 0x00 RETURN   (return 10 bytes of runtime code)
    const init_code = [_]u8{
        0x60, 0x42, 0x60, 0x00, 0x55, // Store 0x42 at slot 0
        0x60, 0x0a, 0x60, 0x00, 0xF3, // Return 10 bytes
    };

    // Write init code to memory
    try frame.memory.set_data(0, &init_code);

    // Set up CREATE result
    const new_contract_address = Address.from_u256(0x2222222222222222222222222222222222222222);
    vm.create_result = .{
        .success = true,
        .address = new_contract_address,
        .gas_left = 90000,
        .output = null,
    };

    // Execute CREATE
    try frame.stack.append(0); // offset
    try frame.stack.append(init_code.len); // size
    try frame.stack.append(1000); // value to send

    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0xF0);

    // Check result
    const created_address = try frame.stack.pop();
    try testing.expectEqual(Address.to_u256(new_contract_address), created_address);

    // Verify address is warm (EIP-2929)
    try testing.expect(!vm.is_address_cold(new_contract_address));

    // Gas should be consumed
    try testing.expect(frame.gas_remaining < 100000);
}

// Test CALL interaction between contracts
test "Integration: inter-contract calls" {
    const allocator = testing.allocator;

    // Create database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const contract_address = Address.from_u256(0x3333333333333333333333333333333333333333);
    const alice_address = Address.from_u256(0x1111111111111111111111111111111111111111);
    const target_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Set up accounts
    try vm.set_balance(contract_address, 10000);
    try vm.set_balance(target_address, 1000);

    // Prepare call data
    const call_data = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    try frame.memory.set_data(0, &call_data);

    // Set up mock call result
    const return_data = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    vm.call_result = .{
        .success = true,
        .gas_left = 80000,
        .output = &return_data,
    };

    // Execute CALL
    try frame.stack.append(50000); // gas
    try frame.stack.append(Address.to_u256(target_address)); // to
    try frame.stack.append(500); // value to send
    try frame.stack.append(0); // args_offset
    try frame.stack.append(4); // args_size
    try frame.stack.append(100); // ret_offset
    try frame.stack.append(32); // ret_size

    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0xF1);

    // Check success
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());

    // Verify return data was written to memory
    const returned_data = try frame.memory.get_slice(100, return_data.len);
    try testing.expectEqualSlices(u8, &return_data, returned_data);

    // Check gas accounting
    try testing.expect(frame.gas_remaining < 100000);
}

// Test DELEGATECALL preserving context
test "Integration: delegatecall context preservation" {
    const allocator = testing.allocator;

    // Create database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const contract_address = Address.from_u256(0x3333333333333333333333333333333333333333);
    const caller_address = Address.from_u256(0x1111111111111111111111111111111111111111);
    const target_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        caller_address,
        contract_address,
        1000, // value
        1_000_000, // gas
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(50000)
        .build();
    defer frame.deinit();
    frame.value = 1000;

    // Prepare call data
    const call_data = [_]u8{ 0x01, 0x02 };
    try frame.memory.set_data(0, &call_data);

    // Set up mock call result
    vm.call_result = .{
        .success = true,
        .gas_left = 40000,
        .output = &[_]u8{0xFF},
    };

    // Execute DELEGATECALL
    try frame.stack.append(30000); // gas
    try frame.stack.append(Address.to_u256(target_address)); // to
    try frame.stack.append(0); // args_offset
    try frame.stack.append(2); // args_size
    try frame.stack.append(50); // ret_offset
    try frame.stack.append(1); // ret_size

    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0xF4);

    // Check success
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());

    // Context should be preserved (caller, value, storage context)
    try testing.expectEqual(contract_address, frame.contract.address);
    try testing.expectEqual(caller_address, frame.contract.caller);
    try testing.expectEqual(@as(u256, 1000), frame.value);
}

// Test STATICCALL read-only enforcement
test "Integration: staticcall restrictions" {
    const allocator = testing.allocator;

    // Create database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const contract_address = Address.from_u256(0x3333333333333333333333333333333333333333);
    const alice_address = Address.from_u256(0x1111111111111111111111111111111111111111);
    const target_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(50000)
        .build();
    defer frame.deinit();

    // Set up for STATICCALL
    vm.call_result = .{
        .success = true,
        .gas_left = 40000,
        .output = null,
    };

    // Execute STATICCALL
    try frame.stack.append(30000); // gas
    try frame.stack.append(Address.to_u256(target_address)); // to
    try frame.stack.append(0); // args_offset
    try frame.stack.append(0); // args_size
    try frame.stack.append(0); // ret_offset
    try frame.stack.append(0); // ret_size

    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0xFA);

    // Check success
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());

    // Now test that state modifications fail in static context
    frame.is_static = true;

    // Try SSTORE - should fail
    try frame.stack.append(0); // slot
    try frame.stack.append(100); // value
    const sstore_result = vm.table.execute(0, interpreter, state, 0x55);
    try testing.expectError(ExecutionError.Error.WriteProtection, sstore_result);

    // Try LOG0 - should fail
    frame.stack.clear();
    try frame.stack.append(0); // offset
    try frame.stack.append(0); // size
    const log_result = vm.table.execute(0, interpreter, state, 0xA0);
    try testing.expectError(ExecutionError.Error.WriteProtection, log_result);

    // Try CREATE - should fail
    frame.stack.clear();
    try frame.stack.append(0); // offset
    try frame.stack.append(0); // size
    try frame.stack.append(0); // value
    const create_result = vm.table.execute(0, interpreter, state, 0xF0);
    try testing.expectError(ExecutionError.Error.WriteProtection, create_result);
}

// Test CREATE2 deterministic address
test "Integration: CREATE2 deterministic deployment" {
    const allocator = testing.allocator;

    // Create database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const contract_address = Address.from_u256(0x3333333333333333333333333333333333333333);
    const alice_address = Address.from_u256(0x1111111111111111111111111111111111111111);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Simple init code
    const init_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xF3 }; // PUSH1 0 PUSH1 0 RETURN

    // Write init code to memory
    try frame.memory.set_data(0, &init_code);

    // Set up CREATE2 result
    const deterministic_address = Address.from_u256(0x4444444444444444444444444444444444444444);
    vm.create_result = .{
        .success = true,
        .address = deterministic_address,
        .gas_left = 90000,
        .output = null,
    };

    // Execute CREATE2 with salt
    const salt: u256 = 0x1234567890ABCDEF;
    try frame.stack.append(0); // offset
    try frame.stack.append(init_code.len); // size
    try frame.stack.append(0); // value
    try frame.stack.append(salt); // salt

    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0xF5);

    // Check result
    const created_address = try frame.stack.pop();
    try testing.expectEqual(Address.to_u256(deterministic_address), created_address);

    // Address should be warm
    try testing.expect(!vm.is_address_cold(deterministic_address));

    // Gas consumption should include hashing cost
    const gas_used = 100000 - frame.gas_remaining;
    const expected_min_gas = init_code.len * 200 + // init code cost
        ((init_code.len + 31) / 32) * 6; // hashing cost
    try testing.expect(gas_used >= expected_min_gas);
}

// Test SELFDESTRUCT workflow
test "Integration: selfdestruct with balance transfer" {
    const allocator = testing.allocator;

    // Create database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const contract_address = Address.from_u256(0x3333333333333333333333333333333333333333);
    const alice_address = Address.from_u256(0x1111111111111111111111111111111111111111);
    const beneficiary = Address.from_u256(0x2222222222222222222222222222222222222222);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Set up contract with balance
    const contract_balance: u256 = 5000;
    try vm.set_balance(contract_address, contract_balance);

    // Execute SELFDESTRUCT
    try frame.stack.append(Address.to_u256(beneficiary));

    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = &frame;
    const result = vm.table.execute(0, interpreter, state, 0xFF);
    try testing.expectError(ExecutionError.Error.STOP, result);

    // Verify contract is marked for deletion
    try testing.expect(vm.is_marked_for_deletion(contract_address));

    // Verify beneficiary is recorded
    try testing.expectEqual(beneficiary, vm.get_selfdestruct_beneficiary(contract_address));
}

// Test call depth limit
test "Integration: call depth limit enforcement" {
    const allocator = testing.allocator;

    // Create database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const contract_address = Address.from_u256(0x3333333333333333333333333333333333333333);
    const alice_address = Address.from_u256(0x1111111111111111111111111111111111111111);
    const target_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Set depth to maximum
    frame.depth = 1024;

    // Try CREATE - should fail silently (push 0)
    try frame.stack.append(0); // offset
    try frame.stack.append(0); // size
    try frame.stack.append(0); // value

    const interpreter1: Operation.Interpreter = &vm;
    const state1: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter1, state1, 0xF0);

    // Should push 0 for failure
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());

    // Try CALL - should fail silently (push 0)
    try frame.stack.append(1000); // gas
    try frame.stack.append(Address.to_u256(target_address)); // to
    try frame.stack.append(0); // value
    try frame.stack.append(0); // args_offset
    try frame.stack.append(0); // args_size
    try frame.stack.append(0); // ret_offset
    try frame.stack.append(0); // ret_size

    const interpreter2: Operation.Interpreter = &vm;
    const state2: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter2, state2, 0xF1);

    // Should push 0 for failure
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// Test return data handling across calls
test "Integration: return data buffer management" {
    const allocator = testing.allocator;

    // Create database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const contract_address = Address.from_u256(0x3333333333333333333333333333333333333333);
    const alice_address = Address.from_u256(0x1111111111111111111111111111111111111111);
    const target_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(50000)
        .build();
    defer frame.deinit();

    // Initial state - no return data
    const interpreter1: Operation.Interpreter = &vm;
    const state1: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter1, state1, 0x3D);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());

    // Make a call that returns data
    const return_data = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55 };
    vm.call_result = .{
        .success = true,
        .gas_left = 40000,
        .output = &return_data,
    };

    try frame.stack.append(30000); // gas
    try frame.stack.append(Address.to_u256(target_address)); // to
    try frame.stack.append(0); // value
    try frame.stack.append(0); // args_offset
    try frame.stack.append(0); // args_size
    try frame.stack.append(0); // ret_offset
    try frame.stack.append(0); // ret_size (don't copy to memory)

    const interpreter2: Operation.Interpreter = &vm;
    const state2: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter2, state2, 0xF1);
    _ = try frame.stack.pop(); // Discard success flag

    // Check return data size
    const interpreter3: Operation.Interpreter = &vm;
    const state3: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter3, state3, 0x3D);
    try testing.expectEqual(@as(u256, return_data.len), try frame.stack.pop());

    // Copy return data to memory
    try frame.stack.append(200); // memory offset
    try frame.stack.append(0); // data offset
    try frame.stack.append(return_data.len); // size

    const interpreter4: Operation.Interpreter = &vm;
    const state4: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter4, &state4, 0x3E);

    // Verify data was copied
    const copied_data = try frame.memory.get_slice(200, return_data.len);
    try testing.expectEqualSlices(u8, &return_data, copied_data);

    // Try to copy beyond return data size - should fail
    try frame.stack.append(300); // memory offset
    try frame.stack.append(0); // data offset
    try frame.stack.append(10); // size (too large)

    const interpreter5: Operation.Interpreter = &vm;
    const state5: Operation.State = &frame;
    const copy_result = vm.table.execute(0, &interpreter5, &state5, 0x3E);
    try testing.expectError(ExecutionError.Error.ReturnDataOutOfBounds, copy_result);
}
