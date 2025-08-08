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

test "Environment: ADDRESS opcode" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
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

    // Execute ADDRESS opcode
    _ = try evm.table.execute(0, interpreter, state, 0x30);

    // Should push contract address to stack
    const result = try frame.stack.peek_n(0);
    const expected = primitives.Address.to_u256(contract_addr);
    try testing.expectEqual(expected, result);

    // Check gas consumption (ADDRESS costs 2 gas)
    try testing.expectEqual(@as(u64, 998), frame.gas_remaining);
}

test "Environment: BALANCE opcode" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set up accounts with balances
    const alice_addr = [_]u8{0x11} ** 20;
    const test_balance: u256 = 1000000;
    try evm.state.set_balance(alice_addr, test_balance);

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
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

    // Test 1: Get balance of existing account
    const alice_u256 = primitives.Address.to_u256(alice_addr);
    try frame.stack.append(alice_u256);
    _ = try evm.table.execute(0, interpreter, state, 0x31);

    const result1 = try frame.stack.peek_n(0);
    try testing.expectEqual(test_balance, result1);

    // Test 2: Get balance of non-existent account (should return 0)
    frame.stack.clear();
    const random_addr = [_]u8{0xFF} ** 20;
    const random_u256 = primitives.Address.to_u256(random_addr);
    try frame.stack.append(random_u256);
    _ = try evm.table.execute(0, interpreter, state, 0x31);

    const result2 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0), result2);
}

test "Environment: ORIGIN and CALLER opcodes" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set transaction origin
    const tx_origin = [_]u8{0x11} ** 20;
    const block_coinbase = [_]u8{0x11} ** 20;
    const context = Evm.Context.init_with_values(
        tx_origin, // tx_origin
        0, // gas_price
        0, // block_number
        0, // block_timestamp
        block_coinbase, // block_coinbase
        0, // block_difficulty
        0, // block_gas_limit
        1, // chain_id
        0, // block_base_fee
        &[_]u256{}, // blob_hashes
        0, // blob_base_fee
    );
    evm.set_context(context);

    const caller_addr = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller_addr,
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

    // Test ORIGIN
    _ = try evm.table.execute(0, interpreter, state, 0x32);
    const origin_result = try frame.stack.peek_n(0);
    const expected_origin = primitives.Address.to_u256(tx_origin);
    try testing.expectEqual(expected_origin, origin_result);

    // Test CALLER
    frame.stack.clear();
    _ = try evm.table.execute(0, interpreter, state, 0x33);
    const caller_result = try frame.stack.peek_n(0);
    const expected_caller = primitives.Address.to_u256(caller_addr);
    try testing.expectEqual(expected_caller, caller_result);
}

test "Environment: CALLVALUE opcode" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const call_value: u256 = 500000;
    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        call_value,
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

    // Execute CALLVALUE
    _ = try evm.table.execute(0, interpreter, state, 0x34);

    const result = try frame.stack.peek_n(0);
    try testing.expectEqual(call_value, result);
}

test "Environment: GASPRICE opcode" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set gas price
    const gas_price: u256 = 20_000_000_000; // 20 gwei
    const tx_origin = [_]u8{0x11} ** 20;
    const block_coinbase = [_]u8{0x11} ** 20;
    const context = Evm.Context.init_with_values(
        tx_origin, // tx_origin
        gas_price, // gas_price
        0, // block_number
        0, // block_timestamp
        block_coinbase, // block_coinbase
        0, // block_difficulty
        0, // block_gas_limit
        1, // chain_id
        0, // block_base_fee
        &[_]u256{}, // blob_hashes
        0, // blob_base_fee
    );
    evm.set_context(context);

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
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

    // Execute GASPRICE
    _ = try evm.table.execute(0, interpreter, state, 0x3A);

    const result = try frame.stack.peek_n(0);
    try testing.expectEqual(gas_price, result);
}

test "Environment: EXTCODESIZE opcode" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set up account with code
    const bob_addr = [_]u8{0xBB} ** 20;
    const test_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x00 }; // PUSH1 0 PUSH1 0 STOP
    try evm.state.set_balance(bob_addr, 0);
    try evm.state.set_code(bob_addr, &test_code);

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
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

    // Test 1: Get code size of account with code
    const bob_u256 = primitives.Address.to_u256(bob_addr);
    try frame.stack.append(bob_u256);
    _ = try evm.table.execute(0, interpreter, state, 0x3B);

    const result1 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, test_code.len), result1);

    // Test 2: Get code size of account without code
    frame.stack.clear();
    const alice_addr = [_]u8{0x11} ** 20;
    const alice_u256 = primitives.Address.to_u256(alice_addr);
    try frame.stack.append(alice_u256);
    _ = try evm.table.execute(0, interpreter, state, 0x3B);

    const result2 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0), result2);
}

