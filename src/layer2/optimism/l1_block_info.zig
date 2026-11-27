//! L1 block attributes and the OP Stack L1 data fee and operator fee.
//!
//! Port of op-revm l1block.rs:
//! https://github.com/ethereum-optimism/optimism/blob/develop/rust/op-revm/src/l1block.rs
//!
//! Formulas (all integer arithmetic, u256, saturating like op-revm):
//!
//!   Bedrock/Regolith: (dataGas + overhead) * l1BaseFee * l1Scalar / 1e6
//!   Ecotone:          dataGas * (l1BaseFee*16*baseFeeScalar + blobBaseFee*blobScalar) / 16e6
//!   Fjord+:           estimatedSize * (l1BaseFee*16*baseFeeScalar + blobBaseFee*blobScalar) / 1e12
//!   Isthmus operator: gas * operatorFeeScalar / 1e6 + operatorFeeConstant
//!   Jovian operator:  gas * operatorFeeScalar * 100 + operatorFeeConstant
//!
//! dataGas pre-Fjord = 4 per zero byte + 16 per non-zero byte (+1088 before Regolith).
//! dataGas Fjord+    = estimatedSize * 16 / 1e6.
//! Deposits (first byte 0x7E) and empty input pay no L1 fee and no operator fee.

const std = @import("std");
const spec_mod = @import("spec.zig");
const constants = @import("constants.zig");
const fast_lz = @import("fast_lz.zig");

const OpSpecId = spec_mod.OpSpecId;

pub const OperatorFeeError = error{
    /// Isthmus+ fee requested but operator_fee_scalar or operator_fee_constant is null.
    /// `tryFetch` always populates both for Isthmus+; this only fires for hand-built values.
    MissingOperatorFeeParams,
};

