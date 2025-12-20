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
    const result = gen.mul(&scalar);

    const manual = gen.add(&gen).add(&gen).add(&gen).add(&gen);
    try std.testing.expect(result.equal(&manual));
    try std.testing.expect(result.isOnCurve());
}

test "BN254 G1 scalar multiplication by zero" {
    const gen = G1.GENERATOR;
    const result = gen.mulByInt(0);
    try std.testing.expect(result.isInfinity());
}

test "BN254 G1 scalar multiplication by one" {
    const gen = G1.GENERATOR;
    const result = gen.mulByInt(1);
    try std.testing.expect(result.equal(&gen));
}

test "BN254 G1 scalar multiplication by curve order gives infinity" {
    const gen = G1.GENERATOR;
    const result = gen.mulByInt(FR_MOD);
    try std.testing.expect(result.isInfinity());
}

test "BN254 G1 point validation rejects off-curve points" {
    const bad_x = FpMont.init(1);
    const bad_y = FpMont.init(2);
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

    const p1 = G1.GENERATOR.mul(&scalar1);
    const p2 = G1.GENERATOR.mul(&scalar2);
    const p3 = G1.GENERATOR.mul(&scalar3);

    const left = p1.add(&p2).add(&p3);
    const right = p1.add(&p2.add(&p3));
    try std.testing.expect(left.equal(&right));
}

test "BN254 G1 commutativity of addition" {
    const scalar1 = Fr.init(11);
    const scalar2 = Fr.init(13);

    const p1 = G1.GENERATOR.mul(&scalar1);
    const p2 = G1.GENERATOR.mul(&scalar2);

    const left = p1.add(&p2);
    const right = p2.add(&p1);
    try std.testing.expect(left.equal(&right));
}

test "BN254 G1 distributivity of scalar multiplication" {
    const scalar1 = Fr.init(7);
    const scalar2 = Fr.init(11);

    const p = G1.GENERATOR.mul(&scalar1);
    const q = G1.GENERATOR.mul(&scalar2);

    const scalar3 = Fr.init(5);
    const left = p.add(&q).mul(&scalar3);
    const right = p.mul(&scalar3).add(&q.mul(&scalar3));
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
    const bad_x = Fp2Mont.init_from_int(1, 1);
    const bad_y = Fp2Mont.init_from_int(2, 2);
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

    const g1_scaled = g1_base.mul(&scalar1);
    const g2_scaled = g2_base.mul(&scalar2);

    const e1 = pairing(&g1_scaled, &g2_base);
    const e2 = pairing(&g1_base, &g2_scaled);
    const e_both = pairing(&g1_scaled, &g2_scaled);

    _ = e1.mul(&e2);
    const scalar_combined = scalar1.mul(&scalar2);
    const e_base = pairing(&g1_base, &g2_base);
    const e_expected = e_base.pow(scalar_combined.value);

    try std.testing.expect(e_both.equal(&e_expected));
}

test "BN254 pairing with infinity" {
    const g1_gen = G1.GENERATOR;
    const g2_gen = G2.GENERATOR;
    const g1_inf = G1.INFINITY;
    const g2_inf = G2.INFINITY;

    const result1 = pairing(&g1_inf, &g2_gen);
    try std.testing.expect(result1.equal(&Fp12Mont.ONE));

    const result2 = pairing(&g1_gen, &g2_inf);
    try std.testing.expect(result2.equal(&Fp12Mont.ONE));

    const result3 = pairing(&g1_inf, &g2_inf);
    try std.testing.expect(result3.equal(&Fp12Mont.ONE));
}

