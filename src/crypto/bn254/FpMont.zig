const std = @import("std");
const curve_parameters = @import("curve_parameters.zig");

//
// Base field: F_p where p is the BN254 prime modulus
// We use Montgomery representation: elements are stored as a*R mod p where R = 2^256
//

pub const FpMont = @This();

value: u256,

pub const ZERO = FpMont{ .value = 0 };
pub const ONE = FpMont{ .value = curve_parameters.MONTGOMERY_R_MOD_P };
pub const FP_MOD = curve_parameters.FP_MOD;

/// Initialize a new FpMont element from a standard integer value
/// This converts the value to Montgomery form by multiplying by R^2 mod p
/// using Montgomery multiplication
pub fn init(value: u256) FpMont {
    const value_mod_p = value % curve_parameters.FP_MOD;

    const a = FpMont{
        .value = value_mod_p,
    };

    return a.mul(&FpMont{ .value = curve_parameters.MONTGOMERY_R2_MOD_P });
}

pub fn toStandardRepresentation(self: *const FpMont) u256 {
    return REDC(self.value);
}

/// Montgomery REDC algorithm
/// Reference: https://en.wikipedia.org/wiki/Montgomery_modular_multiplication
/// This is used to convert from Montgomery to standard representation
pub fn REDC(T: u256) u256 {
    const a = T *% curve_parameters.MONTGOMERY_MINUS_P_INV_MOD_R;

    const u = T + (@as(u512, a) * @as(u512, FP_MOD));
    const u_div_R: u256 = @truncate(u >> 256); // upper 256 bits

    return if (u_div_R >= curve_parameters.FP_MOD) u_div_R - curve_parameters.FP_MOD else u_div_R;
}

pub fn add(self: *const FpMont, other: *const FpMont) FpMont {
    const sum = self.value + other.value;
    return FpMont{
        .value = if (sum >= curve_parameters.FP_MOD) sum - curve_parameters.FP_MOD else sum,
    };
}

pub fn addAssign(self: *FpMont, other: *const FpMont) void {
    self.* = self.add(other);
}

pub fn neg(self: *const FpMont) FpMont {
    return FpMont{
        .value = if (self.value == 0) 0 else curve_parameters.FP_MOD - self.value,
    };
}

pub fn negAssign(self: *FpMont) void {
    self.* = self.neg();
}

pub fn sub(self: *const FpMont, other: *const FpMont) FpMont {
    return self.add(&other.neg());
}

pub fn subAssign(self: *FpMont, other: *const FpMont) void {
    self.* = self.sub(other);
}

/// Montgomery REDC multiplication: (a*R) * (b*R) * R^-1 mod p = (a*b*R) mod p
/// Reference: https://en.wikipedia.org/wiki/Montgomery_modular_multiplication
pub fn mul(self: *const FpMont, other: *const FpMont) FpMont {
    // a = self.value, b = other.value (both in Montgomery form)
    const ab: u512 = @as(u512, self.value) * @as(u512, other.value);
    const ab_lo: u256 = @truncate(ab); // Lower 256 bits

    const k = ab_lo *% curve_parameters.MONTGOMERY_MINUS_P_INV_MOD_R; // Montgomery factor

    const t = ab + (@as(u512, k) * @as(u512, FP_MOD));
    const c: u256 = @truncate(t >> 256); // Upper 256 bits = result candidate

    return FpMont{
        .value = if (c >= curve_parameters.FP_MOD) c - curve_parameters.FP_MOD else c,
    };
}

pub fn mulAssign(self: *FpMont, other: *const FpMont) void {
    self.* = self.mul(other);
}

pub fn div(self: *const FpMont, other: *const FpMont) !FpMont {
    var inverse = try other.inv();
    return self.mul(&inverse);
}

pub fn divAssign(self: *FpMont, other: *const FpMont) !void {
    self.* = try self.div(other);
}

