const std = @import("std");
const FpMont = @import("FpMont.zig");
const Fr = @import("Fr.zig");
const curve_parameters = @import("curve_parameters.zig");

//G1 is the group of points on the elliptic curve y^2 = x^3 + 3
// We use the Jacobian projective coordinates to represent the points
pub const G1 = @This();
x: FpMont,
y: FpMont,
z: FpMont,

pub const INFINITY = curve_parameters.G1_INFINITY;
pub const GENERATOR = curve_parameters.G1_GENERATOR;

pub fn isInfinity(self: *const G1) bool {
    return self.z.value == 0;
}

// Unchecked constructor
pub fn initUnchecked(x: *const FpMont, y: *const FpMont, z: *const FpMont) G1 {
    return G1{ .x = x.*, .y = y.*, .z = z.* };
}

// Checked constructor - validates point is on curve
pub fn init(x: *const FpMont, y: *const FpMont, z: *const FpMont) !G1 {
    const point = G1{ .x = x.*, .y = y.*, .z = z.* };
    if (!point.isOnCurve()) {
        return error.InvalidPoint;
    }
    return point;
}

pub fn toAffine(self: *const G1) !G1 {
    if (self.isInfinity()) {
        return INFINITY;
    }
    // z should not be zero since we checked isInfinity above
    // If inv() fails, return error instead of panicking
    const z_inv = try self.z.inv();
    const z_inv_sq = z_inv.mul(&z_inv);
    const z_inv_cubed = z_inv_sq.mul(&z_inv);

    return G1{
        .x = self.x.mul(&z_inv_sq),
        .y = self.y.mul(&z_inv_cubed),
        .z = FpMont.ONE,
    };
}

pub fn isOnCurve(self: *const G1) bool {
    if (self.isInfinity()) return true;

    // BN254 Jacobian equation: Y² = X³ + 3Z⁶
    const y_squared = self.y.mul(&self.y);
    const x_cubed = self.x.mul(&self.x).mul(&self.x);
    const z_squared = self.z.mul(&self.z);
    const z_sixth = z_squared.mul(&z_squared).mul(&z_squared);
    const rhs = x_cubed.add(&z_sixth.mulBySmallInt(3));

    return y_squared.equal(&rhs);
}

pub fn neg(self: *const G1) G1 {
    return G1{
        .x = self.x,
        .y = self.y.neg(),
        .z = self.z,
    };
}

pub fn negAssign(self: *G1) void {
    self.* = self.neg();
}

pub fn equal(self: *const G1, other: *const G1) bool {
    const selfInf = self.isInfinity();
    const otherInf = other.isInfinity();

    if (selfInf and otherInf) {
        return true;
    }
    if (selfInf != otherInf) {
        return false;
    }

    // Both not infinity: cross-multiply to compare
    // For X coordinates: X1/Z1² = X2/Z2² => X1 * Z2² = X2 * Z1²
    const Z1_sq = self.z.mul(&self.z);
    const Z2_sq = other.z.mul(&other.z);
    const X1_Z2_sq = self.x.mul(&Z2_sq);
    const X2_Z1_sq = other.x.mul(&Z1_sq);

    // For Y coordinates: Y1/Z1³ = Y2/Z2³ => Y1 * Z2³ = Y2 * Z1³
    const Z1_cubed = Z1_sq.mul(&self.z);
    const Z2_cubed = Z2_sq.mul(&other.z);
    const Y1_Z2_cubed = self.y.mul(&Z2_cubed);
    const Y2_Z1_cubed = other.y.mul(&Z1_cubed);

    return X1_Z2_sq.equal(&X2_Z1_sq) and Y1_Z2_cubed.equal(&Y2_Z1_cubed);
}

pub fn sub(self: *const G1, other: *const G1) G1 {
    return self.add(&other.neg());
}

pub fn subAssign(self: *G1, other: *const G1) void {
    self.* = self.sub(other);
}

