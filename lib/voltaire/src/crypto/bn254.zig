const std = @import("std");
const curve_parameters = @import("bn254/curve_parameters.zig");

pub const FpMont = @import("bn254/FpMont.zig");
pub const Fp2Mont = @import("bn254/Fp2Mont.zig");
pub const Fp6Mont = @import("bn254/Fp6Mont.zig");
pub const Fp12Mont = @import("bn254/Fp12Mont.zig");
pub const Fr = @import("bn254/Fr.zig").Fr;

pub const FP_MOD = curve_parameters.FP_MOD;
pub const FR_MOD = curve_parameters.FR_MOD;
pub const G1 = @import("bn254/G1.zig");
pub const G2 = @import("bn254/G2.zig");
pub const pairing = @import("bn254/pairing.zig").pairing;

// ============================================================================
// TESTS - BN254 Module-Level Integration Tests
// ============================================================================

test "BN254 G1 point addition on curve" {
    const gen = G1.GENERATOR;
    const doubled = gen.double();
    const sum = gen.add(&gen);
    try std.testing.expect(sum.equal(&doubled));
    try std.testing.expect(sum.isOnCurve());
}

test "BN254 G1 point doubling matches repeated addition" {
    const gen = G1.GENERATOR;
    const doubled = gen.double();
    const quadrupled_by_double = doubled.double();
    const quadrupled_by_add = gen.add(&gen).add(&gen).add(&gen);
    try std.testing.expect(quadrupled_by_double.equal(&quadrupled_by_add));
}

test "BN254 G1 scalar multiplication basic" {
    const gen = G1.GENERATOR;
    const scalar = Fr.init(5);
    const result = try gen.mul(&scalar);

    const manual = gen.add(&gen).add(&gen).add(&gen).add(&gen);
    try std.testing.expect(result.equal(&manual));
    try std.testing.expect(result.isOnCurve());
}

test "BN254 G1 scalar multiplication by zero" {
    const gen = G1.GENERATOR;
    const result = try gen.mulByInt(0);
    try std.testing.expect(result.isInfinity());
}

test "BN254 G1 scalar multiplication by one" {
    const gen = G1.GENERATOR;
    const result = try gen.mulByInt(1);
    try std.testing.expect(result.equal(&gen));
}

test "BN254 G1 scalar multiplication by curve order gives infinity" {
    const gen = G1.GENERATOR;
    const result = try gen.mulByInt(FR_MOD);
    try std.testing.expect(result.isInfinity());
}

test "BN254 G1 point validation rejects off-curve points" {
    // (1, 2) is the generator; (1, 3) is off the curve.
    const bad_x = FpMont.init(1);
    const bad_y = FpMont.init(3);
    const z = FpMont.ONE;

    const result = G1.init(&bad_x, &bad_y, &z);
    try std.testing.expectError(error.InvalidPoint, result);
}

test "BN254 G1 point at infinity operations" {
    const inf = G1.INFINITY;
    const gen = G1.GENERATOR;

    try std.testing.expect(inf.isInfinity());
    try std.testing.expect(inf.isOnCurve());

    const inf_plus_gen = inf.add(&gen);
    try std.testing.expect(inf_plus_gen.equal(&gen));

    const gen_plus_inf = gen.add(&inf);
    try std.testing.expect(gen_plus_inf.equal(&gen));

    const inf_doubled = inf.double();
    try std.testing.expect(inf_doubled.isInfinity());
}

test "BN254 G1 inverse points sum to infinity" {
    const gen = G1.GENERATOR;
    const neg_gen = gen.neg();
    const sum = gen.add(&neg_gen);
    try std.testing.expect(sum.isInfinity());
}

test "BN254 G1 associativity of addition" {
    const scalar1 = Fr.init(3);
    const scalar2 = Fr.init(5);
    const scalar3 = Fr.init(7);

    const p1 = try G1.GENERATOR.mul(&scalar1);
    const p2 = try G1.GENERATOR.mul(&scalar2);
    const p3 = try G1.GENERATOR.mul(&scalar3);

    const left = p1.add(&p2).add(&p3);
    const right = p1.add(&p2.add(&p3));
    try std.testing.expect(left.equal(&right));
}

test "BN254 G1 commutativity of addition" {
    const scalar1 = Fr.init(11);
    const scalar2 = Fr.init(13);

    const p1 = try G1.GENERATOR.mul(&scalar1);
    const p2 = try G1.GENERATOR.mul(&scalar2);

    const left = p1.add(&p2);
    const right = p2.add(&p1);
    try std.testing.expect(left.equal(&right));
}

test "BN254 G1 distributivity of scalar multiplication" {
    const scalar1 = Fr.init(7);
    const scalar2 = Fr.init(11);

    const p = try G1.GENERATOR.mul(&scalar1);
    const q = try G1.GENERATOR.mul(&scalar2);

    const scalar3 = Fr.init(5);
    const left = try p.add(&q).mul(&scalar3);
    const p_scaled = try p.mul(&scalar3);
    const q_scaled = try q.mul(&scalar3);
    const right = p_scaled.add(&q_scaled);
    try std.testing.expect(left.equal(&right));
}

test "BN254 G2 point addition on curve" {
    const gen = G2.GENERATOR;
    const doubled = gen.double();
    const sum = gen.add(&gen);
    try std.testing.expect(sum.equal(&doubled));
    try std.testing.expect(sum.isOnCurve());
}