// we use double and add to multiply by a small integer, this is faster than Montgomery multiplication for very small hamming weights
pub fn mulBySmallInt(self: *const FpMont, other: u8) FpMont {
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

pub fn mulBySmallIntAssign(self: *FpMont, other: u8) void {
    self.* = self.mulBySmallInt(other);
}

pub fn square(self: *const FpMont) FpMont {
    return self.mul(self);
}

pub fn squareAssign(self: *FpMont) void {
    self.* = self.square();
}

// we get (aR)^(-1) mod P = a^-1 * R^-1 mod P with extended euclidean algorithm
// the we use montgomery multiplication by precomputed R^3 mod P to get a^-1 * R mod P
pub fn inv(self: *const FpMont) !FpMont {
    if (self.value == 0) {
        return error.DivisionByZero;
    }

    var old_r: u256 = self.value;
    var r: u256 = curve_parameters.FP_MOD;
    var old_s: u256 = 1;
    var s: u256 = 0;
    var old_t: u256 = 0;
    var t: u256 = 1;
    var i: u256 = 0;
    while (r != 0) {
        const quotient: u256 = old_r / r;

        // Update remainders: (old_r, r) := (r, old_r - quotient * r)
        const temp_r = r;
        r = old_r -% (quotient *% r);
        old_r = temp_r;

        // Update s coefficients: (old_s, s) := (s, old_s - quotient * s)
        const temp_s = s;
        s = old_s -% (quotient *% s);
        old_s = temp_s;

        // Update t coefficients: (old_t, t) := (t, old_t - quotient * t)
        const temp_t = t;
        t = old_t -% (quotient *% t);
        old_t = temp_t;
        i += 1;
    }
    const first_bit = old_s & (1 << 255);
    const x = FpMont{
        .value = if (first_bit == 0) old_s else old_s +% curve_parameters.FP_MOD,
    };

    return x.mul(&FpMont{ .value = curve_parameters.MONTGOMERY_R3_MOD_P });
}

pub fn invAssign(self: *FpMont) void {
    self.* = self.inv();
}

pub fn pow(self: *const FpMont, exponent: u256) FpMont {
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

pub fn powAssign(self: *FpMont, exponent: u256) void {
    self.* = self.pow(exponent);
}

pub fn equal(self: *const FpMont, other: *const FpMont) bool {
    return self.value == other.value;
}

// ============================================================================
// TESTS - Adapted from Fp.zig for Montgomery form
// ============================================================================

test "FpMont.init basic initialization" {
    const a = FpMont.init(123);
    const result = a.toStandardRepresentation();
    try std.testing.expect(result == 123);
}

test "FpMont.init with modular reduction" {
    const a = FpMont.init(curve_parameters.FP_MOD + 5);
    const result = a.toStandardRepresentation();
    try std.testing.expect(result == 5);
}

test "FpMont.add basic addition" {
    const a = FpMont.init(10);
    const b = FpMont.init(20);
    const result = a.add(&b);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 30);
}

test "FpMont.add with modular reduction" {
    const a = FpMont.init(curve_parameters.FP_MOD - 1);
    const b = FpMont.init(5);
    const result = a.add(&b);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 4);
}

test "FpMont.add with zero" {
    const a = FpMont.init(100);
    const b = FpMont.init(0);
    const result = a.add(&b);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 100);
}

test "FpMont.add resulting in modulus" {
    const a = FpMont.init(curve_parameters.FP_MOD - 10);
    const b = FpMont.init(10);
    const result = a.add(&b);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 0);
}

test "FpMont.neg basic negation" {
    const a = FpMont.init(100);
    const result = a.neg();
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == curve_parameters.FP_MOD - 100);
}

test "FpMont.neg of zero" {
    const a = FpMont.init(0);
    const result = a.neg();
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 0);
}

test "FpMont.neg of maximum value" {
    const a = FpMont.init(curve_parameters.FP_MOD - 1);
    const result = a.neg();
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 1);
}

test "FpMont.sub basic subtraction" {
    const a = FpMont.init(50);
    const b = FpMont.init(20);
    const result = a.sub(&b);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 30);
}

test "FpMont.sub with underflow" {
    const a = FpMont.init(10);
    const b = FpMont.init(20);
    const result = a.sub(&b);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == curve_parameters.FP_MOD - 10);
}

test "FpMont.sub with zero" {
    const a = FpMont.init(100);
    const b = FpMont.init(0);
    const result = a.sub(&b);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 100);
}

test "FpMont.sub from zero" {
    const a = FpMont.init(0);
    const b = FpMont.init(25);
    const result = a.sub(&b);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == curve_parameters.FP_MOD - 25);
}

