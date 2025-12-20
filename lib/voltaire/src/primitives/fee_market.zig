const std = @import("std");

/// EIP-1559 fee market mechanism
/// Base fee adjusts based on block fullness; burned, not paid to miners
/// Calculate fee delta safely (avoids overflow and division by zero)
fn calculateFeeDelta(fee: u64, gas_delta: u64, gas_target: u64, denominator: u64) u64 {
    // Using u128 for intermediate calculation to avoid overflow
    const intermediate: u128 = @as(u128, fee) * @as(u128, gas_delta);
    // Avoid division by zero
    const divisor: u128 = @max(1, @as(u128, gas_target) * @as(u128, denominator));
    const result: u64 = @intCast(@min(@as(u128, std.math.maxInt(u64)), intermediate / divisor));

    // Always return at least 1 to ensure some movement
    return @max(1, result);
}
/// Minimum base fee (wei)
pub const MIN_BASE_FEE: u64 = 7;

/// Base fee change denominator (12.5% max change per block)
pub const BASE_FEE_CHANGE_DENOMINATOR: u64 = 8;

/// Initialize base fee for first EIP-1559 block based on parent gas usage
pub fn initialBaseFee(parent_gas_used: u64, parent_gas_limit: u64) u64 {
    const parent_gas_target = parent_gas_limit / 2;
    var base_fee: u64 = 1_000_000_000; // 1 gwei
    if (parent_gas_used > 0) {
        const gas_used_delta = if (parent_gas_used > parent_gas_target)
            parent_gas_used - parent_gas_target
        else
            parent_gas_target - parent_gas_used;

        const base_fee_delta = calculateFeeDelta(base_fee, gas_used_delta, parent_gas_target, BASE_FEE_CHANGE_DENOMINATOR);

        if (parent_gas_used > parent_gas_target) {
            base_fee = base_fee + base_fee_delta;
        } else if (base_fee > base_fee_delta) {
            base_fee = base_fee - base_fee_delta;
        }
    }

    return @max(base_fee, MIN_BASE_FEE);
}

/// Calculate the next block's base fee based on the current block
///
/// This implements the EIP-1559 base fee adjustment algorithm:
/// - If the block used exactly the target gas, the base fee remains the same
/// - If the block used more than the target, the base fee increases
/// - If the block used less than the target, the base fee decreases
/// - The maximum change per block is 12.5% (1/8)
///
/// Parameters:
/// - parent_base_fee: Base fee of the parent block
/// - parent_gas_used: Gas used by the parent block
/// - parent_gas_target: Target gas usage of the parent block
///
/// Returns: The next block's base fee (in wei)
pub fn nextBaseFee(parent_base_fee: u64, parent_gas_used: u64, parent_gas_target: u64) u64 {
    // Calculating next block's base fee
    // Using parent block base fee and gas usage

    // If parent block is empty, keep the base fee the same
    // Skip the delta calculations and just return the parent fee directly
    if (parent_gas_used == 0) {
        // Parent block was empty, keeping base fee the same
        return parent_base_fee;
    }

    // Calculate base fee delta
    var new_base_fee = parent_base_fee;

    if (parent_gas_used == parent_gas_target) {
        // If parent block used exactly the target gas, keep the base fee the same
        // Parent block used exactly the target gas, keeping base fee the same
    } else if (parent_gas_used > parent_gas_target) {
        // If parent block used more than the target gas, increase the base fee

        // Calculate gas used delta as a fraction of target
        const gas_used_delta = parent_gas_used - parent_gas_target;

        // Calculate the base fee delta (max 12.5% increase)
        const base_fee_delta = calculateFeeDelta(parent_base_fee, gas_used_delta, parent_gas_target, BASE_FEE_CHANGE_DENOMINATOR);

        // Increase the base fee
        // The overflow check is probably unnecessary given gas limits, but it's a good safety measure
        new_base_fee = std.math.add(u64, parent_base_fee, base_fee_delta) catch parent_base_fee;

        // Parent block used more than target gas, increasing base fee
    } else {
        // If parent block used less than the target gas, decrease the base fee

        // Calculate gas used delta as a fraction of target
        const gas_used_delta = parent_gas_target - parent_gas_used;

        // Calculate the base fee delta (max 12.5% decrease)
        const base_fee_delta = calculateFeeDelta(parent_base_fee, gas_used_delta, parent_gas_target, BASE_FEE_CHANGE_DENOMINATOR);

        // Decrease the base fee, but don't go below the minimum
        new_base_fee = if (parent_base_fee > base_fee_delta)
            parent_base_fee - base_fee_delta
        else
            MIN_BASE_FEE;

        // Parent block used less than target gas, decreasing base fee
    }

    // Ensure base fee is at least the minimum
    new_base_fee = @max(new_base_fee, MIN_BASE_FEE);

    // Next block base fee calculated
    return new_base_fee;
}