test "BN254 pairing non-degeneracy" {
    const g1_gen = G1.GENERATOR;
    const g2_gen = G2.GENERATOR;

    const result = pairing(&g1_gen, &g2_gen);
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
    const result = G1.GENERATOR.mulByInt(large_scalar);
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

    const by_2 = gen.mulByInt(2);
    const doubled = gen.double();
    try std.testing.expect(by_2.equal(&doubled));

    const by_3 = gen.mulByInt(3);
    const tripled = gen.add(&gen).add(&gen);
    try std.testing.expect(by_3.equal(&tripled));

    const by_4 = gen.mulByInt(4);
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
    const point = G1.GENERATOR.mul(&scalar);
    const affine = point.toAffine();

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
    const point = G1.GENERATOR.mul(&scalar);
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

    const p1 = G1.GENERATOR.mul(&scalar1);
    const p2 = G1.GENERATOR.mul(&scalar2);
    const q = G2.GENERATOR;

    const e_sum = pairing(&p1.add(&p2), &q);
    const e1 = pairing(&p1, &q);
    const e2 = pairing(&p2, &q);
    const e_product = e1.mul(&e2);

    try std.testing.expect(e_sum.equal(&e_product));
}

test "BN254 pairing additivity in second argument" {
    const scalar1 = Fr.init(7);
    const scalar2 = Fr.init(9);

    const p = G1.GENERATOR;
    const q1 = G2.GENERATOR.mul(&scalar1);
    const q2 = G2.GENERATOR.mul(&scalar2);

    const e_sum = pairing(&p, &q1.add(&q2));
    const e1 = pairing(&p, &q1);
    const e2 = pairing(&p, &q2);
    const e_product = e1.mul(&e2);

    try std.testing.expect(e_sum.equal(&e_product));
}

// ============================================================================
// PRECOMPILE WRAPPER FUNCTIONS (EIP-196/197 Format)
// ============================================================================

/// EIP-196: BN254 Addition
/// Input: 128 bytes (two G1 points, 64 bytes each: x || y)
/// Output: 64 bytes (resulting G1 point: x || y)
pub fn bn254Add(input: *const [128]u8, output: []u8) !void {
    if (output.len < 64) return error.InvalidOutput;

    // Parse first G1 point (bytes 0-63)
    const x1_bytes = input[0..32];
    const y1_bytes = input[32..64];
    const x1_value = std.mem.readInt(u256, x1_bytes, .big);
    const y1_value = std.mem.readInt(u256, y1_bytes, .big);

    // Parse second G1 point (bytes 64-127)
    const x2_bytes = input[64..96];
    const y2_bytes = input[96..128];
    const x2_value = std.mem.readInt(u256, x2_bytes, .big);
    const y2_value = std.mem.readInt(u256, y2_bytes, .big);

    // Handle point at infinity (represented as (0, 0))
    const p1 = if (x1_value == 0 and y1_value == 0)
        G1.INFINITY
    else blk: {
        const x1 = FpMont.init(x1_value);
        const y1 = FpMont.init(y1_value);
        const z1 = FpMont.ONE;
        break :blk try G1.init(&x1, &y1, &z1);
    };

    const p2 = if (x2_value == 0 and y2_value == 0)
        G1.INFINITY
    else blk: {
        const x2 = FpMont.init(x2_value);
        const y2 = FpMont.init(y2_value);
        const z2 = FpMont.ONE;
        break :blk try G1.init(&x2, &y2, &z2);
    };

    // Perform addition
    const result = p1.add(&p2);
    const result_affine = try result.toAffine();

    // Serialize result to output
    // Point at infinity is represented as (0, 0)
    if (result_affine.isInfinity()) {
        @memset(output[0..64], 0);
    } else {
        const x_result = result_affine.x.value;
        const y_result = result_affine.y.value;

        // Write x coordinate (big-endian)
        std.mem.writeInt(u256, output[0..32], x_result, .big);
        // Write y coordinate (big-endian)
        std.mem.writeInt(u256, output[32..64], y_result, .big);
    }
}

