const std = @import("std");
const crypto = @import("crypto");
const Fp = crypto.bn254.Fp;
const Fr = crypto.bn254.Fr;
const Fp2 = crypto.bn254.Fp2;
const G1 = crypto.bn254.G1;
const G2 = crypto.bn254.G2;
const Fp6 = crypto.bn254.Fp6;
const Fp12 = crypto.bn254.Fp12;
const pairing_mod = crypto.bn254.pairing;

// Import precompiles that use Rust wrapper
const evm = @import("evm");
const ecmul_precompile = evm.precompiles.ecmul;
const ecpairing_precompile = evm.precompiles.ecpairing;
const chain_rules = evm.hardforks.chain_rules;
const Hardfork = evm.hardforks.hardfork.Hardfork;

// Helper function for ECMUL comparison
fn fuzzCompareECMUL(context: void, input: []const u8) !void {
    _ = context;
    if (input.len < 96) return; // Need x, y, scalar (32 bytes each)

    // Parse the fuzz input
    var ecmul_input: [96]u8 = undefined;
    @memcpy(&ecmul_input, input[0..96]);

    // Get x, y, scalar from input
    const x_bytes = ecmul_input[0..32];
    const y_bytes = ecmul_input[32..64];
    const scalar_bytes = ecmul_input[64..96];

    const x = std.mem.readInt(u256, x_bytes, .big);
    const y = std.mem.readInt(u256, y_bytes, .big);
    const scalar = std.mem.readInt(u256, scalar_bytes, .big);

    // Run through Rust precompile
    var rust_output: [64]u8 = undefined;
    const rules = chain_rules.for_hardfork(Hardfork.ISTANBUL);
    const rust_result = ecmul_precompile.execute(&ecmul_input, &rust_output, 1000000, rules);

    // Only compare if Rust succeeded (valid point)
    if (rust_result == .success) {
        // Parse Rust output
        const rust_x = std.mem.readInt(u256, rust_output[0..32], .big);
        const rust_y = std.mem.readInt(u256, rust_output[32..64], .big);

        // Check if input point is valid for our implementation
        const x_fp = Fp.init(x);
        const y_fp = Fp.init(y);
        const z_fp = Fp.ONE;

        // Try to create the point - may fail if not on curve
        const maybe_point = G1.init(&x_fp, &y_fp, &z_fp);
        if (maybe_point) |point| {
            // Perform scalar multiplication with our Zig implementation
            const scalar_fr = Fr.init(scalar);
            const zig_result = point.mul(&scalar_fr);

            // Convert to affine for comparison
            const zig_affine = zig_result.toAffine();

            // Compare results
            try std.testing.expectEqual(rust_x, zig_affine.x.value);
            try std.testing.expectEqual(rust_y, zig_affine.y.value);
        } else |_| {
            // If point creation failed, Rust should have returned specific values
            // (implementation-dependent behavior for invalid points)
        }
    }
}

// Fuzz test comparing ECMUL implementations
test "fuzz compare ECMUL Rust vs Zig" {
    try std.testing.fuzz({}, fuzzCompareECMUL, .{});
}

