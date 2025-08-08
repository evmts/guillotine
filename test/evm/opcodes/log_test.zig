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

// Test LOG0 operation
test "LOG0: emit log with no topics" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
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

    // Write data to memory
    const log_data = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    var i: usize = 0;
    while (i < log_data.len) : (i += 1) {
        try frame.memory.set_data(i, &[_]u8{log_data[i]});
    }

    // Push size and offset (bottom to top on stack)
    try frame.stack.append(4); // size
    try frame.stack.append(0); // offset

    // Execute LOG0
    _ = try evm.table.execute(0, interpreter, state, 0xA0);

    // Check that log was emitted
    try testing.expectEqual(@as(usize, 1), evm.state.logs.items.len);
    const emitted_log = evm.state.logs.items[0];
    try testing.expectEqual(contract_addr, emitted_log.address);
    try testing.expectEqual(@as(usize, 0), emitted_log.topics.len);
    try testing.expectEqualSlices(u8, &log_data, emitted_log.data);
}

test "LOG0: emit log with empty data" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
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

    // Push size and offset for empty data
    try frame.stack.append(0); // size
    try frame.stack.append(0); // offset

    // Execute LOG0
    _ = try evm.table.execute(0, interpreter, state, 0xA0);

    // Check that log was emitted with empty data
    try testing.expectEqual(@as(usize, 1), evm.state.logs.items.len);
    const emitted_log = evm.state.logs.items[0];
    try testing.expectEqual(@as(usize, 0), emitted_log.topics.len);
    try testing.expectEqual(@as(usize, 0), emitted_log.data.len);
}

// Test LOG1 operation
test "LOG1: emit log with one topic" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
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

    // Write data to memory
    const log_data = [_]u8{ 0xAA, 0xBB };
    var i: usize = 0;
    while (i < log_data.len) : (i += 1) {
        try frame.memory.set_data(i, &[_]u8{log_data[i]});
    }

    // Push in order: topic, size, offset (bottom to top on stack)
    try frame.stack.append(0x123456); // topic
    try frame.stack.append(2); // size
    try frame.stack.append(0); // offset

    // Execute LOG1
    _ = try evm.table.execute(0, interpreter, state, 0xA1);

    // Check that log was emitted
    try testing.expectEqual(@as(usize, 1), evm.state.logs.items.len);
    const emitted_log = evm.state.logs.items[0];
    try testing.expectEqual(@as(usize, 1), emitted_log.topics.len);
    try testing.expectEqual(@as(u256, 0x123456), emitted_log.topics[0]);
    try testing.expectEqualSlices(u8, &log_data, emitted_log.data);
}

// Test LOG2 operation
test "LOG2: emit log with two topics" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
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

    // Write data to memory
    const log_data = [_]u8{ 0x01, 0x02, 0x03 };
    var i: usize = 0;
    while (i < log_data.len) : (i += 1) {
        try frame.memory.set_data(10 + i, &[_]u8{log_data[i]});
    }

    // Push in order: topic1, topic2, size, offset (bottom to top on stack)
    try frame.stack.append(0xCAFE); // topic1
    try frame.stack.append(0xBEEF); // topic2
    try frame.stack.append(3); // size
    try frame.stack.append(10); // offset

    // Execute LOG2
    _ = try evm.table.execute(0, interpreter, state, 0xA2);

    // Check that log was emitted
    try testing.expectEqual(@as(usize, 1), evm.state.logs.items.len);
    const emitted_log = evm.state.logs.items[0];
    try testing.expectEqual(@as(usize, 2), emitted_log.topics.len);
    try testing.expectEqual(@as(u256, 0xCAFE), emitted_log.topics[0]);
    try testing.expectEqual(@as(u256, 0xBEEF), emitted_log.topics[1]);
    try testing.expectEqualSlices(u8, &log_data, emitted_log.data);
}

// Test LOG3 operation
test "LOG3: emit log with three topics" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
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

    // Push in order: topic1, topic2, topic3, size, offset (bottom to top on stack)
    try frame.stack.append(0x111); // topic1
    try frame.stack.append(0x222); // topic2
    try frame.stack.append(0x333); // topic3
    try frame.stack.append(0); // size (empty data)
    try frame.stack.append(0); // offset

    // Execute LOG3
    _ = try evm.table.execute(0, interpreter, state, 0xA3);

    // Check that log was emitted
    try testing.expectEqual(@as(usize, 1), evm.state.logs.items.len);
    const emitted_log = evm.state.logs.items[0];
    try testing.expectEqual(@as(usize, 3), emitted_log.topics.len);
    try testing.expectEqual(@as(u256, 0x111), emitted_log.topics[0]);
    try testing.expectEqual(@as(u256, 0x222), emitted_log.topics[1]);
    try testing.expectEqual(@as(u256, 0x333), emitted_log.topics[2]);
    try testing.expectEqual(@as(usize, 0), emitted_log.data.len);
}

