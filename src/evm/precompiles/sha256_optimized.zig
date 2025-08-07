const std = @import("std");
const PrecompileOutput = @import("precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("precompile_result.zig").PrecompileError;
const GasConstants = @import("primitives").GasConstants;
const primitives = @import("primitives");
const crypto = @import("crypto");
const ChainRules = @import("../frame.zig").ChainRules;

/// SHA256 precompile implementation (Optimized Version)
///
/// This module implements the SHA256 cryptographic hash function precompile at address 0x02.
/// 
/// Optimizations implemented:
/// 1. Direct hash to output buffer (Issue #332) - eliminates intermediate buffers
/// 2. Uniform interface (Issue #333) - compatible with optimized dispatch
/// 3. Inline gas calculation - reduces function calls
/// 4. Hardware acceleration - uses crypto.SHA256_Accel when available

/// Base gas cost for SHA256 precompile
const SHA256_BASE_COST: u64 = 60;

/// Gas cost per 32-byte word for SHA256 precompile
const SHA256_WORD_COST: u64 = 12;

/// SHA256 always outputs exactly 32 bytes
const SHA256_OUTPUT_SIZE: usize = 32;

/// Calculate gas cost for SHA256 precompile
pub fn calculate_gas(input_size: usize) u64 {
    const word_count = GasConstants.wordCount(input_size);
    return SHA256_BASE_COST + SHA256_WORD_COST * word_count;
}

/// Calculate gas cost with overflow checking
pub fn calculate_gas_checked(input_size: usize) !u64 {
    // Check for potential overflow in word count calculation (bytes + 31)
    const input_plus_31 = std.math.add(usize, input_size, 31) catch {
        return error.Overflow;
    };
    const word_count = input_plus_31 / 32;

    // Convert word_count to u64 with overflow checking
    const word_count_u64 = std.math.cast(u64, word_count) orelse {
        return error.Overflow;
    };

    // Check for potential overflow in gas calculation
    const gas_from_words = std.math.mul(u64, SHA256_WORD_COST, word_count_u64) catch {
        return error.Overflow;
    };

    // Use std.math.add for total gas calculation with overflow checking
    const total_gas = std.math.add(u64, SHA256_BASE_COST, gas_from_words) catch {
        return error.Overflow;
    };

    return total_gas;
}

/// Execute SHA256 precompile (Optimized Version)
/// 
/// Key optimizations:
/// 1. Direct hash to output buffer - no intermediate buffers (Issue #332)
/// 2. Uniform interface - accepts chain_rules parameter (Issue #333)
/// 3. Inline validation - reduces branching
/// 4. Hardware acceleration - uses optimized crypto implementation
pub fn execute(input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
    _ = chain_rules; // Not used by SHA256, but required for uniform interface
    
    // Validate output buffer size inline
    if (output.len < SHA256_OUTPUT_SIZE) {
        @branchHint(.cold);
        return PrecompileOutput.failure_result(PrecompileError.BufferTooSmall);
    }
    
    // Calculate gas cost inline
    const word_count = (input.len + 31) / 32;
    const gas_cost = SHA256_BASE_COST + SHA256_WORD_COST * @as(u64, @intCast(word_count));
    
    // Check gas limit
    if (gas_cost > gas_limit) {
        @branchHint(.unlikely);
        return PrecompileOutput.failure_result(PrecompileError.OutOfGas);
    }
    
    // Direct hash to output buffer - no intermediate copy (Issue #332)
    const output_array: *[SHA256_OUTPUT_SIZE]u8 = output[0..SHA256_OUTPUT_SIZE];
    crypto.SHA256_Accel.SHA256_Accel.hash(input, output_array);
    
    return PrecompileOutput.success_result(gas_cost, SHA256_OUTPUT_SIZE);
}

/// Get the output size for SHA256 precompile
pub fn get_output_size(input_size: usize) usize {
    _ = input_size; // SHA256 output size is always 32 bytes
    return SHA256_OUTPUT_SIZE;
}

// Tests
const testing = std.testing;

test "SHA256 optimized precompile" {
    const test_vectors = [_]struct {
        input: []const u8,
        expected: [32]u8,
    }{
        .{
            .input = "",
            .expected = [_]u8{
                0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
                0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
                0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
                0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
            },
        },
        .{
            .input = "abc",
            .expected = [_]u8{
                0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
                0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
                0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
                0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
            },
        },
    };
    
    const chain_rules = ChainRules.for_hardfork(.ISTANBUL);
    
    for (test_vectors) |tv| {
        var output: [32]u8 = undefined;
        
        const result = execute(tv.input, &output, 100000, chain_rules);
        try testing.expect(result.is_success());
        try testing.expectEqualSlices(u8, &tv.expected, &output);
    }
}

test "SHA256 optimized gas calculation" {
    // Test basic gas calculation
    try testing.expectEqual(@as(u64, 60), calculate_gas(0)); // Empty input
    try testing.expectEqual(@as(u64, 72), calculate_gas(32)); // 1 word
    try testing.expectEqual(@as(u64, 84), calculate_gas(64)); // 2 words
    try testing.expectEqual(@as(u64, 96), calculate_gas(96)); // 3 words
    
    // Test partial word boundaries
    try testing.expectEqual(@as(u64, 72), calculate_gas(1)); // 1 byte = 1 word
    try testing.expectEqual(@as(u64, 72), calculate_gas(31)); // 31 bytes = 1 word
    try testing.expectEqual(@as(u64, 84), calculate_gas(33)); // 33 bytes = 2 words
}

test "SHA256 optimized edge cases" {
    const chain_rules = ChainRules.for_hardfork(.ISTANBUL);
    var output: [32]u8 = undefined;
    
    // Test insufficient gas
    const result_low_gas = execute("test", &output, 10, chain_rules);
    try testing.expect(result_low_gas.is_failure());
    try testing.expectEqual(PrecompileError.OutOfGas, result_low_gas.get_error().?);
    
    // Test output buffer too small
    var small_output: [10]u8 = undefined;
    const result_small_buf = execute("test", &small_output, 100000, chain_rules);
    try testing.expect(result_small_buf.is_failure());
    try testing.expectEqual(PrecompileError.BufferTooSmall, result_small_buf.get_error().?);
    
    // Test exactly enough gas
    const gas_needed = calculate_gas(4); // "test" is 4 bytes
    const result_exact_gas = execute("test", &output, gas_needed, chain_rules);
    try testing.expect(result_exact_gas.is_success());
    try testing.expectEqual(gas_needed, result_exact_gas.get_gas_used());
}