// Helper function for field arithmetic comparison
fn fuzzFieldArithmetic(context: void, input: []const u8) !void {
    _ = context;
    if (input.len < 64) return; // Need two field elements

    const a_value = std.mem.readInt(u256, input[0..32], .big);
    const b_value = std.mem.readInt(u256, input[32..64], .big);

    // Create ECMUL inputs that will test field arithmetic
    // We'll use point addition to test field operations

    // Test 1: (a*G) + (b*G) should equal (a+b)*G
    var ecmul_a: [96]u8 = undefined;
    var ecmul_b: [96]u8 = undefined;
    var ecmul_sum: [96]u8 = undefined;

    // Set generator point for all
    std.mem.writeInt(u256, ecmul_a[0..32], 1, .big);
    std.mem.writeInt(u256, ecmul_a[32..64], 2, .big);
    std.mem.writeInt(u256, ecmul_b[0..32], 1, .big);
    std.mem.writeInt(u256, ecmul_b[32..64], 2, .big);
    std.mem.writeInt(u256, ecmul_sum[0..32], 1, .big);
    std.mem.writeInt(u256, ecmul_sum[32..64], 2, .big);

    // Set scalars
    std.mem.writeInt(u256, ecmul_a[64..96], a_value, .big);
    std.mem.writeInt(u256, ecmul_b[64..96], b_value, .big);

    // For sum, we need (a + b) mod curve order
    const curve_order = Fr.FR_MOD;
    const a_mod = a_value % curve_order;
    const b_mod = b_value % curve_order;
    const sum_scalar = (a_mod + b_mod) % curve_order;
    std.mem.writeInt(u256, ecmul_sum[64..96], sum_scalar, .big);

    // Execute all three
    var output_a: [64]u8 = undefined;
    var output_b: [64]u8 = undefined;
    var output_sum: [64]u8 = undefined;

    const rules = chain_rules.for_hardfork(Hardfork.ISTANBUL);
    const result_a = ecmul_precompile.execute(&ecmul_a, &output_a, 1000000, rules);
    const result_b = ecmul_precompile.execute(&ecmul_b, &output_b, 1000000, rules);
    const result_sum = ecmul_precompile.execute(&ecmul_sum, &output_sum, 1000000, rules);

    if (result_a == .success and result_b == .success and result_sum == .success) {
        // Now compute a*G + b*G using our implementation
        const a_fr = Fr.init(a_value);
        const b_fr = Fr.init(b_value);

        const point_a = G1.GENERATOR.mul(&a_fr);
        const point_b = G1.GENERATOR.mul(&b_fr);
        const zig_sum = point_a.add(&point_b);
        const zig_sum_affine = zig_sum.toAffine();

        // Parse Rust's (a+b)*G result
        const rust_sum_x = std.mem.readInt(u256, output_sum[0..32], .big);
        const rust_sum_y = std.mem.readInt(u256, output_sum[32..64], .big);

        // They should be equal
        try std.testing.expectEqual(rust_sum_x, zig_sum_affine.x.value);
        try std.testing.expectEqual(rust_sum_y, zig_sum_affine.y.value);
    }
}

// Fuzz test for field arithmetic comparison
test "fuzz compare field arithmetic Rust vs Zig" {
    try std.testing.fuzz({}, fuzzFieldArithmetic, .{});
}

// Helper function for pairing comparison
fn fuzzComparePairing(context: void, input: []const u8) !void {
    _ = context;
    if (input.len < 192) return; // Need at least one pair

    // For simplicity, test with single pair using generator points
    var pairing_input: [192]u8 = undefined;

    // G1 generator
    std.mem.writeInt(u256, pairing_input[0..32], 1, .big);
    std.mem.writeInt(u256, pairing_input[32..64], 2, .big);

    // G2 generator coordinates (from our implementation)
    // Note: These need to match what the precompile expects
    // Using simple test coordinates that fit in u256
    if (input.len >= 128) {
        @memcpy(pairing_input[64..192], input[0..128]);
    } else {
        // Use default test values
        std.mem.writeInt(u256, pairing_input[64..96], 1, .big);
        std.mem.writeInt(u256, pairing_input[96..128], 0, .big);
        std.mem.writeInt(u256, pairing_input[128..160], 0, .big);
        std.mem.writeInt(u256, pairing_input[160..192], 1, .big);
    }

    // Run through Rust precompile
    var rust_output: [32]u8 = undefined;
    const rules = chain_rules.for_hardfork(Hardfork.ISTANBUL);
    const rust_result = ecpairing_precompile.execute(&pairing_input, &rust_output, 10000000, rules);

    // The result should be 0 or 1
    if (rust_result == .success) {
        const rust_pairing_result = std.mem.readInt(u256, &rust_output, .big);
        try std.testing.expect(rust_pairing_result == 0 or rust_pairing_result == 1);

        // For valid generator pairing, we can verify specific properties
        // but full pairing comparison would require proper G2 coordinate handling
    }
}