/// L1 attributes read from the L1Block predeploy for one L2 block.
pub const L1BlockInfo = struct {
    /// L2 block number these attributes were fetched for.
    l2_block: u256,
    /// L1 origin base fee.
    l1_base_fee: u256,
    /// Bedrock/Regolith overhead. Ecotone+: set only when the scalars are empty.
    l1_fee_overhead: ?u256,
    /// Bedrock/Regolith l1FeeScalar, or Ecotone+ baseFeeScalar.
    l1_base_fee_scalar: u256,
    /// Ecotone+ L1 blob base fee.
    l1_blob_base_fee: ?u256,
    /// Ecotone+ blobBaseFeeScalar.
    l1_blob_base_fee_scalar: ?u256,
    /// Isthmus+ operatorFeeScalar (u32).
    operator_fee_scalar: ?u256,
    /// Isthmus+ operatorFeeConstant (u64).
    operator_fee_constant: ?u256,
    /// Jovian+ daFootprintGasScalar (u16).
    da_footprint_gas_scalar: ?u16,
    /// Ecotone+ with all scalars zero (first Ecotone block): use the Bedrock formula.
    empty_ecotone_scalars: bool,
    /// L1 cost cached for the transaction currently executing. Clear between transactions.
    tx_l1_cost: ?u256,

    pub fn empty() L1BlockInfo {
        return .{
            .l2_block = 0,
            .l1_base_fee = 0,
            .l1_fee_overhead = null,
            .l1_base_fee_scalar = 0,
            .l1_blob_base_fee = null,
            .l1_blob_base_fee_scalar = null,
            .operator_fee_scalar = null,
            .operator_fee_constant = null,
            .da_footprint_gas_scalar = null,
            .empty_ecotone_scalars = false,
            .tx_l1_cost = null,
        };
    }

    /// Extract a big-endian unsigned integer of `len` bytes at byte `offset` of a slot value.
    pub fn extractScalar(slot_value: u256, offset: usize, len: usize) u256 {
        var bytes: [32]u8 = undefined;
        std.mem.writeInt(u256, &bytes, slot_value, .big);
        var value: u256 = 0;
        for (bytes[offset .. offset + len]) |byte| value = (value << 8) | byte;
        return value;
    }

    /// Read L1 attributes from the L1Block predeploy.
    ///
    /// `Database` is duck-typed: `get_storage(self: *Database, address: [20]u8, slot: u256) !u256`.
    pub fn tryFetch(comptime Database: type, db: *Database, l2_block: u256, spec_id: OpSpecId) !L1BlockInfo {
        const addr = constants.L1_BLOCK_ADDRESS.bytes;
        var info = L1BlockInfo.empty();
        info.l2_block = l2_block;
        info.l1_base_fee = try db.get_storage(addr, constants.L1_BASE_FEE_SLOT);

        if (spec_id.isBefore(.ECOTONE)) {
            info.l1_base_fee_scalar = try db.get_storage(addr, constants.L1_SCALAR_SLOT);
            info.l1_fee_overhead = try db.get_storage(addr, constants.L1_OVERHEAD_SLOT);
            return info;
        }

        // Ecotone
        info.l1_blob_base_fee = try db.get_storage(addr, constants.ECOTONE_L1_BLOB_BASE_FEE_SLOT);
        const fee_scalars = try db.get_storage(addr, constants.ECOTONE_L1_FEE_SCALARS_SLOT);
        info.l1_base_fee_scalar = extractScalar(fee_scalars, constants.BASE_FEE_SCALAR_OFFSET, 4);
        const blob_scalar = extractScalar(fee_scalars, constants.BLOB_BASE_FEE_SCALAR_OFFSET, 4);
        info.l1_blob_base_fee_scalar = blob_scalar;
        // op-revm: blob scalar is zero and bytes [16..24) are zero. The blob base fee is not
        // part of the check.
        info.empty_ecotone_scalars = blob_scalar == 0 and info.l1_base_fee_scalar == 0;
        if (info.empty_ecotone_scalars) {
            info.l1_fee_overhead = try db.get_storage(addr, constants.L1_OVERHEAD_SLOT);
        }

        if (spec_id.isAtLeast(.ISTHMUS)) {
            const operator = try db.get_storage(addr, constants.OPERATOR_FEE_SCALARS_SLOT);
            info.operator_fee_scalar = extractScalar(operator, constants.OPERATOR_FEE_SCALAR_OFFSET, 4);
            info.operator_fee_constant = extractScalar(operator, constants.OPERATOR_FEE_CONSTANT_OFFSET, 8);
        }

        if (spec_id.isAtLeast(.JOVIAN)) {
            const da = try db.get_storage(addr, constants.DA_FOOTPRINT_GAS_SCALAR_SLOT);
            info.da_footprint_gas_scalar = @intCast(extractScalar(da, constants.DA_FOOTPRINT_GAS_SCALAR_OFFSET, 2));
        }

        return info;
    }

    /// L1 data fee plus (Isthmus+) operator fee charged up front on `gas_limit`
    /// (op-revm `tx_cost`). The unused part of the operator fee is refunded by
    /// `operatorFeeRefund` after execution.
    pub fn txCost(
        self: *L1BlockInfo,
        enveloped_tx: []const u8,
        gas_limit: u64,
        spec_id: OpSpecId,
    ) OperatorFeeError!u256 {
        const l1_cost = self.calculateTxL1Cost(enveloped_tx, spec_id);
        const operator = try self.operatorFee(enveloped_tx, gas_limit, spec_id);
        return l1_cost +| operator;
    }

    /// L1 data fee for an EIP-2718 encoded transaction. Cached in `tx_l1_cost`.
    pub fn calculateTxL1Cost(self: *L1BlockInfo, enveloped_tx: []const u8, spec_id: OpSpecId) u256 {
        if (self.tx_l1_cost) |cost| return cost;
        if (enveloped_tx.len == 0 or enveloped_tx[0] == constants.DEPOSIT_TRANSACTION_TYPE) return 0;

        const cost = if (spec_id.isAtLeast(.FJORD))
            self.calculateL1CostFjord(enveloped_tx)
        else if (spec_id.isAtLeast(.ECOTONE))
            self.calculateL1CostEcotone(enveloped_tx, spec_id)
        else
            self.calculateL1CostBedrock(enveloped_tx, spec_id);

        self.tx_l1_cost = cost;
        return cost;
    }

    pub fn clearTxL1Cost(self: *L1BlockInfo) void {
        self.tx_l1_cost = null;
    }

    /// (dataGas + overhead) * l1BaseFee * l1Scalar / 1e6
    pub fn calculateL1CostBedrock(self: L1BlockInfo, tx: []const u8, spec_id: OpSpecId) u256 {
        const data_gas = dataGas(tx, spec_id);
        const gas_with_overhead = data_gas +| (self.l1_fee_overhead orelse 0);
        return (gas_with_overhead *| self.l1_base_fee *| self.l1_base_fee_scalar) / 1_000_000;
    }

    /// dataGas * l1FeeScaled / 16e6. Falls back to Bedrock when the scalars are empty.
    pub fn calculateL1CostEcotone(self: L1BlockInfo, tx: []const u8, spec_id: OpSpecId) u256 {
        if (self.empty_ecotone_scalars) return self.calculateL1CostBedrock(tx, spec_id);
        const data_gas = dataGas(tx, spec_id);
        return (self.l1FeeScaled() *| data_gas) / (1_000_000 * constants.NON_ZERO_BYTE_GAS);
    }

    /// estimatedSize * l1FeeScaled / 1e12
    pub fn calculateL1CostFjord(self: L1BlockInfo, tx: []const u8) u256 {
        const scaled = self.l1FeeScaled();
        if (scaled == 0) return 0;
        return (@as(u256, estimatedSizeFjord(tx)) *| scaled) / 1_000_000_000_000;
    }

    /// l1BaseFee * 16 * baseFeeScalar + blobBaseFee * blobBaseFeeScalar
    pub fn l1FeeScaled(self: L1BlockInfo) u256 {
        const calldata = self.l1_base_fee *| constants.NON_ZERO_BYTE_GAS *| self.l1_base_fee_scalar;
        const blob = (self.l1_blob_base_fee orelse 0) *| (self.l1_blob_base_fee_scalar orelse 0);
        return calldata +| blob;
    }

    /// Operator fee for `gas` (op-revm `operator_fee_charge`). Zero before Isthmus,
    /// for deposits, and for empty input.
    pub fn operatorFee(self: L1BlockInfo, enveloped_tx: []const u8, gas: u64, spec_id: OpSpecId) OperatorFeeError!u256 {
        if (spec_id.isBefore(.ISTHMUS)) return 0;
        if (enveloped_tx.len == 0 or enveloped_tx[0] == constants.DEPOSIT_TRANSACTION_TYPE) return 0;
        return self.operatorFeeInner(gas, spec_id);
    }

    /// Operator fee refund after execution: fee(gas_limit) - fee(gas_used).
    /// Net operator fee paid is therefore fee(gas_used). Callers skip deposits.
    pub fn operatorFeeRefund(
        self: L1BlockInfo,
        gas_limit: u64,
        gas_used: u64,
        spec_id: OpSpecId,
    ) OperatorFeeError!u256 {
        if (spec_id.isBefore(.ISTHMUS)) return 0;
        const charged = try self.operatorFeeInner(gas_limit, spec_id);
        const used = try self.operatorFeeInner(gas_used, spec_id);
        return charged -| used;
    }

    fn operatorFeeInner(self: L1BlockInfo, gas: u64, spec_id: OpSpecId) OperatorFeeError!u256 {
        const scalar = self.operator_fee_scalar orelse return error.MissingOperatorFeeParams;
        const constant = self.operator_fee_constant orelse return error.MissingOperatorFeeParams;
        const product = if (spec_id.isAtLeast(.JOVIAN))
            @as(u256, gas) *| scalar *| constants.OPERATOR_FEE_JOVIAN_MULTIPLIER
        else
            (@as(u256, gas) *| scalar) / constants.OPERATOR_FEE_SCALAR_DECIMAL;
        return product +| constant;
    }
};

