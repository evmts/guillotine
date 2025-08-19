const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const Contract = Evm.Contract;
const Frame = Evm.Frame;
const MemoryDatabase = Evm.MemoryDatabase;
const ExecutionError = Evm.ExecutionError;

// ============================
// 0x3B-0x3F Environmental Information (continued) + 0x40-0x44 Block Information
// ============================

test "EXTCODESIZE (0x3B): Get external code size" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Deploy a contract with code
    const test_code = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x60, 0x01, // PUSH1 1
        0x01, // ADD
        0x00, // STOP
    };

    // Set code directly in the state
    const bob_addr = [_]u8{0xBB} ** 20;
    try evm.state.set_code(bob_addr, &test_code);
    // Set balance directly in the state
    try evm.state.set_balance(bob_addr, 1000);

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        0,
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

    // Test 1: Get code size of contract with code
    try frame.stack.append(primitives.Address.to_u256(bob_addr));
    _ = try evm.table.execute(0, interpreter, state, 0x3B);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, test_code.len), result1);

    // Test 2: Get code size of EOA (should be 0)
    const alice_addr = [_]u8{0x11} ** 20;
    try frame.stack.append(primitives.Address.to_u256(alice_addr));
    _ = try evm.table.execute(0, interpreter, state, 0x3B);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result2);

    // Test 3: Get code size of non-existent account (should be 0)
    const zero_addr = [_]u8{0xFF} ** 20;
    try frame.stack.append(primitives.Address.to_u256(zero_addr));
    _ = try evm.table.execute(0, interpreter, state, 0x3B);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result3);
}

test "EXTCODECOPY (0x3C): Copy external code to memory" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const external_code = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x55, // SSTORE
        0x00, // STOP
    };

    // Set code directly in the state
    const bob_addr = [_]u8{0xBB} ** 20;
    try evm.state.set_code(bob_addr, &external_code);

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        0,
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

    // Test 1: Copy entire external code
    const bob_addr_u256 = primitives.Address.to_u256(bob_addr);
    try frame.stack.append(external_code.len); // size
    try frame.stack.append(0); // code_offset
    try frame.stack.append(0); // mem_offset
    try frame.stack.append(bob_addr_u256); // address
    _ = try evm.table.execute(0, interpreter, state, 0x3C);

    const mem_slice1 = try frame.memory.get_slice(0, external_code.len);
    try testing.expectEqualSlices(u8, &external_code, mem_slice1);

    // Test 2: Copy partial code with offset
    frame.memory.resize_context(0) catch unreachable;
    try frame.stack.append(2); // size=2
    try frame.stack.append(2); // code_offset=2
    try frame.stack.append(10); // mem_offset=10
    try frame.stack.append(bob_addr_u256); // address
    _ = try evm.table.execute(0, interpreter, state, 0x3C);

    const mem_slice2 = try frame.memory.get_slice(10, 2);
    try testing.expectEqualSlices(u8, external_code[2..4], mem_slice2);

    // Test 3: Copy from EOA (should get zeros)
    frame.memory.resize_context(0) catch unreachable;
    const alice_addr = [_]u8{0x11} ** 20;
    const alice_addr_u256 = primitives.Address.to_u256(alice_addr);
    try frame.stack.append(32); // size
    try frame.stack.append(0); // code_offset
    try frame.stack.append(0); // mem_offset
    try frame.stack.append(alice_addr_u256); // address
    _ = try evm.table.execute(0, interpreter, state, 0x3C);

    const mem_slice3 = try frame.memory.get_slice(0, 32);
    const zeros = [_]u8{0} ** 32;
    try testing.expectEqualSlices(u8, &zeros, mem_slice3);
}

test "RETURNDATASIZE (0x3D): Get return data size" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        0,
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

    // Test 1: No return data initially
    _ = try evm.table.execute(0, interpreter, state, 0x3D);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result1);

    // Test 2: Set return data and check size
    const return_data = [_]u8{ 0x42, 0x43, 0x44, 0x45 };
    try frame.return_data.set(&return_data);

    _ = try evm.table.execute(0, interpreter, state, 0x3D);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, return_data.len), result2);

    // Test 3: Large return data
    const large_data = [_]u8{0xFF} ** 1024;
    try frame.return_data.set(&large_data);

    _ = try evm.table.execute(0, interpreter, state, 0x3D);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1024), result3);
}

