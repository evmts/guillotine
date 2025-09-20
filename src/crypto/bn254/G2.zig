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

pub fn isInSubgroup(self: *const G2) bool {
    // For BN254, G2 points are in the correct subgroup if [r]P = O
    // where r is the order of the scalar field (FR_MOD) and O is infinity

    // If point is infinity, it's in the subgroup
    if (self.isInfinity()) {
        return true;
    }

    // Create Fr element from curve order
    const r = Fr{ .value = curve_parameters.FR_MOD };

    // Check if [r]P = O (infinity)
    const r_times_p = self.mul(&r);
    return r_times_p.isInfinity();
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