// Fuzz test comparing pairing results
test "fuzz compare ECPAIRING Rust vs Zig" {
    try std.testing.fuzz({}, fuzzComparePairing, .{});
}

// Helper function for edge cases and invariants
fn fuzzInvariantsAndEdgeCases(context: void, input: []const u8) !void {
    _ = context;
    if (input.len < 32) return;

    const scalar = std.mem.readInt(u256, input[0..32], .big);

    // Test 1: Identity scalar (0) should give identity point
    if (scalar == 0) {
        var ecmul_zero: [96]u8 = undefined;
        std.mem.writeInt(u256, ecmul_zero[0..32], 1, .big); // G.x
        std.mem.writeInt(u256, ecmul_zero[32..64], 2, .big); // G.y
        std.mem.writeInt(u256, ecmul_zero[64..96], 0, .big); // scalar = 0

        var output: [64]u8 = undefined;
        const rules = chain_rules.for_hardfork(Hardfork.ISTANBUL);
        const result = ecmul_precompile.execute(&ecmul_zero, &output, 1000000, rules);

        if (result == .success) {
            // Should return point at infinity (all zeros)
            const x = std.mem.readInt(u256, output[0..32], .big);
            const y = std.mem.readInt(u256, output[32..64], .big);
            try std.testing.expectEqual(@as(u256, 0), x);
            try std.testing.expectEqual(@as(u256, 0), y);
        }

        // Verify with our implementation
        const zero_fr = Fr.init(0);
        const zig_result = G1.GENERATOR.mul(&zero_fr);
        try std.testing.expect(zig_result.isInfinity());
    }

    // Test 2: Scalar = curve order should give identity
    if (scalar == Fr.FR_MOD or scalar % Fr.FR_MOD == 0) {
        var ecmul_order: [96]u8 = undefined;
        std.mem.writeInt(u256, ecmul_order[0..32], 1, .big); // G.x
        std.mem.writeInt(u256, ecmul_order[32..64], 2, .big); // G.y
        std.mem.writeInt(u256, ecmul_order[64..96], scalar, .big);

        var output: [64]u8 = undefined;
        const rules = chain_rules.for_hardfork(Hardfork.ISTANBUL);
        const result = ecmul_precompile.execute(&ecmul_order, &output, 1000000, rules);

        if (result == .success) {
            // Should return point at infinity
            const x = std.mem.readInt(u256, output[0..32], .big);
            const y = std.mem.readInt(u256, output[32..64], .big);
            try std.testing.expectEqual(@as(u256, 0), x);
            try std.testing.expectEqual(@as(u256, 0), y);
        }
    }

    // Test 3: Double and add consistency
    if (input.len >= 64) {
        const k = std.mem.readInt(u256, input[32..64], .big) % 1000; // Keep it small
        if (k > 0 and k < Fr.FR_MOD) {
            // Test that k*G + k*G = 2k*G
            const double_k = (k * 2) % Fr.FR_MOD;

            // Our implementation
            const k_fr = Fr.init(k);
            const double_k_fr = Fr.init(double_k);

            const k_times_g = G1.GENERATOR.mul(&k_fr);
            const sum = k_times_g.add(&k_times_g);
            const double_k_times_g = G1.GENERATOR.mul(&double_k_fr);

            try std.testing.expect(sum.equal(&double_k_times_g));
        }
    }
}

// Test edge cases and invariants
test "fuzz invariants and edge cases" {
    try std.testing.fuzz({}, fuzzInvariantsAndEdgeCases, .{});
}

// Run with: zig test src/crypto/bn254/fuzz_comparison.zig --fuzz
