const std = @import("std");
const testing = std.testing;
const transaction_types = @import("transaction_types.zig");
const rlp = @import("primitives/rlp/rlp.zig");
const hex = @import("primitives/hex.zig");

// Re-export core types with correct names
pub const TxType = transaction_types.TxType;
pub const TypedTransaction = transaction_types.TypedTransaction;
pub const TxLegacy = transaction_types.TxLegacy;
pub const TxEip1559 = transaction_types.TxEip1559;
pub const TxEip2930 = transaction_types.TxEip2930;
pub const TxEip4844 = transaction_types.TxEip4844;
pub const TxEip7702 = transaction_types.TxEip7702;
pub const SignedTransaction = transaction_types.SignedTransaction;
pub const TransactionEnvelope = transaction_types.TransactionEnvelope;
pub const Signature = transaction_types.Signature;
pub const Address = transaction_types.Address;
pub const B256 = transaction_types.B256;
pub const U256 = transaction_types.U256;
pub const ChainId = transaction_types.ChainId;
pub const AccessList = transaction_types.AccessList;
pub const SignedAuthorization = transaction_types.SignedAuthorization;
pub const TxKind = transaction_types.TxKind;

/// Transaction building errors
pub const TransactionBuildingError = error{
    InvalidTransactionType,
    SerializationError,
    DeserializationError,
    InvalidChainId,
    InvalidData,
    OutOfMemory,
};

/// Transaction request for building transactions
pub const TransactionRequest = struct {
    from: ?Address = null,
    to: ?TxKind = null,
    gas: ?u64 = null,
    gas_price: ?U256 = null,
    max_fee_per_gas: ?U256 = null,
    max_priority_fee_per_gas: ?U256 = null,
    value: ?U256 = null,
    data: ?[]const u8 = null,
    nonce: ?u64 = null,
    chain_id: ?ChainId = null,
    access_list: ?AccessList = null,
    transaction_type: ?TxType = null,

    /// Convert request to appropriate transaction type
    pub fn to_transaction(self: TransactionRequest) !TypedTransaction {
        const tx_type = self.transaction_type orelse .legacy;

        switch (tx_type) {
            .legacy => {
                return TypedTransaction{
                    .legacy = TxLegacy{
                        .chain_id = self.chain_id,
                        .nonce = self.nonce orelse 0,
                        .gas_price = @truncate(self.gas_price orelse 20000000000), // 20 gwei default
                        .gas_limit = self.gas orelse 21000,
                        .to = self.to orelse TxKind.create,
                        .value = self.value orelse 0,
                        .input = &.{}, // Simplified to empty for now
                    },
                };
            },
            .eip1559 => {
                return TypedTransaction{
                    .eip1559 = TxEip1559{
                        .chain_id = self.chain_id orelse 1,
                        .nonce = self.nonce orelse 0,
                        .max_priority_fee_per_gas = @truncate(self.max_priority_fee_per_gas orelse 1000000000), // 1 gwei
                        .max_fee_per_gas = @truncate(self.max_fee_per_gas orelse 20000000000), // 20 gwei
                        .gas_limit = self.gas orelse 21000,
                        .to = self.to orelse TxKind.create,
                        .value = self.value orelse 0,
                        .input = &.{}, // Simplified to empty for now
                        .access_list = self.access_list orelse &.{},
                    },
                };
            },
            else => return TransactionBuildingError.InvalidTransactionType,
        }
    }
};

/// Simple transaction builder
pub const TransactionBuilder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TransactionBuilder {
        return TransactionBuilder{ .allocator = allocator };
    }

    /// Build a transaction from a request
    pub fn build_transaction(_: *TransactionBuilder, request: TransactionRequest) !TypedTransaction {
        return try request.to_transaction();
    }

    /// Prepare transaction request with default values
    pub fn prepare_transaction_request(_: *TransactionBuilder, request: TransactionRequest) TransactionRequest {
        var prepared = request;

        // Set default gas limit if not provided
        if (prepared.gas == null) {
            prepared.gas = if (prepared.data != null and prepared.data.?.len > 0) 100000 else 21000;
        }

        // Set default transaction type if not provided
        if (prepared.transaction_type == null) {
            prepared.transaction_type = if (prepared.max_fee_per_gas != null) .eip1559 else .legacy;
        }

        return prepared;
    }

    /// Sign a transaction (placeholder implementation)
    pub fn sign_transaction(_: *TransactionBuilder, tx: TypedTransaction, _: [32]u8) !SignedTransaction {
        // Placeholder signature
        const signature = Signature{
            .y_parity = false,
            .r = 0x123456789abcdef,
            .s = 0xfedcba987654321,
        };

        return SignedTransaction{
            .transaction = tx,
            .signature = signature,
        };
    }

    /// Get transaction hash (placeholder)
    pub fn get_transaction_hash(_: *TransactionBuilder, _: TypedTransaction) !B256 {
        // Placeholder hash
        var hash: B256 = undefined;
        @memset(&hash, 0x42);
        return hash;
    }

    /// Serialize transaction to hex string (placeholder)
    pub fn to_hex(self: *TransactionBuilder, envelope: TransactionEnvelope) ![]u8 {
        // Simplified serialization - just return a placeholder hex string
        _ = envelope;
        return try self.allocator.dupe(u8, "0x1234567890abcdef");
    }
};