/// Rollup data gas for an encoded transaction.
pub fn dataGas(tx: []const u8, spec_id: OpSpecId) u256 {
    if (spec_id.isAtLeast(.FJORD)) {
        return (@as(u256, estimatedSizeFjord(tx)) * constants.NON_ZERO_BYTE_GAS) / 1_000_000;
    }
    var gas: u256 = 0;
    for (tx) |byte| {
        gas += if (byte == 0) constants.ZERO_BYTE_GAS else constants.NON_ZERO_BYTE_GAS;
    }
    if (spec_id.isBefore(.REGOLITH)) gas += constants.PRE_REGOLITH_SIGNATURE_OVERHEAD_GAS;
    return gas;
}

/// Fjord compressed size estimate scaled by 1e6:
/// max(100e6, fastlzSize * 836_500 - 42_585_600) (op-revm `estimate_tx_compressed_size`).
pub fn estimatedSizeFjord(tx: []const u8) u64 {
    const fastlz_size: u64 = fast_lz.flzCompressLen(tx);
    const estimate = (fastlz_size *| constants.FJORD_FASTLZ_COEF) -| constants.FJORD_INTERCEPT;
    return @max(constants.FJORD_MIN_TX_SIZE_SCALED, estimate);
}

/// In-memory storage for tests and tooling.
pub const MockDatabase = struct {
    storage: std.AutoHashMap(StorageKey, u256),

    const StorageKey = struct {
        address: [20]u8,
        slot: u256,
    };

    pub fn init(allocator: std.mem.Allocator) MockDatabase {
        return .{ .storage = std.AutoHashMap(StorageKey, u256).init(allocator) };
    }

    pub fn deinit(self: *MockDatabase) void {
        self.storage.deinit();
    }

    pub fn setStorage(self: *MockDatabase, address: [20]u8, slot: u256, value: u256) !void {
        try self.storage.put(.{ .address = address, .slot = slot }, value);
    }

    pub fn get_storage(self: *MockDatabase, address: [20]u8, slot: u256) !u256 {
        return self.storage.get(.{ .address = address, .slot = slot }) orelse 0;
    }
};

