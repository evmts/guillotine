const std = @import("std");
const OpSpecId = @import("spec.zig").OpSpecId;

/// Deposit transaction parts (EIP-2718 type 0x7E)
///
/// Deposit transactions, also known as deposits, are initiated on L1 and executed on L2.
/// These transactions originate from L1 and are pre-verified, meaning they bypass normal
/// signature verification and have special gas handling rules.
///
/// Reference: https://specs.optimism.io/protocol/deposits.html
pub const DepositTransactionParts = struct {
    /// Hash that uniquely identifies the source of the deposit.
    ///
    /// The source hash is computed differently based on the deposit type:
    /// - For L1 user deposits: keccak256(l1BlockHash, logIndex)
    /// - For L1 attributes deposits: keccak256(bytes32(1), keccak256(l1BlockHash, seqNumber))
    ///
    /// A non-zero value indicates this is a deposit transaction.
    /// Zero value indicates this is a regular (non-deposit) transaction.
    source_hash: [32]u8,

    /// Optional ETH to mint on L2 (free ETH from L1 bridge).
    ///
    /// When present, this amount is unconditionally added to the sender's balance
    /// before transaction execution. This does not revert on deposit failure.
    /// The mint amount comes from the L1 deposit and is "created" on L2.
    mint: ?u128,

    /// System transactions have special gas handling (Bedrock only).
    ///
    /// System transactions are exempt from the L2 gas limit and are used for
    /// protocol-level operations like updating the L1 block attributes.
    /// Normal user deposits have this set to false.
    is_system_transaction: bool,

    /// Check if this represents a deposit transaction.
    ///
    /// A transaction is considered a deposit if its source_hash is non-zero.
    /// The source_hash uniquely identifies the L1 origin of the deposit.
    pub fn isDeposit(self: DepositTransactionParts) bool {
        // Non-zero source_hash indicates deposit
        return !std.mem.allEqual(u8, &self.source_hash, 0);
    }

    /// Create empty (non-deposit) transaction parts.
    ///
    /// Returns a DepositTransactionParts with all fields set to their zero/null values,
    /// representing a regular (non-deposit) transaction.
    pub fn empty() DepositTransactionParts {
        return .{
            .source_hash = std.mem.zeroes([32]u8),
            .mint = null,
            .is_system_transaction = false,
        };
    }

    /// Create a deposit transaction with the given source hash.
    ///
    /// This is a convenience constructor for creating deposit transactions
    /// with optional mint amount and system transaction flag.
    pub fn deposit(source_hash: [32]u8, mint: ?u128, is_system_tx: bool) DepositTransactionParts {
        return .{
            .source_hash = source_hash,
            .mint = mint,
            .is_system_transaction = is_system_tx,
        };
    }
};

/// Optional Optimism transaction data.
///
/// This wraps a standard Ethereum transaction with OP-specific fields required
/// for L1 cost calculation and deposit handling. All standard Ethereum transactions
/// can be wrapped in this structure, with deposit-specific fields being optional.
pub const OpTransactionData = struct {
    /// Raw RLP-encoded transaction bytes (needed for L1 cost calculation).
    ///
    /// This is the full transaction envelope as it would appear on L1.
    /// Used to calculate the L1 data fee component of the total transaction cost.
    /// For deposit transactions, this may be null since they originate from L1 events.
    enveloped_tx: ?[]const u8,

    /// Deposit-specific fields.
    ///
    /// For regular (non-deposit) transactions, this will be empty().
    /// For deposit transactions, this contains the L1 origin information.
    deposit: DepositTransactionParts,

    /// Create empty (non-deposit) transaction data.
    pub fn empty() OpTransactionData {
        return .{
            .enveloped_tx = null,
            .deposit = DepositTransactionParts.empty(),
        };
    }

    /// Check if this is a deposit transaction.
    pub fn isDeposit(self: OpTransactionData) bool {
        return self.deposit.isDeposit();
    }

    /// Calculate gas cost for calldata bytes in the enveloped transaction.
    ///
    /// This implements the L1 data fee calculation based on the size and content
    /// of the transaction calldata. Zero bytes cost 4 gas, non-zero bytes cost 16 gas.
    ///
    /// Returns 0 if enveloped_tx is null (e.g., for deposit transactions).
    pub fn calculateDataGas(self: OpTransactionData) u64 {
        const tx_data = self.enveloped_tx orelse return 0;

        var gas: u64 = 0;
        for (tx_data) |byte| {
            if (byte == 0) {
                gas += 4; // Zero bytes cost 4 gas
            } else {
                gas += 16; // Non-zero bytes cost 16 gas
            }
        }
        return gas;
    }

    /// Create a deposit transaction wrapper.
    ///
    /// Convenience constructor for creating OpTransactionData representing
    /// a deposit transaction with the given parameters.
    pub fn fromDeposit(source_hash: [32]u8, mint: ?u128, is_system_tx: bool) OpTransactionData {
        return .{
            .enveloped_tx = null,
            .deposit = DepositTransactionParts.deposit(source_hash, mint, is_system_tx),
        };
    }
};

