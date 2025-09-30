const FpMont = @import("FpMont.zig");
const Fp2Mont = @import("Fp2Mont.zig");
const Fr = @import("Fr.zig");
const curve_parameters = @import("curve_parameters.zig");

pub const G2 = @This();
x: Fp2Mont,
y: Fp2Mont,
z: Fp2Mont,

pub const INFINITY = curve_parameters.G2_INFINITY;
pub const GENERATOR = curve_parameters.G2_GENERATOR;

pub const FROBENIUS_X_COEFF = curve_parameters.FROBENIUS_G2_X_COEFF;
pub const FROBENIUS_Y_COEFF = curve_parameters.FROBENIUS_G2_Y_COEFF;

pub fn isInfinity(self: *const G2) bool {
    return self.z.u0.value == 0 and self.z.u1.value == 0;
}

pub fn initUnchecked(x: *const Fp2Mont, y: *const Fp2Mont, z: *const Fp2Mont) G2 {
    return G2{ .x = x.*, .y = y.*, .z = z.* };
}

// Checked constructor - validates point is on curve
// WARNING: DOES NOT CHECK IF POINT IS IN RIGHT SUBGROUP
pub fn init(x: *const Fp2Mont, y: *const Fp2Mont, z: *const Fp2Mont) !G2 {
    const point = G2{ .x = x.*, .y = y.*, .z = z.* };
    if (!point.isOnCurve()) {
        return error.InvalidPoint;
    }
    return point;
}

pub fn toAffine(self: *const G2) G2 {
    if (self.isInfinity()) {
        return INFINITY;
    }
    const z_inv = self.z.inv() catch unreachable;
    const z_inv_sq = z_inv.mul(&z_inv);
    const z_inv_cubed = z_inv_sq.mul(&z_inv);

    return G2{
        .x = self.x.mul(&z_inv_sq),
        .y = self.y.mul(&z_inv_cubed),
        .z = Fp2Mont.ONE,
    };
}

pub fn isOnCurve(self: *const G2) bool {
    if (self.isInfinity()) return true;
    const xi = curve_parameters.XI;
    const xi_inv = xi.inv() catch unreachable;
    const z_factor = Fp2Mont.init_from_int(3, 0).mul(&xi_inv);

    // BN254 Jacobian equation: Y² = X³ + (3/xi)Z⁶
    const y_squared = self.y.mul(&self.y);
    const x_cubed = self.x.mul(&self.x).mul(&self.x);
    const z_squared = self.z.mul(&self.z);
    const z_sixth = z_squared.mul(&z_squared).mul(&z_squared);
    const rhs = x_cubed.add(&z_sixth.mul(&z_factor));

    return y_squared.equal(&rhs);
}

pub fn mulByCurveParamT(self: *const G2) G2 {
    var result = INFINITY;
    var base = self.*;
    //var exp: u64 = curve_parameters.CURVE_PARAM_T;
    const exp = curve_parameters.CURVE_PARAM_T_NAF;
    for (exp) |bit| {
        if (bit == 1) {
            result.addAssign(&base);
        } else if (bit == -1) {
            result.addAssign(&base.neg());
        }
        base.doubleAssign();
    }
    return result;
}

pub fn isInSubgroup(self: *const G2) bool {
    // For BN254, G2 points are in the correct subgroup if [r]P = O
    // where r is the order of the scalar field (FR_MOD) and O is infinity
    // you can reduce this to a smaller exponent check by using the frobenius map
    // we use the shortest vector as given by https://eprint.iacr.org/2022/348.pdf

    // If point is infinity, it's in the subgroup
    if (self.isInfinity()) {
        return true;
    }

    if (!self.isOnCurve()) {
        return false;
    }

    const point_times_t = self.mulByCurveParamT();
    const point_times_2t = point_times_t.double();
    const point_times_tp1 = point_times_t.add(self);

    const lhs = point_times_tp1
        .add(&point_times_t.frobenius())
        .add(&point_times_t.frobenius().frobenius());
    const rhs = point_times_2t.frobenius().frobenius().frobenius();

    return lhs.equal(&rhs);
}