/// EIP-196: BN254 Scalar Multiplication
/// Input: 96 bytes (G1 point (64) || scalar (32))
/// Output: 64 bytes (resulting G1 point: x || y)
pub fn bn254Mul(input: *const [96]u8, output: []u8) !void {
    if (output.len < 64) return error.InvalidOutput;

    // Parse G1 point (bytes 0-63)
    const x_bytes = input[0..32];
    const y_bytes = input[32..64];
    const x_value = std.mem.readInt(u256, x_bytes, .big);
    const y_value = std.mem.readInt(u256, y_bytes, .big);

    // Parse scalar (bytes 64-95)
    const scalar_bytes = input[64..96];
    const scalar_value = std.mem.readInt(u256, scalar_bytes, .big);

    // Handle point at infinity (represented as (0, 0))
    const point = if (x_value == 0 and y_value == 0)
        G1.INFINITY
    else blk: {
        const x = FpMont.init(x_value);
        const y = FpMont.init(y_value);
        const z = FpMont.ONE;
        break :blk try G1.init(&x, &y, &z);
    };

    // Perform scalar multiplication
    const result_g1 = try point.mulByInt(scalar_value);
    const result_affine = try result_g1.toAffine();

    // Serialize result to output
    // Point at infinity is represented as (0, 0)
    if (result_affine.isInfinity()) {
        @memset(output[0..64], 0);
    } else {
        const x_result = result_affine.x.value;
        const y_result = result_affine.y.value;

        // Write x coordinate (big-endian)
        std.mem.writeInt(u256, output[0..32], x_result, .big);
        // Write y coordinate (big-endian)
        std.mem.writeInt(u256, output[32..64], y_result, .big);
    }
}

/// EIP-197: BN254 Pairing Check
/// Input: k*192 bytes (k pairs of G1 point (64) || G2 point (128))
/// Returns: true if pairing check passes, false otherwise
pub fn bn254Pairing(input: []const u8) !bool {
    // Input must be a multiple of 192 bytes
    if (input.len % 192 != 0) return error.InvalidInput;

    // Empty input returns true according to EIP-197
    if (input.len == 0) return true;

    const n_pairs = input.len / 192;

    // Accumulate pairing result
    var result = Fp12Mont.ONE;

    var i: usize = 0;
    while (i < n_pairs) : (i += 1) {
        const pair_start = i * 192;

        // Parse G1 point (bytes 0-63 of this pair)
        const g1_x_bytes = input[pair_start .. pair_start + 32];
        const g1_y_bytes = input[pair_start + 32 .. pair_start + 64];
        const g1_x_value = std.mem.readInt(u256, g1_x_bytes[0..32], .big);
        const g1_y_value = std.mem.readInt(u256, g1_y_bytes[0..32], .big);

        const g1_point = if (g1_x_value == 0 and g1_y_value == 0)
            G1.INFINITY
        else blk: {
            const x = FpMont.init(g1_x_value);
            const y = FpMont.init(g1_y_value);
            const z = FpMont.ONE;
            break :blk try G1.init(&x, &y, &z);
        };

        // Parse G2 point (bytes 64-191 of this pair)
        // G2 coordinates are in Fp2: x = x_c0 + x_c1*i, y = y_c0 + y_c1*i
        const g2_x_c0_bytes = input[pair_start + 64 .. pair_start + 96];
        const g2_x_c1_bytes = input[pair_start + 96 .. pair_start + 128];
        const g2_y_c0_bytes = input[pair_start + 128 .. pair_start + 160];
        const g2_y_c1_bytes = input[pair_start + 160 .. pair_start + 192];

        const g2_x_c0_value = std.mem.readInt(u256, g2_x_c0_bytes[0..32], .big);
        const g2_x_c1_value = std.mem.readInt(u256, g2_x_c1_bytes[0..32], .big);
        const g2_y_c0_value = std.mem.readInt(u256, g2_y_c0_bytes[0..32], .big);
        const g2_y_c1_value = std.mem.readInt(u256, g2_y_c1_bytes[0..32], .big);

        const g2_point = if (g2_x_c0_value == 0 and g2_x_c1_value == 0 and
            g2_y_c0_value == 0 and g2_y_c1_value == 0)
            G2.INFINITY
        else blk: {
            const x = Fp2Mont.initFromInt(g2_x_c0_value, g2_x_c1_value);
            const y = Fp2Mont.initFromInt(g2_y_c0_value, g2_y_c1_value);
            const z = Fp2Mont.ONE;
            break :blk try G2.init(&x, &y, &z);
        };

        // Compute pairing for this pair and accumulate
        const pair_result = try pairing(&g1_point, &g2_point);
        result = result.mul(&pair_result);
    }

    // Check if result equals 1 (identity element)
    return result.equal(&Fp12Mont.ONE);
}

