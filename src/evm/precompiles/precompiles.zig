const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const primitives = @import("primitives");
const addresses = @import("precompile_addresses.zig");
const PrecompileOutput = @import("precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("precompile_result.zig").PrecompileError;
const ChainRules = @import("../hardforks/chain_rules.zig").ChainRules;

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

/// Function type for precompiles that don't require chain rules
const PrecompileFn = *const fn (input: []const u8, output: []u8, gas_limit: u64) PrecompileOutput;

/// Function type for precompiles that require chain rules (EC operations)
const PrecompileFnWithChainRules = *const fn (input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput;

/// Unified precompile handler that wraps both function types
const PrecompileHandler = union(enum) {
    standard: PrecompileFn,
    with_chain_rules: PrecompileFnWithChainRules,
};

/// Compile-time function table for O(1) precompile dispatch
/// Index is (precompile_id - 1) since precompile IDs start at 1
const PRECOMPILE_TABLE = blk: {
    var table: [10]?PrecompileHandler = .{null} ** 10;

    // Standard precompiles (no chain rules)
    table[0] = PrecompileHandler{ .standard = &ecrecover.execute }; // ID 1: ECRECOVER
    table[1] = PrecompileHandler{ .standard = &sha256.execute }; // ID 2: SHA256
    table[2] = PrecompileHandler{ .standard = &ripemd160.execute }; // ID 3: RIPEMD160
    table[3] = PrecompileHandler{ .standard = &identity.execute }; // ID 4: IDENTITY
    table[4] = PrecompileHandler{ .standard = &modexp.execute }; // ID 5: MODEXP

    // EC precompiles (require chain rules)
    table[5] = PrecompileHandler{ .with_chain_rules = &ecadd.execute }; // ID 6: ECADD
    table[6] = PrecompileHandler{ .with_chain_rules = &ecmul.execute }; // ID 7: ECMUL
    table[7] = PrecompileHandler{ .with_chain_rules = &ecpairing.execute }; // ID 8: ECPAIRING

    // Standard precompiles
    table[8] = PrecompileHandler{ .standard = &blake2f.execute }; // ID 9: BLAKE2F
    table[9] = PrecompileHandler{ .standard = &kzg_point_evaluation.execute }; // ID 10: POINT_EVALUATION

    break :blk table;
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

/// Checks if a precompile ID is available in the given chain rules
/// This variant accepts a precompile ID directly to avoid redundant address checks
///
/// @param precompile_id The precompile ID (1-10)
/// @param chain_rules The current chain rules configuration
/// @return true if the precompile is available with these chain rules
pub fn is_available_by_id(precompile_id: u8, chain_rules: ChainRules) bool {
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

        // Use table lookup for O(1) dispatch
        // After is_precompile check, we know id is valid (1-10)
        const handler = PRECOMPILE_TABLE[precompile_id - 1].?;

        // Dispatch based on handler type
        return switch (handler) {
            .standard => |fn_ptr| fn_ptr(input, output, gas_limit),
            .with_chain_rules => |fn_ptr| fn_ptr(input, output, gas_limit, chain_rules),
        };
    }
}

/// Executes a precompile given its ID directly
/// This variant avoids redundant address-to-ID conversions
///
/// @param precompile_id The precompile ID (1-10)
/// @param input Input data for the precompile
/// @param output Output buffer to write results (must be large enough)
/// @param gas_limit Maximum gas available for execution
/// @param chain_rules Current chain rules for availability checking
/// @return PrecompileOutput containing success/failure and gas usage
pub fn execute_precompile_by_id(precompile_id: u8, input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
    // When precompiles are disabled, always fail
    if (comptime no_precompiles) {
        return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
    }

    // Check if this precompile is available with the current chain rules
    if (!is_available_by_id(precompile_id, chain_rules)) {
        @branchHint(.cold);
        return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
    }

    // Use table lookup for O(1) dispatch
    // After is_available_by_id check, we know id is valid (1-10)
    const handler = PRECOMPILE_TABLE[precompile_id - 1].?;

    // Dispatch based on handler type
    return switch (handler) {
        .standard => |fn_ptr| fn_ptr(input, output, gas_limit),
        .with_chain_rules => |fn_ptr| fn_ptr(input, output, gas_limit, chain_rules),
    };
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

/// Gets the expected output size for a precompile given its ID
/// This variant avoids redundant address-to-ID conversions
///
/// @param precompile_id The precompile ID (1-10)
/// @param input_size Size of the input data
/// @param chain_rules Current chain rules
/// @return Expected output size or error
pub fn get_output_size_by_id(precompile_id: u8, input_size: usize, chain_rules: ChainRules) !usize {
    // Early return if precompiles are disabled
    if (comptime no_precompiles) {
        return error.InvalidPrecompile;
    }

    if (!is_available_by_id(precompile_id, chain_rules)) {
        @branchHint(.cold);
        return error.PrecompileNotAvailable;
    }

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

/// Checks if a precompile has a fixed output size
///
/// Some precompiles always return the same size output regardless of input,
/// making them suitable for stack allocation optimization.
///
/// @param precompile_id The precompile ID (1-10)
/// @return true if the precompile has a fixed output size
pub fn has_fixed_output_size(precompile_id: u8) bool {
    return switch (precompile_id) {
        1 => true, // ECRECOVER - always 32 bytes
        2 => true, // SHA256 - always 32 bytes
        3 => true, // RIPEMD160 - always 32 bytes (padded to 32)
        4 => false, // IDENTITY - output size matches input
        5 => false, // MODEXP - output size depends on modulus
        6 => true, // ECADD - always 64 bytes
        7 => true, // ECMUL - always 64 bytes
        8 => true, // ECPAIRING - always 32 bytes
        9 => true, // BLAKE2F - always 64 bytes
        10 => true, // KZG_POINT_EVALUATION - always 64 bytes
        else => false,
    };
}

/// Gets the fixed output size for precompiles that have one
///
/// This should only be called for precompiles where has_fixed_output_size returns true.
///
/// @param precompile_id The precompile ID (1-10)
/// @return The fixed output size in bytes
pub fn get_fixed_output_size(precompile_id: u8) usize {
    return switch (precompile_id) {
        1 => 32, // ECRECOVER
        2 => 32, // SHA256
        3 => 32, // RIPEMD160 (padded to 32)
        6 => 64, // ECADD
        7 => 64, // ECMUL
        8 => 32, // ECPAIRING
        9 => 64, // BLAKE2F
        10 => 64, // KZG_POINT_EVALUATION
        else => unreachable, // Should only be called for fixed-size precompiles
    };
}