test "FpMont.mul basic multiplication" {
    const a = FpMont.init(6);
    const b = FpMont.init(5);
    const result = a.mul(&b);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 30);
}

test "FpMont.mul with zero" {
    const a = FpMont.init(100);
    const b = FpMont.init(0);
    const result = a.mul(&b);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 0);
}

test "FpMont.mul with one" {
    const a = FpMont.init(123);
    const b = FpMont.init(1);
    const result = a.mul(&b);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 123);
}

test "FpMont.mul with modular reduction" {
    const a = FpMont.init(curve_parameters.FP_MOD - 1);
    const b = FpMont.init(2);
    const result = a.mul(&b);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == curve_parameters.FP_MOD - 2);
}

test "FpMont.mul large values" {
    const a = FpMont.init(0x1000000000000000000000000000000000000000000000000000000000000000);
    const b = FpMont.init(0x2000000000000000000000000000000000000000000000000000000000000000);
    const result = a.mul(&b);
    const result_std = result.toStandardRepresentation();
    // This will test the modular reduction behavior with large numbers
    try std.testing.expect(result_std < curve_parameters.FP_MOD);
}

test "FpMont.mulBySmallInt basic multiplication" {
    const a = FpMont.init(2);
    const result = a.mulBySmallInt(3);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 6);
}

test "FpMont.square basic squaring" {
    const a = FpMont.init(7);
    const result = a.square();
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 49);
}

test "FpMont.pow basic power" {
    const a = FpMont.init(2);
    const result = a.pow(3);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 8);
}

test "FpMont.pow to power of zero" {
    const a = FpMont.init(123);
    const result = a.pow(0);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 1);
}

test "FpMont.pow to power of one" {
    const a = FpMont.init(456);
    const result = a.pow(1);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 456);
}

test "FpMont.pow with base zero" {
    const a = FpMont.init(0);
    const result = a.pow(5);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 0);
}

test "FpMont.pow with base one" {
    const a = FpMont.init(1);
    const result = a.pow(100);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 1);
}

test "FpMont.pow large exponent" {
    const a = FpMont.init(3);
    const result = a.pow(10);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 59049);
}

test "FpMont.pow with modular reduction" {
    const a = FpMont.init(curve_parameters.FP_MOD - 1);
    const result = a.pow(2);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 1);
}

test "FpMont.inv basic inverse" {
    const a = FpMont.init(2);
    const a_inv = try a.inv();
    const product = a.mul(&a_inv);
    const product_std = product.toStandardRepresentation();
    try std.testing.expect(product_std == 1);
}

test "FpMont.inv of one" {
    const a = FpMont.init(1);
    const result = try a.inv();
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 1);
}

test "FpMont.inv double inverse" {
    const a = FpMont.init(17);
    const a_inv = try a.inv();
    const a_double_inv = try a_inv.inv();
    const a_std = a.toStandardRepresentation();
    const a_double_inv_std = a_double_inv.toStandardRepresentation();
    try std.testing.expect(a_double_inv_std == a_std);
}

test "FpMont.inv with known value" {
    const a = FpMont.init(3);
    const a_inv = try a.inv();
    const product = a.mul(&a_inv);
    const product_std = product.toStandardRepresentation();
    try std.testing.expect(product_std == 1);
}

test "FpMont.inv large value" {
    const a = FpMont.init(12345678);
    const a_inv = try a.inv();
    const product = a.mul(&a_inv);
    const product_std = product.toStandardRepresentation();
    try std.testing.expect(product_std == 1);
}

test "FpMont.inv division by zero" {
    const a = FpMont.init(0);
    try std.testing.expectError(error.DivisionByZero, a.inv());
}

test "FpMont.equal basic equality" {
    const a = FpMont.init(123);
    const b = FpMont.init(123);
    try std.testing.expect(a.equal(&b));
}

test "FpMont.equal different values" {
    const a = FpMont.init(123);
    const b = FpMont.init(456);
    try std.testing.expect(!a.equal(&b));
}

test "FpMont.mul near modulus boundary" {
    const a = FpMont.init(curve_parameters.FP_MOD - 1);
    const b = FpMont.init(curve_parameters.FP_MOD - 1);
    const result = a.mul(&b);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == 1);
}

