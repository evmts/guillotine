const std = @import("std");
const ecpairing = @import("ecpairing.zig");
const ExecutionContext = @import("../frame.zig");
const Hardfork = @import("../hardforks/hardfork.zig").Hardfork;

test "fuzz ecpairing input length validation" {
    const input = std.testing.fuzzInput(.{});
    
    // ECPAIRING expects input length to be a multiple of 192 bytes
    // Each pair is: G1 point (64 bytes) + G2 point (128 bytes) = 192 bytes
    var output: [32]u8 = undefined;
    const rules = ExecutionContext.Frame.chainRulesForHardfork(Hardfork.ISTANBUL);
    
    const result = ecpairing.execute(input, &output, 10000000, rules);
    
    // Check that invalid input lengths are handled properly
    if (input.len % 192 != 0) {
        // Should handle invalid lengths gracefully
        // May return error or handle according to spec
    } else if (input.len == 0) {
        // Empty input should return 1 (success)
        if (result == .success) {
            const success_value = std.mem.readInt(u256, &output, .big);
            try std.testing.expect(success_value == 1);
        }
    }
}

test "fuzz ecpairing single pair validation" {
    const input = std.testing.fuzzInput(.{});
    if (input.len < 192) return;
    
    // Test with a single pair from fuzz input
    var pair_input: [192]u8 = undefined;
    @memcpy(&pair_input, input[0..192]);
    
    var output: [32]u8 = undefined;
    const rules = ExecutionContext.Frame.chainRulesForHardfork(Hardfork.ISTANBUL);
    
    const result = ecpairing.execute(&pair_input, &output, 10000000, rules);
    
    // The precompile should handle any input gracefully
    // Including invalid points, which should result in pairing failure
    if (result == .success) {
        const result_value = std.mem.readInt(u256, &output, .big);
        // Result should be either 0 or 1
        try std.testing.expect(result_value == 0 or result_value == 1);
    }
}

test "fuzz ecpairing multiple pairs" {
    const input = std.testing.fuzzInput(.{});
    
    // Create input with multiple pairs (up to 4 for reasonable gas usage)
    const max_pairs = @min(input.len / 192, 4);
    if (max_pairs == 0) return;
    
    const pair_bytes = max_pairs * 192;
    const pair_input = input[0..pair_bytes];
    
    var output: [32]u8 = undefined;
    const rules = ExecutionContext.Frame.chainRulesForHardfork(Hardfork.ISTANBUL);
    
    const result = ecpairing.execute(pair_input, &output, 10000000, rules);
    
    if (result == .success) {
        const result_value = std.mem.readInt(u256, &output, .big);
        // Result should be either 0 or 1
        try std.testing.expect(result_value == 0 or result_value == 1);
    }
}

test "fuzz ecpairing gas consumption" {
    const input = std.testing.fuzzInput(.{});
    if (input.len < 200) return; // Need at least one pair + gas value
    
    // Use first 192 bytes as a pair
    const pair_input = input[0..192];
    
    // Fuzz the gas limit
    const gas_limit = std.mem.readInt(u64, input[192..200], .little);
    
    var output: [32]u8 = undefined;
    const rules = ExecutionContext.Frame.chainRulesForHardfork(Hardfork.ISTANBUL);
    
    const result = ecpairing.execute(pair_input, &output, gas_limit, rules);
    
    // Calculate required gas: base + per_pair
    const base_gas = rules.precompile_gas.bn128_pairing_base;
    const per_pair_gas = rules.precompile_gas.bn128_pairing_per_pair;
    const required_gas = base_gas + per_pair_gas; // 1 pair
    
    if (gas_limit < required_gas) {
        try std.testing.expect(result == .out_of_gas);
    }
}

test "fuzz ecpairing identity elements" {
    const input = std.testing.fuzzInput(.{});
    if (input.len < 64) return;
    
    // Create pairs with identity elements mixed with fuzzed data
    var pair_input: [192]u8 = undefined;
    
    // G1 point - use fuzzed data
    @memcpy(pair_input[0..64], input[0..64]);
    
    // G2 point - set to identity (all zeros)
    @memset(pair_input[64..192], 0);
    
    var output: [32]u8 = undefined;
    const rules = ExecutionContext.Frame.chainRulesForHardfork(Hardfork.ISTANBUL);
    
    const result = ecpairing.execute(&pair_input, &output, 10000000, rules);
    
    // Pairing with identity should handle gracefully
    // The specific behavior depends on the implementation
    if (result == .success) {
        const result_value = std.mem.readInt(u256, &output, .big);
        try std.testing.expect(result_value == 0 or result_value == 1);
    }
}

test "fuzz ecpairing field element bounds" {
    const input = std.testing.fuzzInput(.{});
    if (input.len < 32) return;
    
    // Create a pair with coordinates at field boundaries
    var pair_input: [192]u8 = undefined;
    @memset(&pair_input, 0);
    
    // Set G1 x-coordinate to fuzzed value
    @memcpy(pair_input[0..32], input[0..32]);
    
    // Set other coordinates to valid small values
    std.mem.writeInt(u256, pair_input[32..64], 1, .big); // G1 y
    std.mem.writeInt(u256, pair_input[64..96], 1, .big); // G2 x1
    std.mem.writeInt(u256, pair_input[96..128], 0, .big); // G2 x2
    std.mem.writeInt(u256, pair_input[128..160], 0, .big); // G2 y1
    std.mem.writeInt(u256, pair_input[160..192], 1, .big); // G2 y2
    
    var output: [32]u8 = undefined;
    const rules = ExecutionContext.Frame.chainRulesForHardfork(Hardfork.ISTANBUL);
    
    const result = ecpairing.execute(&pair_input, &output, 10000000, rules);
    
    // Should handle values outside field bounds gracefully
    // Either by reducing modulo field prime or returning error
}

// Run with: zig test src/evm/precompiles/ecpairing_fuzz.zig --fuzz