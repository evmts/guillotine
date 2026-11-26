//! Base transaction fee charging and distribution.
//!
//! Base uses the OP Stack fee model (op-revm handler.rs `validate_against_state_and_deduct_caller`,
//! `reimburse_caller`, `reward_beneficiary`). For a non-deposit transaction:
//!
//!   upfront  = gas_limit * gas_price + value + L1 data fee + operator_fee(gas_limit)
//!
//!   after execution (gas_used = gas after refunds):
//!     SequencerFeeVault (block coinbase) += gas_used * (gas_price - base_fee)
//!     BaseFeeVault                       += gas_used * base_fee
//!     L1FeeVault                         += L1 data fee
//!     OperatorFeeVault                   += operator_fee(gas_used)        (Isthmus+)
//!     caller refund                       = (gas_limit - gas_used) * gas_price
//!                                         + operator_fee(gas_limit) - operator_fee(gas_used)
//!
//! Deposits (type 0x7E) pay none of these.
//! Formulas for the L1 data fee and operator fee live in ../optimism/l1_block_info.zig.

const std = @import("std");
const OpSpecId = @import("../optimism/spec.zig").OpSpecId;
const constants = @import("../optimism/constants.zig");
const l1_block_info = @import("../optimism/l1_block_info.zig");
const da_footprint = @import("../optimism/da_footprint.zig");

pub const L1BlockInfo = l1_block_info.L1BlockInfo;
pub const txDaFootprint = da_footprint.txDaFootprint;
pub const blockDaFootprint = da_footprint.blockDaFootprint;
pub const validateBlockDaFootprint = da_footprint.validateBlockDaFootprint;

pub const FeeError = error{
    GasUsedExceedsGasLimit,
    GasPriceBelowBaseFee,
} || l1_block_info.OperatorFeeError;

/// Amounts credited after a transaction executes.
pub const Settlement = struct {
    sequencer_fee_vault: u256,
    base_fee_vault: u256,
    l1_fee_vault: u256,
    operator_fee_vault: u256,
    caller_refund: u256,

    pub const ZERO = Settlement{
        .sequencer_fee_vault = 0,
        .base_fee_vault = 0,
        .l1_fee_vault = 0,
        .operator_fee_vault = 0,
        .caller_refund = 0,
    };

    pub fn total(self: Settlement) u256 {
        return self.sequencer_fee_vault +| self.base_fee_vault +| self.l1_fee_vault +|
            self.operator_fee_vault +| self.caller_refund;
    }
};

fn isDeposit(enveloped_tx: []const u8) bool {
    return enveloped_tx.len > 0 and enveloped_tx[0] == constants.DEPOSIT_TRANSACTION_TYPE;
}

/// Balance the caller must hold and is debited before execution.
/// `gas_price` is the effective gas price (EIP-1559: min(max_fee, base_fee + max_priority)).
pub fn upfrontCost(
    info: *L1BlockInfo,
    spec: OpSpecId,
    enveloped_tx: []const u8,
    gas_limit: u64,
    gas_price: u256,
    value: u256,
) FeeError!u256 {
    if (isDeposit(enveloped_tx)) return 0;
    const gas_cost = @as(u256, gas_limit) *| gas_price;
    const l2_extra = try info.txCost(enveloped_tx, gas_limit, spec);
    return gas_cost +| value +| l2_extra;
}

