const FpMont = @import("FpMont.zig");
const curve_parameters = @import("curve_parameters.zig");

//
// Field extension: F_p2 = F_p[u] / (u^2 - β) where β = -1
// Elements: a = a0 + a1*u, where a0, a1 ∈ F_p and u^2 = -1
//

pub const Fp2Mont = @This();

u0: FpMont,
u1: FpMont,

pub const ZERO = Fp2Mont{ .u0 = FpMont.ZERO, .u1 = FpMont.ZERO };
pub const ONE = Fp2Mont{ .u0 = FpMont.ONE, .u1 = FpMont.ZERO };

pub fn init(val_u0: *const FpMont, val_u1: *const FpMont) Fp2Mont {
    return Fp2Mont{
        .u0 = val_u0.*,
        .u1 = val_u1.*,
    };
}

pub fn init_from_int(real: u256, imag: u256) Fp2Mont {
    return Fp2Mont{
        .u0 = FpMont.init(real),
        .u1 = FpMont.init(imag),
    };
}

pub fn add(self: *const Fp2Mont, other: *const Fp2Mont) Fp2Mont {
    return Fp2Mont{
        .u0 = self.u0.add(&other.u0),
        .u1 = self.u1.add(&other.u1),
    };
}

pub fn addAssign(self: *Fp2Mont, other: *const Fp2Mont) void {
    self.* = self.add(other);
}

pub fn neg(self: *const Fp2Mont) Fp2Mont {
    return Fp2Mont{
        .u0 = self.u0.neg(),
        .u1 = self.u1.neg(),
    };
}

pub fn negAssign(self: *Fp2Mont) void {
    self.* = self.neg();
}

pub fn sub(self: *const Fp2Mont, other: *const Fp2Mont) Fp2Mont {
    return Fp2Mont{
        .u0 = self.u0.sub(&other.u0),
        .u1 = self.u1.sub(&other.u1),
    };
}

pub fn subAssign(self: *Fp2Mont, other: *const Fp2Mont) void {
    self.* = self.sub(other);
}

/// Karatsuba multiplication (u^2 = -1):
/// v0 = a0*b0, v1 = a1*b1, v2 = (a0+a1)*(b0+b1)
/// (a0 + a1*u)(b0 + b1*u) = (v0 - v1) + (v2 - v0 - v1)*u
pub fn mul(self: *const Fp2Mont, other: *const Fp2Mont) Fp2Mont {
    // a = a0 + a1*u, b = b0 + b1*u
    const a0_b0 = self.u0.mul(&other.u0);
    const a1_b1 = self.u1.mul(&other.u1);
    const a0_plus_a1 = self.u0.add(&self.u1);
    const b0_plus_b1 = other.u0.add(&other.u1);
    const v2 = a0_plus_a1.mul(&b0_plus_b1);

    const c0 = a0_b0.sub(&a1_b1); // Real part: v0 - v1
    const c1 = v2.sub(&a0_b0).sub(&a1_b1); // Imag part: v2 - v0 - v1

    return Fp2Mont{
        .u0 = c0,
        .u1 = c1,
    };
}

pub fn mulAssign(self: *Fp2Mont, other: *const Fp2Mont) void {
    self.* = self.mul(other);
}

pub fn div(self: *const Fp2Mont, other: *const Fp2Mont) !Fp2Mont {
    var inverse = try other.inv();
    return self.mul(&inverse);
}

pub fn divAssign(self: *Fp2Mont, other: *const Fp2Mont) !void {
    self.* = try self.div(other);
}

