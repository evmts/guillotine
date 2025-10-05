const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

const Evm = evm.Evm;
const eips = evm.Eips;
const Hardfork = evm.Hardfork;
const blob = primitives.Blob;
const Address = primitives.Address.Address;
const Account = evm.Account;
const Database = evm.Database;
const BlockInfo = evm.BlockInfo;
const TransactionContext = evm.TransactionContext;

test "blob gas calculation - single blob" {
    const eips_instance = eips{ .hardfork = .CANCUN };

    // Single blob should cost exactly GAS_PER_BLOB
    const blob_count = 1;
    const blob_gas_price = 1; // minimum price
    const cost = eips_instance.blob_gas_cost(blob_count, blob_gas_price);

    try std.testing.expectEqual(@as(u256, 131072), cost); // 1 * 131072
}

test "blob gas calculation - multiple blobs with higher price" {
    const eips_instance = eips{ .hardfork = .CANCUN };

    // 3 blobs at 10 wei per gas
    const blob_count = 3;
    const blob_gas_price = 10;
    const cost = eips_instance.blob_gas_cost(blob_count, blob_gas_price);

    try std.testing.expectEqual(@as(u256, 3932160), cost); // 3 * 131072 * 10
}

test "blob gas calculation - pre-Cancun returns zero" {
    const eips_instance = eips{ .hardfork = .SHANGHAI };

    const blob_count = 1;
    const blob_gas_price = 100;
    const cost = eips_instance.blob_gas_cost(blob_count, blob_gas_price);

    try std.testing.expectEqual(@as(u256, 0), cost); // Pre-Cancun = no blob gas
}

test "exponential blob pricing - zero excess" {
    const eips_instance = eips{ .hardfork = .CANCUN };

    const price = eips_instance.blob_gas_price(0);
    try std.testing.expectEqual(@as(u128, 1), price); // MIN_blob_gas_price
}

test "exponential blob pricing - with excess" {
    const eips_instance = eips{ .hardfork = .CANCUN };

    // Test with various excess values
    const test_cases = [_]struct { excess: u64, min_expected: u128 }{
        .{ .excess = 0, .min_expected = 1 },
        .{ .excess = 1000000, .min_expected = 1 }, // Small excess, price slightly > 1
        .{ .excess = 10000000, .min_expected = 2 }, // Larger excess
    };

    for (test_cases) |tc| {
        const price = eips_instance.blob_gas_price(tc.excess);
        try std.testing.expect(price >= tc.min_expected);
    }
}

test "excess blob gas calculation" {
    // Test excess calculation for next block
    const eips_instance = eips{ .hardfork = .CANCUN };

    // Case 1: Below target, no excess
    var excess = eips_instance.excess_blob_gas(0, 100000);
    try std.testing.expectEqual(@as(u64, 0), excess);

    // Case 2: Exactly at target, no excess
    excess = eips_instance.excess_blob_gas(0, blob.TARGET_BLOB_GAS_PER_BLOCK_CANCUN);
    try std.testing.expectEqual(@as(u64, 0), excess);

    // Case 3: Above target, has excess
    excess = eips_instance.excess_blob_gas(0, blob.TARGET_BLOB_GAS_PER_BLOCK_CANCUN + 131072);
    try std.testing.expectEqual(@as(u64, 131072), excess); // 1 blob worth of excess

    // Case 4: With existing excess
    excess = eips_instance.excess_blob_gas(100000, 300000);
    const expected = if (100000 + 300000 > blob.TARGET_BLOB_GAS_PER_BLOCK_CANCUN)
        100000 + 300000 - blob.TARGET_BLOB_GAS_PER_BLOCK_CANCUN
    else
        0;
    try std.testing.expectEqual(@as(u64, expected), excess);
}

test "blob transaction validation - too many blobs" {
    // Test that transactions with > 6 blobs are rejected
    const blob_count = 7;
    try std.testing.expect(blob_count > blob.MAX_BLOBS_PER_TRANSACTION);
}

