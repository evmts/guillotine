const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const primitives = @import("primitives");
const addresses = @import("precompile_addresses.zig");
const PrecompileOutput = @import("precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("precompile_result.zig").PrecompileError;
const ChainRules = @import("../hardforks/chain_rules.zig");
const tracy = @import("../tracy_support.zig");

// Import all precompile modules
const ecrecover = @import("ecrecover.zig");
const sha256 = @import("sha256.zig");
const ripemd160 = @import("ripemd160.zig");
const identity = @import("identity.zig");
const modexp = @import("modexp.zig");
const ecadd = @import("ecadd.zig");
const ecmul = @import("ecmul.zig");
const ecpairing = @import("ecpairing.zig");
const blake2f = @import("blake2f.zig");
const kzg_point_evaluation = @import("kzg_point_evaluation.zig");

/// Compile-time flag to disable all precompiles
/// Set via build options: -Dno_precompiles=true
const no_precompiles = if (@hasDecl(build_options, "no_precompiles")) build_options.no_precompiles else false;

/// Unified function type for all precompiles - all take chain_rules parameter
/// Even precompiles that don't use chain_rules accept it for uniform interface
const PrecompileFn = *const fn (input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput;

/// Wrapper functions for precompiles that originally didn't take chain_rules
/// These wrappers provide a uniform interface while ignoring the chain_rules parameter

const WrappedEcrecover = struct {
    pub fn execute(input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
        _ = chain_rules; // Ignore chain_rules parameter
        return ecrecover.execute(input, output, gas_limit);
    }
};

const WrappedSha256 = struct {
    pub fn execute(input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
        _ = chain_rules; // Ignore chain_rules parameter
        return sha256.execute(input, output, gas_limit);
    }
};

const WrappedRipemd160 = struct {
    pub fn execute(input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
        _ = chain_rules; // Ignore chain_rules parameter
        return ripemd160.execute(input, output, gas_limit);
    }
};

const WrappedIdentity = struct {
    pub fn execute(input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
        _ = chain_rules; // Ignore chain_rules parameter
        return identity.execute(input, output, gas_limit);
    }
};

const WrappedModexp = struct {
    pub fn execute(input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
        _ = chain_rules; // Ignore chain_rules parameter
        return modexp.execute(input, output, gas_limit);
    }
};

const WrappedBlake2f = struct {
    pub fn execute(input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
        _ = chain_rules; // Ignore chain_rules parameter
        return blake2f.execute(input, output, gas_limit);
    }
};

const WrappedKzgPointEvaluation = struct {
    pub fn execute(input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
        _ = chain_rules; // Ignore chain_rules parameter
        return kzg_point_evaluation.execute(input, output, gas_limit);
    }
};

/// Direct function pointer table for O(1) precompile dispatch
/// Index is (precompile_id - 1) since precompile IDs start at 1
/// All functions have uniform signature - no union needed!
const PRECOMPILE_TABLE = [_]?PrecompileFn{
    &WrappedEcrecover.execute,           // ID 1: ECRECOVER
    &WrappedSha256.execute,              // ID 2: SHA256
    &WrappedRipemd160.execute,           // ID 3: RIPEMD160
    &WrappedIdentity.execute,            // ID 4: IDENTITY
    &WrappedModexp.execute,              // ID 5: MODEXP
    &ecadd.execute,                      // ID 6: ECADD (already has correct signature)
    &ecmul.execute,                      // ID 7: ECMUL (already has correct signature)
    &ecpairing.execute,                  // ID 8: ECPAIRING (already has correct signature)
    &WrappedBlake2f.execute,             // ID 9: BLAKE2F
    &WrappedKzgPointEvaluation.execute,  // ID 10: POINT_EVALUATION
};

/// Main precompile dispatcher module
///
/// This module provides the main interface for precompile execution. It handles:
/// - primitives.Address.Address-based precompile detection and routing
/// - Hardfork-based availability checks
/// - Unified execution interface for all precompiles
/// - Error handling and result management
///
/// The dispatcher is designed to be easily extensible for future precompiles.
/// Adding a new precompile requires:
/// 1. Adding the address constant to precompile_addresses.zig
/// 2. Implementing the precompile logic in its own module
/// 3. Adding the dispatch case to execute_precompile()
/// 4. Adding availability check to is_available()
/// Checks if the given address is a precompile address
///
/// This function determines whether a given address corresponds to a known precompile.
/// It serves as the entry point for precompile detection during contract calls.
///
/// @param address The address to check
/// @return true if the address is a known precompile, false otherwise
pub fn is_precompile(address: primitives.Address.Address) bool {
    if (comptime no_precompiles) return false;
    return addresses.is_precompile(address);
}

/// Checks if a precompile is available in the given chain rules
///
/// Different precompiles were introduced in different hardforks. This function
/// ensures that precompiles are only available when they should be according
/// to the Ethereum specification.
///
/// @param address The precompile address to check
/// @param chain_rules The current chain rules configuration
/// @return true if the precompile is available with these chain rules
pub fn is_available(address: primitives.Address.Address, chain_rules: ChainRules) bool {
    if (!is_precompile(address)) {
        @branchHint(.cold);
        return false;
    }

    const precompile_id = addresses.get_precompile_id(address);

    return switch (precompile_id) {
        1, 2, 3, 4 => true, // ECRECOVER, SHA256, RIPEMD160, IDENTITY available from Frontier
        5 => chain_rules.is_byzantium, // MODEXP from Byzantium
        6, 7, 8 => chain_rules.is_byzantium, // ECADD, ECMUL, ECPAIRING from Byzantium
        9 => chain_rules.is_istanbul, // BLAKE2F from Istanbul
        10 => chain_rules.is_cancun, // POINT_EVALUATION from Cancun
        else => false,
    };
}

/// Executes a precompile with the given parameters
///
/// This is the main execution function that routes precompile calls to their
/// specific implementations. It handles:
/// - Precompile address validation
/// - Hardfork availability checks
/// - Routing to specific precompile implementations
/// - Consistent error handling
///
/// @param address The precompile address being called
/// @param input Input data for the precompile
/// @param output Output buffer to write results (must be large enough)
/// @param gas_limit Maximum gas available for execution
/// @param chain_rules Current chain rules for availability checking
/// @return PrecompileOutput containing success/failure and gas usage
pub fn execute_precompile(address: primitives.Address.Address, input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
    const zone = tracy.zone(@src(), "execute_precompile\x00");
    defer zone.end();
    
    // When precompiles are disabled, always fail
    if (comptime no_precompiles) {
        return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
    } else {
        // Check if this is a valid precompile address
        if (!is_precompile(address)) {
            @branchHint(.cold);
            return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
        }

        // Check if this precompile is available with the current chain rules
        if (!is_available(address, chain_rules)) {
            @branchHint(.cold);
            return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
        }

        const precompile_id = addresses.get_precompile_id(address);

        // Use table lookup for O(1) dispatch - no union switch needed!
        if (precompile_id < 1 or precompile_id > 10) {
            @branchHint(.cold);
            return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
        }

        const fn_ptr = PRECOMPILE_TABLE[precompile_id - 1] orelse {
            @branchHint(.cold);
            return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
        };

        // Direct dispatch - no switch statement needed!
        return fn_ptr(input, output, gas_limit, chain_rules);
    }
}

/// Estimates the gas cost for a precompile call
///
/// This function calculates the gas cost for a precompile call without actually
/// executing it. Useful for gas estimation and transaction validation.
///
/// @param address The precompile address
/// @param input_size Size of the input data
/// @param chain_rules Current chain rules
/// @return Estimated gas cost or error if not available
pub fn estimate_gas(address: primitives.Address.Address, input_size: usize, chain_rules: ChainRules) !u64 {
    // Early return if precompiles are disabled
    if (comptime no_precompiles) {
        return error.InvalidPrecompile;
    }

    if (!is_precompile(address)) {
        @branchHint(.cold);
        return error.InvalidPrecompile;
    }

    if (!is_available(address, chain_rules)) {
        @branchHint(.cold);
        return error.PrecompileNotAvailable;
    }

    const precompile_id = addresses.get_precompile_id(address);

    return switch (precompile_id) {
        1 => ecrecover.calculate_gas_checked(input_size),
        2 => sha256.calculate_gas_checked(input_size),
        3 => ripemd160.calculate_gas_checked(input_size),
        4 => identity.calculate_gas_checked(input_size),
        5 => modexp.MODEXP_MIN_GAS, // MODEXP gas calculation requires parsing the input
        6 => ecadd.calculate_gas_checked(input_size),
        7 => ecmul.calculate_gas_checked(input_size),
        8 => ecpairing.calculate_gas_checked(input_size),
        9 => blake2f.calculate_gas_checked(input_size),
        10 => kzg_point_evaluation.calculate_gas_checked(input_size),
        else => error.InvalidPrecompile,
    };
}

/// Gets the expected output size for a precompile call
///
/// Some precompiles have fixed output sizes, while others depend on the input.
/// This function provides a way to determine the required output buffer size.
///
/// @param address The precompile address
/// @param input_size Size of the input data
/// @param chain_rules Current chain rules
/// @return Expected output size or error if not available
pub fn get_output_size(address: primitives.Address.Address, input_size: usize, chain_rules: ChainRules) !usize {
    // Early return if precompiles are disabled
    if (comptime no_precompiles) {
        return error.InvalidPrecompile;
    }

    if (!is_precompile(address)) {
        @branchHint(.cold);
        return error.InvalidPrecompile;
    }

    if (!is_available(address, chain_rules)) {
        @branchHint(.cold);
        return error.PrecompileNotAvailable;
    }

    const precompile_id = addresses.get_precompile_id(address);

    return switch (precompile_id) {
        1 => ecrecover.get_output_size(input_size),
        2 => sha256.get_output_size(input_size),
        3 => ripemd160.get_output_size(input_size),
        4 => identity.get_output_size(input_size),
        5 => 32, // MODEXP output size depends on modulus length, return default
        6 => 64, // ECADD - fixed 64 bytes (point)
        7 => 64, // ECMUL - fixed 64 bytes (point)
        8 => 32, // ECPAIRING - fixed 32 bytes (boolean result)
        9 => blake2f.get_output_size(input_size),
        10 => kzg_point_evaluation.get_output_size(input_size),
        else => error.InvalidPrecompile,
    };
}

/// Validates that a precompile call would succeed
///
/// This function performs all validation checks without executing the precompile.
/// Useful for transaction validation and gas estimation.
///
/// @param address The precompile address
/// @param input_size Size of the input data
/// @param gas_limit Available gas limit
/// @param chain_rules Current chain rules
/// @return true if the call would succeed
pub fn validate_call(address: primitives.Address.Address, input_size: usize, gas_limit: u64, chain_rules: ChainRules) bool {
    if (!is_precompile(address)) {
        @branchHint(.cold);
        return false;
    }
    if (!is_available(address, chain_rules)) {
        @branchHint(.cold);
        return false;
    }

    const gas_cost = estimate_gas(address, input_size, chain_rules) catch {
        @branchHint(.cold);
        return false;
    };
    return gas_cost <= gas_limit;
}

// Tests for precompile dispatch mechanism
test "precompile dispatch correctness" {
    const testing = std.testing;
    
    // Create chain rules for testing
    const frontier_rules = ChainRules{
        .is_byzantium = false,
        .is_istanbul = false,
        .is_cancun = false,
    };
    
    const byzantium_rules = ChainRules{
        .is_byzantium = true,
        .is_istanbul = false,
        .is_cancun = false,
    };
    
    const istanbul_rules = ChainRules{
        .is_byzantium = true,
        .is_istanbul = true,
        .is_cancun = false,
    };
    
    const cancun_rules = ChainRules{
        .is_byzantium = true,
        .is_istanbul = true,
        .is_cancun = true,
    };
    
    // Test precompile availability by hardfork
    try testing.expect(is_available(addresses.ECRECOVER_ADDRESS, frontier_rules));
    try testing.expect(is_available(addresses.SHA256_ADDRESS, frontier_rules));
    try testing.expect(is_available(addresses.RIPEMD160_ADDRESS, frontier_rules));
    try testing.expect(is_available(addresses.IDENTITY_ADDRESS, frontier_rules));
    
    try testing.expect(!is_available(addresses.MODEXP_ADDRESS, frontier_rules));
    try testing.expect(is_available(addresses.MODEXP_ADDRESS, byzantium_rules));
    
    try testing.expect(!is_available(addresses.ECADD_ADDRESS, frontier_rules));
    try testing.expect(is_available(addresses.ECADD_ADDRESS, byzantium_rules));
    
    try testing.expect(!is_available(addresses.BLAKE2F_ADDRESS, byzantium_rules));
    try testing.expect(is_available(addresses.BLAKE2F_ADDRESS, istanbul_rules));
    
    try testing.expect(!is_available(addresses.POINT_EVALUATION_ADDRESS, istanbul_rules));
    try testing.expect(is_available(addresses.POINT_EVALUATION_ADDRESS, cancun_rules));
    
    // Test precompile execution for each precompile
    var output_buffer: [1024]u8 = undefined;
    
    // Test IDENTITY precompile (simplest case)
    const identity_input = "hello world";
    const identity_result = execute_precompile(
        addresses.IDENTITY_ADDRESS,
        identity_input,
        &output_buffer,
        1000,
        frontier_rules
    );
    try testing.expect(identity_result.success);
    try testing.expectEqualSlices(u8, identity_input, output_buffer[0..identity_input.len]);
    
    // Test ECRECOVER precompile with valid input
    const ecrecover_input = [_]u8{0} ** 128; // Zero input for simplicity
    const ecrecover_result = execute_precompile(
        addresses.ECRECOVER_ADDRESS,
        &ecrecover_input,
        &output_buffer,
        3000,
        frontier_rules
    );
    try testing.expect(ecrecover_result.success);
    
    // Test SHA256 precompile
    const sha256_input = "test";
    const sha256_result = execute_precompile(
        addresses.SHA256_ADDRESS,
        sha256_input,
        &output_buffer,
        1000,
        frontier_rules
    );
    try testing.expect(sha256_result.success);
    try testing.expectEqual(@as(usize, 32), sha256_result.output_len);
    
    // Test non-precompile address
    const non_precompile = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const non_precompile_result = execute_precompile(
        non_precompile,
        "test",
        &output_buffer,
        1000,
        frontier_rules
    );
    try testing.expect(!non_precompile_result.success);
    
    // Test unavailable precompile (MODEXP on Frontier)
    const unavailable_result = execute_precompile(
        addresses.MODEXP_ADDRESS,
        "test",
        &output_buffer,
        1000,
        frontier_rules
    );
    try testing.expect(!unavailable_result.success);
}

test "precompile gas estimation" {
    const testing = std.testing;
    
    const byzantium_rules = ChainRules{
        .is_byzantium = true,
        .is_istanbul = true,
        .is_cancun = true,
    };
    
    // Test gas estimation for each precompile
    const identity_gas = estimate_gas(addresses.IDENTITY_ADDRESS, 32, byzantium_rules) catch unreachable;
    try testing.expect(identity_gas > 0);
    
    const sha256_gas = estimate_gas(addresses.SHA256_ADDRESS, 32, byzantium_rules) catch unreachable;
    try testing.expect(sha256_gas > 0);
    
    const ecrecover_gas = estimate_gas(addresses.ECRECOVER_ADDRESS, 128, byzantium_rules) catch unreachable;
    try testing.expect(ecrecover_gas > 0);
    
    // Test invalid precompile
    const non_precompile = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const invalid_gas = estimate_gas(non_precompile, 32, byzantium_rules);
    try testing.expectError(error.InvalidPrecompile, invalid_gas);
}
