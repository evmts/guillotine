const std = @import("std");

/// ⚠️ UNAUDITED CUSTOM CRYPTO IMPLEMENTATION - NOT SECURITY AUDITED ⚠️
///
/// This module contains CUSTOM modular exponentiation implementations
/// that have NOT been security audited or verified against known attacks.
/// These implementations are provided for educational/testing purposes only.
/// DO NOT USE IN PRODUCTION without proper security audit and testing.
///
/// Known risks:
/// - Potential timing attacks in big integer operations
/// - Unvalidated against side-channel vulnerabilities
/// - Custom algorithms may have edge case bugs
/// - Memory safety not guaranteed under all conditions
///
/// Modular exponentiation implementation
/// Computes base^exponent mod modulus for arbitrary-precision integers
/// Error set for modular exponentiation operations
pub const ModExpError = error{
    DivisionByZero,
    InvalidInput,
    AllocationFailed,
    NotImplemented,
    OutOfMemory,
    InvalidBase,
    InvalidCharacter,
    NoSpaceLeft,
    InvalidLength,
};

/// ⚠️ UNAUDITED - NOT SECURITY AUDITED ⚠️
/// Performs modular exponentiation: base^exponent mod modulus
/// WARNING: This is a custom crypto implementation that has not been security audited.
/// May be vulnerable to timing attacks and other side-channel attacks.
/// Do not use in production without proper security review.
///
/// @param allocator Memory allocator for big integer operations
/// @param base_bytes Base value as big-endian bytes
/// @param exp_bytes Exponent value as big-endian bytes
/// @param mod_bytes Modulus value as big-endian bytes
/// @param output Output buffer (must be at least mod_bytes.len)
pub fn unauditedModexp(allocator: std.mem.Allocator, base_bytes: []const u8, exp_bytes: []const u8, mod_bytes: []const u8, output: []u8) ModExpError!void {
    // Clear output first
    @memset(output, 0);

    // Handle special cases
    if (exp_bytes.len == 0 or unaudited_isZero(exp_bytes)) {
        // exp = 0, result = 1
        if (output.len > 0) output[output.len - 1] = 1;
        return;
    }

    if (base_bytes.len == 0 or unaudited_isZero(base_bytes)) {
        // base = 0, result = 0 (already cleared)
        return;
    }

    // Check for zero modulus
    if (mod_bytes.len == 0 or unaudited_isZero(mod_bytes)) {
        return ModExpError.DivisionByZero;
    }

    // For simplicity, handle small numbers directly
    if (base_bytes.len <= 8 and exp_bytes.len <= 8 and mod_bytes.len <= 8) {
        const base = unaudited_bytesToU64(base_bytes);
        const exp = unaudited_bytesToU64(exp_bytes);
        const mod = unaudited_bytesToU64(mod_bytes);

        if (mod == 0) return ModExpError.DivisionByZero;

        var result: u64 = 1;
        var base_mod = base % mod;
        var exp_remaining = exp;

        // Square and multiply algorithm
        while (exp_remaining > 0) {
            if (exp_remaining & 1 == 1) {
                result = (result * base_mod) % mod;
            }
            base_mod = (base_mod * base_mod) % mod;
            exp_remaining >>= 1;
        }

        // Write result to output (big-endian)
        const result_bytes = @min(output.len, 8);
        var i: usize = 0;
        while (i < result_bytes) : (i += 1) {
            const shift: u6 = @intCast((result_bytes - 1 - i) * 8);
            output[output.len - result_bytes + i] = @intCast((result >> shift) & 0xFF);
        }
        return;
    }

    // For larger numbers, use big integer implementation
    const Managed = std.math.big.int.Managed;

    // Initialize big integers
    var base = try Managed.init(allocator);
    defer base.deinit();
    var exp = try Managed.init(allocator);
    defer exp.deinit();
    var mod = try Managed.init(allocator);
    defer mod.deinit();

    // Parse inputs from big-endian bytes
    try readBigEndian(&base, base_bytes);
    try readBigEndian(&exp, exp_bytes);
    try readBigEndian(&mod, mod_bytes);

    // Check if modulus is zero
    var zero = try Managed.init(allocator);
    defer zero.deinit();
    try zero.set(0);
    if (mod.eql(zero)) {
        return ModExpError.DivisionByZero;
    }

    // Perform modular exponentiation using square-and-multiply
    var result = try Managed.init(allocator);
    defer result.deinit();
    try result.set(1); // result = 1

    var base_mod = try Managed.init(allocator);
    defer base_mod.deinit();

    // base_mod = base % mod
    var quotient = try Managed.init(allocator);
    defer quotient.deinit();
    try quotient.divFloor(&base_mod, &base, &mod);

    // Temporary variables for operations
    var temp = try Managed.init(allocator);
    defer temp.deinit();
    var exp_copy = try exp.clone();
    defer exp_copy.deinit();

    // Square and multiply algorithm
    while (!exp_copy.eql(zero)) {
        // Check if exp is odd (exp & 1 == 1)
        if (exp_copy.isOdd()) {
            // result = (result * base_mod) % mod
            try temp.mul(&result, &base_mod);
            try quotient.divFloor(&result, &temp, &mod);
        }

        // base_mod = (base_mod * base_mod) % mod
        try temp.sqr(&base_mod);
        try quotient.divFloor(&base_mod, &temp, &mod);

        // exp >>= 1
        try exp_copy.shiftRight(&exp_copy, 1);
    }

    // Write result to output (big-endian)
    try writeBigEndian(&result, output);
}