// ============================================================================
// Tests. Expected values come from op-revm l1block.rs tests unless noted.
// ============================================================================

const testing = std.testing;

fn testInfo() L1BlockInfo {
    var info = L1BlockInfo.empty();
    info.l1_base_fee = 1_000;
    info.l1_fee_overhead = 1_000;
    info.l1_base_fee_scalar = 1_000;
    return info;
}

const FACADE = [_]u8{ 0xFA, 0xCA, 0xDE };
const FA00CA00DE = [_]u8{ 0xFA, 0x00, 0xCA, 0x00, 0xDE };

test "dataGas non-zero bytes (op-revm test_data_gas_non_zero_bytes)" {
    try testing.expectEqual(@as(u256, 1136), dataGas(&FACADE, .BEDROCK));
    try testing.expectEqual(@as(u256, 48), dataGas(&FACADE, .REGOLITH));
    try testing.expectEqual(@as(u256, 1600), dataGas(&FACADE, .FJORD));
}

test "dataGas zero bytes (op-revm test_data_gas_zero_bytes)" {
    try testing.expectEqual(@as(u256, 1144), dataGas(&FA00CA00DE, .BEDROCK));
    try testing.expectEqual(@as(u256, 56), dataGas(&FA00CA00DE, .REGOLITH));
    try testing.expectEqual(@as(u256, 1600), dataGas(&FA00CA00DE, .FJORD));
}

test "Regolith L1 cost (op-revm test_calculate_tx_l1_cost)" {
    var info = testInfo();
    try testing.expectEqual(@as(u256, 1048), info.calculateTxL1Cost(&FACADE, .REGOLITH));
    info.clearTxL1Cost();
    try testing.expectEqual(@as(u256, 0), info.calculateTxL1Cost(&[_]u8{}, .REGOLITH));
    info.clearTxL1Cost();
    try testing.expectEqual(@as(u256, 0), info.calculateTxL1Cost(&[_]u8{ 0x7E, 0xFA, 0xCA, 0xDE }, .REGOLITH));
}