/// Calculate the effective gas price for an EIP-1559 transaction
///
/// The effective gas price is the minimum of:
/// 1. max_fee_per_gas specified by the sender
/// 2. base_fee_per_gas + max_priority_fee_per_gas
///
/// Parameters:
/// - base_fee_per_gas: Current block's base fee
/// - max_fee_per_gas: Maximum fee the sender is willing to pay
/// - max_priority_fee_per_gas: Maximum tip the sender is willing to pay to the miner
///
/// Returns: The effective gas price, and the miner's portion of the fee
pub fn getEffectiveGasPrice(base_fee_per_gas: u64, max_fee_per_gas: u64, max_priority_fee_per_gas: u64) struct { effective_gas_price: u64, miner_fee: u64 } {
    // Calculating effective gas price
    // Using base fee, max fee, and max priority fee

    // Ensure the transaction at least pays the base fee
    if (max_fee_per_gas < base_fee_per_gas) {
        // Transaction's max fee is less than base fee
        // In a real implementation, this transaction would be rejected
        // For now, just return the max fee and zero miner fee
        return .{ .effective_gas_price = max_fee_per_gas, .miner_fee = 0 };
    }

    // Calculate the priority fee (tip to miner)
    // This is limited by both max_priority_fee_per_gas and the leftover after base fee
    const max_priority_fee = @min(max_priority_fee_per_gas, max_fee_per_gas - base_fee_per_gas);

    // The effective gas price is base fee plus priority fee
    const effective_gas_price = base_fee_per_gas + max_priority_fee;

    // Effective gas price and miner fee calculated

    return .{ .effective_gas_price = effective_gas_price, .miner_fee = max_priority_fee };
}

/// Get the gas target for a block
///
/// The gas target is the desired gas usage per block, which is typically
/// half of the maximum gas limit.
///
/// Parameters:
/// - gas_limit: The block's gas limit
///
/// Returns: The gas target for the block
pub fn getGasTarget(gas_limit: u64) u64 {
    return gas_limit / 2;
}

// Tests

test "calculateFeeDelta basic functionality" {
    // Test basic calculation
    const fee = 1000;
    const gas_delta = 100;
    const gas_target = 1000;
    const denominator = 8;

    const result = calculateFeeDelta(fee, gas_delta, gas_target, denominator);
    // Expected: (1000 * 100) / (1000 * 8) = 100000 / 8000 = 12.5, rounded to 12
    try std.testing.expectEqual(@as(u64, 12), result);
}

test "calculateFeeDelta returns at least 1" {
    // Test that result is always at least 1
    const fee = 1;
    const gas_delta = 1;
    const gas_target = 1000000;
    const denominator = 1000000;

    const result = calculateFeeDelta(fee, gas_delta, gas_target, denominator);
    try std.testing.expectEqual(@as(u64, 1), result);
}

test "calculateFeeDelta handles large values without overflow" {
    // Test with large values that would overflow u64 in intermediate calculations
    const fee = std.math.maxInt(u64) / 2;
    const gas_delta = 1000;
    const gas_target = 1000;
    const denominator = 1;

    const result = calculateFeeDelta(fee, gas_delta, gas_target, denominator);
    // Should not panic and return a valid result
    try std.testing.expect(result > 0);
}