// ============================================================================
// EIP-196/197 Test Vectors and Validation Tests
// ============================================================================

test "BN254 EIP-196 ECADD - add two points on curve" {
    // Test vector: G1 + G1 = 2*G1
    const gen = G1.GENERATOR;
    const gen_affine = gen.toAffine();

    var input: [128]u8 = undefined;
    @memset(&input, 0);

    // First point (generator)
    std.mem.writeInt(u256, input[0..32], gen_affine.x.value, .big);
    std.mem.writeInt(u256, input[32..64], gen_affine.y.value, .big);

    // Second point (generator)
    std.mem.writeInt(u256, input[64..96], gen_affine.x.value, .big);
    std.mem.writeInt(u256, input[96..128], gen_affine.y.value, .big);

    var output: [64]u8 = undefined;
    try bn254Add(&input, &output);

    // Parse result
    const result_x = std.mem.readInt(u256, output[0..32], .big);
    const result_y = std.mem.readInt(u256, output[32..64], .big);

    // Verify result equals 2*G1
    const expected = gen.double().toAffine();
    try std.testing.expectEqual(expected.x.value, result_x);
    try std.testing.expectEqual(expected.y.value, result_y);
}

test "BN254 EIP-196 ECADD - add point to infinity" {
    const gen = G1.GENERATOR.toAffine();

    var input: [128]u8 = undefined;
    @memset(&input, 0);

    // First point (generator)
    std.mem.writeInt(u256, input[0..32], gen.x.value, .big);
    std.mem.writeInt(u256, input[32..64], gen.y.value, .big);

    // Second point (infinity represented as (0,0))
    // Already zeroed

    var output: [64]u8 = undefined;
    try bn254Add(&input, &output);

    // Result should equal generator
    const result_x = std.mem.readInt(u256, output[0..32], .big);
    const result_y = std.mem.readInt(u256, output[32..64], .big);

    try std.testing.expectEqual(gen.x.value, result_x);
    try std.testing.expectEqual(gen.y.value, result_y);
}

