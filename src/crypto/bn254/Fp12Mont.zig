const FpMont = @import("FpMont.zig");
const Fp2Mont = @import("Fp2Mont.zig");
const Fp4Mont = @import("Fp4Mont.zig");
const Fp6Mont = @import("Fp6Mont.zig");
const curve_parameters = @import("curve_parameters.zig");

//
// Field extension: F_p12 = F_p6[w] / (w^2 - v)
// Elements: a = a0 + a1*w, where a0, a1 ∈ F_p6 and w^2 = v
//

pub const Fp12Mont = @This();

w0: Fp6Mont,
w1: Fp6Mont,

pub const ZERO = Fp12Mont{ .w0 = Fp6Mont.ZERO, .w1 = Fp6Mont.ZERO };
pub const ONE = Fp12Mont{ .w0 = Fp6Mont.ONE, .w1 = Fp6Mont.ZERO };

pub fn init(w0: *const Fp6Mont, w1: *const Fp6Mont) Fp12Mont {
    return Fp12Mont{ .w0 = w0.*, .w1 = w1.* };
}

pub fn init_from_int(w0_v0_real: u256, w0_v0_imag: u256, w0_v1_real: u256, w0_v1_imag: u256, w0_v2_real: u256, w0_v2_imag: u256, w1_v0_real: u256, w1_v0_imag: u256, w1_v1_real: u256, w1_v1_imag: u256, w1_v2_real: u256, w1_v2_imag: u256) Fp12Mont {
    const w0 = Fp6Mont.init_from_int(w0_v0_real, w0_v0_imag, w0_v1_real, w0_v1_imag, w0_v2_real, w0_v2_imag);
    const w1 = Fp6Mont.init_from_int(w1_v0_real, w1_v0_imag, w1_v1_real, w1_v1_imag, w1_v2_real, w1_v2_imag);
    return Fp12Mont{
        .w0 = w0,
        .w1 = w1,
    };
}

pub fn add(self: *const Fp12Mont, other: *const Fp12Mont) Fp12Mont {
    return Fp12Mont{
        .w0 = self.w0.add(&other.w0),
        .w1 = self.w1.add(&other.w1),
    };
}

pub fn addAssign(self: *Fp12Mont, other: *const Fp12Mont) void {
    self.* = self.add(other);
}

pub fn neg(self: *const Fp12Mont) Fp12Mont {
    return Fp12Mont{
        .w0 = self.w0.neg(),
        .w1 = self.w1.neg(),
    };
}

pub fn negAssign(self: *Fp12Mont) void {
    self.* = self.neg();
}

pub fn sub(self: *const Fp12Mont, other: *const Fp12Mont) Fp12Mont {
    return Fp12Mont{
        .w0 = self.w0.sub(&other.w0),
        .w1 = self.w1.sub(&other.w1),
    };
}

pub fn subAssign(self: *Fp12Mont, other: *const Fp12Mont) void {
    self.* = self.sub(other);
}

/// Karatsuba multiplication: (a0 + a1*w)(b0 + b1*w) mod (w² - v)
pub fn mul(self: *const Fp12Mont, other: *const Fp12Mont) Fp12Mont {
    // a = a0 + a1*w, b = b0 + b1*w, where w² = v
    const a0_b0 = self.w0.mul(&other.w0);
    const a1_b1 = self.w1.mul(&other.w1);

    const a0_plus_a1 = self.w0.add(&self.w1);
    const b0_plus_b1 = other.w0.add(&other.w1);

    const c0 = a0_b0.add(&a1_b1.mulByV()); // a0*b0 + v*a1*b1
    const c1 = a0_plus_a1.mul(&b0_plus_b1).sub(&a0_b0).sub(&a1_b1); // (a0+a1)(b0+b1) - a0*b0 - a1*b1 = a0*b1 + a1*b0

    return Fp12Mont{
        .w0 = c0,
        .w1 = c1,
    };
}

pub fn mulAssign(self: *Fp12Mont, other: *const Fp12Mont) void {
    self.* = self.mul(other);
}