// Test LOG4 operation
test "LOG4: emit log with four topics" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
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

    // Write large data to memory
    var log_data: [100]u8 = undefined;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        log_data[i] = @intCast(i);
        try frame.memory.set_data(i, &[_]u8{log_data[i]});
    }

    // Push in order: topic1, topic2, topic3, topic4, size, offset (bottom to top on stack)
    try frame.stack.append(0x1111); // topic1
    try frame.stack.append(0x2222); // topic2
    try frame.stack.append(0x3333); // topic3
    try frame.stack.append(0x4444); // topic4
    try frame.stack.append(100); // size
    try frame.stack.append(0); // offset

    // Execute LOG4
    _ = try evm.table.execute(0, interpreter, state, 0xA4);

    // Check that log was emitted
    try testing.expectEqual(@as(usize, 1), evm.state.logs.items.len);
    const emitted_log = evm.state.logs.items[0];
    try testing.expectEqual(@as(usize, 4), emitted_log.topics.len);
    try testing.expectEqual(@as(u256, 0x1111), emitted_log.topics[0]);
    try testing.expectEqual(@as(u256, 0x2222), emitted_log.topics[1]);
    try testing.expectEqual(@as(u256, 0x3333), emitted_log.topics[2]);
    try testing.expectEqual(@as(u256, 0x4444), emitted_log.topics[3]);
    try testing.expectEqualSlices(u8, &log_data, emitted_log.data);
}

// Test LOG operations in static call
test "LOG0: write protection in static call" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
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

    // Set static call
    frame.is_static = true;

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push length and offset (stack is LIFO)
    try frame.stack.append(0); // length (pushed first, popped second)
    try frame.stack.append(0); // offset (pushed last, popped first)

    // Execute LOG0 - should fail
    const result = evm.table.execute(0, interpreter, state, 0xA0);
    try testing.expectError(ExecutionError.Error.WriteProtection, result);
}

test "LOG1: write protection in static call" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
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

    // Set static call
    frame.is_static = true;

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push topic, size and offset
    try frame.stack.append(0x123); // topic
    try frame.stack.append(0); // size
    try frame.stack.append(0); // offset

    // Execute LOG1 - should fail
    const result = evm.table.execute(0, interpreter, state, 0xA1);
    try testing.expectError(ExecutionError.Error.WriteProtection, result);
}

// Test gas consumption
test "LOG0: gas consumption" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
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

    // Push size and offset for 32 bytes
    try frame.stack.append(32); // size
    try frame.stack.append(0); // offset

    const gas_before = frame.gas_remaining;

    // Execute LOG0
    _ = try evm.table.execute(0, interpreter, state, 0xA0);

    // LOG0 base cost is 375 gas
    // Plus 8 gas per byte: 32 * 8 = 256
    // Plus memory expansion: 3 gas (for 1 word)
    // Total: 375 + 256 + 3 = 634
    try testing.expectEqual(@as(u64, 634), gas_before - frame.gas_remaining);
}

test "LOG4: gas consumption with topics" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
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

    // Push topics, size and offset
    try frame.stack.append(0x1); // topic1
    try frame.stack.append(0x2); // topic2
    try frame.stack.append(0x3); // topic3
    try frame.stack.append(0x4); // topic4
    try frame.stack.append(10); // size
    try frame.stack.append(0); // offset

    const gas_before = frame.gas_remaining;

    // Execute LOG4
    _ = try evm.table.execute(0, interpreter, state, 0xA4);

    // LOG4 base cost is 375 gas
    // Plus 375 gas per topic: 4 * 375 = 1500
    // Plus 8 gas per byte: 10 * 8 = 80
    // Plus memory expansion: 3 gas (for 1 word)
    // Total: 375 + 1500 + 80 + 3 = 1958
    try testing.expectEqual(@as(u64, 1958), gas_before - frame.gas_remaining);
}

// Test memory expansion
test "LOG0: memory expansion gas" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
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

    // Push size and offset that requires memory expansion (stack is LIFO)
    try frame.stack.append(32); // size
    try frame.stack.append(256); // offset (requires expansion)

    const gas_before = frame.gas_remaining;

    // Execute LOG0
    _ = try evm.table.execute(0, interpreter, state, 0xA0);

    // Should consume gas for LOG0 plus memory expansion
    const gas_used = gas_before - frame.gas_remaining;
    try testing.expect(gas_used > 631); // More than just LOG0 + data cost
}

// Test stack underflow
test "LOG0: stack underflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
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

    // Push only one value (need two)
    try frame.stack.append(0);

    // Execute LOG0 - should fail
    const result = evm.table.execute(0, interpreter, state, 0xA0);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

test "LOG4: stack underflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
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

    // Push only 5 values (need 6 for LOG4)
    try frame.stack.append(0x1); // topic1
    try frame.stack.append(0x2); // topic2
    try frame.stack.append(0x3); // topic3
    try frame.stack.append(0x4); // topic4
    try frame.stack.append(0); // length
    // Missing offset

    // Execute LOG4 - should fail
    const result = evm.table.execute(0, interpreter, state, 0xA4);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

// Test out of gas
test "LOG0: out of gas" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        100,
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
        .withGas(100)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push length and offset for large data (stack is LIFO)
    try frame.stack.append(1000); // length (pushed first, popped second - would cost 8000 gas for data alone)
    try frame.stack.append(0); // offset (pushed last, popped first)

    // Execute LOG0 - should fail
    const result = evm.table.execute(0, interpreter, state, 0xA0);
    try testing.expectError(ExecutionError.Error.OutOfGas, result);
}
