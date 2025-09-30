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

pub fn div(self: *const Fp12Mont, other: *const Fp12Mont) !Fp12Mont {
    var inverse = try other.inv();
    return self.mul(&inverse);
}

pub fn divAssign(self: *Fp12Mont, other: *const Fp12Mont) !void {
    self.* = try self.div(other);
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
    const exp = curve_parameters.CURVE_PARAM_T_NAF;
    var result = ONE;
    var base = self.*;
    for (exp) |bit| {
        if (bit == 1) {
            result.mulAssign(&base);
        } else if (bit == -1) {
            result.mulAssign(&base.unaryInverse());
        }
        base.squareCyclotomicAssign();
    }
    return result;
}

pub fn powParamTAssign(self: *Fp12Mont) void {
    self.* = self.powParamT();
}

// faster squaring for cyclotomic elements
// Granger and Scott, https://eprint.iacr.org/2009/565.pdf
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

    const A = a.square().mulBySmallInt(3).sub(&a.conj().mulBySmallInt(2));
    const B = c.square().mulByY().mulBySmallInt(3).add(&b.conj().mulBySmallInt(2));
    const C = b.square().mulBySmallInt(3).sub(&c.conj().mulBySmallInt(2));

    const result1 = Fp6Mont{
        .v0 = A.y0,
        .v1 = C.y0,
        .v2 = B.y1,
    };
    const result2 = Fp6Mont{
        .v0 = B.y0,
        .v1 = A.y1,
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

// ============================================================================
// TESTS - Following patterns from FpMont.zig and Fp2Mont.zig
// ============================================================================

const std = @import("std");

fn fp12mont(w0_v0_real: u256, w0_v0_imag: u256, w0_v1_real: u256, w0_v1_imag: u256, w0_v2_real: u256, w0_v2_imag: u256, w1_v0_real: u256, w1_v0_imag: u256, w1_v1_real: u256, w1_v1_imag: u256, w1_v2_real: u256, w1_v2_imag: u256) Fp12Mont {
    return Fp12Mont.init_from_int(w0_v0_real, w0_v0_imag, w0_v1_real, w0_v1_imag, w0_v2_real, w0_v2_imag, w1_v0_real, w1_v0_imag, w1_v1_real, w1_v1_imag, w1_v2_real, w1_v2_imag);
}

fn expectFp12MontEqual(expected: Fp12Mont, actual: Fp12Mont) !void {
    try std.testing.expect(expected.equal(&actual));
}

fn printFp12Mont(a: Fp12Mont) void {
    std.debug.print("w0:\n", .{});
    std.debug.print("v0: ", .{});
    std.debug.print("{} + u*{}\n", .{ a.w0.v0.u0.toStandardRepresentation(), a.w0.v0.u1.toStandardRepresentation() });
    std.debug.print("v1: ", .{});
    std.debug.print("{} + u*{}\n", .{ a.w0.v1.u0.toStandardRepresentation(), a.w0.v1.u1.toStandardRepresentation() });
    std.debug.print("v2: ", .{});
    std.debug.print("{} + u*{}\n", .{ a.w0.v2.u0.toStandardRepresentation(), a.w0.v2.u1.toStandardRepresentation() });
    std.debug.print("w1:\n", .{});
    std.debug.print("v0: ", .{});
    std.debug.print("{} + u*{}\n", .{ a.w1.v0.u0.toStandardRepresentation(), a.w1.v0.u1.toStandardRepresentation() });
    std.debug.print("v1: ", .{});
    std.debug.print("{} + u*{}\n", .{ a.w1.v1.u0.toStandardRepresentation(), a.w1.v1.u1.toStandardRepresentation() });
    std.debug.print("v2: ", .{});
    std.debug.print("{} + u*{}\n", .{ a.w1.v2.u0.toStandardRepresentation(), a.w1.v2.u1.toStandardRepresentation() });
}

test "Fp12Mont.init basic initialization" {
    const a = fp12mont(123, 456, 789, 101112, 131415, 161718, 192021, 222324, 252627, 282930, 313233, 343536);
    const expected = Fp12Mont{
        .w0 = Fp6Mont.init_from_int(123, 456, 789, 101112, 131415, 161718),
        .w1 = Fp6Mont.init_from_int(192021, 222324, 252627, 282930, 313233, 343536),
    };
    try expectFp12MontEqual(expected, a);
}

test "Fp12Mont.init with modular reduction" {
    const a = fp12mont(curve_parameters.FP_MOD + 5, curve_parameters.FP_MOD + 10, curve_parameters.FP_MOD + 15, curve_parameters.FP_MOD + 20, curve_parameters.FP_MOD + 25, curve_parameters.FP_MOD + 30, curve_parameters.FP_MOD + 35, curve_parameters.FP_MOD + 40, curve_parameters.FP_MOD + 45, curve_parameters.FP_MOD + 50, curve_parameters.FP_MOD + 55, curve_parameters.FP_MOD + 60);
    const expected = fp12mont(5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60);
    try expectFp12MontEqual(expected, a);
}

test "Fp12Mont.add basic addition" {
    const a = fp12mont(10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120);
    const b = fp12mont(130, 140, 150, 160, 170, 180, 190, 200, 210, 220, 230, 240);
    const result = a.add(&b);
    try expectFp12MontEqual(fp12mont(140, 160, 180, 200, 220, 240, 260, 280, 300, 320, 340, 360), result);
}

test "Fp12Mont.add with zero" {
    const a = fp12mont(100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 1100, 1200);
    const zero = fp12mont(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    const result = a.add(&zero);
    try expectFp12MontEqual(a, result);
}

test "Fp12Mont.add with modular reduction" {
    const a = fp12mont(curve_parameters.FP_MOD - 1, curve_parameters.FP_MOD - 2, curve_parameters.FP_MOD - 3, curve_parameters.FP_MOD - 4, curve_parameters.FP_MOD - 5, curve_parameters.FP_MOD - 6, curve_parameters.FP_MOD - 7, curve_parameters.FP_MOD - 8, curve_parameters.FP_MOD - 9, curve_parameters.FP_MOD - 10, curve_parameters.FP_MOD - 11, curve_parameters.FP_MOD - 12);
    const b = fp12mont(5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60);
    const result = a.add(&b);
    try expectFp12MontEqual(fp12mont(4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48), result);
}

test "Fp12Mont.add commutative property" {
    const a = fp12mont(15, 25, 35, 45, 55, 65, 75, 85, 95, 105, 115, 125);
    const b = fp12mont(135, 145, 155, 165, 175, 185, 195, 205, 215, 225, 235, 245);
    const result1 = a.add(&b);
    const result2 = b.add(&a);
    try expectFp12MontEqual(result1, result2);
}

test "Fp12Mont.neg basic negation" {
    const a = fp12mont(100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 1100, 1200);
    const result = a.neg();
    const expected = fp12mont(curve_parameters.FP_MOD - 100, curve_parameters.FP_MOD - 200, curve_parameters.FP_MOD - 300, curve_parameters.FP_MOD - 400, curve_parameters.FP_MOD - 500, curve_parameters.FP_MOD - 600, curve_parameters.FP_MOD - 700, curve_parameters.FP_MOD - 800, curve_parameters.FP_MOD - 900, curve_parameters.FP_MOD - 1000, curve_parameters.FP_MOD - 1100, curve_parameters.FP_MOD - 1200);
    try expectFp12MontEqual(expected, result);
}

test "Fp12Mont.neg double negation" {
    const a = fp12mont(123, 456, 789, 101112, 131415, 161718, 192021, 222324, 252627, 282930, 313233, 343536);
    const result = a.neg().neg();
    try expectFp12MontEqual(a, result);
}

test "Fp12Mont.neg of zero" {
    const zero = fp12mont(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    const result = zero.neg();
    const expected = fp12mont(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    try expectFp12MontEqual(expected, result);
}

test "Fp12Mont.sub basic subtraction" {
    const a = fp12mont(100, 150, 200, 250, 300, 350, 400, 450, 500, 550, 600, 650);
    const b = fp12mont(30, 50, 70, 90, 110, 130, 150, 170, 190, 210, 230, 250);
    const result = a.sub(&b);
    try expectFp12MontEqual(fp12mont(70, 100, 130, 160, 190, 220, 250, 280, 310, 340, 370, 400), result);
}

test "Fp12Mont.sub with zero" {
    const a = fp12mont(100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 1100, 1200);
    const zero = fp12mont(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    const result = a.sub(&zero);
    try expectFp12MontEqual(a, result);
}

test "Fp12Mont.sub from zero" {
    const a = fp12mont(25, 35, 45, 55, 65, 75, 85, 95, 105, 115, 125, 135);
    const zero = fp12mont(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    const result = zero.sub(&a);
    try expectFp12MontEqual(a.neg(), result);
}

test "Fp12Mont.mul basic multiplication" {
    const a = fp12mont(1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0); // 1
    const b = fp12mont(0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0); // w
    const result = a.mul(&b);
    try expectFp12MontEqual(fp12mont(0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0), result);
}

test "Fp12Mont.mul with zero" {
    const a = fp12mont(100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 1100, 1200);
    const zero = fp12mont(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    const result = a.mul(&zero);
    try expectFp12MontEqual(zero, result);
}

test "Fp12Mont.mul with one" {
    const a = fp12mont(123, 456, 789, 101112, 131415, 161718, 192021, 222324, 252627, 282930, 313233, 343536);
    const one = fp12mont(1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    const result = a.mul(&one);
    try expectFp12MontEqual(a, result);
}

test "Fp12Mont.mul commutative property" {
    const a = fp12mont(6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28);
    const b = fp12mont(3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25);
    const result1 = a.mul(&b);
    const result2 = b.mul(&a);
    try expectFp12MontEqual(result1, result2);
}

test "Fp12Mont.square basic squaring" {
    const a = fp12mont(2, 1, 1, 2, 3, 1, 1, 2, 3, 1, 2, 1);
    const result_square = a.square();
    const result_mul = a.mul(&a);
    try expectFp12MontEqual(result_square, result_mul);
}

test "Fp12Mont.square of zero" {
    const zero = fp12mont(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    const result = zero.square();
    try expectFp12MontEqual(zero, result);
}

test "Fp12Mont.square of one" {
    const one = fp12mont(1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    const result = one.square();
    try expectFp12MontEqual(one, result);
}

test "Fp12Mont.pow to power of zero" {
    const a = fp12mont(123, 456, 789, 101112, 131415, 161718, 192021, 222324, 252627, 282930, 313233, 343536);
    const result = a.pow(0);
    try expectFp12MontEqual(fp12mont(1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0), result);
}

test "Fp12Mont.pow to power of one" {
    const a = fp12mont(123, 456, 789, 101112, 131415, 161718, 192021, 222324, 252627, 282930, 313233, 343536);
    const result = a.pow(1);
    try expectFp12MontEqual(a, result);
}

test "Fp12Mont.pow basic power" {
    const a = fp12mont(2, 1, 1, 0, 0, 1, 1, 0, 0, 1, 2, 1);
    const result = a.pow(2);
    const expected = a.mul(&a);
    try expectFp12MontEqual(expected, result);
}

test "Fp12Mont.pow with base zero" {
    const a = fp12mont(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    const result = a.pow(5);
    try expectFp12MontEqual(fp12mont(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0), result);
}

test "Fp12Mont.pow with base one" {
    const a = fp12mont(1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    const result = a.pow(100);
    try expectFp12MontEqual(fp12mont(1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0), result);
}

test "Fp12Mont.mulBySmallInt basic multiplication" {
    const a = fp12mont(2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13);
    const result = a.mulBySmallInt(3);
    try expectFp12MontEqual(fp12mont(6, 9, 12, 15, 18, 21, 24, 27, 30, 33, 36, 39), result);
}

test "Fp12Mont.mulBySmallInt with zero" {
    const a = fp12mont(10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120);
    const result = a.mulBySmallInt(0);
    try expectFp12MontEqual(fp12mont(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0), result);
}

test "Fp12Mont.mulBySmallInt with one" {
    const a = fp12mont(123, 456, 789, 101112, 131415, 161718, 192021, 222324, 252627, 282930, 313233, 343536);
    const result = a.mulBySmallInt(1);
    try expectFp12MontEqual(a, result);
}

test "Fp12Mont.inv basic inverse" {
    const a = fp12mont(3, 4, 1, 2, 5, 6, 7, 8, 9, 10, 11, 12);
    const a_inv = try a.inv();
    const product = a.mul(&a_inv);
    try expectFp12MontEqual(fp12mont(1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0), product);
}

test "Fp12Mont.inv of one" {
    const one = fp12mont(1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    const result = try one.inv();
    try expectFp12MontEqual(one, result);
}

test "Fp12Mont.inv double inverse" {
    const a = fp12mont(17, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67);
    const a_inv = try a.inv();
    const a_double_inv = try a_inv.inv();
    try expectFp12MontEqual(a, a_double_inv);
}

test "Fp12Mont.unaryInverse basic operation" {
    const a = fp12mont(5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 27);
    const result = a.unaryInverse();
    // Verify unaryInverse is indeed the conjugate: (a0, a1) -> (a0, -a1)
    const expected = fp12mont(5, 7, 9, 11, 13, 15, curve_parameters.FP_MOD - 17, curve_parameters.FP_MOD - 19, curve_parameters.FP_MOD - 21, curve_parameters.FP_MOD - 23, curve_parameters.FP_MOD - 25, curve_parameters.FP_MOD - 27);
    try expectFp12MontEqual(expected, result);
}

test "Fp12Mont.unaryInverse double application" {
    const a = fp12mont(123, 456, 789, 101112, 131415, 161718, 192021, 222324, 252627, 282930, 313233, 343536);
    const result = a.unaryInverse().unaryInverse();
    try expectFp12MontEqual(a, result);
}

test "Fp12Mont.equal basic equality" {
    const a = fp12mont(123, 456, 789, 101112, 131415, 161718, 192021, 222324, 252627, 282930, 313233, 343536);
    const b = fp12mont(123, 456, 789, 101112, 131415, 161718, 192021, 222324, 252627, 282930, 313233, 343536);
    try std.testing.expect(a.equal(&b));
}

test "Fp12Mont.equal different values" {
    const a = fp12mont(123, 456, 789, 101112, 131415, 161718, 192021, 222324, 252627, 282930, 313233, 343536);
    const b = fp12mont(321, 456, 789, 101112, 131415, 161718, 192021, 222324, 252627, 282930, 313233, 343536);
    try std.testing.expect(!a.equal(&b));
}

test "Fp12Mont.equal reflexive property" {
    const a = fp12mont(111, 222, 333, 444, 555, 666, 777, 888, 999, 1010, 1111, 1212);
    try std.testing.expect(a.equal(&a));
}

test "Fp12Mont.frobeniusMap basic operation" {
    const a = fp12mont(5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 27);
    const result = a.frobeniusMap();
    // Verify Frobenius map changes the element (unless it's in the base field)
    try std.testing.expect(!a.equal(&result));
    // Verify 12th power of Frobenius returns to original element (in Fp12)
    var current = a;
    for (0..12) |_| {
        current = current.frobeniusMap();
    }
    try expectFp12MontEqual(a, current);
}

test "Fp12Mont.powParamT basic operation" {
    const pairing = @import("pairing.zig");
    const a = fp12mont(2, 1, 1, 2, 3, 1, 1, 2, 3, 1, 2, 1);
    const a_cycl = pairing.final_exponentiation_easy_part(&a);
    const result = a_cycl.powParamT();
    // Verify it's equivalent to a.pow(curve_parameters.CURVE_PARAM_T)
    const expected = a_cycl.pow(curve_parameters.CURVE_PARAM_T);
    try expectFp12MontEqual(expected, result);
    // Verify for identity element
    const one = fp12mont(1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    const one_result = one.powParamT();
    try expectFp12MontEqual(one, one_result);
}

test "Fp12Mont.squareCyclotomic basic operation" {
    // Test with identity element - this should always work
    const pairing = @import("pairing.zig");
    const one = fp12mont(1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    const one_squared = one.squareCyclotomic();
    try expectFp12MontEqual(one, one_squared);

    // Test with a non-trivial element
    const a = fp12mont(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12);
    const a_cycl = pairing.final_exponentiation_easy_part(&a);
    const result = a_cycl.squareCyclotomic();
    const result2 = a_cycl.square();

    try std.testing.expect(result.equal(&result2));
}

// Mathematical property tests

test "Fp12Mont.mul distributive property over addition" {
    const a = fp12mont(123, 456, 789, 101112, 131415, 161718, 192021, 222324, 252627, 282930, 313233, 343536);
    const b = fp12mont(13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59);
    const c = fp12mont(61, 67, 71, 73, 79, 83, 89, 97, 101, 103, 107, 109);
    const left = a.mul(&b.add(&c));
    const right = a.mul(&b).add(&a.mul(&c));
    try expectFp12MontEqual(left, right);
}

test "Fp12Mont.mul associative property" {
    const a = fp12mont(12, 34, 56, 78, 90, 12, 34, 56, 78, 90, 12, 34);
    const b = fp12mont(11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53);
    const c = fp12mont(59, 61, 67, 71, 73, 79, 83, 89, 97, 101, 103, 107);
    const left = a.mul(&b).mul(&c);
    const right = a.mul(&b.mul(&c));
    try expectFp12MontEqual(left, right);
}