//we use double and add to multiply by a small integer
pub fn mulBySmallInt(self: *const Fp12Mont, other: u8) Fp12Mont {
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

pub fn mulBySmallIntAssign(self: *Fp12Mont, other: u8) void {
    self.* = self.mulBySmallInt(other);
}

/// Complex squaring: (a0 + a1*w)² = (a0 + a1)(a0 + v*a1) - a0*a1 - v*a0*a1 + 2*a0*a1*w
pub fn square(self: *const Fp12Mont) Fp12Mont {
    // a = a0 + a1*w, where w² = v
    const a0_a1 = self.w0.mul(&self.w1);
    const a0_plus_a1 = self.w0.add(&self.w1);
    const a0_plus_v_a1 = self.w0.add(&self.w1.mulByV());

    const c0 = a0_plus_a1.mul(&a0_plus_v_a1).sub(&a0_a1).sub(&a0_a1.mulByV()); // (a0+a1)(a0+v*a1) - a0*a1 - v*a0*a1
    const c1 = a0_a1.mulBySmallInt(2); // 2*a0*a1

    return Fp12Mont{
        .w0 = c0,
        .w1 = c1,
    };
}

pub fn squareAssign(self: *Fp12Mont) void {
    self.* = self.square();
}

pub fn pow(self: *const Fp12Mont, exponent: u256) Fp12Mont {
    var result = ONE;
    var base = self.*;
    var exp = exponent;
    while (exp > 0) : (exp >>= 1) {
        if (exp & 1 == 1) {
            result.mulAssign(&base);
        }
        base.squareAssign();
    }
    return result;
}

pub fn powAssign(self: *Fp12Mont, exponent: u256) void {
    self.* = self.pow(exponent);
}

pub fn inv(self: *const Fp12Mont) !Fp12Mont {
    const v = curve_parameters.V;

    const w0_squared = self.w0.mul(&self.w0);
    const w1_squared = self.w1.mul(&self.w1);
    const norm = w0_squared.sub(&v.mul(&w1_squared));
    const norm_inv = try norm.inv();

    return Fp12Mont{
        .w0 = self.w0.mul(&norm_inv),
        .w1 = self.w1.mul(&norm_inv).neg(),
    };
}

pub fn invAssign(self: *Fp12Mont) !void {
    self.* = try self.inv();
}

// The inverse of a unary field element is it's conjugate
pub fn unaryInverse(self: *const Fp12Mont) Fp12Mont {
    return Fp12Mont{
        .w0 = self.w0,
        .w1 = self.w1.neg(),
    };
}

pub fn unaryInverseAssign(self: *Fp12Mont) void {
    self.* = self.unaryInverse();
}

pub fn equal(self: *const Fp12Mont, other: *const Fp12Mont) bool {
    return self.w0.equal(&other.w0) and self.w1.equal(&other.w1);
}

pub fn frobeniusMap(self: *const Fp12Mont) Fp12Mont {
    return Fp12Mont{
        .w0 = self.w0.frobeniusMap(),
        .w1 = self.w1.frobeniusMap().mulByFp2(&curve_parameters.FROBENIUS_COEFF_FP12),
    };
}

pub fn frobeniusMapAssign(self: *Fp12Mont) void {
    self.* = self.frobeniusMap();
}

pub fn powParamT(self: *const Fp12Mont) Fp12Mont {
    var exp: u64 = curve_parameters.CURVE_PARAM_T;
    var result = ONE;
    var base = self.*;
    while (exp > 0) : (exp >>= 1) {
        if (exp & 1 == 1) {
            result.mulAssign(&base);
        }
        base.squareCyclotomicAssign();
    }
    return result;
}

pub fn powParamTAssign(self: *Fp12Mont) void {
    self.* = self.powParamT();
}

pub fn squareCyclotomic(self: *const Fp12Mont) Fp12Mont {
    const a = Fp4Mont{
        .y0 = self.w0.v0,
        .y1 = self.w1.v1,
    };
    const b = Fp4Mont{
        .y0 = self.w1.v0,
        .y1 = self.w0.v2,
    };
    const c = Fp4Mont{
        .y0 = self.w0.v1,
        .y1 = self.w1.v2,
    };

    const A = a.square().mulBySmallInt(3).add(&a.conj().mulBySmallInt(2));
    const B = c.square().mulByY().mulBySmallInt(3).add(&b.conj().mulBySmallInt(2));
    const C = b.square().mulBySmallInt(3).sub(&b.conj().mulBySmallInt(2));

    const result1 = Fp6Mont{
        .v0 = A.y0,
        .v1 = B.y0,
        .v2 = C.y0,
    };
    const result2 = Fp6Mont{
        .v0 = A.y1,
        .v1 = B.y1,
        .v2 = C.y1,
    };

    return Fp12Mont{
        .w0 = result1,
        .w1 = result2,
    };
}

pub fn squareCyclotomicAssign(self: *Fp12Mont) void {
    self.* = self.squareCyclotomic();
}
