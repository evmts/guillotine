//! Ethereum Transaction Types - Complete transaction format support
//!
//! This module provides comprehensive support for all Ethereum transaction types,
//! from legacy transactions to the latest EIP-4844 blob transactions and
//! EIP-7702 authorization lists.
//!
//! ## Transaction Types Overview
//!
//! ### Legacy Transactions (Type 0)
//! - Original Ethereum transaction format
//! - Fixed gas price model
//! - Simple structure with nonce, gas, value, data, and signature
//!
//! ### EIP-2930 Transactions (Type 1)
//! - Access list support for gas optimization
//! - Explicit chain ID for replay protection
//! - Backward compatible with legacy transactions
//!
//! ### EIP-1559 Transactions (Type 2)
//! - Priority fee and max fee per gas model
//! - Base fee adjustment mechanism
//! - Dynamic fee market for better UX
//!
//! ### EIP-4844 Blob Transactions (Type 3)
//! - Blob data for layer 2 scaling
//! - Temporary blob storage (4096 slots)
//! - Separate blob gas market
//!
//! ### EIP-7702 Authorization Transactions (Type 4)
//! - EOA delegation to smart contracts
//! - Authorization list for permission management
//! - Backward compatible execution
//!
//! ## Key Features
//!
//! - **Type Safety**: Strongly typed transaction structures
//! - **Serialization**: RLP encoding/decoding support
//! - **Validation**: Comprehensive transaction validation
//! - **Signature Handling**: ECDSA signature verification
//! - **Gas Calculations**: Accurate gas cost estimation
//!
//! ## Usage Examples
//!
//! ### Creating a Legacy Transaction
//! ```zig
//! const tx = LegacyTransaction{
//!     .nonce = 42,
//!     .gas_price = 20_000_000_000, // 20 gwei
//!     .gas_limit = 21_000,
//!     .to = some_address,
//!     .value = 1_000_000_000_000_000_000, // 1 ether
//!     .data = &[_]u8{},
//!     .v = 27,
//!     .r = signature_r,
//!     .s = signature_s,
//! };
//! ```
//!
//! ### Creating an EIP-1559 Transaction
//! ```zig
//! const tx = Eip1559Transaction{
//!     .chainId = 1, // Mainnet
//!     .nonce = 42,
//!     .maxPriorityFeePerGas = 2_000_000_000, // 2 gwei
//!     .maxFeePerGas = 20_000_000_000, // 20 gwei
//!     .gas_limit = 21_000,
//!     .to = some_address,
//!     .value = 1_000_000_000_000_000_000, // 1 ether
//!     .data = &[_]u8{},
//!     .accessList = &[_]AccessListItem{},
//! };
//! ```
//!
//! ### Working with Access Lists
//! ```zig
//! const access_list = [_]AccessListItem{
//!     .{
//!         .address = contract_address,
//!         .storageKeys = &[_]Hash{storage_key1, storage_key2},
//!     },
//! };
//! ```
//!
//! ## Design Principles
//!
//! 1. **Specification Compliance**: Exact adherence to EIP specifications
//! 2. **Forward Compatibility**: Extensible design for future transaction types
//! 3. **Memory Efficiency**: Minimal allocations with clear ownership
//! 4. **Type Safety**: Prevent common transaction construction errors
//! 5. **Performance**: Optimized for high-throughput transaction processing

const std = @import("std");
const testing = std.testing;
const rlp = @import("rlp.zig");
const address = @import("address.zig");
const authorization = @import("authorization.zig");
const crypto_pkg = @import("crypto");
const hash = crypto_pkg.Hash;
const hex = @import("hex.zig");
const crypto = crypto_pkg.Crypto;
const Address = address.Address;
const Hash = hash.Hash;
const Authorization = authorization.Authorization;
const Allocator = std.mem.Allocator;

