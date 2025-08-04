const FpMont = @import("FpMont.zig");
const Fp2Mont = @import("Fp2Mont.zig");
const curve_parameters = @import("curve_parameters.zig");

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

pub fn mul(self: *const Fp6Mont, other: *const Fp6Mont) Fp6Mont {
    // ξ = 9 + u ∈ Fp2
    const xi = curve_parameters.XI;

    // s0 = a0 * b0, s1 = a1 * b1, s2 = a2 * b2
    const s0 = self.v0.mul(&other.v0);
    const s1 = self.v1.mul(&other.v1);
    const s2 = self.v2.mul(&other.v2);

    // t0 = (a1 + a2) * (b1 + b2)
    // t1 = (a0 + a1) * (b0 + b1)
    // t2 = (a0 + a2) * (b0 + b2)
    const t0 = self.v1.add(&self.v2).mul(&other.v1.add(&other.v2));
    const t1 = self.v0.add(&self.v1).mul(&other.v0.add(&other.v1));
    const t2 = self.v0.add(&self.v2).mul(&other.v0.add(&other.v2));

    // tmp0 = t0 - s1 - s2
    // tmp1 = t1 - s0 - s1
    // tmp2 = t2 - s0 - s2
    const tmp0 = t0.sub(&s1).sub(&s2);
    const tmp1 = t1.sub(&s0).sub(&s1);
    const tmp2 = t2.sub(&s0).sub(&s2);

    // c0 = s0 + ξ * tmp0
    // c1 = tmp1 + ξ * s2
    // c2 = tmp2 + s1
    const c0 = s0.add(&xi.mul(&tmp0));
    const c1 = tmp1.add(&xi.mul(&s2));
    const c2 = tmp2.add(&s1);

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

// TODO: optimize this
pub fn square(self: *const Fp6Mont) Fp6Mont {
    return self.mul(self);
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

pub fn norm(self: *const Fp6Mont) Fp2Mont {
    const xi = curve_parameters.XI;

    // c0 = v0^2 - ξ * (v1 * v2)
    const c0 = self.v0.mul(&self.v0).sub(&xi.mul(&self.v1.mul(&self.v2)));

    // c1 = ξ * v2^2 - v0 * v1
    const c1 = xi.mul(&self.v2.mul(&self.v2)).sub(&self.v0.mul(&self.v1));

    // c2 = v1^2 - v0 * v2
    const c2 = self.v1.mul(&self.v1).sub(&self.v0.mul(&self.v2));

    // norm_result = v0 * c0 + ξ * (v2 * c1 + v1 * c2)
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
    self.v0.frobeniusMapAssign();
    self.v1.frobeniusMapAssign();
    self.v2.frobeniusMapAssign();
}