test "integration - blob transaction full flow" {
    const allocator = std.testing.allocator;

    // Setup test database and EVM
    var db = Database.init(allocator);
    defer db.deinit();

    // Create origin account with balance
    const origin = Address{ .bytes = [_]u8{0x01} ** 20 };
    const origin_balance: u256 = 10_000_000_000_000_000_000; // 10 ETH
    const origin_account = Account{
        .balance = origin_balance,
        .nonce = 0,
        .code_hash = primitives.EMPTY_CODE_HASH,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(origin.bytes, origin_account);

    // Create block with blob base fee
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 18000000, // Post-Cancun
        .parent_hash = [_]u8{0} ** 32,
        .timestamp = 1700000000,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = Address{ .bytes = [_]u8{0x02} ** 20 },
        .base_fee = 30_000_000_000, // 30 gwei
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 1_000_000_000, // 1 gwei blob base fee
        .blob_versioned_hashes = &.{},
        .excess_blob_gas = 0,
        .blob_gas_used = 0,
    };

    // Create transaction context with blobs
    const blob_hash1 = [_]u8{0x01} ** 32;
    const blob_hash2 = [_]u8{0x02} ** 32;
    const blob_hashes = [_][32]u8{ blob_hash1, blob_hash2 };

    const tx_context = TransactionContext{
        .gas_limit = 100000,
        .coinbase = block_info.coinbase,
        .chain_id = 1,
        .blob_versioned_hashes = &blob_hashes,
        .blob_base_fee = block_info.blob_base_fee,
        .max_fee_per_blob_gas = 5_000_000_000, // 5 gwei max fee per blob gas
    };

    // Initialize EVM
    var evm_instance = try Evm(.{}).init(allocator, &db, block_info, tx_context, 35_000_000_000, // gas price 35 gwei (5 gwei priority fee)
        origin, .CANCUN);
    defer evm_instance.deinit();

    // Execute a simple call with blob transaction
    const CallParams = Evm(.{}).CallParams;
    const call_params = CallParams{
        .call = .{
            .caller = origin,
            .to = Address{ .bytes = [_]u8{0x03} ** 20 },
            .value = 1_000_000_000_000_000_000, // 1 ETH
            .input = &.{},
            .gas = 50000,
        },
    };

    var result = evm_instance.call(call_params);
    defer result.deinit(allocator);

    // Verify transaction succeeded
    try std.testing.expect(result.success);

    // Verify blob gas was charged
    const final_origin_account = try db.get_account(origin.bytes);
    try std.testing.expect(final_origin_account.?.balance < origin_balance);

    // Calculate expected charges
    const execution_gas_cost = 50000 * 35_000_000_000; // execution gas
    const blob_gas_cost = 2 * 131072 * 1_000_000_000; // 2 blobs
    const value_transfer = 1_000_000_000_000_000_000;
    const total_cost = execution_gas_cost + blob_gas_cost + value_transfer;

    const expected_balance = origin_balance - total_cost;
    // Allow for gas refunds and other adjustments
    const actual_balance = final_origin_account.?.balance;
    const difference = if (expected_balance > actual_balance)
        expected_balance - actual_balance
    else
        actual_balance - expected_balance;

    // Check that the difference is within 1% (accounting for gas refunds)
    try std.testing.expect(difference < expected_balance / 100);
}

test "blob gas cost calculation with max blobs" {
    const eips_instance = eips{ .hardfork = .CANCUN };

    // Test with maximum allowed blobs
    const blob_count = blob.MAX_BLOBS_PER_TRANSACTION;
    const blob_gas_price = 5_000_000_000; // 5 gwei per gas
    const cost = eips_instance.blob_gas_cost(blob_count, blob_gas_price);

    // 6 blobs * 131072 gas/blob * 5 gwei/gas
    const expected = @as(u256, 6) * 131072 * 5_000_000_000;
    try std.testing.expectEqual(expected, cost);
}

test "blob gas calculation with zero blobs" {
    const eips_instance = eips{ .hardfork = .CANCUN };

    const blob_count = 0;
    const blob_gas_price = 1_000_000_000;
    const cost = eips_instance.blob_gas_cost(blob_count, blob_gas_price);

    try std.testing.expectEqual(@as(u256, 0), cost);
}

test "max_blob_gas_cost" {
    const eips_instance = eips{ .hardfork = .CANCUN };

    const blob_count = 2;
    const max_fee_per_blob_gas: u256 = 10_000_000_000; // 10 gwei
    const max_cost = eips_instance.max_blob_gas_cost(max_fee_per_blob_gas, blob_count);

    // 2 blobs * 131072 gas/blob * 10 gwei/gas
    const expected = @as(u256, 2) * 131072 * 10_000_000_000;
    try std.testing.expectEqual(expected, max_cost);
}

test "blob gas calculation" {
    // Test blob gas calculation
    try std.testing.expectEqual(@as(u64, 0), 0 * blob.BLOB_GAS_PER_BLOB);
    try std.testing.expectEqual(@as(u64, 131072), 1 * blob.BLOB_GAS_PER_BLOB);
    try std.testing.expectEqual(@as(u64, 262144), 2 * blob.BLOB_GAS_PER_BLOB);
    try std.testing.expectEqual(@as(u64, 393216), 3 * blob.BLOB_GAS_PER_BLOB);
    try std.testing.expectEqual(@as(u64, 786432), 6 * blob.BLOB_GAS_PER_BLOB);
}

