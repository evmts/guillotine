const std = @import("std");
const FpMont = @import("FpMont.zig");
const Fr = @import("Fr.zig");
const Fp2Mont = @import("Fp2Mont.zig");
const G1 = @import("G1.zig");
const G2 = @import("G2.zig");
const Fp6Mont = @import("Fp6Mont.zig");
const Fp12Mont = @import("Fp12Mont.zig");
const pairing_mod = @import("pairing.zig");

// Fuzz tests for field operations
test "fuzz Fp arithmetic operations" {
    const input = std.testing.fuzzInput(.{});
    if (input.len < 64) return; // Need at least 2 u256 values

    // Parse two u256 values from fuzz input
    const a_bytes = input[0..32];
    const b_bytes = input[32..64];

    const a_value = std.mem.readInt(u256, a_bytes, .big);
    const b_value = std.mem.readInt(u256, b_bytes, .big);

    const a = FpMont.init(a_value);
    const b = FpMont.init(b_value);

    // Test addition commutativity
    const sum1 = a.add(&b);
    const sum2 = b.add(&a);
    try std.testing.expect(sum1.equal(&sum2));

    // Test multiplication commutativity
    const prod1 = a.mul(&b);
    const prod2 = b.mul(&a);
    try std.testing.expect(prod1.equal(&prod2));

    // Test that a * a^-1 = 1 (when a != 0)
    if (a.value != 0) {
        const a_inv = a.inv();
        const should_be_one = a.mul(&a_inv);
        try std.testing.expect(should_be_one.equal(&FpMont.ONE));
    }

    // Test distributive property: a * (b + c) = a*b + a*c
    if (input.len >= 96) {
        const c_bytes = input[64..96];
        const c_value = std.mem.readInt(u256, c_bytes, .big);
        const c = FpMont.init(c_value);

        const left = a.mul(&b.add(&c));
        const right = a.mul(&b).add(&a.mul(&c));
        try std.testing.expect(left.equal(&right));
    }
}

test "fuzz Fp2 arithmetic operations" {
    const input = std.testing.fuzzInput(.{});
    if (input.len < 128) return; // Need at least 4 u256 values

    // Parse four u256 values from fuzz input
    const a0 = std.mem.readInt(u256, input[0..32], .big);
    const a1 = std.mem.readInt(u256, input[32..64], .big);
    const b0 = std.mem.readInt(u256, input[64..96], .big);
    const b1 = std.mem.readInt(u256, input[96..128], .big);

    const a = Fp2Mont.init_from_int(a0, a1);
    const b = Fp2Mont.init_from_int(b0, b1);

    // Test addition commutativity
    const sum1 = a.add(&b);
    const sum2 = b.add(&a);
    try std.testing.expect(sum1.equal(&sum2));

    // Test multiplication commutativity
    const prod1 = a.mul(&b);
    const prod2 = b.mul(&a);
    try std.testing.expect(prod1.equal(&prod2));

    // Test that a * a^-1 = 1 (when a != 0)
    if (!a.equal(&Fp2Mont.ZERO)) {
        const a_inv = a.inv();
        const should_be_one = a.mul(&a_inv);
        try std.testing.expect(should_be_one.equal(&Fp2Mont.ONE));
    }
}

test "fuzz G1 point operations" {
    const input = std.testing.fuzzInput(.{});
    if (input.len < 32) return; // Need at least one scalar

    const scalar_bytes = input[0..32];
    const scalar_value = std.mem.readInt(u256, scalar_bytes, .big);
    const scalar = Fr.init(scalar_value);

    // Test scalar multiplication
    const point = G1.GENERATOR.mul(&scalar);

    // Verify the result is still on the curve
    try std.testing.expect(point.isOnCurve());

    // Test that 0 * P = O (identity)
    const zero_scalar = Fr.init(0);
    const should_be_identity = G1.GENERATOR.mul(&zero_scalar);
    try std.testing.expect(should_be_identity.isInfinity());

    // Test addition with identity
    const sum = point.add(&G1.INFINITY);
    try std.testing.expect(sum.equal(&point));
}