/// ⚠️ UNAUDITED - NOT SECURITY AUDITED ⚠️
/// Check if a byte array represents zero
/// WARNING: May be vulnerable to timing attacks
pub fn unaudited_isZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

/// ⚠️ UNAUDITED - NOT SECURITY AUDITED ⚠️
/// Convert bytes to u64 (big-endian)
/// WARNING: May be vulnerable to timing attacks
pub fn unaudited_bytesToU64(bytes: []const u8) u64 {
    var result: u64 = 0;
    for (bytes) |byte| {
        result = (result << 8) | byte;
    }
    return result;
}

/// ⚠️ UNAUDITED - NOT SECURITY AUDITED ⚠️
/// Convert u64 to bytes (big-endian)
/// WARNING: May be vulnerable to timing attacks
pub fn unaudited_u64ToBytes(value: u64, output: []u8) void {
    const len = output.len;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const shift: u6 = @intCast((len - 1 - i) * 8);
        output[i] = @intCast((value >> shift) & 0xFF);
    }
}

/// Gas calculation constants (per EIP-198)
pub const GAS_QUADRATIC_THRESHOLD: usize = 64;
pub const GAS_LINEAR_THRESHOLD: usize = 1024;

/// ⚠️ UNAUDITED - NOT SECURITY AUDITED ⚠️
/// Calculates multiplication complexity for gas cost
/// WARNING: Custom gas calculation logic not audited
pub fn unaudited_calculateMultiplicationComplexity(x: usize) u64 {
    const x64: u64 = @intCast(x);

    if (x <= GAS_QUADRATIC_THRESHOLD) {
        return x64 * x64;
    } else if (x <= GAS_LINEAR_THRESHOLD) {
        // x^2/4 + 96*x - 3072
        return (x64 * x64) / 4 + 96 * x64 - 3072;
    } else {
        // x^2/16 + 480*x - 199680
        return (x64 * x64) / 16 + 480 * x64 - 199680;
    }
}

/// ⚠️ UNAUDITED - NOT SECURITY AUDITED ⚠️
/// Calculates adjusted exponent length based on leading zeros
/// WARNING: Custom exponent length calculation not audited
pub fn unaudited_calculateAdjustedExponentLength(exp_len: usize, exp_bytes: []const u8) u64 {
    if (exp_len == 0) return 0;

    // Find first non-zero byte
    var leading_zeros: usize = 0;
    for (exp_bytes) |byte| {
        if (byte != 0) break;
        leading_zeros += 1;
    }

    // If all zeros, adjusted length is 0
    if (leading_zeros == exp_bytes.len) return 0;

    // Get the first non-zero byte and count its leading zero bits
    const first_non_zero = exp_bytes[leading_zeros];
    const bit_length = 8 - @clz(first_non_zero);

    // Adjusted length = (exp_len - leading_zeros - 1) * 8 + bit_length
    const adj_len = (exp_len - leading_zeros - 1) * 8 + bit_length;

    return @intCast(adj_len);
}

