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
pub const fromBytes = hash.fromBytes;
pub const fromSlice = hash.fromSlice;
pub const fromHex = hash.fromHex;
pub const fromHexComptime = hash.fromHexComptime;
pub const toHex = hash.toHex;
pub const toHexUpper = hash.toHexUpper;
pub const isZero = hash.isZero;
pub const equal = hash.equal;
pub const keccak256 = hash.keccak256;
pub const keccak256Empty = hash.keccak256Empty;
pub const eip191HashMessage = hash.eip191HashMessage;
pub const selectorFromSignature = hash.selectorFromSignature;
pub const compare = hash.compare;
pub const lessThan = hash.lessThan;
pub const greaterThan = hash.greaterThan;
pub const xor = hash.xor;
pub const bitAnd = hash.bitAnd;
pub const bitOr = hash.bitOr;
pub const bitNot = hash.bitNot;
pub const toU256 = hash.toU256;
pub const fromU256 = hash.fromU256;

// Tests to verify the module works
const std = @import("std");

test "hash module integration" {
    // Test basic hash creation
    const test_hash = keccak256("test");
    try std.testing.expect(!isZero(test_hash));

    // Test selector creation
    const sel = selectorFromSignature("transfer(address,uint256)");
    const expected = [4]u8{ 0xa9, 0x05, 0x9c, 0xbb };
    try std.testing.expectEqual(expected, sel);
}