pub fn double(self: *const G1) G1 {
    // Compute intermediate values
    const X_squared = self.x.mul(&self.x); // X²
    const Y_squared = self.y.mul(&self.y); // Y²
    const Y_fourth = Y_squared.mul(&Y_squared); // Y⁴

    // S = 4XY²
    const S = self.x.mul(&Y_squared).mulBySmallInt(4);

    // M = 3X²
    const M = X_squared.mulBySmallInt(3);

    // X' = M² - 2S
    const M_squared = M.mul(&M);
    const two_S = S.mulBySmallInt(2);
    const x_result = M_squared.sub(&two_S);

    // Y' = M(S - X') - 8Y⁴
    const S_minus_X = S.sub(&x_result);

    //const eight_Y_fourth = Y_fourth.mul(&Fp.init(8));
    const eight_Y_fourth = Y_fourth.mulBySmallInt(8);

    const y_result = M.mul(&S_minus_X).sub(&eight_Y_fourth);

    // Z' = 2YZ
    const z_result = self.y.mul(&self.z).mulBySmallInt(2);

    return G1{ .x = x_result, .y = y_result, .z = z_result };
}

pub fn doubleAssign(self: *G1) void {
    self.* = self.double();
}

pub fn add(self: *const G1, other: *const G1) G1 {
    if (self.isInfinity()) {
        return other.*;
    }
    if (other.isInfinity()) {
        return self.*;
    }

    // Compute U1 = X1 * Z2² and U2 = X2 * Z1²
    const Z1_sq = self.z.mul(&self.z);
    const Z2_sq = other.z.mul(&other.z);
    const U1 = self.x.mul(&Z2_sq);
    const U2 = other.x.mul(&Z1_sq);

    // Compute S1 = Y1 * Z2³ and S2 = Y2 * Z1³
    const Z1_cubed = Z1_sq.mul(&self.z);
    const Z2_cubed = Z2_sq.mul(&other.z);
    const S1 = self.y.mul(&Z2_cubed);
    const S2 = other.y.mul(&Z1_cubed);

    // Check if points are equal or negatives
    if (U1.equal(&U2)) {
        if (S1.equal(&S2)) {
            return self.double();
        }
        return INFINITY;
    }

    // Compute H = U2 - U1 and R = S2 - S1
    const H = U2.sub(&U1);
    const R = S2.sub(&S1);

    // Compute H², H³, and intermediate values
    const H_sq = H.mul(&H);
    const H_cubed = H_sq.mul(&H);
    const U1_H_sq = U1.mul(&H_sq);

    // X3 = R² - H³ - 2*U1*H²
    const R_sq = R.mul(&R);
    const two_U1_H_sq = U1_H_sq.mulBySmallInt(2);
    const result_x = R_sq.sub(&H_cubed).sub(&two_U1_H_sq);

    // Y3 = R*(U1*H² - X3) - S1*H³
    const result_y = R.mul(&U1_H_sq.sub(&result_x)).sub(&S1.mul(&H_cubed));

    // Z3 = Z1 * Z2 * H
    const result_z = self.z.mul(&other.z).mul(&H);

    return G1{ .x = result_x, .y = result_y, .z = result_z };
}

pub fn addAssign(self: *G1, other: *const G1) void {
    self.* = self.add(other);
}

// GLV endomorphism phi(x, y) = (beta * x, y), where beta is a primitive cube
// root of unity in Fp. On G1, phi(P) = [lambda]P with lambda a cube root of
// unity in Fr; both constants live in curve_parameters.G1_SCALAR and are
// checked by the "G1 GLV constants" test below.
pub fn glsEndomorphism(self: *const G1) !G1 {
    if (self.isInfinity()) return INFINITY;
    const cube_root = FpMont.init(curve_parameters.G1_SCALAR.cube_root);
    const point_aff = try self.toAffine();
    return G1{
        .x = point_aff.x.mul(&cube_root),
        .y = point_aff.y,
        .z = FpMont.ONE,
    };
}

// Signed GLV decomposition: k = k1 + lambda * k2 (mod r) with |k1|, |k2| < 2^128.
pub const scalar_decomposition = struct {
    k1: i256,
    k2: i256,
};

