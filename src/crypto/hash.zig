// Hash module - comprehensive hash types and utilities for Ethereum
// Based on Alloy's hash implementation with Zig optimizations

pub const hash = @import("hash_utils.zig");

// Re-export main types
pub const Hash = hash.Hash;
pub const B256 = hash.B256;
pub const BlockHash = hash.BlockHash;
pub const TxHash = hash.TxHash;
pub const StorageKey = hash.StorageKey;
pub const StorageValue = hash.StorageValue;
pub const Selector = hash.Selector;

// Re-export constants
pub const ZERO_HASH = hash.ZERO_HASH;
pub const EMPTY_KECCAK256 = hash.EMPTY_KECCAK256;

// Re-export core functions
pub const zero = hash.zero;
pub const from_bytes = hash.fromBytes;
pub const from_slice = hash.fromSlice;
pub const from_hex = hash.fromHex;
pub const from_hex_comptime = hash.fromHexComptime;
pub const to_hex = hash.toHex;
pub const to_hex_upper = hash.toHexUpper;
pub const is_zero = hash.isZero;
pub const equal = hash.equal;
pub const keccak256 = hash.keccak256;
pub const keccak256_empty = hash.keccak256Empty;
pub const sha256 = hash.sha256;
pub const eip191_hash_message = hash.eip191HashMessage;
pub const selector_from_signature = hash.selectorFromSignature;
pub const compare = hash.compare;
pub const less_than = hash.lessThan;
pub const greater_than = hash.greaterThan;
pub const xor = hash.xor;
pub const bit_and = hash.bitAnd;
pub const bit_or = hash.bitOr;
pub const bit_not = hash.bitNot;
pub const to_u256 = hash.toU256;
pub const from_u256 = hash.fromU256;

// Tests to verify the module works
const std = @import("std");

test "hash module integration" {
    // Test basic hash creation
    const test_hash = keccak256("test");
    try std.testing.expect(!is_zero(test_hash));

    // Test selector creation
    const sel = selector_from_signature("transfer(address,uint256)");
    const expected = [4]u8{ 0xa9, 0x05, 0x9c, 0xbb };
    try std.testing.expectEqual(expected, sel);
}
