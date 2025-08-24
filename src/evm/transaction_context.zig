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
};

test "TransactionContext creation and field access" {
    const coinbase_addr = [_]u8{0x01} ++ [_]u8{0x00} ** 19;
    
    const tx_context = TransactionContext{
        .gas_limit = 21000,
        .coinbase = coinbase_addr,
        .chain_id = 1,
    };
    
    try std.testing.expectEqual(@as(u64, 21000), tx_context.gas_limit);
    try std.testing.expectEqual(coinbase_addr, tx_context.coinbase);
    try std.testing.expectEqual(@as(u16, 1), tx_context.chain_id);
}

test "TransactionContext with maximum values" {
    const max_addr = [_]u8{0xFF} ** 20;
    const max_tx_context = TransactionContext{
        .gas_limit = std.math.maxInt(u64),
        .coinbase = max_addr,
        .chain_id = std.math.maxInt(u16),
    };
    
    try std.testing.expectEqual(std.math.maxInt(u64), max_tx_context.gas_limit);
    try std.testing.expectEqual(max_addr, max_tx_context.coinbase);
    try std.testing.expectEqual(std.math.maxInt(u16), max_tx_context.chain_id);
}

test "TransactionContext with zero values" {
    const zero_addr = [_]u8{0} ** 20;
    const zero_tx_context = TransactionContext{
        .gas_limit = 0,
        .coinbase = zero_addr,
        .chain_id = 0,
    };
    
    try std.testing.expectEqual(@as(u64, 0), zero_tx_context.gas_limit);
    try std.testing.expectEqual(zero_addr, zero_tx_context.coinbase);
    try std.testing.expectEqual(@as(u16, 0), zero_tx_context.chain_id);
}