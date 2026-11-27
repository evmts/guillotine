//! Transaction-level context for EVM execution.

const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;

/// One EIP-2930 access list entry: an address and the storage keys of it that the
/// transaction declares up front. The address and every key start the transaction warm.
pub const AccessListEntry = struct {
    address: Address,
    storage_keys: []const u256 = &.{},
};

/// One EIP-7702 authorization tuple `(chain_id, address, nonce, y_parity, r, s)`.
pub const Authorization = primitives.Authorization.Authorization;

/// Transaction execution context.
///
/// Contains immutable transaction parameters that remain constant
/// throughout the entire transaction execution.
pub const TransactionContext = struct {
    /// Transaction gas limit
    gas_limit: u64,
    /// Coinbase address (miner/validator)
    coinbase: Address,
    /// Chain ID (EIP-155). Real chain IDs exceed 16 bits (for example
    /// 11155111 for Sepolia), so the full u64 range is supported.
    /// NOTE: chain_id is used by the CHAINID opcode
    chain_id: u64,
    /// Blob versioned hashes for EIP-4844 blob transactions
    /// Empty slice for non-blob transactions
    blob_versioned_hashes: []const [32]u8 = &.{},
    /// Deprecated compatibility field. Blob base fee is block-level and EVM
    /// execution reads BlockInfo.blob_base_fee exclusively.
    blob_base_fee: u256 = 0,
    /// Whether the transaction is an EIP-4844 type-3 transaction.
    /// This remains distinct from blob_versioned_hashes so zero-blob type-3
    /// transactions can be rejected.
    is_blob_transaction: bool = false,
    /// EIP-1559 fee cap used for the effective gas price and the upfront
    /// balance check. Null for legacy transactions, whose gas_price is
    /// already their fee cap.
    max_fee_per_gas: ?u256 = null,
    /// EIP-1559 priority fee cap (tip). Zero for legacy transactions.
    max_priority_fee_per_gas: u256 = 0,
    /// EIP-4844 fee cap used for validation and the upfront balance check.
    max_fee_per_blob_gas: u256 = 0,
    /// EIP-2930 access list (Berlin+). Each address costs 2,400 and each storage key
    /// 1,900 intrinsic gas, and all of them start the transaction warm. A non-empty
    /// list before Berlin makes the transaction invalid. The slices are borrowed:
    /// they must outlive every `Evm.call` made with this context.
    access_list: []const AccessListEntry = &.{},
    /// EIP-7702 authorization list (Prague+). Each tuple costs 25,000 intrinsic gas,
    /// is applied before execution and refunds 12,500 when its authority already
    /// exists. A non-empty list before Prague makes the transaction invalid.
    /// Borrowed, like `access_list`.
    authorization_list: []const Authorization = &.{},
    /// Whether the transaction is an EIP-7702 type-4 transaction. Distinct from
    /// `authorization_list` so that a type-4 transaction with an empty list can be
    /// rejected, as the EIP requires.
    is_set_code_transaction: bool = false,
    /// The nonce the transaction was signed with. When set, `Evm.call` rejects the
    /// transaction unless it equals the sender's account nonce. Null (the default)
    /// skips the comparison and uses the account nonce, for callers that do not
    /// track nonces.
    tx_nonce: ?u64 = null,
    /// Simulation only (`eth_call` with a zero gas price). From London a transaction
    /// whose gas price is below the block base fee is invalid, and `Evm.call`
    /// rejects it. Setting this accepts such a legacy-priced call; the block
    /// producer is then paid nothing per gas. Never set it for a transaction that
    /// is to be included in a block.
    allow_gas_price_below_base_fee: bool = false,
};

test "TransactionContext creation and field access" {
    const coinbase_addr = Address{ .bytes = [_]u8{0x01} ++ @as([19]u8, @splat(0x00)) };

    const tx_context = TransactionContext{
        .gas_limit = 21000,
        .coinbase = coinbase_addr,
        .chain_id = 1,
    };

    try std.testing.expectEqual(@as(u64, 21000), tx_context.gas_limit);
    try std.testing.expectEqual(coinbase_addr, tx_context.coinbase);
    try std.testing.expectEqual(@as(u64, 1), tx_context.chain_id);
    try std.testing.expectEqual(@as(usize, 0), tx_context.blob_versioned_hashes.len);
    try std.testing.expect(!tx_context.is_blob_transaction);
    try std.testing.expectEqual(@as(?u256, null), tx_context.max_fee_per_gas);
    try std.testing.expectEqual(@as(u256, 0), tx_context.max_priority_fee_per_gas);
    try std.testing.expectEqual(@as(u256, 0), tx_context.max_fee_per_blob_gas);
    // The transaction-level lists default to "none", so callers that never set
    // them keep their behavior.
    try std.testing.expectEqual(@as(usize, 0), tx_context.access_list.len);
    try std.testing.expectEqual(@as(usize, 0), tx_context.authorization_list.len);
    try std.testing.expect(!tx_context.is_set_code_transaction);
    try std.testing.expectEqual(@as(?u64, null), tx_context.tx_nonce);
    try std.testing.expect(!tx_context.allow_gas_price_below_base_fee);
}

