/// ECPAIRING precompile implementation (address 0x08)
///
/// Implements elliptic curve pairing check on the BN254 (alt_bn128) curve according to EIP-197.
/// This precompile computes bilinear pairings and is essential for zkSNARK verification
/// and other advanced cryptographic protocols.
///
/// ## Gas Cost
/// - Byzantium to Berlin: 100,000 + 80,000 * k (where k = number of pairs)
/// - Istanbul onwards: 45,000 + 34,000 * k (EIP-1108 optimization)
///
/// ## Input Format
/// - Variable length: 192 * k bytes (where k = number of pairs)
/// - Each pair consists of 192 bytes:
///   - Bytes 0-63: G1 point (x, y) coordinates (32 bytes each, big-endian)
///   - Bytes 64-191: G2 point coordinates in Fp2 (4 × 32 bytes, big-endian)
/// - Empty input (k=0) is valid and returns 1
/// - Input length must be multiple of 192 bytes
///
/// ## Output Format
/// - 32 bytes containing either:
///   - 0x0000...0001 (true) if pairing equation holds
///   - 0x0000...0000 (false) if pairing equation fails
///
/// ## Pairing Equation
/// For pairs (A₁,B₁), (A₂,B₂), ..., (Aₖ,Bₖ):
/// e(A₁,B₁) * e(A₂,B₂) * ... * e(Aₖ,Bₖ) = 1
///
/// ## Error Handling
/// - Invalid input length: Return failure
/// - Invalid points (not on curve): Return failure
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
    @import("bn254.zig") // Pure Zig implementation for WASM (limited)
else
    @import("bn254_rust_wrapper.zig"); // Rust implementation for native

/// Calculate gas cost for ECPAIRING based on chain rules and number of pairs
///
/// Gas costs changed with EIP-1108 (Istanbul hardfork) to make pairing operations
/// more affordable for zkSNARK applications.
///
/// @param num_pairs Number of (G1, G2) pairs to process
/// @param chain_rules Current chain configuration
/// @return Gas cost for ECPAIRING operation
pub fn calculate_gas(num_pairs: usize, chain_rules: ChainRules) u64 {
    if (chain_rules.is_istanbul) {
        @branchHint(.likely);
        return GasConstants.ECPAIRING_BASE_GAS_COST +
            GasConstants.ECPAIRING_PER_PAIR_GAS_COST * @as(u64, @intCast(num_pairs));
    } else {
        @branchHint(.cold);
        return GasConstants.ECPAIRING_BASE_GAS_COST_BYZANTIUM +
            GasConstants.ECPAIRING_PER_PAIR_GAS_COST_BYZANTIUM * @as(u64, @intCast(num_pairs));
    }
}

/// Calculate gas cost with overflow protection (for precompile dispatcher)
///
/// @param input_size Size of input data in bytes
/// @return Gas cost for ECPAIRING operation or error if invalid
pub fn calculate_gas_checked(input_size: usize) !u64 {
    // Input must be multiple of 192 bytes (each pair is 192 bytes)
    if (input_size % 192 != 0) {
        return error.InvalidInputSize;
    }

    const num_pairs = input_size / 192;

    // Check for overflow in gas calculation
    const max_pairs = (std.math.maxInt(u64) - GasConstants.ECPAIRING_BASE_GAS_COST) /
        GasConstants.ECPAIRING_PER_PAIR_GAS_COST;

    if (num_pairs > max_pairs) {
        return error.GasOverflow;
    }

    // Return Istanbul gas cost as default (most common case)
    return GasConstants.ECPAIRING_BASE_GAS_COST +
        GasConstants.ECPAIRING_PER_PAIR_GAS_COST * @as(u64, @intCast(num_pairs));
}

/// Execute ECPAIRING precompile
///
/// This is the main entry point for ECPAIRING execution. It performs:
/// 1. Input validation (length must be multiple of 192)
/// 2. Gas cost calculation and validation
/// 3. Point parsing and validation
/// 4. Multi-pairing computation
/// 5. Result formatting
///
/// @param input Input data (must be multiple of 192 bytes)
/// @param output Output buffer (must be >= 32 bytes)
/// @param gas_limit Maximum gas available
/// @param chain_rules Current chain configuration
/// @return PrecompileOutput with success/failure and gas usage
pub fn execute(input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
    // Validate output buffer size
    if (ec_validation.validate_output_buffer_size(output, 32)) |failure_result| {
        return failure_result;
    }

    // Validate input length (must be multiple of 192 bytes)
    if (ec_validation.validate_input_size_multiple(input.len, 192)) |failure_result| {
        return failure_result;
    }

    const num_pairs = input.len / 192;

    // Calculate and validate gas cost
    const gas_cost = calculate_gas(num_pairs, chain_rules);
    if (ec_validation.validate_gas_requirement(gas_cost, gas_limit)) |failure_result| {
        return failure_result;
    }

    if (builtin.target.cpu.arch == .wasm32) {
        // WASM builds: Use limited pure Zig implementation
        // TODO: Implement full pairing operations in pure Zig for WASM
        // For now, handle empty input correctly but fail on non-empty input
        if (num_pairs == 0) {
            // Empty input should return true (identity pairing)
            @memset(output[0..32], 0);
            output[31] = 1;
        } else {
            // Non-empty input: return false (pairing fails)
            @memset(output[0..32], 0);
            log.warn("ECPAIRING in WASM build: using placeholder implementation (non-empty input returns false)", .{});
        }
    } else {
        // Use Rust implementation for native targets
        // Ensure BN254 Rust library is initialized
        bn254_backend.init() catch {
            @branchHint(.cold);
            return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
        };

        // Perform elliptic curve pairing check using Rust BN254 library
        bn254_backend.ecpairing(input, output[0..32]) catch {
            @branchHint(.cold);
            return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
        };
    }

    return PrecompileOutput.success_result(gas_cost, 32);
}

