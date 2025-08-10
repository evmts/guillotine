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

// ============================
// 0x45-0x4A Block Information (continued)
// ============================

test "GASLIMIT (0x45): Get block gas limit" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const test_cases = [_]u64{
        0, // Zero (unusual but valid)
        8_000_000, // Classic 8M gas limit
        12_500_000, // ~12.5M (common mainnet value)
        30_000_000, // 30M gas limit
        std.math.maxInt(u64), // Maximum possible
    };

    for (test_cases) |gas_limit| {
        // Create context with test values
        const context = Evm.Context.init_with_values([_]u8{0x11} ** 20, // origin
            0, // gas_price
            0, // block_number
            0, // timestamp
            [_]u8{0x11} ** 20, // coinbase
            0, // prev_randao
            gas_limit, // gas_limit
            1, // chain_id
            0, // base_fee
            &[_]u256{}, // blob_hashes
            0 // blob_base_fee
        );
        evm.set_context(context);

        const caller = [_]u8{0x11} ** 20;
        const contract_addr = [_]u8{0x11} ** 20;
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

        // Execute GASLIMIT
        _ = try evm.table.execute(0, interpreter, state, 0x45);

        const result = try frame.stack.pop();
        try testing.expectEqual(@as(u256, gas_limit), result);
    }
}

test "CHAINID (0x46): Get chain ID" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const test_cases = [_]u256{
        1, // Ethereum mainnet
        5, // Goerli testnet
        10, // Optimism mainnet
        137, // Polygon mainnet
        42161, // Arbitrum One
        43114, // Avalanche C-Chain
        56, // BSC mainnet
        std.math.maxInt(u256), // Maximum chain ID
    };

    for (test_cases) |chain_id| {
        // Create context with test values
        const context = Evm.Context.init_with_values([_]u8{0x11} ** 20, // origin
            0, // gas_price
            0, // block_number
            0, // timestamp
            [_]u8{0x11} ** 20, // coinbase
            0, // prev_randao
            0, // gas_limit
            chain_id, // chain_id
            0, // base_fee
            &[_]u256{}, // blob_hashes
            0 // blob_base_fee
        );
        evm.set_context(context);

        const caller = [_]u8{0x11} ** 20;
        const contract_addr = [_]u8{0x11} ** 20;
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

        const result = try frame.stack.pop();
        try testing.expectEqual(chain_id, result);
    }
}

test "SELFBALANCE (0x47): Get contract's own balance" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const test_cases = [_]u256{
        0, // No balance
        1, // 1 wei
        1_000_000_000_000_000_000, // 1 ETH
        42_000_000_000_000_000_000, // 42 ETH
        std.math.maxInt(u256), // Max balance
    };

    for (test_cases) |balance| {
        const caller = [_]u8{0x11} ** 20;
        const contract_addr = [_]u8{0x11} ** 20;
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

        // Set the contract's balance directly in the state
        try evm.state.set_balance(contract.address, balance);

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

        const result = try frame.stack.pop();
        try testing.expectEqual(balance, result);
    }
}

test "BASEFEE (0x48): Get block base fee" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const test_cases = [_]u256{
        0, // Zero base fee (unlikely but valid)
        1_000_000_000, // 1 Gwei
        20_000_000_000, // 20 Gwei (typical)
        100_000_000_000, // 100 Gwei (high congestion)
        500_000_000_000, // 500 Gwei (extreme congestion)
        std.math.maxInt(u256), // Maximum possible
    };

    for (test_cases) |base_fee| {
        // Create context with test values
        const context = Evm.Context.init_with_values([_]u8{0x11} ** 20, // origin
            0, // gas_price
            0, // block_number
            0, // timestamp
            [_]u8{0x11} ** 20, // coinbase
            0, // prev_randao
            0, // gas_limit
            1, // chain_id
            base_fee, // base_fee
            &[_]u256{}, // blob_hashes
            0 // blob_base_fee
        );
        evm.set_context(context);

        const caller = [_]u8{0x11} ** 20;
        const contract_addr = [_]u8{0x11} ** 20;
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

        // Execute BASEFEE
        _ = try evm.table.execute(0, interpreter, state, 0x48);

        const result = try frame.stack.pop();
        try testing.expectEqual(base_fee, result);
    }
}

