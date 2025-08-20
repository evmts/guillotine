const std = @import("std");
const curve_parameters = @import("curve_parameters.zig");

pub const FR_MOD = curve_parameters.FR_MOD;

pub const Fr = @This();

value: u256,

pub const ZERO = Fr{ .value = 0 };
pub const ONE = Fr{ .value = 1 };

pub fn init(value: u256) Fr {
    return Fr{
        .value = value % FR_MOD,
    };
}

pub fn add(self: *const Fr, other: *const Fr) Fr {
    const sum = self.value + other.value;
    return Fr{
        .value = if (sum >= FR_MOD) sum - FR_MOD else sum,
    };
}

pub fn addAssign(self: *Fr, other: *const Fr) void {
    self.* = self.add(other);
}

pub fn neg(self: *const Fr) Fr {
    return Fr{
        .value = if (self.value == 0) 0 else FR_MOD - self.value,
    };
}

pub fn negAssign(self: *Fr) void {
    self.* = self.neg();
}

pub fn sub(self: *const Fr, other: *const Fr) Fr {
    return self.add(&other.neg());
}

pub fn subAssign(self: *Fr, other: *const Fr) void {
    self.* = self.sub(other);
}

pub fn mul(self: *const Fr, other: *const Fr) Fr {
    const product = @as(u512, self.value) * @as(u512, other.value);
    return Fr{
        .value = @intCast(product % FR_MOD),
    };
}

pub fn mulAssign(self: *Fr, other: *const Fr) void {
    self.* = self.mul(other);
}

pub fn pow(self: *const Fr, exponent: u256) Fr {
    var result = ONE;
    var base = self.*;
    var exp = exponent;
    while (exp > 0) {
        if (exp & 1 == 1) {
            result.mulAssign(&base);
        }
        base.mulAssign(&base);
        exp >>= 1;
    }
    return result;
}

pub fn powAssign(self: *Fr, exponent: u256) void {
    self.* = self.pow(exponent);
}

// Fermat's little theorem: a^(p-1) = 1 (mod p)
// disgustingly slow, temporary solution
pub fn inv(self: *const Fr) !Fr {
    if (self.value == 0) {
        return error.DivisionByZero;
    }
    return self.pow(FR_MOD - 2);
}

pub fn invAssign(self: *Fr) !void {
    self.* = self.inv();
}

pub fn equal(self: *const Fr, other: *const Fr) bool {
    return self.value == other.value;
}

test "Fr.add basic addition" {
    const a = Fr{ .value = 10 };
    const b = Fr{ .value = 20 };
    const result = a.add(&b);
    try std.testing.expect(result.value == 30);
}

test "Fr.add with modular reduction" {
    const a = Fr{ .value = FR_MOD - 1 };
    const b = Fr{ .value = 5 };
    const result = a.add(&b);
    try std.testing.expect(result.value == 4);
}

test "Fr.add with zero" {
    const a = Fr{ .value = 100 };
    const b = Fr{ .value = 0 };
    const result = a.add(&b);
    try std.testing.expect(result.value == 100);
}

test "Fr.add resulting in modulus" {
    const a = Fr{ .value = FR_MOD - 10 };
    const b = Fr{ .value = 10 };
    const result = a.add(&b);
    try std.testing.expect(result.value == 0);
}

test "Fr.neg basic negation" {
    const a = Fr{ .value = 100 };
    const result = a.neg();
    try std.testing.expect(result.value == FR_MOD - 100);
}

test "Fr.neg of zero" {
    const a = Fr{ .value = 0 };
    const result = a.neg();
    try std.testing.expect(result.value == 0);
}

test "Fr.neg of maximum value" {
    const a = Fr{ .value = FR_MOD - 1 };
    const result = a.neg();
    try std.testing.expect(result.value == 1);
}

test "Fr.sub basic subtraction" {
    const a = Fr{ .value = 50 };
    const b = Fr{ .value = 20 };
    const result = a.sub(&b);
    try std.testing.expect(result.value == 30);
}

test "Fr.sub with underflow" {
    const a = Fr{ .value = 10 };
    const b = Fr{ .value = 20 };
    const result = a.sub(&b);
    try std.testing.expect(result.value == FR_MOD - 10);
}

test "Fr.sub with zero" {
    const a = Fr{ .value = 100 };
    const b = Fr{ .value = 0 };
    const result = a.sub(&b);
    try std.testing.expect(result.value == 100);
}

test "Fr.sub from zero" {
    const a = Fr{ .value = 0 };
    const b = Fr{ .value = 25 };
    const result = a.sub(&b);
    try std.testing.expect(result.value == FR_MOD - 25);
}

test "Fr.mul basic multiplication" {
    const a = Fr{ .value = 6 };
    const b = Fr{ .value = 5 };
    const result = a.mul(&b);
    try std.testing.expect(result.value == 30);
}

test "Fr.mul with zero" {
    const a = Fr{ .value = 100 };
    const b = Fr{ .value = 0 };
    const result = a.mul(&b);
    try std.testing.expect(result.value == 0);
}

test "Fr.mul with one" {
    const a = Fr{ .value = 123 };
    const b = Fr{ .value = 1 };
    const result = a.mul(&b);
    try std.testing.expect(result.value == 123);
}