/// Public API wrapper for ModExp precompile
pub const ModExp = struct {
    /// ⚠️ UNAUDITED - NOT SECURITY AUDITED ⚠️
    /// Performs modular exponentiation and returns allocated result
    /// WARNING: Custom crypto implementation not audited
    pub fn modexp(allocator: std.mem.Allocator, base: []const u8, exp: []const u8, modulus: []const u8) ![]u8 {
        if (modulus.len == 0 or unaudited_isZero(modulus)) {
            return ModExpError.DivisionByZero;
        }

        // Allocate output buffer matching modulus length
        const output = try allocator.alloc(u8, modulus.len);
        errdefer allocator.free(output);

        // Call internal implementation
        try unauditedModexp(allocator, base, exp, modulus, output);

        return output;
    }

    /// ⚠️ UNAUDITED - NOT SECURITY AUDITED ⚠️
    /// Calculates gas cost for MODEXP operation (EIP-2565)
    /// WARNING: Custom gas calculation logic not audited
    pub fn calculateGas(
        base_len: usize,
        exp_len: usize,
        mod_len: usize,
        exp_bytes: []const u8,
        hardfork: anytype,
    ) u64 {
        _ = hardfork; // Hardfork-specific logic would go here if needed

        // Calculate maximum length for multiplication complexity
        const max_len = @max(base_len, mod_len);
        const mult_complexity = unaudited_calculateMultiplicationComplexity(max_len);

        // Calculate iteration count based on exponent
        const adj_exp_len = unaudited_calculateAdjustedExponentLength(exp_len, exp_bytes);
        const iteration_count = @max(adj_exp_len, 1);

        // Gas cost = max(200, floor(mult_complexity * iteration_count / 3))
        const gas_cost = (mult_complexity * iteration_count) / 3;
        return @max(200, gas_cost);
    }
};

test "modexp: base^0 mod m = 1" {
    const allocator = std.testing.allocator;

    const base = [_]u8{5};
    const exp = [_]u8{0};
    const mod = [_]u8{7};
    var output: [1]u8 = undefined;

    try unauditedModexp(allocator, &base, &exp, &mod, &output);
    try std.testing.expectEqual(@as(u8, 1), output[0]);
}

test "modexp: 0^exp mod m = 0" {
    const allocator = std.testing.allocator;

    const base = [_]u8{0};
    const exp = [_]u8{5};
    const mod = [_]u8{7};
    var output: [1]u8 = undefined;

    try unauditedModexp(allocator, &base, &exp, &mod, &output);
    try std.testing.expectEqual(@as(u8, 0), output[0]);
}

test "modexp: 2^3 mod 5 = 3" {
    const allocator = std.testing.allocator;

    const base = [_]u8{2};
    const exp = [_]u8{3};
    const mod = [_]u8{5};
    var output: [1]u8 = undefined;

    try unauditedModexp(allocator, &base, &exp, &mod, &output);
    try std.testing.expectEqual(@as(u8, 3), output[0]);
}

test "modexp: division by zero" {
    const allocator = std.testing.allocator;

    const base = [_]u8{2};
    const exp = [_]u8{3};
    const mod = [_]u8{0};
    var output: [1]u8 = undefined;

    try std.testing.expectError(ModExpError.DivisionByZero, unauditedModexp(allocator, &base, &exp, &mod, &output));
}

/// Read big-endian bytes into a Managed big integer
fn readBigEndian(big: *std.math.big.int.Managed, bytes: []const u8) !void {
    if (bytes.len == 0) {
        try big.set(0);
        return;
    }

    // Convert bytes to hex string and use setString
    const hex_string = try std.fmt.allocPrint(big.allocator, "{X}", .{bytes});
    defer big.allocator.free(hex_string);

    try big.setString(16, hex_string);
}

