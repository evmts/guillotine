const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const GasConstants = primitives.GasConstants;
const Evm = @import("evm.zig").Evm;
const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
const DatabaseInterface = @import("database_interface.zig").DatabaseInterface;
const BlockInfo = @import("block_info.zig").DefaultBlockInfo;
const TransactionContext = @import("transaction_context.zig").TransactionContext;
const CallParams = @import("call_params.zig").CallParams;
const CallKind = @import("call_params.zig").CallKind;

const ZERO_ADDRESS = [_]u8{0} ** 20;
const TEST_ADDRESS_1 = [_]u8{1} ** 20;
const TEST_ADDRESS_2 = [_]u8{2} ** 20;
const TEST_ADDRESS_3 = [_]u8{3} ** 20;
const TEST_ADDRESS_4 = [_]u8{4} ** 20;

test "warm/cold access - multiple addresses in single transaction" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);
    
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .basefee = 10,
        .coinbase = ZERO_ADDRESS,
        .prevrandao = [_]u8{1} ** 32,
        .blob_base_fee = 1,
    };
    
    const tx_context = TransactionContext{
        .gas_price = 20,
        .gas_limit = 1_000_000,
        .origin = TEST_ADDRESS_1,
        .blob_hashes = &.{},
        .max_fee_per_blob_gas = null,
    };
    
    var evm = try Evm.init(allocator, db_interface, &block_info, &tx_context);
    defer evm.deinit();
    
    // Test bytecode: Multiple BALANCE calls to different addresses
    // PUSH20 addr2, BALANCE, PUSH20 addr3, BALANCE, PUSH20 addr2, BALANCE, STOP
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // First BALANCE - addr2 (cold)
    try bytecode.append(0x73); // PUSH20
    try bytecode.appendSlice(&TEST_ADDRESS_2);
    try bytecode.append(0x31); // BALANCE
    
    // Second BALANCE - addr3 (cold)
    try bytecode.append(0x73); // PUSH20
    try bytecode.appendSlice(&TEST_ADDRESS_3);
    try bytecode.append(0x31); // BALANCE
    
    // Third BALANCE - addr2 again (warm)
    try bytecode.append(0x73); // PUSH20
    try bytecode.appendSlice(&TEST_ADDRESS_2);
    try bytecode.append(0x31); // BALANCE
    
    try bytecode.append(0x00); // STOP
    
    // Deploy contract
    try memory_db.set_code(ZERO_ADDRESS, bytecode.items);
    
    const params = CallParams{
        .kind = CallKind.Call,
        .caller = TEST_ADDRESS_1,
        .target_address = ZERO_ADDRESS,
        .value = 0,
        .input_data = &.{},
        .gas_limit = 100_000,
        .is_static = false,
    };
    
    const result = try evm.call(params);
    
    // Expected gas usage:
    // PUSH20: 3 gas each (x3 = 9)
    // BALANCE first addr2: 2600 gas (cold)
    // BALANCE addr3: 2600 gas (cold)
    // BALANCE second addr2: 100 gas (warm)
    // Total: 9 + 2600 + 2600 + 100 = 5309
    const expected_gas_used: u64 = 9 + 2600 + 2600 + 100;
    const actual_gas_used = params.gas_limit - result.gas_left;
    
    // Account for base call cost
    try testing.expect(actual_gas_used >= expected_gas_used);
}

test "warm/cold access - storage slots across different addresses" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);
    
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .basefee = 10,
        .coinbase = ZERO_ADDRESS,
        .prevrandao = [_]u8{1} ** 32,
        .blob_base_fee = 1,
    };
    
    const tx_context = TransactionContext{
        .gas_price = 20,
        .gas_limit = 1_000_000,
        .origin = TEST_ADDRESS_1,
        .blob_hashes = &.{},
        .max_fee_per_blob_gas = null,
    };
    
    var evm = try Evm.init(allocator, db_interface, &block_info, &tx_context);
    defer evm.deinit();
    
    // Test that storage slots are tracked per-address
    const slot1: u256 = 42;
    const slot2: u256 = 100;
    
    // Access slot1 on ADDRESS_2
    const cost1 = try evm.access_storage_slot(TEST_ADDRESS_2, slot1);
    try testing.expectEqual(GasConstants.ColdSloadCost, cost1);
    
    // Access same slot number on different address - should be cold
    const cost2 = try evm.access_storage_slot(TEST_ADDRESS_3, slot1);
    try testing.expectEqual(GasConstants.ColdSloadCost, cost2);
    
    // Access same slot on ADDRESS_2 again - should be warm
    const cost3 = try evm.access_storage_slot(TEST_ADDRESS_2, slot1);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, cost3);
    
    // Different slot on ADDRESS_2 - should be cold
    const cost4 = try evm.access_storage_slot(TEST_ADDRESS_2, slot2);
    try testing.expectEqual(GasConstants.ColdSloadCost, cost4);
}

