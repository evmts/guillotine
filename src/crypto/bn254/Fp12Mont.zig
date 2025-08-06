const FpMont = @import("FpMont.zig");
const Fp2Mont = @import("Fp2Mont.zig");
const Fp6Mont = @import("Fp6Mont.zig");
const curve_parameters = @import("curve_parameters.zig");

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

pub fn mul(self: *const Fp12Mont, other: *const Fp12Mont) Fp12Mont {
    const v = curve_parameters.V;

    const w0_mul_w0 = self.w0.mul(&other.w0);
    const w1_mul_w1 = self.w1.mul(&other.w1);
    const result_w0 = w0_mul_w0.add(&v.mul(&w1_mul_w1));

    const result_w1 = self.w1.mul(&other.w0).add(&self.w0.mul(&other.w1));

    return Fp12Mont{
        .w0 = result_w0,
        .w1 = result_w1,
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

// TODO: optimize this
pub fn square(self: *const Fp12Mont) Fp12Mont {
    return self.mul(self);
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
        base.mulAssign(&base);
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
