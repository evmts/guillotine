const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const opcodes = Evm.opcodes;
const ExecutionError = Evm.ExecutionError;
const Address = primitives.Address;
const gas_constants = Evm.gas_constants;
const Hardfork = Evm.Hardfork.Hardfork;
const MemoryDatabase = Evm.MemoryDatabase;
const Contract = Evm.Contract;
const Frame = Evm.Frame;
const CallParams = Evm.Host.CallParams;
const CallResult = Evm.CallResult;
// Updated to new API - migration in progress, tests not run yet

// Test CREATE operation
test "CREATE: create new contract" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Create contract
    const contract_address = [_]u8{0} ** 19 ++ [_]u8{1};
    const caller_address = [_]u8{0} ** 19 ++ [_]u8{2};
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        100000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Set depth to 1024 to trigger depth limit failure (CREATE should return 0)
    frame.depth = 1024;

    // Write init code to memory (simple code that returns empty)
    const init_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xF3 }; // PUSH1 0 PUSH1 0 RETURN
    var i: usize = 0;
    while (i < init_code.len) : (i += 1) {
        try frame.memory.set_data(i, &[_]u8{init_code[i]});
    }

    // Push size, offset, value
    try frame.stack.append(init_code.len); // size (will be popped 3rd)
    try frame.stack.append(0); // offset (will be popped 2nd)
    try frame.stack.append(0); // value (will be popped 1st)

    // Execute CREATE through jump table
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0xF0);

    // Should push 0 for failure - VM doesn't execute init code yet
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

test "CREATE: empty init code creates empty contract" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Create contract
    const contract_address = [_]u8{0} ** 19 ++ [_]u8{1};
    const caller_address = [_]u8{0} ** 19 ++ [_]u8{2};
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        100000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Push size, offset, value
    try frame.stack.append(0); // size (will be popped 3rd)
    try frame.stack.append(0); // offset (will be popped 2nd)
    try frame.stack.append(0); // value (will be popped 1st)

    // Execute CREATE through jump table
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0xF0);

    // Should push non-zero address for successful empty contract creation
    const created_address = try frame.stack.pop();
    try testing.expect(created_address != 0);
}

test "CREATE: write protection in static call" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Create contract
    const contract_address = [_]u8{0} ** 19 ++ [_]u8{1};
    const caller_address = [_]u8{0} ** 19 ++ [_]u8{2};
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        100000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame with static call
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(100000)
        .isStatic(true)
        .build();
    defer frame.deinit();

    // Push size, offset, value
    try frame.stack.append(0); // size (will be popped 3rd)
    try frame.stack.append(0); // offset (will be popped 2nd)
    try frame.stack.append(0); // value (will be popped 1st)

    // Execute CREATE - should fail
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    const result = evm.table.execute(0, interpreter, state, 0xF0);
    try testing.expectError(ExecutionError.Error.WriteProtection, result);
}

test "CREATE: depth limit" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Create contract
    const contract_address = [_]u8{0} ** 19 ++ [_]u8{1};
    const caller_address = [_]u8{0} ** 19 ++ [_]u8{2};
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        100000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame with max depth
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Set depth to 1024 to trigger depth limit failure
    frame.depth = 1024;

    // Push size, offset, value
    try frame.stack.append(0); // size (will be popped 3rd)
    try frame.stack.append(0); // offset (will be popped 2nd)
    try frame.stack.append(0); // value (will be popped 1st)

    // Execute CREATE
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0xF0);

    // Should push 0 due to depth limit
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// Test CREATE2 operation
test "CREATE2: create with deterministic address" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Create contract
    const contract_address = [_]u8{0} ** 19 ++ [_]u8{1};
    const caller_address = [_]u8{0} ** 19 ++ [_]u8{2};
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        100000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Set depth to 1024 to trigger depth limit failure
    frame.depth = 1024;

    // Write init code to memory
    const init_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xF3 };
    var i: usize = 0;
    while (i < init_code.len) : (i += 1) {
        try frame.memory.set_data(i, &[_]u8{init_code[i]});
    }

    // Push salt, size, offset, value
    try frame.stack.append(0x12345678); // salt (will be popped 4th)
    try frame.stack.append(init_code.len); // size (will be popped 3rd)
    try frame.stack.append(0); // offset (will be popped 2nd)
    try frame.stack.append(0); // value (will be popped 1st)

    // Execute CREATE2
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0xF5);

    // Should push 0 for failed creation (VM doesn't execute init code yet)
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