/// Decomposes `scalar mod r` against the reduced lattice basis
/// v1 = (a1, b1), v2 = (a2, b2), with a1*b2 + b1*a2 = r,
/// a1 = lambda*b1 and a2 = -lambda*b2 (mod r).
/// With c1 = floor(b2*k/r) = b2*k/r - f1 and c2 = floor(b1*k/r) = b1*k/r - f2:
///   k1 = k - c1*a1 - c2*a2 = f1*a1 + f2*a2   in [0, a1 + a2)
///   k2 = c1*b1 - c2*b2     = f2*b2 - f1*b1   in (-b1, b2)
/// so both halves fit in 128 bits for every input, including adversarial ones
/// that drive k2 negative.
pub fn decomposeScalar(scalar: u256) scalar_decomposition {
    const r_mod = curve_parameters.FR_MOD;
    const k: i512 = @intCast(scalar % r_mod);
    const basis = curve_parameters.G1_SCALAR.lattice_basis;
    const v1 = basis[0];
    const v2 = basis[1];

    const c1 = @divFloor(@as(i512, v2.y) * k, r_mod);
    const c2 = @divFloor(@as(i512, v1.y) * k, r_mod);

    const k1 = k - c1 * @as(i512, v1.x) - c2 * @as(i512, v2.x);
    const k2 = c1 * @as(i512, v1.y) - c2 * @as(i512, v2.y);

    return scalar_decomposition{ .k1 = @intCast(k1), .k2 = @intCast(k2) };
}

// Left-to-right double-and-add for scalars below 2^128.
fn mulShort(self: *const G1, scalar: u128) G1 {
    var result = INFINITY;
    if (scalar == 0) return result;
    var i: u8 = 128 - @as(u8, @clz(scalar));
    while (i > 0) {
        i -= 1;
        result.doubleAssign();
        if ((scalar >> @as(u7, @intCast(i))) & 1 == 1) result.addAssign(self);
    }
    return result;
}

/// Scalar multiplication [scalar]P. G1 has cofactor 1, so every curve point
/// has order r and the scalar is reduced mod r first.
/// Scalars >= 2^128 use GLV: [k]P = [k1]P + [k2]phi(P), evaluated with
/// Shamir's trick over one shared ~128-bit doubling chain.
pub fn mulByInt(self: *const G1, scalar: u256) !G1 {
    const k = scalar % curve_parameters.FR_MOD;
    if (k == 0 or self.isInfinity()) return INFINITY;
    if (k == 1) return self.*;
    if (k < (@as(u256, 1) << 128)) return mulShort(self, @intCast(k));

    const decomposition = decomposeScalar(k);
    var p1 = self.*;
    if (decomposition.k1 < 0) p1.negAssign();
    var p2 = try self.glsEndomorphism();
    if (decomposition.k2 < 0) p2.negAssign();
    const k1: u128 = @intCast(@abs(decomposition.k1));
    const k2: u128 = @intCast(@abs(decomposition.k2));
    const p1_plus_p2 = p1.add(&p2);

    var result = INFINITY;
    const top = k1 | k2;
    if (top == 0) return result;
    var i: u8 = 128 - @as(u8, @clz(top));
    while (i > 0) {
        i -= 1;
        result.doubleAssign();
        const shift: u7 = @intCast(i);
        const bit1 = (k1 >> shift) & 1;
        const bit2 = (k2 >> shift) & 1;
        if (bit1 == 1 and bit2 == 1) {
            result.addAssign(&p1_plus_p2);
        } else if (bit1 == 1) {
            result.addAssign(&p1);
        } else if (bit2 == 1) {
            result.addAssign(&p2);
        }
    }
    return result;
}

pub fn mul(self: *const G1, scalar: *const Fr) !G1 {
    return try self.mulByInt(scalar.value);
}

pub fn mulAssign(self: *G1, scalar: *const Fr) !void {
    self.* = try self.mul(scalar);
}

// ============================================================================
// TESTS - Adapted from g1.zig for Montgomery form
// ============================================================================

test "G1.add opposite" {
    const Gen = G1.GENERATOR;
    const minusG = Gen.neg();
    const G_plus_minusG = Gen.add(&minusG);
    try std.testing.expect(G_plus_minusG.isInfinity());
}

