const FpMont = @import("FpMont.zig");
const Fp2Mont = @import("Fp2Mont.zig");
const curve_parameters = @import("curve_parameters.zig");

//
// Field extension: F_p6 = F_p2[v] / (v^3 - ξ) where ξ = 9 + u ∈ F_p2
// Elements: a = a0 + a1*v + a2*v^2, where a0, a1, a2 ∈ F_p2 and v^3 = 9 + u
//

pub const Fp6Mont = @This();

v0: Fp2Mont,
v1: Fp2Mont,
v2: Fp2Mont,

pub const ZERO = Fp6Mont{ .v0 = Fp2Mont.ZERO, .v1 = Fp2Mont.ZERO, .v2 = Fp2Mont.ZERO };
pub const ONE = Fp6Mont{ .v0 = Fp2Mont.ONE, .v1 = Fp2Mont.ZERO, .v2 = Fp2Mont.ZERO };

pub fn init(val_v0: *const Fp2Mont, val_v1: *const Fp2Mont, val_v2: *const Fp2Mont) Fp6Mont {
    return Fp6Mont{
        .v0 = val_v0.*,
        .v1 = val_v1.*,
        .v2 = val_v2.*,
    };
}

pub fn init_from_int(v0_real: u256, v0_imag: u256, v1_real: u256, v1_imag: u256, v2_real: u256, v2_imag: u256) Fp6Mont {
    return Fp6Mont{
        .v0 = Fp2Mont.init_from_int(v0_real, v0_imag),
        .v1 = Fp2Mont.init_from_int(v1_real, v1_imag),
        .v2 = Fp2Mont.init_from_int(v2_real, v2_imag),
    };
}

pub fn add(self: *const Fp6Mont, other: *const Fp6Mont) Fp6Mont {
    return Fp6Mont{
        .v0 = self.v0.add(&other.v0),
        .v1 = self.v1.add(&other.v1),
        .v2 = self.v2.add(&other.v2),
    };
}

pub fn addAssign(self: *Fp6Mont, other: *const Fp6Mont) void {
    self.* = self.add(other);
}

pub fn neg(self: *const Fp6Mont) Fp6Mont {
    return Fp6Mont{
        .v0 = self.v0.neg(),
        .v1 = self.v1.neg(),
        .v2 = self.v2.neg(),
    };
}

pub fn negAssign(self: *Fp6Mont) void {
    self.* = self.neg();
}

pub fn sub(self: *const Fp6Mont, other: *const Fp6Mont) Fp6Mont {
    return Fp6Mont{
        .v0 = self.v0.sub(&other.v0),
        .v1 = self.v1.sub(&other.v1),
        .v2 = self.v2.sub(&other.v2),
    };
}

pub fn subAssign(self: *Fp6Mont, other: *const Fp6Mont) void {
    self.* = self.sub(other);
}

pub fn mulByV(self: *const Fp6Mont) Fp6Mont {
    const xi = curve_parameters.XI;
    return Fp6Mont{
        .v0 = self.v2.mul(&xi),
        .v1 = self.v0,
        .v2 = self.v1,
    };
}

