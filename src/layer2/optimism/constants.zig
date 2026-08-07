//! Optimism constants used in L1 fee calculations.
//!
//! Based on the Rust implementation from op-revm:
//! https://github.com/bluealloy/revm/blob/main/crates/op-revm/src/constants.rs

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

// Contract addresses
pub const L1_BLOCK_ADDRESS: Address = Address.fromU256(0x4200000000000000000000000000000000000015);
pub const L1_FEE_RECIPIENT: Address = Address.fromU256(0x420000000000000000000000000000000000001A);
pub const BASE_FEE_RECIPIENT: Address = Address.fromU256(0x4200000000000000000000000000000000000019);
pub const OPERATOR_FEE_RECIPIENT: Address = Address.fromU256(0x420000000000000000000000000000000000001B);

// Storage slots
pub const L1_BASE_FEE_SLOT: u256 = 1;
pub const L1_OVERHEAD_SLOT: u256 = 5;
pub const L1_SCALAR_SLOT: u256 = 6;
pub const ECOTONE_L1_BLOB_BASE_FEE_SLOT: u256 = 7;
pub const ECOTONE_L1_FEE_SCALARS_SLOT: u256 = 3;
pub const OPERATOR_FEE_SCALARS_SLOT: u256 = 8;

// Slot aliases for tryFetch compatibility
pub const L1_BLOB_BASE_FEE_SLOT: u256 = ECOTONE_L1_BLOB_BASE_FEE_SLOT;
pub const ECOTONE_SCALARS_SLOT: u256 = ECOTONE_L1_FEE_SCALARS_SLOT;
pub const OPERATOR_FEE_SLOT: u256 = OPERATOR_FEE_SCALARS_SLOT;

// Gas costs
pub const NON_ZERO_BYTE_GAS: u64 = 16;
pub const ZERO_BYTE_GAS: u64 = 4;

// Ecotone scalar offsets
pub const BASE_FEE_SCALAR_OFFSET: usize = 16;
pub const BLOB_BASE_FEE_SCALAR_OFFSET: usize = 20;

// Isthmus operator fee scalar offsets
pub const OPERATOR_FEE_SCALAR_OFFSET: usize = 20;
pub const OPERATOR_FEE_CONSTANT_OFFSET: usize = 24;

// Operator fee scalar decimal precision
pub const OPERATOR_FEE_SCALAR_DECIMAL: u64 = 1_000_000;

// Empty scalars constant
pub const EMPTY_SCALARS: [8]u8 = [_]u8{0} ** 8;

// Fjord compression estimation constants
// https://github.com/ethereum-optimism/op-geth/blob/647c346e2bef36219cc7b47d76b1cb87e7ca29e4/core/types/rollup_cost.go#L79
pub const FJORD_COMPRESSION_INTERCEPT: u64 = 836_500;

// https://github.com/ethereum-optimism/op-geth/blob/647c346e2bef36219cc7b47d76b1cb87e7ca29e4/core/types/rollup_cost.go#L78
pub const FJORD_MIN_TX_SIZE: u64 = 42_585_600;

// https://github.com/ethereum-optimism/op-geth/blob/647c346e2bef36219cc7b47d76b1cb87e7ca29e4/core/types/rollup_cost.go#82
pub const FJORD_MAX_TX_SIZE: u64 = 100 * 1_000_000;

// https://github.com/ethereum-optimism/op-geth/blob/647c346e2bef36219cc7b47d76b1cb87e7ca29e4/core/types/rollup_cost.go#L77
pub const FJORD_COMPRESSION_RATIO: u64 = 6;

// Tests
test "constants - scalar offsets" {
    try std.testing.expectEqual(@as(usize, 16), BASE_FEE_SCALAR_OFFSET);
    try std.testing.expectEqual(@as(usize, 20), BLOB_BASE_FEE_SCALAR_OFFSET);
    try std.testing.expectEqual(@as(usize, 20), OPERATOR_FEE_SCALAR_OFFSET);
    try std.testing.expectEqual(@as(usize, 24), OPERATOR_FEE_CONSTANT_OFFSET);
}

test "constants - gas costs" {
    try std.testing.expectEqual(@as(u64, 16), NON_ZERO_BYTE_GAS);
    try std.testing.expectEqual(@as(u64, 4), ZERO_BYTE_GAS);
    try std.testing.expectEqual(@as(u64, 1_000_000), OPERATOR_FEE_SCALAR_DECIMAL);
}

test "constants - fjord compression" {
    try std.testing.expectEqual(@as(u64, 836_500), FJORD_COMPRESSION_INTERCEPT);
    try std.testing.expectEqual(@as(u64, 42_585_600), FJORD_MIN_TX_SIZE);
    try std.testing.expectEqual(@as(u64, 100_000_000), FJORD_MAX_TX_SIZE);
    try std.testing.expectEqual(@as(u64, 6), FJORD_COMPRESSION_RATIO);
}

test "constants - addresses" {
    try std.testing.expectEqual(@as(u256, 0x4200000000000000000000000000000000000015), L1_BLOCK_ADDRESS.toU256());
    try std.testing.expectEqual(@as(u256, 0x420000000000000000000000000000000000001A), L1_FEE_RECIPIENT.toU256());
    try std.testing.expectEqual(@as(u256, 0x4200000000000000000000000000000000000019), BASE_FEE_RECIPIENT.toU256());
    try std.testing.expectEqual(@as(u256, 0x420000000000000000000000000000000000001B), OPERATOR_FEE_RECIPIENT.toU256());
}

test "constants - storage slots" {
    try std.testing.expectEqual(@as(u256, 1), L1_BASE_FEE_SLOT);
    try std.testing.expectEqual(@as(u256, 5), L1_OVERHEAD_SLOT);
    try std.testing.expectEqual(@as(u256, 6), L1_SCALAR_SLOT);
    try std.testing.expectEqual(@as(u256, 7), ECOTONE_L1_BLOB_BASE_FEE_SLOT);
    try std.testing.expectEqual(@as(u256, 3), ECOTONE_L1_FEE_SCALARS_SLOT);
    try std.testing.expectEqual(@as(u256, 8), OPERATOR_FEE_SCALARS_SLOT);
}

test "constants - empty scalars" {
    for (EMPTY_SCALARS) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}