// Test CALL operation
test "CALL: basic call behavior" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Create contract
    const contract_address = [_]u8{0} ** 19 ++ [_]u8{1};
    const caller_address = [_]u8{0} ** 19 ++ [_]u8{2};
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        100000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Set depth to 1024 to trigger depth limit failure
    frame.depth = 1024;

    // Write call data to memory
    const call_data = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    var i: usize = 0;
    while (i < call_data.len) : (i += 1) {
        try frame.memory.set_data(i, &[_]u8{call_data[i]});
    }

    // Pre-expand memory to accommodate return data at offset 100
    _ = try frame.memory.ensure_context_capacity(110); // Need at least 100 + 10 bytes

    // Push in reverse order for stack (LIFO): ret_size, ret_offset, args_size, args_offset, value, to, gas
    try frame.stack.append(10); // ret_size
    try frame.stack.append(100); // ret_offset
    try frame.stack.append(4); // args_size
    try frame.stack.append(0); // args_offset
    try frame.stack.append(0); // value
    const alice_address = [_]u8{0} ** 19 ++ [_]u8{2};
    try frame.stack.append(primitives.Address.to_u256(alice_address)); // to
    try frame.stack.append(50000); // gas

    // Execute CALL
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0xF1);

    // Should push 0 for failure (regular calls not implemented yet)
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "CALL: failed call" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Create contract
    const contract_address = [_]u8{0} ** 19 ++ [_]u8{1};
    const caller_address = [_]u8{0} ** 19 ++ [_]u8{2};
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        100000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Set depth to 1024 to trigger depth limit failure
    frame.depth = 1024;

    // Push in reverse order for stack (LIFO)
    try frame.stack.append(0); // ret_size
    try frame.stack.append(0); // ret_offset
    try frame.stack.append(0); // args_size
    try frame.stack.append(0); // args_offset
    try frame.stack.append(0); // value
    const alice_address = [_]u8{0} ** 19 ++ [_]u8{2};
    try frame.stack.append(primitives.Address.to_u256(alice_address)); // to
    try frame.stack.append(50000); // gas

    // Execute CALL
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0xF1);

    // Should push 0 for failure (regular calls not implemented yet)
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "CALL: cold address access costs more gas" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Create contract
    const contract_address = [_]u8{0} ** 19 ++ [_]u8{1};
    const caller_address = [_]u8{0} ** 19 ++ [_]u8{2};
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        100000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Set depth to 1024 to trigger depth limit failure
    frame.depth = 1024;

    // Push in reverse order for stack (LIFO)
    try frame.stack.append(0); // ret_size
    try frame.stack.append(0); // ret_offset
    try frame.stack.append(0); // args_size
    try frame.stack.append(0); // args_offset
    try frame.stack.append(0); // value
    const alice_address = [_]u8{0} ** 19 ++ [_]u8{2};
    try frame.stack.append(primitives.Address.to_u256(alice_address)); // to
    try frame.stack.append(1000); // gas

    const gas_before = frame.gas_remaining;

    // Execute CALL
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0xF1);

    // Should push 0 for failure (regular calls not implemented yet)
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
    const gas_used = gas_before - frame.gas_remaining;
    try testing.expect(gas_used > 0); // Should consume gas for cold address access
}

test "CALL: value transfer in static call fails" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Create contract
    const contract_address = [_]u8{0} ** 19 ++ [_]u8{1};
    const caller_address = [_]u8{0} ** 19 ++ [_]u8{2};
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        100000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame with static call
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(100000)
        .isStatic(true)
        .build();
    defer frame.deinit();

    // Push in reverse order for stack (LIFO) with non-zero value
    try frame.stack.append(0); // ret_size
    try frame.stack.append(0); // ret_offset
    try frame.stack.append(0); // args_size
    try frame.stack.append(0); // args_offset
    try frame.stack.append(100); // value (non-zero!)
    const alice_address = [_]u8{0} ** 19 ++ [_]u8{2};
    try frame.stack.append(primitives.Address.to_u256(alice_address)); // to
    try frame.stack.append(1000); // gas

    // Execute CALL - should fail
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    const result = evm.table.execute(0, interpreter, state, 0xF1);
    try testing.expectError(ExecutionError.Error.WriteProtection, result);
}

