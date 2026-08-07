//! L1 Block Info and L1 fee calculation for Optimism.
//!
//! Based on the Rust implementation from op-revm:
//! https://github.com/bluealloy/revm/blob/main/crates/op-revm/src/l1block.rs
//!
//! The L1BlockInfo struct contains L1 block data that is used to calculate
//! the L1 cost of a transaction on Optimism L2.

const std = @import("std");
const primitives = @import("primitives");
const spec_mod = @import("spec.zig");
const constants = @import("constants.zig");
const fast_lz = @import("fast_lz.zig");

const OpSpecId = spec_mod.OpSpecId;

/// L1 block information used for L1 cost calculation.
///
/// We can extract L1 epoch data from each L2 block, by looking at the `setL1BlockValues`
/// transaction data. This data is then used to calculate the L1 cost of a transaction.
pub const L1BlockInfo = struct {
    /// The L2 block number.
    l2_block: u256,
    /// The base fee of the L1 origin block.
    l1_base_fee: u256,
    /// The current L1 fee overhead (Bedrock/Regolith only).
    l1_fee_overhead: ?u256,
    /// The current L1 base fee scalar.
    l1_base_fee_scalar: u256,
    /// The current L1 blob base fee (Ecotone+).
    l1_blob_base_fee: ?u256,
    /// The current L1 blob base fee scalar (Ecotone+).
    l1_blob_base_fee_scalar: ?u256,
    /// The current operator fee scalar (Isthmus+).
    operator_fee_scalar: ?u256,
    /// The current operator fee constant (Isthmus+).
    operator_fee_constant: ?u256,
    /// True if Ecotone is activated but scalars haven't been set yet.
    empty_ecotone_scalars: bool,
    /// Cached L1 cost for this transaction.
    tx_l1_cost: ?u256,

    /// Calculate the L1 cost of a transaction.
    ///
    /// This is the main entry point for L1 fee calculation. It:
    /// 1. Checks if cost is already cached
    /// 2. Handles deposit transactions (0x7E) which have zero L1 cost
    /// 3. Routes to the correct calculation based on spec_id
    pub fn calculateTxL1Cost(self: *L1BlockInfo, tx_data: []const u8, spec_id: OpSpecId) u256 {
        // Return cached value if available
        if (self.tx_l1_cost) |cost| {
            return cost;
        }

        // Deposit transactions (0x7E) and empty data have zero L1 cost
        if (tx_data.len == 0 or (tx_data.len > 0 and tx_data[0] == 0x7E)) {
            return 0;
        }

        // Calculate cost based on hardfork
        const cost = if (spec_id.isAtLeast(.FJORD))
            self.calculateL1CostFjord(tx_data)
        else if (spec_id.isAtLeast(.ECOTONE))
            self.calculateL1CostEcotone(tx_data, spec_id)
        else
            self.calculateL1CostBedrock(tx_data, spec_id);

        // Cache the result
        self.tx_l1_cost = cost;
        return cost;
    }

    /// Calculate L1 cost using Bedrock/Regolith formula.
    ///
    /// Formula: (data_gas + overhead) * l1_base_fee * l1_scalar / 1e6
    ///
    /// Pre-Regolith adds 68 * 16 gas for empty signature overhead.
    pub fn calculateL1CostBedrock(self: L1BlockInfo, tx_data: []const u8, spec_id: OpSpecId) u256 {
        const rollup_data_gas = self.dataGas(tx_data, spec_id);
        const overhead = self.l1_fee_overhead orelse 0;

        // (data_gas + overhead) * l1_base_fee * l1_scalar / 1e6
        var result = rollup_data_gas + overhead;
        result = saturatingMul(result, self.l1_base_fee);
        result = saturatingMul(result, self.l1_base_fee_scalar);
        return result / 1_000_000;
    }

    /// Calculate L1 cost using Ecotone formula.
    ///
    /// Formula: calldata_gas * (l1_base_fee * 16 * l1_base_fee_scalar + l1_blob_base_fee * l1_blob_base_fee_scalar) / (16 * 1e6)
    ///
    /// Edge case: If scalars are empty (first Ecotone block), fall back to Bedrock formula.
    pub fn calculateL1CostEcotone(self: L1BlockInfo, tx_data: []const u8, spec_id: OpSpecId) u256 {
        // Edge case: First Ecotone block uses Bedrock formula
        if (self.empty_ecotone_scalars) {
            return self.calculateL1CostBedrock(tx_data, spec_id);
        }

        const rollup_data_gas = self.dataGas(tx_data, spec_id);
        const l1_fee_scaled = self.calculateL1FeeScaledEcotone();

        // data_gas * l1_fee_scaled / (16 * 1e6)
        const result = saturatingMul(l1_fee_scaled, rollup_data_gas);
        return result / (1_000_000 * constants.NON_ZERO_BYTE_GAS);
    }

    /// Calculate L1 cost using Fjord formula.
    ///
    /// Formula: estimated_size * (base_fee_scalar * l1_base_fee * 16 + blob_scalar * l1_blob_base_fee) / 1e12
    ///
    /// Uses FastLZ compression estimation.
    pub fn calculateL1CostFjord(self: L1BlockInfo, tx_data: []const u8) u256 {
        const l1_fee_scaled = self.calculateL1FeeScaledEcotone();
        const estimated_size = self.txEstimatedSizeFjord(tx_data);

        // estimated_size * l1_fee_scaled / 1e12
        const result = saturatingMul(estimated_size, l1_fee_scaled);
        return result / 1_000_000_000_000;
    }

    /// Calculate operator fee (Isthmus+).
    ///
    /// Formula: (gas_limit * operator_fee_scalar / 1e6) + operator_fee_constant
    ///
    /// Deposit transactions (0x7E) have zero operator fee.
    pub fn calculateOperatorFee(self: L1BlockInfo, tx_data: []const u8, gas_limit: u64) u256 {
        // Deposit transactions have zero operator fee
        if (tx_data.len > 0 and tx_data[0] == 0x7E) {
            return 0;
        }

        return self.operatorFeeChargeInner(gas_limit);
    }

    /// Internal operator fee calculation.
    fn operatorFeeChargeInner(self: L1BlockInfo, gas: u64) u256 {
        const operator_fee_scalar = self.operator_fee_scalar orelse return 0;
        const operator_fee_constant = self.operator_fee_constant orelse return 0;

        // (gas * scalar / 1e6) + constant
        const product = (gas * operator_fee_scalar) / constants.OPERATOR_FEE_SCALAR_DECIMAL;
        return product + operator_fee_constant;
    }

    /// Calculate data gas for posting transaction on L1.
    ///
    /// - Fjord+: Uses FastLZ compression estimation, 16 gas per compressed byte
    /// - Pre-Fjord: 16 gas per non-zero byte, 4 gas per zero byte
    /// - Pre-Regolith: Add 68 * 16 gas for empty signature overhead
    pub fn dataGas(self: L1BlockInfo, tx_data: []const u8, spec_id: OpSpecId) u256 {
        _ = self;

        if (spec_id.isAtLeast(.FJORD)) {
            const estimated_size = txEstimatedSizeFjordInternal(tx_data);
            return (estimated_size * constants.NON_ZERO_BYTE_GAS) / 1_000_000;
        }

        // Count gas: 16 per non-zero byte, 4 per zero byte
        var gas: u64 = 0;
        for (tx_data) |byte| {
            if (byte == 0) {
                gas += constants.ZERO_BYTE_GAS;
            } else {
                gas += constants.NON_ZERO_BYTE_GAS;
            }
        }

        // Pre-Regolith: Add 68 * 16 gas for signature overhead
        if (!spec_id.isAtLeast(.REGOLITH)) {
            gas += 68 * constants.NON_ZERO_BYTE_GAS;
        }

        return gas;
    }

    /// Calculate estimated compressed transaction size for Fjord.
    ///
    /// Formula: max(min_size, fastlz_coef * fastlz_size - intercept)
    ///
    /// All values are scaled by 1e6 for precision.
    fn txEstimatedSizeFjord(self: L1BlockInfo, tx_data: []const u8) u256 {
        _ = self;
        return txEstimatedSizeFjordInternal(tx_data);
    }

    /// Calculate l1_base_fee * 16 * l1_base_fee_scalar + l1_blob_base_fee * l1_blob_base_fee_scalar.
    ///
    /// This is the scaled L1 fee used in Ecotone and Fjord formulas.
    fn calculateL1FeeScaledEcotone(self: L1BlockInfo) u256 {
        const calldata_cost_per_byte = saturatingMul(
            saturatingMul(self.l1_base_fee, constants.NON_ZERO_BYTE_GAS),
            self.l1_base_fee_scalar,
        );

        const blob_cost_per_byte = saturatingMul(
            self.l1_blob_base_fee orelse 0,
            self.l1_blob_base_fee_scalar orelse 0,
        );

        return saturatingAdd(calldata_cost_per_byte, blob_cost_per_byte);
    }

    /// Clear cached L1 cost.
    pub fn clearTxL1Cost(self: *L1BlockInfo) void {
        self.tx_l1_cost = null;
    }

    /// Create L1BlockInfo with default/empty values.
    /// Useful for testing or when L1 block info is not available.
    pub fn empty() L1BlockInfo {
        return L1BlockInfo{
            .l2_block = 0,
            .l1_base_fee = 0,
            .l1_fee_overhead = null,
            .l1_base_fee_scalar = 0,
            .l1_blob_base_fee = null,
            .l1_blob_base_fee_scalar = null,
            .operator_fee_scalar = null,
            .operator_fee_constant = null,
            .empty_ecotone_scalars = false,
            .tx_l1_cost = null,
        };
    }

    /// Try to fetch L1BlockInfo from L2 state database.
    ///
    /// Database interface is duck-typed - must have get_storage(address: [20]u8, key: u256) method.
    /// This reads the L1Block contract storage to populate the L1BlockInfo struct.
    ///
    /// The storage layout differs between hardforks:
    /// - Bedrock/Regolith: overhead and scalar in separate slots (5, 6)
    /// - Ecotone+: blob base fee (slot 7) and packed scalars (slot 3)
    /// - Isthmus+: additional operator fee scalars (slot 8)
    pub fn tryFetch(
        comptime Database: type,
        db: *Database,
        l2_block: u256,
        spec_id: OpSpecId,
    ) !L1BlockInfo {
        const l1_block_addr = constants.L1_BLOCK_ADDRESS.toBytes();

        // Read L1 base fee (always present at slot 1)
        const l1_base_fee = try db.get_storage(l1_block_addr, constants.L1_BASE_FEE_SLOT);

        if (!spec_id.isAtLeast(.ECOTONE)) {
            // Bedrock/Regolith format - use overhead and scalar slots
            const l1_fee_overhead = try db.get_storage(l1_block_addr, constants.L1_OVERHEAD_SLOT);
            const l1_fee_scalar = try db.get_storage(l1_block_addr, constants.L1_SCALAR_SLOT);

            return L1BlockInfo{
                .l2_block = l2_block,
                .l1_base_fee = l1_base_fee,
                .l1_fee_overhead = l1_fee_overhead,
                .l1_base_fee_scalar = l1_fee_scalar,
                .l1_blob_base_fee = null,
                .l1_blob_base_fee_scalar = null,
                .operator_fee_scalar = null,
                .operator_fee_constant = null,
                .empty_ecotone_scalars = false,
                .tx_l1_cost = null,
            };
        }

        // Ecotone+ format: read packed scalars from slot 3, blob base fee from slot 7
        const l1_blob_base_fee = try db.get_storage(l1_block_addr, constants.ECOTONE_L1_BLOB_BASE_FEE_SLOT);
        const fee_scalars = try db.get_storage(l1_block_addr, constants.ECOTONE_L1_FEE_SCALARS_SLOT);

        // Extract packed scalars: base_fee_scalar at bytes 16-19, blob_scalar at bytes 20-23
        // Inline extraction to avoid u256 function parameter issues in FFI builds
        const base_fee_scalar = blk: {
            const shift: u8 = @intCast((32 - constants.BASE_FEE_SCALAR_OFFSET - 4) * 8);
            break :blk (fee_scalars >> shift) & 0xFFFFFFFF;
        };
        const blob_base_fee_scalar = blk: {
            const shift: u8 = @intCast((32 - constants.BLOB_BASE_FEE_SCALAR_OFFSET - 4) * 8);
            break :blk (fee_scalars >> shift) & 0xFFFFFFFF;
        };

        // Empty scalars edge case (first Ecotone block)
        const empty_ecotone_scalars = (l1_blob_base_fee == 0 and base_fee_scalar == 0 and blob_base_fee_scalar == 0);

        var info = L1BlockInfo{
            .l2_block = l2_block,
            .l1_base_fee = l1_base_fee,
            .l1_fee_overhead = null,
            .l1_base_fee_scalar = base_fee_scalar,
            .l1_blob_base_fee = l1_blob_base_fee,
            .l1_blob_base_fee_scalar = blob_base_fee_scalar,
            .operator_fee_scalar = null,
            .operator_fee_constant = null,
            .empty_ecotone_scalars = empty_ecotone_scalars,
            .tx_l1_cost = null,
        };

        // Isthmus+: read operator fee scalars from slot 8
        if (spec_id.isAtLeast(.ISTHMUS)) {
            const op_fee_scalars = try db.get_storage(l1_block_addr, constants.OPERATOR_FEE_SCALARS_SLOT);
            info.operator_fee_scalar = blk: {
                const shift: u8 = @intCast((32 - constants.OPERATOR_FEE_SCALAR_OFFSET - 4) * 8);
                break :blk (op_fee_scalars >> shift) & 0xFFFFFFFF;
            };
            info.operator_fee_constant = blk: {
                const shift: u8 = @intCast((32 - constants.OPERATOR_FEE_CONSTANT_OFFSET - 4) * 8);
                break :blk (op_fee_scalars >> shift) & 0xFFFFFFFF;
            };
        }

        return info;
    }
};