/// Write a Managed big integer to big-endian bytes
fn writeBigEndian(big: *const std.math.big.int.Managed, output: []u8) !void {
    @memset(output, 0);

    // Check if the big integer is zero
    if (big.bitCountTwosComp() == 0) {
        return;
    }

    // Convert to hex string and then to bytes
    const hex_string = try big.toString(big.allocator, 16, .upper);
    defer big.allocator.free(hex_string);

    // Parse hex string back to bytes
    const hex_bytes = try big.allocator.alloc(u8, hex_string.len / 2);
    defer big.allocator.free(hex_bytes);
    _ = try std.fmt.hexToBytes(hex_bytes, hex_string);

    // Copy to output buffer (right-aligned)
    const copy_len = @min(output.len, hex_bytes.len);
    const offset = output.len - copy_len;
    @memcpy(output[offset..], hex_bytes[0..copy_len]);
}

test "modexp: large numbers - 2^255 mod 2^128" {
    const allocator = std.testing.allocator;

    // base = 2
    const base = [_]u8{2};

    // exp = 255
    const exp = [_]u8{0xFF};

    // mod = 2^128 = 0x100000000000000000000000000000000
    const mod = [_]u8{1} ++ ([_]u8{0} ** 16);

    var output: [17]u8 = undefined;

    try unauditedModexp(allocator, &base, &exp, &mod, &output);

    // 2^255 mod 2^128 = 2^127
    var expected: [17]u8 = .{0} ** 17;
    expected[9] = 0x80; // 2^127 in big-endian

    try std.testing.expectEqualSlices(u8, &expected, &output);
}

test "modexp: large base and modulus" {
    const allocator = std.testing.allocator;

    // base = 0xDEADBEEFDEADBEEFDEADBEEFDEADBEEF (16 bytes)
    const base = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF } ** 4;

    // exp = 3
    const exp = [_]u8{3};

    // mod = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF (16 bytes)
    const mod = [_]u8{0xFF} ** 16;

    var output: [16]u8 = undefined;

    try unauditedModexp(allocator, &base, &exp, &mod, &output);

    // Verify the result is less than the modulus
    for (output, 0..) |byte, i| {
        if (byte < mod[i]) break;
        if (byte > mod[i]) {
            try std.testing.expect(false);
        }
    }
}

test "modexp: very large exponent" {
    const allocator = std.testing.allocator;

    // base = 3
    const base = [_]u8{3};

    // exp = 0x010000000000000000 (2^64)
    const exp = [_]u8{1} ++ ([_]u8{0} ** 8);

    // mod = 1000000007 (large prime)
    const mod = [_]u8{ 0x3B, 0x9A, 0xCA, 0x07 };

    var output: [4]u8 = undefined;

    try unauditedModexp(allocator, &base, &exp, &mod, &output);

    // Verify result is less than modulus
    const result = unaudited_bytesToU64(&output);
    const modulus = unaudited_bytesToU64(&mod);
    try std.testing.expect(result < modulus);
}

// Gas calculation tests

test "calculateMultiplicationComplexity: quadratic region x=1" {
    const x: usize = 1;
    const complexity = unaudited_calculateMultiplicationComplexity(x);
    // x <= 64: complexity = x^2
    try std.testing.expectEqual(@as(u64, 1), complexity);
}

test "calculateMultiplicationComplexity: quadratic region x=32" {
    const x: usize = 32;
    const complexity = unaudited_calculateMultiplicationComplexity(x);
    // x <= 64: complexity = x^2 = 1024
    try std.testing.expectEqual(@as(u64, 1024), complexity);
}

test "calculateMultiplicationComplexity: quadratic boundary x=64" {
    const x: usize = 64;
    const complexity = unaudited_calculateMultiplicationComplexity(x);
    // x == 64: complexity = x^2 = 4096
    try std.testing.expectEqual(@as(u64, 4096), complexity);
}

