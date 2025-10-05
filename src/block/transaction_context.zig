//! Transaction-level context for EVM execution.

const std = @import("std");
const Address = @import("primitives").Address.Address;

/// Transaction execution context.
///
/// Contains immutable transaction parameters that remain constant
/// throughout the entire transaction execution.
pub const TransactionContext = struct {
    /// Transaction gas limit
    gas_limit: u64,
    /// Coinbase address (miner/validator)
    coinbase: Address,
    /// Chain ID - supports chain IDs up to 65535
    /// NOTE: chain_id is used by the CHAINID opcode
    chain_id: u16,
    /// Blob versioned hashes for EIP-4844 blob transactions
    /// Empty slice for non-blob transactions
    blob_versioned_hashes: []const [32]u8 = &.{},
    /// Blob base fee for EIP-4844
    /// Set to 0 for non-Cancun hardforks
    /// TODO: this is a block-level setting (and already present in BlockInfo), should be removed
    blob_base_fee: u256 = 0,
};

test "TransactionContext creation and field access" {
    const coinbase_addr = Address{ .bytes = [_]u8{0x01} ++ [_]u8{0x00} ** 19 };
    
    const tx_context = TransactionContext{
        .gas_limit = 21000,
        .coinbase = coinbase_addr,
        .chain_id = 1,
    };
    
    try std.testing.expectEqual(@as(u64, 21000), tx_context.gas_limit);
    try std.testing.expectEqual(coinbase_addr, tx_context.coinbase);
    try std.testing.expectEqual(@as(u16, 1), tx_context.chain_id);
    try std.testing.expectEqual(@as(usize, 0), tx_context.blob_versioned_hashes.len);
    try std.testing.expectEqual(@as(u256, 0), tx_context.blob_base_fee);
}

test "TransactionContext with maximum values" {
    const max_addr = Address{ .bytes = [_]u8{0xFF} ** 20 };
    const max_tx_context = TransactionContext{
        .gas_limit = std.math.maxInt(u64),
        .coinbase = max_addr,
        .chain_id = std.math.maxInt(u16),
        .blob_base_fee = std.math.maxInt(u256),
    };
    
    try std.testing.expectEqual(std.math.maxInt(u64), max_tx_context.gas_limit);
    try std.testing.expectEqual(max_addr, max_tx_context.coinbase);
    try std.testing.expectEqual(std.math.maxInt(u16), max_tx_context.chain_id);
    try std.testing.expectEqual(std.math.maxInt(u256), max_tx_context.blob_base_fee);
}

test "TransactionContext with zero values" {
    const zero_addr = Address{ .bytes = [_]u8{0} ** 20 };
    const zero_tx_context = TransactionContext{
        .gas_limit = 0,
        .coinbase = zero_addr,
        .chain_id = 0,
    };
    
    try std.testing.expectEqual(@as(u64, 0), zero_tx_context.gas_limit);
    try std.testing.expectEqual(zero_addr, zero_tx_context.coinbase);
    try std.testing.expectEqual(@as(u16, 0), zero_tx_context.chain_id);
}

test "TransactionContext with blob data (EIP-4844)" {
    const coinbase_addr = Address{ .bytes = [_]u8{0x01} ++ [_]u8{0x00} ** 19 };
    const blob_hash1 = [_]u8{0x01} ** 32;
    const blob_hash2 = [_]u8{0x02} ** 32;
    const blob_hashes = [_][32]u8{ blob_hash1, blob_hash2 };
    
    const blob_tx_context = TransactionContext{
        .gas_limit = 30_000_000,
        .coinbase = coinbase_addr,
        .chain_id = 1,
        .blob_versioned_hashes = &blob_hashes,
        .blob_base_fee = 1_000_000_000, // 1 gwei
    };
    
    try std.testing.expectEqual(@as(u64, 30_000_000), blob_tx_context.gas_limit);
    try std.testing.expectEqual(coinbase_addr, blob_tx_context.coinbase);
    try std.testing.expectEqual(@as(u16, 1), blob_tx_context.chain_id);
    try std.testing.expectEqual(@as(usize, 2), blob_tx_context.blob_versioned_hashes.len);
    try std.testing.expectEqual(blob_hash1, blob_tx_context.blob_versioned_hashes[0]);
    try std.testing.expectEqual(blob_hash2, blob_tx_context.blob_versioned_hashes[1]);
    try std.testing.expectEqual(@as(u256, 1_000_000_000), blob_tx_context.blob_base_fee);
}
