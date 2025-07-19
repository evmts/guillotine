const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const primitives = @import("primitives");
const addresses = @import("precompile_addresses.zig");
const PrecompileOutput = @import("precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("precompile_result.zig").PrecompileError;
const ChainRules = @import("../hardforks/chain_rules.zig");

/// Compile-time flag to disable all precompiles
/// Set via build options: -Dno_precompiles=true
const no_precompiles = if (@hasDecl(build_options, "no_precompiles")) build_options.no_precompiles else false;

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
    // When precompiles are disabled, always fail
    if (comptime no_precompiles) {
        return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
    } else {
        // Check if this is a valid precompile address
        if (!is_precompile(address)) {
            return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
        }

        // Check if this precompile is available with the current chain rules
        if (!is_available(address, chain_rules)) {
            return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
        }

        const precompile_id = addresses.get_precompile_id(address);

        // Route to specific precompile implementation
        return switch (precompile_id) {
            4 => {
                const identity = @import("identity.zig");
                return identity.execute(input, output, gas_limit);
            }, // IDENTITY

            // Placeholder implementations for future precompiles
            1 => {
                const ecrecover = @import("ecrecover.zig");
                return ecrecover.execute(input, output, gas_limit);
            }, // ECRECOVER
            2 => {
                const sha256 = @import("sha256.zig");
                return sha256.execute(input, output, gas_limit);
            }, // SHA256
            3 => {
                const ripemd160 = @import("ripemd160.zig");
                return ripemd160.execute(input, output, gas_limit);
            }, // RIPEMD160
            5 => {
                const modexp = @import("modexp.zig");
                return modexp.execute(input, output, gas_limit);
            }, // MODEXP
            6 => {
                const ecadd = @import("ecadd.zig");
                return ecadd.execute(input, output, gas_limit, chain_rules);
            }, // ECADD
            7 => {
                const ecmul = @import("ecmul.zig");
                return ecmul.execute(input, output, gas_limit, chain_rules);
            }, // ECMUL
            8 => {
                const ecpairing = @import("ecpairing.zig");
                return ecpairing.execute(input, output, gas_limit, chain_rules);
            }, // ECPAIRING
            9 => {
                const blake2f = @import("blake2f.zig");
                return blake2f.execute(input, output, gas_limit);
            }, // BLAKE2F
            10 => {
                const kzg_point_evaluation = @import("kzg_point_evaluation.zig");
                return kzg_point_evaluation.execute(input, output, gas_limit);
            }, // POINT_EVALUATION

            else => {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            },
        };
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
        return error.InvalidPrecompile;
    }

    if (!is_available(address, chain_rules)) {
        return error.PrecompileNotAvailable;
    }

    const precompile_id = addresses.get_precompile_id(address);

    return switch (precompile_id) {
        4 => blk: {
            const identity = @import("identity.zig");
            break :blk identity.calculate_gas_checked(input_size);
        }, // IDENTITY

        // Placeholder gas calculations for future precompiles
        1 => blk: {
            const ecrecover = @import("ecrecover.zig");
            break :blk ecrecover.calculate_gas_checked(input_size);
        }, // ECRECOVER
        2 => blk: {
            const sha256 = @import("sha256.zig");
            break :blk sha256.calculate_gas_checked(input_size);
        }, // SHA256
        3 => blk: {
            const ripemd160 = @import("ripemd160.zig");
            break :blk ripemd160.calculate_gas_checked(input_size);
        }, // RIPEMD160
        5 => blk: {
            // MODEXP gas calculation requires parsing the input
            // For estimation, we return minimum gas
            const modexp = @import("modexp.zig");
            break :blk modexp.MODEXP_MIN_GAS;
        }, // MODEXP
        6 => blk: {
            const ecadd = @import("ecadd.zig");
            break :blk ecadd.calculate_gas_checked(input_size);
        }, // ECADD
        7 => blk: {
            const ecmul = @import("ecmul.zig");
            break :blk ecmul.calculate_gas_checked(input_size);
        }, // ECMUL
        8 => blk: {
            const ecpairing = @import("ecpairing.zig");
            break :blk ecpairing.calculate_gas_checked(input_size);
        }, // ECPAIRING
        9 => blk: {
            const blake2f = @import("blake2f.zig");
            break :blk blake2f.calculate_gas_checked(input_size);
        }, // BLAKE2F
        10 => blk: {
            const kzg_point_evaluation = @import("kzg_point_evaluation.zig");
            break :blk kzg_point_evaluation.calculate_gas_checked(input_size);
        }, // POINT_EVALUATION

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
        return error.InvalidPrecompile;
    }

    if (!is_available(address, chain_rules)) {
        return error.PrecompileNotAvailable;
    }

    const precompile_id = addresses.get_precompile_id(address);

    return switch (precompile_id) {
        4 => blk: {
            const identity = @import("identity.zig");
            break :blk identity.get_output_size(input_size);
        }, // IDENTITY

        // Placeholder output sizes for future precompiles
        1 => blk: {
            const ecrecover = @import("ecrecover.zig");
            break :blk ecrecover.get_output_size(input_size);
        }, // ECRECOVER
        2 => blk: {
            const sha256 = @import("sha256.zig");
            break :blk sha256.get_output_size(input_size);
        }, // SHA256
        3 => blk: {
            const ripemd160 = @import("ripemd160.zig");
            break :blk ripemd160.get_output_size(input_size);
        }, // RIPEMD160
        5 => blk: {
            // MODEXP output size depends on modulus length which requires parsing input
            // For size estimation, return a reasonable default
            break :blk 32;
        }, // MODEXP
        6 => 64, // ECADD - fixed 64 bytes (point)
        7 => 64, // ECMUL - fixed 64 bytes (point)
        8 => 32, // ECPAIRING - fixed 32 bytes (boolean result)
        9 => blk: {
            const blake2f = @import("blake2f.zig");
            break :blk blake2f.get_output_size(input_size);
        }, // BLAKE2F
        10 => blk: {
            const kzg_point_evaluation = @import("kzg_point_evaluation.zig");
            break :blk kzg_point_evaluation.get_output_size(input_size);
        }, // POINT_EVALUATION

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
        return false;
    }
    if (!is_available(address, chain_rules)) {
        return false;
    }

    const gas_cost = estimate_gas(address, input_size, chain_rules) catch {
        return false;
    };
    return gas_cost <= gas_limit;
}