test "RETURNDATACOPY (0x3E): Copy return data to memory" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        0,
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

    const return_data = [_]u8{
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00,
    };
    try frame.return_data.set(&return_data);

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Copy all return data
    try frame.stack.append(return_data.len); // size
    try frame.stack.append(0); // data_offset
    try frame.stack.append(0); // mem_offset
    _ = try evm.table.execute(0, interpreter, state, 0x3E);

    const mem_slice1 = try frame.memory.get_slice(0, return_data.len);
    try testing.expectEqualSlices(u8, &return_data, mem_slice1);

    // Test 2: Copy partial data with offsets
    frame.memory.resize_context(0) catch unreachable;
    try frame.stack.append(4); // size=4
    try frame.stack.append(4); // data_offset=4
    try frame.stack.append(32); // mem_offset=32
    _ = try evm.table.execute(0, interpreter, state, 0x3E);

    const mem_slice2 = try frame.memory.get_slice(32, 4);
    try testing.expectEqualSlices(u8, return_data[4..8], mem_slice2);

    // Test 3: Out of bounds should revert
    try frame.stack.append(32); // size > return_data.len
    try frame.stack.append(0); // data_offset
    try frame.stack.append(0); // mem_offset
    const result = evm.table.execute(0, interpreter, state, 0x3E);
    try testing.expectError(ExecutionError.Error.ReturnDataOutOfBounds, result);
}

test "EXTCODEHASH (0x3F): Get external code hash" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set up contract with known code
    const test_code = [_]u8{ 0x60, 0x00, 0x60, 0x01, 0x01 }; // PUSH1 0, PUSH1 1, ADD
    const bob_addr = [_]u8{0xBB} ** 20;
    // Set code using tracked allocation
    try evm.state.set_code(bob_addr, &test_code);

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        0,
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

    // Test 1: Get hash of contract with code
    try frame.stack.append(primitives.Address.to_u256(bob_addr));
    _ = try evm.table.execute(0, interpreter, state, 0x3F);

    // Calculate expected hash
    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&test_code, &expected_hash, .{});
    var expected_u256: u256 = 0;
    for (expected_hash) |_| {
        expected_u256 = (expected_u256 << 8) | byte;
    }

    const result1 = try frame.stack.pop();
    try testing.expectEqual(expected_u256, result1);

    // Test 2: Get hash of EOA (should be 0)
    const alice_addr = [_]u8{0x11} ** 20;
    try frame.stack.append(primitives.Address.to_u256(alice_addr));
    _ = try evm.table.execute(0, interpreter, state, 0x3F);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result2);
}

test "BLOCKHASH (0x40): Get block hash" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set up block context
    const alice_addr = [_]u8{0x11} ** 20;
    const context = Evm.Context.init_with_values(
        alice_addr, // tx_origin
        0, // gas_price
        1000, // block_number
        0, // block_timestamp
        alice_addr, // block_coinbase
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
        0,
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

    // Test 1: Get recent block hash (should return pseudo-hash)
    try frame.stack.append(999);
    _ = try evm.table.execute(0, interpreter, state, 0x40);
    const result1 = try frame.stack.pop();
    // Should be a non-zero pseudo-hash
    try testing.expect(result1 != 0);

    // Test 2: Get older block hash (within 256 blocks)
    try frame.stack.append(995);
    _ = try evm.table.execute(0, interpreter, state, 0x40);
    const result2 = try frame.stack.pop();
    // Should be a non-zero pseudo-hash, different from result1
    try testing.expect(result2 != 0);
    try testing.expect(result1 != result2);

    // Test 3: Block too old (> 256 blocks ago)
    try frame.stack.append(700); // 300 blocks ago
    _ = try evm.table.execute(0, interpreter, state, 0x40);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result3);

    // Test 4: Future block
    try frame.stack.append(1001);
    _ = try evm.table.execute(0, interpreter, state, 0x40);
    const result4 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result4);

    // Test 5: Current block
    try frame.stack.append(1000);
    _ = try evm.table.execute(0, interpreter, state, 0x40);
    const result5 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result5);

    // Test 6: Genesis block
    try frame.stack.append(0);
    _ = try evm.table.execute(0, interpreter, state, 0x40);
    const result6 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result6);
}