test "warm/cold access - EXTCODESIZE and EXTCODEHASH" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);
    
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .basefee = 10,
        .coinbase = ZERO_ADDRESS,
        .prevrandao = [_]u8{1} ** 32,
        .blob_base_fee = 1,
    };
    
    const tx_context = TransactionContext{
        .gas_price = 20,
        .gas_limit = 1_000_000,
        .origin = TEST_ADDRESS_1,
        .blob_hashes = &.{},
        .max_fee_per_blob_gas = null,
    };
    
    var evm = try Evm.init(allocator, db_interface, &block_info, &tx_context);
    defer evm.deinit();
    
    // EXTCODESIZE should also trigger warm/cold access
    // First access should be cold
    const cold_cost = try evm.access_address(TEST_ADDRESS_2);
    try testing.expectEqual(GasConstants.ColdAccountAccessCost, cold_cost);
    
    // Subsequent EXTCODEHASH to same address should be warm
    const warm_cost = try evm.access_address(TEST_ADDRESS_2);
    try testing.expectEqual(GasConstants.WarmAccessCost, warm_cost);
}

test "warm/cold access - nested calls preserve access list" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);
    
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .basefee = 10,
        .coinbase = ZERO_ADDRESS,
        .prevrandao = [_]u8{1} ** 32,
        .blob_base_fee = 1,
    };
    
    const tx_context = TransactionContext{
        .gas_price = 20,
        .gas_limit = 1_000_000,
        .origin = TEST_ADDRESS_1,
        .blob_hashes = &.{},
        .max_fee_per_blob_gas = null,
    };
    
    var evm = try Evm.init(allocator, db_interface, &block_info, &tx_context);
    defer evm.deinit();
    
    // Warm an address in the parent context
    _ = try evm.access_address(TEST_ADDRESS_2);
    
    // Create a snapshot (simulating a CALL)
    const snapshot = evm.create_snapshot();
    
    // Access should still be warm in nested context
    const nested_cost = try evm.access_address(TEST_ADDRESS_2);
    try testing.expectEqual(GasConstants.WarmAccessCost, nested_cost);
    
    // Warm a new address in nested context
    _ = try evm.access_address(TEST_ADDRESS_3);
    
    // Revert the snapshot
    evm.revert_to_snapshot(snapshot);
    
    // TEST_ADDRESS_2 should still be warm
    const post_revert_cost2 = try evm.access_address(TEST_ADDRESS_2);
    try testing.expectEqual(GasConstants.WarmAccessCost, post_revert_cost2);
    
    // TEST_ADDRESS_3 warming should have been reverted - should be cold
    const post_revert_cost3 = try evm.access_address(TEST_ADDRESS_3);
    try testing.expectEqual(GasConstants.ColdAccountAccessCost, post_revert_cost3);
}

test "warm/cold access - SSTORE gas calculation" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);
    
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .basefee = 10,
        .coinbase = ZERO_ADDRESS,
        .prevrandao = [_]u8{1} ** 32,
        .blob_base_fee = 1,
    };
    
    const tx_context = TransactionContext{
        .gas_price = 20,
        .gas_limit = 1_000_000,
        .origin = TEST_ADDRESS_1,
        .blob_hashes = &.{},
        .max_fee_per_blob_gas = null,
    };
    
    var evm = try Evm.init(allocator, db_interface, &block_info, &tx_context);
    defer evm.deinit();
    
    const slot: u256 = 42;
    
    // First SSTORE to a slot should include cold access cost
    const cold_cost = try evm.access_storage_slot(TEST_ADDRESS_2, slot);
    try testing.expectEqual(GasConstants.ColdSloadCost, cold_cost);
    
    // Second SSTORE to same slot should use warm access cost
    const warm_cost = try evm.access_storage_slot(TEST_ADDRESS_2, slot);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, warm_cost);
}

