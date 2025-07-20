const std = @import("std");
const PrecompileOutput = @import("../precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("../precompile_result.zig").PrecompileError;

/// ArbInfo precompile (0x65) - Provides Arbitrum chain information
///
/// Key functions:
/// - getBalance(address) - gets account balance  
/// - getCode(address) - gets contract code
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
    
    const result = switch (selector) {
        // getBalance(address)
        0xf8b2cb4f => blk: {
            if (input.len < 36) {
                return PrecompileOutput.failure_result(PrecompileError.InvalidInput);
            }
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            // For now, return a mock balance
            @memset(output[0..32], 0);
            output[31] = 100; // Mock balance
            break :blk 32;
        },
        else => return PrecompileOutput.failure_result(PrecompileError.InvalidInput),
    };
    
    return PrecompileOutput.success_result(gas_cost, result);
}

test "ArbInfo getBalance" {
    // getBalance(address) selector + mock address
    var input: [36]u8 = undefined;
    @memcpy(input[0..4], &[_]u8{ 0xf8, 0xb2, 0xcb, 0x4f });
    @memset(input[4..], 0);
    var output: [32]u8 = undefined;
    
    const result = execute(&input, &output, 1000);
    
    try std.testing.expect(result.is_success());
    try std.testing.expectEqual(@as(u64, 101), result.get_gas_used()); // 100 + 1 word
    try std.testing.expectEqual(@as(usize, 32), result.get_output_size());
    try std.testing.expectEqual(@as(u8, 100), output[31]);
}