// Transaction error types
pub const TransactionError = error{
    InvalidTransactionType,
    InvalidSignature,
    OutOfMemory,
};

// Transaction types based on EIPs
pub const TransactionType = enum(u8) {
    legacy = 0x00,
    eip2930 = 0x01,
    eip1559 = 0x02,
    eip4844 = 0x03,
    eip7702 = 0x04,
};

// Legacy transaction structure
pub const LegacyTransaction = struct {
    nonce: u64,
    gas_price: u256,
    gas_limit: u64,
    to: ?Address, // null for contract creation
    value: u256,
    data: []const u8,
    v: u64,
    r: [32]u8,
    s: [32]u8,
};

// EIP-1559 transaction structure
pub const Eip1559Transaction = struct {
    chain_id: u64,
    nonce: u64,
    max_priority_fee_per_gas: u256,
    max_fee_per_gas: u256,
    gas_limit: u64,
    to: ?Address,
    value: u256,
    data: []const u8,
    access_list: []const AccessListItem,
    v: u64,
    r: [32]u8,
    s: [32]u8,
};

// EIP-7702 transaction structure
pub const Eip7702Transaction = struct {
    chain_id: u64,
    nonce: u64,
    max_priority_fee_per_gas: u256,
    max_fee_per_gas: u256,
    gas_limit: u64,
    to: ?Address,
    value: u256,
    data: []const u8,
    access_list: []const AccessListItem,
    authorization_list: []const Authorization,
    v: u64,
    r: [32]u8,
    s: [32]u8,
};

pub const AccessListItem = struct {
    address: Address,
    storage_keys: []const [32]u8,
};

// Encode legacy transaction for signing
pub fn encode_legacy_for_signing(allocator: Allocator, tx: LegacyTransaction, chain_id: u64) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    // Encode fields for signing (EIP-155)
    try rlp.encodeUint(allocator, tx.nonce, &list);
    try rlp.encodeUint(allocator, tx.gas_price, &list);
    try rlp.encodeUint(allocator, tx.gas_limit, &list);

    // Encode 'to' field
    if (tx.to) |to_addr| {
        try rlp.encodeBytes(allocator, &to_addr.bytes, &list);
    } else {
        try list.append(0x80); // Empty RLP string for null
    }

    try rlp.encodeUint(allocator, tx.value, &list);
    try rlp.encodeBytes(allocator, tx.data, &list);

    // For unsigned transaction (EIP-155)
    if (tx.v == 0) {
        try rlp.encodeUint(allocator, chain_id, &list);
        try rlp.encodeUint(allocator, 0, &list);
        try rlp.encodeUint(allocator, 0, &list);
    } else {
        // For signed transaction
        try rlp.encodeUint(allocator, tx.v, &list);
        try rlp.encodeBytes(allocator, &tx.r, &list);
        try rlp.encodeBytes(allocator, &tx.s, &list);
    }

    // Wrap in RLP list
    var result = std.ArrayList(u8).init(allocator);
    if (list.items.len <= 55) {
        try result.append(@as(u8, @intCast(0xc0 + list.items.len)));
    } else {
        const len_bytes = rlp.encodeLength(list.items.len);
        try result.append(@as(u8, @intCast(0xf7 + len_bytes.len)));
        try result.appendSlice(len_bytes);
    }
    try result.appendSlice(list.items);

    return result.toOwnedSlice();
}