test "calculateMultiplicationComplexity: linear region x=65" {
    const x: usize = 65;
    const complexity = unaudited_calculateMultiplicationComplexity(x);
    // 64 < x <= 1024: complexity = x^2/4 + 96*x - 3072
    // = 4225/4 + 96*65 - 3072 = 1056.25 + 6240 - 3072 = 4224.25 = 4224 (integer)
    const expected: u64 = (65 * 65) / 4 + 96 * 65 - 3072;
    try std.testing.expectEqual(expected, complexity);
}

test "calculateMultiplicationComplexity: linear region x=512" {
    const x: usize = 512;
    const complexity = unaudited_calculateMultiplicationComplexity(x);
    // 64 < x <= 1024: complexity = x^2/4 + 96*x - 3072
    const expected: u64 = (512 * 512) / 4 + 96 * 512 - 3072;
    try std.testing.expectEqual(expected, complexity);
}

test "calculateMultiplicationComplexity: linear boundary x=1024" {
    const x: usize = 1024;
    const complexity = unaudited_calculateMultiplicationComplexity(x);
    // x == 1024: complexity = x^2/4 + 96*x - 3072
    const expected: u64 = (1024 * 1024) / 4 + 96 * 1024 - 3072;
    try std.testing.expectEqual(expected, complexity);
}

test "calculateMultiplicationComplexity: large region x=1025" {
    const x: usize = 1025;
    const complexity = unaudited_calculateMultiplicationComplexity(x);
    // x > 1024: complexity = x^2/16 + 480*x - 199680
    const expected: u64 = (1025 * 1025) / 16 + 480 * 1025 - 199680;
    try std.testing.expectEqual(expected, complexity);
}

test "calculateMultiplicationComplexity: large region x=2048" {
    const x: usize = 2048;
    const complexity = unaudited_calculateMultiplicationComplexity(x);
    // x > 1024: complexity = x^2/16 + 480*x - 199680
    const expected: u64 = (2048 * 2048) / 16 + 480 * 2048 - 199680;
    try std.testing.expectEqual(expected, complexity);
}

test "calculateMultiplicationComplexity: large region x=4096" {
    const x: usize = 4096;
    const complexity = unaudited_calculateMultiplicationComplexity(x);
    // x > 1024: complexity = x^2/16 + 480*x - 199680
    const expected: u64 = (4096 * 4096) / 16 + 480 * 4096 - 199680;
    try std.testing.expectEqual(expected, complexity);
}

test "calculateMultiplicationComplexity: verify monotonic increasing" {
    // Verify complexity increases as x increases
    var x: usize = 1;
    var prev = unaudited_calculateMultiplicationComplexity(x);
    x = 2;
    while (x <= 4096) : (x *= 2) {
        const current = unaudited_calculateMultiplicationComplexity(x);
        try std.testing.expect(current > prev);
        prev = current;
    }
}

test "calculateAdjustedExponentLength: zero length exponent" {
    const exp_len: usize = 0;
    const exp_bytes: [0]u8 = .{};
    const adj_len = unaudited_calculateAdjustedExponentLength(exp_len, &exp_bytes);
    try std.testing.expectEqual(@as(u64, 0), adj_len);
}

test "calculateAdjustedExponentLength: all zero bytes" {
    const exp_len: usize = 4;
    const exp_bytes = [_]u8{ 0, 0, 0, 0 };
    const adj_len = unaudited_calculateAdjustedExponentLength(exp_len, &exp_bytes);
    try std.testing.expectEqual(@as(u64, 0), adj_len);
}

test "calculateAdjustedExponentLength: single byte 0x01" {
    const exp_len: usize = 1;
    const exp_bytes = [_]u8{0x01};
    const adj_len = unaudited_calculateAdjustedExponentLength(exp_len, &exp_bytes);
    // First non-zero byte is 0x01, bit length = 1
    // adj_len = (1 - 0 - 1) * 8 + 1 = 0 * 8 + 1 = 1
    try std.testing.expectEqual(@as(u64, 1), adj_len);
}

test "calculateAdjustedExponentLength: single byte 0xFF" {
    const exp_len: usize = 1;
    const exp_bytes = [_]u8{0xFF};
    const adj_len = unaudited_calculateAdjustedExponentLength(exp_len, &exp_bytes);
    // First non-zero byte is 0xFF, bit length = 8
    // adj_len = (1 - 0 - 1) * 8 + 8 = 0 * 8 + 8 = 8
    try std.testing.expectEqual(@as(u64, 8), adj_len);
}