test "Environment: EXTCODECOPY opcode" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set up account with code
    const bob_addr = [_]u8{0xBB} ** 20;
    const test_code = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x01, // ADD
        0x60, 0x03, // PUSH1 3
        0x02, // MUL
        0x00, // STOP
    };
    try evm.state.set_balance(bob_addr, 0);
    try evm.state.set_code(bob_addr, &test_code);

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
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

    // Test 1: Copy entire code
    const bob_u256 = primitives.Address.to_u256(bob_addr);
    try frame.stack.append(test_code.len); // size (will be popped 4th)
    try frame.stack.append(0); // code offset (will be popped 3rd)
    try frame.stack.append(0); // memory offset (will be popped 2nd)
    try frame.stack.append(bob_u256); // address (will be popped 1st)

    _ = try evm.table.execute(0, interpreter, state, 0x3C);

    // Verify code was copied to memory
    var i: usize = 0;
    while (i < test_code.len) : (i += 1) {
        const mem_byte = try frame.memory.get_byte(i);
        try testing.expectEqual(test_code[i], mem_byte);
    }

    // Test 2: Copy partial code with offset
    frame.stack.clear();
    try frame.stack.append(4); // size (copy 4 bytes) (will be popped 4th)
    try frame.stack.append(2); // code offset (skip first 2 bytes) (will be popped 3rd)
    try frame.stack.append(32); // memory offset (will be popped 2nd)
    try frame.stack.append(bob_u256); // address (will be popped 1st)

    _ = try evm.table.execute(0, interpreter, state, 0x3C);

    // Verify partial copy
    i = 0;
    while (i < 4) : (i += 1) {
        const mem_byte = try frame.memory.get_byte(32 + i);
        try testing.expectEqual(test_code[2 + i], mem_byte);
    }

    // Test 3: Copy beyond code length (should pad with zeros)
    frame.stack.clear();
    try frame.stack.append(16); // size (longer than code) (will be popped 4th)
    try frame.stack.append(0); // code offset (will be popped 3rd)
    try frame.stack.append(64); // memory offset (will be popped 2nd)
    try frame.stack.append(bob_u256); // address (will be popped 1st)

    _ = try evm.table.execute(0, interpreter, state, 0x3C);

    // Verify padding with zeros
    i = test_code.len;
    while (i < 16) : (i += 1) {
        const mem_byte = try frame.memory.get_byte(64 + i);
        try testing.expectEqual(@as(u8, 0), mem_byte);
    }
}

test "Environment: EXTCODEHASH opcode" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set up account with code
    const bob_addr = [_]u8{0xBB} ** 20;
    const test_code = [_]u8{ 0x60, 0x00, 0x00 }; // PUSH1 0 STOP
    try evm.state.set_balance(bob_addr, 0);
    try evm.state.set_code(bob_addr, &test_code);

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
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

    // Test 1: Get hash of account with code
    const bob_u256 = primitives.Address.to_u256(bob_addr);
    try frame.stack.append(bob_u256);
    _ = try evm.table.execute(0, interpreter, state, 0x3F);

    const hash = try frame.stack.peek_n(0);
    try testing.expect(hash != 0); // Should be non-zero hash

    // Test 2: Get hash of empty account (should return 0)
    frame.stack.clear();
    const alice_addr = [_]u8{0x11} ** 20;
    const alice_u256 = primitives.Address.to_u256(alice_addr);
    try frame.stack.append(alice_u256);
    _ = try evm.table.execute(0, interpreter, state, 0x3F);

    const result2 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0), result2);
}

test "Environment: SELFBALANCE opcode (Istanbul)" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set balance for contract
    const contract_addr = [_]u8{0x11} ** 20;
    const contract_balance: u256 = 2_000_000;
    try evm.state.set_balance(contract_addr, contract_balance);

    const caller = [_]u8{0x11} ** 20;
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

    // Execute SELFBALANCE
    _ = try evm.table.execute(0, interpreter, state, 0x47);

    const result = try frame.stack.peek_n(0);
    try testing.expectEqual(contract_balance, result);

    // Check gas consumption (SELFBALANCE costs 5 gas)
    try testing.expectEqual(@as(u64, 995), frame.gas_remaining);
}

test "Environment: CHAINID opcode (Istanbul)" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set chain ID
    const chain_id: u256 = 1; // Mainnet
    const tx_origin = [_]u8{0x11} ** 20;
    const block_coinbase = [_]u8{0x11} ** 20;
    const context = Evm.Context.init_with_values(
        tx_origin, // tx_origin
        0, // gas_price
        0, // block_number
        0, // block_timestamp
        block_coinbase, // block_coinbase
        0, // block_difficulty
        0, // block_gas_limit
        chain_id, // chain_id
        0, // block_base_fee
        &[_]u256{}, // blob_hashes
        0, // blob_base_fee
    );
    evm.set_context(context);

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
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

    // Execute CHAINID
    _ = try evm.table.execute(0, interpreter, state, 0x46);

    const result = try frame.stack.peek_n(0);
    try testing.expectEqual(chain_id, result);
}

test "Environment: Cold/Warm address access (EIP-2929)" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set up account
    const bob_addr = [_]u8{0x11} ** 20;
    try evm.state.set_balance(bob_addr, 1000);

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
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

    // First access should be cold (2600 gas)
    const bob_u256 = primitives.Address.to_u256(bob_addr);
    try frame.stack.append(bob_u256);
    const initial_gas = frame.gas_remaining;
    _ = try evm.table.execute(0, interpreter, state, 0x31);
    const cold_gas_used = initial_gas - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 2600), cold_gas_used);

    // Second access should be warm (100 gas)
    frame.stack.clear();
    try frame.stack.append(bob_u256);
    const warm_initial_gas = frame.gas_remaining;
    _ = try evm.table.execute(0, interpreter, state, 0x31);
    const warm_gas_used = warm_initial_gas - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 100), warm_gas_used); // Warm access costs 100 gas
}

test "Environment: Stack underflow errors" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
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

    // Test opcodes that require stack items
    try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(0, interpreter, state, 0x31));

    try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(0, interpreter, state, 0x3B));

    try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(0, interpreter, state, 0x3F));

    // EXTCODECOPY needs 4 stack items
    try frame.stack.append(1);
    try frame.stack.append(2);
    try frame.stack.append(3);
    // Only 3 items
    try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(0, interpreter, state, 0x3C));
}