/// Get expected output size for ECPAIRING
///
/// ECPAIRING always produces 32 bytes of output.
///
/// @param input_size Size of input data (unused)
/// @return Fixed output size of 32 bytes
pub fn get_output_size(input_size: usize) usize {
    _ = input_size; // Output size is fixed regardless of input
    return 32;
}

/// Validate gas requirement without executing
///
/// Checks if an ECPAIRING call would succeed with the given gas limit.
///
/// @param input_size Size of input data
/// @param gas_limit Available gas limit
/// @param chain_rules Current chain configuration
/// @return true if operation would succeed
pub fn validate_gas_requirement(input_size: usize, gas_limit: u64, chain_rules: ChainRules) bool {
    // Input must be multiple of 192 bytes
    if (input_size % 192 != 0) {
        return false;
    }

    const num_pairs = input_size / 192;
    const gas_cost = calculate_gas(num_pairs, chain_rules);
    return gas_cost <= gas_limit;
}

// Tests
const testing = std.testing;

test "ECPAIRING empty input" {
    // Create chain rules for Istanbul hardfork
    const chain_rules = ChainRules.for_hardfork(.ISTANBUL);

    // Test empty input (k=0) - should return true
    const input: []const u8 = &[_]u8{};
    var output = [_]u8{0} ** 32;

    const result = execute(input, &output, 50000, chain_rules);
    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, 45000), result.get_gas_used()); // Base cost only
    try testing.expectEqual(@as(usize, 32), result.get_output_size());

    // Result should be true (0x0000...0001)
    for (output[0..31]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
    try testing.expectEqual(@as(u8, 1), output[31]);
}

test "ECPAIRING single pair - identity pairing" {
    const chain_rules = ChainRules.for_hardfork(.ISTANBUL);

    // Test single pair with point at infinity (should result in identity pairing)
    var input = [_]u8{0} ** 192; // G1 = O, G2 = O
    var output = [_]u8{0} ** 32;

    const gas_needed = 45000 + 34000; // Base + 1 pair
    const result = execute(&input, &output, gas_needed, chain_rules);

    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, gas_needed), result.get_gas_used());

    // e(O, O) = 1, so result should be true
    for (output[0..31]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
    try testing.expectEqual(@as(u8, 1), output[31]);
}

test "ECPAIRING invalid input length" {
    const chain_rules = ChainRules.for_hardfork(.ISTANBUL);

    // Test with invalid input length (not multiple of 192)
    var input = [_]u8{0} ** 100; // Invalid length
    var output = [_]u8{0} ** 32;

    const result = execute(&input, &output, 100000, chain_rules);

    try testing.expect(result.is_failure());
    try testing.expectEqual(PrecompileError.ExecutionFailed, result.get_error().?);
}

test "ECPAIRING gas calculation" {
    // Test gas calculation for different numbers of pairs

    // Byzantium costs
    const byzantium_rules = ChainRules.for_hardfork(.BYZANTIUM);
    try testing.expectEqual(@as(u64, 100000), calculate_gas(0, byzantium_rules)); // Empty
    try testing.expectEqual(@as(u64, 180000), calculate_gas(1, byzantium_rules)); // 1 pair
    try testing.expectEqual(@as(u64, 260000), calculate_gas(2, byzantium_rules)); // 2 pairs

    // Istanbul costs (reduced)
    const istanbul_rules = ChainRules.for_hardfork(.ISTANBUL);
    try testing.expectEqual(@as(u64, 45000), calculate_gas(0, istanbul_rules)); // Empty
    try testing.expectEqual(@as(u64, 79000), calculate_gas(1, istanbul_rules)); // 1 pair
    try testing.expectEqual(@as(u64, 113000), calculate_gas(2, istanbul_rules)); // 2 pairs
}

test "ECPAIRING gas checked calculation" {
    // Test input size validation
    try testing.expectError(error.InvalidInputSize, calculate_gas_checked(100)); // Not multiple of 192
    try testing.expectError(error.InvalidInputSize, calculate_gas_checked(191)); // Just under 192

    // Test valid sizes
    try testing.expectEqual(@as(u64, 45000), try calculate_gas_checked(0)); // Empty
    try testing.expectEqual(@as(u64, 79000), try calculate_gas_checked(192)); // 1 pair
    try testing.expectEqual(@as(u64, 113000), try calculate_gas_checked(384)); // 2 pairs
}

test "ECPAIRING out of gas" {
    const chain_rules = ChainRules.for_hardfork(.ISTANBUL);

    var input = [_]u8{0} ** 192; // 1 pair
    var output = [_]u8{0} ** 32;

    // Provide insufficient gas
    const result = execute(&input, &output, 50000, chain_rules); // Need 79000

    try testing.expect(result.is_failure());
    try testing.expectEqual(PrecompileError.OutOfGas, result.get_error().?);
}

test "ECPAIRING validate gas requirement" {
    const chain_rules = ChainRules.for_hardfork(.ISTANBUL);

    // Test validation function
    try testing.expect(validate_gas_requirement(0, 45000, chain_rules)); // Empty input
    try testing.expect(validate_gas_requirement(192, 79000, chain_rules)); // 1 pair
    try testing.expect(!validate_gas_requirement(192, 70000, chain_rules)); // Insufficient gas
    try testing.expect(!validate_gas_requirement(100, 100000, chain_rules)); // Invalid input size
}