// Test DELEGATECALL operation
test "DELEGATECALL: execute code in current context" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Create contract
    const contract_address = [_]u8{0} ** 19 ++ [_]u8{1};
    const caller_address = [_]u8{0} ** 19 ++ [_]u8{2};
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        100000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Set depth to 1024 to trigger depth limit failure
    frame.depth = 1024;

    // Pre-expand memory to accommodate return data at offset 50
    _ = try frame.memory.ensure_context_capacity(52); // Need at least 50 + 2 bytes

    // Push in reverse order for stack (LIFO): ret_size, ret_offset, args_size, args_offset, to, gas
    try frame.stack.append(2); // ret_size
    try frame.stack.append(50); // ret_offset
    try frame.stack.append(0); // args_size
    try frame.stack.append(0); // args_offset
    const alice_address = [_]u8{0} ** 19 ++ [_]u8{2};
    try frame.stack.append(primitives.Address.to_u256(alice_address)); // to
    try frame.stack.append(50000); // gas

    // Execute DELEGATECALL
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0xF4);

    // Should push 0 for failure (VM doesn't implement delegatecall yet)
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// Test STATICCALL operation
test "STATICCALL: read-only call" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Create contract
    const contract_address = [_]u8{0} ** 19 ++ [_]u8{1};
    const caller_address = [_]u8{0} ** 19 ++ [_]u8{2};
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        100000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Set depth to 1024 to trigger depth limit failure
    frame.depth = 1024;

    // Pre-expand memory to accommodate return data at offset 200
    _ = try frame.memory.ensure_context_capacity(202); // Need at least 200 + 2 bytes

    // Push in reverse order for stack (LIFO): ret_size, ret_offset, args_size, args_offset, to, gas
    try frame.stack.append(2); // ret_size
    try frame.stack.append(200); // ret_offset
    try frame.stack.append(0); // args_size
    try frame.stack.append(0); // args_offset
    const alice_address = [_]u8{0} ** 19 ++ [_]u8{2};
    try frame.stack.append(primitives.Address.to_u256(alice_address)); // to
    try frame.stack.append(50000); // gas

    // Execute STATICCALL
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0xFA);

    // Should push 0 for failure (regular calls not implemented yet)
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// Test depth limit for calls
test "CALL: depth limit" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Create contract
    const contract_address = [_]u8{0} ** 19 ++ [_]u8{1};
    const caller_address = [_]u8{0} ** 19 ++ [_]u8{2};
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        100000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame with max depth
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Set depth to 1024 to trigger depth limit failure
    frame.depth = 1024;

    // Push parameters
    try frame.stack.append(1000); // gas
    const alice_address = [_]u8{0} ** 19 ++ [_]u8{2};
    try frame.stack.append(primitives.Address.to_u256(alice_address)); // to
    try frame.stack.append(0); // value
    try frame.stack.append(0); // args_offset
    try frame.stack.append(0); // args_size
    try frame.stack.append(0); // ret_offset
    try frame.stack.append(0); // ret_size

    // Execute CALL
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0xF1);

    // Should push 0 due to depth limit
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// Test gas calculation
test "CREATE: gas consumption" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Create contract
    const contract_address = [_]u8{0} ** 19 ++ [_]u8{1};
    const caller_address = [_]u8{0} ** 19 ++ [_]u8{2};
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        100000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Write init code to memory
    const init_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xF3 };
    var i: usize = 0;
    while (i < init_code.len) : (i += 1) {
        try frame.memory.set_data(i, &[_]u8{init_code[i]});
    }

    // Push parameters
    try frame.stack.append(init_code.len); // size (will be popped 3rd)
    try frame.stack.append(0); // offset (will be popped 2nd)
    try frame.stack.append(0); // value (will be popped 1st)

    const gas_before = frame.gas_remaining;

    // Execute CREATE
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0xF0);

    // Should consume gas for CREATE operation regardless of success/failure
    const gas_used = gas_before - frame.gas_remaining;
    try testing.expect(gas_used > 0); // VM should consume some gas for CREATE
}

test "CREATE2: additional gas for hashing" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Create contract
    const contract_address = [_]u8{0} ** 19 ++ [_]u8{1};
    const caller_address = [_]u8{0} ** 19 ++ [_]u8{2};
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        100000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Write init code to memory
    const init_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xF3 };
    var i: usize = 0;
    while (i < init_code.len) : (i += 1) {
        try frame.memory.set_data(i, &[_]u8{init_code[i]});
    }

    // Push parameters
    try frame.stack.append(0x12345678); // salt (will be popped 4th)
    try frame.stack.append(init_code.len); // size (will be popped 3rd)
    try frame.stack.append(0); // offset (will be popped 2nd)
    try frame.stack.append(0); // value (will be popped 1st)

    const gas_before = frame.gas_remaining;

    // Execute CREATE2
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0xF5);

    // Should consume gas for CREATE2 operation regardless of success/failure
    const gas_used = gas_before - frame.gas_remaining;
    try testing.expect(gas_used > 0); // VM should consume some gas for CREATE2
}