test "COINBASE (0x41): Get block coinbase" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set coinbase address
    const coinbase_addr = [_]u8{ 0xC0, 0x1B, 0xBA, 0x5E } ++ [_]u8{0} ** 16;
    const alice_addr = [_]u8{0x11} ** 20;
    const context = Evm.Context.init_with_values(
        alice_addr, // tx_origin
        0, // gas_price
        0, // block_number
        0, // block_timestamp
        coinbase_addr, // block_coinbase
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
        0,
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

    // Execute COINBASE
    _ = try evm.table.execute(0, interpreter, state, 0x41);

    const expected = primitives.Address.to_u256(coinbase_addr);
    const result = try frame.stack.pop();
    try testing.expectEqual(expected, result);
}

test "TIMESTAMP (0x42): Get block timestamp" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const test_cases = [_]u64{
        0, // Genesis
        1640995200, // 2022-01-01 00:00:00 UTC
        1704067200, // 2024-01-01 00:00:00 UTC
        std.math.maxInt(u64), // Far future
    };

    for (test_cases) |timestamp| {
        const alice_addr = [_]u8{0x11} ** 20;
        const context = Evm.Context.init_with_values(
            alice_addr, // tx_origin
            0, // gas_price
            0, // block_number
            timestamp, // block_timestamp
            alice_addr, // block_coinbase
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
            0,
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

        // Execute TIMESTAMP
        _ = try evm.table.execute(0, interpreter, state, 0x42);

        const result = try frame.stack.pop();
        try testing.expectEqual(@as(u256, timestamp), result);
    }
}

test "NUMBER (0x43): Get block number" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const test_cases = [_]u64{
        0, // Genesis
        1, // First block
        1000000, // Millionth block
        15537393, // Merge block on mainnet
        std.math.maxInt(u64), // Max block number
    };

    for (test_cases) |block_num| {
        const alice_addr = [_]u8{0x11} ** 20;
        const context = Evm.Context.init_with_values(
            alice_addr, // tx_origin
            0, // gas_price
            block_num, // block_number
            0, // block_timestamp
            alice_addr, // block_coinbase
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
            0,
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

        // Execute NUMBER
        _ = try evm.table.execute(0, interpreter, state, 0x43);

        const result = try frame.stack.pop();
        try testing.expectEqual(@as(u256, block_num), result);
    }
}

test "PREVRANDAO (0x44): Get previous RANDAO" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Post-merge, DIFFICULTY opcode returns PREVRANDAO
    const test_values = [_]u256{
        0,
        0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef,
        std.math.maxInt(u256),
    };

    for (test_values) |randao| {
        const alice_addr = [_]u8{0x11} ** 20;
        const context = Evm.Context.init_with_values(
            alice_addr, // tx_origin
            0, // gas_price
            0, // block_number
            0, // block_timestamp
            alice_addr, // block_coinbase
            randao, // block_difficulty (Post-merge, this is PREVRANDAO)
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
            0,
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

        // Execute PREVRANDAO
        _ = try evm.table.execute(0, interpreter, state, 0x44);

        const result = try frame.stack.pop();
        try testing.expectEqual(randao, result);
    }
}

// ============================
// Gas consumption tests
// ============================

test "EXTCODE* opcodes: Gas consumption with EIP-2929" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set up external code
    const code = [_]u8{ 0x60, 0x42 };
    const bob_addr = [_]u8{0xBB} ** 20;
    // Set code using tracked allocation
    try evm.state.set_code(bob_addr, &code);

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        0,
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

    // Test EXTCODESIZE - cold access
    try frame.stack.append(primitives.Address.to_u256(bob_addr));
    const gas_before_cold = frame.gas_remaining;
    _ = try evm.table.execute(0, interpreter, state, 0x3B);
    const gas_cold = gas_before_cold - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 2600), gas_cold); // Cold access
    _ = try frame.stack.pop();

    // Test EXTCODESIZE - warm access
    try frame.stack.append(primitives.Address.to_u256(bob_addr));
    const gas_before_warm = frame.gas_remaining;
    _ = try evm.table.execute(0, interpreter, state, 0x3B);
    const gas_warm = gas_before_warm - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 100), gas_warm); // Warm access
}