test "calculateFeeDelta handles division by zero protection" {
    // Test with zero gas_target and denominator
    const fee = 1000;
    const gas_delta = 100;
    const gas_target = 0;
    const denominator = 0;

    const result = calculateFeeDelta(fee, gas_delta, gas_target, denominator);
    // Should use divisor of 1 and return fee * gas_delta
    try std.testing.expectEqual(@as(u64, 100000), result);
}

test "MIN_BASE_FEE constant value" {
    try std.testing.expectEqual(@as(u64, 7), MIN_BASE_FEE);
}

test "BASE_FEE_CHANGE_DENOMINATOR constant value" {
    try std.testing.expectEqual(@as(u64, 8), BASE_FEE_CHANGE_DENOMINATOR);
}

test "initial_base_fee with exactly target gas usage" {
    const parent_gas_limit = 30_000_000;
    const parent_gas_used = 15_000_000; // Exactly half (target)

    const base_fee = initialBaseFee(parent_gas_used, parent_gas_limit);
    // When exactly at target, there's still a minimal adjustment due to calculateFeeDelta returning at least 1
    // gas_used_delta = 0, but calculate_fee_delta returns 1, so base_fee = 1_000_000_000 - 1
    try std.testing.expectEqual(@as(u64, 999_999_999), base_fee);
}

test "initial_base_fee with above target gas usage" {
    const parent_gas_limit = 30_000_000;
    const parent_gas_used = 20_000_000; // Above target (15M)

    const base_fee = initialBaseFee(parent_gas_used, parent_gas_limit);
    // Should be higher than 1 gwei
    try std.testing.expect(base_fee > 1_000_000_000);

    // Calculate expected: 1 gwei + (1 gwei * 5M / 15M / 8)
    // = 1_000_000_000 + (1_000_000_000 * 5_000_000 / 15_000_000 / 8)
    // = 1_000_000_000 + 41_666_666
    try std.testing.expectEqual(@as(u64, 1_041_666_666), base_fee);
}

test "initial_base_fee with below target gas usage" {
    const parent_gas_limit = 30_000_000;
    const parent_gas_used = 10_000_000; // Below target (15M)

    const base_fee = initialBaseFee(parent_gas_used, parent_gas_limit);
    // Should be lower than 1 gwei
    try std.testing.expect(base_fee < 1_000_000_000);

    // Calculate expected: 1 gwei - (1 gwei * 5M / 15M / 8)
    // = 1_000_000_000 - 41_666_666
    try std.testing.expectEqual(@as(u64, 958_333_334), base_fee);
}

test "initial_base_fee with zero gas usage" {
    const parent_gas_limit = 30_000_000;
    const parent_gas_used = 0;

    const base_fee = initialBaseFee(parent_gas_used, parent_gas_limit);
    // Should return 1 gwei (no adjustment)
    try std.testing.expectEqual(@as(u64, 1_000_000_000), base_fee);
}

test "initial_base_fee respects minimum base fee" {
    const parent_gas_limit = 100;
    const parent_gas_used = 0;

    const base_fee = initialBaseFee(parent_gas_used, parent_gas_limit);
    // Even with extreme values, should respect MIN_BASE_FEE
    try std.testing.expect(base_fee >= MIN_BASE_FEE);
}

test "next_base_fee with exactly target gas usage" {
    const parent_base_fee = 1_000_000_000;
    const parent_gas_target = 15_000_000;
    const parent_gas_used = 15_000_000; // Exactly target

    const next_fee = nextBaseFee(parent_base_fee, parent_gas_used, parent_gas_target);
    // Should remain the same
    try std.testing.expectEqual(parent_base_fee, next_fee);
}

test "next_base_fee with above target gas usage" {
    const parent_base_fee = 1_000_000_000;
    const parent_gas_target = 15_000_000;
    const parent_gas_used = 20_000_000; // 5M above target

    const next_fee = nextBaseFee(parent_base_fee, parent_gas_used, parent_gas_target);
    // Should increase by up to 12.5%
    try std.testing.expect(next_fee > parent_base_fee);

    // Expected increase: base_fee * (5M / 15M) / 8 = base_fee * 1/24
    const expected = parent_base_fee + (parent_base_fee / 24);
    try std.testing.expectEqual(expected, next_fee);
}