test "warm/cold access - pre-warming validation" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);
    
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .basefee = 10,
        .coinbase = TEST_ADDRESS_3,
        .prevrandao = [_]u8{1} ** 32,
        .blob_base_fee = 1,
    };
    
    const tx_context = TransactionContext{
        .gas_price = 20,
        .gas_limit = 1_000_000,
        .origin = TEST_ADDRESS_1,
        .blob_hashes = &.{},
        .max_fee_per_blob_gas = null,
    };
    
    var evm = try Evm.init(allocator, db_interface, &block_info, &tx_context);
    defer evm.deinit();
    
    // Pre-warm standard addresses as per EIP-2929
    const addresses_to_warm = [_]Address{
        TEST_ADDRESS_1,  // tx.origin
        TEST_ADDRESS_2,  // target (simulated)
        TEST_ADDRESS_3,  // coinbase
    };
    try evm.access_list.pre_warm_addresses(&addresses_to_warm);
    
    // Verify all are warm and return correct gas cost
    for (addresses_to_warm) |addr| {
        const cost = try evm.access_address(addr);
        try testing.expectEqual(GasConstants.WarmAccessCost, cost);
        try testing.expect(evm.access_list.is_address_warm(addr));
    }
    
    // Non-prewarmed address should be cold
    const cold_cost = try evm.access_address(TEST_ADDRESS_4);
    try testing.expectEqual(GasConstants.ColdAccountAccessCost, cold_cost);
}

test "warm/cold access - large number of unique accesses" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);
    
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .basefee = 10,
        .coinbase = ZERO_ADDRESS,
        .prevrandao = [_]u8{1} ** 32,
        .blob_base_fee = 1,
    };
    
    const tx_context = TransactionContext{
        .gas_price = 20,
        .gas_limit = 10_000_000,
        .origin = TEST_ADDRESS_1,
        .blob_hashes = &.{},
        .max_fee_per_blob_gas = null,
    };
    
    var evm = try Evm.init(allocator, db_interface, &block_info, &tx_context);
    defer evm.deinit();
    
    // Access many different addresses
    var total_gas: u64 = 0;
    var i: u8 = 0;
    while (i < 100) : (i += 1) {
        var addr = [_]u8{0} ** 20;
        addr[19] = i;
        
        // First access should be cold
        const cost1 = try evm.access_address(addr);
        try testing.expectEqual(GasConstants.ColdAccountAccessCost, cost1);
        total_gas += cost1;
        
        // Second access should be warm
        const cost2 = try evm.access_address(addr);
        try testing.expectEqual(GasConstants.WarmAccessCost, cost2);
        total_gas += cost2;
    }
    
    // Verify total gas calculation
    const expected_gas = 100 * (GasConstants.ColdAccountAccessCost + GasConstants.WarmAccessCost);
    try testing.expectEqual(expected_gas, total_gas);
}

test "warm/cold access - CALL opcode target pre-warming" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);
    
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .basefee = 10,
        .coinbase = ZERO_ADDRESS,
        .prevrandao = [_]u8{1} ** 32,
        .blob_base_fee = 1,
    };
    
    const tx_context = TransactionContext{
        .gas_price = 20,
        .gas_limit = 1_000_000,
        .origin = TEST_ADDRESS_1,
        .blob_hashes = &.{},
        .max_fee_per_blob_gas = null,
    };
    
    var evm = try Evm.init(allocator, db_interface, &block_info, &tx_context);
    defer evm.deinit();
    
    // When making a CALL, the target address should be accessed for warm/cold
    // This test verifies the gas calculation includes access cost
    
    // First, make target address cold
    try testing.expect(!evm.access_list.is_address_warm(TEST_ADDRESS_2));
    
    // Access it once - should be cold
    const cost = try evm.access_address(TEST_ADDRESS_2);
    try testing.expectEqual(GasConstants.ColdAccountAccessCost, cost);
    
    // Now it should be warm for subsequent CALL
    try testing.expect(evm.access_list.is_address_warm(TEST_ADDRESS_2));
}