test "Ecotone L1 cost (op-revm test_calculate_tx_l1_cost_ecotone)" {
    var info = testInfo();
    info.l1_blob_base_fee = 1_000;
    info.l1_blob_base_fee_scalar = 1_000;
    try testing.expectEqual(@as(u256, 51), info.calculateTxL1Cost(&FACADE, .ECOTONE));
    info.clearTxL1Cost();
    try testing.expectEqual(@as(u256, 0), info.calculateTxL1Cost(&[_]u8{}, .ECOTONE));
    info.clearTxL1Cost();
    try testing.expectEqual(@as(u256, 0), info.calculateTxL1Cost(&[_]u8{ 0x7E, 0xFA, 0xCA, 0xDE }, .ECOTONE));
    info.clearTxL1Cost();
    info.empty_ecotone_scalars = true;
    try testing.expectEqual(@as(u256, 1048), info.calculateTxL1Cost(&FACADE, .ECOTONE));
}

const FJORD_FASTLZ_202_TX = "02f901550a758302df1483be21b88304743f94f80e51afb613d764fa61751affd3313c190a86bb870151bd62fd12adb8e41ef24f3f000000000000000000000000000000000000000000000000000000000000006e000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e5831000000000000000000000000000000000000000000000000000000000003c1e5000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000148c89ed219d02f1a5be012c689b4f5b731827bebe000000000000000000000000c001a033fd89cb37c31b2cba46b6466e040c61fc9b2a3675a7f5f493ebd5ad77c497f8a07cdf65680e238392693019b4092f610222e71b7cec06449cb922b93b6a12744e";

test "Fjord L1 cost (op-revm test_calculate_tx_l1_cost_fjord)" {
    var info = testInfo();
    info.l1_blob_base_fee = 1_000;
    info.l1_blob_base_fee_scalar = 1_000;
    try testing.expectEqual(@as(u256, 1700), info.calculateTxL1Cost(&FACADE, .FJORD));
    info.clearTxL1Cost();
    // fastLzSize = 202: estimatedSize = 836500*202 - 42585600 = 126387400; cost = 126387400*17/1e6.
    var tx202: [FJORD_FASTLZ_202_TX.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&tx202, FJORD_FASTLZ_202_TX);
    try testing.expectEqual(@as(u64, 202), fast_lz.flzCompressLen(&tx202));
    try testing.expectEqual(@as(u256, 2148), info.calculateTxL1Cost(&tx202, .FJORD));
    info.clearTxL1Cost();
    try testing.expectEqual(@as(u256, 0), info.calculateTxL1Cost(&[_]u8{}, .FJORD));
    info.clearTxL1Cost();
    try testing.expectEqual(@as(u256, 0), info.calculateTxL1Cost(&[_]u8{ 0x7E, 0xFA, 0xCA, 0xDE }, .FJORD));
}

// OP mainnet Ecotone block 118024092, tx 0xa75ef696bf67439b4d5b61da85de9f3ceaa2e145abe982212101b244b63749c2.
const ECOTONE_MAINNET_TX = "02f8b30a832253fc8402d11f39842c8a46398301388094dc6ff44d5d932cbd77b52e5612ba0529dc6226f180b844a9059cbb000000000000000000000000d43e02db81f4d46cdf8521f623d21ea0ec7562a50000000000000000000000000000000000000000000000008ac7230489e80000c001a02947e24750723b48f886931562c55d9e07f856d8e06468e719755e18bbc3a570a0784da9ce59fd7754ea5be6e17a86b348e441348cd48ace59d174772465eadbd1";

test "Ecotone L1 cost matches OP mainnet block 118024092" {
    var tx: [ECOTONE_MAINNET_TX.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&tx, ECOTONE_MAINNET_TX);
    var info = L1BlockInfo.empty();
    info.l1_base_fee = 47_036_678_951;
    info.l1_base_fee_scalar = 1368;
    info.l1_blob_base_fee = 57_422_457_042;
    info.l1_blob_base_fee_scalar = 810_949;
    try testing.expectEqual(@as(u256, 2456), dataGas(&tx, .ECOTONE));
    try testing.expectEqual(@as(u256, 7_306_020_222_001), info.calculateL1CostEcotone(&tx, .ECOTONE));
}

