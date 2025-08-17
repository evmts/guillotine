const FpMont = @import("FpMont.zig");
const Fp2Mont = @import("Fp2Mont.zig");
const curve_parameters = @import("curve_parameters.zig");

//
// Field extension: F_p4 = F_p2[y] / (y^2 - ξ)
// Elements: a = a0 + a1*y, where a0, a1 ∈ F_p2 and y^2 = ξ
// This extension is used in the final exponentiation of the pairing function
//

pub const Fp4Mont = @This();

y0: Fp2Mont,
y1: Fp2Mont,

pub const ZERO = Fp4Mont{ .y0 = Fp2Mont.ZERO, .y1 = Fp2Mont.ZERO };
pub const ONE = Fp4Mont{ .y0 = Fp2Mont.ONE, .y1 = Fp2Mont.ZERO };

pub fn init(y0: *const Fp2Mont, y1: *const Fp2Mont) Fp4Mont {
    return Fp4Mont{ .y0 = y0.*, .y1 = y1.* };
}

pub fn init_from_int(y0_real: u256, y0_imag: u256, y1_real: u256, y1_imag: u256) Fp4Mont {
    const y0 = Fp2Mont.init_from_int(y0_real, y0_imag);
    const y1 = Fp2Mont.init_from_int(y1_real, y1_imag);
    return Fp4Mont{
        .y0 = y0,
        .y1 = y1,
    };
}

pub fn add(self: *const Fp4Mont, other: *const Fp4Mont) Fp4Mont {
    return Fp4Mont{
        .y0 = self.y0.add(&other.y0),
        .y1 = self.y1.add(&other.y1),
    };
}

pub fn addAssign(self: *Fp4Mont, other: *const Fp4Mont) void {
    self.* = self.add(other);
}

pub fn neg(self: *const Fp4Mont) Fp4Mont {
    return Fp4Mont{
        .y0 = self.y0.neg(),
        .y1 = self.y1.neg(),
    };
}

pub fn negAssign(self: *Fp4Mont) void {
    self.* = self.neg();
}

pub fn sub(self: *const Fp4Mont, other: *const Fp4Mont) Fp4Mont {
    return Fp4Mont{
        .y0 = self.y0.sub(&other.y0),
        .y1 = self.y1.sub(&other.y1),
    };
}

pub fn subAssign(self: *Fp4Mont, other: *const Fp4Mont) void {
    self.* = self.sub(other);
}

pub fn mulByY(self: *const Fp4Mont) Fp4Mont {
    const xi = curve_parameters.XI;
    return Fp4Mont{
        .y0 = self.y1.mul(&xi),
        .y1 = self.y0,
    };
}

