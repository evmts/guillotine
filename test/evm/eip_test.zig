//! Comprehensive tests for EIP-2929, EIP-3651, and EIP-4844 implementations

const std = @import("std");
const testing = std.testing;
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const ZERO_ADDRESS = primitives.ZERO_ADDRESS;
const GasConstants = primitives.GasConstants;

const Evm = @import("evm").Evm;
const DatabaseInterface = @import("evm").DatabaseInterface;
const MemoryDatabase = @import("evm").MemoryDatabase;
const BlockInfo = @import("evm").BlockInfo;
const TransactionContext = @import("evm").TransactionContext;
const Hardfork = @import("evm").Hardfork;
const Contract = @import("contract.zig").Contract;

// EIP-2929: Gas cost changes for state access opcodes
test "EIP-2929 - SLOAD warm/cold access costs" {
    const allocator = testing.allocator;
    
    // Setup database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, Hardfork.BERLIN);
    defer evm.deinit();
    
    // Test cold SLOAD (first access)
    const cold_cost = try evm.access_storage_slot(ZERO_ADDRESS, 42);
    try testing.expectEqual(GasConstants.ColdSloadCost, cold_cost); // 2100 gas
    
    // Test warm SLOAD (second access)
    const warm_cost = try evm.access_storage_slot(ZERO_ADDRESS, 42);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, warm_cost); // 100 gas
}

test "EIP-2929 - BALANCE/EXTCODESIZE/EXTCODECOPY/EXTCODEHASH warm/cold access costs" {
    const allocator = testing.allocator;
    
    // Setup database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, Hardfork.BERLIN);
    defer evm.deinit();
    
    const test_address = [_]u8{0x42} ** 20;
    
    // Test cold access (first access)
    const cold_cost = try evm.access_address(test_address);
    try testing.expectEqual(GasConstants.ColdAccountAccessCost, cold_cost); // 2600 gas
    
    // Test warm access (second access)
    const warm_cost = try evm.access_address(test_address);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, warm_cost); // 100 gas
}

test "EIP-2929 - Pre-Berlin hardfork should not use warm/cold distinction" {
    const allocator = testing.allocator;
    
    // Setup database and EVM with pre-Berlin hardfork
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, Hardfork.ISTANBUL);
    defer evm.deinit();
    
    // Pre-Berlin should always return warm costs
    const first_access = try evm.access_address([_]u8{0x42} ** 20);
    const second_access = try evm.access_address([_]u8{0x42} ** 20);
    
    // Both should be the same (no cold/warm distinction)
    try testing.expectEqual(first_access, second_access);
}

// EIP-3651: Warm COINBASE
test "EIP-3651 - Coinbase address should be warm at transaction start" {
    const allocator = testing.allocator;
    
    // Setup database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const block_info = BlockInfo.init();
    const coinbase_address = [_]u8{0xC0} ** 20;
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = coinbase_address,
        .chain_id = 1,
    };
    
    // Test with Shanghai hardfork (EIP-3651 active)
    var evm_shanghai = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, Hardfork.SHANGHAI);
    defer evm_shanghai.deinit();
    
    // Coinbase should be warm from the start
    const coinbase_cost = try evm_shanghai.access_address(coinbase_address);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, coinbase_cost); // 100 gas, not 2600
    
    // Test with pre-Shanghai hardfork (EIP-3651 not active)
    var evm_london = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, Hardfork.LONDON);
    defer evm_london.deinit();
    
    // Coinbase should be cold at start
    const coinbase_cost_london = try evm_london.access_address(coinbase_address);
    try testing.expectEqual(GasConstants.ColdAccountAccessCost, coinbase_cost_london); // 2600 gas
}