// OP mainnet Fjord block 124665056, tx 0x1059e8004daff32caa1f1b1ef97fe3a07a8cf40508f5b835b66d9420d87c4a4a.
const FJORD_MAINNET_TX = "02f904940a8303fba78401d6d2798401db2b6d830493e0943e6f4f7866654c18f536170780344aa8772950b680b904246a761202000000000000000000000000087000a300de7200382b55d40045000000e5d60e0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003a0000000000000000000000000000000000000000000000000000000000000022482ad56cb0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000120000000000000000000000000dc6ff44d5d932cbd77b52e5612ba0529dc6226f1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000044095ea7b300000000000000000000000021c4928109acb0659a88ae5329b5374a3024694c0000000000000000000000000000000000000000000000049b9ca9a6943400000000000000000000000000000000000000000000000000000000000000000000000000000000000021c4928109acb0659a88ae5329b5374a3024694c000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000024b6b55f250000000000000000000000000000000000000000000000049b9ca9a694340000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000415ec214a3950bea839a7e6fbb0ba1540ac2076acd50820e2d5ef83d0902cdffb24a47aff7de5190290769c4f0a9c6fabf63012986a0d590b1b571547a8c7050ea1b00000000000000000000000000000000000000000000000000000000000000c080a06db770e6e25a617fe9652f0958bd9bd6e49281a53036906386ed39ec48eadf63a07f47cf51a4a40b4494cf26efc686709a9b03939e20ee27e59682f5faa536667e";

test "Fjord L1 cost matches OP mainnet block 124665056" {
    var tx: [FJORD_MAINNET_TX.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&tx, FJORD_MAINNET_TX);
    var info = L1BlockInfo.empty();
    info.l1_base_fee = 1_055_991_687;
    info.l1_base_fee_scalar = 5227;
    info.l1_blob_base_fee = 1;
    info.l1_blob_base_fee_scalar = 1_014_213;
    try testing.expectEqual(@as(u256, 4471), dataGas(&tx, .FJORD));
    try testing.expectEqual(@as(u256, 0x5bf1ab43d), info.calculateL1CostFjord(&tx));
}

test "Fjord L1 cost is zero when the scaled fee is zero" {
    const info = L1BlockInfo.empty();
    try testing.expectEqual(@as(u256, 0), info.calculateL1CostFjord(&FACADE));
}

test "operator fee formulas (op-revm test_operator_fee_charge_formulas)" {
    var info = L1BlockInfo.empty();
    info.operator_fee_scalar = 1_000;
    info.operator_fee_constant = 10;
    const input = [_]u8{0x01};
    try testing.expectEqual(@as(u256, 0), try L1BlockInfo.empty().operatorFee(&input, 1_000, .FJORD));
    try testing.expectEqual(@as(u256, 11), try info.operatorFee(&input, 1_000, .ISTHMUS));
    try testing.expectEqual(@as(u256, 100_000_010), try info.operatorFee(&input, 1_000, .JOVIAN));
}

test "operator fee is zero for deposits and empty input" {
    var info = L1BlockInfo.empty();
    info.operator_fee_scalar = 1_000;
    info.operator_fee_constant = 10;
    try testing.expectEqual(@as(u256, 0), try info.operatorFee(&[_]u8{ 0x7E, 0x01 }, 1_000, .JOVIAN));
    try testing.expectEqual(@as(u256, 0), try info.operatorFee(&[_]u8{}, 1_000, .JOVIAN));
}

test "operator fee refund (op-revm test_operator_fee_refund)" {
    // gas limit 100, 50 spent: fee(100) - fee(50) with scalar 2000, constant 5.
    var info = L1BlockInfo.empty();
    info.operator_fee_scalar = 2_000;
    info.operator_fee_constant = 5;
    // Isthmus: 100*2000/1e6 + 5 = 5; 50*2000/1e6 + 5 = 5. Refund 0.
    try testing.expectEqual(@as(u256, 0), try info.operatorFeeRefund(100, 50, .ISTHMUS));
    // Jovian: (100*2000*100 + 5) - (50*2000*100 + 5) = 10_000_000.
    try testing.expectEqual(@as(u256, 10_000_000), try info.operatorFeeRefund(100, 50, .JOVIAN));
    try testing.expectEqual(@as(u256, 0), try info.operatorFeeRefund(100, 50, .HOLOCENE));
}

