const std = @import("std");
const PrecompileOutput = @import("precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("precompile_result.zig").PrecompileError;
const GasConstants = @import("primitives").GasConstants;
const primitives = @import("primitives");
const crypto = @import("crypto");

/// SHA256 precompile implementation
///
/// This module implements the SHA256 cryptographic hash function precompile at address 0x02.
/// The precompile follows the Ethereum specification:
///
/// - Address: 0x0000000000000000000000000000000000000002
/// - Gas cost: 60 + 12 * ceil(input_size / 32)
/// - Output: Always 32 bytes (SHA256 hash)
/// - Available: From Frontier hardfork onwards
///
/// ## Gas Calculation
/// The gas cost is calculated as a base cost of 60 gas plus 12 gas per 32-byte word.
/// This reflects the computational cost of hashing data.
///
/// ## Implementation
/// Uses Zig's standard library `std.crypto.hash.sha2.Sha256` for the actual cryptographic operation.
/// This ensures security, correctness, and performance while maintaining minimal code complexity.
///
/// ## Security
/// SHA256 is a cryptographically secure hash function that produces a 256-bit (32-byte) digest.
/// The implementation is resistant to length extension attacks and produces deterministic output.
/// Base gas cost for SHA256 precompile
/// This is the minimum cost regardless of input size
const SHA256_BASE_COST: u64 = 60;

/// Gas cost per 32-byte word for SHA256 precompile
/// Total cost = SHA256_BASE_COST + (word_count * SHA256_WORD_COST)
const SHA256_WORD_COST: u64 = 12;

/// SHA256 always outputs exactly 32 bytes
const SHA256_OUTPUT_SIZE: usize = crypto.HashAlgorithms.SHA256.OUTPUT_SIZE;

/// Calculate gas cost for SHA256 precompile
///
/// The gas cost follows the formula: 60 + 12 * ceil(input_size / 32)
/// This provides a base cost plus a linear cost based on the number of 32-byte words.
///
/// @param input_size Size of input data in bytes
/// @return Gas cost for processing this input
pub fn calculate_gas(input_size: usize) u64 {
    const word_count = GasConstants.wordCount(input_size);
    return SHA256_BASE_COST + SHA256_WORD_COST * word_count;
}

/// Calculate gas cost with overflow checking
///
/// Same as calculate_gas but returns an error if the calculation would overflow.
/// This is important for very large inputs that could cause arithmetic overflow.
/// Uses std.math functions for cleaner and more robust overflow handling.
///
/// @param input_size Size of input data in bytes
/// @return Gas cost or error.Overflow if calculation overflows
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

/// Hash function wrapper for SHA256
///
/// Wrapper that matches the signature expected by executeHashPrecompile template.
/// This allows SHA256 to use the generic hash precompile implementation.
/// Uses hardware acceleration when available for improved performance.
///
/// @param input Input data to hash
/// @param output Output buffer for hash result (must be at least 32 bytes)
fn sha256Hash(input: []const u8, output: []u8) void {
    // Hash directly into the output buffer to avoid intermediate allocation
    // The output buffer must be at least SHA256_OUTPUT_SIZE bytes
    crypto.SHA256_Accel.SHA256_Accel.hash(input, output[0..SHA256_OUTPUT_SIZE]);
}

/// Output formatter for SHA256
///
/// SHA256 outputs exactly 32 bytes which matches the expected output size,
/// so no padding is required. Since we hash directly into the output buffer,
/// this is a no-op for SHA256.
///
/// @param hash_bytes The hash (already in output buffer)
/// @param output The output buffer (same as hash_bytes for in-place operation)
fn sha256Format(hash_bytes: []const u8, output: []u8) void {
    // No-op: SHA256 already wrote directly to the output buffer
    // and doesn't need any formatting or padding
    _ = hash_bytes;
    _ = output;
}

/// Execute SHA256 precompile
///
/// Computes the SHA256 hash of the input data and writes it to the output buffer.
/// Performs gas checking and validates output buffer size before execution.
///
/// This implementation now uses the shared executeHashPrecompile template for
/// consistency and potential size reduction through code reuse.
///
/// @param input Input data to hash
/// @param output Output buffer for the 32-byte hash (must be at least 32 bytes)
/// @param gas_limit Maximum gas available for execution
/// @return PrecompileOutput with success/failure status and gas usage
pub fn execute(input: []const u8, output: []u8, gas_limit: u64) PrecompileOutput {
    const precompile_utils = @import("precompile_gas.zig");
    return precompile_utils.executeHashPrecompile(
        SHA256_BASE_COST,
        SHA256_WORD_COST,
        sha256Hash,
        SHA256_OUTPUT_SIZE,
        sha256Format,
        input,
        output,
        gas_limit,
    );
}

/// Validate that sufficient gas is available for the given input size
///
/// @param input_size Size of input data in bytes
/// @param available_gas Available gas limit
/// @return true if gas is sufficient, false otherwise
pub fn validate_gas_requirement(input_size: usize, available_gas: u64) bool {
    const required_gas = calculate_gas(input_size);
    return required_gas <= available_gas;
}

/// Get the output size for SHA256 precompile
///
/// SHA256 always produces exactly 32 bytes of output regardless of input size.
/// This function is provided for consistency with other precompiles.
///
/// @param input_size Size of input data (unused for SHA256)
/// @return Always returns 32 (SHA256_OUTPUT_SIZE)
pub fn get_output_size(input_size: usize) usize {
    _ = input_size; // SHA256 output size is always 32 bytes
    return SHA256_OUTPUT_SIZE;
}

test "SHA256 precompile with hardware acceleration" {
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

    for (test_vectors) |tv| {
        const output = try std.testing.allocator.alloc(u8, 32);
        defer std.testing.allocator.free(output);

        const result = execute(tv.input, output, 100000);
        try std.testing.expect(result.is_ok);
        try std.testing.expectEqualSlices(u8, &tv.expected, output);
    }
}

test "SHA256 precompile gas calculation" {
    // Test basic gas calculation
    try std.testing.expectEqual(@as(u64, 60), calculate_gas(0)); // Empty input
    try std.testing.expectEqual(@as(u64, 72), calculate_gas(32)); // 1 word
    try std.testing.expectEqual(@as(u64, 84), calculate_gas(64)); // 2 words
    try std.testing.expectEqual(@as(u64, 96), calculate_gas(96)); // 3 words

    // Test partial word boundaries
    try std.testing.expectEqual(@as(u64, 72), calculate_gas(1)); // 1 byte = 1 word
    try std.testing.expectEqual(@as(u64, 72), calculate_gas(31)); // 31 bytes = 1 word
    try std.testing.expectEqual(@as(u64, 84), calculate_gas(33)); // 33 bytes = 2 words
}

test "SHA256 precompile gas overflow protection" {
    // Test overflow handling
    const max_size = std.math.maxInt(usize);
    const result = calculate_gas_checked(max_size);
    try std.testing.expectError(error.Overflow, result);

    // Test near-overflow
    const large_size = std.math.maxInt(usize) - 1000;
    const result2 = calculate_gas_checked(large_size);
    try std.testing.expectError(error.Overflow, result2);
}

test "SHA256 precompile consistency" {
    // Test that our hardware-accelerated version matches standard SHA256
    const test_data = "The quick brown fox jumps over the lazy dog";
    const output = try std.testing.allocator.alloc(u8, 32);
    defer std.testing.allocator.free(output);

    const result = execute(test_data, output, 100000);
    try std.testing.expect(result.is_ok);

    // Compare with standard library
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(test_data, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, output);
}

test "SHA256 precompile edge cases" {
    const output = try std.testing.allocator.alloc(u8, 32);
    defer std.testing.allocator.free(output);

    // Test insufficient gas
    const result_low_gas = execute("test", output, 10);
    try std.testing.expect(!result_low_gas.is_ok);
    try std.testing.expectEqual(PrecompileError.OutOfGas, result_low_gas.error_value);

    // Test output buffer too small
    const small_output = try std.testing.allocator.alloc(u8, 10);
    defer std.testing.allocator.free(small_output);
    const result_small_buf = execute("test", small_output, 100000);
    try std.testing.expect(!result_small_buf.is_ok);
    try std.testing.expectEqual(PrecompileError.InvalidInput, result_small_buf.error_value);

    // Test exactly enough gas
    const gas_needed = calculate_gas(4); // "test" is 4 bytes
    const result_exact_gas = execute("test", output, gas_needed);
    try std.testing.expect(result_exact_gas.is_ok);
    try std.testing.expectEqual(gas_needed, result_exact_gas.gas_used);
}
