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

test "Block: BLOCKHASH operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set up block context
    const tx_origin: Address.Address = [_]u8{0x11} ** 20;
    const block_coinbase: Address.Address = [_]u8{0x11} ** 20;
    const context = Evm.Context.init_with_values(
        tx_origin, // tx_origin
        0, // gas_price
        1000, // block_number
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

    // Test 1: Get blockhash for recent block (should return a hash)
    try frame.stack.append(999); // Block number (1 block ago)
    _ = try evm.table.execute(0, interpreter, state, 0x40);
    const hash_value = try frame.stack.pop();
    // Should return a non-zero hash for recent blocks
    try testing.expect(hash_value != 0);

    // Test 2: Block number too old (> 256 blocks ago)
    frame.stack.clear();
    try frame.stack.append(700); // More than 256 blocks ago
    _ = try evm.table.execute(0, interpreter, state, 0x40);
    const old_hash = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), old_hash);

    // Test 3: Future block number
    frame.stack.clear();
    try frame.stack.append(1001); // Future block
    _ = try evm.table.execute(0, interpreter, state, 0x40);
    const future_hash = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), future_hash);

    // Test gas consumption (3 BLOCKHASH operations * 20 gas each)
    try testing.expectEqual(@as(u64, 940), frame.gas_remaining);
}

test "Block: COINBASE operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set coinbase address
    const tx_origin: Address.Address = [_]u8{0x11} ** 20;
    const block_coinbase: Address.Address = [_]u8{0xCC} ** 20;
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

    // Test: Push coinbase address to stack
    _ = try evm.table.execute(0, interpreter, state, 0x41);
    const result = try frame.stack.pop();
    const coinbase_as_u256 = primitives.Address.to_u256(evm.access_list.context.block_coinbase);
    try testing.expectEqual(coinbase_as_u256, result);

    // Test gas consumption
    try testing.expectEqual(@as(u64, 998), frame.gas_remaining);
}

test "Block: TIMESTAMP operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set block timestamp
    const tx_origin: Address.Address = [_]u8{0x11} ** 20;
    const block_coinbase: Address.Address = [_]u8{0x11} ** 20;
    const context = Evm.Context.init_with_values(
        tx_origin, // tx_origin
        0, // gas_price
        0, // block_number
        1234567890, // block_timestamp
        block_coinbase, // block_coinbase
        0, // block_difficulty
        0, // block_gas_limit
        1, // chain_id
        0, // block_base_fee
        &[_]u256{}, // blob_hashes
        0, // blob_base_fee
    );
    evm.set_context(context);

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

    // Test: Push timestamp to stack
    _ = try evm.table.execute(0, interpreter, state, 0x42);
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1234567890), result);

    // Test gas consumption
    try testing.expectEqual(@as(u64, 998), frame.gas_remaining);
}

test "Block: NUMBER operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set block number
    const tx_origin: Address.Address = [_]u8{0x11} ** 20;
    const block_coinbase: Address.Address = [_]u8{0x11} ** 20;
    const context = Evm.Context.init_with_values(
        tx_origin, // tx_origin
        0, // gas_price
        987654321, // block_number
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

    // Test: Push block number to stack
    _ = try evm.table.execute(0, interpreter, state, 0x43);
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 987654321), result);

    // Test gas consumption
    try testing.expectEqual(@as(u64, 998), frame.gas_remaining);
}

test "Block: DIFFICULTY/PREVRANDAO operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set difficulty/prevrandao
    const tx_origin: Address.Address = [_]u8{0x11} ** 20;
    const block_coinbase: Address.Address = [_]u8{0x11} ** 20;
    const context = Evm.Context.init_with_values(
        tx_origin, // tx_origin
        0, // gas_price
        0, // block_number
        0, // block_timestamp
        block_coinbase, // block_coinbase
        0x123456789ABCDEF0, // block_difficulty
        0, // block_gas_limit
        1, // chain_id
        0, // block_base_fee
        &[_]u256{}, // blob_hashes
        0, // blob_base_fee
    );
    evm.set_context(context);

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

    // Test: Push difficulty to stack
    _ = try evm.table.execute(0, interpreter, state, 0x44);
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0x123456789ABCDEF0), result);

    // Test gas consumption
    try testing.expectEqual(@as(u64, 998), frame.gas_remaining);
}

test "Block: GASLIMIT operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set gas limit
    const tx_origin: Address.Address = [_]u8{0x11} ** 20;
    const block_coinbase: Address.Address = [_]u8{0x11} ** 20;
    const context = Evm.Context.init_with_values(
        tx_origin, // tx_origin
        0, // gas_price
        0, // block_number
        0, // block_timestamp
        block_coinbase, // block_coinbase
        0, // block_difficulty
        30_000_000, // block_gas_limit
        1, // chain_id
        0, // block_base_fee
        &[_]u256{}, // blob_hashes
        0, // blob_base_fee
    );
    evm.set_context(context);

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

    // Test: Push gas limit to stack
    _ = try evm.table.execute(0, interpreter, state, 0x45);
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 30_000_000), result);

    // Test gas consumption
    try testing.expectEqual(@as(u64, 998), frame.gas_remaining);
}

