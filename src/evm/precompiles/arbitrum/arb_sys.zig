const std = @import("std");
const PrecompileOutput = @import("../precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("../precompile_result.zig").PrecompileError;

/// ArbSys precompile (0x64) - Provides system-level functionality
/// 
/// Key functions:
/// - arbBlockNumber() - returns Arbitrum block number
/// - arbBlockHash(uint256) - returns Arbitrum block hash
/// - withdrawEth(address) - initiates ETH withdrawal to L1
/// - isTopLevelCall() - checks if current call is top-level
/// - getStorageGasAvailable() - returns available storage gas
pub fn execute(input: []const u8, output: []u8, gas_limit: u64) PrecompileOutput {
    const base_gas = 100;
    const per_word_gas = 3;
    const gas_cost = base_gas + (input.len / 32) * per_word_gas;
    
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
            // For now, return a mock block number
            // In real implementation, this would query the Arbitrum state
            @memset(output[0..32], 0);
            output[31] = 42; // Mock block number
            break :blk 32;
        },
        // arbBlockHash(uint256 blockNumber)
        0x1f90ce5b => blk: {
            if (input.len < 36) {
                return PrecompileOutput.failure_result(PrecompileError.InvalidInput);
            }
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            // For now, return a mock hash
            @memset(output[0..32], 0xFF); // Mock hash
            break :blk 32;
        },
        // isTopLevelCall()
        0x08bd624c => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            @memset(output[0..32], 0);
            output[31] = 1; // Return true for now
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

test "ArbSys invalid selector" {
    // Invalid selector
    const input = &[_]u8{ 0x00, 0x00, 0x00, 0x00 };
    var output: [32]u8 = undefined;
    
    const result = execute(input, &output, 1000);
    
    try std.testing.expect(result.is_failure());
}