pub fn neg(self: *const G2) G2 {
    return G2{
        .x = self.x,
        .y = self.y.neg(),
        .z = self.z,
    };
}

pub fn negAssign(self: *G2) void {
    self.* = self.neg();
}

pub fn equal(self: *const G2, other: *const G2) bool {
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

pub fn double(self: *const G2) G2 {
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
    const eight_Y_fourth = Y_fourth.mulBySmallInt(8);
    const y_result = M.mul(&S_minus_X).sub(&eight_Y_fourth);

    // Z' = 2YZ
    const z_result = self.y.mul(&self.z).mulBySmallInt(2);

    return G2{ .x = x_result, .y = y_result, .z = z_result };
}

pub fn doubleAssign(self: *G2) void {
    self.* = self.double();
}

pub fn add(self: *const G2, other: *const G2) G2 {
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

    return G2{ .x = result_x, .y = result_y, .z = result_z };
}

pub fn addAssign(self: *G2, other: *const G2) void {
    self.* = self.add(other);
}

const ScalarDecomposition = struct {
    k1: i70,
    k2: i70,
    k3: i70,
    k4: i70,
};

pub fn decomposeScalar(scalar: u256) ScalarDecomposition {
    const k: i512 = @intCast(scalar);
    const params = curve_parameters.G2_SCALAR;
    const r_mod = @as(i512, @intCast(curve_parameters.FR_MOD));
    const coeffs = params.projection_coeffs;

    const b1 = @divTrunc(coeffs[0] * k, r_mod);
    const b2 = @divTrunc(coeffs[1] * k, r_mod);
    const b3 = @divTrunc(coeffs[2] * k, r_mod);
    const b4 = @divTrunc(coeffs[3] * k, r_mod);

    const basis = params.lattice_basis;
    const v1 = basis[0];
    const v2 = basis[1];
    const v3 = basis[2];
    const v4 = basis[3];

    const k1 = k - b1 * @as(i512, v1[0]) - b2 * @as(i512, v2[0]) - b3 * @as(i512, v3[0]) - b4 * @as(i512, v4[0]);
    const k2 = -b1 * @as(i512, v1[1]) - b2 * @as(i512, v2[1]) - b3 * @as(i512, v3[1]) - b4 * @as(i512, v4[1]);
    const k3 = -b1 * @as(i512, v1[2]) - b2 * @as(i512, v2[2]) - b3 * @as(i512, v3[2]) - b4 * @as(i512, v4[2]);
    const k4 = -b1 * @as(i512, v1[3]) - b2 * @as(i512, v2[3]) - b3 * @as(i512, v3[3]) - b4 * @as(i512, v4[3]);

    return ScalarDecomposition{
        .k1 = @intCast(k1),
        .k2 = @intCast(k2),
        .k3 = @intCast(k3),
        .k4 = @intCast(k4),
    };
}

pub fn mul(self: *const G2, scalar: *const Fr) G2 {
    return self.mul_by_int(scalar.value);
}

pub fn mul_by_int(self: *const G2, scalar: u256) G2 {
    if (self.isInfinity() or scalar == 0) {
        return INFINITY;
    }

    const decomposition = decomposeScalar(scalar);

    var base_points = [4]G2{
        self.*,
        self.lambda_endomorphism(),
        self.gamma_endomorphism(),
        self.gamma_lambda_endomorphism(),
    };

    if (decomposition.k1 < 0) base_points[0].negAssign();
    if (decomposition.k2 < 0) base_points[1].negAssign();
    if (decomposition.k3 < 0) base_points[2].negAssign();
    if (decomposition.k4 < 0) base_points[3].negAssign();

    const precomputed_points = init_precomputed_points(&base_points);

    const k1_abs: u70 = @intCast(@abs(decomposition.k1));
    const k2_abs: u70 = @intCast(@abs(decomposition.k2));
    const k3_abs: u70 = @intCast(@abs(decomposition.k3));
    const k4_abs: u70 = @intCast(@abs(decomposition.k4));

    const window_bits: usize = 70;
    var result = INFINITY;
    var i: usize = 0;
    while (i < window_bits) : (i += 1) {
        result.doubleAssign();
        const bit_index: u7 = @intCast(window_bits - 1 - i);
        const prec_index = get_precomputed_index(k1_abs, k2_abs, k3_abs, k4_abs, bit_index);
        if (prec_index != 0) {
            result.addAssign(&precomputed_points[prec_index]);
        }
    }

    return result;
}

fn get_precomputed_index(k1: u70, k2: u70, k3: u70, k4: u70, i: u7) u4 {
    const k4_bit = @as(u4, @intCast((k4 >> i) & 1));
    const k3_bit = @as(u4, @intCast((k3 >> i) & 1));
    const k2_bit = @as(u4, @intCast((k2 >> i) & 1));
    const k1_bit = @as(u4, @intCast((k1 >> i) & 1));
    return k4_bit << 3 | k3_bit << 2 | k2_bit << 1 | k1_bit;
}

fn init_precomputed_points(points: *const [4]G2) [16]G2 {
    var result: [16]G2 = undefined;
    result[0] = INFINITY;
    inline for (0..4) |i| {
        const current_size = 1 << i;
        for (0..current_size) |j| {
            result[current_size + j] = result[j].add(&points[i]);
        }
    }
    return result;
}

pub fn mulAssign(self: *G2, scalar: *const Fr) void {
    self.* = self.mul(scalar);
}

pub fn frobenius(self: *const G2) G2 {
    return G2{
        .x = self.x.frobeniusMap().mul(&FROBENIUS_X_COEFF),
        .y = self.y.frobeniusMap().mul(&FROBENIUS_Y_COEFF),
        .z = self.z.frobeniusMap(),
    };
}

pub fn lambda_endomorphism(self: *const G2) G2 {
    const cube_root = FpMont.init(curve_parameters.G2_SCALAR.cube_root);

    const self_aff = self.toAffine();
    return G2{
        .x = self_aff.x.scalarMul(&cube_root),
        .y = self_aff.y,
        .z = Fp2Mont.ONE,
    };
}

pub fn gamma_endomorphism(self: *const G2) G2 {
    return self.frobenius().frobenius().frobenius();
}

pub fn gamma_lambda_endomorphism(self: *const G2) G2 {
    return self.gamma_endomorphism().lambda_endomorphism();
}

const std = @import("std");

test "G2.isOnCurve generator" {
    try std.testing.expect(G2.GENERATOR.isOnCurve());
}

test "G2.isOnCurve identity" {
    try std.testing.expect(G2.INFINITY.isOnCurve());
}

test "G2.isOnCurve multiples" {
    const scalars = [_]u256{ 2, 3, 7, 13, 27 };
    for (scalars) |k| {
        var scalar = Fr.init(k);
        const point = G2.GENERATOR.mul(&scalar);
        try std.testing.expect(point.isOnCurve());
    }
}

test "G2.curve order annihilates subgroup points" {
    const order = curve_parameters.FR_MOD;
    const scalars = [_]u256{ 1, 5, 9, 33, 101 };
    for (scalars) |k| {
        var scalar = Fr.init(k);
        const point = G2.GENERATOR.mul(&scalar);
        const multiple = point.mul_by_int(order);
        try std.testing.expect(multiple.isInfinity());
    }
}

test "G2.isInSubgroup generator multiples" {
    const scalars = [_]u256{ 1, 7, 19, 123, 98765 };
    for (scalars) |k| {
        var scalar = Fr.init(k);
        const point = G2.GENERATOR.mul(&scalar);
        try std.testing.expect(point.isInSubgroup());
    }
}

test "G2.isInSubgroup non subgroup point" {
    const x = Fp2Mont{ .u0 = FpMont{ .value = 122 }, .u1 = FpMont{ .value = 3333 } };
    const y = Fp2Mont{ .u0 = FpMont{ .value = 4562906498667794019468448659772613644715180855375958127421599247974276735405 }, .u1 = FpMont{ .value = 11306249705311604911826567979787687424320829738512421461876664403170710609448 } };
    const z = Fp2Mont.ONE;
    const point = G2.initUnchecked(&x, &y, &z);
    try std.testing.expect(point.isOnCurve());
    try std.testing.expect(!point.isInSubgroup());
}

test "G2.equal different representations same point" {
    var scalar = Fr.init(11);
    const point = G2.GENERATOR.mul(&scalar);
    const scale = Fp2Mont.init_from_int(5, 0);
    const scale_sq = scale.mul(&scale);
    const scale_cu = scale_sq.mul(&scale);
    const scaled = G2{
        .x = point.x.mul(&scale_sq),
        .y = point.y.mul(&scale_cu),
        .z = point.z.mul(&scale),
    };
    try std.testing.expect(point.equal(&scaled));
}

test "G2.toAffine normalizes coordinates" {
    var scalar = Fr.init(19);
    const projective = G2.GENERATOR.mul(&scalar);
    const affine = projective.toAffine();
    try std.testing.expect(affine.z.equal(&Fp2Mont.ONE));
    try std.testing.expect(projective.equal(&affine));
    try std.testing.expect(affine.isOnCurve());
}

test "G2.add inverse gives infinity" {
    var scalar = Fr.init(23);
    const point = G2.GENERATOR.mul(&scalar);
    const inverse = point.neg();
    const sum = point.add(&inverse);
    try std.testing.expect(sum.isInfinity());
}

test "G2.add commutativity" {
    var s1 = Fr.init(9);
    var s2 = Fr.init(17);
    const p1 = G2.GENERATOR.mul(&s1);
    const p2 = G2.GENERATOR.mul(&s2);
    const left = p1.add(&p2);
    const right = p2.add(&p1);
    try std.testing.expect(left.equal(&right));
}

test "G2.add associativity" {
    var s1 = Fr.init(5);
    var s2 = Fr.init(11);
    var s3 = Fr.init(19);
    const p1 = G2.GENERATOR.mul(&s1);
    const p2 = G2.GENERATOR.mul(&s2);
    const p3 = G2.GENERATOR.mul(&s3);

    var left = p1.add(&p2);
    left.addAssign(&p3);
    var right = p2.add(&p3);
    right.addAssign(&p1);
    try std.testing.expect(left.equal(&right));
}

test "G2.double matches add self" {
    var scalar = Fr.init(29);
    const point = G2.GENERATOR.mul(&scalar);
    const doubled = point.double();
    const sum = point.add(&point);
    try std.testing.expect(doubled.equal(&sum));
}

test "G2.assignment helpers" {
    var s1 = Fr.init(7);
    var s2 = Fr.init(13);
    var p = G2.GENERATOR.mul(&s1);
    const q = G2.GENERATOR.mul(&s2);

    const add_expected = p.add(&q);
    p.addAssign(&q);
    try std.testing.expect(p.equal(&add_expected));

    p = G2.GENERATOR.mul(&s1);
    const double_expected = p.double();
    p.doubleAssign();
    try std.testing.expect(p.equal(&double_expected));

    p = G2.GENERATOR.mul(&s1);
    const neg_expected = p.neg();
    p.negAssign();
    try std.testing.expect(p.equal(&neg_expected));

    p = G2.GENERATOR.mul(&s1);
    var scalar = Fr.init(21);
    const mul_expected = p.mul(&scalar);
    p.mulAssign(&scalar);
    try std.testing.expect(p.equal(&mul_expected));
}

test "G2.mul matches naive ladder" {
    const scalars = [_]u256{ 0, 1, 2, 3, 5, 9, 15, 37 };
    for (scalars) |k| {
        var expected = INFINITY;
        var addend = G2.GENERATOR;
        var tmp = k;
        while (tmp != 0) : (tmp >>= 1) {
            if ((tmp & 1) == 1) {
                expected = expected.add(&addend);
            }
            addend = addend.double();
        }
        const actual = G2.GENERATOR.mul_by_int(k);
        try std.testing.expect(expected.equal(&actual));
    }
}

test "G2.mul edge cases" {
    const zero = G2.GENERATOR.mul_by_int(0);
    try std.testing.expect(zero.isInfinity());

    const one = G2.GENERATOR.mul_by_int(1);
    try std.testing.expect(one.equal(&G2.GENERATOR));

    const near_order = curve_parameters.FR_MOD - 1;
    const neg_point = G2.GENERATOR.neg();
    const result = G2.GENERATOR.mul_by_int(near_order);
    try std.testing.expect(result.equal(&neg_point));
}

test "G2.distributivity over addition" {
    var s1 = Fr.init(8);
    var s2 = Fr.init(21);
    const scalar = Fr.init(17);
    const p = G2.GENERATOR.mul(&s1);
    const q = G2.GENERATOR.mul(&s2);

    const lhs = p.mul(&scalar).add(&q.mul(&scalar));
    const rhs = p.add(&q).mul(&scalar);
    try std.testing.expect(lhs.equal(&rhs));
}

test "G2.lambda endomorphism equals multiplication by lambda" {
    const lambda = Fr{ .value = curve_parameters.G2_SCALAR.lambda };
    const scalars = [_]u256{ 1, 3, 17, 55, 1234 };
    for (scalars) |k| {
        var scalar = Fr.init(k);
        const point = G2.GENERATOR.mul(&scalar);
        const by_lambda = point.mul(&lambda);
        const endo = point.lambda_endomorphism();
        try std.testing.expect(by_lambda.equal(&endo));
    }
}

test "G2.gamma endomorphism equals multiplication by gamma" {
    const gamma = Fr{ .value = curve_parameters.G2_SCALAR.gamma };
    const scalars = [_]u256{ 2, 9, 27, 91 };
    for (scalars) |k| {
        var scalar = Fr.init(k);
        const point = G2.GENERATOR.mul(&scalar);
        const by_gamma = point.mul(&gamma);
        const endo = point.gamma_endomorphism();
        try std.testing.expect(by_gamma.equal(&endo));
    }
}

test "G2.gamma lambda endomorphism equals multiplication by gamma lambda" {
    const gamma_lambda = Fr{ .value = curve_parameters.G2_SCALAR.gamma_lambda };
    const scalars = [_]u256{ 4, 13, 29, 123 };
    for (scalars) |k| {
        var scalar = Fr.init(k);
        const point = G2.GENERATOR.mul(&scalar);
        const composed = point.gamma_endomorphism().lambda_endomorphism();
        const by_gamma_lambda = point.mul(&gamma_lambda);
        const direct = point.gamma_lambda_endomorphism();
        try std.testing.expect(by_gamma_lambda.equal(&direct));
        try std.testing.expect(composed.equal(&direct));
    }
}

test "G2.frobenius has order 12" {
    var scalar = Fr.init(15);
    const point = G2.GENERATOR.mul(&scalar);
    var iter = point;
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        iter = iter.frobenius();
        try std.testing.expect(iter.isOnCurve());
    }
    try std.testing.expect(iter.equal(&point));
}