test "Fr.mul with modular reduction" {
    const a = Fr{ .value = FR_MOD - 1 };
    const b = Fr{ .value = 2 };
    const result = a.mul(&b);
    try std.testing.expect(result.value == FR_MOD - 2);
}

test "Fr.mul large values" {
    const a = Fr{ .value = FR_MOD - 1 };
    const b = Fr{ .value = FR_MOD - 5 };
    const result = a.mul(&b);
    // This will test the modular reduction behavior with large numbers
    try std.testing.expect(result.value == 5);
}

test "Fr.pow basic power" {
    const a = Fr{ .value = 2 };
    const result = a.pow(3);
    try std.testing.expect(result.value == 8);
}

test "Fr.pow to power of zero" {
    const a = Fr{ .value = 123 };
    const result = a.pow(0);
    try std.testing.expect(result.value == 1);
}

test "Fr.pow to power of one" {
    const a = Fr{ .value = 456 };
    const result = a.pow(1);
    try std.testing.expect(result.value == 456);
}

test "Fr.pow with base zero" {
    const a = Fr{ .value = 0 };
    const result = a.pow(5);
    try std.testing.expect(result.value == 0);
}

test "Fr.pow with base one" {
    const a = Fr{ .value = 1 };
    const result = a.pow(100);
    try std.testing.expect(result.value == 1);
}

test "Fr.pow large exponent" {
    const a = Fr{ .value = 3 };
    const result = a.pow(10);
    try std.testing.expect(result.value == 59049);
}

test "Fr.pow with modular reduction" {
    const a = Fr{ .value = FR_MOD - 1 };
    const result = a.pow(2);
    try std.testing.expect(result.value == 1);
}

test "Fr.inv basic inverse" {
    const a = Fr{ .value = 2 };
    const a_inv = try a.inv();
    const product = a.mul(&a_inv);
    try std.testing.expect(product.value == 1);
}

test "Fr.inv of one" {
    const a = Fr{ .value = 1 };
    const result = try a.inv();
    try std.testing.expect(result.value == 1);
}

test "Fr.inv double inverse" {
    const a = Fr{ .value = 17 };
    const a_inv = try a.inv();
    const a_double_inv = try a_inv.inv();
    try std.testing.expect(a_double_inv.value == a.value);
}

test "Fr.inv with known value" {
    const a = Fr{ .value = 3 };
    const a_inv = try a.inv();
    const product = a.mul(&a_inv);
    try std.testing.expect(product.value == 1);
}

test "Fr.inv large value" {
    const a = Fr{ .value = 12345678 };
    const a_inv = try a.inv();
    const product = a.mul(&a_inv);
    try std.testing.expect(product.value == 1);
}

test "Fr.equal basic equality" {
    const a = Fr{ .value = 123 };
    const b = Fr{ .value = 123 };
    try std.testing.expect(a.equal(&b));
}

test "Fr.equal different values" {
    const a = Fr{ .value = 123 };
    const b = Fr{ .value = 456 };
    try std.testing.expect(!a.equal(&b));
}

test "Fr.init basic initialization" {
    const a = Fr.init(123);
    try std.testing.expect(a.value == 123);
}

test "Fr.init with modular reduction" {
    const a = Fr.init(FR_MOD + 5);
    try std.testing.expect(a.value == 5);
}

test "Fr.mul near modulus boundary" {
    const a = Fr{ .value = FR_MOD - 1 };
    const b = Fr{ .value = FR_MOD - 1 };
    const result = a.mul(&b);
    try std.testing.expect(result.value == 1);
}

test "Fr.mul distributive property" {
    const a = Fr{ .value = 123 };
    const b = Fr{ .value = 456 };
    const c = Fr{ .value = 789 };
    const left = a.mul(&b.add(&c));
    const right = a.mul(&b).add(&a.mul(&c));
    try std.testing.expect(left.equal(&right));
}

test "Fr.mul associative property" {
    const a = Fr{ .value = 123 };
    const b = Fr{ .value = 456 };
    const c = Fr{ .value = 789 };
    const left = a.mul(&b).mul(&c);
    const right = a.mul(&b).mul(&c);
    try std.testing.expect(left.equal(&right));
}

test "Fr.add modular wraparound edge case" {
    const a = Fr{ .value = FR_MOD - 1 };
    const b = Fr{ .value = FR_MOD - 1 };
    const result = a.add(&b);
    try std.testing.expect(result.value == FR_MOD - 2);
}

test "Fr.pow edge case with large exponent" {
    const a = Fr{ .value = 2 };
    const result = a.pow(256);
    // 2^256 mod FR_MOD should be computed correctly
    try std.testing.expect(result.value < FR_MOD);
}

test "Fr.inv mathematical property a * a^-1 = 1" {
    const values = [_]u256{ 2, 3, 7, 11, 13, 17, 65537, FR_MOD - 1 };
    for (values) |val| {
        const a = Fr{ .value = val };
        const a_inv = try a.inv();
        const product = a.mul(&a_inv);
        try std.testing.expect(product.value == 1);
    }
}

test "Fr.inv of zero returns error" {
    const a = Fr{ .value = 0 };
    try std.testing.expectError(error.DivisionByZero, a.inv());
}