//we use double and add to multiply by a small integer
pub fn mulBySmallInt(self: *const Fp2Mont, other: u8) Fp2Mont {
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

pub fn mulBySmallIntAssign(self: *Fp2Mont, other: u8) void {
    self.* = self.mulBySmallInt(other);
}

/// Complex squaring: (a0 + a1*u)² = (a0 + a1)(a0 - a1) + 2*a0*a1*u
/// Optimized for β = -1
pub fn square(self: *const Fp2Mont) Fp2Mont {
    // a = a0 + a1*u
    const a0_plus_a1 = self.u0.add(&self.u1);
    const a0_minus_a1 = self.u0.sub(&self.u1);

    const c0 = a0_plus_a1.mul(&a0_minus_a1); // Real part: (a0+a1)(a0-a1) = a0² - a1²
    const c1 = self.u0.mul(&self.u1).mulBySmallInt(2); // Imag part: 2*a0*a1

    return Fp2Mont{
        .u0 = c0,
        .u1 = c1,
    };
}

pub fn squareAssign(self: *Fp2Mont) void {
    self.* = self.square();
}

pub fn pow(self: *const Fp2Mont, exponent: u256) Fp2Mont {
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

pub fn powAssign(self: *Fp2Mont, exponent: u256) void {
    self.* = self.pow(exponent);
}

/// Norm: N(a0 + a1*u) = a0² + a1² (since u² = -1, norm becomes a0² - (a1*u)² = a0² + a1²)
pub fn norm(self: *const Fp2Mont) FpMont {
    // a = a0 + a1*u
    const a0_squared = self.u0.mul(&self.u0);
    const a1_squared = self.u1.mul(&self.u1);
    return a0_squared.add(&a1_squared); // a0² + a1²
}

pub fn conj(self: *const Fp2Mont) Fp2Mont {
    return Fp2Mont{
        .u0 = self.u0,
        .u1 = self.u1.neg(),
    };
}

pub fn conjAssign(self: *Fp2Mont) void {
    self.* = self.conj();
}

pub fn scalarMul(self: *const Fp2Mont, scalar: *const FpMont) Fp2Mont {
    return Fp2Mont{
        .u0 = self.u0.mul(scalar),
        .u1 = self.u1.mul(scalar),
    };
}

pub fn scalarMulAssign(self: *Fp2Mont, scalar: *const FpMont) void {
    self.* = self.scalarMul(scalar);
}

pub fn inv(self: *const Fp2Mont) !Fp2Mont {
    const norm_val = self.norm();
    const norm_inv = try norm_val.inv();
    const conj_val = self.conj();
    return conj_val.scalarMul(&norm_inv);
}

pub fn invAssign(self: *Fp2Mont) !void {
    self.* = try self.inv();
}

pub fn equal(self: *const Fp2Mont, other: *const Fp2Mont) bool {
    return self.u0.equal(&other.u0) and self.u1.equal(&other.u1);
}

pub fn frobeniusMap(self: *const Fp2Mont) Fp2Mont {
    return self.conj();
}

pub fn frobeniusMapAssign(self: *Fp2Mont) void {
    self.* = self.frobeniusMap();
}

// ============================================================================
// TESTS - Adapted from Fp2.zig for Montgomery form
// ============================================================================

const std = @import("std");

fn fp2mont(real: u256, imag: u256) Fp2Mont {
    return Fp2Mont.init_from_int(real, imag);
}

fn expectFp2MontEqual(expected: Fp2Mont, actual: Fp2Mont) !void {
    try std.testing.expect(expected.equal(&actual));
}

test "Fp2Mont.add basic addition" {
    const a = fp2mont(10, 20);
    const b = fp2mont(30, 40);
    const result = a.add(&b);
    try expectFp2MontEqual(fp2mont(40, 60), result);
}

test "Fp2Mont.add with zero" {
    const a = fp2mont(100, 200);
    const zero = fp2mont(0, 0);
    const result = a.add(&zero);
    try expectFp2MontEqual(a, result);
}

test "Fp2Mont.add with modular reduction" {
    const a = fp2mont(curve_parameters.FP_MOD - 1, curve_parameters.FP_MOD - 2);
    const b = fp2mont(5, 10);
    const result = a.add(&b);
    try expectFp2MontEqual(fp2mont(4, 8), result);
}

test "Fp2Mont.add commutative property" {
    const a = fp2mont(15, 25);
    const b = fp2mont(35, 45);
    const result1 = a.add(&b);
    const result2 = b.add(&a);
    try expectFp2MontEqual(result1, result2);
}

test "Fp2Mont.neg basic negation" {
    const a = fp2mont(100, 200);
    const result = a.neg();
    const expected = fp2mont(curve_parameters.FP_MOD - 100, curve_parameters.FP_MOD - 200);
    try expectFp2MontEqual(expected, result);
}

test "Fp2Mont.neg double negation" {
    const a = fp2mont(123, 456);
    const result = a.neg().neg();
    try expectFp2MontEqual(a, result);
}

test "Fp2Mont.neg of zero" {
    const zero = fp2mont(0, 0);
    const result = zero.neg();
    const expected = fp2mont(0, 0);
    try expectFp2MontEqual(expected, result);
}

test "Fp2Mont.sub basic subtraction" {
    const a = fp2mont(50, 80);
    const b = fp2mont(20, 30);
    const result = a.sub(&b);
    try expectFp2MontEqual(fp2mont(30, 50), result);
}

test "Fp2Mont.sub with zero" {
    const a = fp2mont(100, 200);
    const zero = fp2mont(0, 0);
    const result = a.sub(&zero);
    try expectFp2MontEqual(a, result);
}

test "Fp2Mont.sub from zero" {
    const a = fp2mont(25, 35);
    const zero = fp2mont(0, 0);
    const result = zero.sub(&a);
    try expectFp2MontEqual(a.neg(), result);
}

test "Fp2Mont.mul basic multiplication" {
    const a = fp2mont(3, 4);
    const b = fp2mont(1, 2);
    const result = a.mul(&b);
    // (3 + 4i)(1 + 2i) = 3 + 6i + 4i + 8i^2 = 3 + 10i - 8 = -5 + 10i
    const expected = fp2mont(curve_parameters.FP_MOD - 5, 10);
    try expectFp2MontEqual(expected, result);
}

test "Fp2Mont.mul with zero" {
    const a = fp2mont(100, 200);
    const zero = fp2mont(0, 0);
    const result = a.mul(&zero);
    try expectFp2MontEqual(zero, result);
}

test "Fp2Mont.mul with one" {
    const a = fp2mont(123, 456);
    const one = fp2mont(1, 0);
    const result = a.mul(&one);
    try expectFp2MontEqual(a, result);
}

test "Fp2Mont.mul with i" {
    const a = fp2mont(5, 7);
    const i = fp2mont(0, 1);
    const result = a.mul(&i);
    // (5 + 7i)(0 + 1i) = 0 + 5i + 0 + 7i^2 = 5i - 7 = -7 + 5i
    const expected = fp2mont(curve_parameters.FP_MOD - 7, 5);
    try expectFp2MontEqual(expected, result);
}

test "Fp2Mont.mul commutative property" {
    const a = fp2mont(6, 8);
    const b = fp2mont(3, 5);
    const result1 = a.mul(&b);
    const result2 = b.mul(&a);
    try expectFp2MontEqual(result1, result2);
}

test "Fp2Mont.pow to power of zero" {
    const a = fp2mont(123, 456);
    const result = a.pow(0);
    try expectFp2MontEqual(fp2mont(1, 0), result);
}

test "Fp2Mont.pow to power of one" {
    const a = fp2mont(123, 456);
    const result = a.pow(1);
    try expectFp2MontEqual(a, result);
}

test "Fp2Mont.pow basic power" {
    const a = fp2mont(2, 1);
    const result = a.pow(2);
    // (2 + i)^2 = 4 + 4i + i^2 = 4 + 4i - 1 = 3 + 4i
    try expectFp2MontEqual(fp2mont(3, 4), result);
}

test "Fp2Mont.pow of i" {
    const i = fp2mont(0, 1);
    const result = i.pow(2);
    // i^2 = -1
    try expectFp2MontEqual(fp2mont(curve_parameters.FP_MOD - 1, 0), result);
}

test "Fp2Mont.norm basic norm" {
    const a = fp2mont(3, 4);
    const result = a.norm();
    const expected = FpMont.init(25);
    // norm(3 + 4i) = 3^2 + 4^2 = 9 + 16 = 25
    try std.testing.expect(result.equal(&expected));
}

test "Fp2Mont.norm of zero" {
    const zero = fp2mont(0, 0);
    const result = zero.norm();
    const expected = FpMont.init(0);
    try std.testing.expect(result.equal(&expected));
}

test "Fp2Mont.norm of one" {
    const one = fp2mont(1, 0);
    const result = one.norm();
    const expected = FpMont.init(1);
    try std.testing.expect(result.equal(&expected));
}

test "Fp2Mont.norm of i" {
    const i = fp2mont(0, 1);
    const result = i.norm();
    const expected = FpMont.init(1);
    try std.testing.expect(result.equal(&expected));
}

test "Fp2Mont.conj basic conjugate" {
    const a = fp2mont(5, 7);
    const result = a.conj();
    try expectFp2MontEqual(fp2mont(5, curve_parameters.FP_MOD - 7), result);
}

test "Fp2Mont.conj double conjugate" {
    const a = fp2mont(123, 456);
    const result = a.conj().conj();
    try expectFp2MontEqual(a, result);
}

test "Fp2Mont.conj of real number" {
    const a = fp2mont(100, 0);
    const result = a.conj();
    const expected = fp2mont(100, 0);
    try expectFp2MontEqual(expected, result);
}

test "Fp2Mont.conj mathematical property" {
    const a = fp2mont(50, 75);
    const conj_a = a.conj();
    const product = a.mul(&conj_a);
    const norm_squared = a.norm();
    // a * conj(a) should equal norm(a)
    const expected = Fp2Mont{ .u0 = norm_squared, .u1 = FpMont.init(0) };
    try expectFp2MontEqual(expected, product);
}

test "Fp2Mont.scalarMul basic scalar multiplication" {
    const a = fp2mont(3, 4);
    const scalar = FpMont.init(5);
    const result = a.scalarMul(&scalar);
    try expectFp2MontEqual(fp2mont(15, 20), result);
}

test "Fp2Mont.scalarMul with zero" {
    const a = fp2mont(10, 20);
    const zero = FpMont.init(0);
    const result = a.scalarMul(&zero);
    try expectFp2MontEqual(fp2mont(0, 0), result);
}

test "Fp2Mont.scalarMul with one" {
    const a = fp2mont(123, 456);
    const one = FpMont.init(1);
    const result = a.scalarMul(&one);
    try expectFp2MontEqual(a, result);
}

test "Fp2Mont.inv basic inverse" {
    const a = fp2mont(3, 4);
    const a_inv = try a.inv();
    const product = a.mul(&a_inv);
    // Should be approximately (1, 0)
    try expectFp2MontEqual(fp2mont(1, 0), product);
}

test "Fp2Mont.inv of one" {
    const one = fp2mont(1, 0);
    const result = try one.inv();
    try expectFp2MontEqual(one, result);
}

test "Fp2Mont.inv double inverse" {
    const a = fp2mont(17, 23);
    const a_inv = try a.inv();
    const a_double_inv = try a_inv.inv();
    try expectFp2MontEqual(a, a_double_inv);
}

test "Fp2Mont.inv of i" {
    const i = fp2mont(0, 1);
    const i_inv = try i.inv();
    const product = i.mul(&i_inv);
    try expectFp2MontEqual(fp2mont(1, 0), product);
}

test "Fp2Mont.equal basic equality" {
    const a = fp2mont(123, 456);
    const b = fp2mont(123, 456);
    try std.testing.expect(a.equal(&b));
}

test "Fp2Mont.equal different values" {
    const a = fp2mont(123, 456);
    const b = fp2mont(789, 456);
    try std.testing.expect(!a.equal(&b));
}

test "Fp2Mont.equal different imaginary parts" {
    const a = fp2mont(123, 456);
    const b = fp2mont(123, 789);
    try std.testing.expect(!a.equal(&b));
}

test "Fp2Mont.equal with zero" {
    const a = fp2mont(0, 0);
    const b = fp2mont(0, 0);
    try std.testing.expect(a.equal(&b));
}

test "Fp2Mont.equal reflexive property" {
    const a = fp2mont(111, 222);
    try std.testing.expect(a.equal(&a));
}

test "Fp2Mont.equal symmetric property" {
    const a = fp2mont(333, 444);
    const b = fp2mont(333, 444);
    try std.testing.expect(a.equal(&b));
    try std.testing.expect(b.equal(&a));
}

test "Fp2Mont.equal one component different" {
    const a = fp2mont(100, 200);
    const b = fp2mont(100, 201);
    const c = fp2mont(101, 200);
    try std.testing.expect(!a.equal(&b));
    try std.testing.expect(!a.equal(&c));
}

test "Fp2Mont.init basic initialization" {
    const a = Fp2Mont.init_from_int(123, 456);
    const expected = fp2mont(123, 456);
    try expectFp2MontEqual(expected, a);
}

test "Fp2Mont.init with modular reduction" {
    const a = Fp2Mont.init_from_int(curve_parameters.FP_MOD + 5, curve_parameters.FP_MOD + 10);
    const expected = fp2mont(5, 10);
    try expectFp2MontEqual(expected, a);
}

test "Fp2Mont.mul complex edge cases near modulus" {
    const a = fp2mont(curve_parameters.FP_MOD - 1, curve_parameters.FP_MOD - 1);
    const b = fp2mont(curve_parameters.FP_MOD - 1, curve_parameters.FP_MOD - 1);
    const result = a.mul(&b);
    const expected = fp2mont(0, 2); // Since (FP_MOD-1)^2 ≡ 1 (mod FP_MOD)
    // (FP_MOD-1 + (FP_MOD-1)i)^2 = (FP_MOD-1)^2 - (FP_MOD-1)^2 + 2(FP_MOD-1)^2 i = 2(FP_MOD-1)^2 i
    try expectFp2MontEqual(expected, result);
}

test "Fp2Mont.mul distributive property over addition" {
    const a = fp2mont(123, 456);
    const b = fp2mont(789, 321);
    const c = fp2mont(654, 987);
    const left = a.mul(&b.add(&c));
    const right = a.mul(&b).add(&a.mul(&c));
    try expectFp2MontEqual(left, right);
}

test "Fp2Mont.mul associative property" {
    const a = fp2mont(12, 34);
    const b = fp2mont(56, 78);
    const c = fp2mont(91, 23);
    const left = a.mul(&b).mul(&c);
    const right = a.mul(&b.mul(&c));
    try expectFp2MontEqual(left, right);
}

test "Fp2Mont.mul by complex conjugate gives norm" {
    const a = fp2mont(123, 456);
    const conj_a = a.conj();
    const product = a.mul(&conj_a);
    const norm_a = a.norm();
    const expected = Fp2Mont{ .u0 = norm_a, .u1 = FpMont.init(0) };
    try expectFp2MontEqual(expected, product);
}

test "Fp2Mont.mul i properties" {
    const i = fp2mont(0, 1);
    const i_squared = i.mul(&i);
    try expectFp2MontEqual(fp2mont(curve_parameters.FP_MOD - 1, 0), i_squared); // i^2 = -1

    const i_cubed = i_squared.mul(&i);
    try expectFp2MontEqual(fp2mont(0, curve_parameters.FP_MOD - 1), i_cubed); // i^3 = -i

    const i_fourth = i_cubed.mul(&i);
    try expectFp2MontEqual(fp2mont(1, 0), i_fourth); // i^4 = 1
}

test "Fp2Mont.pow complex exponentiation edge cases" {
    const a = fp2mont(2, 3);
    const a_256 = a.pow(256);
    // Should compute correctly (result will be some valid Fp2Mont value)
    // Just verify the computation completes without error
    _ = a_256;

    // Test that a^0 = 1 for any non-zero a
    const a_zero = a.pow(0);
    try expectFp2MontEqual(fp2mont(1, 0), a_zero);
}

test "Fp2Mont.norm multiplicative property" {
    const a = fp2mont(12, 34);
    const b = fp2mont(56, 78);
    const product = a.mul(&b);
    const norm_product = product.norm();
    const product_norms = a.norm().mul(&b.norm());
    try std.testing.expect(norm_product.equal(&product_norms));
}

test "Fp2Mont.inv edge cases with large values" {
    const a = fp2mont(curve_parameters.FP_MOD - 100, curve_parameters.FP_MOD - 200);
    const a_inv = try a.inv();
    const product = a.mul(&a_inv);
    try expectFp2MontEqual(fp2mont(1, 0), product);
}

test "Fp2Mont.add/sub near modulus boundaries" {
    const a = fp2mont(curve_parameters.FP_MOD - 5, curve_parameters.FP_MOD - 10);
    const b = fp2mont(10, 20);
    const sum = a.add(&b);
    const diff = a.sub(&b);

    const expected_sum = fp2mont(5, 10);
    const expected_diff = fp2mont(curve_parameters.FP_MOD - 15, curve_parameters.FP_MOD - 30);

    // Addition should wrap correctly
    try expectFp2MontEqual(expected_sum, sum);

    // Subtraction should handle underflow correctly
    try expectFp2MontEqual(expected_diff, diff);
}

// Additional tests for methods that exist in Fp2Mont but not in Fp2

test "Fp2Mont.addAssign basic assignment" {
    var a = fp2mont(10, 20);
    const b = fp2mont(30, 40);
    a.addAssign(&b);
    try expectFp2MontEqual(fp2mont(40, 60), a);
}

test "Fp2Mont.subAssign basic assignment" {
    var a = fp2mont(50, 80);
    const b = fp2mont(20, 30);
    a.subAssign(&b);
    try expectFp2MontEqual(fp2mont(30, 50), a);
}

test "Fp2Mont.mulAssign basic assignment" {
    var a = fp2mont(3, 4);
    const b = fp2mont(1, 2);
    a.mulAssign(&b);
    const expected = fp2mont(curve_parameters.FP_MOD - 5, 10);
    try expectFp2MontEqual(expected, a);
}

test "Fp2Mont.mulBySmallIntAssign basic assignment" {
    var a = fp2mont(3, 4);
    a.mulBySmallIntAssign(5);
    try expectFp2MontEqual(fp2mont(15, 20), a);
}

test "Fp2Mont.squareAssign basic assignment" {
    var a = fp2mont(2, 1);
    a.squareAssign();
    // (2 + i)^2 = 4 + 4i + i^2 = 4 + 4i - 1 = 3 + 4i
    try expectFp2MontEqual(fp2mont(3, 4), a);
}

test "Fp2Mont.powAssign basic assignment" {
    var a = fp2mont(2, 1);
    a.powAssign(2);
    try expectFp2MontEqual(fp2mont(3, 4), a);
}

test "Fp2Mont.negAssign basic assignment" {
    var a = fp2mont(100, 200);
    a.negAssign();
    const expected = fp2mont(curve_parameters.FP_MOD - 100, curve_parameters.FP_MOD - 200);
    try expectFp2MontEqual(expected, a);
}

test "Fp2Mont.conjAssign basic assignment" {
    var a = fp2mont(5, 7);
    a.conjAssign();
    try expectFp2MontEqual(fp2mont(5, curve_parameters.FP_MOD - 7), a);
}

test "Fp2Mont.scalarMulAssign basic assignment" {
    var a = fp2mont(3, 4);
    const scalar = FpMont.init(5);
    a.scalarMulAssign(&scalar);
    try expectFp2MontEqual(fp2mont(15, 20), a);
}

test "Fp2Mont.invAssign basic assignment" {
    var a = fp2mont(3, 4);
    const original = a;
    try a.invAssign();
    const product = original.mul(&a);
    try expectFp2MontEqual(fp2mont(1, 0), product);
}

test "Fp2Mont.frobeniusMapAssign basic assignment" {
    var a = fp2mont(5, 7);
    a.frobeniusMapAssign();
    try expectFp2MontEqual(fp2mont(5, curve_parameters.FP_MOD - 7), a);
}

// Test Montgomery representation consistency
test "Fp2Mont.representation consistency" {
    const values = [_][2]u256{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 123, 456 }, .{ curve_parameters.FP_MOD - 1, curve_parameters.FP_MOD - 1 } };
    for (values) |val| {
        const mont = fp2mont(val[0], val[1]);
        const expected = Fp2Mont.init_from_int(val[0], val[1]);
        try expectFp2MontEqual(expected, mont);
    }
}
