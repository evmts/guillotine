const std = @import("std");
const primitives = @import("primitives");
const gas_constants = primitives.GasConstants;

/// Gas calculation utilities for precompiles
///
/// This module provides common gas calculation patterns used by precompiles.
/// Many precompiles use linear gas costs (base + per_word * word_count) or other
/// standard patterns defined here.
/// Calculates linear gas cost: base_cost + per_word_cost * ceil(input_size / 32)
///
/// This is the most common gas calculation pattern for precompiles. The cost consists
/// of a base cost plus a per-word cost for each 32-byte word of input data.
/// Partial words are rounded up to full words.
///
/// @param input_size Size of the input data in bytes
/// @param base_cost Base gas cost regardless of input size
/// @param per_word_cost Gas cost per 32-byte word of input
/// @return Total gas cost for the operation
pub fn calculate_linear_cost(input_size: usize, base_cost: u64, per_word_cost: u64) u64 {
    const word_count = gas_constants.wordCount(input_size);
    return base_cost + per_word_cost * @as(u64, @intCast(word_count));
}

/// Calculates linear gas cost with checked arithmetic to prevent overflow
///
/// Same as calculate_linear_cost but returns an error if the calculation would overflow.
/// This is important for very large input sizes that could cause integer overflow.
///
/// @param input_size Size of the input data in bytes
/// @param base_cost Base gas cost regardless of input size
/// @param per_word_cost Gas cost per 32-byte word of input
/// @return Total gas cost or error if overflow occurs
pub fn calculate_linear_cost_checked(input_size: usize, base_cost: u64, per_word_cost: u64) !u64 {
    const word_count = gas_constants.wordCount(input_size);
    const word_count_u64 = std.math.cast(u64, word_count) orelse {
        @branchHint(.cold);
        return error.Overflow;
    };

    const word_cost = std.math.mul(u64, per_word_cost, word_count_u64) catch {
        @branchHint(.cold);
        return error.Overflow;
    };
    const total_cost = std.math.add(u64, base_cost, word_cost) catch {
        @branchHint(.cold);
        return error.Overflow;
    };

    return total_cost;
}

/// Validates that the gas limit is sufficient for the calculated cost
///
/// This is a convenience function that combines gas calculation with validation.
/// It calculates the required gas and checks if the provided limit is sufficient.
///
/// @param input_size Size of the input data in bytes
/// @param base_cost Base gas cost regardless of input size
/// @param per_word_cost Gas cost per 32-byte word of input
/// @param gas_limit Maximum gas available for the operation
/// @return The calculated gas cost if within limit, error otherwise
pub fn validate_gas_limit(input_size: usize, base_cost: u64, per_word_cost: u64, gas_limit: u64) !u64 {
    const gas_cost = try calculate_linear_cost_checked(input_size, base_cost, per_word_cost);

    if (gas_cost > gas_limit) {
        @branchHint(.cold);
        return error.OutOfGas;
    }

    return gas_cost;
}

/// Calculates the number of 32-byte words for a given byte size
///
/// This is a utility function for converting byte sizes to word counts.
/// Used when precompiles need to know the exact word count for other calculations.
///
/// @param byte_size Size in bytes
/// @return Number of 32-byte words (rounded up)
pub fn bytes_to_words(byte_size: usize) usize {
    return gas_constants.wordCount(byte_size);
}

/// Calculates gas cost for dynamic-length operations
///
/// Some precompiles have more complex gas calculations that depend on the
/// content of the input data, not just its size. This provides a framework
/// for such calculations.
///
/// @param input_data The input data to analyze
/// @param base_cost Base gas cost
/// @param calculate_dynamic_cost Function to calculate additional cost based on input
/// @return Total gas cost
pub fn calculate_dynamic_cost(input_data: []const u8, base_cost: u64, calculate_dynamic_cost_fn: fn ([]const u8) u64) u64 {
    const dynamic_cost = calculate_dynamic_cost_fn(input_data);
    return base_cost + dynamic_cost;
}

// ============================================================================
// SHARED PRECOMPILE UTILITIES
// ============================================================================

