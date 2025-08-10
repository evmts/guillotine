/// ECMUL precompile implementation (address 0x07)
///
/// Implements elliptic curve scalar multiplication on the BN254 (alt_bn128) curve according to EIP-196.
/// This precompile multiplies a point by a scalar and is used for zkSNARK verification
/// and other cryptographic applications requiring elliptic curve operations.
///
/// ## Gas Cost
/// - Byzantium to Berlin: 40,000 gas
/// - Istanbul onwards: 6,000 gas (EIP-1108 optimization)
///
/// ## Input Format
/// - 96 bytes total (3 × 32-byte fields)
/// - Bytes 0-31: x coordinate (big-endian)
/// - Bytes 32-63: y coordinate (big-endian)
/// - Bytes 64-95: scalar k (big-endian)
/// - Shorter inputs are zero-padded
///
/// ## Output Format
/// - 64 bytes (2 × 32-byte coordinates)
/// - Bytes 0-31: x coordinate of result (big-endian)
/// - Bytes 32-63: y coordinate of result (big-endian)
/// - Point at infinity represented as (0, 0)
///
/// ## Error Handling
/// - Invalid points (not on curve): Return (0, 0)
/// - Malformed input: Return (0, 0)
/// - Out of gas: Standard precompile error
const std = @import("std");
const builtin = @import("builtin");
const log = @import("../log.zig");
const GasConstants = @import("primitives").GasConstants;
const PrecompileOutput = @import("precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("precompile_result.zig").PrecompileError;
const ChainRules = @import("../hardforks/chain_rules.zig").ChainRules;
const ec_validation = @import("ec_validation.zig");

// Conditional imports based on target
const bn254_backend = if (builtin.target.cpu.arch == .wasm32)
    @import("bn254.zig") // Pure Zig implementation for WASM
else
    @import("bn254_rust_wrapper.zig"); // Rust implementation for native

/// Calculate gas cost for ECMUL based on chain rules
///
/// Gas costs changed with EIP-1108 (Istanbul hardfork) to make elliptic curve
/// operations more affordable for zkSNARK applications.
///
/// @param chain_rules Current chain configuration
/// @return Gas cost for ECMUL operation
pub fn calculate_gas(chain_rules: ChainRules) u64 {
    if (chain_rules.is_istanbul) {
        @branchHint(.likely);
        return GasConstants.ECMUL_GAS_COST;
    } else {
        @branchHint(.cold);
        return GasConstants.ECMUL_GAS_COST_BYZANTIUM;
    }
}

/// Calculate gas cost with overflow protection (for precompile dispatcher)
///
/// This is a compatibility function for the precompile dispatcher system.
/// Since ECMUL has fixed gas costs that depend on hardfork rules rather than input size,
/// this function returns the modern (Istanbul+) gas cost as the default.
///
/// @param input_size Size of input data (not used for ECMUL)
/// @return Gas cost for ECMUL operation
pub fn calculate_gas_checked(input_size: usize) !u64 {
    _ = input_size; // ECMUL has fixed gas cost regardless of input size
    // Return Istanbul gas cost as default (most common case)
    // The actual hardfork-specific gas cost will be calculated in execute()
    return GasConstants.ECMUL_GAS_COST;
}

/// Execute ECMUL precompile
///
/// This is the main entry point for ECMUL execution. It performs:
/// 1. Gas cost validation
/// 2. Input parsing and padding
/// 3. Point validation
/// 4. Elliptic curve scalar multiplication
/// 5. Result formatting
///
/// @param input Input data (up to 96 bytes)
/// @param output Output buffer (must be >= 64 bytes)
/// @param gas_limit Maximum gas available
/// @param chain_rules Current chain configuration
/// @return PrecompileOutput with success/failure and gas usage
pub fn execute(input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
    // Calculate and validate gas cost
    const gas_cost = calculate_gas(chain_rules);
    if (ec_validation.validate_gas_requirement(gas_cost, gas_limit)) |failure_result| {
        return failure_result;
    }

    // Validate output buffer size
    if (ec_validation.validate_output_buffer_size(output, 64)) |failure_result| {
        return failure_result;
    }

    // Pad input to exactly 96 bytes (zero-padding for shorter inputs)
    const padded_input = ec_validation.pad_input(input, 96);

    if (builtin.target.cpu.arch == .wasm32) {
        // WASM builds: Use limited pure Zig implementation
        // TODO: Implement full scalar multiplication in pure Zig for WASM
        // For now, return point at infinity for all scalar multiplications
        log.warn("ECMUL in WASM build: using placeholder implementation (returns point at infinity)", .{});
        return ec_validation.return_point_at_infinity(output, gas_cost);
    } else {
        // Use Rust implementation for native targets
        // Ensure BN254 Rust library is initialized
        bn254_backend.init() catch {
            @branchHint(.cold);
            return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
        };

        // Perform elliptic curve scalar multiplication using Rust BN254 library
        bn254_backend.ecmul(&padded_input, output[0..64]) catch {
            @branchHint(.cold);
            // Invalid input results in point at infinity (0, 0)
            return ec_validation.return_point_at_infinity(output, gas_cost);
        };
    }

    return PrecompileOutput.success_result(gas_cost, 64);
}

/// Get expected output size for ECMUL
///
/// ECMUL always produces 64 bytes of output (two 32-byte coordinates).
///
/// @param input_size Size of input data (unused)
/// @return Fixed output size of 64 bytes
pub fn get_output_size(input_size: usize) usize {
    _ = input_size; // Output size is fixed regardless of input
    return 64;
}

/// Validate gas requirement without executing
///
/// Checks if an ECMUL call would succeed with the given gas limit.
///
/// @param input_size Size of input data (unused)
/// @param gas_limit Available gas limit
/// @param chain_rules Current chain configuration
/// @return true if operation would succeed
pub fn validate_gas_requirement(input_size: usize, gas_limit: u64, chain_rules: ChainRules) bool {
    _ = input_size; // Gas cost is fixed regardless of input size
    const gas_cost = calculate_gas(chain_rules);
    return gas_cost <= gas_limit;
}

// Tests
const testing = std.testing;

test "ECMUL basic scalar multiplication" {
    // Create chain rules for Istanbul hardfork (6000 gas cost)
    const chain_rules = ChainRules.for_hardfork(.ISTANBUL);

    // Test multiplying point at infinity by any scalar
    var input = [_]u8{0} ** 96; // All zeros = point at infinity, scalar = 0
    var output = [_]u8{0} ** 64;

    const result = execute(&input, &output, 10000, chain_rules);
    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, 6000), result.get_gas_used());
    try testing.expectEqual(@as(usize, 64), result.get_output_size());

    // Result should be point at infinity (0, 0)
    for (output) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "ECMUL generator point by zero" {
    const chain_rules = ChainRules.for_hardfork(.ISTANBUL);

    // Test multiplying generator point (1, 2) by scalar 0
    var input = [_]u8{0} ** 96;

    // Set point to (1, 2)
    input[31] = 1; // x = 1
    input[63] = 2; // y = 2
    // Scalar remains 0

    var output = [_]u8{0} ** 64;
    const result = execute(&input, &output, 10000, chain_rules);

    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, 6000), result.get_gas_used());

    // Result should be point at infinity (0, 0) since any point * 0 = O
    for (output) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "ECMUL generator point by one" {
    const chain_rules = ChainRules.for_hardfork(.ISTANBUL);

    // Test multiplying generator point (1, 2) by scalar 1
    var input = [_]u8{0} ** 96;

    // Set point to (1, 2)
    input[31] = 1; // x = 1
    input[63] = 2; // y = 2
    // Set scalar to 1
    input[95] = 1; // scalar = 1

    var output = [_]u8{0} ** 64;
    const result = execute(&input, &output, 10000, chain_rules);

    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, 6000), result.get_gas_used());

    // Result should be (1, 2) since generator * 1 = generator
    try testing.expectEqual(@as(u8, 1), output[31]); // x coordinate
    try testing.expectEqual(@as(u8, 2), output[63]); // y coordinate
}

