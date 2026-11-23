//! Jovian DA footprint block limit.
//!
//! Spec: https://specs.optimism.io/protocol/jovian/exec-engine.html#da-footprint-block-limit
//! op-revm: `encoded_tx_da_footprint` in rust/op-revm/src/transaction/mod.rs
//!
//!   txDaFootprint  = 0 for deposits, else
//!                    max(100e6, fastlzSize*836_500 - 42_585_600) / 1e6 * daFootprintGasScalar
//!   daFootprint    = sum of txDaFootprint over the block
//!   header.blobGasUsed = daFootprint, and daFootprint <= gasLimit
//!   base fee update uses gasMetered = max(gasUsed, blobGasUsed)

const std = @import("std");
const constants = @import("constants.zig");
const l1_block_info = @import("l1_block_info.zig");

pub const DaFootprintError = error{
    /// Block DA footprint exceeds the block gas limit.
    DaFootprintExceedsGasLimit,
};

/// DA footprint of one EIP-2718 encoded transaction (type byte included).
pub fn txDaFootprint(encoded_2718: []const u8, da_footprint_gas_scalar: u16) u64 {
    if (encoded_2718.len > 0 and encoded_2718[0] == constants.DEPOSIT_TRANSACTION_TYPE) return 0;
    return (l1_block_info.estimatedSizeFjord(encoded_2718) / 1_000_000) *| da_footprint_gas_scalar;
}

/// Sum of the DA footprints of a block's transactions (saturating).
pub fn blockDaFootprint(encoded_txs: []const []const u8, da_footprint_gas_scalar: u16) u64 {
    var total: u64 = 0;
    for (encoded_txs) |tx| total +|= txDaFootprint(tx, da_footprint_gas_scalar);
    return total;
}

/// Header validation: the block DA footprint must not exceed the gas limit.
pub fn validateBlockDaFootprint(da_footprint: u64, gas_limit: u64) DaFootprintError!void {
    if (da_footprint > gas_limit) return error.DaFootprintExceedsGasLimit;
}

/// Gas value fed to the EIP-1559 base fee update from Jovian on.
pub fn gasMetered(gas_used: u64, blob_gas_used: u64) u64 {
    return @max(gas_used, blob_gas_used);
}

const testing = std.testing;

test "deposit transactions have zero DA footprint" {
    const deposit = [_]u8{0x7E} ++ [_]u8{0xAB} ** 1000;
    try testing.expectEqual(@as(u64, 0), txDaFootprint(&deposit, 400));
}

test "small transaction uses the 100-byte minimum size" {
    // 3 bytes compress to 4: 4*836_500 - 42_585_600 < 0, so the estimate is the 100e6 floor.
    const tx = [_]u8{ 0x02, 0xCA, 0xDE };
    try testing.expectEqual(@as(u64, 100 * 400), txDaFootprint(&tx, 400));
    try testing.expectEqual(@as(u64, 100), txDaFootprint(&tx, 1));
}

test "DA footprint floors the size before scaling" {
    // Random-looking 400-byte payload: footprint = floor(estimate / 1e6) * scalar.
    var tx: [400]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(&tx);
    tx[0] = 0x02;
    const estimate = l1_block_info.estimatedSizeFjord(&tx);
    try testing.expect(estimate > 100_000_000);
    try testing.expectEqual((estimate / 1_000_000) * 400, txDaFootprint(&tx, 400));
}

test "block DA footprint sums non-deposit transactions" {
    const user = [_]u8{ 0x02, 0x01 };
    const deposit = [_]u8{ 0x7E, 0x01 };
    const txs = [_][]const u8{ &user, &deposit, &user };
    try testing.expectEqual(@as(u64, 2 * 100 * 400), blockDaFootprint(&txs, 400));
}

test "block DA footprint limit" {
    try validateBlockDaFootprint(30_000_000, 30_000_000);
    try testing.expectError(error.DaFootprintExceedsGasLimit, validateBlockDaFootprint(30_000_001, 30_000_000));
}

test "gasMetered is max of gas used and blob gas used" {
    try testing.expectEqual(@as(u64, 10), gasMetered(10, 3));
    try testing.expectEqual(@as(u64, 12), gasMetered(10, 12));
}