/// Generic hash precompile execution template
///
/// This template consolidates the common execution pattern used by hash-based
/// precompiles like SHA256 and RIPEMD160. It handles gas checking, output
/// validation, hash computation, and result formatting in a unified way.
///
/// @param comptime base_cost Base gas cost for the precompile
/// @param comptime per_word_cost Gas cost per 32-byte word of input
/// @param comptime hash_fn Hash function that takes input bytes and produces fixed-size hash
/// @param comptime hash_size Size of the hash output in bytes
/// @param comptime output_size Total output size (may include padding)
/// @param comptime format_output Function to format hash into final output
/// @param input Input data to hash
/// @param output Output buffer to write result
/// @param gas_limit Maximum gas available for execution
/// @return PrecompileOutput with success/failure status and gas usage
pub fn executeHashPrecompile(
    comptime base_cost: u64,
    comptime per_word_cost: u64,
    comptime hash_fn: fn ([]const u8, []u8) void,
    comptime output_size: usize,
    comptime format_output: fn ([]const u8, []u8) void,
    input: []const u8,
    output: []u8,
    gas_limit: u64,
) @import("precompile_result.zig").PrecompileOutput {
    const PrecompileOutput = @import("precompile_result.zig").PrecompileOutput;
    const PrecompileError = @import("precompile_result.zig").PrecompileError;

    // Calculate required gas using common linear cost function
    const gas_cost = calculate_linear_cost(input.len, base_cost, per_word_cost);

    // Check if we have enough gas
    if (gas_cost > gas_limit) {
        @branchHint(.cold);
        return PrecompileOutput.failure_result(PrecompileError.OutOfGas);
    }

    // Validate output buffer size
    if (output.len < output_size) {
        @branchHint(.cold);
        return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
    }

    // Compute hash directly into output buffer (avoids intermediate allocation)
    // Most hash functions can write directly to the output buffer
    hash_fn(input, output);

    // Format output in-place if needed (e.g., for padding)
    format_output(output, output);

    return PrecompileOutput.success_result(gas_cost, output_size);
}

/// Formats hash output with left padding (for RIPEMD160)
///
/// RIPEMD160 outputs a 20-byte hash but must be formatted as 32 bytes with
/// 12 zero bytes of left padding according to Ethereum specification.
///
/// @param hash_bytes The 20-byte hash to format
/// @param output The 32-byte output buffer to fill
pub fn formatLeftPaddedHash(comptime hash_size: usize, hash_bytes: []const u8, output: []u8) void {
    const output_size = 32;
    const padding_size = output_size - hash_size;

    // Zero out the entire output buffer
    @memset(output[0..output_size], 0);

    // Copy hash to the right position (after padding)
    @memcpy(output[padding_size..output_size], hash_bytes[0..hash_size]);
}

/// Formats hash output without padding (for SHA256)
///
/// SHA256 outputs exactly 32 bytes which matches the expected output size,
/// so no padding is required.
///
/// @param hash_bytes The 32-byte hash to copy
/// @param output The 32-byte output buffer to fill
pub fn formatDirectHash(comptime hash_size: usize, hash_bytes: []const u8, output: []u8) void {
    @memcpy(output[0..hash_size], hash_bytes[0..hash_size]);
}

/// Common input padding utility
///
/// Many precompiles need to pad input to specific sizes. This utility provides
/// a common implementation for zero-padding input data.
///
/// @param input Source input data
/// @param padded_buffer Target buffer to fill (must be pre-allocated)
/// @param target_size Size to pad to
pub fn padInput(input: []const u8, padded_buffer: []u8, target_size: usize) void {
    std.debug.assert(padded_buffer.len >= target_size);

    // Zero out the entire buffer
    @memset(padded_buffer[0..target_size], 0);

    // Copy input data (truncate if longer than target)
    const copy_len = @min(input.len, target_size);
    @memcpy(padded_buffer[0..copy_len], input[0..copy_len]);
}

/// Converts bytes to u256 (big-endian)
///
/// Common utility for converting byte arrays to 256-bit integers.
/// Used by various precompiles for coordinate and field element parsing.
///
/// @param bytes Input bytes (up to 32 bytes)
/// @return u256 value in big-endian representation
pub fn bytesToU256(bytes: []const u8) u256 {
    var result: u256 = 0;
    const len = @min(bytes.len, 32);

    for (bytes[0..len]) |byte| {
        result = (result << 8) | @as(u256, byte);
    }

    return result;
}

/// Converts u256 to bytes (big-endian, 32 bytes)
///
/// Common utility for converting 256-bit integers to byte arrays.
/// Always produces exactly 32 bytes with leading zeros if necessary.
///
/// @param value u256 value to convert
/// @param output Output buffer (must be at least 32 bytes)
pub fn u256ToBytes(value: u256, output: []u8) void {
    std.debug.assert(output.len >= 32);

    var temp_value = value;
    var i: usize = 32;

    while (i > 0) {
        i -= 1;
        output[i] = @as(u8, @intCast(temp_value & 0xFF));
        temp_value >>= 8;
    }
}
