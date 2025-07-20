const std = @import("std");
const PrecompileOutput = @import("../precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("../precompile_result.zig").PrecompileError;

/// ArbAggregator precompile (0x6d)
/// Provides batch and data availability information
///
/// Key functions:
/// - getBatchNumber() - Get current batch number
/// - getL1PricingData() - Get L1 pricing data for calldata
/// - getTxBaseFee() - Get transaction base fee
pub fn execute(input: []const u8, output: []u8, gas_limit: u64) PrecompileOutput {
    const gas_cost = 100; // Fixed gas cost for aggregator queries
    
    if (gas_cost > gas_limit) {
        return PrecompileOutput.failure_result(PrecompileError.OutOfGas);
    }
    
    if (input.len < 4) {
        return PrecompileOutput.failure_result(PrecompileError.InvalidInput);
    }
    
    // Get function selector (first 4 bytes)
    const selector = std.mem.readInt(u32, input[0..4], .big);
    
    const result: usize = switch (selector) {
        // getBatchNumber()
        0x7a7c2ecc => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            // Return mock batch number
            @memset(output[0..32], 0);
            output[31] = 123; // Mock batch number
            break :blk 32;
        },
        // getTxBaseFee()
        0x4bdb8e5e => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            // Return mock base fee
            @memset(output[0..32], 0);
            output[30] = 0x3b;
            output[31] = 0x9a; // 15258 wei
            break :blk 32;
        },
        // getL1PricingData() returns (uint256,uint256,uint256)
        // posterDataCost, posterDataSize, posterDataChecksum
        0x0c2d9c44 => blk: {
            if (output.len < 96) { // 3 * 32 bytes
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            // Return mock L1 pricing data
            @memset(output[0..96], 0);
            // posterDataCost: 50000 wei
            output[27] = 0xc3;
            output[28] = 0x50;
            // posterDataSize: 1024 bytes
            output[60] = 0x04;
            output[61] = 0x00;
            // posterDataChecksum: mock checksum
            output[95] = 0xab;
            break :blk 96;
        },
        else => return PrecompileOutput.failure_result(PrecompileError.InvalidInput),
    };
    
    return PrecompileOutput.success_result(gas_cost, result);
}

test "ArbAggregator getBatchNumber" {
    // getBatchNumber() selector
    const input = &[_]u8{ 0x7a, 0x7c, 0x2e, 0xcc };
    var output: [32]u8 = undefined;
    
    const result = execute(input, &output, 1000);
    
    try std.testing.expect(result.is_success());
    try std.testing.expectEqual(@as(u64, 100), result.get_gas_used());
    try std.testing.expectEqual(@as(usize, 32), result.get_output_size());
    try std.testing.expectEqual(@as(u8, 123), output[31]);
}

test "ArbAggregator getTxBaseFee" {
    // getTxBaseFee() selector
    const input = &[_]u8{ 0x4b, 0xdb, 0x8e, 0x5e };
    var output: [32]u8 = undefined;
    
    const result = execute(input, &output, 1000);
    
    try std.testing.expect(result.is_success());
    try std.testing.expectEqual(@as(u64, 100), result.get_gas_used());
    try std.testing.expectEqual(@as(usize, 32), result.get_output_size());
    try std.testing.expectEqual(@as(u8, 0x3b), output[30]);
    try std.testing.expectEqual(@as(u8, 0x9a), output[31]);
}

test "ArbAggregator getL1PricingData" {
    // getL1PricingData() selector
    const input = &[_]u8{ 0x0c, 0x2d, 0x9c, 0x44 };
    var output: [96]u8 = undefined;
    
    const result = execute(input, &output, 1000);
    
    try std.testing.expect(result.is_success());
    try std.testing.expectEqual(@as(u64, 100), result.get_gas_used());
    try std.testing.expectEqual(@as(usize, 96), result.get_output_size());
    // Check posterDataCost
    try std.testing.expectEqual(@as(u8, 0xc3), output[27]);
    try std.testing.expectEqual(@as(u8, 0x50), output[28]);
}

test "ArbAggregator invalid selector" {
    const input = &[_]u8{ 0xff, 0xff, 0xff, 0xff };
    var output: [32]u8 = undefined;
    
    const result = execute(input, &output, 1000);
    
    try std.testing.expect(result.is_failure());
    try std.testing.expectEqual(PrecompileError.InvalidInput, result.get_error());
}