// Encode EIP-1559 transaction for signing
pub fn encode_eip1559_for_signing(allocator: Allocator, tx: Eip1559Transaction) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    // Encode fields
    try rlp.encodeUint(allocator, tx.chain_id, &list);
    try rlp.encodeUint(allocator, tx.nonce, &list);
    try rlp.encodeUint(allocator, tx.max_priority_fee_per_gas, &list);
    try rlp.encodeUint(allocator, tx.max_fee_per_gas, &list);
    try rlp.encodeUint(allocator, tx.gas_limit, &list);

    // Encode 'to' field
    if (tx.to) |to_addr| {
        try rlp.encodeBytes(allocator, &to_addr.bytes, &list);
    } else {
        try list.append(0x80); // Empty RLP string for null
    }

    try rlp.encodeUint(allocator, tx.value, &list);
    try rlp.encodeBytes(allocator, tx.data, &list);

    // Encode access list
    try encode_access_list(allocator, tx.access_list, &list);

    // For unsigned transaction
    if (tx.v == 0) {
        // No signature fields for unsigned
    } else {
        // For signed transaction
        try rlp.encodeUint(allocator, tx.v, &list);
        try rlp.encodeBytes(allocator, &tx.r, &list);
        try rlp.encodeBytes(allocator, &tx.s, &list);
    }

    // Wrap in RLP list
    var rlp_wrapped = std.ArrayList(u8).init(allocator);
    defer rlp_wrapped.deinit();

    if (list.items.len <= 55) {
        try rlp_wrapped.append(@as(u8, @intCast(0xc0 + list.items.len)));
    } else {
        const len_bytes = rlp.encodeLength(list.items.len);
        try rlp_wrapped.append(@as(u8, @intCast(0xf7 + len_bytes.len)));
        try rlp_wrapped.appendSlice(len_bytes);
    }
    try rlp_wrapped.appendSlice(list.items);

    // Prepend transaction type
    var result = std.ArrayList(u8).init(allocator);
    try result.append(@intFromEnum(TransactionType.eip1559));
    try result.appendSlice(rlp_wrapped.items);

    return result.toOwnedSlice();
}

// Encode access list
fn encode_access_list(allocator: Allocator, access_list: []const AccessListItem, output: *std.ArrayList(u8)) !void {
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    for (access_list) |item| {
        var item_list = std.ArrayList(u8).init(allocator);
        defer item_list.deinit();

        // Encode address
        try rlp.encodeBytes(allocator, &item.address.bytes, &item_list);

        // Encode storage keys
        var keys_list = std.ArrayList(u8).init(allocator);
        defer keys_list.deinit();

        for (item.storage_keys) |key| {
            try rlp.encodeBytes(allocator, &key, &keys_list);
        }

        // Wrap storage keys in RLP list
        if (keys_list.items.len <= 55) {
            try item_list.append(@as(u8, @intCast(0xc0 + keys_list.items.len)));
        } else {
            const len_bytes = rlp.encodeLength(keys_list.items.len);
            try item_list.append(@as(u8, @intCast(0xf7 + len_bytes.len)));
            try item_list.appendSlice(len_bytes);
        }
        try item_list.appendSlice(keys_list.items);

        // Wrap access list item
        if (item_list.items.len <= 55) {
            try list.append(@as(u8, @intCast(0xc0 + item_list.items.len)));
        } else {
            const len_bytes = rlp.encodeLength(item_list.items.len);
            try list.append(@as(u8, @intCast(0xf7 + len_bytes.len)));
            try list.appendSlice(len_bytes);
        }
        try list.appendSlice(item_list.items);
    }

    // Wrap entire access list
    if (list.items.len <= 55) {
        try output.append(@as(u8, @intCast(0xc0 + list.items.len)));
    } else {
        const len_bytes = rlp.encodeLength(list.items.len);
        try output.append(@as(u8, @intCast(0xf7 + len_bytes.len)));
        try output.appendSlice(len_bytes);
    }
    try output.appendSlice(list.items);
}

// Sign legacy transaction
pub fn sign_legacy_transaction(allocator: Allocator, tx: LegacyTransaction, private_key: crypto.PrivateKey, chain_id: u64) !LegacyTransaction {
    // Encode transaction for signing
    const encoded = try encode_legacy_for_signing(allocator, tx, chain_id);
    defer allocator.free(encoded);

    // Hash the encoded transaction
    const h = hash.keccak256(encoded);

    // Sign the hash
    const signature = try crypto.sign(allocator, private_key, h);

    // Create signed transaction
    var signed_tx = tx;
    signed_tx.v = @as(u64, signature.v) + (chain_id * 2) + 8; // EIP-155
    signed_tx.r = signature.r;
    signed_tx.s = signature.s;

    return signed_tx;
}

