const std = @import("std");
const crypto = @import("crypto");
const PrecompileOutput = @import("precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("precompile_result.zig").PrecompileError;
const GasConstants = @import("primitives").GasConstants;
const primitives = @import("primitives");
const ChainRules = @import("../hardforks/chain_rules.zig").ChainRules;

/// RIPEMD160 precompile implementation (Optimized Version)
///
/// This module implements the RIPEMD160 cryptographic hash function precompile at address 0x03.
///
/// Optimizations implemented:
/// 1. Direct hash to output buffer (Issue #332) - eliminates intermediate buffers
/// 2. Uniform interface (Issue #333) - compatible with optimized dispatch
/// 3. Inline gas calculation - reduces function calls
/// 4. Efficient output formatting - direct writes with proper padding
/// Base gas cost for RIPEMD160 precompile
const RIPEMD160_BASE_COST: u64 = 600;

/// Gas cost per 32-byte word for RIPEMD160 precompile
const RIPEMD160_WORD_COST: u64 = 120;

/// RIPEMD160 outputs 20 bytes, but EVM expects 32 bytes
const RIPEMD160_HASH_SIZE: usize = 20;
const RIPEMD160_OUTPUT_SIZE: usize = 32;

/// Calculate gas cost for RIPEMD160 precompile
pub fn calculate_gas(input_size: usize) u64 {
    const word_count = GasConstants.wordCount(input_size);
    return RIPEMD160_BASE_COST + RIPEMD160_WORD_COST * word_count;
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
    const gas_from_words = std.math.mul(u64, RIPEMD160_WORD_COST, word_count_u64) catch {
        return error.Overflow;
    };

    // Use std.math.add for total gas calculation with overflow checking
    const total_gas = std.math.add(u64, RIPEMD160_BASE_COST, gas_from_words) catch {
        return error.Overflow;
    };

    return total_gas;
}

/// Execute RIPEMD160 precompile (Optimized Version)
///
/// Key optimizations:
/// 1. Direct hash to output buffer - no intermediate buffers (Issue #332)
/// 2. Uniform interface - accepts chain_rules parameter (Issue #333)
/// 3. Inline validation and formatting - reduces function calls
/// 4. Efficient zero-padding - uses @memset for first 12 bytes
pub fn execute(input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
    _ = chain_rules; // Not used by RIPEMD160, but required for uniform interface

    // Validate output buffer size inline
    if (output.len < RIPEMD160_OUTPUT_SIZE) {
        @branchHint(.cold);
        return PrecompileOutput.failure_result(PrecompileError.BufferTooSmall);
    }

    // Calculate gas cost inline
    const word_count = (input.len + 31) / 32;
    const gas_cost = RIPEMD160_BASE_COST + RIPEMD160_WORD_COST * @as(u64, @intCast(word_count));

    // Check gas limit
    if (gas_cost > gas_limit) {
        @branchHint(.unlikely);
        return PrecompileOutput.failure_result(PrecompileError.OutOfGas);
    }

    // Zero-pad the first 12 bytes efficiently
    @memset(output[0..12], 0);

    // Direct hash to output buffer starting at byte 12 (Issue #332)
    // RIPEMD160 produces 20 bytes, which fits in bytes 12-31
    const hash_result = crypto.Ripemd160.unaudited_hash(input);
    @memcpy(output[12..32], &hash_result);

    return PrecompileOutput.success_result(gas_cost, RIPEMD160_OUTPUT_SIZE);
}

/// Get the output size for RIPEMD160 precompile
pub fn get_output_size(input_size: usize) usize {
    _ = input_size; // RIPEMD160 output size is always 32 bytes (with padding)
    return RIPEMD160_OUTPUT_SIZE;
}

// Tests
const testing = std.testing;

test "RIPEMD160 optimized precompile" {
    const test_vectors = [_]struct {
        input: []const u8,
        expected: [32]u8,
    }{
        .{
            .input = "",
            .expected = [_]u8{0} ** 12 ++ [_]u8{
                0x9c, 0x11, 0x85, 0xa5, 0xc5, 0xe9, 0xfc, 0x54,
                0x61, 0x28, 0x08, 0x97, 0x7e, 0xe8, 0xf5, 0x48,
                0xb2, 0x25, 0x8d, 0x31,
            },
        },
        .{
            .input = "abc",
            .expected = [_]u8{0} ** 12 ++ [_]u8{
                0x8e, 0xb2, 0x08, 0xf7, 0xe0, 0x5d, 0x98, 0x7a,
                0x9b, 0x04, 0x4a, 0x8e, 0x98, 0xc6, 0xb0, 0x87,
                0xf1, 0x5a, 0x0b, 0xfc,
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

test "RIPEMD160 optimized gas calculation" {
    // Test basic gas calculation
    try testing.expectEqual(@as(u64, 600), calculate_gas(0)); // Empty input
    try testing.expectEqual(@as(u64, 720), calculate_gas(32)); // 1 word
    try testing.expectEqual(@as(u64, 840), calculate_gas(64)); // 2 words
    try testing.expectEqual(@as(u64, 960), calculate_gas(96)); // 3 words

    // Test partial word boundaries
    try testing.expectEqual(@as(u64, 720), calculate_gas(1)); // 1 byte = 1 word
    try testing.expectEqual(@as(u64, 720), calculate_gas(31)); // 31 bytes = 1 word
    try testing.expectEqual(@as(u64, 840), calculate_gas(33)); // 33 bytes = 2 words
}

test "RIPEMD160 optimized edge cases" {
    const chain_rules = ChainRules.for_hardfork(.ISTANBUL);
    var output: [32]u8 = undefined;

    // Test insufficient gas
    const result_low_gas = execute("test", &output, 100, chain_rules);
    try testing.expect(result_low_gas.is_failure());
    try testing.expectEqual(PrecompileError.OutOfGas, result_low_gas.get_error().?);

    // Test output buffer too small
    var small_output: [20]u8 = undefined;
    const result_small_buf = execute("test", &small_output, 100000, chain_rules);
    try testing.expect(result_small_buf.is_failure());
    try testing.expectEqual(PrecompileError.BufferTooSmall, result_small_buf.get_error().?);

    // Test exactly enough gas
    const gas_needed = calculate_gas(4); // "test" is 4 bytes
    const result_exact_gas = execute("test", &output, gas_needed, chain_rules);
    try testing.expect(result_exact_gas.is_success());
    try testing.expectEqual(gas_needed, result_exact_gas.get_gas_used());
}

test "RIPEMD160 optimized output format" {
    const chain_rules = ChainRules.for_hardfork(.ISTANBUL);
    var output: [32]u8 = undefined;

    // Test that first 12 bytes are always zero
    const result = execute("test data", &output, 10000, chain_rules);
    try testing.expect(result.is_success());

    // Check padding
    for (output[0..12]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }

    // Check that bytes 12-31 contain the hash
    var expected_hash: [20]u8 = undefined;
    std.crypto.hash.Ripemd160.hash("test data", &expected_hash, .{});
    try testing.expectEqualSlices(u8, &expected_hash, output[12..32]);
}
