const std = @import("std");
const PrecompileResult = @import("precompile_result.zig").PrecompileResult;
const PrecompileOutput = @import("precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("precompile_result.zig").PrecompileError;
const primitives = @import("primitives");
const crypto = @import("crypto");

/// ModExp precompile implementation (address 0x05)
///
/// This implementation uses Zig's standard library big integer support for
/// arbitrary-precision modular exponentiation following the Ethereum specification.
///
/// ## Input Format
/// - Bytes 0-31: Length of base (big-endian)
/// - Bytes 32-63: Length of exponent (big-endian)
/// - Bytes 64-95: Length of modulus (big-endian)
/// - Bytes 96+: base || exponent || modulus (all big-endian)
///
/// ## Output Format
/// - Result of base^exponent mod modulus, left-padded with zeros to modulus length
///
/// ## Gas Cost
/// - Complex formula based on input sizes and exponent magnitude
/// - Minimum cost: 200 gas
/// Gas constants for ModExp precompile (per EIP-198)
pub const MODEXP_MIN_GAS: u64 = primitives.GasConstants.MODEXP_MIN_GAS;
pub const MODEXP_QUADRATIC_THRESHOLD: usize = primitives.GasConstants.MODEXP_QUADRATIC_THRESHOLD;
pub const MODEXP_LINEAR_THRESHOLD: usize = primitives.GasConstants.MODEXP_LINEAR_THRESHOLD;

/// Calculates the gas cost for ModExp precompile execution
///
/// Follows the Ethereum specification for ModExp gas calculation:
/// - f(x) = x for x <= 64
/// - f(x) = x^2/4 + 96*x - 3072 for 64 < x <= 1024
/// - f(x) = x^2/16 + 480*x - 199680 for x > 1024
///
/// @param base_len Length of the base in bytes
/// @param exp_len Length of the exponent in bytes
/// @param mod_len Length of the modulus in bytes
/// @param exp_bytes The exponent bytes for determining adjusted length
/// @return Total gas cost for the operation
pub fn calculate_gas(base_len: usize, exp_len: usize, mod_len: usize, exp_bytes: []const u8) u64 {
    // Calculate max(base_len, mod_len)
    const max_len = @max(base_len, mod_len);

    // Calculate multiplication complexity
    const mult_complexity = calculate_multiplication_complexity(max_len);

    // Calculate adjusted exponent length
    const adj_exp_len = calculate_adjusted_exponent_length(exp_len, exp_bytes);

    // Gas = mult_complexity * max(adj_exp_len, 1) / 20
    const gas = mult_complexity * @max(adj_exp_len, 1) / 20;

    return @max(gas, MODEXP_MIN_GAS);
}

/// Calculates multiplication complexity based on size
fn calculate_multiplication_complexity(x: usize) u64 {
    return crypto.ModExp.unaudited_calculateMultiplicationComplexity(x);
}

/// Calculates adjusted exponent length based on leading zeros
fn calculate_adjusted_exponent_length(exp_len: usize, exp_bytes: []const u8) u64 {
    return crypto.ModExp.unaudited_calculateAdjustedExponentLength(exp_len, exp_bytes);
}

/// Executes the ModExp precompile
///
/// This function performs modular exponentiation using Zig's big integer library:
/// 1. Parses input to extract base, exponent, and modulus lengths
/// 2. Validates input and gas requirements
/// 3. Performs base^exponent mod modulus calculation
/// 4. Returns result padded to modulus length
///
/// @param input Input data containing lengths and values
/// @param output Output buffer to write result
/// @param gas_limit Maximum gas available for this operation
/// @return PrecompileOutput containing success/failure and gas usage
pub fn execute(input: []const u8, output: []u8, gas_limit: u64) PrecompileOutput {
    // Need at least 96 bytes for the three length fields
    if (input.len < 96) {
        return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
    }

    // Parse lengths from input (big-endian 32-byte fields)
    const base_len = parse_u256_to_usize(input[0..32]);
    const exp_len = parse_u256_to_usize(input[32..64]);
    const mod_len = parse_u256_to_usize(input[64..96]);

    // Check for reasonable limits to prevent excessive memory allocation
    const max_size = 1024 * 1024; // 1MB limit
    if (base_len > max_size or exp_len > max_size or mod_len > max_size) {
        return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
    }

    // Calculate required input size
    const required_input_size = 96 + base_len + exp_len + mod_len;
    if (input.len < required_input_size) {
        return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
    }

    // Extract base, exponent, and modulus from input
    const base_start = 96;
    const exp_start = base_start + base_len;
    const mod_start = exp_start + exp_len;

    const base_bytes = if (base_len > 0) input[base_start..exp_start] else &[_]u8{};
    const exp_bytes = if (exp_len > 0) input[exp_start..mod_start] else &[_]u8{};
    const mod_bytes = if (mod_len > 0) input[mod_start .. mod_start + mod_len] else &[_]u8{};

    // Calculate gas cost
    const gas_cost = calculate_gas(base_len, exp_len, mod_len, exp_bytes);

    // Check if we have enough gas
    if (gas_cost > gas_limit) {
        return PrecompileOutput.failure_result(PrecompileError.OutOfGas);
    }

    // Handle edge cases
    if (mod_len == 0) {
        // Modulus length 0 means result is 0
        return PrecompileOutput.success_result(gas_cost, 0);
    }

    // Check if modulus is zero
    if (crypto.ModExp.unaudited_isZero(mod_bytes)) {
        // Modulus is 0, result is 0
        @memset(output[0..mod_len], 0);
        return PrecompileOutput.success_result(gas_cost, mod_len);
    }

    // Validate output buffer size
    if (output.len < mod_len) {
        return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
    }

    // Perform modular exponentiation using primitives
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    crypto.ModExp.unaudited_modexp(allocator, base_bytes, exp_bytes, mod_bytes, output[0..mod_len]) catch {
        return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
    };

    return PrecompileOutput.success_result(gas_cost, mod_len);
}

/// Parses a 32-byte big-endian value to usize
pub fn parse_u256_to_usize(bytes: []const u8) usize {
    std.debug.assert(bytes.len == 32);

    // For usize, we only care about the last 8 bytes on 64-bit systems
    // or last 4 bytes on 32-bit systems
    const usize_bytes = @sizeOf(usize);
    const start = 32 - usize_bytes;

    var result: usize = 0;
    for (bytes[start..]) |byte| {
        result = (result << 8) | byte;
    }

    return result;
}

/// Gets the expected output size for ModExp precompile
///
/// ModExp always returns exactly modulus_length bytes.
///
/// @param input Input data to parse modulus length from
/// @return Expected output size or 0 if input is invalid
pub fn get_output_size(input: []const u8) usize {
    if (input.len < 96) return 0;

    const mod_len = parse_u256_to_usize(input[64..96]);
    return mod_len;
}