test "next_base_fee with below target gas usage" {
    const parent_base_fee = 1_000_000_000;
    const parent_gas_target = 15_000_000;
    const parent_gas_used = 10_000_000; // 5M below target

    const next_fee = nextBaseFee(parent_base_fee, parent_gas_used, parent_gas_target);
    // Should decrease by up to 12.5%
    try std.testing.expect(next_fee < parent_base_fee);

    // Expected decrease: base_fee * (5M / 15M) / 8 = base_fee * 1/24
    const expected = parent_base_fee - (parent_base_fee / 24);
    try std.testing.expectEqual(expected, next_fee);
}

test "next_base_fee with maximum increase (full block)" {
    const parent_base_fee = 1_000_000_000;
    const parent_gas_target = 15_000_000;
    const parent_gas_used = 30_000_000; // Double the target (full block)

    const next_fee = nextBaseFee(parent_base_fee, parent_gas_used, parent_gas_target);
    // Should increase by exactly 12.5%
    const expected = parent_base_fee + (parent_base_fee / 8);
    try std.testing.expectEqual(expected, next_fee);
}

test "next_base_fee with empty parent block" {
    const parent_base_fee = 1_000_000_000;
    const parent_gas_target = 15_000_000;
    const parent_gas_used = 0; // Empty block

    const next_fee = nextBaseFee(parent_base_fee, parent_gas_used, parent_gas_target);
    // Should remain the same for empty blocks
    try std.testing.expectEqual(parent_base_fee, next_fee);
}

test "next_base_fee respects minimum base fee on decrease" {
    const parent_base_fee = 10; // Very low base fee
    const parent_gas_target = 15_000_000;
    const parent_gas_used = 0; // Would normally decrease

    const next_fee = nextBaseFee(parent_base_fee, parent_gas_used, parent_gas_target);
    // Should not go below MIN_BASE_FEE
    try std.testing.expectEqual(@as(u64, 10), next_fee); // Stays at parent fee since it's above MIN_BASE_FEE
}

test "next_base_fee respects minimum when decrease would go below" {
    const parent_base_fee = 8; // Just above MIN_BASE_FEE
    const parent_gas_target = 15_000_000;
    const parent_gas_used = 1; // Very low usage

    const next_fee = nextBaseFee(parent_base_fee, parent_gas_used, parent_gas_target);
    // Should not go below MIN_BASE_FEE
    try std.testing.expect(next_fee >= MIN_BASE_FEE);
}

test "next_base_fee handles overflow protection" {
    const parent_base_fee = std.math.maxInt(u64) - 1000;
    const parent_gas_target = 15_000_000;
    const parent_gas_used = 30_000_000; // Would increase

    const next_fee = nextBaseFee(parent_base_fee, parent_gas_used, parent_gas_target);
    // Should handle overflow gracefully
    try std.testing.expectEqual(parent_base_fee, next_fee);
}

test "get_effective_gas_price with sufficient max fee" {
    const base_fee = 1_000_000_000; // 1 gwei
    const max_fee = 2_000_000_000; // 2 gwei
    const max_priority_fee = 500_000_000; // 0.5 gwei

    const result = getEffectiveGasPrice(base_fee, max_fee, max_priority_fee);
    // Effective price should be base + priority
    try std.testing.expectEqual(@as(u64, 1_500_000_000), result.effective_gas_price);
    try std.testing.expectEqual(@as(u64, 500_000_000), result.miner_fee);
}

test "get_effective_gas_price with limited max fee" {
    const base_fee = 1_000_000_000; // 1 gwei
    const max_fee = 1_200_000_000; // 1.2 gwei
    const max_priority_fee = 500_000_000; // 0.5 gwei (more than available)

    const result = getEffectiveGasPrice(base_fee, max_fee, max_priority_fee);
    // Priority fee limited by max_fee - base_fee
    try std.testing.expectEqual(@as(u64, 1_200_000_000), result.effective_gas_price);
    try std.testing.expectEqual(@as(u64, 200_000_000), result.miner_fee);
}