test "G1.add" {
    const Gen = G1.GENERATOR;
    const Gen2 = G1{
        .x = FpMont.init(21888242871839275222246405745257275088696311157297823662689037894645226208560),
        .y = FpMont.init(21888242871839275222246405745257275088696311157297823662689037894645226208572),
        .z = FpMont.init(4),
    };
    const expected_result = G1{
        .x = FpMont.init(119872),
        .y = FpMont.init(21888242871839275222246405745257275088696311157297823662689037894645159203143),
        .z = FpMont.init(312),
    };
    try std.testing.expect(Gen.add(&Gen2).equal(&expected_result));
}

test "G1.double" {
    const Gen = G1.GENERATOR;
    const doubleG = Gen.double();
    const expected_result = G1{
        .x = FpMont.init(21888242871839275222246405745257275088696311157297823662689037894645226208560),
        .y = FpMont.init(21888242871839275222246405745257275088696311157297823662689037894645226208572),
        .z = FpMont.init(4),
    };

    try std.testing.expect(doubleG.equal(&expected_result));
}

test "G1.mul" {
    const Gen = G1.GENERATOR;
    const minus_G = try Gen.mul(&Fr.init(1).neg());
    const G_plus_minus_G = Gen.add(&minus_G);
    try std.testing.expect(G_plus_minus_G.isInfinity());
}

test "G1.isOnCurve generator" {
    const gen = G1.GENERATOR;
    try std.testing.expect(gen.isOnCurve());
}

test "G1.isOnCurve identity" {
    const identity = G1.INFINITY;
    try std.testing.expect(identity.isOnCurve());
}

test "G1.isOnCurve random point" {
    const k = 7; // example scalar
    const random_point = try G1.GENERATOR.mul(&Fr.init(k));
    try std.testing.expect(random_point.isOnCurve());
}

test "G1.equal generator to itself" {
    const gen = G1.GENERATOR;
    try std.testing.expect(gen.equal(&gen));
}

test "G1.equal different representations same point" {
    const gen = G1.GENERATOR;
    const scaled_gen = G1{
        .x = gen.x.mul(&FpMont.init(4)), // scale by 2²
        .y = gen.y.mul(&FpMont.init(8)), // scale by 2³
        .z = gen.z.mul(&FpMont.init(2)), // scale by 2
    };
    try std.testing.expect(gen.equal(&scaled_gen));
}

test "G1.toAffine random point" {
    const k = 13; // example scalar
    const random_point = try G1.GENERATOR.mul(&Fr.init(k));
    const affine = try random_point.toAffine();

    const expected_result = G1{
        .x = FpMont.init(2672242651313367459976336264061690128665099451055893690004467838496751824703),
        .y = FpMont.init(18247534626997477790812670345925575171672701304065784723769023620148097699216),
        .z = FpMont.ONE, // affine points have z = 1
    };

    try std.testing.expect(affine.equal(&expected_result));
    try std.testing.expect(affine.isOnCurve());
}

test "G1.add generator to identity" {
    const gen = G1.GENERATOR;
    const identity = G1.INFINITY;
    const result = gen.add(&identity);
    try std.testing.expect(result.equal(&gen));
}

test "G1.add random points" {
    const k1 = 3; // example scalar
    const k2 = 5; // example scalar
    const point1 = try G1.GENERATOR.mul(&Fr.init(k1));
    const point2 = try G1.GENERATOR.mul(&Fr.init(k2));
    const result = point1.add(&point2);

    const expected_result = G1{
        .x = FpMont.init(41677742803929195922238593),
        .y = FpMont.init(269065159484683478575364835230449703617),
        .z = FpMont.init(712815062608),
    };

    try std.testing.expect(result.equal(&expected_result));
    try std.testing.expect(result.isOnCurve());
}

test "G1.add commutativity" {
    const k1 = 11; // example scalar
    const k2 = 17; // example scalar
    const point1 = try G1.GENERATOR.mul(&Fr.init(k1));
    const point2 = try G1.GENERATOR.mul(&Fr.init(k2));

    const result1 = point1.add(&point2);
    const result2 = point2.add(&point1);
    try std.testing.expect(result1.equal(&result2));
}

test "G1.double identity" {
    const identity = G1.INFINITY;
    const result = identity.double();
    try std.testing.expect(result.isInfinity());
}