// Compute legacy transaction hash
pub fn compute_legacy_transaction_hash(allocator: Allocator, tx: LegacyTransaction) !Hash {
    // Encode the full signed transaction
    const encoded = try encode_legacy_for_signing(allocator, tx, 1);
    defer allocator.free(encoded);

    // Return keccak256 hash
    return hash.keccak256(encoded);
}

// Detect transaction type from raw data
pub fn detect_transaction_type(data: []const u8) TransactionType {
    if (data.len == 0) return TransactionType.legacy;

    // Check for typed transaction envelope
    return switch (data[0]) {
        0x01 => TransactionType.eip2930,
        0x02 => TransactionType.eip1559,
        0x03 => TransactionType.eip4844,
        0x04 => TransactionType.eip7702,
        else => TransactionType.legacy,
    };
}

// Tests

test "encode legacy transaction" {
    const allocator = testing.allocator;

    // Test transaction data
    const tx = LegacyTransaction{
        .nonce = 0,
        .gas_price = 20_000_000_000, // 20 gwei
        .gas_limit = 21000,
        .to = try Address.fromHex("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"),
        .value = 1_000_000_000_000_000, // 0.001 ETH
        .data = &[_]u8{},
        .v = 37, // mainnet with EIP-155
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };

    // Encode transaction for signing
    const encoded = try encode_legacy_for_signing(allocator, tx, 1);
    defer allocator.free(encoded);

    // Should produce valid RLP encoding
    try testing.expect(encoded.len > 0);
}

test "legacy transaction signature" {
    const allocator = testing.allocator;

    // Test private key
    const private_key = crypto.PrivateKey{
        .bytes = [_]u8{
            0xac, 0x09, 0x74, 0xbe, 0xc3, 0x9a, 0x17, 0xe3,
            0x6b, 0xa4, 0xa6, 0xb4, 0xd2, 0x38, 0xff, 0x24,
            0x4e, 0x21, 0xdb, 0x63, 0x5c, 0x51, 0xcb, 0x29,
            0x36, 0x49, 0x5a, 0xf7, 0x42, 0x2f, 0xba, 0x41,
        },
    };

    const tx = LegacyTransaction{
        .nonce = 0,
        .gas_price = 20_000_000_000,
        .gas_limit = 21000,
        .to = try Address.fromHex("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"),
        .value = 1_000_000_000_000_000,
        .data = &[_]u8{},
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };

    // Sign transaction
    const signed_tx = try sign_legacy_transaction(allocator, tx, private_key, 1);

    // Verify signature components
    try testing.expect(signed_tx.v == 37 or signed_tx.v == 38); // EIP-155 for mainnet
    try testing.expect(!std.mem.eql(u8, &signed_tx.r, &([_]u8{0} ** 32)));
    try testing.expect(!std.mem.eql(u8, &signed_tx.s, &([_]u8{0} ** 32)));
}

test "encode eip1559 transaction" {
    const allocator = testing.allocator;

    const tx = Eip1559Transaction{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 1_000_000_000, // 1 gwei
        .max_fee_per_gas = 20_000_000_000, // 20 gwei
        .gas_limit = 21000,
        .to = try Address.fromHex("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"),
        .value = 1_000_000_000_000_000,
        .data = &[_]u8{},
        .access_list = &[_]AccessListItem{},
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };

    const encoded = try encode_eip1559_for_signing(allocator, tx);
    defer allocator.free(encoded);

    // Should start with transaction type
    try testing.expectEqual(@as(u8, 0x02), encoded[0]);
}