test "fuzz G2 point operations" {
    const input = std.testing.fuzzInput(.{});
    if (input.len < 32) return; // Need at least one scalar

    const scalar_bytes = input[0..32];
    const scalar_value = std.mem.readInt(u256, scalar_bytes, .big);
    const scalar = Fr.init(scalar_value);

    // Test scalar multiplication
    const point = G2.GENERATOR.mul(&scalar);

    // Verify the result is still on the curve
    try std.testing.expect(point.isOnCurve());

    // Test that 0 * P = O (identity)
    const zero_scalar = Fr.init(0);
    const should_be_identity = G2.GENERATOR.mul(&zero_scalar);
    try std.testing.expect(should_be_identity.isInfinity());

    // Test addition with identity
    const sum = point.add(&G2.INFINITY);
    try std.testing.expect(sum.equal(&point));
}

test "fuzz pairing bilinearity" {
    const input = std.testing.fuzzInput(.{});
    if (input.len < 64) return; // Need at least two scalars

    const a_bytes = input[0..32];
    const b_bytes = input[32..64];

    const a_value = std.mem.readInt(u256, a_bytes, .big);
    const b_value = std.mem.readInt(u256, b_bytes, .big);

    // Avoid zero scalars for this test
    if (a_value == 0 or b_value == 0) return;

    const a = Fr.init(a_value % Fr.FR_MOD);
    const b = Fr.init(b_value % Fr.FR_MOD);

    // Test bilinearity: e(aP, bQ) = e(P, Q)^(ab)
    const P = G1.GENERATOR;
    const Q = G2.GENERATOR;

    const aP = P.mul(&a);
    const bQ = Q.mul(&b);

    // e(aP, bQ)
    const left = pairing_mod.pairing(&aP, &bQ);

    // e(P, Q)^(ab)
    const ab = a.mul(&b);
    const e_PQ = pairing_mod.pairing(&P, &Q);
    const right = e_PQ.pow(ab.value);

    try std.testing.expect(left.equal(&right));
}

test "fuzz field element edge cases" {
    const input = std.testing.fuzzInput(.{});
    if (input.len < 32) return;

    const value = std.mem.readInt(u256, input[0..32], .big);
    const fp = FpMont.init(value);

    // Test that init properly reduces modulo FP_MOD
    try std.testing.expect(fp.value < FpMont.FP_MOD);

    // Test double negation
    const neg_neg = fp.neg().neg();
    try std.testing.expect(neg_neg.equal(&fp));

    // Test that addition wraps correctly
    const almost_mod = FpMont.init(FpMont.FP_MOD - 1);
    const sum = almost_mod.add(&FpMont.ONE);
    try std.testing.expect(sum.equal(&FpMont.ZERO));
}

test "fuzz Fp6 and Fp12 operations" {
    const input = std.testing.fuzzInput(.{});
    if (input.len < 192) return; // Need 6 u256 values for Fp6

    // Parse six u256 values for Fp6
    const v0_real = std.mem.readInt(u256, input[0..32], .big);
    const v0_imag = std.mem.readInt(u256, input[32..64], .big);
    const v1_real = std.mem.readInt(u256, input[64..96], .big);
    const v1_imag = std.mem.readInt(u256, input[96..128], .big);
    const v2_real = std.mem.readInt(u256, input[128..160], .big);
    const v2_imag = std.mem.readInt(u256, input[160..192], .big);

    const fp6 = Fp6Mont.init_from_int(v0_real, v0_imag, v1_real, v1_imag, v2_real, v2_imag);

    // Test that a * a^-1 = 1 (when a != 0)
    if (!fp6.equal(&Fp6Mont.ZERO)) {
        const inv = fp6.inv();
        const should_be_one = fp6.mul(&inv);
        try std.testing.expect(should_be_one.equal(&Fp6Mont.ONE));
    }

    // Test Frobenius map property: frob(a)^p = a
    const frob = fp6.frobeniusMap();
    const frob_p = frob.pow(FpMont.FP_MOD);
    try std.testing.expect(frob_p.equal(&fp6));
}

// Run fuzz tests with: zig test src/crypto/bn254/fuzz.zig --fuzz
