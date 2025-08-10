const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const CallParams = Evm.Host.CallParams;
const CallResult = Evm.CallResult;
const Contract = Evm.Contract;
const Frame = Evm.Frame;
const MemoryDatabase = Evm.MemoryDatabase;
const ExecutionError = Evm.ExecutionError;
// Updated to new API - migration in progress, tests not run yet
// Updated to new API - migration in progress, tests not run yet

test "Control: STOP halts execution" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Execute STOP opcode - should return STOP error
    const result = evm.table.execute(0, interpreter, state, 0x00);
    try testing.expectError(ExecutionError.Error.STOP, result);

    // Gas should not be consumed by the opcode itself (jump table handles base gas)
    try testing.expectEqual(@as(u64, 1000), frame.gas_remaining);
}

test "Control: JUMP basic operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    // Create contract with JUMPDEST at position 5
    var code = [_]u8{0} ** 10;
    code[5] = 0x5b; // JUMPDEST opcode

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Valid jump to JUMPDEST
    try frame.stack.append(5);
    _ = try evm.table.execute(0, interpreter, state, 0x56);
    try testing.expectEqual(@as(usize, 5), frame.pc);
    try testing.expectEqual(@as(usize, 0), frame.stack.size);

    // Test 2: Invalid jump (not a JUMPDEST)
    frame.pc = 0; // Reset PC
    try frame.stack.append(3);
    const result = evm.table.execute(0, interpreter, state, 0x56);
    try testing.expectError(ExecutionError.Error.InvalidJump, result);

    // Test 3: Jump out of bounds
    frame.stack.clear();
    try frame.stack.append(100);
    const result2 = evm.table.execute(0, interpreter, state, 0x56);
    try testing.expectError(ExecutionError.Error.InvalidJump, result2);

    // Test 4: Jump to max u256 (out of range)
    frame.stack.clear();
    try frame.stack.append(std.math.maxInt(u256));
    const result3 = evm.table.execute(0, interpreter, state, 0x56);
    try testing.expectError(ExecutionError.Error.InvalidJump, result3);
}

test "Control: JUMPI conditional jump" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    // Create contract with JUMPDEST at position 5
    var code = [_]u8{0} ** 10;
    code[5] = 0x5b; // JUMPDEST opcode

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Jump when condition is non-zero
    // JUMPI expects stack: [condition, destination] with destination on top
    try frame.stack.append(1);
    try frame.stack.append(5);
    _ = try evm.table.execute(0, interpreter, state, 0x57);
    try testing.expectEqual(@as(usize, 5), frame.pc);
    try testing.expectEqual(@as(usize, 0), frame.stack.size);

    // Test 2: No jump when condition is zero
    frame.pc = 0; // Reset PC
    try frame.stack.append(0);
    try frame.stack.append(5);
    _ = try evm.table.execute(0, interpreter, state, 0x57);
    try testing.expectEqual(@as(usize, 0), frame.pc); // PC unchanged
    try testing.expectEqual(@as(usize, 0), frame.stack.size);

    // Test 3: Invalid jump with non-zero condition
    frame.pc = 0;
    try frame.stack.append(1);
    try frame.stack.append(3);
    const result = evm.table.execute(0, interpreter, state, 0x57);
    try testing.expectError(ExecutionError.Error.InvalidJump, result);

    // Test 4: Invalid destination is OK if condition is zero
    frame.stack.clear();
    frame.pc = 0;
    try frame.stack.append(0);
    try frame.stack.append(3);
    _ = try evm.table.execute(0, interpreter, state, 0x57);
    try testing.expectEqual(@as(usize, 0), frame.pc); // No jump occurred
}

test "Control: PC returns program counter" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: PC at position 0
    _ = try evm.table.execute(0, interpreter, state, 0x58);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result1);

    // Test 2: PC at position 42
    frame.stack.clear();
    frame.pc = 42;
    _ = try evm.table.execute(42, interpreter, state, 0x58);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 42), result2);

    // Test 3: PC at large position
    frame.stack.clear();
    frame.pc = 1000;
    _ = try evm.table.execute(1000, interpreter, state, 0x58);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1000), result3);
}

test "Control: JUMPDEST is a no-op" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push some values to stack to ensure it's not modified
    try frame.stack.append(42);
    try frame.stack.append(100);

    // Execute JUMPDEST - should be a no-op
    _ = try evm.table.execute(0, interpreter, state, 0x5B);

    // Stack should be unchanged
    try testing.expectEqual(@as(usize, 2), frame.stack.size);
    const val1 = try frame.stack.pop();
    const val2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 100), val1);
    try testing.expectEqual(@as(u256, 42), val2);

    // PC should not be modified by the opcode
    try testing.expectEqual(@as(usize, 0), frame.pc);
}