test "BN254 G2 scalar multiplication basic" {
    const gen = G2.GENERATOR;
    const result = gen.mulByInt(3);
    const manual = gen.add(&gen).add(&gen);
    try std.testing.expect(result.equal(&manual));
    try std.testing.expect(result.isOnCurve());
}

test "BN254 G2 scalar multiplication by zero" {
    const gen = G2.GENERATOR;
    const result = gen.mulByInt(0);
    try std.testing.expect(result.isInfinity());
}

test "BN254 G2 scalar multiplication by curve order" {
    const gen = G2.GENERATOR;
    const result = gen.mulByInt(FR_MOD);
    try std.testing.expect(result.isInfinity());
}

test "BN254 G2 point validation rejects off-curve points" {
    const bad_x = Fp2Mont.initFromInt(1, 1);
    const bad_y = Fp2Mont.initFromInt(2, 2);
    const z = Fp2Mont.ONE;

    const result = G2.init(&bad_x, &bad_y, &z);
    try std.testing.expectError(error.InvalidPoint, result);
}

test "BN254 G2 point at infinity operations" {
    const inf = G2.INFINITY;
    const gen = G2.GENERATOR;

    try std.testing.expect(inf.isInfinity());
    try std.testing.expect(inf.isOnCurve());

    const inf_plus_gen = inf.add(&gen);
    try std.testing.expect(inf_plus_gen.equal(&gen));

    const inf_doubled = inf.double();
    try std.testing.expect(inf_doubled.isInfinity());
}

test "BN254 G2 subgroup check on generator" {
    const gen = G2.GENERATOR;
    try std.testing.expect(gen.isInSubgroup());
}

test "BN254 G2 subgroup check on multiples" {
    const scalars = [_]u256{ 2, 7, 13, 99, 1234 };
    for (scalars) |s| {
        const point = G2.GENERATOR.mulByInt(s);
        try std.testing.expect(point.isInSubgroup());
    }
}

test "BN254 pairing bilinearity" {
    const scalar1 = Fr.init(7);
    const scalar2 = Fr.init(11);

    const g1_base = G1.GENERATOR;
    const g2_base = G2.GENERATOR;

    const g1_scaled = try g1_base.mul(&scalar1);
    const g2_scaled = g2_base.mul(&scalar2);

    const e1 = try pairing(&g1_scaled, &g2_base);
    const e2 = try pairing(&g1_base, &g2_scaled);
    const e_both = try pairing(&g1_scaled, &g2_scaled);

    _ = e1.mul(&e2);
    const scalar_combined = scalar1.mul(&scalar2);
    const e_base = try pairing(&g1_base, &g2_base);
    const e_expected = e_base.pow(scalar_combined.value);

    try std.testing.expect(e_both.equal(&e_expected));
}

test "BN254 pairing with infinity" {
    const g1_gen = G1.GENERATOR;
    const g2_gen = G2.GENERATOR;
    const g1_inf = G1.INFINITY;
    const g2_inf = G2.INFINITY;

    const result1 = try pairing(&g1_inf, &g2_gen);
    try std.testing.expect(result1.equal(&Fp12Mont.ONE));

    const result2 = try pairing(&g1_gen, &g2_inf);
    try std.testing.expect(result2.equal(&Fp12Mont.ONE));

    const result3 = try pairing(&g1_inf, &g2_inf);
    try std.testing.expect(result3.equal(&Fp12Mont.ONE));
}

test "BN254 pairing non-degeneracy" {
    const g1_gen = G1.GENERATOR;
    const g2_gen = G2.GENERATOR;

    const result = try pairing(&g1_gen, &g2_gen);
    try std.testing.expect(!result.equal(&Fp12Mont.ONE));
}

test "BN254 field modulus properties" {
    try std.testing.expect(FP_MOD > 0);
    try std.testing.expect(FR_MOD > 0);
    try std.testing.expect(FP_MOD != FR_MOD);
}

test "BN254 generator points are on curve" {
    try std.testing.expect(G1.GENERATOR.isOnCurve());
    try std.testing.expect(G2.GENERATOR.isOnCurve());
}

test "BN254 generator points are not infinity" {
    try std.testing.expect(!G1.GENERATOR.isInfinity());
    try std.testing.expect(!G2.GENERATOR.isInfinity());
}

test "BN254 G1 large scalar multiplication" {
    const large_scalar = FR_MOD - 1;
    const result = try G1.GENERATOR.mulByInt(large_scalar);
    const neg_gen = G1.GENERATOR.neg();
    try std.testing.expect(result.equal(&neg_gen));
}

test "BN254 G2 large scalar multiplication" {
    const large_scalar = FR_MOD - 1;
    const result = G2.GENERATOR.mulByInt(large_scalar);
    const neg_gen = G2.GENERATOR.neg();
    try std.testing.expect(result.equal(&neg_gen));
}

test "BN254 G1 small scalar edge cases" {
    const gen = G1.GENERATOR;

    const by_2 = try gen.mulByInt(2);
    const doubled = gen.double();
    try std.testing.expect(by_2.equal(&doubled));

    const by_3 = try gen.mulByInt(3);
    const tripled = gen.add(&gen).add(&gen);
    try std.testing.expect(by_3.equal(&tripled));

    const by_4 = try gen.mulByInt(4);
    const quadrupled = doubled.double();
    try std.testing.expect(by_4.equal(&quadrupled));
}