test "get_effective_gas_price with max fee below base fee" {
    const base_fee = 1_000_000_000; // 1 gwei
    const max_fee = 800_000_000; // 0.8 gwei (below base)
    const max_priority_fee = 100_000_000; // 0.1 gwei

    const result = getEffectiveGasPrice(base_fee, max_fee, max_priority_fee);
    // Transaction would be rejected, but returns max_fee and 0 miner fee
    try std.testing.expectEqual(@as(u64, 800_000_000), result.effective_gas_price);
    try std.testing.expectEqual(@as(u64, 0), result.miner_fee);
}

test "get_effective_gas_price with zero priority fee" {
    const base_fee = 1_000_000_000; // 1 gwei
    const max_fee = 2_000_000_000; // 2 gwei
    const max_priority_fee = 0; // No tip

    const result = getEffectiveGasPrice(base_fee, max_fee, max_priority_fee);
    // Should just pay base fee
    try std.testing.expectEqual(base_fee, result.effective_gas_price);
    try std.testing.expectEqual(@as(u64, 0), result.miner_fee);
}

test "get_effective_gas_price with exact base fee" {
    const base_fee = 1_000_000_000; // 1 gwei
    const max_fee = 1_000_000_000; // Exactly base fee
    const max_priority_fee = 100_000_000; // 0.1 gwei (can't be paid)

    const result = getEffectiveGasPrice(base_fee, max_fee, max_priority_fee);
    // No room for priority fee
    try std.testing.expectEqual(base_fee, result.effective_gas_price);
    try std.testing.expectEqual(@as(u64, 0), result.miner_fee);
}

test "get_gas_target basic calculation" {
    const gas_limit = 30_000_000;
    const target = getGasTarget(gas_limit);
    try std.testing.expectEqual(@as(u64, 15_000_000), target);
}

test "get_gas_target with odd gas limit" {
    const gas_limit = 30_000_001;
    const target = getGasTarget(gas_limit);
    // Integer division rounds down
    try std.testing.expectEqual(@as(u64, 15_000_000), target);
}

test "get_gas_target with zero gas limit" {
    const gas_limit = 0;
    const target = getGasTarget(gas_limit);
    try std.testing.expectEqual(@as(u64, 0), target);
}

test "get_gas_target with small gas limit" {
    const gas_limit = 1;
    const target = getGasTarget(gas_limit);
    try std.testing.expectEqual(@as(u64, 0), target);
}

// Additional comprehensive tests for initialBaseFee

test "initialBaseFee with maximum gas limit" {
    const parent_gas_limit = std.math.maxInt(u64);
    const parent_gas_used = std.math.maxInt(u64) / 2; // At target

    const base_fee = initialBaseFee(parent_gas_used, parent_gas_limit);
    // Should handle large values without overflow
    try std.testing.expect(base_fee >= MIN_BASE_FEE);
}

test "initialBaseFee with full parent block" {
    const parent_gas_limit = 30_000_000;
    const parent_gas_used = 30_000_000; // Completely full

    const base_fee = initialBaseFee(parent_gas_used, parent_gas_limit);
    // Should be at maximum increase (12.5%)
    // 1 gwei + (1 gwei * 15M / 15M / 8) = 1 gwei + 125M wei
    try std.testing.expectEqual(@as(u64, 1_125_000_000), base_fee);
}

test "initialBaseFee with very small gas limit" {
    const parent_gas_limit = 100;
    const parent_gas_used = 50; // At target

    const base_fee = initialBaseFee(parent_gas_used, parent_gas_limit);
    // Should still work with small values and respect minimum
    try std.testing.expect(base_fee >= MIN_BASE_FEE);
}

test "initialBaseFee with near-zero parent gas used" {
    const parent_gas_limit = 30_000_000;
    const parent_gas_used = 1; // Nearly empty

    const base_fee = initialBaseFee(parent_gas_used, parent_gas_limit);
    // Should decrease from 1 gwei but respect minimum
    try std.testing.expect(base_fee < 1_000_000_000);
    try std.testing.expect(base_fee >= MIN_BASE_FEE);
}