test "G1.double random point" {
    const k = 9; // example scalar
    const random_point = try G1.GENERATOR.mul(&Fr.init(k));
    const doubled = random_point.double();

    const expected_result = G1{
        .x = FpMont.init(16214338358589738794944521397038398142658042174982207107873684518498175669939),
        .y = FpMont.init(11686337248854933627526225912767414320106940505209835321155346996117578735613),
        .z = FpMont.init(2952297635626254264598100546197407825999396807330657291329469442697244479715),
    };

    try std.testing.expect(doubled.equal(&expected_result));
    try std.testing.expect(doubled.isOnCurve());
}

test "G1.chain operations" {
    const gen = G1.GENERATOR;
    const doubled = gen.double();
    const quadrupled = doubled.double();
    const gen_times_four = gen.add(&gen).add(&gen).add(&gen);
    try std.testing.expect(quadrupled.equal(&gen_times_four));
}

// Additional tests for assignment methods
test "G1.addAssign basic assignment" {
    var a = G1.GENERATOR;
    const b = G1.GENERATOR.double();
    const expected = a.add(&b);
    a.addAssign(&b);
    try std.testing.expect(a.equal(&expected));
}

test "G1.doubleAssign basic assignment" {
    var a = G1.GENERATOR;
    const expected = a.double();
    a.doubleAssign();
    try std.testing.expect(a.equal(&expected));
}

test "G1.negAssign basic assignment" {
    var a = G1.GENERATOR;
    const expected = a.neg();
    a.negAssign();
    try std.testing.expect(a.equal(&expected));
}

test "G1.mulAssign basic assignment" {
    var a = G1.GENERATOR;
    const scalar = Fr.init(7);
    const expected = try a.mul(&scalar);
    try a.mulAssign(&scalar);
    try std.testing.expect(a.equal(&expected));
}

test "G1.glsEndomorphism" {
    const gen = G1.GENERATOR;

    const test_values = [_]Fr{
        Fr.init(1),
        Fr.init(2654765),
        Fr.init(34567898765434567898765434567898765434567898765434567898765434567898765434567),
        Fr.init(45677654345678987654345678987654345678987654345678987654345678),
        Fr.init(5678456789876543456789876543456789876543456789876543456789876543456789),
    };

    for (test_values) |value| {
        const point = try gen.mul(&value);
        const endo = try point.glsEndomorphism();
        const point_times_lambda = try point.mul(&Fr.init(curve_parameters.G1_SCALAR.lambda));
        try std.testing.expect(point_times_lambda.equal(&endo));
    }
}


test "G1 GLV constants: beta, lambda, lattice basis, phi(G) == [lambda]G" {
    const p_mod = curve_parameters.FP_MOD;
    const r_mod = curve_parameters.FR_MOD;
    const beta_int = curve_parameters.G1_SCALAR.cube_root;
    const lambda_int = curve_parameters.G1_SCALAR.lambda;

    // beta is a non-trivial cube root of unity in Fp.
    const beta = FpMont.init(beta_int);
    try std.testing.expect(beta_int < p_mod);
    try std.testing.expect(!beta.equal(&FpMont.ONE));
    try std.testing.expect(beta.pow(3).equal(&FpMont.ONE));

    // lambda is a non-trivial cube root of unity in Fr.
    try std.testing.expect(lambda_int < r_mod);
    try std.testing.expect(lambda_int != 1);
    const lambda_wide: u512 = lambda_int;
    const lambda_sq = (lambda_wide * lambda_wide) % r_mod;
    try std.testing.expectEqual(@as(u512, 1), (lambda_sq * lambda_wide) % r_mod);

    // Lattice basis: a1 - lambda*b1 = 0, a2 + lambda*b2 = 0 (mod r), det = r.
    const basis = curve_parameters.G1_SCALAR.lattice_basis;
    const lambda_signed: i512 = @intCast(lambda_int);
    const r_signed: i512 = @intCast(r_mod);
    try std.testing.expectEqual(@as(i512, 0), @mod(@as(i512, basis[0].x) - lambda_signed * basis[0].y, r_signed));
    try std.testing.expectEqual(@as(i512, 0), @mod(@as(i512, basis[1].x) + lambda_signed * basis[1].y, r_signed));
    try std.testing.expectEqual(r_signed, @as(i512, basis[0].x) * basis[1].y + @as(i512, basis[0].y) * basis[1].x);

    // phi(G) = (beta * 1, 2) must equal [lambda]G computed by plain
    // double-and-add over all 256 bits (independent of the GLV path).
    var reference = G1.INFINITY;
    var i: u16 = 256;
    while (i > 0) {
        i -= 1;
        reference.doubleAssign();
        if ((lambda_int >> @as(u8, @intCast(i))) & 1 == 1) reference.addAssign(&G1.GENERATOR);
    }
    const phi = try G1.GENERATOR.glsEndomorphism();
    const expected_phi = G1{ .x = FpMont.init(beta_int), .y = FpMont.init(2), .z = FpMont.ONE };
    try std.testing.expect(phi.equal(&expected_phi));
    try std.testing.expect(reference.equal(&phi));
    const via_mul = try G1.GENERATOR.mulByInt(lambda_int);
    try std.testing.expect(via_mul.equal(&phi));
}

