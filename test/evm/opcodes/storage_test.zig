const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const Contract = Evm.Contract;
const Frame = Evm.Frame;
const MemoryDatabase = Evm.MemoryDatabase;
const ExecutionError = Evm.ExecutionError;
// Updated to new API - migration in progress, tests not run yet

// Test SLOAD operation
test "SLOAD: load value from storage" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        3000,
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
        .withGas(3000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Set storage value
    try evm.state.set_storage(contract_addr, 0x123, 0x456789);

    // Push storage slot
    try frame.stack.append(0x123);

    // Execute SLOAD
    _ = try evm.table.execute(0, interpreter, state, 0x54);

    // Should return the stored value
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0x456789), result);
}

test "SLOAD: load from uninitialized slot returns zero" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        3000,
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
        .withGas(3000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push storage slot that hasn't been set
    try frame.stack.append(0x999);

    // Execute SLOAD
    _ = try evm.table.execute(0, interpreter, state, 0x54);

    // Should return 0
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

test "SLOAD: cold storage access costs more gas" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        3000,
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
        .withGas(3000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push storage slot
    try frame.stack.append(0x123);

    const gas_before = frame.gas_remaining;

    // Execute SLOAD - cold access
    _ = try evm.table.execute(0, interpreter, state, 0x54);

    // Should consume 2100 gas for cold access
    const cold_gas_used = gas_before - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 2100), cold_gas_used);

    // Clean up stack
    _ = try frame.stack.pop();

    // Second access should be warm
    try frame.stack.append(0x123);
    const gas_before_warm = frame.gas_remaining;

    _ = try evm.table.execute(0, interpreter, state, 0x54);

    // Should consume 100 gas for warm access
    const warm_gas_used = gas_before_warm - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 100), warm_gas_used);
}

// Test SSTORE operation
test "SSTORE: store value to storage" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        25000,
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
        .withGas(25000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push value and slot (value first, then slot - stack is LIFO)
    try frame.stack.append(0xABCDEF); // value
    try frame.stack.append(0x555); // slot

    // Execute SSTORE
    _ = try evm.table.execute(0, interpreter, state, 0x55);

    // Check that value was stored
    const stored_value = evm.state.get_storage(contract_addr, 0x555);
    try testing.expectEqual(@as(u256, 0xABCDEF), stored_value);
}

test "SSTORE: overwrite existing value" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        25000,
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
        .withGas(25000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Set initial value
    try evm.state.set_storage(contract_addr, 0x100, 0x111);

    // Push new value and slot (value first, then slot - stack is LIFO)
    try frame.stack.append(0x222); // new value
    try frame.stack.append(0x100); // slot

    // Execute SSTORE
    _ = try evm.table.execute(0, interpreter, state, 0x55);

    // Check that value was updated
    const stored_value = evm.state.get_storage(contract_addr, 0x100);
    try testing.expectEqual(@as(u256, 0x222), stored_value);
}

test "SSTORE: write protection in static call" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        3000,
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
        .withGas(3000)
        .build();
    defer frame.deinit();

    // Set static call
    frame.is_static = true;

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push value and slot (value first, then slot - stack is LIFO)
    try frame.stack.append(0x123); // value
    try frame.stack.append(0x456); // slot

    // Execute SSTORE - should fail
    const result = evm.table.execute(0, interpreter, state, 0x55);
    try testing.expectError(ExecutionError.Error.WriteProtection, result);
}

test "SSTORE: cold storage access costs more gas" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        25000,
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
        .withGas(25000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push value and slot
    try frame.stack.append(0x123); // value
    try frame.stack.append(0x789); // slot

    const gas_before = frame.gas_remaining;

    // Execute SSTORE - cold access
    _ = try evm.table.execute(0, interpreter, state, 0x55);

    // Should consume 2100 gas for cold access + 20000 for SSTORE_SET (new non-zero value)
    const cold_gas_used = gas_before - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 22100), cold_gas_used);

    // Second access to same slot should be warm
    try frame.stack.append(0x456); // different value
    try frame.stack.append(0x789); // same slot
    const gas_before_warm = frame.gas_remaining;

    _ = try evm.table.execute(0, interpreter, state, 0x55);

    // Should consume 2900 gas for warm SSTORE_RESET (changing existing non-zero value)
    const warm_gas_used = gas_before_warm - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 2900), warm_gas_used);
}

// Test TLOAD operation (EIP-1153)
test "TLOAD: load value from transient storage" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        3000,
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
        .withGas(3000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Set transient storage value
    try evm.state.set_transient_storage(contract_addr, 0xAAA, 0xBBBBBB);

    // Push storage slot
    try frame.stack.append(0xAAA);

    // Execute TLOAD
    _ = try evm.table.execute(0, interpreter, state, 0x5C);

    // Should return the transient value
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0xBBBBBB), result);
}