test "BN254 G2 small scalar edge cases" {
    const gen = G2.GENERATOR;

    const by_2 = gen.mulByInt(2);
    const doubled = gen.double();
    try std.testing.expect(by_2.equal(&doubled));

    const by_3 = gen.mulByInt(3);
    const tripled = gen.add(&gen).add(&gen);
    try std.testing.expect(by_3.equal(&tripled));
}

test "BN254 G1 toAffine preserves point" {
    const scalar = Fr.init(17);
    const point = try G1.GENERATOR.mul(&scalar);
    const affine = try point.toAffine();

    try std.testing.expect(point.equal(&affine));
    try std.testing.expect(affine.isOnCurve());
    try std.testing.expect(affine.z.equal(&FpMont.ONE));
}

test "BN254 G2 toAffine preserves point" {
    const scalar = Fr.init(19);
    const point = G2.GENERATOR.mul(&scalar);
    const affine = point.toAffine();

    try std.testing.expect(point.equal(&affine));
    try std.testing.expect(affine.isOnCurve());
    try std.testing.expect(affine.z.equal(&Fp2Mont.ONE));
}

test "BN254 G1 negation twice gives original" {
    const scalar = Fr.init(23);
    const point = try G1.GENERATOR.mul(&scalar);
    const neg_neg = point.neg().neg();
    try std.testing.expect(point.equal(&neg_neg));
}

test "BN254 G2 negation twice gives original" {
    const scalar = Fr.init(29);
    const point = G2.GENERATOR.mul(&scalar);
    const neg_neg = point.neg().neg();
    try std.testing.expect(point.equal(&neg_neg));
}

test "BN254 pairing additivity in first argument" {
    const scalar1 = Fr.init(3);
    const scalar2 = Fr.init(5);

    const p1 = try G1.GENERATOR.mul(&scalar1);
    const p2 = try G1.GENERATOR.mul(&scalar2);
    const q = G2.GENERATOR;

    const e_sum = try pairing(&p1.add(&p2), &q);
    const e1 = try pairing(&p1, &q);
    const e2 = try pairing(&p2, &q);
    const e_product = e1.mul(&e2);

    try std.testing.expect(e_sum.equal(&e_product));
}

test "BN254 pairing additivity in second argument" {
    const scalar1 = Fr.init(7);
    const scalar2 = Fr.init(9);

    const p = G1.GENERATOR;
    const q1 = G2.GENERATOR.mul(&scalar1);
    const q2 = G2.GENERATOR.mul(&scalar2);

    const e_sum = try pairing(&p, &q1.add(&q2));
    const e1 = try pairing(&p, &q1);
    const e2 = try pairing(&p, &q2);
    const e_product = e1.mul(&e2);

    try std.testing.expect(e_sum.equal(&e_product));
}

// ============================================================================
// PRECOMPILE WRAPPER FUNCTIONS (EIP-196/197 Format)
// ============================================================================

const pairing_mod = @import("bn254/pairing.zig");
pub const Pair = pairing_mod.Pair;
pub const multiPairing = pairing_mod.multiPairing;
pub const multiMillerLoop = pairing_mod.multiMillerLoop;

/// Reads one big-endian 32-byte field element and rejects values >= p.
fn readFp(bytes: *const [32]u8) !FpMont {
    return FpMont.initCanonical(std.mem.readInt(u256, bytes, .big));
}

/// Decodes an EIP-196/197 G1 point `x || y`. `(0, 0)` is the point at infinity.
/// Every coordinate must be canonical (< p) and the point must be on the curve.
fn readG1(bytes: *const [64]u8) !G1 {
    const x = try readFp(bytes[0..32]);
    const y = try readFp(bytes[32..64]);
    if (x.equal(&FpMont.ZERO) and y.equal(&FpMont.ZERO)) return G1.INFINITY;
    return G1.init(&x, &y, &FpMont.ONE);
}

/// Decodes an EIP-197 G2 point. Each Fp2 element `c0 + c1*u` is encoded
/// imaginary part first: `x_c1 || x_c0 || y_c1 || y_c0`.
/// All zeros is the point at infinity. Every coordinate must be canonical
/// (< p) and the point must be on the twist and in the order-r subgroup.
fn readG2(bytes: *const [128]u8) !G2 {
    const x_imag = try readFp(bytes[0..32]);
    const x_real = try readFp(bytes[32..64]);
    const y_imag = try readFp(bytes[64..96]);
    const y_real = try readFp(bytes[96..128]);
    const x = Fp2Mont.init(&x_real, &x_imag);
    const y = Fp2Mont.init(&y_real, &y_imag);
    if (x.equal(&Fp2Mont.ZERO) and y.equal(&Fp2Mont.ZERO)) return G2.INFINITY;
    return G2.init(&x, &y, &Fp2Mont.ONE);
}

/// Writes an affine G1 point as `x || y`; infinity is 64 zero bytes.
fn writeG1(point: *const G1, output: []u8) !void {
    const affine = try point.toAffine();
    if (affine.isInfinity()) {
        @memset(output[0..64], 0);
        return;
    }
    std.mem.writeInt(u256, output[0..32], affine.x.toStandardRepresentation(), .big);
    std.mem.writeInt(u256, output[32..64], affine.y.toStandardRepresentation(), .big);
}

