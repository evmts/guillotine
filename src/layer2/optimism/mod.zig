//! OP Stack execution rules shared by OP Mainnet, Base, and other OP Stack chains.
pub const spec = @import("spec.zig");
pub const constants = @import("constants.zig");
pub const l1_block_info = @import("l1_block_info.zig");
pub const fast_lz = @import("fast_lz.zig");
pub const transaction = @import("transaction.zig");
pub const deposit = @import("deposit.zig");
pub const da_footprint = @import("da_footprint.zig");
pub const eip1559 = @import("eip1559.zig");
pub const precompiles = @import("precompiles.zig");

pub const OpSpecId = spec.OpSpecId;
pub const L1BlockInfo = l1_block_info.L1BlockInfo;
pub const MockDatabase = l1_block_info.MockDatabase;
pub const DepositTransactionParts = transaction.DepositTransactionParts;
pub const OpTransactionData = transaction.OpTransactionData;
pub const OpTxType = transaction.OpTxType;
pub const getOptimismPrecompileOverrides = precompiles.overrides;

test "optimism module re-exports OpSpecId and deposit constants" {
    const std = @import("std");
    try std.testing.expect(OpSpecId.JOVIAN.isAtLeast(.BEDROCK));
    try std.testing.expectEqual(@as(u8, 0x7e), @backingInt(OpTxType.Deposit));
}
