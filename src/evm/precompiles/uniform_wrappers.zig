/// Uniform interface wrappers for precompiles
///
/// This module provides wrapper functions that adapt existing precompiles
/// to the uniform interface required by the optimized dispatcher.
/// These wrappers allow gradual migration while maintaining compatibility.

const std = @import("std");
const PrecompileOutput = @import("precompile_result.zig").PrecompileOutput;
const ChainRules = @import("../hardforks/chain_rules.zig").ChainRules;

// Import precompile modules that need wrapping
const ecrecover = @import("ecrecover.zig");
const identity = @import("identity.zig");
const modexp = @import("modexp.zig");
const blake2f = @import("blake2f.zig");
const kzg_point_evaluation = @import("kzg_point_evaluation.zig");

/// Wrapper for ECRECOVER precompile
pub fn ecrecover_uniform(input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
    _ = chain_rules; // Not used by ECRECOVER
    return ecrecover.execute(input, output, gas_limit);
}

/// Wrapper for IDENTITY precompile
pub fn identity_uniform(input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
    _ = chain_rules; // Not used by IDENTITY
    return identity.execute(input, output, gas_limit);
}

/// Wrapper for MODEXP precompile
pub fn modexp_uniform(input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
    _ = chain_rules; // Not used by MODEXP
    return modexp.execute(input, output, gas_limit);
}

/// Wrapper for BLAKE2F precompile
pub fn blake2f_uniform(input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
    _ = chain_rules; // Not used by BLAKE2F
    return blake2f.execute(input, output, gas_limit);
}

/// Wrapper for KZG_POINT_EVALUATION precompile
pub fn kzg_point_evaluation_uniform(input: []const u8, output: []u8, gas_limit: u64, chain_rules: ChainRules) PrecompileOutput {
    _ = chain_rules; // Not used by KZG_POINT_EVALUATION
    return kzg_point_evaluation.execute(input, output, gas_limit);
}

// Tests
const testing = std.testing;

test "uniform wrappers maintain functionality" {
    const chain_rules = ChainRules.for_hardfork(.ISTANBUL);
    
    // Test IDENTITY wrapper
    {
        const input = "test data";
        var output: [32]u8 = undefined;
        const result = identity_uniform(input, &output, 1000, chain_rules);
        try testing.expect(result.is_success());
        try testing.expectEqualSlices(u8, input, output[0..input.len]);
    }
    
    // Test BLAKE2F wrapper (with minimal valid input)
    {
        // Minimal valid BLAKE2F input is 213 bytes
        var input: [213]u8 = undefined;
        @memset(&input, 0);
        input[0] = 1; // rounds = 1
        var output: [64]u8 = undefined;
        
        const result = blake2f_uniform(&input, &output, 1000, chain_rules);
        try testing.expect(result.is_success());
    }
}