/// EIP-196: BN254 Addition
/// Input: 128 bytes (two G1 points, 64 bytes each: x || y)
/// Output: 64 bytes (resulting G1 point: x || y)
pub fn bn254Add(input: *const [128]u8, output: []u8) !void {
    if (output.len < 64) return error.InvalidOutput;
    const p1 = try readG1(input[0..64]);
    const p2 = try readG1(input[64..128]);
    const result = p1.add(&p2);
    try writeG1(&result, output);
}

/// EIP-196: BN254 Scalar Multiplication
/// Input: 96 bytes (G1 point (64) || scalar (32))
/// Output: 64 bytes (resulting G1 point: x || y)
pub fn bn254Mul(input: *const [96]u8, output: []u8) !void {
    if (output.len < 64) return error.InvalidOutput;
    const point = try readG1(input[0..64]);
    const scalar = std.mem.readInt(u256, input[64..96], .big);
    const result = try point.mulByInt(scalar);
    try writeG1(&result, output);
}

/// EIP-197: BN254 Pairing Check
/// Input: k*192 bytes, each pair `x1 || y1 || x2_imag || x2_real || y2_imag || y2_real`.
/// Returns true when prod_i e(P_i, Q_i) == 1 (also for empty input).
/// Every pair is validated. Non-infinity pairs share one Miller loop per
/// chunk of `pairing_mod.MULTI_MILLER_CHUNK` and one final exponentiation.
pub fn bn254Pairing(input: []const u8) !bool {
    if (input.len % 192 != 0) return error.InvalidInput;

    var chunk: [pairing_mod.MULTI_MILLER_CHUNK]Pair = undefined;
    var n: usize = 0;
    var active: usize = 0;
    var f = Fp12Mont.ONE;

    var offset: usize = 0;
    while (offset < input.len) : (offset += 192) {
        const g1 = try readG1(input[offset..][0..64]);
        const g2 = try readG2(input[offset + 64 ..][0..128]);
        if (g1.isInfinity() or g2.isInfinity()) continue;
        chunk[n] = .{ .g1 = g1, .g2 = g2 };
        n += 1;
        active += 1;
        if (n == chunk.len) {
            const partial = try multiMillerLoop(chunk[0..n]);
            f.mulAssign(&partial);
            n = 0;
        }
    }
    if (active == 0) return true;
    if (n > 0) {
        const partial = try multiMillerLoop(chunk[0..n]);
        f.mulAssign(&partial);
    }
    const result = try pairing_mod.finalExponentiation(&f);
    return result.equal(&Fp12Mont.ONE);
}

// ============================================================================
// EIP-196/197 Test Vectors and Validation Tests
// ============================================================================

test "BN254 EIP-196 ECADD - G1 + G1 = 2*G1" {
    var input: [128]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000002");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "030644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd3" ++
        "15ed738c0e0a7c92e7845f96b2ae9c0a68a6a449e3538fc7ff3ebf7a5a18a2c4");
    var output: [64]u8 = undefined;
    try bn254Add(&input, &output);
    try std.testing.expectEqualSlices(u8, &expected, &output);
}

test "BN254 EIP-196 ECADD - add point to infinity" {
    var input = @as([128]u8, @splat(0));
    input[31] = 1;
    input[63] = 2;
    var output: [64]u8 = undefined;
    try bn254Add(&input, &output);
    try std.testing.expectEqualSlices(u8, input[0..64], &output);
}

test "BN254 EIP-196 ECADD - add two infinities" {
    const input = @as([128]u8, @splat(0));
    var output = @as([64]u8, @splat(0xff));
    try bn254Add(&input, &output);
    try std.testing.expectEqualSlices(u8, &(@as([64]u8, @splat(0))), &output);
}

test "BN254 EIP-196 ECADD - add point and its negation" {
    var input: [128]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd45");
    var output = @as([64]u8, @splat(0xff));
    try bn254Add(&input, &output);
    try std.testing.expectEqualSlices(u8, &(@as([64]u8, @splat(0))), &output);
}

test "BN254 EIP-196 ECADD - invalid point returns error" {
    var input = @as([128]u8, @splat(0));
    input[31] = 1;
    input[63] = 3;
    var output: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidPoint, bn254Add(&input, &output));
}

test "BN254 EIP-196 ECADD - non-canonical coordinate is rejected" {
    // x = p + 1 reduces to 1, which would decode as the generator (1, 2).
    var input = @as([128]u8, @splat(0));
    std.mem.writeInt(u256, input[0..32], FP_MOD + 1, .big);
    input[63] = 2;
    var output: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidFieldElement, bn254Add(&input, &output));

    // (p, 0) reduces to (0, 0), which would decode as infinity.
    var second = @as([128]u8, @splat(0));
    std.mem.writeInt(u256, second[64..96], FP_MOD, .big);
    try std.testing.expectError(error.InvalidFieldElement, bn254Add(&second, &output));

    // y = p + 2 reduces to 2.
    var third = @as([128]u8, @splat(0));
    third[31] = 1;
    std.mem.writeInt(u256, third[32..64], FP_MOD + 2, .big);
    try std.testing.expectError(error.InvalidFieldElement, bn254Add(&third, &output));
}