test "BLOBHASH (0x49): Get blob versioned hash" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    // Set up blob hashes
    const blob_hashes = [_]u256{
        0x0101010101010101010101010101010101010101010101010101010101010101,
        0x0202020202020202020202020202020202020202020202020202020202020202,
        0x0303030303030303030303030303030303030303030303030303030303030303,
    };
    // Create context with test values
    const context = Evm.Context.init_with_values([_]u8{0x11} ** 20, // origin
        0, // gas_price
        0, // block_number
        0, // timestamp
        [_]u8{0x11} ** 20, // coinbase
        0, // prev_randao
        0, // gas_limit
        1, // chain_id
        0, // base_fee
        &blob_hashes, // blob_hashes
        0 // blob_base_fee
    );
    evm.set_context(context);

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
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

    // Test 1: Get first blob hash
    try frame.stack.append(0);
    _ = try evm.table.execute(0, interpreter, state, 0x49);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(blob_hashes[0], result1);

    // Test 2: Get second blob hash
    try frame.stack.append(1);
    _ = try evm.table.execute(0, interpreter, state, 0x49);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(blob_hashes[1], result2);

    // Test 3: Get third blob hash
    try frame.stack.append(2);
    _ = try evm.table.execute(0, interpreter, state, 0x49);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(blob_hashes[2], result3);

    // Test 4: Index out of bounds (should return 0)
    try frame.stack.append(3);
    _ = try evm.table.execute(0, interpreter, state, 0x49);
    const result4 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result4);

    // Test 5: Large index (should return 0)
    try frame.stack.append(1000);
    _ = try evm.table.execute(0, interpreter, state, 0x49);
    const result5 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result5);
}

test "BLOBBASEFEE (0x4A): Get blob base fee" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const test_cases = [_]u256{
        0, // Zero blob base fee
        1, // Minimum blob base fee
        1_000_000_000, // 1 Gwei
        10_000_000_000, // 10 Gwei
        100_000_000_000, // 100 Gwei
        std.math.maxInt(u256), // Maximum possible
    };

    for (test_cases) |blob_base_fee| {
        // Create context with test values
        const context = Evm.Context.init_with_values([_]u8{0x11} ** 20, // origin
            0, // gas_price
            0, // block_number
            0, // timestamp
            [_]u8{0x11} ** 20, // coinbase
            0, // prev_randao
            0, // gas_limit
            1, // chain_id
            0, // base_fee
            &[_]u256{}, // blob_hashes
            blob_base_fee // blob_base_fee
        );
        evm.set_context(context);

        const caller = [_]u8{0x11} ** 20;
        const contract_addr = [_]u8{0x11} ** 20;
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

        // Execute BLOBBASEFEE
        _ = try evm.table.execute(0, interpreter, state, 0x4A);

        const result = try frame.stack.pop();
        try testing.expectEqual(blob_base_fee, result);
    }
}

// ============================
// Gas consumption tests
// ============================

test "Block info opcodes: Gas consumption" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    // Set up blob hashes for BLOBHASH test
    const blob_hashes = [_]u256{0x01};
    // Create context with test values
    const context = Evm.Context.init_with_values([_]u8{0x11} ** 20, // origin
        0, // gas_price
        0, // block_number
        0, // timestamp
        [_]u8{0x11} ** 20, // coinbase
        0, // prev_randao
        0, // gas_limit
        1, // chain_id
        0, // base_fee
        &blob_hashes, // blob_hashes
        0 // blob_base_fee
    );
    evm.set_context(context);

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
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

    const opcodes = [_]struct {
        opcode: u8,
        name: []const u8,
        expected_gas: u64,
        needs_stack: bool,
    }{
        .{ .opcode = 0x45, .name = "GASLIMIT", .expected_gas = 2, .needs_stack = false },
        .{ .opcode = 0x46, .name = "CHAINID", .expected_gas = 2, .needs_stack = false },
        .{ .opcode = 0x47, .name = "SELFBALANCE", .expected_gas = 5, .needs_stack = false },
        .{ .opcode = 0x48, .name = "BASEFEE", .expected_gas = 2, .needs_stack = false },
        .{ .opcode = 0x49, .name = "BLOBHASH", .expected_gas = 3, .needs_stack = true },
        .{ .opcode = 0x4A, .name = "BLOBBASEFEE", .expected_gas = 2, .needs_stack = false },
    };

    for (opcodes) |op| {
        frame.stack.clear();
        if (op.needs_stack) {
            try frame.stack.append(0); // Index for BLOBHASH
        }

        const gas_before = 1000;
        frame.gas_remaining = gas_before;

        _ = try evm.table.execute(0, interpreter, state, op.opcode);

        const gas_used = gas_before - frame.gas_remaining;
        try testing.expectEqual(op.expected_gas, gas_used);
    }
}

// ============================
// Invalid opcodes 0x4B-0x4E
// ============================