test "ECMUL invalid point" {
    const chain_rules = ChainRules.for_hardfork(.ISTANBUL);

    // Test with invalid point (1, 1) - not on curve
    var input = [_]u8{0} ** 96;
    input[31] = 1; // x = 1
    input[63] = 1; // y = 1 (invalid)
    input[95] = 5; // scalar = 5

    var output = [_]u8{0} ** 64;
    const result = execute(&input, &output, 10000, chain_rules);

    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, 6000), result.get_gas_used());

    // Result should be point at infinity (0, 0)
    for (output) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "ECMUL gas costs by hardfork" {
    // Test Byzantium gas cost (before Istanbul)
    const byzantium_rules = ChainRules.for_hardfork(.BYZANTIUM);
    const byzantium_gas = calculate_gas(byzantium_rules);
    try testing.expectEqual(@as(u64, 40000), byzantium_gas);

    // Test Istanbul gas cost (reduced costs)
    const istanbul_rules = ChainRules.for_hardfork(.ISTANBUL);
    const istanbul_gas = calculate_gas(istanbul_rules);
    try testing.expectEqual(@as(u64, 6000), istanbul_gas);
}

test "ECMUL out of gas" {
    const chain_rules = ChainRules.for_hardfork(.ISTANBUL);

    var input = [_]u8{0} ** 96;
    var output = [_]u8{0} ** 64;

    // Provide insufficient gas
    const result = execute(&input, &output, 1000, chain_rules);

    try testing.expect(result.is_failure());
    try testing.expectEqual(PrecompileError.OutOfGas, result.get_error().?);
}

test "ECMUL short input handling" {
    const chain_rules = ChainRules.for_hardfork(.ISTANBUL);

    // Test with short input (should be zero-padded)
    var input = [_]u8{ 1, 2, 3 }; // Only 3 bytes
    var output = [_]u8{0} ** 64;

    const result = execute(&input, &output, 10000, chain_rules);

    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, 6000), result.get_gas_used());

    // Should treat as mostly zero input and return point at infinity
    for (output) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}
