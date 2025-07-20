const std = @import("std");
const PrecompileOutput = @import("../precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("../precompile_result.zig").PrecompileError;

/// ArbSys precompile (0x64)
/// Provides Arbitrum system information
///
/// Key functions:
/// - arbBlockNumber() - Current Arbitrum block number
/// - arbChainID() - Arbitrum chain ID
/// - arbOSVersion() - ArbOS version
/// - isTopLevelCall() - Whether current call is top level
/// - mapL1SenderContractAddressToL2Alias() - L1 to L2 address aliasing
pub fn execute(input: []const u8, output: []u8, gas_limit: u64) PrecompileOutput {
    const gas_cost = 100; // Fixed gas cost for ArbSys queries
    
    if (gas_cost > gas_limit) {
        return PrecompileOutput.failure_result(PrecompileError.OutOfGas);
    }
    
    if (input.len < 4) {
        return PrecompileOutput.failure_result(PrecompileError.InvalidInput);
    }
    
    // Get function selector (first 4 bytes)
    const selector = std.mem.readInt(u32, input[0..4], .big);
    
    const result: usize = switch (selector) {
        // arbBlockNumber()
        0xa3b1b31d => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            // Return mock Arbitrum block number
            @memset(output[0..32], 0);
            output[31] = 42; // Mock block number
            break :blk 32;
        },
        // arbChainID()
        0x6c94c87b => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            // Return Arbitrum One chain ID
            @memset(output[0..32], 0);
            output[29] = 0xa4;
            output[30] = 0xb1; // 42161 (Arbitrum One)
            break :blk 32;
        },
        // arbOSVersion()
        0x051038f2 => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            // Return mock ArbOS version
            @memset(output[0..32], 0);
            output[31] = 11; // Version 11
            break :blk 32;
        },
        // isTopLevelCall()
        0x08bd624c => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            // Return true (1) for top level call
            @memset(output[0..32], 0);
            output[31] = 1;
            break :blk 32;
        },
        else => return PrecompileOutput.failure_result(PrecompileError.InvalidInput),
    };
    
    return PrecompileOutput.success_result(gas_cost, result);
}

test "ArbSys arbBlockNumber" {
    // arbBlockNumber() selector
    const input = &[_]u8{ 0xa3, 0xb1, 0xb3, 0x1d };
    var output: [32]u8 = undefined;
    
    const result = execute(input, &output, 1000);
    
    try std.testing.expect(result.is_success());
    try std.testing.expectEqual(@as(u64, 100), result.get_gas_used());
    try std.testing.expectEqual(@as(usize, 32), result.get_output_size());
    try std.testing.expectEqual(@as(u8, 42), output[31]);
}

test "ArbSys arbChainID" {
    // arbChainID() selector
    const input = &[_]u8{ 0x6c, 0x94, 0xc8, 0x7b };
    var output: [32]u8 = undefined;
    
    const result = execute(input, &output, 1000);
    
    try std.testing.expect(result.is_success());
    try std.testing.expectEqual(@as(u64, 100), result.get_gas_used());
    try std.testing.expectEqual(@as(usize, 32), result.get_output_size());
    try std.testing.expectEqual(@as(u8, 0xa4), output[29]);
    try std.testing.expectEqual(@as(u8, 0xb1), output[30]);
}

test "ArbSys insufficient gas" {
    const input = &[_]u8{ 0xa3, 0xb1, 0xb3, 0x1d };
    var output: [32]u8 = undefined;
    
    const result = execute(input, &output, 50); // Not enough gas
    
    try std.testing.expect(result.is_failure());
    try std.testing.expectEqual(PrecompileError.OutOfGas, result.get_error());
}