test "BN254 EIP-196 ECADD - add two infinities" {
    var input: [128]u8 = undefined;
    @memset(&input, 0); // Both points are infinity

    var output: [64]u8 = undefined;
    try bn254Add(&input, &output);

    // Result should be infinity (0,0)
    for (output) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "BN254 EIP-196 ECADD - add point and its negation" {
    const gen = G1.GENERATOR.toAffine();
    const neg_gen = gen.neg().toAffine();

    var input: [128]u8 = undefined;
    @memset(&input, 0);

    // First point (generator)
    std.mem.writeInt(u256, input[0..32], gen.x.value, .big);
    std.mem.writeInt(u256, input[32..64], gen.y.value, .big);

    // Second point (negative generator)
    std.mem.writeInt(u256, input[64..96], neg_gen.x.value, .big);
    std.mem.writeInt(u256, input[96..128], neg_gen.y.value, .big);

    var output: [64]u8 = undefined;
    try bn254Add(&input, &output);

    // Result should be infinity (0,0)
    for (output) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "BN254 EIP-196 ECADD - invalid point returns error" {
    var input: [128]u8 = undefined;
    @memset(&input, 0);

    // Invalid point (1, 2) not on curve
    std.mem.writeInt(u256, input[0..32], 1, .big);
    std.mem.writeInt(u256, input[32..64], 2, .big);

    // Second point is infinity

    var output: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidPoint, bn254Add(&input, &output));
}

test "BN254 EIP-196 ECMUL - multiply by zero" {
    const gen = G1.GENERATOR.toAffine();

    var input: [96]u8 = undefined;
    @memset(&input, 0);

    // Point (generator)
    std.mem.writeInt(u256, input[0..32], gen.x.value, .big);
    std.mem.writeInt(u256, input[32..64], gen.y.value, .big);

    // Scalar is 0 (already zeroed)

    var output: [64]u8 = undefined;
    try bn254Mul(&input, &output);

    // Result should be infinity (0,0)
    for (output) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "BN254 EIP-196 ECMUL - multiply by one" {
    const gen = G1.GENERATOR.toAffine();

    var input: [96]u8 = undefined;
    @memset(&input, 0);

    // Point (generator)
    std.mem.writeInt(u256, input[0..32], gen.x.value, .big);
    std.mem.writeInt(u256, input[32..64], gen.y.value, .big);

    // Scalar is 1
    std.mem.writeInt(u256, input[64..96], 1, .big);

    var output: [64]u8 = undefined;
    try bn254Mul(&input, &output);

    // Result should equal generator
    const result_x = std.mem.readInt(u256, output[0..32], .big);
    const result_y = std.mem.readInt(u256, output[32..64], .big);

    try std.testing.expectEqual(gen.x.value, result_x);
    try std.testing.expectEqual(gen.y.value, result_y);
}

test "BN254 EIP-196 ECMUL - multiply by two" {
    const gen = G1.GENERATOR.toAffine();

    var input: [96]u8 = undefined;
    @memset(&input, 0);

    // Point (generator)
    std.mem.writeInt(u256, input[0..32], gen.x.value, .big);
    std.mem.writeInt(u256, input[32..64], gen.y.value, .big);

    // Scalar is 2
    std.mem.writeInt(u256, input[64..96], 2, .big);

    var output: [64]u8 = undefined;
    try bn254Mul(&input, &output);

    // Result should equal 2*G1
    const result_x = std.mem.readInt(u256, output[0..32], .big);
    const result_y = std.mem.readInt(u256, output[32..64], .big);

    const expected = G1.GENERATOR.double().toAffine();
    try std.testing.expectEqual(expected.x.value, result_x);
    try std.testing.expectEqual(expected.y.value, result_y);
}

test "BN254 EIP-196 ECMUL - multiply infinity by scalar" {
    var input: [96]u8 = undefined;
    @memset(&input, 0);

    // Point is infinity (0,0)
    // Scalar is 5
    std.mem.writeInt(u256, input[64..96], 5, .big);

    var output: [64]u8 = undefined;
    try bn254Mul(&input, &output);

    // Result should be infinity (0,0)
    for (output) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "BN254 EIP-196 ECMUL - multiply by curve order" {
    const gen = G1.GENERATOR.toAffine();

    var input: [96]u8 = undefined;
    @memset(&input, 0);

    // Point (generator)
    std.mem.writeInt(u256, input[0..32], gen.x.value, .big);
    std.mem.writeInt(u256, input[32..64], gen.y.value, .big);

    // Scalar is curve order (should give infinity)
    std.mem.writeInt(u256, input[64..96], FR_MOD, .big);

    var output: [64]u8 = undefined;
    try bn254Mul(&input, &output);

    // Result should be infinity (0,0)
    for (output) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "BN254 EIP-196 ECMUL - multiply by large scalar" {
    const gen = G1.GENERATOR.toAffine();
    const scalar: u256 = 123456789;

    var input: [96]u8 = undefined;
    @memset(&input, 0);

    // Point (generator)
    std.mem.writeInt(u256, input[0..32], gen.x.value, .big);
    std.mem.writeInt(u256, input[32..64], gen.y.value, .big);

    // Scalar
    std.mem.writeInt(u256, input[64..96], scalar, .big);

    var output: [64]u8 = undefined;
    try bn254Mul(&input, &output);

    // Verify result matches expected
    const expected = G1.GENERATOR.mulByInt(scalar).toAffine();
    const result_x = std.mem.readInt(u256, output[0..32], .big);
    const result_y = std.mem.readInt(u256, output[32..64], .big);

    try std.testing.expectEqual(expected.x.value, result_x);
    try std.testing.expectEqual(expected.y.value, result_y);
}

test "BN254 EIP-197 ECPAIRING - empty input" {
    const input: []const u8 = &[_]u8{};
    const result = try bn254Pairing(input);
    try std.testing.expect(result); // Empty input should return true
}

test "BN254 EIP-197 ECPAIRING - invalid input length" {
    // Input must be multiple of 192
    const input = [_]u8{0} ** 100;
    try std.testing.expectError(error.InvalidInput, bn254Pairing(&input));
}

test "BN254 EIP-197 ECPAIRING - single valid pairing" {
    // e(G1, G2) should not equal 1
    const g1 = G1.GENERATOR.toAffine();
    const g2 = G2.GENERATOR.toAffine();

    var input: [192]u8 = undefined;
    @memset(&input, 0);

    // G1 point
    std.mem.writeInt(u256, input[0..32], g1.x.value, .big);
    std.mem.writeInt(u256, input[32..64], g1.y.value, .big);

    // G2 point
    std.mem.writeInt(u256, input[64..96], g2.x.u0.value, .big);
    std.mem.writeInt(u256, input[96..128], g2.x.u1.value, .big);
    std.mem.writeInt(u256, input[128..160], g2.y.u0.value, .big);
    std.mem.writeInt(u256, input[160..192], g2.y.u1.value, .big);

    const result = try bn254Pairing(&input);
    try std.testing.expect(!result); // e(G1, G2) != 1
}

test "BN254 EIP-197 ECPAIRING - bilinearity check" {
    // e(aG1, bG2) = e(G1, G2)^(ab)
    // Verify: e(2G1, 3G2) * e(-6G1, G2) = 1
    const g1 = G1.GENERATOR;
    const g2 = G2.GENERATOR;

    const p1 = g1.mulByInt(2).toAffine();
    const p2 = g2.mulByInt(3).toAffine();
    const p3 = g1.mulByInt(6).neg().toAffine();
    const p4 = g2.toAffine();

    var input: [384]u8 = undefined;
    @memset(&input, 0);

    // First pair: (2G1, 3G2)
    std.mem.writeInt(u256, input[0..32], p1.x.value, .big);
    std.mem.writeInt(u256, input[32..64], p1.y.value, .big);
    std.mem.writeInt(u256, input[64..96], p2.x.u0.value, .big);
    std.mem.writeInt(u256, input[96..128], p2.x.u1.value, .big);
    std.mem.writeInt(u256, input[128..160], p2.y.u0.value, .big);
    std.mem.writeInt(u256, input[160..192], p2.y.u1.value, .big);

    // Second pair: (-6G1, G2)
    std.mem.writeInt(u256, input[192..224], p3.x.value, .big);
    std.mem.writeInt(u256, input[224..256], p3.y.value, .big);
    std.mem.writeInt(u256, input[256..288], p4.x.u0.value, .big);
    std.mem.writeInt(u256, input[288..320], p4.x.u1.value, .big);
    std.mem.writeInt(u256, input[320..352], p4.y.u0.value, .big);
    std.mem.writeInt(u256, input[352..384], p4.y.u1.value, .big);

    const result = try bn254Pairing(&input);
    try std.testing.expect(result); // Product should equal 1
}

test "BN254 EIP-197 ECPAIRING - with infinity points" {
    // e(0, G2) = 1
    const g2 = G2.GENERATOR.toAffine();

    var input: [192]u8 = undefined;
    @memset(&input, 0);

    // G1 point is infinity (0,0) - already zeroed

    // G2 point
    std.mem.writeInt(u256, input[64..96], g2.x.u0.value, .big);
    std.mem.writeInt(u256, input[96..128], g2.x.u1.value, .big);
    std.mem.writeInt(u256, input[128..160], g2.y.u0.value, .big);
    std.mem.writeInt(u256, input[160..192], g2.y.u1.value, .big);

    const result = try bn254Pairing(&input);
    try std.testing.expect(result); // e(0, G2) = 1
}

test "BN254 EIP-196 - scalar validation" {
    // Scalars must be less than the curve order
    const valid_scalar = FR_MOD - 1;
    const result = G1.GENERATOR.mulByInt(valid_scalar);
    try std.testing.expect(result.isOnCurve());

    // Maximum valid scalar
    const max_scalar = FR_MOD - 1;
    const result2 = G1.GENERATOR.mulByInt(max_scalar);
    try std.testing.expect(result2.isOnCurve());
}

test "BN254 point serialization - point at infinity" {
    const inf = G1.INFINITY;
    try std.testing.expect(inf.x.equal(&FpMont.ZERO));
    try std.testing.expect(inf.y.equal(&FpMont.ZERO));
    try std.testing.expect(inf.z.equal(&FpMont.ZERO));
}

test "BN254 point validation - generator has correct order" {
    const n_minus_1 = FR_MOD - 1;
    const result = G1.GENERATOR.mulByInt(n_minus_1);
    const neg_gen = G1.GENERATOR.neg();
    try std.testing.expect(result.equal(&neg_gen));
}

test "BN254 G1 cofactor test" {
    const gen = G1.GENERATOR;
    const order_mult = gen.mulByInt(FR_MOD);
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

        const by_mul = G1.GENERATOR.mulByInt(s);
        try std.testing.expect(by_doubling.equal(&by_mul));
    }
}

test "BN254 mixed addition (affine + projective)" {
    const affine_gen = G1.GENERATOR.toAffine();
    const proj_gen = G1.GENERATOR;

    const sum1 = affine_gen.add(&proj_gen);
    const sum2 = proj_gen.add(&affine_gen);

    try std.testing.expect(sum1.equal(&sum2));
    try std.testing.expect(sum1.isOnCurve());
}

test "BN254 scalar multiplication - windowing consistency" {
    const test_scalars = [_]u256{ 15, 31, 63, 127, 255, 511, 1023 };

    for (test_scalars) |scalar| {
        const result = G1.GENERATOR.mulByInt(scalar);

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

    const g1_a = G1.GENERATOR.mul(&a);
    const g2_b = G2.GENERATOR.mul(&b);

    const e1 = pairing(&g1_a, &G2.GENERATOR);
    const e_b = e1.pow(b.value);

    const e2 = pairing(&G1.GENERATOR, &g2_b);
    const e_a = e2.pow(a.value);

    try std.testing.expect(e_a.equal(&e_b));

    const e_ab = pairing(&G1.GENERATOR, &G2.GENERATOR).pow(ab.value);
    try std.testing.expect(e_ab.equal(&e_a));
}

test "BN254 negation preserves distance" {
    const scalar = Fr.init(42);
    const point = G1.GENERATOR.mul(&scalar);
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
        const g1_point = G1.GENERATOR.mulByInt(scalar);
        try std.testing.expect(g1_point.isOnCurve());

        const g2_point = G2.GENERATOR.mulByInt(scalar);
        try std.testing.expect(g2_point.isOnCurve());
    }
}