//we use double and add to multiply by a small integer
pub fn mulBySmallInt(self: *const Fp4Mont, other: u8) Fp4Mont {
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

pub fn mulBySmallIntAssign(self: *Fp4Mont, other: u8) void {
    self.* = self.mulBySmallInt(other);
}

/// Complex squaring: (a0 + a1*y)² = (a0 + a1)(a0 + ξ*a1) - a0*a1 - ξ*a0*a1 + 2*a0*a1*y
pub fn square(self: *const Fp4Mont) Fp4Mont {
    const xi = curve_parameters.XI;

    // a = a0 + a1*y, where y² = ξ
    const a0_a1 = self.y0.mul(&self.y1);
    const a0_plus_a1 = self.y0.add(&self.y1);
    const a0_plus_y_a1 = self.y0.add(&self.y1.mul(&xi));

    const c0 = a0_plus_a1.mul(&a0_plus_y_a1).sub(&a0_a1).sub(&a0_a1.mul(&xi)); // (a0+a1)(a0+ξ*a1) - a0*a1 - ξ*a0*a1
    const c1 = a0_a1.mulBySmallInt(2); // 2*a0*a1

    return Fp4Mont{
        .y0 = c0,
        .y1 = c1,
    };
}

pub fn squareAssign(self: *Fp4Mont) void {
    self.* = self.square();
}

pub fn conj(self: *const Fp4Mont) Fp4Mont {
    return Fp4Mont{
        .y0 = self.y0,
        .y1 = self.y1.neg(),
    };
}

pub fn equal(self: *const Fp4Mont, other: *const Fp4Mont) bool {
    return self.y0.equal(&other.y0) and self.y1.equal(&other.y1);
}

// ============================================================================
// TESTS - Following patterns from FpMont.zig and Fp2Mont.zig
// ============================================================================

const std = @import("std");

fn fp4mont(y0_real: u256, y0_imag: u256, y1_real: u256, y1_imag: u256) Fp4Mont {
    return Fp4Mont.init_from_int(y0_real, y0_imag, y1_real, y1_imag);
}

fn expectFp4MontEqual(expected: Fp4Mont, actual: Fp4Mont) !void {
    try std.testing.expect(expected.equal(&actual));
}

test "Fp4Mont.init basic initialization" {
    const a = fp4mont(123, 456, 789, 101112);
    const expected = Fp4Mont{
        .y0 = Fp2Mont.init_from_int(123, 456),
        .y1 = Fp2Mont.init_from_int(789, 101112),
    };
    try expectFp4MontEqual(expected, a);
}

test "Fp4Mont.init with modular reduction" {
    const a = fp4mont(curve_parameters.FP_MOD + 5, curve_parameters.FP_MOD + 10, curve_parameters.FP_MOD + 15, curve_parameters.FP_MOD + 20);
    const expected = fp4mont(5, 10, 15, 20);
    try expectFp4MontEqual(expected, a);
}

test "Fp4Mont.add basic addition" {
    const a = fp4mont(10, 20, 30, 40);
    const b = fp4mont(50, 60, 70, 80);
    const result = a.add(&b);
    try expectFp4MontEqual(fp4mont(60, 80, 100, 120), result);
}

test "Fp4Mont.add with zero" {
    const a = fp4mont(100, 200, 300, 400);
    const zero = fp4mont(0, 0, 0, 0);
    const result = a.add(&zero);
    try expectFp4MontEqual(a, result);
}

test "Fp4Mont.add with modular reduction" {
    const a = fp4mont(curve_parameters.FP_MOD - 1, curve_parameters.FP_MOD - 2, curve_parameters.FP_MOD - 3, curve_parameters.FP_MOD - 4);
    const b = fp4mont(5, 10, 15, 20);
    const result = a.add(&b);
    try expectFp4MontEqual(fp4mont(4, 8, 12, 16), result);
}

test "Fp4Mont.add commutative property" {
    const a = fp4mont(15, 25, 35, 45);
    const b = fp4mont(55, 65, 75, 85);
    const result1 = a.add(&b);
    const result2 = b.add(&a);
    try expectFp4MontEqual(result1, result2);
}

test "Fp4Mont.neg basic negation" {
    const a = fp4mont(100, 200, 300, 400);
    const result = a.neg();
    const expected = fp4mont(curve_parameters.FP_MOD - 100, curve_parameters.FP_MOD - 200, curve_parameters.FP_MOD - 300, curve_parameters.FP_MOD - 400);
    try expectFp4MontEqual(expected, result);
}

test "Fp4Mont.neg double negation" {
    const a = fp4mont(123, 456, 789, 101112);
    const result = a.neg().neg();
    try expectFp4MontEqual(a, result);
}

test "Fp4Mont.neg of zero" {
    const zero = fp4mont(0, 0, 0, 0);
    const result = zero.neg();
    const expected = fp4mont(0, 0, 0, 0);
    try expectFp4MontEqual(expected, result);
}

test "Fp4Mont.sub basic subtraction" {
    const a = fp4mont(100, 150, 200, 250);
    const b = fp4mont(30, 50, 70, 90);
    const result = a.sub(&b);
    try expectFp4MontEqual(fp4mont(70, 100, 130, 160), result);
}

test "Fp4Mont.sub with zero" {
    const a = fp4mont(100, 200, 300, 400);
    const zero = fp4mont(0, 0, 0, 0);
    const result = a.sub(&zero);
    try expectFp4MontEqual(a, result);
}

test "Fp4Mont.sub from zero" {
    const a = fp4mont(25, 35, 45, 55);
    const zero = fp4mont(0, 0, 0, 0);
    const result = zero.sub(&a);
    try expectFp4MontEqual(a.neg(), result);
}

test "Fp4Mont.square of zero" {
    const zero = fp4mont(0, 0, 0, 0);
    const result = zero.square();
    try expectFp4MontEqual(zero, result);
}

test "Fp4Mont.square of one" {
    const one = fp4mont(1, 0, 0, 0);
    const result = one.square();
    try expectFp4MontEqual(one, result);
}

test "Fp4Mont.conj basic conjugate" {
    const a = fp4mont(5, 7, 9, 11);
    const result = a.conj();
    const expected = fp4mont(5, 7, curve_parameters.FP_MOD - 9, curve_parameters.FP_MOD - 11);
    try expectFp4MontEqual(expected, result);
}

test "Fp4Mont.conj double conjugate" {
    const a = fp4mont(123, 456, 789, 101112);
    const result = a.conj().conj();
    try expectFp4MontEqual(a, result);
}

test "Fp4Mont.conj of real number" {
    const a = fp4mont(100, 50, 0, 0);
    const result = a.conj();
    const expected = fp4mont(100, 50, 0, 0);
    try expectFp4MontEqual(expected, result);
}

test "Fp4Mont.equal basic equality" {
    const a = fp4mont(123, 456, 789, 101112);
    const b = fp4mont(123, 456, 789, 101112);
    try std.testing.expect(a.equal(&b));
}

test "Fp4Mont.equal different values" {
    const a = fp4mont(123, 456, 789, 101112);
    const b = fp4mont(321, 456, 789, 101112);
    try std.testing.expect(!a.equal(&b));
}

test "Fp4Mont.equal reflexive property" {
    const a = fp4mont(111, 222, 333, 444);
    try std.testing.expect(a.equal(&a));
}

test "Fp4Mont.mulBySmallInt basic multiplication" {
    const a = fp4mont(2, 3, 4, 5);
    const result = a.mulBySmallInt(3);
    try expectFp4MontEqual(fp4mont(6, 9, 12, 15), result);
}

test "Fp4Mont.mulBySmallInt with zero" {
    const a = fp4mont(10, 20, 30, 40);
    const result = a.mulBySmallInt(0);
    try expectFp4MontEqual(fp4mont(0, 0, 0, 0), result);
}

test "Fp4Mont.mulBySmallInt with one" {
    const a = fp4mont(123, 456, 789, 101112);
    const result = a.mulBySmallInt(1);
    try expectFp4MontEqual(a, result);
}

test "Fp4Mont.mulByY basic operation" {
    const a = fp4mont(1, 2, 3, 4);
    const result = a.mulByY();
    const xi = curve_parameters.XI;
    const expected_y0 = Fp2Mont.init_from_int(3, 4).mul(&xi);
    const expected_y1 = Fp2Mont.init_from_int(1, 2);
    const expected = Fp4Mont{ .y0 = expected_y0, .y1 = expected_y1 };
    try expectFp4MontEqual(expected, result);
}