test "Block opcodes: Gas consumption" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        0,
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

    const simple_opcodes = [_]struct {
        opcode: u8,
        name: []const u8,
        expected_gas: u64,
        needs_stack: bool,
    }{
        .{ .opcode = 0x40, .name = "BLOCKHASH", .expected_gas = 20, .needs_stack = true },
        .{ .opcode = 0x41, .name = "COINBASE", .expected_gas = 2, .needs_stack = false },
        .{ .opcode = 0x42, .name = "TIMESTAMP", .expected_gas = 2, .needs_stack = false },
        .{ .opcode = 0x43, .name = "NUMBER", .expected_gas = 2, .needs_stack = false },
        .{ .opcode = 0x44, .name = "PREVRANDAO", .expected_gas = 2, .needs_stack = false },
    };

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    for (simple_opcodes) |op| {
        frame.stack.clear();
        if (op.needs_stack) {
            try frame.stack.append(999); // Block number for BLOCKHASH
        }

        const gas_before = 1000;
        frame.gas_remaining = gas_before;

        _ = try evm.table.execute(0, interpreter, state, op.opcode);

        const gas_used = gas_before - frame.gas_remaining;
        try testing.expectEqual(op.expected_gas, gas_used);

        // Pop result if needed
        if (frame.stack.size > 0) {
            _ = try frame.stack.pop();
        }
    }
}

// ============================
// Edge cases and error conditions
// ============================

test "RETURNDATACOPY: Out of bounds access" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        0,
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

    const return_data = [_]u8{ 0x42, 0x43, 0x44, 0x45 };
    try frame.return_data.set(&return_data);

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test cases that should fail
    const test_cases = [_]struct {
        size: u256,
        data_offset: u256,
        mem_offset: u256,
        desc: []const u8,
    }{
        .{ .size = 5, .data_offset = 0, .mem_offset = 0, .desc = "size > data length" },
        .{ .size = 2, .data_offset = 3, .mem_offset = 0, .desc = "offset + size > data length" },
        .{ .size = 1, .data_offset = 5, .mem_offset = 0, .desc = "offset beyond data" },
    };

    for (test_cases) |tc| {
        frame.stack.clear();
        try frame.stack.append(tc.size);
        try frame.stack.append(tc.data_offset);
        try frame.stack.append(tc.mem_offset);

        const result = evm.table.execute(0, interpreter, state, 0x3E);
        try testing.expectError(ExecutionError.Error.ReturnDataOutOfBounds, result);
    }
}

test "Memory copy opcodes: Memory expansion" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set up external code
    const code = [_]u8{0xFF} ** 32;
    const bob_addr = [_]u8{0xBB} ** 20;
    // Set code using tracked allocation
    try evm.state.set_code(bob_addr, &code);

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        0,
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
    defer frame.deinit(); // Limited gas

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test EXTCODECOPY with huge memory offset - should run out of gas
    const huge_offset = 1_000_000;
    const bob_addr_u256 = primitives.Address.to_u256(bob_addr);
    try frame.stack.append(32); // size
    try frame.stack.append(0); // code_offset
    try frame.stack.append(huge_offset); // mem_offset
    try frame.stack.append(bob_addr_u256); // address

    const result = evm.table.execute(0, interpreter, state, 0x3C);
    try testing.expectError(ExecutionError.Error.OutOfGas, result);
}

test "BLOCKHASH: Edge cases" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const alice_addr = [_]u8{0x11} ** 20;
    const context = Evm.Context.init_with_values(
        alice_addr, // tx_origin
        0, // gas_price
        1000, // block_number
        0, // block_timestamp
        alice_addr, // block_coinbase
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
        0,
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

    // Test with maximum u256 block number
    try frame.stack.append(std.math.maxInt(u256));
    _ = try evm.table.execute(0, interpreter, state, 0x40);
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result); // Should return 0 for invalid block
}