test "operator fee without params is an error, not a crash" {
    const info = L1BlockInfo.empty();
    try testing.expectError(error.MissingOperatorFeeParams, info.operatorFee(&[_]u8{0x02}, 1, .ISTHMUS));
    try testing.expectError(error.MissingOperatorFeeParams, info.operatorFeeRefund(2, 1, .JOVIAN));
}

test "Jovian operator fee maximum fits u256 (spec: 103 bits)" {
    var info = L1BlockInfo.empty();
    info.operator_fee_scalar = std.math.maxInt(u32);
    info.operator_fee_constant = std.math.maxInt(u64);
    const fee = try info.operatorFee(&[_]u8{0x02}, std.math.maxInt(u64), .JOVIAN);
    const expected = @as(u256, std.math.maxInt(u64)) * std.math.maxInt(u32) * 100 + std.math.maxInt(u64);
    try testing.expectEqual(expected, fee);
    try testing.expect(fee < (@as(u256, 1) << 103));
}

test "txCost adds L1 fee and operator fee on gas limit" {
    var info = testInfo();
    info.l1_blob_base_fee = 1_000;
    info.l1_blob_base_fee_scalar = 1_000;
    info.operator_fee_scalar = 1_000;
    info.operator_fee_constant = 10;
    try testing.expectEqual(@as(u256, 1700 + 11), try info.txCost(&FACADE, 1_000, .ISTHMUS));
    info.clearTxL1Cost();
    try testing.expectEqual(@as(u256, 1700), try info.txCost(&FACADE, 1_000, .HOLOCENE));
}

test "L1 cost cache returns cached value until cleared" {
    var info = testInfo();
    const first = info.calculateTxL1Cost(&FACADE, .REGOLITH);
    try testing.expectEqual(first, info.tx_l1_cost.?);
    try testing.expectEqual(first, info.calculateTxL1Cost(&[_]u8{0x01}, .REGOLITH));
    info.clearTxL1Cost();
    try testing.expect(info.tx_l1_cost == null);
}

test "extractScalar reads big-endian fields" {
    const packed_value: u256 = 0x00000000_00000000_00000000_00000000_00000558_000C5E75_00000000_00000000;
    try testing.expectEqual(@as(u256, 1368), L1BlockInfo.extractScalar(packed_value, 16, 4));
    try testing.expectEqual(@as(u256, 810_613), L1BlockInfo.extractScalar(packed_value, 20, 4));
    try testing.expectEqual(@as(u256, 0xFFFFFFFF), L1BlockInfo.extractScalar(0xFFFFFFFF << 96, 16, 4));
    try testing.expectEqual(@as(u256, 0), L1BlockInfo.extractScalar(0, 16, 4));
    try testing.expectEqual(@as(u256, std.math.maxInt(u64)), L1BlockInfo.extractScalar(std.math.maxInt(u64), 24, 8));
}

test "tryFetch Bedrock reads overhead and scalar slots" {
    var db = MockDatabase.init(testing.allocator);
    defer db.deinit();
    const addr = constants.L1_BLOCK_ADDRESS.bytes;
    try db.setStorage(addr, constants.L1_BASE_FEE_SLOT, 1_000_000_000);
    try db.setStorage(addr, constants.L1_OVERHEAD_SLOT, 2100);
    try db.setStorage(addr, constants.L1_SCALAR_SLOT, 1_000_000);

    const info = try L1BlockInfo.tryFetch(MockDatabase, &db, 100, .BEDROCK);
    try testing.expectEqual(@as(u256, 100), info.l2_block);
    try testing.expectEqual(@as(u256, 1_000_000_000), info.l1_base_fee);
    try testing.expectEqual(@as(u256, 2100), info.l1_fee_overhead.?);
    try testing.expectEqual(@as(u256, 1_000_000), info.l1_base_fee_scalar);
    try testing.expect(info.l1_blob_base_fee == null);
    try testing.expect(!info.empty_ecotone_scalars);
}

