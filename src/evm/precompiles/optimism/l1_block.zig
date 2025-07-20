const std = @import("std");
const PrecompileOutput = @import("../precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("../precompile_result.zig").PrecompileError;

/// L1Block precompile (0x4200000000000000000000000000000000000015)
/// Provides information about the L1 chain
///
/// Key functions:
/// - number() - L1 block number
/// - timestamp() - L1 block timestamp  
/// - basefee() - L1 base fee
/// - hash() - L1 block hash
/// - sequenceNumber() - L2 block number within epoch
pub fn execute(input: []const u8, output: []u8, gas_limit: u64) PrecompileOutput {
    const gas_cost = 100; // Fixed gas cost for L1Block queries
    
    if (gas_cost > gas_limit) {
        return PrecompileOutput.failure_result(PrecompileError.OutOfGas);
    }
    
    if (input.len < 4) {
        return PrecompileOutput.failure_result(PrecompileError.InvalidInput);
    }
    
    // Get function selector (first 4 bytes)
    const selector = std.mem.readInt(u32, input[0..4], .big);
    
    const result: usize = switch (selector) {
        // number()
        0x8381f58a => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            // Return mock L1 block number
            @memset(output[0..32], 0);
            output[30] = 0x01;
            output[31] = 0x00; // 256
            break :blk 32;
        },
        // timestamp()
        0xb80777ea => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            // Return mock timestamp
            @memset(output[0..32], 0);
            // Mock timestamp (approx 2024)
            output[28] = 0x65;
            output[29] = 0x00;
            output[30] = 0x00;
            output[31] = 0x00;
            break :blk 32;
        },
        // basefee()
        0x5cf24969 => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            // Return mock base fee
            @memset(output[0..32], 0);
            output[31] = 30; // 30 gwei
            break :blk 32;
        },
        else => return PrecompileOutput.failure_result(PrecompileError.InvalidInput),
    };
    
    return PrecompileOutput.success_result(gas_cost, result);
}

test "L1Block number" {
    // number() selector
    const input = &[_]u8{ 0x83, 0x81, 0xf5, 0x8a };
    var output: [32]u8 = undefined;
    
    const result = execute(input, &output, 1000);
    
    try std.testing.expect(result.is_success());
    try std.testing.expectEqual(@as(u64, 100), result.get_gas_used());
    try std.testing.expectEqual(@as(usize, 32), result.get_output_size());
    try std.testing.expectEqual(@as(u8, 0x01), output[30]);
    try std.testing.expectEqual(@as(u8, 0x00), output[31]);
}

test "L1Block timestamp" {
    // timestamp() selector
    const input = &[_]u8{ 0xb8, 0x07, 0x77, 0xea };
    var output: [32]u8 = undefined;
    
    const result = execute(input, &output, 1000);
    
    try std.testing.expect(result.is_success());
    try std.testing.expectEqual(@as(u64, 100), result.get_gas_used());
    try std.testing.expectEqual(@as(usize, 32), result.get_output_size());
    try std.testing.expectEqual(@as(u8, 0x65), output[28]);
}