/// Transaction type identifier for Optimism.
///
/// Optimism supports all standard Ethereum transaction types plus the
/// special deposit transaction type (0x7E) for L1-originated transactions.
pub const OpTxType = enum(u8) {
    /// Legacy transaction (pre-EIP-2718)
    Legacy = 0x00,

    /// EIP-2930: Access list transaction
    Eip2930 = 0x01,

    /// EIP-1559: Fee market transaction
    Eip1559 = 0x02,

    /// EIP-4844: Blob transaction
    Eip4844 = 0x03,

    /// EIP-7702: Set code transaction. Accepted from Isthmus (Prague), see
    /// specs.optimism.io/protocol/isthmus/exec-engine.html#eip-7702.
    Eip7702 = 0x04,

    /// Optimism deposit transaction (type 0x7E / 126)
    ///
    /// This transaction type is specific to Optimism and represents
    /// a transaction initiated on L1 and executed on L2.
    Deposit = 0x7E,

    pub const DecodeError = error{ EmptyEnvelope, UnknownTxType, TxTypeNotSupported };

    /// Transaction type of an EIP-2718 envelope. A first byte >= 0xC0 is an RLP list
    /// (legacy transaction); otherwise it is the type byte.
    pub fn fromEnvelope(envelope: []const u8) DecodeError!OpTxType {
        if (envelope.len == 0) return error.EmptyEnvelope;
        const first = envelope[0];
        if (first >= 0xc0) return .Legacy;
        return std.enums.fromInt(OpTxType, first) orelse error.UnknownTxType;
    }

    /// True if `spec` accepts this type. Blob transactions are never valid on the
    /// OP Stack (no L2 blob space; op-alloy `OpTxType` has no 0x03 variant).
    /// EIP-7702 activates with Isthmus (Prague).
    pub fn isSupported(self: OpTxType, spec: OpSpecId) bool {
        return switch (self) {
            .Legacy, .Eip2930, .Eip1559, .Deposit => true,
            .Eip4844 => false,
            .Eip7702 => spec.isAtLeast(.ISTHMUS),
        };
    }

    /// Decode the type of `envelope` and reject types `spec` does not accept.
    pub fn decode(envelope: []const u8, spec: OpSpecId) DecodeError!OpTxType {
        const tx_type = try fromEnvelope(envelope);
        if (!tx_type.isSupported(spec)) return error.TxTypeNotSupported;
        return tx_type;
    }

    /// Check if this transaction type is a deposit.
    pub fn isDeposit(self: OpTxType) bool {
        return self == .Deposit;
    }

    /// Get a human-readable name for the transaction type.
    pub fn name(self: OpTxType) []const u8 {
        return switch (self) {
            .Legacy => "Legacy",
            .Eip2930 => "EIP-2930 (Access List)",
            .Eip1559 => "EIP-1559 (Fee Market)",
            .Eip4844 => "EIP-4844 (Blob)",
            .Eip7702 => "EIP-7702 (Set Code)",
            .Deposit => "Deposit (OP)",
        };
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "DepositTransactionParts: empty constructor creates non-deposit" {
    const parts = DepositTransactionParts.empty();

    try std.testing.expect(!parts.isDeposit());
    try std.testing.expectEqual(@as(?u128, null), parts.mint);
    try std.testing.expect(!parts.is_system_transaction);
}

test "DepositTransactionParts: isDeposit with zero source_hash" {
    const parts = DepositTransactionParts{
        .source_hash = std.mem.zeroes([32]u8),
        .mint = 1000,
        .is_system_transaction = true,
    };

    try std.testing.expect(!parts.isDeposit());
}

test "DepositTransactionParts: isDeposit with non-zero source_hash" {
    var source_hash: [32]u8 = undefined;
    @memset(&source_hash, 0);
    source_hash[31] = 1; // Make it non-zero

    const parts = DepositTransactionParts{
        .source_hash = source_hash,
        .mint = null,
        .is_system_transaction = false,
    };

    try std.testing.expect(parts.isDeposit());
}

test "DepositTransactionParts: deposit constructor" {
    var source_hash: [32]u8 = undefined;
    @memset(&source_hash, 0xff);

    const parts = DepositTransactionParts.deposit(source_hash, 5000, true);

    try std.testing.expect(parts.isDeposit());
    try std.testing.expectEqual(@as(?u128, 5000), parts.mint);
    try std.testing.expect(parts.is_system_transaction);
}

test "OpTransactionData: empty constructor" {
    const data = OpTransactionData.empty();

    try std.testing.expect(!data.isDeposit());
    try std.testing.expectEqual(@as(?[]const u8, null), data.enveloped_tx);
    try std.testing.expect(!data.deposit.isDeposit());
}

test "OpTransactionData: isDeposit delegates to deposit field" {
    var source_hash: [32]u8 = undefined;
    @memset(&source_hash, 0x42);

    const data = OpTransactionData{
        .enveloped_tx = null,
        .deposit = DepositTransactionParts.deposit(source_hash, null, false),
    };

    try std.testing.expect(data.isDeposit());
}

test "OpTransactionData: calculateDataGas with null enveloped_tx" {
    const data = OpTransactionData.empty();
    const gas = data.calculateDataGas();

    try std.testing.expectEqual(@as(u64, 0), gas);
}

test "OpTransactionData: calculateDataGas with zero bytes" {
    const tx_data = [_]u8{ 0, 0, 0, 0 };
    const data = OpTransactionData{
        .enveloped_tx = &tx_data,
        .deposit = DepositTransactionParts.empty(),
    };

    const gas = data.calculateDataGas();
    try std.testing.expectEqual(@as(u64, 4 * 4), gas); // 4 bytes * 4 gas each
}

test "OpTransactionData: calculateDataGas with non-zero bytes" {
    const tx_data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const data = OpTransactionData{
        .enveloped_tx = &tx_data,
        .deposit = DepositTransactionParts.empty(),
    };

    const gas = data.calculateDataGas();
    try std.testing.expectEqual(@as(u64, 4 * 16), gas); // 4 bytes * 16 gas each
}

test "OpTransactionData: calculateDataGas with mixed bytes" {
    const tx_data = [_]u8{ 0x00, 0x01, 0x00, 0x02 };
    const data = OpTransactionData{
        .enveloped_tx = &tx_data,
        .deposit = DepositTransactionParts.empty(),
    };

    const gas = data.calculateDataGas();
    try std.testing.expectEqual(@as(u64, 2 * 4 + 2 * 16), gas); // 2 zero + 2 non-zero
}

test "OpTransactionData: fromDeposit constructor" {
    var source_hash: [32]u8 = undefined;
    @memset(&source_hash, 0xaa);

    const data = OpTransactionData.fromDeposit(source_hash, 10000, false);

    try std.testing.expect(data.isDeposit());
    try std.testing.expectEqual(@as(?[]const u8, null), data.enveloped_tx);
    try std.testing.expectEqual(@as(?u128, 10000), data.deposit.mint);
    try std.testing.expect(!data.deposit.is_system_transaction);
}

test "OpTxType: isDeposit for each type" {
    try std.testing.expect(!OpTxType.Legacy.isDeposit());
    try std.testing.expect(!OpTxType.Eip2930.isDeposit());
    try std.testing.expect(!OpTxType.Eip1559.isDeposit());
    try std.testing.expect(!OpTxType.Eip4844.isDeposit());
    try std.testing.expect(OpTxType.Deposit.isDeposit());
}

test "OpTxType: correct enum values" {
    try std.testing.expectEqual(@as(u8, 0x00), @intFromEnum(OpTxType.Legacy));
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(OpTxType.Eip2930));
    try std.testing.expectEqual(@as(u8, 0x02), @intFromEnum(OpTxType.Eip1559));
    try std.testing.expectEqual(@as(u8, 0x03), @intFromEnum(OpTxType.Eip4844));
    try std.testing.expectEqual(@as(u8, 0x7E), @intFromEnum(OpTxType.Deposit));
}

test "OpTxType: name returns correct strings" {
    try std.testing.expectEqualStrings("Legacy", OpTxType.Legacy.name());
    try std.testing.expectEqualStrings("EIP-2930 (Access List)", OpTxType.Eip2930.name());
    try std.testing.expectEqualStrings("EIP-1559 (Fee Market)", OpTxType.Eip1559.name());
    try std.testing.expectEqualStrings("EIP-4844 (Blob)", OpTxType.Eip4844.name());
    try std.testing.expectEqualStrings("Deposit (OP)", OpTxType.Deposit.name());
}

test "Edge case: maximum mint value" {
    const max_mint = std.math.maxInt(u128);
    var source_hash: [32]u8 = undefined;
    @memset(&source_hash, 1);

    const parts = DepositTransactionParts.deposit(source_hash, max_mint, false);

    try std.testing.expectEqual(@as(?u128, max_mint), parts.mint);
    try std.testing.expect(parts.isDeposit());
}

test "Edge case: all source_hash bytes set" {
    var source_hash: [32]u8 = undefined;
    @memset(&source_hash, 0xff);

    const parts = DepositTransactionParts{
        .source_hash = source_hash,
        .mint = null,
        .is_system_transaction = false,
    };

    try std.testing.expect(parts.isDeposit());
}

test "Edge case: calculateDataGas with large transaction" {
    const allocator = std.testing.allocator;

    // Create a 1KB transaction with alternating zero/non-zero bytes
    const tx_data = try allocator.alloc(u8, 1024);
    defer allocator.free(tx_data);

    for (tx_data, 0..) |*byte, i| {
        byte.* = if (i % 2 == 0) 0x00 else 0xff;
    }

    const data = OpTransactionData{
        .enveloped_tx = tx_data,
        .deposit = DepositTransactionParts.empty(),
    };

    const gas = data.calculateDataGas();
    // 512 zero bytes (4 gas each) + 512 non-zero bytes (16 gas each)
    try std.testing.expectEqual(@as(u64, 512 * 4 + 512 * 16), gas);
}

test "Integration: full deposit transaction flow" {
    // Simulate a deposit transaction with mint
    var source_hash: [32]u8 = undefined;
    @memset(&source_hash, 0);
    source_hash[0] = 0xab;
    source_hash[31] = 0xcd;

    const mint_amount: u128 = 1_000_000_000_000_000_000; // 1 ETH in wei

    const op_tx = OpTransactionData.fromDeposit(source_hash, mint_amount, false);

    // Verify deposit properties
    try std.testing.expect(op_tx.isDeposit());
    try std.testing.expectEqual(@as(?u128, mint_amount), op_tx.deposit.mint);
    try std.testing.expect(!op_tx.deposit.is_system_transaction);

    // Verify no L1 data gas (deposit transactions don't have enveloped_tx)
    try std.testing.expectEqual(@as(u64, 0), op_tx.calculateDataGas());
}

test "Integration: regular transaction with L1 data cost" {
    // Simulate a regular L2 transaction with calldata
    const calldata = [_]u8{ 0xa9, 0x05, 0x9c, 0xbb, 0x00, 0x00 }; // Example function call

    const op_tx = OpTransactionData{
        .enveloped_tx = &calldata,
        .deposit = DepositTransactionParts.empty(),
    };

    // Verify it's not a deposit
    try std.testing.expect(!op_tx.isDeposit());

    // Calculate L1 data gas: 2 zero bytes + 4 non-zero bytes
    const expected_gas: u64 = 2 * 4 + 4 * 16;
    try std.testing.expectEqual(expected_gas, op_tx.calculateDataGas());
}

test "OpTxType: EIP-7702 is type 0x04 and gated on Isthmus" {
    try std.testing.expectEqual(@as(u8, 0x04), @intFromEnum(OpTxType.Eip7702));
    try std.testing.expectEqualStrings("EIP-7702 (Set Code)", OpTxType.Eip7702.name());
    try std.testing.expect(!OpTxType.Eip7702.isDeposit());
    const envelope = [_]u8{ 0x04, 0xf8, 0x00 };
    try std.testing.expectEqual(OpTxType.Eip7702, try OpTxType.fromEnvelope(&envelope));
    for (OpSpecId.ALL) |spec| {
        if (spec.isBefore(.ISTHMUS)) {
            try std.testing.expectError(error.TxTypeNotSupported, OpTxType.decode(&envelope, spec));
        } else {
            try std.testing.expectEqual(OpTxType.Eip7702, try OpTxType.decode(&envelope, spec));
        }
    }
}

test "OpTxType: decode envelopes and reject blob and unknown types" {
    try std.testing.expectEqual(OpTxType.Legacy, try OpTxType.decode(&.{ 0xf8, 0x6b }, .BEDROCK));
    try std.testing.expectEqual(OpTxType.Legacy, try OpTxType.decode(&.{0xc0}, .JOVIAN));
    try std.testing.expectEqual(OpTxType.Eip2930, try OpTxType.decode(&.{0x01}, .BEDROCK));
    try std.testing.expectEqual(OpTxType.Eip1559, try OpTxType.decode(&.{0x02}, .JOVIAN));
    try std.testing.expectEqual(OpTxType.Deposit, try OpTxType.decode(&.{0x7e}, .BEDROCK));
    for (OpSpecId.ALL) |spec| {
        try std.testing.expectError(error.TxTypeNotSupported, OpTxType.decode(&.{0x03}, spec));
    }
    try std.testing.expectError(error.UnknownTxType, OpTxType.decode(&.{0x05}, .JOVIAN));
    try std.testing.expectError(error.UnknownTxType, OpTxType.decode(&.{0x7f}, .JOVIAN));
    try std.testing.expectError(error.EmptyEnvelope, OpTxType.decode(&.{}, .JOVIAN));
}