test "BN254 EIP-196 ECMUL - multiply by zero" {
    var input = @as([96]u8, @splat(0));
    input[31] = 1;
    input[63] = 2;
    var output = @as([64]u8, @splat(0xff));
    try bn254Mul(&input, &output);
    try std.testing.expectEqualSlices(u8, &(@as([64]u8, @splat(0))), &output);
}

test "BN254 EIP-196 ECMUL - multiply by one" {
    var input = @as([96]u8, @splat(0));
    input[31] = 1;
    input[63] = 2;
    input[95] = 1;
    var output: [64]u8 = undefined;
    try bn254Mul(&input, &output);
    try std.testing.expectEqualSlices(u8, input[0..64], &output);
}

test "BN254 EIP-196 ECMUL - multiply by two equals ECADD doubling" {
    var input = @as([96]u8, @splat(0));
    input[31] = 1;
    input[63] = 2;
    input[95] = 2;
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "030644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd3" ++
        "15ed738c0e0a7c92e7845f96b2ae9c0a68a6a449e3538fc7ff3ebf7a5a18a2c4");
    var output: [64]u8 = undefined;
    try bn254Mul(&input, &output);
    try std.testing.expectEqualSlices(u8, &expected, &output);
}

test "BN254 EIP-196 ECMUL - multiply infinity by scalar" {
    var input = @as([96]u8, @splat(0));
    input[95] = 17;
    var output = @as([64]u8, @splat(0xff));
    try bn254Mul(&input, &output);
    try std.testing.expectEqualSlices(u8, &(@as([64]u8, @splat(0))), &output);
}

test "BN254 EIP-196 ECMUL - multiply by curve order" {
    var input = @as([96]u8, @splat(0));
    input[31] = 1;
    input[63] = 2;
    std.mem.writeInt(u256, input[64..96], FR_MOD, .big);
    var output = @as([64]u8, @splat(0xff));
    try bn254Mul(&input, &output);
    try std.testing.expectEqualSlices(u8, &(@as([64]u8, @splat(0))), &output);
}

test "BN254 EIP-196 ECMUL - scalar that drives GLV k2 negative" {
    // Regression: this scalar made the old unsigned decomposition panic.
    // Expected value computed with affine double-and-add in Python.
    var input: [96]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "30644e72e131a02850c6967bfe2f29ac703b66375e9e1b409038b08cbe50a2a0");
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "2d05f531875cda41623492659b90af27591bb58589547035b0aaaa694f309930" ++
        "2daff94d2ad0c8ca881a8aa14d2b573e34d68d44b52be6ac9d1440637ac039d6");
    var output: [64]u8 = undefined;
    try bn254Mul(&input, &output);
    try std.testing.expectEqualSlices(u8, &expected, &output);
}

test "BN254 EIP-196 ECMUL - maximum 256-bit scalar" {
    var input = @as([96]u8, @splat(0xff));
    @memset(input[0..64], 0);
    input[31] = 1;
    input[63] = 2;
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "2f588cffe99db877a4434b598ab28f81e0522910ea52b45f0adaa772b2d5d352" ++
        "12f42fa8fd34fb1b33d8c6a718b6590198389b26fc9d8808d971f8b009777a97");
    var output: [64]u8 = undefined;
    try bn254Mul(&input, &output);
    try std.testing.expectEqualSlices(u8, &expected, &output);
}

test "BN254 EIP-196 ECMUL - non-canonical coordinate is rejected" {
    var input = @as([96]u8, @splat(0));
    std.mem.writeInt(u256, input[0..32], FP_MOD + 1, .big);
    input[63] = 2;
    input[95] = 3;
    var output: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidFieldElement, bn254Mul(&input, &output));
}

// EIP-197 encodings (x1 || y1 || x2_imag || x2_real || y2_imag || y2_real).
const eip197_g1 = "0000000000000000000000000000000000000000000000000000000000000001" ++
    "0000000000000000000000000000000000000000000000000000000000000002";
const eip197_neg_g1 = "0000000000000000000000000000000000000000000000000000000000000001" ++
    "30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd45";
const eip197_two_g1 = "030644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd3" ++
    "15ed738c0e0a7c92e7845f96b2ae9c0a68a6a449e3538fc7ff3ebf7a5a18a2c4";
const eip197_g2 = "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2" ++
    "1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed" ++
    "090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b" ++
    "12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa";
const eip197_two_g2 = "203e205db4f19b37b60121b83a7333706db86431c6d835849957ed8c3928ad79" ++
    "27dc7234fd11d3e8c36c59277c3e6f149d5cd3cfa9a62aee49f8130962b4b3b9" ++
    "195e8aa5b7827463722b8c153931579d3505566b4edf48d498e185f0509de152" ++
    "04bb53b8977e5f92a0bc372742c4830944a59b4fe6b1c0466e2a6dad122b5d2e";
const eip197_zero_g1 = "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
const eip197_zero_g2 = "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

test "BN254 EIP-197 ECPAIRING - empty input" {
    const input: []const u8 = &[_]u8{};
    try std.testing.expect(try bn254Pairing(input));
}

test "BN254 EIP-197 ECPAIRING - invalid input length" {
    const input = @as([100]u8, @splat(0));
    try std.testing.expectError(error.InvalidInput, bn254Pairing(&input));
}

test "BN254 EIP-197 ECPAIRING - e(G1, G2) != 1" {
    var input: [192]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, eip197_g1 ++ eip197_g2);
    try std.testing.expect(!(try bn254Pairing(&input)));
}

