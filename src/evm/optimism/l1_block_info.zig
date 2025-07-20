const std = @import("std");
const primitives = @import("primitives");
const OptimismHardfork = @import("hardfork.zig").OptimismHardfork;
const B256 = @import("crypto").Hash.B256;

/// L1Block contract storage slots
pub const L1BlockSlots = struct {
    /// L1 block number (slot 0)
    pub const NUMBER: u256 = 0;
    /// L1 block timestamp (slot 1) 
    pub const TIMESTAMP: u256 = 1;
    /// L1 base fee (slot 2)
    pub const BASE_FEE: u256 = 2;
    /// L1 block hash (slot 3)
    pub const HASH: u256 = 3;
    /// Sequence number (slot 4)
    pub const SEQUENCE_NUMBER: u256 = 4;
    /// Batcher hash (slot 5) - pre-Ecotone: overhead
    pub const BATCHER_HASH: u256 = 5;
    /// L1 fee overhead (slot 5) - pre-Ecotone only
    pub const L1_FEE_OVERHEAD: u256 = 5;
    /// L1 fee scalar (slot 6) - pre-Ecotone only
    pub const L1_FEE_SCALAR: u256 = 6;
    /// L1 blob base fee (slot 7) - Ecotone+
    pub const BLOB_BASE_FEE: u256 = 7;
    /// L1 base fee scalar (slot 3, packed) - Ecotone+
    pub const BASE_FEE_SCALAR: u256 = 3;
    /// L1 blob base fee scalar (slot 3, packed) - Ecotone+
    pub const BLOB_BASE_FEE_SCALAR: u256 = 3;
    /// Operator fee scalar (slot 8) - Isthmus+
    pub const OPERATOR_FEE_SCALAR: u256 = 8;
    /// Operator fee constant (slot 8) - Isthmus+
    pub const OPERATOR_FEE_CONSTANT: u256 = 8;
};

/// L1 block information from the L1Block contract
pub const L1BlockInfo = struct {
    /// L1 block number
    number: u64,
    /// L1 block timestamp
    timestamp: u64,
    /// L1 base fee
    base_fee: u256,
    /// L1 block hash
    hash: B256,
    /// Sequence number (L2 block number within epoch)
    sequence_number: u64,
    /// Batcher address hash (Ecotone+)
    batcher_hash: ?B256,
    /// L1 fee overhead (pre-Ecotone)
    l1_fee_overhead: ?u256,
    /// L1 fee scalar (pre-Ecotone)
    l1_fee_scalar: ?u256,
    /// L1 blob base fee (Ecotone+)
    blob_base_fee: ?u256,
    /// L1 base fee scalar (Ecotone+)
    base_fee_scalar: ?u32,
    /// L1 blob base fee scalar (Ecotone+)
    blob_base_fee_scalar: ?u32,
    /// Operator fee scalar (Isthmus+)
    operator_fee_scalar: ?u64,
    /// Operator fee constant (Isthmus+)
    operator_fee_constant: ?u64,
    
    /// Decode packed Ecotone fee scalars from slot 3
    pub fn decodeEcotoneFeeScalars(slot3_value: u256) struct { base_fee_scalar: u32, blob_base_fee_scalar: u32 } {
        // Layout: [zeros][blob_base_fee_scalar:32][base_fee_scalar:32]
        const base_fee_scalar = @as(u32, @truncate(slot3_value));
        const blob_base_fee_scalar = @as(u32, @truncate(slot3_value >> 32));
        
        return .{
            .base_fee_scalar = base_fee_scalar,
            .blob_base_fee_scalar = blob_base_fee_scalar,
        };
    }
    
    /// Decode Isthmus operator fee parameters from slot 8
    pub fn decodeOperatorFeeParams(slot8_value: u256) struct { scalar: u64, constant: u64 } {
        // Layout: [zeros][constant:64][scalar:64]
        const scalar = @as(u64, @truncate(slot8_value));
        const constant = @as(u64, @truncate(slot8_value >> 64));
        
        return .{
            .scalar = scalar,
            .constant = constant,
        };
    }
};

/// Constants for L1 data gas calculation
pub const L1GasConstants = struct {
    /// Gas per non-zero byte (16)
    pub const NON_ZERO_BYTE_GAS: u64 = 16;
    /// Gas per zero byte (4)
    pub const ZERO_BYTE_GAS: u64 = 4;
    
    /// Ecotone constants for FastLZ compression estimation
    pub const ECOTONE = struct {
        /// Minimum compressed size is 0.24 * original_size
        pub const MIN_COMPRESSED_SIZE_RATIO: u32 = 24;
        pub const MIN_COMPRESSED_SIZE_DIVISOR: u32 = 100;
    };
    
    /// Fjord constants for improved compression estimation
    pub const FJORD = struct {
        /// FastLZ compression ratio: 0.255 * original_size
        pub const FASTLZ_RATIO: u32 = 255;
        pub const FASTLZ_DIVISOR: u32 = 1000;
        /// Channel compression ratio: 0.21 * original_size
        pub const CHANNEL_RATIO: u32 = 21;
        pub const CHANNEL_DIVISOR: u32 = 100;
    };
};

/// Calculate the L1 data gas for a transaction
pub fn calculateDataGas(data: []const u8) u64 {
    var gas: u64 = 0;
    for (data) |byte| {
        if (byte == 0) {
            gas += L1GasConstants.ZERO_BYTE_GAS;
        } else {
            gas += L1GasConstants.NON_ZERO_BYTE_GAS;
        }
    }
    return gas;
}

test "calculateDataGas" {
    const data = &[_]u8{ 0, 1, 2, 0, 0, 3, 4, 0 };
    const expected = 3 * L1GasConstants.ZERO_BYTE_GAS + 4 * L1GasConstants.NON_ZERO_BYTE_GAS;
    try std.testing.expectEqual(expected, calculateDataGas(data));
}

test "decodeEcotoneFeeScalars" {
    // Example: base_fee_scalar = 1000, blob_base_fee_scalar = 2000
    const slot_value: u256 = 1000 | (@as(u256, 2000) << 32);
    const scalars = L1BlockInfo.decodeEcotoneFeeScalars(slot_value);
    
    try std.testing.expectEqual(@as(u32, 1000), scalars.base_fee_scalar);
    try std.testing.expectEqual(@as(u32, 2000), scalars.blob_base_fee_scalar);
}