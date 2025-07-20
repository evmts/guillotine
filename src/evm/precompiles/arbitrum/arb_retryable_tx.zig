const std = @import("std");
const PrecompileOutput = @import("../precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("../precompile_result.zig").PrecompileError;

/// ArbRetryableTx precompile (0x6e)
/// Manages retryable tickets for L1-to-L2 transactions
///
/// Key functions:
/// - getLifetime() - Get default lifetime for retryable tickets
/// - getTimeout(bytes32 ticketId) - Get timeout for specific ticket
/// - getSubmissionPrice(uint256 dataLength) - Calculate submission price
pub fn execute(input: []const u8, output: []u8, gas_limit: u64) PrecompileOutput {
    const gas_cost = 150; // Fixed gas cost for retryable tx queries
    
    if (gas_cost > gas_limit) {
        return PrecompileOutput.failure_result(PrecompileError.OutOfGas);
    }
    
    if (input.len < 4) {
        return PrecompileOutput.failure_result(PrecompileError.InvalidInput);
    }
    
    // Get function selector (first 4 bytes)
    const selector = std.mem.readInt(u32, input[0..4], .big);
    
    const result: usize = switch (selector) {
        // getLifetime()
        0x79552c0a => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            // Return default lifetime (1 week in seconds)
            @memset(output[0..32], 0);
            output[28] = 0x00;
            output[29] = 0x09;
            output[30] = 0x3a;
            output[31] = 0x80; // 604800 seconds
            break :blk 32;
        },
        // getTimeout(bytes32 ticketId)
        0x12b05d33 => blk: {
            if (input.len < 36) { // 4 bytes selector + 32 bytes ticketId
                return PrecompileOutput.failure_result(PrecompileError.InvalidInput);
            }
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            // Return mock timeout timestamp
            @memset(output[0..32], 0);
            output[28] = 0x65;
            output[29] = 0x6e;
            output[30] = 0xf0;
            output[31] = 0x00; // Mock timestamp
            break :blk 32;
        },
        // getSubmissionPrice(uint256 dataLength)
        0xc8f542b1 => blk: {
            if (input.len < 36) { // 4 bytes selector + 32 bytes dataLength
                return PrecompileOutput.failure_result(PrecompileError.InvalidInput);
            }
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            // Calculate mock submission price (base + per-byte cost)
            // For simplicity, return fixed price
            @memset(output[0..32], 0);
            output[28] = 0x00;
            output[29] = 0x0f;
            output[30] = 0x42;
            output[31] = 0x40; // 1000000 wei base price
            break :blk 32;
        },
        else => return PrecompileOutput.failure_result(PrecompileError.InvalidInput),
    };
    
    return PrecompileOutput.success_result(gas_cost, result);
}

test "ArbRetryableTx getLifetime" {
    // getLifetime() selector
    const input = &[_]u8{ 0x79, 0x55, 0x2c, 0x0a };
    var output: [32]u8 = undefined;
    
    const result = execute(input, &output, 1000);
    
    try std.testing.expect(result.is_success());
    try std.testing.expectEqual(@as(u64, 150), result.get_gas_used());
    try std.testing.expectEqual(@as(usize, 32), result.get_output_size());
    // Check lifetime value (604800 seconds)
    try std.testing.expectEqual(@as(u8, 0x09), output[29]);
    try std.testing.expectEqual(@as(u8, 0x3a), output[30]);
    try std.testing.expectEqual(@as(u8, 0x80), output[31]);
}

test "ArbRetryableTx getTimeout" {
    // getTimeout(bytes32) selector + mock ticket ID
    var input: [36]u8 = undefined;
    input[0..4].* = .{ 0x12, 0xb0, 0x5d, 0x33 };
    @memset(input[4..], 0); // Zero ticket ID
    
    var output: [32]u8 = undefined;
    
    const result = execute(&input, &output, 1000);
    
    try std.testing.expect(result.is_success());
    try std.testing.expectEqual(@as(u64, 150), result.get_gas_used());
    try std.testing.expectEqual(@as(usize, 32), result.get_output_size());
}

test "ArbRetryableTx getSubmissionPrice" {
    // getSubmissionPrice(uint256) selector + data length
    var input: [36]u8 = undefined;
    input[0..4].* = .{ 0xc8, 0xf5, 0x42, 0xb1 };
    @memset(input[4..], 0);
    input[35] = 100; // 100 bytes of data
    
    var output: [32]u8 = undefined;
    
    const result = execute(&input, &output, 1000);
    
    try std.testing.expect(result.is_success());
    try std.testing.expectEqual(@as(u64, 150), result.get_gas_used());
    try std.testing.expectEqual(@as(usize, 32), result.get_output_size());
    // Check base price
    try std.testing.expectEqual(@as(u8, 0x0f), output[29]);
    try std.testing.expectEqual(@as(u8, 0x42), output[30]);
    try std.testing.expectEqual(@as(u8, 0x40), output[31]);
}

test "ArbRetryableTx insufficient input" {
    // getTimeout with insufficient input
    const input = &[_]u8{ 0x12, 0xb0, 0x5d, 0x33 }; // Missing ticket ID
    var output: [32]u8 = undefined;
    
    const result = execute(input, &output, 1000);
    
    try std.testing.expect(result.is_failure());
    try std.testing.expectEqual(PrecompileError.InvalidInput, result.get_error());
}