test "BN254 EIP-197 ECPAIRING - e(G1, G2) * e(-G1, G2) == 1" {
    var input: [384]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, eip197_g1 ++ eip197_g2 ++ eip197_neg_g1 ++ eip197_g2);
    try std.testing.expect(try bn254Pairing(&input));
}

test "BN254 EIP-197 ECPAIRING - e(2*G1, G2) * e(-G1, 2*G2) == 1" {
    var input: [384]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, eip197_two_g1 ++ eip197_g2 ++ eip197_neg_g1 ++ eip197_two_g2);
    try std.testing.expect(try bn254Pairing(&input));

    // e(2*G1, G2) * e(G1, 2*G2) = e(G1, G2)^4 != 1
    _ = try std.fmt.hexToBytes(&input, eip197_two_g1 ++ eip197_g2 ++ eip197_g1 ++ eip197_two_g2);
    try std.testing.expect(!(try bn254Pairing(&input)));
}

test "BN254 EIP-197 ECPAIRING - geth jeff1 vector" {
    // go-ethereum core/vm/testdata/precompiles/bn256Pairing.json "jeff1", expected 1.
    var input: [384]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, "1c76476f4def4bb94541d57ebba1193381ffa7aa76ada664dd31c16024c43f59" ++
        "3034dd2920f673e204fee2811c678745fc819b55d3e9d294e45c9b03a76aef41" ++
        "209dd15ebff5d46c4bd888e51a93cf99a7329636c63514396b4a452003a35bf7" ++
        "04bf11ca01483bfa8b34b43561848d28905960114c8ac04049af4b6315a41678" ++
        "2bb8324af6cfc93537a2ad1a445cfd0ca2a71acd7ac41fadbf933c2a51be344d" ++
        "120a2a4cf30c1bf9845f20c6fe39e07ea2cce61f0c9bb048165fe5e4de877550" ++
        "111e129f1cf1097710d41c4ac70fcdfa5ba2023c6ff1cbeac322de49d1b6df7c" ++
        "2032c61a830e3c17286de9462bf242fca2883585b93870a73853face6a6bf411" ++
        eip197_g2);
    try std.testing.expect(try bn254Pairing(&input));
}

test "BN254 EIP-197 ECPAIRING - with infinity points" {
    var input: [192]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, eip197_zero_g1 ++ eip197_g2);
    try std.testing.expect(try bn254Pairing(&input));
    _ = try std.fmt.hexToBytes(&input, eip197_g1 ++ eip197_zero_g2);
    try std.testing.expect(try bn254Pairing(&input));
    _ = try std.fmt.hexToBytes(&input, eip197_zero_g1 ++ eip197_zero_g2);
    try std.testing.expect(try bn254Pairing(&input));

    // An infinity pair contributes 1 and does not change a non-trivial product.
    var mixed: [384]u8 = undefined;
    _ = try std.fmt.hexToBytes(&mixed, eip197_zero_g1 ++ eip197_g2 ++ eip197_g1 ++ eip197_g2);
    try std.testing.expect(!(try bn254Pairing(&mixed)));
}

test "BN254 EIP-197 ECPAIRING - real-then-imaginary G2 order is rejected" {
    // The generator with each Fp2 written real first is off the twist.
    var input: [192]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, eip197_g1 ++
        "1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed" ++
        "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2" ++
        "12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa" ++
        "090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b");
    try std.testing.expectError(error.InvalidPoint, bn254Pairing(&input));
}

test "BN254 EIP-197 ECPAIRING - non-canonical coordinates are rejected" {
    var input: [192]u8 = undefined;
    // G1 x = p + 1 reduces to 1.
    _ = try std.fmt.hexToBytes(&input, eip197_g1 ++ eip197_g2);
    std.mem.writeInt(u256, input[0..32], FP_MOD + 1, .big);
    try std.testing.expectError(error.InvalidFieldElement, bn254Pairing(&input));

    // G1 (p, p) reduces to (0, 0), the infinity encoding.
    _ = try std.fmt.hexToBytes(&input, eip197_zero_g1 ++ eip197_g2);
    std.mem.writeInt(u256, input[0..32], FP_MOD, .big);
    std.mem.writeInt(u256, input[32..64], FP_MOD, .big);
    try std.testing.expectError(error.InvalidFieldElement, bn254Pairing(&input));

    // Each G2 limb, one at a time, shifted by p.
    for (0..4) |limb| {
        _ = try std.fmt.hexToBytes(&input, eip197_g1 ++ eip197_g2);
        const start = 64 + limb * 32;
        const bytes = input[start..][0..32];
        const value = std.mem.readInt(u256, bytes, .big);
        std.mem.writeInt(u256, bytes, value + FP_MOD, .big);
        try std.testing.expectError(error.InvalidFieldElement, bn254Pairing(&input));
    }

    // G2 all limbs = p reduces to the infinity encoding.
    _ = try std.fmt.hexToBytes(&input, eip197_g1 ++ eip197_zero_g2);
    for (0..4) |limb| {
        std.mem.writeInt(u256, input[64 + limb * 32 ..][0..32], FP_MOD, .big);
    }
    try std.testing.expectError(error.InvalidFieldElement, bn254Pairing(&input));
}