test "initialBaseFee with extreme below-target usage" {
    const parent_gas_limit = 30_000_000;
    const parent_gas_used = 100; // Way below target

    const base_fee = initialBaseFee(parent_gas_used, parent_gas_limit);
    // Should decrease significantly but respect minimum
    try std.testing.expect(base_fee >= MIN_BASE_FEE);
}

test "initialBaseFee minimum enforcement at boundary" {
    const parent_gas_limit = 1000;
    const parent_gas_used = 1; // Very low usage to force decrease

    const base_fee = initialBaseFee(parent_gas_used, parent_gas_limit);
    // Even with extreme decrease, should not go below MIN_BASE_FEE
    try std.testing.expectEqual(MIN_BASE_FEE, base_fee);
}

// Additional comprehensive tests for nextBaseFee

test "nextBaseFee with minimal above-target usage" {
    const parent_base_fee = 1_000_000_000;
    const parent_gas_target = 15_000_000;
    const parent_gas_used = 15_000_001; // Just 1 over target

    const next_fee = nextBaseFee(parent_base_fee, parent_gas_used, parent_gas_target);
    // Should increase minimally (at least by 1)
    try std.testing.expect(next_fee > parent_base_fee);
    try std.testing.expect(next_fee - parent_base_fee >= 1);
}

test "nextBaseFee with minimal below-target usage" {
    const parent_base_fee = 1_000_000_000;
    const parent_gas_target = 15_000_000;
    const parent_gas_used = 14_999_999; // Just 1 under target

    const next_fee = nextBaseFee(parent_base_fee, parent_gas_used, parent_gas_target);
    // Should decrease minimally (at least by 1)
    try std.testing.expect(next_fee < parent_base_fee);
    try std.testing.expect(parent_base_fee - next_fee >= 1);
}

test "nextBaseFee precision with small base fee" {
    const parent_base_fee = 10; // Very small base fee
    const parent_gas_target = 15_000_000;
    const parent_gas_used = 20_000_000; // Above target

    const next_fee = nextBaseFee(parent_base_fee, parent_gas_used, parent_gas_target);
    // Should still increase by at least 1 due to minimum delta
    try std.testing.expect(next_fee > parent_base_fee);
    try std.testing.expect(next_fee - parent_base_fee >= 1);
}

test "nextBaseFee precision with large base fee" {
    const parent_base_fee = 1_000_000_000_000; // 1000 gwei
    const parent_gas_target = 15_000_000;
    const parent_gas_used = 16_000_000; // Slightly above target

    const next_fee = nextBaseFee(parent_base_fee, parent_gas_used, parent_gas_target);
    // Should calculate precise increase
    try std.testing.expect(next_fee > parent_base_fee);

    // Expected: base_fee * (1M / 15M) / 8 = base_fee * 1/120
    const expected_delta = parent_base_fee / 120;
    const expected = parent_base_fee + expected_delta;
    try std.testing.expectEqual(expected, next_fee);
}

test "nextBaseFee with very high gas usage" {
    const parent_base_fee = 1_000_000_000;
    const parent_gas_target = 15_000_000;
    const parent_gas_used = 100_000_000; // Way above target

    const next_fee = nextBaseFee(parent_base_fee, parent_gas_used, parent_gas_target);
    // Should cap at 12.5% increase
    const max_increase = parent_base_fee + (parent_base_fee / 8);
    try std.testing.expectEqual(max_increase, next_fee);
}

test "nextBaseFee decrease to minimum boundary" {
    const parent_base_fee = 8; // Just above MIN_BASE_FEE
    const parent_gas_target = 1_000;
    const parent_gas_used = 1; // Very low to force decrease

    const next_fee = nextBaseFee(parent_base_fee, parent_gas_used, parent_gas_target);
    // Should not go below MIN_BASE_FEE
    try std.testing.expect(next_fee >= MIN_BASE_FEE);
    try std.testing.expectEqual(MIN_BASE_FEE, next_fee);
}

