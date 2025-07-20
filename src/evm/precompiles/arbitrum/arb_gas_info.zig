const std = @import("std");
const PrecompileOutput = @import("../precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("../precompile_result.zig").PrecompileError;

/// ArbGasInfo precompile (0x6c)
/// Provides Arbitrum gas pricing information
///
/// Key functions:
/// - getPricesInWei() - Get L1 and L2 gas prices in wei
/// - getPricesInArbGas() - Get gas prices in ArbGas units
/// - getGasAccountingParams() - Get gas accounting parameters
/// - getCurrentTxL1GasFees() - Get L1 gas fees for current transaction
pub fn execute(input: []const u8, output: []u8, gas_limit: u64) PrecompileOutput {
    const gas_cost = 150; // Fixed gas cost for gas info queries
    
    if (gas_cost > gas_limit) {
        return PrecompileOutput.failure_result(PrecompileError.OutOfGas);
    }
    
    if (input.len < 4) {
        return PrecompileOutput.failure_result(PrecompileError.InvalidInput);
    }
    
    // Get function selector (first 4 bytes)
    const selector = std.mem.readInt(u32, input[0..4], .big);
    
    const result: usize = switch (selector) {
        // getPricesInWei() returns (uint256,uint256,uint256,uint256,uint256,uint256)
        // perL2Tx, perL1CalldataUnit, perStorageAllocation, perArbGasBase, perArbGasCongestion, perArbGasTotal
        0x41b247a8 => blk: {
            if (output.len < 192) { // 6 * 32 bytes
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            // Return mock gas prices
            @memset(output[0..192], 0);
            // perL2Tx: 100000 wei
            output[29] = 0x01;
            output[30] = 0x86;
            output[31] = 0xa0;
            // perL1CalldataUnit: 16 wei per byte
            output[63] = 16;
            // perStorageAllocation: 1000 wei
            output[92] = 0x03;
            output[95] = 0xe8;
            // perArbGasBase: 100 wei
            output[127] = 100;
            // perArbGasCongestion: 0 wei (no congestion)
            // perArbGasTotal: 100 wei (base only)
            output[191] = 100;
            break :blk 192;
        },
        // getCurrentTxL1GasFees() returns uint256
        0xc1880f1d => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            // Return mock L1 gas fees for current tx
            @memset(output[0..32], 0);
            output[30] = 0x27;
            output[31] = 0x10; // 10000 wei
            break :blk 32;
        },
        // getGasAccountingParams() returns (uint256,uint256,uint256)
        // speedLimitPerSecond, gasPoolMax, maxTxGasLimit
        0x612af178 => blk: {
            if (output.len < 96) { // 3 * 32 bytes
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            // Return mock gas accounting params
            @memset(output[0..96], 0);
            // speedLimitPerSecond: 1000000
            output[26] = 0x0f;
            output[27] = 0x42;
            output[28] = 0x40;
            // gasPoolMax: 10000000
            output[57] = 0x98;
            output[58] = 0x96;
            output[59] = 0x80;
            // maxTxGasLimit: 32000000
            output[88] = 0x01;
            output[89] = 0xe8;
            output[90] = 0x48;
            output[91] = 0x00;
            break :blk 96;
        },
        else => return PrecompileOutput.failure_result(PrecompileError.InvalidInput),
    };
    
    return PrecompileOutput.success_result(gas_cost, result);
}

test "ArbGasInfo getPricesInWei" {
    // getPricesInWei() selector
    const input = &[_]u8{ 0x41, 0xb2, 0x47, 0xa8 };
    var output: [192]u8 = undefined;
    
    const result = execute(input, &output, 1000);
    
    try std.testing.expect(result.is_success());
    try std.testing.expectEqual(@as(u64, 150), result.get_gas_used());
    try std.testing.expectEqual(@as(usize, 192), result.get_output_size());
    
    // Check perL2Tx value
    try std.testing.expectEqual(@as(u8, 0x01), output[29]);
    try std.testing.expectEqual(@as(u8, 0x86), output[30]);
    try std.testing.expectEqual(@as(u8, 0xa0), output[31]);
    
    // Check perL1CalldataUnit
    try std.testing.expectEqual(@as(u8, 16), output[63]);
}

test "ArbGasInfo getCurrentTxL1GasFees" {
    // getCurrentTxL1GasFees() selector
    const input = &[_]u8{ 0xc1, 0x88, 0x0f, 0x1d };
    var output: [32]u8 = undefined;
    
    const result = execute(input, &output, 1000);
    
    try std.testing.expect(result.is_success());
    try std.testing.expectEqual(@as(u64, 150), result.get_gas_used());
    try std.testing.expectEqual(@as(usize, 32), result.get_output_size());
    try std.testing.expectEqual(@as(u8, 0x27), output[30]);
    try std.testing.expectEqual(@as(u8, 0x10), output[31]);
}

test "ArbGasInfo getGasAccountingParams" {
    // getGasAccountingParams() selector
    const input = &[_]u8{ 0x61, 0x2a, 0xf1, 0x78 };
    var output: [96]u8 = undefined;
    
    const result = execute(input, &output, 1000);
    
    try std.testing.expect(result.is_success());
    try std.testing.expectEqual(@as(u64, 150), result.get_gas_used());
    try std.testing.expectEqual(@as(usize, 96), result.get_output_size());
}

test "ArbGasInfo insufficient gas" {
    const input = &[_]u8{ 0x41, 0xb2, 0x47, 0xa8 };
    var output: [192]u8 = undefined;
    
    const result = execute(input, &output, 100); // Not enough gas
    
    try std.testing.expect(result.is_failure());
    try std.testing.expectEqual(PrecompileError.OutOfGas, result.get_error());
}