test "BN254 EIP-197 ECPAIRING - G2 point outside the r-torsion subgroup is rejected" {
    // x = 2 + u on the twist; Python confirms [r]Q != O.
    var input: [192]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, eip197_g1 ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "2b76c179599bb92a963dac85546a005a777f7c13f6a7b75d5918b6b5808f5fde" ++
        "101f7278419308b95099eca02dcee0c5381f4d26d1d62313f057167f064101ce");
    try std.testing.expectError(error.NotInSubgroup, bn254Pairing(&input));
}

test "BN254 EIP-197 ECPAIRING - off-curve G1 is rejected" {
    var input: [192]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, eip197_g1 ++ eip197_g2);
    input[63] = 3;
    try std.testing.expectError(error.InvalidPoint, bn254Pairing(&input));
}

test "BN254 EIP-197 ECPAIRING - more pairs than one Miller-loop chunk" {
    // 18 pairs = 9 cancelling (G1, G2), (-G1, G2) couples; crosses the 16-pair chunk.
    const couple = eip197_g1 ++ eip197_g2 ++ eip197_neg_g1 ++ eip197_g2;
    var input: [18 * 192]u8 = undefined;
    for (0..9) |i| _ = try std.fmt.hexToBytes(input[i * 2 * 192 ..][0 .. 2 * 192], couple);
    try std.testing.expect(try bn254Pairing(&input));

    // Flip the last pair's G1 from -G1 to G1: product becomes e(G1, G2)^2.
    _ = try std.fmt.hexToBytes(input[17 * 192 ..][0..64], eip197_g1);
    try std.testing.expect(!(try bn254Pairing(&input)));
}

test "BN254 EIP-196 - scalar validation" {
    // Scalars must be less than the curve order
    const valid_scalar = FR_MOD - 1;
    const result = try G1.GENERATOR.mulByInt(valid_scalar);
    try std.testing.expect(result.isOnCurve());

    // Maximum valid scalar
    const max_scalar = FR_MOD - 1;
    const result2 = try G1.GENERATOR.mulByInt(max_scalar);
    try std.testing.expect(result2.isOnCurve());
}

test "BN254 point serialization - point at infinity" {
    // Jacobian infinity is (0 : 1 : 0); the EIP-196 wire encoding is (0, 0).
    const inf = G1.INFINITY;
    try std.testing.expect(inf.isInfinity());
    try std.testing.expect(inf.x.equal(&FpMont.ZERO));
    try std.testing.expect(inf.y.equal(&FpMont.ONE));
    try std.testing.expect(inf.z.equal(&FpMont.ZERO));
    var output = @as([64]u8, @splat(0xff));
    try writeG1(&inf, &output);
    try std.testing.expectEqualSlices(u8, &(@as([64]u8, @splat(0))), &output);
}

test "BN254 point validation - generator has correct order" {
    const n_minus_1 = FR_MOD - 1;
    const result = try G1.GENERATOR.mulByInt(n_minus_1);
    const neg_gen = G1.GENERATOR.neg();
    try std.testing.expect(result.equal(&neg_gen));
}

test "BN254 G1 cofactor test" {
    const gen = G1.GENERATOR;
    const order_mult = try gen.mulByInt(FR_MOD);
    try std.testing.expect(order_mult.isInfinity());
}

test "BN254 G2 cofactor test" {
    const gen = G2.GENERATOR;
    const order_mult = gen.mulByInt(FR_MOD);
    try std.testing.expect(order_mult.isInfinity());
}

test "BN254 field element validation" {
    const valid_fp = FpMont.init(FP_MOD - 1);
    try std.testing.expect(!valid_fp.equal(&FpMont.ZERO));

    const zero_fp = FpMont.ZERO;
    try std.testing.expect(zero_fp.equal(&FpMont.ZERO));

    const one_fp = FpMont.ONE;
    try std.testing.expect(!one_fp.equal(&FpMont.ZERO));
}

test "BN254 scalar field arithmetic" {
    const a = Fr.init(5);
    const b = Fr.init(7);

    const sum = a.add(&b);
    const expected_sum = Fr.init(12);
    try std.testing.expect(sum.equal(&expected_sum));

    const prod = a.mul(&b);
    const expected_prod = Fr.init(35);
    try std.testing.expect(prod.equal(&expected_prod));
}

test "BN254 point doubling formula correctness" {
    const scalars = [_]u256{ 2, 4, 8, 16, 32, 64 };
    for (scalars) |s| {
        const by_doubling = blk: {
            var result = G1.GENERATOR;
            var remaining = s;
            while (remaining > 1) : (remaining /= 2) {
                result = result.double();
            }
            break :blk result;
        };

        const by_mul = try G1.GENERATOR.mulByInt(s);
        try std.testing.expect(by_doubling.equal(&by_mul));
    }
}

test "BN254 mixed addition (affine + projective)" {
    const affine_gen = try G1.GENERATOR.toAffine();
    const proj_gen = G1.GENERATOR;

    const sum1 = affine_gen.add(&proj_gen);
    const sum2 = proj_gen.add(&affine_gen);

    try std.testing.expect(sum1.equal(&sum2));
    try std.testing.expect(sum1.isOnCurve());
}