/// Karatsuba multiplication: (a0 + a1*v + a2*v²)(b0 + b1*v + b2*v²) mod (v³ - ξ)
/// Reference: https://en.wikipedia.org/wiki/Karatsuba_algorithm
pub fn mul(self: *const Fp6Mont, other: *const Fp6Mont) Fp6Mont {
    // a = a0 + a1*v + a2*v², b = b0 + b1*v + b2*v², ξ = 9 + u ∈ F_p2
    const xi = curve_parameters.XI;

    // Direct products: a_i * b_i
    const a0_b0 = self.v0.mul(&other.v0);
    const a1_b1 = self.v1.mul(&other.v1);
    const a2_b2 = self.v2.mul(&other.v2);

    // Karatsuba cross-products: (a_i + a_j)(b_i + b_j)
    const t0 = self.v1.add(&self.v2).mul(&other.v1.add(&other.v2)); // (a1+a2)(b1+b2)
    const t1 = self.v0.add(&self.v1).mul(&other.v0.add(&other.v1)); // (a0+a1)(b0+b1)
    const t2 = self.v0.add(&self.v2).mul(&other.v0.add(&other.v2)); // (a0+a2)(b0+b2)

    // Extract cross-terms: t_i - direct products
    const a1_b2_plus_a2_b1 = t0.sub(&a1_b1).sub(&a2_b2); // a1*b2 + a2*b1
    const a0_b1_plus_a1_b0 = t1.sub(&a0_b0).sub(&a1_b1); // a0*b1 + a1*b0
    const a0_b2_plus_a2_b0 = t2.sub(&a0_b0).sub(&a2_b2); // a0*b2 + a2*b0

    // Final result with ξ = 9 + u reduction: v³ ≡ ξ
    const c0 = a0_b0.add(&xi.mul(&a1_b2_plus_a2_b1)); // a0*b0 + ξ*(a1*b2 + a2*b1)
    const c1 = a0_b1_plus_a1_b0.add(&xi.mul(&a2_b2)); // (a0*b1 + a1*b0) + ξ*a2*b2
    const c2 = a0_b2_plus_a2_b0.add(&a1_b1); // (a0*b2 + a2*b0) + a1*b1

    return Fp6Mont{
        .v0 = c0,
        .v1 = c1,
        .v2 = c2,
    };
}

pub fn mulAssign(self: *Fp6Mont, other: *const Fp6Mont) void {
    self.* = self.mul(other);
}

//we use double and add to multiply by a small integer
pub fn mulBySmallInt(self: *const Fp6Mont, other: u8) Fp6Mont {
    var result = ZERO;
    var base = self.*;
    var exp = other;
    while (exp > 0) : (exp >>= 1) {
        if (exp & 1 == 1) {
            result.addAssign(&base);
        }
        base.addAssign(&base);
    }
    return result;
}

pub fn mulBySmallIntAssign(self: *Fp6Mont, other: u8) void {
    self.* = self.mulBySmallInt(other);
}

/// CH-SQR2 squaring: (a0 + a1*v + a2*v²)² using Squaring Method 2
/// Reference: https://www.lirmm.fr/arith18/papers/Chung-Squaring.pdf
/// Saves 3 multiplications compared to naive squaring (5 muls vs 8 muls)
pub fn square(self: *const Fp6Mont) Fp6Mont {
    // a = a0 + a1*v + a2*v², ξ = 9 + u ∈ F_p2
    const xi = curve_parameters.XI;

    // CH-SQR2 intermediate products
    const s0 = self.v0.square(); // a0²
    const s1 = self.v0.mul(&self.v1).mulBySmallInt(2); // 2*a0*a1
    const s2 = self.v0.sub(&self.v1).add(&self.v2).square(); // (a0 - a1 + a2)²
    const s3 = self.v1.mul(&self.v2).mulBySmallInt(2); // 2*a1*a2
    const s4 = self.v2.square(); // a2²

    // Final coefficients using CH-SQR2 formula
    const c0 = s0.add(&xi.mul(&s3)); // a0² + ξ*2*a1*a2
    const c1 = s1.add(&xi.mul(&s4)); // 2*a0*a1 + ξ*a2²
    const c2 = s1.add(&s2).add(&s3).sub(&s4).sub(&s0); // 2*a0*a2 + a1²

    return Fp6Mont{
        .v0 = c0,
        .v1 = c1,
        .v2 = c2,
    };
}

pub fn squareAssign(self: *Fp6Mont) void {
    self.* = self.square();
}

pub fn pow(self: *const Fp6Mont, exponent: u256) Fp6Mont {
    var result = ONE;
    var base = self.*;
    var exp = exponent;
    while (exp > 0) : (exp >>= 1) {
        if (exp & 1 == 1) {
            result.mulAssign(&base);
        }
        base.mulAssign(&base);
    }
    return result;
}

pub fn powAssign(self: *Fp6Mont, exponent: u256) void {
    self.* = self.pow(exponent);
}