test "Invalid opcodes 0x4B-0x4E: Should revert" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
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

    const invalid_opcodes = [_]u8{ 0x4B, 0x4C, 0x4D, 0x4E };

    for (invalid_opcodes) |opcode| {
        const gas_before = frame.gas_remaining;
        const result = evm.table.execute(0, interpreter, state, opcode);

        // Should fail with InvalidOpcode error
        try testing.expectError(ExecutionError.Error.InvalidOpcode, result);

        // Should consume all gas
        try testing.expectEqual(@as(u64, 0), frame.gas_remaining);

        // Reset for next test
        frame.gas_remaining = gas_before;
    }
}

// ============================
// Edge cases and special scenarios
// ============================

test "SELFBALANCE: Balance changes during execution" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
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

    // Initial balance: 1000 wei - set directly in the state
    try evm.state.set_balance(contract.address, 1000);

    // Check initial balance
    _ = try evm.table.execute(0, interpreter, state, 0x47);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1000), result1);

    // Simulate balance change (e.g., from a transfer) - set directly in the state
    try evm.state.set_balance(contract.address, 2500);

    // Check updated balance
    _ = try evm.table.execute(0, interpreter, state, 0x47);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 2500), result2);
}

test "BLOBHASH: Empty blob list" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    // No blob hashes set (empty slice)
    // Create context with test values
    const context = Evm.Context.init_with_values([_]u8{0x11} ** 20, // origin
        0, // gas_price
        0, // block_number
        0, // timestamp
        [_]u8{0x11} ** 20, // coinbase
        0, // prev_randao
        0, // gas_limit
        1, // chain_id
        0, // base_fee
        &[_]u256{}, // blob_hashes (empty)
        0 // blob_base_fee
    );
    evm.set_context(context);

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
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

    // Any index should return 0 when no blobs
    try frame.stack.append(0);
    _ = try evm.table.execute(0, interpreter, state, 0x49);
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

test "CHAINID: EIP-1344 behavior" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    // Test that CHAINID returns consistent value
    // Create context with test values
    const context = Evm.Context.init_with_values([_]u8{0x11} ** 20, // origin
        0, // gas_price
        0, // block_number
        0, // timestamp
        [_]u8{0x11} ** 20, // coinbase
        0, // prev_randao
        0, // gas_limit
        1337, // chain_id
        0, // base_fee
        &[_]u256{}, // blob_hashes
        0 // blob_base_fee
    );
    evm.set_context(context);

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
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

    // Execute CHAINID multiple times - should always return same value
    for (0..3) |_| {
        _ = try evm.table.execute(0, interpreter, state, 0x46);
        const result = try frame.stack.pop();
        try testing.expectEqual(@as(u256, 1337), result);
    }
}

test "Stack operations: All opcodes push exactly one value" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    // Set up blob hash for BLOBHASH
    const blob_hashes = [_]u256{0x01};
    // Create context with test values
    const context = Evm.Context.init_with_values([_]u8{0x11} ** 20, // origin
        0, // gas_price
        0, // block_number
        0, // timestamp
        [_]u8{0x11} ** 20, // coinbase
        0, // prev_randao
        0, // gas_limit
        1, // chain_id
        0, // base_fee
        &blob_hashes, // blob_hashes
        0 // blob_base_fee
    );
    evm.set_context(context);

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
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

    const opcodes = [_]struct {
        opcode: u8,
        needs_input: bool,
    }{
        .{ .opcode = 0x45, .needs_input = false }, // GASLIMIT
        .{ .opcode = 0x46, .needs_input = false }, // CHAINID
        .{ .opcode = 0x47, .needs_input = false }, // SELFBALANCE
        .{ .opcode = 0x48, .needs_input = false }, // BASEFEE
        .{ .opcode = 0x49, .needs_input = true }, // BLOBHASH
        .{ .opcode = 0x4A, .needs_input = false }, // BLOBBASEFEE
    };

    for (opcodes) |op| {
        // Clear stack for clean test
        frame.stack.clear();

        if (op.needs_input) {
            try frame.stack.append(0); // Input for BLOBHASH
        }

        const initial_stack_len = frame.stack.size;

        _ = try evm.table.execute(0, interpreter, state, op.opcode);

        // Check that exactly one value was pushed (or net zero for BLOBHASH which pops 1 and pushes 1)
        const expected_len = if (op.needs_input)
            initial_stack_len // BLOBHASH: pop 1, push 1 = net 0
        else
            initial_stack_len + 1; // Others: just push 1 = net +1
        try testing.expectEqual(expected_len, frame.stack.size);
    }
}