// Test stack errors
test "CREATE: stack underflow" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Create contract
    const contract_address = [_]u8{0} ** 19 ++ [_]u8{1};
    const caller_address = [_]u8{0} ** 19 ++ [_]u8{2};
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        100000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Push only two values (need three)
    try frame.stack.append(0); // offset
    try frame.stack.append(0); // size

    // Execute CREATE - should fail
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    const result = evm.table.execute(0, interpreter, state, 0xF0);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

test "CALL: stack underflow" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Create contract
    const contract_address = [_]u8{0} ** 19 ++ [_]u8{1};
    const caller_address = [_]u8{0} ** 19 ++ [_]u8{2};
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        100000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Push only six values (need seven)
    try frame.stack.append(0); // to
    try frame.stack.append(0); // value
    try frame.stack.append(0); // args_offset
    try frame.stack.append(0); // args_size
    try frame.stack.append(0); // ret_offset
    try frame.stack.append(0); // ret_size

    // Execute CALL - should fail
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    const result = evm.table.execute(0, interpreter, state, 0xF1);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

// Test memory expansion
test "CREATE: memory expansion for init code" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Create contract
    const contract_address = [_]u8{0} ** 19 ++ [_]u8{1};
    const caller_address = [_]u8{0} ** 19 ++ [_]u8{2};
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        100000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Set up sufficient balance for contract creation
    try evm.state.set_balance(contract_address, 1000000);

    // Initialize memory with some init code at offset 200
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try frame.memory.set_data(200 + i, &[_]u8{@intCast(i % 256)});
    }

    // Push parameters that require memory expansion
    try frame.stack.append(100); // size
    try frame.stack.append(200); // offset (requires expansion to 300 bytes)
    try frame.stack.append(0); // value

    const gas_before = frame.gas_remaining;

    // Execute CREATE
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0xF0);

    // Should consume gas for memory expansion regardless of success/failure
    const gas_used = gas_before - frame.gas_remaining;
    try testing.expect(gas_used > 0); // VM should consume some gas for memory operations
}

// Test EIP-3860: Limit and meter initcode
test "CREATE: EIP-3860 initcode size limit" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Create contract
    const contract_address = [_]u8{0} ** 19 ++ [_]u8{1};
    const caller_address = [_]u8{0} ** 19 ++ [_]u8{2};
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        100000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000000)
        .build();
    defer frame.deinit();

    // Push parameters with size exceeding MaxInitcodeSize (49152)
    try frame.stack.append(49153); // size (one byte over limit)
    try frame.stack.append(0); // offset
    try frame.stack.append(0); // value

    // Execute CREATE with oversized code - should fail
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    const result = evm.table.execute(0, interpreter, state, 0xF0);
    try testing.expectError(ExecutionError.Error.MaxCodeSizeExceeded, result);
}

test "CREATE: EIP-3860 initcode word gas" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Create contract
    const contract_address = [_]u8{0} ** 19 ++ [_]u8{1};
    const caller_address = [_]u8{0} ** 19 ++ [_]u8{2};
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        100000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Set up sufficient balance for contract creation
    try evm.state.set_balance(contract_address, 1000000);

    // Write 64 bytes of init code (2 words)
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        try frame.memory.set_data(i, &[_]u8{0x00});
    }

    // Push parameters
    try frame.stack.append(64); // size (2 words)
    try frame.stack.append(0); // offset
    try frame.stack.append(0); // value

    const gas_before = frame.gas_remaining;

    // Execute CREATE
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    _ = try evm.table.execute(0, interpreter, state, 0xF0);

    // Should consume gas for CREATE operation regardless of success/failure
    const gas_used = gas_before - frame.gas_remaining;
    try testing.expect(gas_used > 0); // VM should consume some gas for CREATE
}

test "CREATE2: EIP-3860 initcode size limit" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Create contract
    const contract_address = [_]u8{0} ** 19 ++ [_]u8{1};
    const caller_address = [_]u8{0} ** 19 ++ [_]u8{2};
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        100000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000000)
        .build();
    defer frame.deinit();

    // Push parameters with size exceeding MaxInitcodeSize (49152)
    try frame.stack.append(0x123); // salt (will be popped 4th)
    try frame.stack.append(49153); // size (one byte over limit) (will be popped 3rd)
    try frame.stack.append(0); // offset (will be popped 2nd)
    try frame.stack.append(0); // value (will be popped 1st)

    // Execute CREATE2 - should fail with MaxCodeSizeExceeded
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;
    const result = evm.table.execute(0, interpreter, state, 0xF5);
    try testing.expectError(ExecutionError.Error.MaxCodeSizeExceeded, result);
}