/// Fee distribution and caller refund after execution.
pub fn settle(
    info: *L1BlockInfo,
    spec: OpSpecId,
    enveloped_tx: []const u8,
    gas_limit: u64,
    gas_used: u64,
    base_fee: u256,
    gas_price: u256,
) FeeError!Settlement {
    if (isDeposit(enveloped_tx)) return Settlement.ZERO;
    if (gas_used > gas_limit) return error.GasUsedExceedsGasLimit;
    if (gas_price < base_fee) return error.GasPriceBelowBaseFee;

    const used = @as(u256, gas_used);
    return .{
        .sequencer_fee_vault = used *| (gas_price - base_fee),
        .base_fee_vault = used *| base_fee,
        .l1_fee_vault = info.calculateTxL1Cost(enveloped_tx, spec),
        .operator_fee_vault = try info.operatorFee(enveloped_tx, gas_used, spec),
        .caller_refund = (@as(u256, gas_limit - gas_used) *| gas_price) +|
            try info.operatorFeeRefund(gas_limit, gas_used, spec),
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn jovianInfo() L1BlockInfo {
    var info = L1BlockInfo.empty();
    // Illustrative L1Block values (not taken from a specific Base block).
    info.l1_base_fee = 1_055_991_687;
    info.l1_base_fee_scalar = 2269;
    info.l1_blob_base_fee = 1;
    info.l1_blob_base_fee_scalar = 1_055_762;
    info.operator_fee_scalar = 0;
    info.operator_fee_constant = 0;
    info.da_footprint_gas_scalar = 400;
    return info;
}

const EIP1559_TX = [_]u8{0x02} ++ @as([120]u8, @splat(0xAB));

test "upfront cost equals settlement total plus value for every spec" {
    for (OpSpecId.ALL) |spec| {
        var info = jovianInfo();
        info.l1_fee_overhead = 188;
        info.operator_fee_scalar = 1_500;
        info.operator_fee_constant = 7;
        const gas_limit: u64 = 100_000;
        const gas_used: u64 = 63_421;
        const base_fee: u256 = 5_000_000;
        const gas_price: u256 = 6_000_000;
        const value: u256 = 12345;
        const upfront = try upfrontCost(&info, spec, &EIP1559_TX, gas_limit, gas_price, value);
        const settlement = try settle(&info, spec, &EIP1559_TX, gas_limit, gas_used, base_fee, gas_price);
        info.clearTxL1Cost();
        // Conservation: every wei charged up front is distributed or refunded.
        try testing.expectEqual(upfront, settlement.total() + value);
        if (spec.isBefore(.ISTHMUS)) try testing.expectEqual(@as(u256, 0), settlement.operator_fee_vault);
    }
}

test "settlement splits base fee and priority fee" {
    var info = jovianInfo();
    const s = try settle(&info, .JOVIAN, &EIP1559_TX, 50_000, 21_000, 100, 150);
    try testing.expectEqual(@as(u256, 21_000 * 50), s.sequencer_fee_vault);
    try testing.expectEqual(@as(u256, 21_000 * 100), s.base_fee_vault);
    try testing.expectEqual(@as(u256, 29_000 * 150), s.caller_refund);
    try testing.expect(s.l1_fee_vault > 0);
    try testing.expectEqual(@as(u256, 0), s.operator_fee_vault);
}

test "Isthmus operator fee: gas_used * scalar / 1e6 + constant" {
    var info = jovianInfo();
    info.operator_fee_scalar = 2_000_000; // 2 wei per gas
    info.operator_fee_constant = 1_000;
    const s = try settle(&info, .ISTHMUS, &EIP1559_TX, 50_000, 21_000, 100, 100);
    try testing.expectEqual(@as(u256, 21_000 * 2 + 1_000), s.operator_fee_vault);
    // Refund covers the unused 29,000 gas of operator fee.
    try testing.expectEqual(@as(u256, 29_000 * 100 + 29_000 * 2), s.caller_refund);
}

test "Jovian operator fee: gas_used * scalar * 100 + constant" {
    var info = jovianInfo();
    info.operator_fee_scalar = 3;
    info.operator_fee_constant = 1_000;
    const s = try settle(&info, .JOVIAN, &EIP1559_TX, 50_000, 21_000, 100, 100);
    try testing.expectEqual(@as(u256, 21_000 * 3 * 100 + 1_000), s.operator_fee_vault);
}

test "deposits pay no fees" {
    var info = jovianInfo();
    info.operator_fee_scalar = 3;
    info.operator_fee_constant = 1_000;
    const deposit = [_]u8{ 0x7E, 0x01, 0x02 };
    try testing.expectEqual(@as(u256, 0), try upfrontCost(&info, .JOVIAN, &deposit, 1_000_000, 0, 5));
    const s = try settle(&info, .JOVIAN, &deposit, 1_000_000, 50_000, 100, 0);
    try testing.expectEqual(@as(u256, 0), s.total());
}

test "settle rejects inconsistent inputs" {
    var info = jovianInfo();
    try testing.expectError(error.GasUsedExceedsGasLimit, settle(&info, .JOVIAN, &EIP1559_TX, 100, 101, 1, 1));
    try testing.expectError(error.GasPriceBelowBaseFee, settle(&info, .JOVIAN, &EIP1559_TX, 100, 50, 2, 1));
}

test "Jovian DA footprint on a Base block" {
    const user = [_]u8{0x02} ++ @as([10]u8, @splat(0x11));
    const deposit = [_]u8{0x7E} ++ @as([10]u8, @splat(0x11));
    const txs = [_][]const u8{ &deposit, &user, &user };
    const footprint = blockDaFootprint(&txs, 400);
    try testing.expectEqual(@as(u64, 2 * 100 * 400), footprint);
    try validateBlockDaFootprint(footprint, 150_000_000);
    try testing.expectError(error.DaFootprintExceedsGasLimit, validateBlockDaFootprint(footprint, footprint - 1));
}