test "TransactionContext carries an access list, an authorization list and a nonce" {
    const target = Address{ .bytes = [_]u8{0xAA} ++ @as([19]u8, @splat(0x00)) };
    const keys = [_]u256{ 1, 2 };
    const access_list = [_]AccessListEntry{
        .{ .address = target, .storage_keys = &keys },
        .{ .address = Address{ .bytes = @as([20]u8, @splat(0xBB)) } },
    };
    const authorizations = [_]Authorization{.{
        .chain_id = 1,
        .address = target,
        .nonce = 7,
        .v = 1,
        .r = @as([32]u8, @splat(1)),
        .s = @as([32]u8, @splat(2)),
    }};
    const tx_context = TransactionContext{
        .gas_limit = 100_000,
        .coinbase = target,
        .chain_id = 1,
        .access_list = &access_list,
        .authorization_list = &authorizations,
        .is_set_code_transaction = true,
        .tx_nonce = 41,
    };
    try std.testing.expectEqual(@as(usize, 2), tx_context.access_list.len);
    try std.testing.expectEqual(@as(usize, 2), tx_context.access_list[0].storage_keys.len);
    try std.testing.expectEqual(@as(usize, 0), tx_context.access_list[1].storage_keys.len);
    try std.testing.expectEqual(@as(u64, 7), tx_context.authorization_list[0].nonce);
    try std.testing.expect(tx_context.is_set_code_transaction);
    try std.testing.expectEqual(@as(?u64, 41), tx_context.tx_nonce);
}

test "TransactionContext with maximum values" {
    const max_addr = Address{ .bytes = @as([20]u8, @splat(0xFF)) };
    const max_tx_context = TransactionContext{
        .gas_limit = std.math.maxInt(u64),
        .coinbase = max_addr,
        .chain_id = std.math.maxInt(u64),
        .max_fee_per_gas = std.math.maxInt(u256),
        .max_fee_per_blob_gas = std.math.maxInt(u256),
    };

    try std.testing.expectEqual(std.math.maxInt(u64), max_tx_context.gas_limit);
    try std.testing.expectEqual(max_addr, max_tx_context.coinbase);
    try std.testing.expectEqual(std.math.maxInt(u64), max_tx_context.chain_id);
    try std.testing.expectEqual(std.math.maxInt(u256), max_tx_context.max_fee_per_gas.?);
    try std.testing.expectEqual(std.math.maxInt(u256), max_tx_context.max_fee_per_blob_gas);
}

test "TransactionContext with zero values" {
    const zero_addr = Address{ .bytes = @as([20]u8, @splat(0)) };
    const zero_tx_context = TransactionContext{
        .gas_limit = 0,
        .coinbase = zero_addr,
        .chain_id = 0,
    };

    try std.testing.expectEqual(@as(u64, 0), zero_tx_context.gas_limit);
    try std.testing.expectEqual(zero_addr, zero_tx_context.coinbase);
    try std.testing.expectEqual(@as(u64, 0), zero_tx_context.chain_id);
}

test "TransactionContext with blob data (EIP-4844)" {
    const coinbase_addr = Address{ .bytes = [_]u8{0x01} ++ @as([19]u8, @splat(0x00)) };
    const blob_hash1 = @as([32]u8, @splat(0x01));
    const blob_hash2 = @as([32]u8, @splat(0x02));
    const blob_hashes = [_][32]u8{ blob_hash1, blob_hash2 };

    const blob_tx_context = TransactionContext{
        .gas_limit = 30_000_000,
        .coinbase = coinbase_addr,
        .chain_id = 1,
        .blob_versioned_hashes = &blob_hashes,
        .is_blob_transaction = true,
        .max_fee_per_blob_gas = 1_000_000_000, // 1 gwei
    };

    try std.testing.expectEqual(@as(u64, 30_000_000), blob_tx_context.gas_limit);
    try std.testing.expectEqual(coinbase_addr, blob_tx_context.coinbase);
    try std.testing.expectEqual(@as(u64, 1), blob_tx_context.chain_id);
    try std.testing.expectEqual(@as(usize, 2), blob_tx_context.blob_versioned_hashes.len);
    try std.testing.expectEqual(blob_hash1, blob_tx_context.blob_versioned_hashes[0]);
    try std.testing.expectEqual(blob_hash2, blob_tx_context.blob_versioned_hashes[1]);
    try std.testing.expect(blob_tx_context.is_blob_transaction);
    try std.testing.expectEqual(@as(u256, 1_000_000_000), blob_tx_context.max_fee_per_blob_gas);
}

test "TransactionContext holds chain IDs wider than 16 bits" {
    const sepolia = TransactionContext{
        .gas_limit = 21000,
        .coinbase = Address{ .bytes = @as([20]u8, @splat(0)) },
        .chain_id = 11155111,
    };
    try std.testing.expectEqual(@as(u64, 11155111), sepolia.chain_id);
    try std.testing.expectEqual(u64, @TypeOf(sepolia.chain_id));
}