test "G1 GLV glsEndomorphism of infinity is infinity" {
    const result = try G1.INFINITY.glsEndomorphism();
    try std.testing.expect(result.isInfinity());
}

test "G1 GLV decomposeScalar recomposes and stays within 128 bits" {
    const r_mod = curve_parameters.FR_MOD;
    const lambda: i512 = @intCast(curve_parameters.G1_SCALAR.lambda);
    const bound: i256 = @as(i256, 1) << 128;
    var prng = std.Random.DefaultPrng.init(0x0b254_617c);
    const random = prng.random();
    const fixed = [_]u256{
        0,
        1,
        2,
        r_mod - 1,
        r_mod,
        r_mod + 1,
        @as(u256, 1) << 128,
        (@as(u256, 1) << 255) - 1,
        std.math.maxInt(u256),
        // Makes k2 negative: floor(b2*k/r) has fractional part 1/r.
        0x30644e72e131a02850c6967bfe2f29ac703b66375e9e1b409038b08cbe50a2a0,
    };
    var saw_negative = false;
    for (0..fixed.len + 1000) |n| {
        const k = if (n < fixed.len) fixed[n] else random.int(u256);
        const d = G1.decomposeScalar(k);
        try std.testing.expect(d.k1 > -bound and d.k1 < bound);
        try std.testing.expect(d.k2 > -bound and d.k2 < bound);
        if (d.k1 < 0 or d.k2 < 0) saw_negative = true;
        const recomposed = @mod(@as(i512, d.k1) + lambda * @as(i512, d.k2), @as(i512, @intCast(r_mod)));
        try std.testing.expectEqual(@as(i512, @intCast(k % r_mod)), recomposed);
    }
    try std.testing.expect(saw_negative);
}

test "G1 GLV mulByInt matches naive double-and-add" {
    const r_mod = curve_parameters.FR_MOD;
    var prng = std.Random.DefaultPrng.init(0x61_76_5f_6d_75_6c);
    const random = prng.random();
    const fixed = [_]u256{
        0,
        1,
        2,
        3,
        r_mod - 1,
        r_mod,
        r_mod + 1,
        (@as(u256, 1) << 128) - 1,
        @as(u256, 1) << 128,
        (@as(u256, 1) << 255) - 1,
        std.math.maxInt(u256),
        0x30644e72e131a02850c6967bfe2f29ac703b66375e9e1b409038b08cbe50a2a0,
    };
    const bases = [_]G1{ G1.GENERATOR, G1.GENERATOR.double().add(&G1.GENERATOR) };
    for (bases) |base| {
        for (0..fixed.len + 100) |n| {
            const k = if (n < fixed.len) fixed[n] else random.int(u256);
            // Naive reference: double-and-add over all 256 bits, no reduction.
            var expected = G1.INFINITY;
            var i: u16 = 256;
            while (i > 0) {
                i -= 1;
                expected.doubleAssign();
                if ((k >> @as(u8, @intCast(i))) & 1 == 1) expected.addAssign(&base);
            }
            const actual = try base.mulByInt(k);
            try std.testing.expect(actual.equal(&expected));
            try std.testing.expect(actual.isOnCurve());
        }
    }
    const at_infinity = try G1.INFINITY.mulByInt(r_mod - 1);
    try std.testing.expect(at_infinity.isInfinity());
}