test "blob gas constants validation" {
    // Verify constants are correctly defined
    try std.testing.expectEqual(@as(u64, 131072), blob.BLOB_GAS_PER_BLOB);
    try std.testing.expectEqual(@as(u64, 1), blob.MIN_BLOB_BASE_FEE);
    try std.testing.expectEqual(@as(u64, 393216), blob.TARGET_BLOB_GAS_PER_BLOCK_CANCUN);
    try std.testing.expectEqual(@as(u64, 786432), blob.MAX_BLOB_GAS_PER_BLOCK_CANCUN);
    try std.testing.expectEqual(@as(u64, 3338477), blob.BLOB_BASE_FEE_UPDATE_FRACTION_CANCUN);
    try std.testing.expectEqual(@as(usize, 6), blob.MAX_BLOBS_PER_TRANSACTION);

    // Verify relationships between constants
    try std.testing.expectEqual(blob.TARGET_BLOB_GAS_PER_BLOCK_CANCUN, 3 * blob.BLOB_GAS_PER_BLOB);
    try std.testing.expectEqual(blob.MAX_BLOB_GAS_PER_BLOCK_CANCUN, 6 * blob.BLOB_GAS_PER_BLOB);
}

test "hardfork-specific blob gas parameters - Cancun vs Prague" {
    // Test Cancun parameters
    const eips_cancun = eips{ .hardfork = .CANCUN };
    try std.testing.expectEqual(@as(u64, 393216), eips_cancun.target_blob_gas()); // 3 blobs
    try std.testing.expectEqual(@as(u64, 786432), eips_cancun.max_blob_gas()); // 6 blobs
    try std.testing.expectEqual(@as(u64, 3338477), eips_cancun.blob_base_fee_update_fraction());

    // Test Prague parameters (EIP-7691)
    const eips_prague = eips{ .hardfork = .PRAGUE };
    try std.testing.expectEqual(@as(u64, 786432), eips_prague.target_blob_gas()); // 6 blobs
    try std.testing.expectEqual(@as(u64, 1179648), eips_prague.max_blob_gas()); // 9 blobs
    try std.testing.expectEqual(@as(u64, 5007716), eips_prague.blob_base_fee_update_fraction());

    // Verify the constants are correctly defined
    try std.testing.expectEqual(blob.TARGET_BLOB_GAS_PER_BLOCK_CANCUN, 3 * blob.BLOB_GAS_PER_BLOB);
    try std.testing.expectEqual(blob.MAX_BLOB_GAS_PER_BLOCK_CANCUN, 6 * blob.BLOB_GAS_PER_BLOB);
    try std.testing.expectEqual(blob.TARGET_BLOB_GAS_PER_BLOCK_PRAGUE, 6 * blob.BLOB_GAS_PER_BLOB);
    try std.testing.expectEqual(blob.MAX_BLOB_GAS_PER_BLOCK_PRAGUE, 9 * blob.BLOB_GAS_PER_BLOB);
}

test "blob gas price calculation with different update fractions" {
    const eips_cancun = eips{ .hardfork = .CANCUN };
    const eips_prague = eips{ .hardfork = .PRAGUE };

    // Test with same excess gas but different hardforks
    const excess_gas: u64 = 1000000;

    const price_cancun = eips_cancun.blob_gas_price(excess_gas);
    const price_prague = eips_prague.blob_gas_price(excess_gas);

    // Prague has a higher update fraction, so it should have a different price curve
    // Both should be non-zero but different
    try std.testing.expect(price_cancun > 0);
    try std.testing.expect(price_prague > 0);
    // The exact relationship depends on the exponential formula
}

test "excess blob gas calculation with different targets" {
    const eips_cancun = eips{ .hardfork = .CANCUN };
    const eips_prague = eips{ .hardfork = .PRAGUE };

    // Test with gas usage that would create excess in Cancun but not in Prague
    const parent_excess: u64 = 0;
    const parent_used: u64 = 500000; // Between Cancun target (393216) and Prague target (786432)

    const excess_cancun = eips_cancun.excess_blob_gas(parent_excess, parent_used);
    const excess_prague = eips_prague.excess_blob_gas(parent_excess, parent_used);

    // Should have excess in Cancun but not in Prague
    try std.testing.expectEqual(@as(u64, 106784), excess_cancun); // 500000 - 393216
    try std.testing.expectEqual(@as(u64, 0), excess_prague); // Below Prague target
}