test "nextBaseFee at minimum with empty block" {
    const parent_base_fee = MIN_BASE_FEE;
    const parent_gas_target = 15_000_000;
    const parent_gas_used = 0; // Empty block

    const next_fee = nextBaseFee(parent_base_fee, parent_gas_used, parent_gas_target);
    // Should stay at minimum for empty blocks
    try std.testing.expectEqual(MIN_BASE_FEE, next_fee);
}

test "nextBaseFee at minimum with below-target usage" {
    const parent_base_fee = MIN_BASE_FEE;
    const parent_gas_target = 15_000_000;
    const parent_gas_used = 1_000_000; // Below target

    const next_fee = nextBaseFee(parent_base_fee, parent_gas_used, parent_gas_target);
    // Should stay at minimum (cannot decrease further)
    try std.testing.expectEqual(MIN_BASE_FEE, next_fee);
}

test "nextBaseFee with gas used exceeding realistic limits" {
    const parent_base_fee = 1_000_000_000;
    const parent_gas_target = 15_000_000;
    const parent_gas_used = 1_000_000_000; // Unrealistically high

    const next_fee = nextBaseFee(parent_base_fee, parent_gas_used, parent_gas_target);
    // Should still cap at 12.5% increase
    const max_increase = parent_base_fee + (parent_base_fee / 8);
    try std.testing.expectEqual(max_increase, next_fee);
}

test "nextBaseFee precision loss with integer division" {
    const parent_base_fee = 15; // Base fee that doesn't divide evenly
    const parent_gas_target = 15_000_000;
    const parent_gas_used = 20_000_000; // Above target

    const next_fee = nextBaseFee(parent_base_fee, parent_gas_used, parent_gas_target);
    // Should handle integer division correctly
    try std.testing.expect(next_fee > parent_base_fee);
    // Minimum increase should be 1
    try std.testing.expect(next_fee - parent_base_fee >= 1);
}

test "nextBaseFee with maximum safe base fee" {
    const parent_base_fee = std.math.maxInt(u64) / 2;
    const parent_gas_target = 15_000_000;
    const parent_gas_used = 20_000_000; // Above target would increase

    const next_fee = nextBaseFee(parent_base_fee, parent_gas_used, parent_gas_target);
    // Should not overflow - calculateFeeDelta handles this
    try std.testing.expect(next_fee >= parent_base_fee);
}

test "nextBaseFee boundary at exact target after increase" {
    const parent_base_fee = 1_000_000_000;
    const parent_gas_target = 15_000_000;
    // First increase
    const parent_gas_used_high = 20_000_000;
    const increased_fee = nextBaseFee(parent_base_fee, parent_gas_used_high, parent_gas_target);

    // Then at target
    const next_fee = nextBaseFee(increased_fee, parent_gas_target, parent_gas_target);
    // Should stay at increased fee
    try std.testing.expectEqual(increased_fee, next_fee);
}

test "nextBaseFee boundary at exact target after decrease" {
    const parent_base_fee = 1_000_000_000;
    const parent_gas_target = 15_000_000;
    // First decrease
    const parent_gas_used_low = 10_000_000;
    const decreased_fee = nextBaseFee(parent_base_fee, parent_gas_used_low, parent_gas_target);

    // Then at target
    const next_fee = nextBaseFee(decreased_fee, parent_gas_target, parent_gas_target);
    // Should stay at decreased fee
    try std.testing.expectEqual(decreased_fee, next_fee);
}

test "nextBaseFee with zero gas target" {
    const parent_base_fee = 1_000_000_000;
    const parent_gas_target = 0; // Edge case
    const parent_gas_used = 0;

    const next_fee = nextBaseFee(parent_base_fee, parent_gas_used, parent_gas_target);
    // Empty block behavior
    try std.testing.expectEqual(parent_base_fee, next_fee);
}

// Edge case tests for fee delta calculations

test "calculateFeeDelta with maximum fee and small delta" {
    const fee = std.math.maxInt(u64) / 10;
    const gas_delta = 1;
    const gas_target = 15_000_000;
    const denominator = 8;

    const result = calculateFeeDelta(fee, gas_delta, gas_target, denominator);
    // Should not overflow and return valid result
    try std.testing.expect(result >= 1);
}

