const std = @import("std");
const Evm = @import("evm");
const primitives = @import("primitives");
const B256 = @import("crypto").Hash.B256;

const L1BlockInfo = Evm.optimism.L1BlockInfo;
const OptimismRules = Evm.optimism.OptimismRules;
const calculateL1Cost = Evm.optimism.calculateL1Cost;
const calculateDataGas = Evm.optimism.calculateDataGas;
const calculateOperatorFee = Evm.optimism.calculateOperatorFee;

test "L1 cost calculation - pre-Ecotone" {
    const tx_data = &[_]u8{ 0x00, 0x01, 0x02, 0x03, 0x00, 0x00, 0x04, 0x05 };
    
    const l1_info = L1BlockInfo{
        .number = 1000,
        .timestamp = 1234567890,
        .base_fee = 30_000_000_000, // 30 gwei
        .hash = std.mem.zeroes(B256),
        .sequence_number = 1,
        .batcher_hash = null,
        .l1_fee_overhead = 2100,
        .l1_fee_scalar = 1_000_000, // 1.0 in 6 decimals
        .blob_base_fee = null,
        .base_fee_scalar = null,
        .blob_base_fee_scalar = null,
        .operator_fee_scalar = null,
        .operator_fee_constant = null,
    };
    
    const op_rules = OptimismRules{ .hardfork = .BEDROCK };
    const cost = calculateL1Cost(tx_data, l1_info, op_rules);
    
    // Manual calculation:
    // data_gas = 3 * 4 + 5 * 16 = 12 + 80 = 92
    // total_gas = 92 + 2100 = 2192
    // cost = 2192 * 1_000_000 * 30_000_000_000 / 1_000_000
    const expected: u256 = 2192 * 30_000_000_000;
    try std.testing.expectEqual(expected, cost);
}

test "L1 cost calculation - Ecotone" {
    const tx_data = &[_]u8{ 0x00, 0x01, 0x02, 0x03, 0x00, 0x00, 0x04, 0x05 };
    
    const l1_info = L1BlockInfo{
        .number = 2000,
        .timestamp = 1234567890,
        .base_fee = 30_000_000_000, // 30 gwei
        .hash = std.mem.zeroes(B256),
        .sequence_number = 1,
        .batcher_hash = std.mem.zeroes(B256),
        .l1_fee_overhead = null,
        .l1_fee_scalar = null,
        .blob_base_fee = 1_000_000_000, // 1 gwei
        .base_fee_scalar = 1000,
        .blob_base_fee_scalar = 1000,
        .operator_fee_scalar = null,
        .operator_fee_constant = null,
    };
    
    const op_rules = OptimismRules{ .hardfork = .ECOTONE };
    const cost = calculateL1Cost(tx_data, l1_info, op_rules);
    
    // Verify cost is calculated (exact value depends on compression estimation)
    try std.testing.expect(cost > 0);
}

test "L1 cost calculation - Fjord" {
    const tx_data = &[_]u8{ 0x00, 0x01, 0x02, 0x03, 0x00, 0x00, 0x04, 0x05 };
    
    const l1_info = L1BlockInfo{
        .number = 3000,
        .timestamp = 1234567890,
        .base_fee = 30_000_000_000, // 30 gwei
        .hash = std.mem.zeroes(B256),
        .sequence_number = 1,
        .batcher_hash = std.mem.zeroes(B256),
        .l1_fee_overhead = null,
        .l1_fee_scalar = null,
        .blob_base_fee = 1_000_000_000, // 1 gwei
        .base_fee_scalar = 1000,
        .blob_base_fee_scalar = 1000,
        .operator_fee_scalar = null,
        .operator_fee_constant = null,
    };
    
    const op_rules = OptimismRules{ .hardfork = .FJORD };
    const cost = calculateL1Cost(tx_data, l1_info, op_rules);
    
    // Fjord should use different compression estimation
    try std.testing.expect(cost > 0);
}

test "Operator fee calculation - Isthmus" {
    const tx_data = &[_]u8{ 0x00, 0x01, 0x02, 0x03, 0x00, 0x00, 0x04, 0x05 };
    
    const l1_info = L1BlockInfo{
        .number = 4000,
        .timestamp = 1234567890,
        .base_fee = 30_000_000_000, // 30 gwei
        .hash = std.mem.zeroes(B256),
        .sequence_number = 1,
        .batcher_hash = std.mem.zeroes(B256),
        .l1_fee_overhead = null,
        .l1_fee_scalar = null,
        .blob_base_fee = 1_000_000_000,
        .base_fee_scalar = 1000,
        .blob_base_fee_scalar = 1000,
        .operator_fee_scalar = 1000,
        .operator_fee_constant = 10000,
    };
    
    const fee = calculateOperatorFee(tx_data, l1_info);
    
    // Manual calculation:
    // data_gas = 92
    // fee = (92 * 1000 + 10000) * 30_000_000_000 / 1e12
    const expected: u256 = (92 * 1000 + 10000) * 30_000_000_000 / 1_000_000_000_000;
    try std.testing.expectEqual(expected, fee);
}

test "Data gas calculation" {
    // Test empty data
    try std.testing.expectEqual(@as(u64, 0), calculateDataGas(&.{}));
    
    // Test all zeros
    const zeros = &[_]u8{0} ** 10;
    try std.testing.expectEqual(@as(u64, 40), calculateDataGas(zeros));
    
    // Test all non-zeros
    const non_zeros = &[_]u8{1} ** 10;
    try std.testing.expectEqual(@as(u64, 160), calculateDataGas(non_zeros));
    
    // Test mixed
    const mixed = &[_]u8{ 0, 1, 2, 0, 0, 3, 4, 0 };
    try std.testing.expectEqual(@as(u64, 4 * 4 + 4 * 16), calculateDataGas(mixed));
}

test "L1 cost with zero data" {
    const tx_data = &[_]u8{};
    
    const l1_info = L1BlockInfo{
        .number = 1000,
        .timestamp = 1234567890,
        .base_fee = 30_000_000_000,
        .hash = std.mem.zeroes(B256),
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
    
    const op_rules = OptimismRules{ .hardfork = .BEDROCK };
    const cost = calculateL1Cost(tx_data, l1_info, op_rules);
    
    // Only overhead should be charged
    const expected: u256 = 2100 * 1_000_000 * 30_000_000_000 / 1_000_000;
    try std.testing.expectEqual(expected, cost);
}

test "L1BlockInfo fee scalar decoding" {
    // Test Ecotone fee scalar encoding
    // base_fee_scalar = 1500, blob_base_fee_scalar = 2500
    const packed_value: u256 = 1500 | (@as(u256, 2500) << 32);
    
    const scalars = L1BlockInfo.decodeEcotoneFeeScalars(packed_value);
    try std.testing.expectEqual(@as(u32, 1500), scalars.base_fee_scalar);
    try std.testing.expectEqual(@as(u32, 2500), scalars.blob_base_fee_scalar);
}

test "Operator fee parameter decoding" {
    // Test Isthmus operator fee encoding
    // scalar = 5000, constant = 20000
    const packed_value: u256 = 5000 | (@as(u256, 20000) << 64);
    
    const params = L1BlockInfo.decodeOperatorFeeParams(packed_value);
    try std.testing.expectEqual(@as(u64, 5000), params.scalar);
    try std.testing.expectEqual(@as(u64, 20000), params.constant);
}