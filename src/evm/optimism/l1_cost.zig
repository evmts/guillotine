const std = @import("std");
const primitives = @import("primitives");
const L1BlockInfo = @import("l1_block_info.zig").L1BlockInfo;
const L1GasConstants = @import("l1_block_info.zig").L1GasConstants;
const OptimismRules = @import("hardfork.zig").OptimismRules;
const calculateDataGas = @import("l1_block_info.zig").calculateDataGas;

/// Calculate L1 cost for a transaction based on Optimism rules
pub fn calculateL1Cost(
    tx_data: []const u8,
    l1_block_info: L1BlockInfo,
    op_rules: OptimismRules,
) u256 {
    if (op_rules.isEcotone()) {
        return calculateEcotoneL1Cost(tx_data, l1_block_info, op_rules.isFjord());
    } else {
        return calculatePreEcotoneL1Cost(tx_data, l1_block_info);
    }
}

/// Pre-Ecotone L1 cost calculation
/// Formula: (data_gas + overhead) * scalar * base_fee / 1e6
fn calculatePreEcotoneL1Cost(tx_data: []const u8, l1_block_info: L1BlockInfo) u256 {
    const data_gas = calculateDataGas(tx_data);
    const overhead = l1_block_info.l1_fee_overhead orelse 0;
    const scalar = l1_block_info.l1_fee_scalar orelse 0;
    
    // (data_gas + overhead) * scalar * base_fee / 1e6
    const total_gas = @as(u256, data_gas) + overhead;
    const scaled = total_gas * scalar;
    const with_base_fee = scaled * l1_block_info.base_fee;
    
    // Divide by 1e6 for scalar precision
    return with_base_fee / 1_000_000;
}

/// Ecotone+ L1 cost calculation with compression estimation
fn calculateEcotoneL1Cost(tx_data: []const u8, l1_block_info: L1BlockInfo, is_fjord: bool) u256 {
    const base_fee = l1_block_info.base_fee;
    const blob_base_fee = l1_block_info.blob_base_fee orelse 0;
    const base_fee_scalar = l1_block_info.base_fee_scalar orelse 0;
    const blob_base_fee_scalar = l1_block_info.blob_base_fee_scalar orelse 0;
    
    // Estimate compressed size
    const compressed_size = if (is_fjord)
        estimateFjordCompressedSize(tx_data)
    else
        estimateEcotoneCompressedSize(tx_data);
    
    // Calculate weighted gas price
    // weighted_gas_price = base_fee_scalar * base_fee * 16 + blob_base_fee_scalar * blob_base_fee
    const scaled_base_fee = @as(u256, base_fee_scalar) * base_fee * 16;
    const scaled_blob_fee = @as(u256, blob_base_fee_scalar) * blob_base_fee;
    const weighted_gas_price = scaled_base_fee + scaled_blob_fee;
    
    // L1 cost = compressed_size * weighted_gas_price / 1e12
    const cost = compressed_size * weighted_gas_price;
    
    // Divide by 1e12 for precision (1e6 for scalars * 1e6 for additional precision)
    return cost / 1_000_000_000_000;
}

/// Estimate compressed size using Ecotone formula
fn estimateEcotoneCompressedSize(data: []const u8) u256 {
    const original_size = @as(u256, data.len);
    
    // Minimum compressed size is 24% of original
    const min_size = (original_size * L1GasConstants.ECOTONE.MIN_COMPRESSED_SIZE_RATIO) / 
                     L1GasConstants.ECOTONE.MIN_COMPRESSED_SIZE_DIVISOR;
    
    // Count zero bytes for better estimation
    var zero_count: u256 = 0;
    for (data) |byte| {
        if (byte == 0) zero_count += 1;
    }
    
    // Estimate based on zero byte ratio
    // More zeros = better compression
    const non_zero_count = original_size - zero_count;
    const estimated = zero_count / 4 + non_zero_count;
    
    return @max(estimated, min_size);
}

/// Estimate compressed size using Fjord formula
fn estimateFjordCompressedSize(data: []const u8) u256 {
    const original_size = @as(u256, data.len);
    
    if (original_size == 0) return 0;
    
    // FastLZ estimation: 0.255 * original_size
    const fastlz_size = (original_size * L1GasConstants.FJORD.FASTLZ_RATIO) / 
                        L1GasConstants.FJORD.FASTLZ_DIVISOR;
    
    // Channel estimation: 0.21 * original_size  
    const channel_size = (original_size * L1GasConstants.FJORD.CHANNEL_RATIO) / 
                         L1GasConstants.FJORD.CHANNEL_DIVISOR;
    
    // Use the maximum of the two estimations
    return @max(fastlz_size, channel_size);
}

/// Calculate operator fee for Isthmus hardfork
pub fn calculateOperatorFee(
    tx_data: []const u8,
    l1_block_info: L1BlockInfo,
) u256 {
    const operator_fee_scalar = l1_block_info.operator_fee_scalar orelse return 0;
    const operator_fee_constant = l1_block_info.operator_fee_constant orelse return 0;
    
    const data_gas = calculateDataGas(tx_data);
    
    // operator_fee = (data_gas * scalar + constant) * base_fee / 1e12
    const scaled_gas = @as(u256, data_gas) * operator_fee_scalar;
    const with_constant = scaled_gas + operator_fee_constant;
    const with_base_fee = with_constant * l1_block_info.base_fee;
    
    return with_base_fee / 1_000_000_000_000;
}

test "calculatePreEcotoneL1Cost" {
    const tx_data = &[_]u8{1, 2, 3, 0, 0, 4, 5};
    const l1_info = L1BlockInfo{
        .number = 1000,
        .timestamp = 1234567890,
        .base_fee = 30_000_000_000, // 30 gwei
        .hash = std.mem.zeroes(primitives.B256),
        .sequence_number = 1,
        .batcher_hash = null,
        .l1_fee_overhead = 2100,
        .l1_fee_scalar = 1_000_000,
        .blob_base_fee = null,
        .base_fee_scalar = null,
        .blob_base_fee_scalar = null,
        .operator_fee_scalar = null,
        .operator_fee_constant = null,
    };
    
    const cost = calculatePreEcotoneL1Cost(tx_data, l1_info);
    
    // Verify cost is calculated correctly
    const data_gas = calculateDataGas(tx_data);
    const expected = ((data_gas + 2100) * 1_000_000 * 30_000_000_000) / 1_000_000;
    try std.testing.expectEqual(expected, cost);
}

test "estimateFjordCompressedSize" {
    // Test with mixed data
    const data = &[_]u8{0, 0, 0, 1, 2, 3, 0, 0, 4, 5};
    const compressed = estimateFjordCompressedSize(data);
    
    // FastLZ: 10 * 255 / 1000 = 2.55 -> 2
    // Channel: 10 * 21 / 100 = 2.1 -> 2
    try std.testing.expectEqual(@as(u256, 2), compressed);
}