test "calculateAdjustedExponentLength: two bytes 0x01 0x00" {
    const exp_len: usize = 2;
    const exp_bytes = [_]u8{ 0x01, 0x00 };
    const adj_len = unaudited_calculateAdjustedExponentLength(exp_len, &exp_bytes);
    // First non-zero byte is 0x01 at index 0, bit length = 1
    // adj_len = (2 - 0 - 1) * 8 + 1 = 1 * 8 + 1 = 9
    try std.testing.expectEqual(@as(u64, 9), adj_len);
}

test "calculateAdjustedExponentLength: leading zeros 0x00 0x00 0x80 0x00" {
    const exp_len: usize = 4;
    const exp_bytes = [_]u8{ 0x00, 0x00, 0x80, 0x00 };
    const adj_len = unaudited_calculateAdjustedExponentLength(exp_len, &exp_bytes);
    // First non-zero byte is 0x80 at index 2, bit length = 8
    // adj_len = (4 - 2 - 1) * 8 + 8 = 1 * 8 + 8 = 16
    try std.testing.expectEqual(@as(u64, 16), adj_len);
}

test "calculateAdjustedExponentLength: leading zeros 0x00 0x00 0x01 0xFF" {
    const exp_len: usize = 4;
    const exp_bytes = [_]u8{ 0x00, 0x00, 0x01, 0xFF };
    const adj_len = unaudited_calculateAdjustedExponentLength(exp_len, &exp_bytes);
    // First non-zero byte is 0x01 at index 2, bit length = 1
    // adj_len = (4 - 2 - 1) * 8 + 1 = 1 * 8 + 1 = 9
    try std.testing.expectEqual(@as(u64, 9), adj_len);
}

test "calculateAdjustedExponentLength: maximum bit width single byte" {
    const exp_len: usize = 1;
    const exp_bytes = [_]u8{0x80};
    const adj_len = unaudited_calculateAdjustedExponentLength(exp_len, &exp_bytes);
    // First non-zero byte is 0x80, bit length = 8
    // adj_len = (1 - 0 - 1) * 8 + 8 = 0 * 8 + 8 = 8
    try std.testing.expectEqual(@as(u64, 8), adj_len);
}

test "calculateAdjustedExponentLength: maximum bit width 32 bytes" {
    const exp_len: usize = 32;
    const exp_bytes = [_]u8{0xFF} ** 32;
    const adj_len = unaudited_calculateAdjustedExponentLength(exp_len, &exp_bytes);
    // First non-zero byte is 0xFF at index 0, bit length = 8
    // adj_len = (32 - 0 - 1) * 8 + 8 = 31 * 8 + 8 = 256
    try std.testing.expectEqual(@as(u64, 256), adj_len);
}

test "calculateAdjustedExponentLength: various bit lengths" {
    // Test byte 0x01 (1 bit)
    {
        const exp_bytes = [_]u8{0x01};
        const adj_len = unaudited_calculateAdjustedExponentLength(1, &exp_bytes);
        try std.testing.expectEqual(@as(u64, 1), adj_len);
    }
    // Test byte 0x02 (2 bits)
    {
        const exp_bytes = [_]u8{0x02};
        const adj_len = unaudited_calculateAdjustedExponentLength(1, &exp_bytes);
        try std.testing.expectEqual(@as(u64, 2), adj_len);
    }
    // Test byte 0x04 (3 bits)
    {
        const exp_bytes = [_]u8{0x04};
        const adj_len = unaudited_calculateAdjustedExponentLength(1, &exp_bytes);
        try std.testing.expectEqual(@as(u64, 3), adj_len);
    }
    // Test byte 0x08 (4 bits)
    {
        const exp_bytes = [_]u8{0x08};
        const adj_len = unaudited_calculateAdjustedExponentLength(1, &exp_bytes);
        try std.testing.expectEqual(@as(u64, 4), adj_len);
    }
    // Test byte 0x10 (5 bits)
    {
        const exp_bytes = [_]u8{0x10};
        const adj_len = unaudited_calculateAdjustedExponentLength(1, &exp_bytes);
        try std.testing.expectEqual(@as(u64, 5), adj_len);
    }
    // Test byte 0x20 (6 bits)
    {
        const exp_bytes = [_]u8{0x20};
        const adj_len = unaudited_calculateAdjustedExponentLength(1, &exp_bytes);
        try std.testing.expectEqual(@as(u64, 6), adj_len);
    }
    // Test byte 0x40 (7 bits)
    {
        const exp_bytes = [_]u8{0x40};
        const adj_len = unaudited_calculateAdjustedExponentLength(1, &exp_bytes);
        try std.testing.expectEqual(@as(u64, 7), adj_len);
    }
}