test "FpMont.mul maximum values causing overflow" {
    const a = FpMont.init(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF);
    const b = FpMont.init(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF);
    const result = a.mul(&b);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std < curve_parameters.FP_MOD);
}

test "FpMont.mul distributive property" {
    const a = FpMont.init(123);
    const b = FpMont.init(456);
    const c = FpMont.init(789);
    const left = a.mul(&b.add(&c));
    const right = a.mul(&b).add(&a.mul(&c));
    const left_std = left.toStandardRepresentation();
    const right_std = right.toStandardRepresentation();
    try std.testing.expect(left_std == right_std);
}

test "FpMont.mul associative property" {
    const a = FpMont.init(123);
    const b = FpMont.init(456);
    const c = FpMont.init(789);
    const left = a.mul(&b).mul(&c);
    const right = a.mul(&b.mul(&c));
    const left_std = left.toStandardRepresentation();
    const right_std = right.toStandardRepresentation();
    try std.testing.expect(left_std == right_std);
}

test "FpMont.add modular wraparound edge case" {
    const a = FpMont.init(curve_parameters.FP_MOD - 1);
    const b = FpMont.init(curve_parameters.FP_MOD - 1);
    const result = a.add(&b);
    const result_std = result.toStandardRepresentation();
    try std.testing.expect(result_std == curve_parameters.FP_MOD - 2);
}

test "FpMont.pow edge case with large exponent" {
    const a = FpMont.init(2);
    const result = a.pow(256);
    const result_std = result.toStandardRepresentation();
    // 2^256 mod FP_MOD should be computed correctly
    try std.testing.expect(result_std < curve_parameters.FP_MOD);
}

test "FpMont.inv mathematical property a * a^-1 = 1" {
    const values = [_]u256{ 2, 3, 7, 11, 13, 17, 65537, curve_parameters.FP_MOD - 1 };
    for (values) |val| {
        const a = FpMont.init(val);
        const a_inv = try a.inv();
        const product = a.mul(&a_inv);
        const product_std = product.toStandardRepresentation();
        try std.testing.expect(product_std == 1);
    }
}

// Additional tests for methods that exist in FpMont but not in Fp

test "FpMont.addAssign basic assignment" {
    var a = FpMont.init(10);
    const b = FpMont.init(20);
    a.addAssign(&b);
    const result_std = a.toStandardRepresentation();
    try std.testing.expect(result_std == 30);
}

test "FpMont.subAssign basic assignment" {
    var a = FpMont.init(50);
    const b = FpMont.init(20);
    a.subAssign(&b);
    const result_std = a.toStandardRepresentation();
    try std.testing.expect(result_std == 30);
}

test "FpMont.mulAssign basic assignment" {
    var a = FpMont.init(6);
    const b = FpMont.init(5);
    a.mulAssign(&b);
    const result_std = a.toStandardRepresentation();
    try std.testing.expect(result_std == 30);
}

test "FpMont.mulBySmallIntAssign basic assignment" {
    var a = FpMont.init(2);
    a.mulBySmallIntAssign(3);
    const result_std = a.toStandardRepresentation();
    try std.testing.expect(result_std == 6);
}

test "FpMont.squareAssign basic assignment" {
    var a = FpMont.init(7);
    a.squareAssign();
    const result_std = a.toStandardRepresentation();
    try std.testing.expect(result_std == 49);
}

test "FpMont.powAssign basic assignment" {
    var a = FpMont.init(2);
    a.powAssign(3);
    const result_std = a.toStandardRepresentation();
    try std.testing.expect(result_std == 8);
}

test "FpMont.negAssign basic assignment" {
    var a = FpMont.init(100);
    a.negAssign();
    const result_std = a.toStandardRepresentation();
    try std.testing.expect(result_std == curve_parameters.FP_MOD - 100);
}

// Test Montgomery representation consistency
test "FpMont.toStandardRepresentation round trip" {
    const values = [_]u256{ 0, 1, 2, 123, 456, 789, curve_parameters.FP_MOD - 1 };
    for (values) |val| {
        const mont = FpMont.init(val);
        const back_to_std = mont.toStandardRepresentation();
        try std.testing.expect(back_to_std == val);
    }
}