/// Utility functions for transaction building
pub const TransactionUtils = struct {
    /// Estimate gas for a transaction
    pub fn estimate_gas(tx: TypedTransaction) u64 {
        switch (tx) {
            .legacy => |legacy| {
                const base_gas: u64 = 21000;
                const data_gas = @as(u64, @intCast(legacy.input.len)) * 16; // Simplified calculation
                return base_gas + data_gas;
            },
            .eip1559 => |eip1559| {
                const base_gas: u64 = 21000;
                const data_gas = @as(u64, @intCast(eip1559.input.len)) * 16;
                return base_gas + data_gas;
            },
            else => return 21000,
        }
    }

    /// Check if transaction is a contract creation
    pub fn is_contract_creation(tx: TypedTransaction) bool {
        switch (tx) {
            .legacy => |legacy| return legacy.to.is_create(),
            .eip1559 => |eip1559| return eip1559.to.is_create(),
            .eip2930 => |eip2930| return eip2930.to.is_create(),
            else => return false,
        }
    }

    /// Get transaction type
    pub fn get_transaction_type(tx: TypedTransaction) TxType {
        return switch (tx) {
            .legacy => .legacy,
            .eip2930 => .eip2930,
            .eip1559 => .eip1559,
            .eip4844 => .eip4844,
            .eip7702 => .eip7702,
        };
    }
};

// Tests
test "transaction request to transaction conversion" {
    const request = TransactionRequest{
        .to = TxKind{ .call = [_]u8{0} ** 20 },
        .value = 1000000000000000000, // 1 ETH in wei
        .gas = 21000,
        .gas_price = 20000000000, // 20 gwei
        .nonce = 0,
        .transaction_type = .legacy,
    };

    const tx = try request.to_transaction();
    try testing.expect(tx == .legacy);
    try testing.expectEqual(1000000000000000000, tx.legacy.value);
    try testing.expectEqual(21000, tx.legacy.gas_limit);
}

test "transaction builder" {
    var builder = TransactionBuilder.init(testing.allocator);

    const request = TransactionRequest{
        .to = TxKind{ .call = [_]u8{0} ** 20 },
        .value = 1000000000000000000,
        .gas = 21000,
        .max_fee_per_gas = 20000000000,
        .max_priority_fee_per_gas = 1000000000,
        .nonce = 0,
        .transaction_type = .eip1559,
    };

    const tx = try builder.build_transaction(request);
    try testing.expect(tx == .eip1559);
    try testing.expectEqual(21000, tx.eip1559.gas_limit);
}

test "transaction utils" {
    const legacy_tx = TypedTransaction{
        .legacy = TxLegacy{
            .chain_id = 1,
            .nonce = 0,
            .gas_price = 20000000000,
            .gas_limit = 21000,
            .to = TxKind.create,
            .value = 0,
            .input = &.{},
        },
    };

    try testing.expect(TransactionUtils.is_contract_creation(legacy_tx));
    try testing.expectEqual(TxType.legacy, TransactionUtils.get_transaction_type(legacy_tx));

    const estimated_gas = TransactionUtils.estimate_gas(legacy_tx);
    try testing.expectEqual(21000, estimated_gas);
}

test "transaction preparation" {
    var builder = TransactionBuilder.init(testing.allocator);

    const request = TransactionRequest{
        .to = TxKind{ .call = [_]u8{0} ** 20 },
        .value = 1000000000000000000,
    };

    const prepared = builder.prepare_transaction_request(request);
    try testing.expectEqual(21000, prepared.gas.?);
    try testing.expectEqual(TxType.legacy, prepared.transaction_type.?);
}

test "eip1559 transaction" {
    const request = TransactionRequest{
        .to = TxKind{ .call = [_]u8{0} ** 20 },
        .value = 1000000000000000000,
        .max_fee_per_gas = 20000000000,
        .max_priority_fee_per_gas = 1000000000,
        .chain_id = 1,
        .nonce = 42,
        .transaction_type = .eip1559,
    };

    const tx = try request.to_transaction();
    try testing.expect(tx == .eip1559);
    try testing.expectEqual(1, tx.eip1559.chain_id);
    try testing.expectEqual(42, tx.eip1559.nonce);
    try testing.expectEqual(20000000000, tx.eip1559.max_fee_per_gas);
    try testing.expectEqual(1000000000, tx.eip1559.max_priority_fee_per_gas);
}