test "G2.decomposeScalar recomposes original" {
    const scalars = [_]Fr{
        Fr.init(1),
        Fr.init(56789),
        Fr.init(9876543210),
        Fr.init(curve_parameters.FR_MOD - 5),
        Fr.init(curve_parameters.FR_MOD / 2 + 12345),
    };

    const lambda = @as(i512, @intCast(curve_parameters.G2_SCALAR.lambda));
    const gamma = @as(i512, @intCast(curve_parameters.G2_SCALAR.gamma));
    const gamma_lambda = @as(i512, @intCast(curve_parameters.G2_SCALAR.gamma_lambda));
    const modulus = @as(i512, @intCast(curve_parameters.FR_MOD));

    for (scalars) |scalar_val| {
        const decomposition = G2.decomposeScalar(scalar_val.value);
        const k1 = @as(i512, decomposition.k1);
        const k2 = @as(i512, decomposition.k2);
        const k3 = @as(i512, decomposition.k3);
        const k4 = @as(i512, decomposition.k4);

        var acc = k1;
        acc += lambda * k2;
        acc += gamma * k3;
        acc += gamma_lambda * k4;

        var reconstructed = @mod(acc, modulus);
        if (reconstructed < 0) {
            reconstructed += modulus;
        }
        const expected = @as(i512, @intCast(scalar_val.value));
        try std.testing.expect(reconstructed == expected);
    }
}