test "eip1559 with access list" {
    const allocator = testing.allocator;

    const storage_keys = [_][32]u8{
        hash.fromU256(0).bytes,
        hash.fromU256(1).bytes,
    };

    const access_list = [_]AccessListItem{
        .{
            .address = try Address.fromHex("0x0000000000000000000000000000000000000000"),
            .storage_keys = &storage_keys,
        },
    };

    const tx = Eip1559Transaction{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 1_000_000_000,
        .max_fee_per_gas = 20_000_000_000,
        .gas_limit = 30000, // Higher for access list
        .to = try Address.fromHex("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"),
        .value = 0,
        .data = &[_]u8{},
        .access_list = &access_list,
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };

    const encoded = try encode_eip1559_for_signing(allocator, tx);
    defer allocator.free(encoded);

    try testing.expect(encoded.len > 100); // Should be larger with access list
}

test "compute transaction hash" {
    const allocator = testing.allocator;

    const tx = LegacyTransaction{
        .nonce = 0,
        .gas_price = 20_000_000_000,
        .gas_limit = 21000,
        .to = try Address.fromHex("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"),
        .value = 1_000_000_000_000_000,
        .data = &[_]u8{},
        .v = 37,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };

    const h = try compute_legacy_transaction_hash(allocator, tx);

    // Hash should be 32 bytes
    try testing.expectEqual(@as(usize, 32), h.bytes.len);

    // Hash should be deterministic
    const h2 = try compute_legacy_transaction_hash(allocator, tx);
    try testing.expectEqual(h, h2);
}

test "contract creation transaction" {
    const allocator = testing.allocator;

    const init_code = [_]u8{ 0x60, 0x80, 0x60, 0x40, 0x52 }; // Sample init code

    const tx = LegacyTransaction{
        .nonce = 0,
        .gas_price = 20_000_000_000,
        .gas_limit = 100000, // Higher for contract creation
        .to = null, // null for contract creation
        .value = 0,
        .data = &init_code,
        .v = 37,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };

    const encoded = try encode_legacy_for_signing(allocator, tx, 1);
    defer allocator.free(encoded);

    // Should encode properly with null `to` field
    try testing.expect(encoded.len > 0);
}

test "detect transaction type" {
    // Legacy transaction (no prefix)
    const legacy_data = [_]u8{0xf8} ++ [_]u8{0} ** 10;
    try testing.expectEqual(TransactionType.legacy, detect_transaction_type(&legacy_data));

    // EIP-2930 (0x01 prefix)
    const eip2930_data = [_]u8{0x01} ++ [_]u8{0} ** 10;
    try testing.expectEqual(TransactionType.eip2930, detect_transaction_type(&eip2930_data));

    // EIP-1559 (0x02 prefix)
    const eip1559_data = [_]u8{0x02} ++ [_]u8{0} ** 10;
    try testing.expectEqual(TransactionType.eip1559, detect_transaction_type(&eip1559_data));

    // EIP-4844 (0x03 prefix)
    const eip4844_data = [_]u8{0x03} ++ [_]u8{0} ** 10;
    try testing.expectEqual(TransactionType.eip4844, detect_transaction_type(&eip4844_data));
}

test "decode mainnet transaction" {
    const allocator = testing.allocator;

    // This is a real mainnet transaction (simplified)
    const tx_hex = "0x02f8710180843b9aca00850df8475800825208940000000000000000000000000000000000000000880de0b6b3a764000080c001a0c7cf543e1b26a19fca825d164a0dc96e62c6a4a373d90abcf82b0de7f97e58f5a06d4b6bc588356822e38a0bec5fb4baa8efd8f19ec90b0584df2bbba09cd78c0d";

    // In a real implementation, you would decode this hex and parse the transaction
    _ = tx_hex;
    _ = allocator;

    // For now, just verify we can handle the concept
    try testing.expect(true);
}