test "BN254 scalar multiplication - windowing consistency" {
    const test_scalars = [_]u256{ 15, 31, 63, 127, 255, 511, 1023 };

    for (test_scalars) |scalar| {
        const result = try G1.GENERATOR.mulByInt(scalar);

        var expected = G1.INFINITY;
        var base = G1.GENERATOR;
        var s = scalar;
        while (s > 0) : (s >>= 1) {
            if ((s & 1) == 1) {
                expected = expected.add(&base);
            }
            base = base.double();
        }

        try std.testing.expect(result.equal(&expected));
    }
}

test "BN254 pairing bilinearity with specific scalars" {
    const a = Fr.init(3);
    const b = Fr.init(5);
    const ab = a.mul(&b);

    const g1_a = try G1.GENERATOR.mul(&a);
    const g2_b = G2.GENERATOR.mul(&b);

    const e1 = try pairing(&g1_a, &G2.GENERATOR);
    const e_b = e1.pow(b.value);

    const e2 = try pairing(&G1.GENERATOR, &g2_b);
    const e_a = e2.pow(a.value);

    try std.testing.expect(e_a.equal(&e_b));

    const e_base = try pairing(&G1.GENERATOR, &G2.GENERATOR);
    const e_ab = e_base.pow(ab.value);
    try std.testing.expect(e_ab.equal(&e_a));
}

test "BN254 negation preserves distance" {
    const scalar = Fr.init(42);
    const point = try G1.GENERATOR.mul(&scalar);
    const neg_point = point.neg();

    const sum = point.add(&neg_point);
    try std.testing.expect(sum.isInfinity());

    const neg_neg_point = neg_point.neg();
    try std.testing.expect(point.equal(&neg_neg_point));
}

test "BN254 G2 point compression consistency" {
    const scalar = Fr.init(17);
    const point = G2.GENERATOR.mul(&scalar);
    const affine = point.toAffine();

    try std.testing.expect(point.equal(&affine));
    try std.testing.expect(affine.z.equal(&Fp2Mont.ONE));
}

test "BN254 curve equation validation for random multiples" {
    const test_scalars = [_]u256{ 1, 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47 };

    for (test_scalars) |scalar| {
        const g1_point = try G1.GENERATOR.mulByInt(scalar);
        try std.testing.expect(g1_point.isOnCurve());

        const g2_point = G2.GENERATOR.mulByInt(scalar);
        try std.testing.expect(g2_point.isOnCurve());
    }
}

test "BN254 EIP-196 ECMUL - multiply by large scalar" {
    const gen = (try G1.GENERATOR.toAffine());
    const scalar: u256 = 123456789;

    var input: [96]u8 = undefined;
    @memset(&input, 0);

    // Point (generator)
    std.mem.writeInt(u256, input[0..32], gen.x.toStandardRepresentation(), .big);
    std.mem.writeInt(u256, input[32..64], gen.y.toStandardRepresentation(), .big);

    // Scalar
    std.mem.writeInt(u256, input[64..96], scalar, .big);

    var output: [64]u8 = undefined;
    try bn254Mul(&input, &output);

    // Verify result matches expected
    const expected = (try (try G1.GENERATOR.mulByInt(scalar)).toAffine());
    const result_x = std.mem.readInt(u256, output[0..32], .big);
    const result_y = std.mem.readInt(u256, output[32..64], .big);

    try std.testing.expectEqual(expected.x.toStandardRepresentation(), result_x);
    try std.testing.expectEqual(expected.y.toStandardRepresentation(), result_y);
}

test "BN254 EIP-197 ECPAIRING - bilinearity check" {
    // e(aG1, bG2) = e(G1, G2)^(ab)
    // Verify: e(2G1, 3G2) * e(-6G1, G2) = 1
    const g1 = G1.GENERATOR;
    const g2 = G2.GENERATOR;

    const p1 = (try (try g1.mulByInt(2)).toAffine());
    const p2 = g2.mulByInt(3).toAffine();
    const p3 = (try (try g1.mulByInt(6)).neg().toAffine());
    const p4 = g2.toAffine();

    var input: [384]u8 = undefined;
    @memset(&input, 0);

    // First pair: (2G1, 3G2)
    std.mem.writeInt(u256, input[0..32], p1.x.toStandardRepresentation(), .big);
    std.mem.writeInt(u256, input[32..64], p1.y.toStandardRepresentation(), .big);
    std.mem.writeInt(u256, input[64..96], p2.x.u1.toStandardRepresentation(), .big);
    std.mem.writeInt(u256, input[96..128], p2.x.u0.toStandardRepresentation(), .big);
    std.mem.writeInt(u256, input[128..160], p2.y.u1.toStandardRepresentation(), .big);
    std.mem.writeInt(u256, input[160..192], p2.y.u0.toStandardRepresentation(), .big);

    // Second pair: (-6G1, G2)
    std.mem.writeInt(u256, input[192..224], p3.x.toStandardRepresentation(), .big);
    std.mem.writeInt(u256, input[224..256], p3.y.toStandardRepresentation(), .big);
    std.mem.writeInt(u256, input[256..288], p4.x.u1.toStandardRepresentation(), .big);
    std.mem.writeInt(u256, input[288..320], p4.x.u0.toStandardRepresentation(), .big);
    std.mem.writeInt(u256, input[320..352], p4.y.u1.toStandardRepresentation(), .big);
    std.mem.writeInt(u256, input[352..384], p4.y.u0.toStandardRepresentation(), .big);

    const result = try bn254Pairing(&input);
    try std.testing.expect(result); // Product should equal 1
}
