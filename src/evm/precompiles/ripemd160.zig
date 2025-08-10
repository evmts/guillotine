const std = @import("std");
const PrecompileResult = @import("precompile_result.zig").PrecompileResult;
const PrecompileOutput = @import("precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("precompile_result.zig").PrecompileError;
const primitives = @import("primitives");
const crypto = @import("crypto");
const GasConstants = @import("primitives").GasConstants;

/// RIPEMD160 precompile implementation (address 0x03)
///
/// This implementation is based on the Bitcoin Core reference implementation
/// and provides a production-ready RIPEMD160 hash function following the
/// Ethereum precompile specification.
///
/// ## Input Format
/// - Any length byte array (no restrictions)
///
/// ## Output Format
/// - Always 32 bytes: 20-byte RIPEMD160 hash + 12 zero bytes (left-padding)
///
/// ## Gas Cost
/// - Base cost: 600 gas
/// - Per word cost: 120 gas per 32-byte word
/// - Total: 600 + 120 * ceil(input_size / 32)
///
/// ## Examples
/// ```zig
/// // Empty input hash
/// const empty_result = execute(&[_]u8{}, &output, 1000);
/// // RIPEMD160("") = 9c1185a5c5e9fc54612808977ee8f548b2258d31
///
/// // "abc" hash
/// const abc_input = "abc";
/// const abc_result = execute(abc_input, &output, 1000);
/// // RIPEMD160("abc") = 8eb208f7e05d987a9b044a8e98c6b087f15a0bfc
/// ```
/// Gas constants for RIPEMD160 precompile (per Ethereum specification)
pub const RIPEMD160_BASE_GAS_COST: u64 = 600;
pub const RIPEMD160_WORD_GAS_COST: u64 = 120;

/// Expected output size for RIPEMD160 (32 bytes with padding)
const RIPEMD160_OUTPUT_SIZE: usize = 32;

/// Actual RIPEMD160 hash size (20 bytes)
const RIPEMD160_HASH_SIZE: usize = 20;

/// Calculates the gas cost for RIPEMD160 precompile execution
///
/// Follows the Ethereum specification: 600 + 120 * ceil(input_size / 32)
/// The cost increases linearly with input size to account for processing overhead.
///
/// @param input_size Size of the input data in bytes
/// @return Total gas cost for the operation
pub fn calculate_gas(input_size: usize) u64 {
    const word_count = GasConstants.wordCount(input_size);
    return RIPEMD160_BASE_GAS_COST + RIPEMD160_WORD_GAS_COST * @as(u64, @intCast(word_count));
}

/// Calculates gas cost with overflow protection
///
/// This function provides safe gas calculation that prevents integer overflow
/// for extremely large inputs that could cause arithmetic overflow.
///
/// @param input_size Size of the input data in bytes
/// @return Gas cost or error if overflow would occur
pub fn calculate_gas_checked(input_size: usize) !u64 {
    // Check for potential overflow in word count calculation
    if (input_size > std.math.maxInt(u64) - 31) {
        return error.Overflow;
    }

    const word_count = GasConstants.wordCount(input_size);

    // Check for overflow in multiplication
    if (word_count > std.math.maxInt(u64) / RIPEMD160_WORD_GAS_COST) {
        return error.Overflow;
    }

    const word_gas = RIPEMD160_WORD_GAS_COST * @as(u64, @intCast(word_count));

    // Check for overflow in addition
    if (word_gas > std.math.maxInt(u64) - RIPEMD160_BASE_GAS_COST) {
        return error.Overflow;
    }

    return RIPEMD160_BASE_GAS_COST + word_gas;
}

/// Hash function wrapper for RIPEMD160
///
/// Wrapper that matches the signature expected by executeHashPrecompile template.
/// This allows RIPEMD160 to use the generic hash precompile implementation.
///
/// @param input Input data to hash
/// @param output Output buffer for hash result (must be at least 32 bytes)
fn ripemd160Hash(input: []const u8, output: []u8) void {
    // Hash directly into the right position in the output buffer (after padding)
    // RIPEMD160 produces 20 bytes, but Ethereum requires 32 bytes with left padding
    const hash = crypto.HashAlgorithms.RIPEMD160.hash_fixed(input);

    // Zero out the padding area (first 12 bytes)
    @memset(output[0..12], 0);

    // Copy the hash after the padding
    @memcpy(output[12..32], &hash);
}

/// Output formatter for RIPEMD160
///
/// Since we already hash and pad directly into the output buffer,
/// this is a no-op for RIPEMD160.
///
/// @param hash_bytes The hash (already in output buffer with padding)
/// @param output The output buffer (same as hash_bytes for in-place operation)
fn ripemd160Format(hash_bytes: []const u8, output: []u8) void {
    // No-op: RIPEMD160 already wrote and padded directly to the output buffer
    _ = hash_bytes;
    _ = output;
}

/// Executes the RIPEMD160 precompile
///
/// This function performs the complete RIPEMD160 precompile execution:
/// 1. Validates gas requirements
/// 2. Computes RIPEMD160 hash using the core implementation
/// 3. Formats output as 32 bytes with zero padding
/// 4. Returns execution result with gas usage
///
/// This implementation now uses the shared executeHashPrecompile template for
/// consistency and potential size reduction through code reuse.
///
/// @param input Input data to hash (any length)
/// @param output Output buffer to write result (must be >= 32 bytes)
/// @param gas_limit Maximum gas available for this operation
/// @return PrecompileOutput containing success/failure and gas usage
pub fn execute(input: []const u8, output: []u8, gas_limit: u64) PrecompileOutput {
    const precompile_utils = @import("precompile_gas.zig");
    return precompile_utils.executeHashPrecompile(
        RIPEMD160_BASE_GAS_COST,
        RIPEMD160_WORD_GAS_COST,
        ripemd160Hash,
        RIPEMD160_OUTPUT_SIZE,
        ripemd160Format,
        input,
        output,
        gas_limit,
    );
}

/// Validates that a precompile call would succeed without executing
///
/// This function performs gas and input validation without actually executing
/// the hash computation. Useful for transaction validation and gas estimation.
///
/// @param input_size Size of the input data
/// @param gas_limit Available gas limit
/// @return true if the call would succeed
pub fn validate_call(input_size: usize, gas_limit: u64) bool {
    const gas_cost = calculate_gas(input_size);
    return gas_cost <= gas_limit;
}

/// Gets the expected output size for RIPEMD160 precompile
///
/// RIPEMD160 always returns exactly 32 bytes regardless of input size.
/// This consists of the 20-byte hash followed by 12 zero bytes.
///
/// @param input_size Size of input (unused, but kept for interface consistency)
/// @return Always returns 32
pub fn get_output_size(input_size: usize) usize {
    _ = input_size; // Unused parameter
    return RIPEMD160_OUTPUT_SIZE;
}

/// Known RIPEMD160 test vectors for validation
pub const TestVector = struct {
    input: []const u8,
    expected_hash: [20]u8,
};

/// Standard RIPEMD160 test vectors from the specification
/// Use these to validate the approved cryptographic library implementation
pub const test_vectors = [_]TestVector{
    // Empty string: RIPEMD160("") = 9c1185a5c5e9fc54612808977ee8f548b2258d31
    .{
        .input = "",
        .expected_hash = [20]u8{ 0x9c, 0x11, 0x85, 0xa5, 0xc5, 0xe9, 0xfc, 0x54, 0x61, 0x28, 0x08, 0x97, 0x7e, 0xe8, 0xf5, 0x48, 0xb2, 0x25, 0x8d, 0x31 },
    },
    // "a": RIPEMD160("a") = 0bdc9d2d256b3ee9daae347be6f4dc835a467ffe
    .{
        .input = "a",
        .expected_hash = [20]u8{ 0x0b, 0xdc, 0x9d, 0x2d, 0x25, 0x6b, 0x3e, 0xe9, 0xda, 0xae, 0x34, 0x7b, 0xe6, 0xf4, 0xdc, 0x83, 0x5a, 0x46, 0x7f, 0xfe },
    },
    // "abc": RIPEMD160("abc") = 8eb208f7e05d987a9b044a8e98c6b087f15a0bfc
    .{
        .input = "abc",
        .expected_hash = [20]u8{ 0x8e, 0xb2, 0x08, 0xf7, 0xe0, 0x5d, 0x98, 0x7a, 0x9b, 0x04, 0x4a, 0x8e, 0x98, 0xc6, 0xb0, 0x87, 0xf1, 0x5a, 0x0b, 0xfc },
    },
};