test "tryFetch Ecotone unpacks scalars" {
    var db = MockDatabase.init(testing.allocator);
    defer db.deinit();
    const addr = constants.L1_BLOCK_ADDRESS.bytes;
    try db.setStorage(addr, constants.L1_BASE_FEE_SLOT, 47_036_678_951);
    try db.setStorage(addr, constants.ECOTONE_L1_BLOB_BASE_FEE_SLOT, 57_422_457_042);
    try db.setStorage(addr, constants.ECOTONE_L1_FEE_SCALARS_SLOT, 0x00000000_00000000_00000000_00000000_00000558_000C5FC5_00000000_00000000);
    try db.setStorage(addr, constants.L1_OVERHEAD_SLOT, 999);

    const info = try L1BlockInfo.tryFetch(MockDatabase, &db, 118024092, .ECOTONE);
    try testing.expectEqual(@as(u256, 1368), info.l1_base_fee_scalar);
    try testing.expectEqual(@as(u256, 810_949), info.l1_blob_base_fee_scalar.?);
    try testing.expectEqual(@as(u256, 57_422_457_042), info.l1_blob_base_fee.?);
    try testing.expect(!info.empty_ecotone_scalars);
    // Overhead is only read when the scalars are empty.
    try testing.expect(info.l1_fee_overhead == null);
    try testing.expect(info.operator_fee_scalar == null);
}

test "tryFetch Ecotone empty scalars reads overhead" {
    var db = MockDatabase.init(testing.allocator);
    defer db.deinit();
    const addr = constants.L1_BLOCK_ADDRESS.bytes;
    try db.setStorage(addr, constants.L1_BASE_FEE_SLOT, 1_000_000_000);
    // Non-zero blob base fee does not prevent the empty-scalars case.
    try db.setStorage(addr, constants.ECOTONE_L1_BLOB_BASE_FEE_SLOT, 7);
    try db.setStorage(addr, constants.L1_OVERHEAD_SLOT, 188);

    const info = try L1BlockInfo.tryFetch(MockDatabase, &db, 1, .ECOTONE);
    try testing.expect(info.empty_ecotone_scalars);
    try testing.expectEqual(@as(u256, 188), info.l1_fee_overhead.?);
}

test "tryFetch Isthmus reads u32 scalar and u64 constant" {
    var db = MockDatabase.init(testing.allocator);
    defer db.deinit();
    const addr = constants.L1_BLOCK_ADDRESS.bytes;
    try db.setStorage(addr, constants.ECOTONE_L1_FEE_SCALARS_SLOT, 0x00000000_00000000_00000000_00000000_00001000_00002000_00000000_00000000);
    // scalar 5000 at [20..24), constant 0x0102030405060708 at [24..32).
    try db.setStorage(addr, constants.OPERATOR_FEE_SCALARS_SLOT, 0x00000000_00000000_00000000_00000000_00000000_00001388_01020304_05060708);

    const info = try L1BlockInfo.tryFetch(MockDatabase, &db, 200, .ISTHMUS);
    try testing.expectEqual(@as(u256, 5000), info.operator_fee_scalar.?);
    try testing.expectEqual(@as(u256, 0x0102030405060708), info.operator_fee_constant.?);
    try testing.expect(info.da_footprint_gas_scalar == null);
}

test "tryFetch Jovian reads DA footprint gas scalar from slot 8 offset 18" {
    var db = MockDatabase.init(testing.allocator);
    defer db.deinit();
    const addr = constants.L1_BLOCK_ADDRESS.bytes;
    // da scalar 400 (0x0190) at [18..20), operator scalar 7 at [20..24), constant 9 at [24..32).
    try db.setStorage(addr, constants.OPERATOR_FEE_SCALARS_SLOT, 0x00000000_00000000_00000000_00000000_00000190_00000007_00000000_00000009);

    const info = try L1BlockInfo.tryFetch(MockDatabase, &db, 300, .JOVIAN);
    try testing.expectEqual(@as(u16, 400), info.da_footprint_gas_scalar.?);
    try testing.expectEqual(@as(u256, 7), info.operator_fee_scalar.?);
    try testing.expectEqual(@as(u256, 9), info.operator_fee_constant.?);
}