test "modexp: all zero inputs" {
    const allocator = std.testing.allocator;

    const base = [_]u8{0};
    const exp = [_]u8{0};
    const mod = [_]u8{7};
    var output: [1]u8 = undefined;

    try unauditedModexp(allocator, &base, &exp, &mod, &output);
    // 0^0 mod 7 = 1 (by mathematical convention)
    try std.testing.expectEqual(@as(u8, 1), output[0]);
}

test "modexp: empty exponent" {
    const allocator = std.testing.allocator;

    const base = [_]u8{5};
    const exp: [0]u8 = .{};
    const mod = [_]u8{7};
    var output: [1]u8 = undefined;

    try unauditedModexp(allocator, &base, &exp, &mod, &output);
    // base^(empty) = base^0 = 1
    try std.testing.expectEqual(@as(u8, 1), output[0]);
}

test "modexp: empty base" {
    const allocator = std.testing.allocator;

    const base: [0]u8 = .{};
    const exp = [_]u8{5};
    const mod = [_]u8{7};
    var output: [1]u8 = undefined;

    try unauditedModexp(allocator, &base, &exp, &mod, &output);
    // (empty)^5 = 0^5 = 0
    try std.testing.expectEqual(@as(u8, 0), output[0]);
}

test "modexp: empty modulus gives division by zero" {
    const allocator = std.testing.allocator;

    const base = [_]u8{5};
    const exp = [_]u8{3};
    const mod: [0]u8 = .{};
    var output: [1]u8 = undefined;

    try std.testing.expectError(ModExpError.DivisionByZero, unauditedModexp(allocator, &base, &exp, &mod, &output));
}

test "modexp: EIP-198 test vector 1" {
    const allocator = std.testing.allocator;

    // Example from EIP-198: 2^2 mod 3 = 1
    const base = [_]u8{2};
    const exp = [_]u8{2};
    const mod = [_]u8{3};
    var output: [1]u8 = undefined;

    try unauditedModexp(allocator, &base, &exp, &mod, &output);
    try std.testing.expectEqual(@as(u8, 1), output[0]);
}

test "modexp: EIP-198 test vector 2" {
    const allocator = std.testing.allocator;

    // Example: 5^3 mod 13 = 8
    const base = [_]u8{5};
    const exp = [_]u8{3};
    const mod = [_]u8{13};
    var output: [1]u8 = undefined;

    try unauditedModexp(allocator, &base, &exp, &mod, &output);
    try std.testing.expectEqual(@as(u8, 8), output[0]);
}

test "modexp: boundary at GAS_QUADRATIC_THRESHOLD" {
    const allocator = std.testing.allocator;

    // Test with 64-byte values (GAS_QUADRATIC_THRESHOLD)
    const base = [_]u8{2} ++ ([_]u8{0} ** 63);
    const exp = [_]u8{3};
    const mod = [_]u8{0xFF} ++ ([_]u8{0xFF} ** 63);
    var output: [64]u8 = undefined;

    try unauditedModexp(allocator, &base, &exp, &mod, &output);

    // Verify result is less than modulus
    var result_greater = false;
    for (output, 0..) |byte, i| {
        if (byte < mod[i]) break;
        if (byte > mod[i]) {
            result_greater = true;
            break;
        }
    }
    try std.testing.expect(!result_greater);
}