test "TLOAD: load from uninitialized slot returns zero" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        3000,
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
        .withGas(3000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push storage slot that hasn't been set
    try frame.stack.append(0xFFF);

    // Execute TLOAD
    _ = try evm.table.execute(0, interpreter, state, 0x5C);

    // Should return 0
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

test "TLOAD: transient storage is separate from regular storage" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        5000,
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
        .withGas(5000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Set same slot in both storages with different values
    try evm.state.set_storage(contract_addr, 0x100, 0x111);
    try evm.state.set_transient_storage(contract_addr, 0x100, 0x222);

    // Load from transient storage
    try frame.stack.append(0x100);
    _ = try evm.table.execute(0, interpreter, state, 0x5C);

    // Should return transient value, not regular storage value
    const transient_result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0x222), transient_result);

    // Load from regular storage
    try frame.stack.append(0x100);
    _ = try evm.table.execute(0, interpreter, state, 0x54);

    // Should return regular storage value
    const regular_result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0x111), regular_result);
}

// Test TSTORE operation (EIP-1153)
test "TSTORE: store value to transient storage" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        3000,
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
        .withGas(3000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push value and slot (value first, then slot - stack is LIFO)
    try frame.stack.append(0xDEADBEEF); // value
    try frame.stack.append(0x777); // slot

    // Execute TSTORE
    _ = try evm.table.execute(0, interpreter, state, 0x5D);

    // Check that value was stored
    const stored_value = evm.state.get_transient_storage(contract_addr, 0x777);
    try testing.expectEqual(@as(u256, 0xDEADBEEF), stored_value);
}

test "TSTORE: overwrite existing transient value" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        3000,
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
        .withGas(3000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Set initial transient value
    try evm.state.set_transient_storage(contract_addr, 0x200, 0x333);

    // Push new value and slot
    try frame.stack.append(0x444); // new value
    try frame.stack.append(0x200); // slot

    // Execute TSTORE
    _ = try evm.table.execute(0, interpreter, state, 0x5D);

    // Check that value was updated
    const stored_value = evm.state.get_transient_storage(contract_addr, 0x200);
    try testing.expectEqual(@as(u256, 0x444), stored_value);
}

test "TSTORE: write protection in static call" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        3000,
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
        .withGas(3000)
        .build();
    defer frame.deinit();

    // Set static call
    frame.is_static = true;

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push value and slot
    try frame.stack.append(0x123); // value
    try frame.stack.append(0x456); // slot

    // Execute TSTORE - should fail
    const result = evm.table.execute(0, interpreter, state, 0x5D);
    try testing.expectError(ExecutionError.Error.WriteProtection, result);
}

test "TSTORE: does not affect regular storage" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        3000,
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
        .withGas(3000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Set regular storage value
    try evm.state.set_storage(contract_addr, 0x300, 0x555);

    // Store to transient storage at same slot
    try frame.stack.append(0x666); // value
    try frame.stack.append(0x300); // slot

    // Execute TSTORE
    _ = try evm.table.execute(0, interpreter, state, 0x5D);

    // Regular storage should be unchanged
    const regular_value = evm.state.get_storage(contract_addr, 0x300);
    try testing.expectEqual(@as(u256, 0x555), regular_value);

    // Transient storage should have new value
    const transient_value = evm.state.get_transient_storage(contract_addr, 0x300);
    try testing.expectEqual(@as(u256, 0x666), transient_value);
}

// Test stack errors
test "SLOAD: stack underflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        3000,
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
        .withGas(3000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Empty stack

    // Execute SLOAD - should fail
    const result = evm.table.execute(0, interpreter, state, 0x54);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

test "SSTORE: stack underflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        3000,
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
        .withGas(3000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push only one value (need two)
    try frame.stack.append(0x123);

    // Execute SSTORE - should fail
    const result = evm.table.execute(0, interpreter, state, 0x55);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

test "TLOAD: stack underflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        3000,
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
        .withGas(3000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Empty stack

    // Execute TLOAD - should fail
    const result = evm.table.execute(0, interpreter, state, 0x5C);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

test "TSTORE: stack underflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        3000,
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
        .withGas(3000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push only one value (need two)
    try frame.stack.append(0x789);

    // Execute TSTORE - should fail
    const result = evm.table.execute(0, interpreter, state, 0x5D);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

// Test gas consumption
test "TLOAD: gas consumption" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        3000,
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
        .withGas(3000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push storage slot
    try frame.stack.append(0x123);

    const gas_before = frame.gas_remaining;

    // Execute TLOAD
    _ = try evm.table.execute(0, interpreter, state, 0x5C);

    // TLOAD base cost is 100 gas (no cold/warm distinction for transient storage)
    const gas_used = gas_before - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 100), gas_used);
}

test "TSTORE: gas consumption" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        3000,
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
        .withGas(3000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push value and slot
    try frame.stack.append(0x123); // value
    try frame.stack.append(0x456); // slot

    const gas_before = frame.gas_remaining;

    // Execute TSTORE
    _ = try evm.table.execute(0, interpreter, state, 0x5D);

    // TSTORE base cost is 100 gas (no cold/warm distinction for transient storage)
    const gas_used = gas_before - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 100), gas_used);
}