/// Mock database for testing L1BlockInfo.tryFetch().
///
/// Provides a simple in-memory storage implementation.
pub const MockDatabase = struct {
    storage: std.AutoHashMap(StorageKey, u256),
    allocator: std.mem.Allocator,

    const StorageKey = struct {
        address: [20]u8,
        slot: u256,
    };

    pub fn init(allocator: std.mem.Allocator) MockDatabase {
        return MockDatabase{
            .storage = std.AutoHashMap(StorageKey, u256).init(allocator),
            .allocator = allocator,
        };
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

// Helper functions

fn txEstimatedSizeFjordInternal(tx_data: []const u8) u256 {
    const fastlz_size: u64 = fast_lz.flzCompressLen(tx_data);

    // estimated = fastlz_coef * fastlz_size - intercept (with saturating subtraction)
    // Using saturating arithmetic to prevent underflow
    const product = fastlz_size *| constants.FJORD_COMPRESSION_INTERCEPT;
    const estimated = product -| constants.FJORD_MIN_TX_SIZE;

    // Return max(min_size, estimated)
    const min_size = constants.FJORD_MAX_TX_SIZE;
    return @max(min_size, estimated);
}

fn saturatingAdd(a: u256, b: u256) u256 {
    return a +| b;
}

fn saturatingMul(a: u256, b: u256) u256 {
    return a *| b;
}

// Tests
test "L1BlockInfo - Bedrock basic calculation" {
    const info = L1BlockInfo{
        .l2_block = 0,
        .l1_base_fee = 1_000_000_000, // 1 gwei
        .l1_fee_overhead = 2100,
        .l1_base_fee_scalar = 1_000_000,
        .l1_blob_base_fee = null,
        .l1_blob_base_fee_scalar = null,
        .operator_fee_scalar = null,
        .operator_fee_constant = null,
        .empty_ecotone_scalars = false,
        .tx_l1_cost = null,
    };

    const tx = [_]u8{ 0x01, 0x02, 0x03 }; // 3 non-zero bytes = 48 gas
    const cost = info.calculateL1CostBedrock(&tx, .REGOLITH);

    // Expected: (48 + 2100) * 1e9 * 1e6 / 1e6 = 2148 * 1e9 = 2,148,000,000,000 wei
    try std.testing.expectEqual(@as(u256, 2_148_000_000_000), cost);
}

test "L1BlockInfo - Bedrock with pre-Regolith overhead" {
    const info = L1BlockInfo{
        .l2_block = 0,
        .l1_base_fee = 1_000,
        .l1_fee_overhead = 1_000,
        .l1_base_fee_scalar = 1_000_000,
        .l1_blob_base_fee = null,
        .l1_blob_base_fee_scalar = null,
        .operator_fee_scalar = null,
        .operator_fee_constant = null,
        .empty_ecotone_scalars = false,
        .tx_l1_cost = null,
    };

    const tx = [_]u8{ 0xFA, 0xCA, 0xDE }; // 3 non-zero bytes
    const cost = info.calculateL1CostBedrock(&tx, .BEDROCK);

    // Pre-Regolith adds 68 * 16 = 1088 gas
    // data_gas = 48 + 1088 = 1136
    // cost = (1136 + 1000) * 1000 * 1_000_000 / 1_000_000 = 2136 * 1000 = 2,136,000
    try std.testing.expectEqual(@as(u256, 2_136_000), cost);
}

test "L1BlockInfo - Ecotone basic calculation" {
    const info = L1BlockInfo{
        .l2_block = 0,
        .l1_base_fee = 1_000,
        .l1_fee_overhead = null,
        .l1_base_fee_scalar = 1_000,
        .l1_blob_base_fee = 1_000,
        .l1_blob_base_fee_scalar = 1_000,
        .operator_fee_scalar = null,
        .operator_fee_constant = null,
        .empty_ecotone_scalars = false,
        .tx_l1_cost = null,
    };

    const tx = [_]u8{ 0xFA, 0xCA, 0xDE }; // 3 non-zero bytes = 48 gas
    const cost = info.calculateL1CostEcotone(&tx, .ECOTONE);

    // calldata_cost = 1000 * 16 * 1000 = 16_000_000
    // blob_cost = 1000 * 1000 = 1_000_000
    // l1_fee_scaled = 17_000_000
    // cost = 48 * 17_000_000 / (16 * 1_000_000) = 816_000_000 / 16_000_000 = 51
    try std.testing.expectEqual(@as(u256, 51), cost);
}

test "L1BlockInfo - Ecotone with empty scalars falls back to Bedrock" {
    var info = L1BlockInfo{
        .l2_block = 0,
        .l1_base_fee = 1_000,
        .l1_fee_overhead = 1_000,
        .l1_base_fee_scalar = 1_000_000,
        .l1_blob_base_fee = 0,
        .l1_blob_base_fee_scalar = 0,
        .operator_fee_scalar = null,
        .operator_fee_constant = null,
        .empty_ecotone_scalars = true,
        .tx_l1_cost = null,
    };

    const tx = [_]u8{ 0xFA, 0xCA, 0xDE };
    const cost = info.calculateL1CostEcotone(&tx, .ECOTONE);

    // Should use Bedrock formula: (48 + 1000) * 1000 * 1_000_000 / 1_000_000 = 1048 * 1000 = 1,048,000
    try std.testing.expectEqual(@as(u256, 1_048_000), cost);
}

test "L1BlockInfo - Fjord basic calculation" {
    const info = L1BlockInfo{
        .l2_block = 0,
        .l1_base_fee = 1_000,
        .l1_fee_overhead = null,
        .l1_base_fee_scalar = 1_000,
        .l1_blob_base_fee = 1_000,
        .l1_blob_base_fee_scalar = 1_000,
        .operator_fee_scalar = null,
        .operator_fee_constant = null,
        .empty_ecotone_scalars = false,
        .tx_l1_cost = null,
    };

    const tx = [_]u8{ 0xFA, 0xCA, 0xDE };
    const cost = info.calculateL1CostFjord(&tx);

    // fastlz_size = 4
    // estimated = max(100e6, 836500 * 4 - 42585600) = max(100e6, 3346000 - 42585600)
    // = max(100e6, -39239600) = 100e6
    // l1_fee_scaled = 17_000_000
    // cost = 100_000_000 * 17_000_000 / 1e12 = 1,700,000,000,000 / 1e12 = 1700
    try std.testing.expectEqual(@as(u256, 1700), cost);
}

test "L1BlockInfo - deposit transaction has zero cost" {
    var info = L1BlockInfo{
        .l2_block = 0,
        .l1_base_fee = 1_000_000_000,
        .l1_fee_overhead = 2100,
        .l1_base_fee_scalar = 1_000_000,
        .l1_blob_base_fee = null,
        .l1_blob_base_fee_scalar = null,
        .operator_fee_scalar = null,
        .operator_fee_constant = null,
        .empty_ecotone_scalars = false,
        .tx_l1_cost = null,
    };

    const deposit_tx = [_]u8{ 0x7E, 0xFA, 0xCA, 0xDE };
    const cost = info.calculateTxL1Cost(&deposit_tx, .REGOLITH);

    try std.testing.expectEqual(@as(u256, 0), cost);
}

test "L1BlockInfo - empty transaction has zero cost" {
    var info = L1BlockInfo{
        .l2_block = 0,
        .l1_base_fee = 1_000_000_000,
        .l1_fee_overhead = 2100,
        .l1_base_fee_scalar = 1_000_000,
        .l1_blob_base_fee = null,
        .l1_blob_base_fee_scalar = null,
        .operator_fee_scalar = null,
        .operator_fee_constant = null,
        .empty_ecotone_scalars = false,
        .tx_l1_cost = null,
    };

    const empty_tx = [_]u8{};
    const cost = info.calculateTxL1Cost(&empty_tx, .REGOLITH);

    try std.testing.expectEqual(@as(u256, 0), cost);
}

test "L1BlockInfo - data gas calculation with zeros" {
    const info = L1BlockInfo{
        .l2_block = 0,
        .l1_base_fee = 1_000_000,
        .l1_fee_overhead = 0,
        .l1_base_fee_scalar = 1_000_000,
        .l1_blob_base_fee = null,
        .l1_blob_base_fee_scalar = null,
        .operator_fee_scalar = null,
        .operator_fee_constant = null,
        .empty_ecotone_scalars = false,
        .tx_l1_cost = null,
    };

    // 0xFA00CA00DE = 3 non-zero, 2 zero = 3*16 + 2*4 = 56 gas
    const tx = [_]u8{ 0xFA, 0x00, 0xCA, 0x00, 0xDE };
    const gas = info.dataGas(&tx, .REGOLITH);

    try std.testing.expectEqual(@as(u256, 56), gas);
}

test "L1BlockInfo - data gas pre-Regolith adds overhead" {
    const info = L1BlockInfo{
        .l2_block = 0,
        .l1_base_fee = 1_000_000,
        .l1_fee_overhead = 0,
        .l1_base_fee_scalar = 1_000_000,
        .l1_blob_base_fee = null,
        .l1_blob_base_fee_scalar = null,
        .operator_fee_scalar = null,
        .operator_fee_constant = null,
        .empty_ecotone_scalars = false,
        .tx_l1_cost = null,
    };

    const tx = [_]u8{ 0xFA, 0xCA, 0xDE }; // 3 * 16 = 48
    const gas = info.dataGas(&tx, .BEDROCK);

    // Pre-Regolith adds 68 * 16 = 1088
    // Total = 48 + 1088 = 1136
    try std.testing.expectEqual(@as(u256, 1136), gas);
}

test "L1BlockInfo - operator fee calculation" {
    const info = L1BlockInfo{
        .l2_block = 0,
        .l1_base_fee = 1_000_000,
        .l1_fee_overhead = null,
        .l1_base_fee_scalar = 1_000_000,
        .l1_blob_base_fee = null,
        .l1_blob_base_fee_scalar = null,
        .operator_fee_scalar = 2_000,
        .operator_fee_constant = 5,
        .empty_ecotone_scalars = false,
        .tx_l1_cost = null,
    };

    const tx = [_]u8{ 0x01 };
    const fee = info.calculateOperatorFee(&tx, 50_000);

    // (50_000 * 2_000 / 1_000_000) + 5 = (100_000_000 / 1_000_000) + 5 = 100 + 5 = 105
    try std.testing.expectEqual(@as(u256, 105), fee);
}

test "L1BlockInfo - operator fee deposit is zero" {
    const info = L1BlockInfo{
        .l2_block = 0,
        .l1_base_fee = 1_000_000,
        .l1_fee_overhead = null,
        .l1_base_fee_scalar = 1_000_000,
        .l1_blob_base_fee = null,
        .l1_blob_base_fee_scalar = null,
        .operator_fee_scalar = 2_000,
        .operator_fee_constant = 5,
        .empty_ecotone_scalars = false,
        .tx_l1_cost = null,
    };

    const deposit_tx = [_]u8{ 0x7E, 0x01 };
    const fee = info.calculateOperatorFee(&deposit_tx, 50_000);

    try std.testing.expectEqual(@as(u256, 0), fee);
}

test "L1BlockInfo - caching works correctly" {
    var info = L1BlockInfo{
        .l2_block = 0,
        .l1_base_fee = 1_000,
        .l1_fee_overhead = 1_000,
        .l1_base_fee_scalar = 1_000_000,
        .l1_blob_base_fee = null,
        .l1_blob_base_fee_scalar = null,
        .operator_fee_scalar = null,
        .operator_fee_constant = null,
        .empty_ecotone_scalars = false,
        .tx_l1_cost = null,
    };

    const tx = [_]u8{ 0xFA, 0xCA, 0xDE };
    const cost1 = info.calculateTxL1Cost(&tx, .REGOLITH);
    const cost2 = info.calculateTxL1Cost(&tx, .REGOLITH); // Should return cached value

    try std.testing.expectEqual(cost1, cost2);
    try std.testing.expect(info.tx_l1_cost != null);

    // Clear cache and recalculate
    info.clearTxL1Cost();
    try std.testing.expect(info.tx_l1_cost == null);

    const cost3 = info.calculateTxL1Cost(&tx, .REGOLITH);
    try std.testing.expectEqual(cost1, cost3);
}

test "L1BlockInfo - empty constructor" {
    const info = L1BlockInfo.empty();

    try std.testing.expectEqual(@as(u256, 0), info.l2_block);
    try std.testing.expectEqual(@as(u256, 0), info.l1_base_fee);
    try std.testing.expect(info.l1_fee_overhead == null);
    try std.testing.expectEqual(@as(u256, 0), info.l1_base_fee_scalar);
    try std.testing.expect(info.l1_blob_base_fee == null);
    try std.testing.expect(info.l1_blob_base_fee_scalar == null);
    try std.testing.expect(info.operator_fee_scalar == null);
    try std.testing.expect(info.operator_fee_constant == null);
    try std.testing.expect(!info.empty_ecotone_scalars);
    try std.testing.expect(info.tx_l1_cost == null);
}

test "extractScalar - extracts 4 bytes at offset" {
    // Packed u256 with known values at specific offsets
    // Bytes 16-19: 0x00000558 (1368)
    // Bytes 20-23: 0x000C5E75 (810,613)
    // Full value: 0x00000000_00000000_00000000_00000000_00000558_000C5E75_00000000_00000000
    const packed: u256 = 0x00000000_00000000_00000000_00000000_00000558_000C5E75_00000000_00000000;

    const base_fee_scalar = L1BlockInfo.extractScalar(packed, 16);
    const blob_base_fee_scalar = L1BlockInfo.extractScalar(packed, 20);

    try std.testing.expectEqual(@as(u256, 1368), base_fee_scalar);
    try std.testing.expectEqual(@as(u256, 810_613), blob_base_fee_scalar);
}

test "extractScalar - handles max u32 value" {
    // Bytes 16-19: 0xFFFFFFFF
    const packed: u256 = 0x00000000_00000000_00000000_00000000_FFFFFFFF_00000000_00000000_00000000;

    const value = L1BlockInfo.extractScalar(packed, 16);
    try std.testing.expectEqual(@as(u256, 0xFFFFFFFF), value);
}

test "extractScalar - handles zero" {
    const packed: u256 = 0;
    const value = L1BlockInfo.extractScalar(packed, 16);
    try std.testing.expectEqual(@as(u256, 0), value);
}

test "L1BlockInfo.tryFetch - Bedrock format" {
    var mock_db = MockDatabase.init(std.testing.allocator);
    defer mock_db.deinit();

    const l1_block_addr = constants.L1_BLOCK_ADDRESS.toBytes();
    try mock_db.setStorage(l1_block_addr, constants.L1_BASE_FEE_SLOT, 1_000_000_000);
    try mock_db.setStorage(l1_block_addr, constants.L1_OVERHEAD_SLOT, 2100);
    try mock_db.setStorage(l1_block_addr, constants.L1_SCALAR_SLOT, 1_000_000);

    const info = try L1BlockInfo.tryFetch(MockDatabase, &mock_db, 100, .BEDROCK);

    try std.testing.expectEqual(@as(u256, 100), info.l2_block);
    try std.testing.expectEqual(@as(u256, 1_000_000_000), info.l1_base_fee);
    try std.testing.expectEqual(@as(u256, 2100), info.l1_fee_overhead.?);
    try std.testing.expectEqual(@as(u256, 1_000_000), info.l1_base_fee_scalar);
    try std.testing.expect(info.l1_blob_base_fee == null);
    try std.testing.expect(info.l1_blob_base_fee_scalar == null);
    try std.testing.expect(!info.empty_ecotone_scalars);
}

test "L1BlockInfo.tryFetch - Ecotone format with packed scalars" {
    var mock_db = MockDatabase.init(std.testing.allocator);
    defer mock_db.deinit();

    const l1_block_addr = constants.L1_BLOCK_ADDRESS.toBytes();

    // L1 base fee
    try mock_db.setStorage(l1_block_addr, constants.L1_BASE_FEE_SLOT, 47_036_678_951);

    // Blob base fee
    try mock_db.setStorage(l1_block_addr, constants.ECOTONE_L1_BLOB_BASE_FEE_SLOT, 57_422_457_042);

    // Packed scalars: base_fee_scalar = 1368 at bytes 16-19, blob_scalar = 810949 at bytes 20-23
    // 1368 = 0x558, 810949 = 0xC5E45
    const packed_scalars: u256 = 0x00000000_00000000_00000000_00000000_00000558_000C5E45_00000000_00000000;
    try mock_db.setStorage(l1_block_addr, constants.ECOTONE_L1_FEE_SCALARS_SLOT, packed_scalars);

    const info = try L1BlockInfo.tryFetch(MockDatabase, &mock_db, 118024092, .ECOTONE);

    try std.testing.expectEqual(@as(u256, 118024092), info.l2_block);
    try std.testing.expectEqual(@as(u256, 47_036_678_951), info.l1_base_fee);
    try std.testing.expect(info.l1_fee_overhead == null);
    try std.testing.expectEqual(@as(u256, 1368), info.l1_base_fee_scalar);
    try std.testing.expectEqual(@as(u256, 57_422_457_042), info.l1_blob_base_fee.?);
    try std.testing.expectEqual(@as(u256, 810_949), info.l1_blob_base_fee_scalar.?);
    try std.testing.expect(!info.empty_ecotone_scalars);
}

test "L1BlockInfo.tryFetch - empty scalars edge case" {
    var mock_db = MockDatabase.init(std.testing.allocator);
    defer mock_db.deinit();

    const l1_block_addr = constants.L1_BLOCK_ADDRESS.toBytes();

    // L1 base fee present but all scalars zero (first Ecotone block)
    try mock_db.setStorage(l1_block_addr, constants.L1_BASE_FEE_SLOT, 1_000_000_000);
    try mock_db.setStorage(l1_block_addr, constants.ECOTONE_L1_BLOB_BASE_FEE_SLOT, 0);
    try mock_db.setStorage(l1_block_addr, constants.ECOTONE_L1_FEE_SCALARS_SLOT, 0);

    const info = try L1BlockInfo.tryFetch(MockDatabase, &mock_db, 100, .ECOTONE);

    try std.testing.expect(info.empty_ecotone_scalars);
    try std.testing.expectEqual(@as(u256, 0), info.l1_base_fee_scalar);
    try std.testing.expectEqual(@as(u256, 0), info.l1_blob_base_fee.?);
    try std.testing.expectEqual(@as(u256, 0), info.l1_blob_base_fee_scalar.?);
}

test "L1BlockInfo.tryFetch - Isthmus with operator fees" {
    var mock_db = MockDatabase.init(std.testing.allocator);
    defer mock_db.deinit();

    const l1_block_addr = constants.L1_BLOCK_ADDRESS.toBytes();

    // Base fees
    try mock_db.setStorage(l1_block_addr, constants.L1_BASE_FEE_SLOT, 1_000_000_000);
    try mock_db.setStorage(l1_block_addr, constants.ECOTONE_L1_BLOB_BASE_FEE_SLOT, 1_000_000);

    // Packed fee scalars
    const packed_scalars: u256 = 0x00000000_00000000_00000000_00000000_00001000_00002000_00000000_00000000;
    try mock_db.setStorage(l1_block_addr, constants.ECOTONE_L1_FEE_SCALARS_SLOT, packed_scalars);

    // Operator fee scalars: scalar = 5000 at bytes 20-23, constant = 100 at bytes 24-27
    // 5000 = 0x1388, 100 = 0x64
    const packed_op_scalars: u256 = 0x00000000_00000000_00000000_00000000_00000000_00001388_00000064_00000000;
    try mock_db.setStorage(l1_block_addr, constants.OPERATOR_FEE_SCALARS_SLOT, packed_op_scalars);

    const info = try L1BlockInfo.tryFetch(MockDatabase, &mock_db, 200, .ISTHMUS);

    try std.testing.expectEqual(@as(u256, 5000), info.operator_fee_scalar.?);
    try std.testing.expectEqual(@as(u256, 100), info.operator_fee_constant.?);
}