test "Block: BASEFEE operations (London)" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set base fee
    const tx_origin: Address.Address = [_]u8{0x11} ** 20;
    const block_coinbase: Address.Address = [_]u8{0x11} ** 20;
    const context = Evm.Context.init_with_values(
        tx_origin, // tx_origin
        0, // gas_price
        0, // block_number
        0, // block_timestamp
        block_coinbase, // block_coinbase
        0, // block_difficulty
        0, // block_gas_limit
        1, // chain_id
        1_000_000_000, // block_base_fee (1 gwei)
        &[_]u256{}, // blob_hashes
        0, // blob_base_fee
    );
    evm.set_context(context);

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

    // Test: Push base fee to stack
    _ = try evm.table.execute(0, interpreter, state, 0x48);
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1_000_000_000), result);

    // Test gas consumption
    try testing.expectEqual(@as(u64, 998), frame.gas_remaining);
}

test "Block: BLOBHASH operations (Cancun)" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set up blob hashes
    const blob_hashes = [_]u256{
        0x1111111111111111111111111111111111111111111111111111111111111111,
        0x2222222222222222222222222222222222222222222222222222222222222222,
        0x3333333333333333333333333333333333333333333333333333333333333333,
    };
    const tx_origin: Address.Address = [_]u8{0x11} ** 20;
    const block_coinbase: Address.Address = [_]u8{0x11} ** 20;
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
        &blob_hashes, // blob_hashes
        0, // blob_base_fee
    );
    evm.set_context(context);

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

    // Test 1: Get first blob hash
    try frame.stack.append(0);
    _ = try evm.table.execute(0, interpreter, state, 0x49);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0x1111111111111111111111111111111111111111111111111111111111111111), result1);

    // Test 2: Get second blob hash
    frame.stack.clear();
    try frame.stack.append(1);
    _ = try evm.table.execute(0, interpreter, state, 0x49);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0x2222222222222222222222222222222222222222222222222222222222222222), result2);

    // Test 3: Out of bounds index
    frame.stack.clear();
    try frame.stack.append(3);
    _ = try evm.table.execute(0, interpreter, state, 0x49);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result3); // Returns 0 for out of bounds

    // Test 4: Very large index
    frame.stack.clear();
    try frame.stack.append(std.math.maxInt(u256));
    _ = try evm.table.execute(0, interpreter, state, 0x49);
    const result4 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result4); // Returns 0 for out of bounds

    // Test gas consumption (4 BLOBHASH operations * 3 gas each)
    try testing.expectEqual(@as(u64, 988), frame.gas_remaining);
}

test "Block: BLOBBASEFEE operations (Cancun)" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    // Set blob base fee
    const tx_origin: Address.Address = [_]u8{0x11} ** 20;
    const block_coinbase: Address.Address = [_]u8{0x11} ** 20;
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
        100_000_000, // blob_base_fee (0.1 gwei)
    );
    evm.set_context(context);

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

    // Test: Push blob base fee to stack
    _ = try evm.table.execute(0, interpreter, state, 0x4A);
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 100_000_000), result);

    // Test gas consumption
    try testing.expectEqual(@as(u64, 998), frame.gas_remaining);
}

test "Block: Stack underflow errors" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    // Test BLOCKHASH with empty stack
    try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(0, interpreter, state, 0x40));

    // Test BLOBHASH with empty stack (Cancun)
    frame.stack.clear();
    try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(0, interpreter, state, 0x49));
}

test "Block: Edge cases" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    // Test with maximum values
    const tx_origin: Address.Address = [_]u8{0x11} ** 20;
    const block_coinbase: Address.Address = [_]u8{0x11} ** 20;
    const context = Evm.Context.init_with_values(
        tx_origin, // tx_origin
        0, // gas_price
        std.math.maxInt(u64), // block_number
        std.math.maxInt(u64), // block_timestamp
        block_coinbase, // block_coinbase
        std.math.maxInt(u256), // block_difficulty
        std.math.maxInt(u64), // block_gas_limit
        1, // chain_id
        std.math.maxInt(u256), // block_base_fee
        &[_]u256{}, // blob_hashes
        std.math.maxInt(u256), // blob_base_fee
    );
    evm.set_context(context);

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test all opcodes still work with max values
    _ = try evm.table.execute(0, interpreter, state, 0x43);
    const number_result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, std.math.maxInt(u64)), number_result);

    frame.stack.clear();
    _ = try evm.table.execute(0, interpreter, state, 0x42);
    const timestamp_result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, std.math.maxInt(u64)), timestamp_result);
}