test "Control: RETURN with data" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Return with data
    const test_data = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    try frame.memory.set_data(10, &test_data);
    try frame.stack.append(4); // size (first)
    try frame.stack.append(10); // offset (second, on top)

    const result = evm.table.execute(0, interpreter, state, 0xF3);
    try testing.expectError(ExecutionError.Error.STOP, result); // RETURN uses STOP error

    // Check output was set
    try testing.expectEqualSlices(u8, &test_data, frame.output);

    // Test 2: Return with zero size
    frame.stack.clear();
    frame.output = &[_]u8{ 1, 2, 3 }; // Set some existing output
    try frame.stack.append(0);
    try frame.stack.append(0);

    const result2 = evm.table.execute(0, interpreter, state, 0xF3);
    try testing.expectError(ExecutionError.Error.STOP, result2);
    try testing.expectEqual(@as(usize, 0), frame.output.len);

    // Test 3: Return with memory expansion
    frame.stack.clear();
    frame.gas_remaining = 1000;
    try frame.stack.append(100);
    try frame.stack.append(32);

    const result3 = evm.table.execute(0, interpreter, state, 0xF3);
    try testing.expectError(ExecutionError.Error.STOP, result3);

    // Gas should be consumed for memory expansion
    try testing.expect(frame.gas_remaining < 1000);
}

test "Control: REVERT with data" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Revert with data
    const test_data = [_]u8{ 0x08, 0xc3, 0x79, 0xa0 }; // Common revert signature
    try frame.memory.set_data(0, &test_data);
    try frame.stack.append(4); // size (first)
    try frame.stack.append(0); // offset (second, on top)

    const result = evm.table.execute(0, interpreter, state, 0xFD);
    try testing.expectError(ExecutionError.Error.REVERT, result);

    // Check output was set
    try testing.expectEqualSlices(u8, &test_data, frame.output);

    // Test 2: Revert with zero size
    frame.stack.clear();
    try frame.stack.append(0);
    try frame.stack.append(0);

    const result2 = evm.table.execute(0, interpreter, state, 0xFD);
    try testing.expectError(ExecutionError.Error.REVERT, result2);
    try testing.expectEqual(@as(usize, 0), frame.output.len);

    // Test 3: Revert with out of bounds offset
    frame.stack.clear();
    try frame.stack.append(std.math.maxInt(u256));
    try frame.stack.append(32);

    const result3 = evm.table.execute(0, interpreter, state, 0xFD);
    try testing.expectError(ExecutionError.Error.OutOfOffset, result3);
}

test "Control: INVALID always fails" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // INVALID should always return InvalidOpcode error
    const result = evm.table.execute(0, interpreter, state, 0xFE);
    try testing.expectError(ExecutionError.Error.InvalidOpcode, result);

    // Stack should be unchanged
    try frame.stack.append(42);
    const result2 = evm.table.execute(0, interpreter, state, 0xFE);
    try testing.expectError(ExecutionError.Error.InvalidOpcode, result2);
    try testing.expectEqual(@as(usize, 1), frame.stack.size);
}

test "Control: SELFDESTRUCT basic operation" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        100, // Contract has 100 wei
        10000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Selfdestruct to beneficiary
    const beneficiary_addr: Address.Address = [_]u8{0x22} ** 20;
    const beneficiary_u256 = primitives.Address.to_u256(beneficiary_addr);
    try frame.stack.append(beneficiary_u256);

    const result = evm.table.execute(0, interpreter, state, 0xFF);
    try testing.expectError(ExecutionError.Error.STOP, result);

    // Gas should be consumed for base SELFDESTRUCT (5000) + cold address access (2600)
    const gas_used = 10000 - frame.gas_remaining;
    try testing.expect(gas_used >= 5000); // At least base SELFDESTRUCT gas

    // Test 2: Selfdestruct with warm beneficiary
    frame.stack.clear();
    frame.gas_remaining = 10000;

    // Pre-warm the beneficiary address
    _ = try evm.access_list.access_address(beneficiary_addr);
    try frame.stack.append(beneficiary_u256);

    const result2 = evm.table.execute(0, interpreter, state, 0xFF);
    try testing.expectError(ExecutionError.Error.STOP, result2);

    // Only base SELFDESTRUCT gas (5000) should be consumed for warm address
    const gas_used2 = 10000 - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 5000), gas_used2);

    // Test 3: Selfdestruct in static context should fail
    frame.stack.clear();
    frame.is_static = true;
    try frame.stack.append(beneficiary_u256);

    const result3 = evm.table.execute(0, interpreter, state, 0xFF);
    try testing.expectError(ExecutionError.Error.WriteProtection, result3);
}

test "Control: Stack underflow errors" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const jumpdest_code = [_]u8{0x5b}; // JUMPDEST at position 0
    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &jumpdest_code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test JUMP with empty stack
    const jump_result = evm.table.execute(0, interpreter, state, 0x56);
    try testing.expectError(ExecutionError.Error.StackUnderflow, jump_result);

    // Test JUMPI with insufficient stack
    try frame.stack.append(0); // Only destination, no condition
    const jumpi_result = evm.table.execute(0, interpreter, state, 0x57);
    try testing.expectError(ExecutionError.Error.StackUnderflow, jumpi_result);

    // Test RETURN with empty stack
    frame.stack.clear();
    const return_result = evm.table.execute(0, interpreter, state, 0xF3);
    try testing.expectError(ExecutionError.Error.StackUnderflow, return_result);

    // Test REVERT with only one value
    try frame.stack.append(0);
    const revert_result = evm.table.execute(0, interpreter, state, 0xFD);
    try testing.expectError(ExecutionError.Error.StackUnderflow, revert_result);

    // Test SELFDESTRUCT with empty stack
    frame.stack.clear();
    const selfdestruct_result = evm.table.execute(0, interpreter, state, 0xFF);
    try testing.expectError(ExecutionError.Error.StackUnderflow, selfdestruct_result);
}