// EIP-4844: Shard blob transactions
test "EIP-4844 - BLOBHASH opcode functionality" {
    const allocator = testing.allocator;
    
    // Setup database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const block_info = BlockInfo.init();
    
    // Create blob hashes for testing
    const blob_hash1 = [_]u8{0x01} ** 32;
    const blob_hash2 = [_]u8{0x02} ** 32;
    const blob_hashes = [_][32]u8{ blob_hash1, blob_hash2 };
    
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
        .blob_versioned_hashes = &blob_hashes,
        .blob_base_fee = 1_000_000_000, // 1 gwei
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, Hardfork.CANCUN);
    defer evm.deinit();
    
    // Test get_blob_hash with valid index
    const hash0_opt = evm.get_blob_hash(0);
    try testing.expect(hash0_opt != null);
    try testing.expectEqual(blob_hash1, hash0_opt.?);
    
    const hash1_opt = evm.get_blob_hash(1);
    try testing.expect(hash1_opt != null);
    try testing.expectEqual(blob_hash2, hash1_opt.?);
    
    // Test get_blob_hash with out-of-bounds index
    const hash2_opt = evm.get_blob_hash(2);
    try testing.expect(hash2_opt == null);
    
    // Test get_blob_hash with large index
    const hash_large_opt = evm.get_blob_hash(std.math.maxInt(u256));
    try testing.expect(hash_large_opt == null);
}

test "EIP-4844 - BLOBBASEFEE opcode functionality" {
    const allocator = testing.allocator;
    
    // Setup database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const block_info = BlockInfo.init();
    const expected_blob_base_fee: u256 = 123_456_789_000; // wei
    
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
        .blob_base_fee = expected_blob_base_fee,
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, Hardfork.CANCUN);
    defer evm.deinit();
    
    // Test get_blob_base_fee
    const blob_base_fee = evm.get_blob_base_fee();
    try testing.expectEqual(expected_blob_base_fee, blob_base_fee);
}

// Integration test combining all EIPs
test "Integration - All EIPs working together" {
    const allocator = testing.allocator;
    
    // Setup database with some initial state
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    // Add an account with storage
    const test_account_address = [_]u8{0xAA} ** 20;
    const test_account = DatabaseInterface.Account{
        .nonce = 5,
        .balance = 1_000_000_000_000_000_000, // 1 ETH
        .code_hash = [_]u8{0} ** 32,
    };
    try memory_db.set_account(test_account_address, test_account);
    try memory_db.set_storage(test_account_address, 0x100, 0x42);
    
    const db_interface = memory_db.to_database_interface();
    
    const block_info = BlockInfo.init();
    const coinbase_address = [_]u8{0xC0} ** 20;
    
    // Create blob hashes
    const blob_hash = [_]u8{0xBB} ** 32;
    const blob_hashes = [_][32]u8{blob_hash};
    
    const context = TransactionContext{
        .gas_limit = 10_000_000,
        .coinbase = coinbase_address,
        .chain_id = 1,
        .blob_versioned_hashes = &blob_hashes,
        .blob_base_fee = 7_000_000_000, // 7 gwei
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 20_000_000_000, ZERO_ADDRESS, Hardfork.CANCUN);
    defer evm.deinit();
    
    // Test EIP-3651: Coinbase should be warm
    const coinbase_access_cost = try evm.access_address(coinbase_address);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, coinbase_access_cost);
    
    // Test EIP-2929: First access to account should be cold
    const first_account_access = try evm.access_address(test_account_address);
    try testing.expectEqual(GasConstants.ColdAccountAccessCost, first_account_access);
    
    // Second access should be warm
    const second_account_access = try evm.access_address(test_account_address);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, second_account_access);
    
    // Test EIP-2929: Storage access
    const first_storage_access = try evm.access_storage_slot(test_account_address, 0x100);
    try testing.expectEqual(GasConstants.ColdSloadCost, first_storage_access);
    
    const second_storage_access = try evm.access_storage_slot(test_account_address, 0x100);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, second_storage_access);
    
    // Test EIP-4844: Blob functionality
    const blob_hash_result = evm.get_blob_hash(0);
    try testing.expect(blob_hash_result != null);
    try testing.expectEqual(blob_hash, blob_hash_result.?);
    
    const blob_base_fee = evm.get_blob_base_fee();
    try testing.expectEqual(@as(u256, 7_000_000_000), blob_base_fee);
}

// Test access list clearing between transactions
test "Access list clearing between transactions" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, Hardfork.BERLIN);
    defer evm.deinit();
    
    const test_address = [_]u8{0x42} ** 20;
    
    // First access should be cold
    const first_cost = try evm.access_address(test_address);
    try testing.expectEqual(GasConstants.ColdAccountAccessCost, first_cost);
    
    // Clear access list (simulating new transaction)
    evm.access_list.clear();
    
    // After clearing, access should be cold again
    const cost_after_clear = try evm.access_address(test_address);
    try testing.expectEqual(GasConstants.ColdAccountAccessCost, cost_after_clear);
}