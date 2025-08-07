const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const primitives = @import("primitives");
const addresses = @import("precompile_addresses.zig");
const PrecompileOutput = @import("precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("precompile_result.zig").PrecompileError;
const ChainRules = @import("../frame.zig").ChainRules;

// Import all precompile modules
const ecrecover = @import("ecrecover.zig");
const sha256 = @import("sha256_optimized.zig");
const ripemd160 = @import("ripemd160_optimized.zig");
const identity = @import("identity.zig");
const modexp = @import("modexp.zig");
const ecadd = @import("ecadd.zig");
const ecmul = @import("ecmul.zig");
const ecpairing = @import("ecpairing.zig");
const blake2f = @import("blake2f.zig");
const kzg_point_evaluation = @import("kzg_point_evaluation.zig");
const uniform_wrappers = @import("uniform_wrappers.zig");

/// Compile-time flag to disable all precompiles
const no_precompiles = if (@hasDecl(build_options, "no_precompiles")) build_options.no_precompiles else false;

/// Uniform precompile function type (Issue #333)
/// All precompiles now use the same signature, simplifying dispatch
pub const PrecompileFn = *const fn (input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput;

/// Maximum number of precompiles (IDs 1-10)
const MAX_PRECOMPILES = 10;

/// Compile-time function table for O(1) precompile dispatch
/// Direct function pointers, no union overhead
const PRECOMPILE_TABLE = blk: {
    var table: [MAX_PRECOMPILES]?PrecompileFn = .{null} ** MAX_PRECOMPILES;
    
    // All precompiles now use uniform interface
    table[0] = &uniform_wrappers.ecrecover_uniform; // ID 1: ECRECOVER
    table[1] = &sha256.execute; // ID 2: SHA256 (optimized)
    table[2] = &ripemd160.execute; // ID 3: RIPEMD160 (optimized)
    table[3] = &uniform_wrappers.identity_uniform; // ID 4: IDENTITY
    table[4] = &uniform_wrappers.modexp_uniform; // ID 5: MODEXP
    table[5] = &ecadd.execute; // ID 6: ECADD (already has chain_rules)
    table[6] = &ecmul.execute; // ID 7: ECMUL (already has chain_rules)
    table[7] = &ecpairing.execute; // ID 8: ECPAIRING (already has chain_rules)
    table[8] = &uniform_wrappers.blake2f_uniform; // ID 9: BLAKE2F
    table[9] = &uniform_wrappers.kzg_point_evaluation_uniform; // ID 10: POINT_EVALUATION
    
    break :blk table;
};

/// Checks if the given address is a precompile address
pub fn is_precompile(address: primitives.Address.Address) bool {
    if (comptime no_precompiles) return false;
    return addresses.is_precompile(address);
}

/// Checks if a precompile is available in the given chain rules
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

/// Optimized precompile execution with uniform interface
/// Eliminates union dispatch overhead (Issue #333)
pub fn execute_precompile(address: primitives.Address.Address, input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
    // When precompiles are disabled, always fail
    if (comptime no_precompiles) {
        return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
    }
    
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
    if (precompile_id < 1 or precompile_id > MAX_PRECOMPILES) {
        @branchHint(.cold);
        return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
    }

    const fn_ptr = PRECOMPILE_TABLE[precompile_id - 1] orelse {
        @branchHint(.cold);
        return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
    };

    // Direct function call - no union dispatch overhead
    return fn_ptr(input, output, gas_limit, chain_rules);
}

/// Estimates the gas cost for a precompile call
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