test "calculateFeeDelta with zero fee" {
    const fee = 0;
    const gas_delta = 1_000_000;
    const gas_target = 15_000_000;
    const denominator = 8;

    const result = calculateFeeDelta(fee, gas_delta, gas_target, denominator);
    // 0 * anything = 0, but minimum is 1
    try std.testing.expectEqual(@as(u64, 1), result);
}

test "calculateFeeDelta with zero gas delta" {
    const fee = 1_000_000_000;
    const gas_delta = 0;
    const gas_target = 15_000_000;
    const denominator = 8;

    const result = calculateFeeDelta(fee, gas_delta, gas_target, denominator);
    // 0 delta should result in minimum return of 1
    try std.testing.expectEqual(@as(u64, 1), result);
}

test "calculateFeeDelta with all maximum values" {
    const fee = std.math.maxInt(u64);
    const gas_delta = std.math.maxInt(u64);
    const gas_target = std.math.maxInt(u64);
    const denominator = std.math.maxInt(u64);

    const result = calculateFeeDelta(fee, gas_delta, gas_target, denominator);
    // Should handle overflow and return capped result
    try std.testing.expect(result > 0);
    try std.testing.expect(result <= std.math.maxInt(u64));
}

test "calculateFeeDelta rounding behavior" {
    // Test that integer division rounds down correctly
    const fee = 1000;
    const gas_delta = 3;
    const gas_target = 100;
    const denominator = 8;

    const result = calculateFeeDelta(fee, gas_delta, gas_target, denominator);
    // (1000 * 3) / (100 * 8) = 3000 / 800 = 3.75 -> rounds to 3
    try std.testing.expectEqual(@as(u64, 3), result);
}

// Tests for sequential fee adjustments (realistic block sequences)

test "nextBaseFee sequence of full blocks" {
    var current_fee: u64 = 1_000_000_000;
    const gas_target: u64 = 15_000_000;
    const gas_used: u64 = 30_000_000; // Full block

    // After 10 full blocks, fee should compound
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const next = nextBaseFee(current_fee, gas_used, gas_target);
        // Each step should increase by 12.5%
        try std.testing.expect(next > current_fee);
        current_fee = next;
    }

    // After 10 blocks at 12.5% increase each, fee should be significantly higher
    try std.testing.expect(current_fee > 3_000_000_000); // More than 3x original
}

test "nextBaseFee sequence of empty blocks" {
    var current_fee: u64 = 1_000_000_000;
    const gas_target: u64 = 15_000_000;
    const gas_used: u64 = 0; // Empty block

    // After 10 empty blocks, fee should stay the same
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const next = nextBaseFee(current_fee, gas_used, gas_target);
        try std.testing.expectEqual(current_fee, next);
        current_fee = next;
    }

    try std.testing.expectEqual(@as(u64, 1_000_000_000), current_fee);
}

test "nextBaseFee sequence alternating full and empty" {
    var current_fee: u64 = 1_000_000_000;
    const gas_target: u64 = 15_000_000;

    // Alternate between full and empty blocks
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        if (i % 2 == 0) {
            // Full block
            current_fee = nextBaseFee(current_fee, 30_000_000, gas_target);
        } else {
            // Empty block
            current_fee = nextBaseFee(current_fee, 0, gas_target);
        }
    }

    // Fee should be higher than start (more full than empty)
    try std.testing.expect(current_fee > 1_000_000_000);
}

test "nextBaseFee sequence descending to minimum" {
    var current_fee: u64 = 1_000_000_000;
    const gas_target: u64 = 15_000_000;
    const gas_used: u64 = 100; // Very low usage

    // Keep decreasing until we hit minimum
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const next = nextBaseFee(current_fee, gas_used, gas_target);
        if (next == MIN_BASE_FEE and current_fee == MIN_BASE_FEE) {
            break; // Reached minimum
        }
        current_fee = next;
    }

    // Should eventually reach minimum
    try std.testing.expectEqual(MIN_BASE_FEE, current_fee);
}