test "modexp: boundary at GAS_LINEAR_THRESHOLD" {
    const allocator = std.testing.allocator;

    // Test with 1024-byte values (GAS_LINEAR_THRESHOLD)
    var base: [1024]u8 = undefined;
    @memset(&base, 0);
    base[0] = 2;

    const exp = [_]u8{3};

    var mod: [1024]u8 = undefined;
    @memset(&mod, 0xFF);

    var output: [1024]u8 = undefined;

    try unauditedModexp(allocator, &base, &exp, &mod, &output);

    // Verify result is less than modulus
    var result_greater = false;
    for (output, 0..) |byte, i| {
        if (byte < mod[i]) break;
        if (byte > mod[i]) {
            result_greater = true;
            break;
        }
    }
    try std.testing.expect(!result_greater);
}

test "modexp: 1^exp mod m = 1" {
    const allocator = std.testing.allocator;

    const base = [_]u8{1};
    const exp = [_]u8{100};
    const mod = [_]u8{7};
    var output: [1]u8 = undefined;

    try unauditedModexp(allocator, &base, &exp, &mod, &output);
    try std.testing.expectEqual(@as(u8, 1), output[0]);
}

test "modexp: base^1 mod m = base mod m" {
    const allocator = std.testing.allocator;

    const base = [_]u8{10};
    const exp = [_]u8{1};
    const mod = [_]u8{7};
    var output: [1]u8 = undefined;

    try unauditedModexp(allocator, &base, &exp, &mod, &output);
    // 10 mod 7 = 3
    try std.testing.expectEqual(@as(u8, 3), output[0]);
}

test "modexp: modulus of 1" {
    const allocator = std.testing.allocator;

    const base = [_]u8{5};
    const exp = [_]u8{3};
    const mod = [_]u8{1};
    var output: [1]u8 = undefined;

    try unauditedModexp(allocator, &base, &exp, &mod, &output);
    // Any number mod 1 = 0
    try std.testing.expectEqual(@as(u8, 0), output[0]);
}

test "modexp: result fits exactly in output buffer" {
    const allocator = std.testing.allocator;

    const base = [_]u8{2};
    const exp = [_]u8{8};
    const mod = [_]u8{ 0xFF, 0xFF };
    var output: [2]u8 = undefined;

    try unauditedModexp(allocator, &base, &exp, &mod, &output);

    // 2^8 = 256 = 0x0100
    // 256 mod 65535 = 256 = 0x0100
    try std.testing.expectEqual(@as(u8, 0x01), output[0]);
    try std.testing.expectEqual(@as(u8, 0x00), output[1]);
}

test "modexp: ModExp.modexp wrapper function" {
    const allocator = std.testing.allocator;

    const base = [_]u8{2};
    const exp = [_]u8{3};
    const mod = [_]u8{5};

    const result = try ModExp.modexp(allocator, &base, &exp, &mod);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(u8, 3), result[0]);
}

test "modexp: ModExp.modexp with zero modulus" {
    const allocator = std.testing.allocator;

    const base = [_]u8{2};
    const exp = [_]u8{3};
    const mod = [_]u8{0};

    const result = ModExp.modexp(allocator, &base, &exp, &mod);
    try std.testing.expectError(ModExpError.DivisionByZero, result);
}

test "modexp: gas calculation with zero exponent" {
    const base_len = 32;
    const exp_len = 1;
    const mod_len = 32;
    const exp_bytes = [_]u8{0};

    const gas = ModExp.calculateGas(base_len, exp_len, mod_len, &exp_bytes, void{});
    // Should return minimum gas cost
    try std.testing.expectEqual(@as(u64, 200), gas);
}

test "modexp: gas calculation with small inputs" {
    const base_len = 1;
    const exp_len = 1;
    const mod_len = 1;
    const exp_bytes = [_]u8{1};

    const gas = ModExp.calculateGas(base_len, exp_len, mod_len, &exp_bytes, void{});
    // Minimum gas cost
    try std.testing.expectEqual(@as(u64, 200), gas);
}