/// Norm: N(a0 + a1*v + a2*v²) = a*a̅ where a̅ is conjugate over F_p2
/// Maps F_p6 element to F_p2 via the norm map
pub fn norm(self: *const Fp6Mont) Fp2Mont {
    // a = a0 + a1*v + a2*v², ξ = 9 + u ∈ F_p2
    const xi = curve_parameters.XI;

    // Intermediate norm components
    const c0 = self.v0.mul(&self.v0).sub(&xi.mul(&self.v1.mul(&self.v2))); // a0² - ξ*a1*a2
    const c1 = xi.mul(&self.v2.mul(&self.v2)).sub(&self.v0.mul(&self.v1)); // ξ*a2² - a0*a1
    const c2 = self.v1.mul(&self.v1).sub(&self.v0.mul(&self.v2)); // a1² - a0*a2

    // Final norm: a0*c0 + ξ*(a2*c1 + a1*c2)
    return self.v0.mul(&c0).add(&xi.mul(&self.v2.mul(&c1).add(&self.v1.mul(&c2))));
}

pub fn scalarMul(self: *const Fp6Mont, scalar: *const FpMont) Fp6Mont {
    return Fp6Mont{
        .v0 = self.v0.scalarMul(scalar),
        .v1 = self.v1.scalarMul(scalar),
        .v2 = self.v2.scalarMul(scalar),
    };
}

pub fn scalarMulAssign(self: *Fp6Mont, scalar: *const FpMont) void {
    self.* = self.scalarMul(scalar);
}

pub fn mulByFp2(self: *const Fp6Mont, fp2_val: *const Fp2Mont) Fp6Mont {
    return Fp6Mont{
        .v0 = self.v0.mul(fp2_val),
        .v1 = self.v1.mul(fp2_val),
        .v2 = self.v2.mul(fp2_val),
    };
}

pub fn mulByFp2Assign(self: *Fp6Mont, fp2_val: *const Fp2Mont) void {
    self.* = self.mulByFp2(fp2_val);
}

pub fn inv(self: *const Fp6Mont) !Fp6Mont {
    const xi = curve_parameters.XI;

    // Calculate squares and basic products
    const v0_sq = self.v0.mul(&self.v0);
    const v1_sq = self.v1.mul(&self.v1);
    const v2_sq = self.v2.mul(&self.v2);
    const v2_xi = self.v2.mul(&xi);
    const v1_v0 = self.v1.mul(&self.v0);

    // Calculate norm factor components
    const D1 = v2_sq.mul(&v2_xi).mul(&xi);
    const D2 = v1_v0.mul(&v2_xi).mulBySmallInt(3);
    const D3 = v1_sq.mul(&self.v1).mul(&xi);
    const D4 = v0_sq.mul(&self.v0);

    const norm_factor = D1.sub(&D2).add(&D3).add(&D4);
    const norm_factor_inv = try norm_factor.inv();

    // Calculate result components
    const result_v0 = v0_sq.sub(&v2_xi.mul(&self.v1));
    const result_v1 = v2_sq.mul(&xi).sub(&v1_v0);
    const result_v2 = v1_sq.sub(&self.v0.mul(&self.v2));

    return Fp6Mont{
        .v0 = result_v0.mul(&norm_factor_inv),
        .v1 = result_v1.mul(&norm_factor_inv),
        .v2 = result_v2.mul(&norm_factor_inv),
    };
}

pub fn invAssign(self: *Fp6Mont) !void {
    self.* = try self.inv();
}

pub fn equal(self: *const Fp6Mont, other: *const Fp6Mont) bool {
    return self.v0.equal(&other.v0) and self.v1.equal(&other.v1) and self.v2.equal(&other.v2);
}

pub fn frobeniusMap(self: *const Fp6Mont) Fp6Mont {
    return Fp6Mont{
        .v0 = self.v0.frobeniusMap(),
        .v1 = self.v1.frobeniusMap().mul(&curve_parameters.FROBENIUS_COEFF_FP6_V1),
        .v2 = self.v2.frobeniusMap().mul(&curve_parameters.FROBENIUS_COEFF_FP6_V2),
    };
}

pub fn frobeniusMapAssign(self: *Fp6Mont) void {
    self.* = self.frobeniusMap();
}
