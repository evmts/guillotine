//! Modular Exponentiation (ModExp)
//!
//! Computes base^exponent mod modulus for arbitrary-precision integers.
//! Used in Ethereum precompile 0x05 and RSA-style cryptographic operations.
//!
//! WARNING: UNAUDITED - Custom cryptographic implementation that has NOT been security audited.
//! This implementation is provided for educational/testing purposes only.
//! DO NOT USE IN PRODUCTION without proper security audit and testing.
//!
//! ## Overview
//! Modular exponentiation is a fundamental operation in public-key cryptography,
//! computing (base^exponent) mod modulus efficiently for large numbers.
//!
//! ## Algorithm
//! Odd moduli use Montgomery multiplication with binary or 4-bit sliding
//! windows. Even moduli use truncated powering for the power-of-two factor
//! and the Chinese remainder theorem when there is also an odd factor.
//! Arithmetic scratch is proportional to the number of significant modulus limbs.
//!
//! ## Usage
//! ```zig
//! const std = @import("std");
//! const ModExp = @import("crypto").ModExp;
//!
//! pub fn main() !void {
//!     const allocator = std.heap.page_allocator;
//!     const result = try ModExp.modexp(allocator, &.{3}, &.{10}, &.{13});
//!     defer allocator.free(result);
//!     // result contains 3 (3^10 mod 13).
//! }
//! ```
//!
//! ## Security Considerations
//! - Unaudited custom implementation
//! - Potential timing attacks in big integer operations
//! - Unvalidated against side-channel vulnerabilities
//! - Custom algorithms may have edge case bugs
//! - Memory safety not guaranteed under all conditions
//! - Use audited libraries (GMP, OpenSSL) in production
//!
//! ## Ethereum Context
//! - Precompile 0x05: ModExp for RSA verification
//! - EIP-198: Big integer modular exponentiation
//! - Gas cost scales with input sizes
//!
//! ## References
//! - [EIP-198](https://eips.ethereum.org/EIPS/eip-198) - ModExp precompile

const std = @import("std");

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
/// @param allocator Scratch allocator for moduli larger than 4096 bits
/// @param base_bytes Base value as big-endian bytes
/// @param exp_bytes Exponent value as big-endian bytes
/// @param mod_bytes Modulus value as big-endian bytes
/// @param output Output buffer (must be at least mod_bytes.len)
pub fn unauditedModexp(allocator: std.mem.Allocator, base_bytes: []const u8, exp_bytes: []const u8, mod_bytes: []const u8, output: []u8) ModExpError!void {
    @memset(output, 0);
    const modulus = trimBytes(mod_bytes);
    if (modulus.len == 0) return error.DivisionByZero;
    if (modulus.len == 1 and modulus[0] == 1) return;

    const exponent = trimBytes(exp_bytes);
    if (exponent.len == 0) {
        if (output.len != 0) output[output.len - 1] = 1;
        return;
    }
    const base = trimBytes(base_bytes);
    if (base.len == 0) return;
    if (base.len == 1 and base[0] == 1) {
        if (output.len != 0) output[output.len - 1] = 1;
        return;
    }

    const max_bytes = std.math.maxInt(usize) / 8;
    if (exponent.len > max_bytes or modulus.len > max_bytes) return error.InvalidLength;
    const exp_bits = (exponent.len - 1) * 8 + 8 - @clz(exponent[0]);
    const n = limbCount(modulus.len, 8);

    // Modulus, result, and arithmetic scratch. Base and exponent are read from
    // the original byte slices, so their lengths do not affect scratch size.
    var stack: [64 * workspace_limbs]u64 = undefined;
    const size = std.math.mul(usize, n, workspace_limbs) catch return error.OutOfMemory;
    const heap = size > stack.len;
    const storage = if (heap) try allocator.alloc(u64, size) else stack[0..size];
    defer if (heap) allocator.free(storage);

    const mod = storage[0..n];
    const result = storage[n..][0..n];
    const work = storage[2 * n ..];
    readWords(mod, modulus);

    if (exp_bits == 1) {
        const normalized = work[0..n];
        const shift = normalizeModulus(normalized, mod);
        reduceBase(result, base, mod, normalized, shift);
    } else if (mod[0] & 1 != 0) {
        powerOdd(result, base, exponent, exp_bits, mod, work);
    } else {
        powerEven(result, base, exponent, exp_bits, mod, work);
    }
    writeWords(output, result);
}

const window_powers = 8;
const workspace_limbs = 2 + 2 + window_powers;

fn trimBytes(bytes: []const u8) []const u8 {
    for (bytes, 0..) |byte, i| {
        if (byte != 0) return bytes[i..];
    }
    return bytes[bytes.len..];
}

fn limbCount(size: usize, comptime unit: usize) usize {
    return size / unit + @intFromBool(size % unit != 0);
}

fn readWords(words: []u64, bytes: []const u8) void {
    @memset(words, 0);
    var end = bytes.len;
    for (words) |*word| {
        if (end == 0) break;
        const start = end -| 8;
        word.* = if (end - start == 8)
            std.mem.readInt(u64, bytes[start..][0..8], .big)
        else
            unaudited_bytesToU64(bytes[start..end]);
        end = start;
    }
}

fn writeWords(bytes: []u8, words: []const u64) void {
    var end = bytes.len;
    for (words) |word| {
        if (end == 0) break;
        if (end >= 8) {
            end -= 8;
            std.mem.writeInt(u64, bytes[end..][0..8], word, .big);
        } else {
            unaudited_u64ToBytes(word, bytes[0..end]);
            break;
        }
    }
}

fn lessThan(lhs: []const u64, rhs: []const u64) bool {
    var i = lhs.len;
    while (i != 0) {
        i -= 1;
        if (lhs[i] != rhs[i]) return lhs[i] < rhs[i];
    }
    return false;
}

inline fn subWord(lhs: u64, rhs: u64, borrow: *u1) u64 {
    const diff = @subWithOverflow(lhs, rhs);
    const tail = @subWithOverflow(diff[0], borrow.*);
    borrow.* = diff[1] | tail[1];
    return tail[0];
}

fn subtract(out: []u64, lhs: []const u64, rhs: []const u64) void {
    var borrow: u1 = 0;
    for (out, 0..) |*word, i| {
        const left = if (i < lhs.len) lhs[i] else 0;
        const right = if (i < rhs.len) rhs[i] else 0;
        word.* = subWord(left, right, &borrow);
    }
}

fn add(out: []u64, rhs: []const u64) void {
    var carry: u64 = 0;
    for (out, rhs) |*word, right| {
        const sum = @as(u128, word.*) + right + carry;
        word.* = @truncate(sum);
        carry = @truncate(sum >> 64);
    }
}

fn shiftRight(words: []u64, bits: usize) []u64 {
    const whole = bits / 64;
    const shift: u6 = @truncate(bits);
    const result = words[0 .. words.len - whole];
    if (shift == 0) {
        if (whole != 0) std.mem.copyForwards(u64, result, words[whole..]);
    } else {
        const upper: u6 = @intCast(64 - @as(u7, shift));
        for (result[0 .. result.len - 1], whole..) |*word, i| {
            word.* = (words[i] >> shift) | (words[i + 1] << upper);
        }
        result[result.len - 1] = words[words.len - 1] >> shift;
    }
    var len = result.len;
    while (len != 0 and result[len - 1] == 0) len -= 1;
    return result[0..len];
}

fn normalizeModulus(normalized: []u64, modulus: []const u64) u6 {
    const shift: u6 = @intCast(@clz(modulus[modulus.len - 1]));
    var carry: u64 = 0;
    for (normalized, modulus) |*word, digit| {
        const wide = @as(u128, digit) << shift;
        word.* = @as(u64, @truncate(wide)) | carry;
        carry = @truncate(wide >> 64);
    }
    return shift;
}

// Append a radix-2^64 digit to a normalized remainder. Knuth's quotient
// estimate from the top two words is corrected using the next divisor word.
// The remaining estimate can overshoot by one, in which case we add back.
fn reduceDigit(remainder: []u64, digit: u64, divisor: []const u64, shift: u6) void {
    const n = divisor.len;
    const high = remainder[n - 1];
    std.mem.copyBackwards(u64, remainder[1..], remainder[0 .. n - 1]);
    const wide = @as(u128, digit) << shift;
    remainder[0] = @truncate(wide);
    remainder[1] |= @truncate(wide >> 64);

    const top = divisor[n - 1];
    if (high == 0 and remainder[n - 1] < top) return;
    const head = (@as(u128, high) << 64) | remainder[n - 1];
    var q: u64 = if (high == top) std.math.maxInt(u64) else @intCast(head / top);
    var r = head - @as(u128, q) * top;
    while (r <= std.math.maxInt(u64) and
        @as(u128, q) * divisor[n - 2] > ((r << 64) | remainder[n - 2]))
    {
        q -= 1;
        r += top;
    }

    var carry: u64 = 0;
    for (remainder, divisor) |*word, part| {
        const product = @as(u128, part) * q + carry;
        const diff = @subWithOverflow(word.*, @as(u64, @truncate(product)));
        word.* = diff[0];
        carry = @as(u64, @truncate(product >> 64)) + diff[1];
    }
    if (high < carry) add(remainder, divisor);
}

fn reduceBase(out: []u64, base: []const u8, modulus: []const u64, normalized: []const u64, shift: u6) void {
    if (limbCount(base.len, 8) <= modulus.len) {
        readWords(out, base);
        if (lessThan(out, modulus)) return;
    }

    @memset(out, 0);
    var start: usize = 0;
    var width = (base.len - 1) % 8 + 1;
    while (start < base.len) : (width = 8) {
        const digit = unaudited_bytesToU64(base[start..][0..width]);
        if (modulus.len == 1) {
            out[0] = @intCast(((@as(u128, out[0]) << 64) | digit) % modulus[0]);
        } else {
            reduceDigit(out, digit, normalized, shift);
        }
        start += width;
    }
    if (modulus.len > 1) _ = shiftRight(out, shift);
}

fn radixSquared(out: []u64, modulus: []const u64, normalized: []const u64, shift: u6) void {
    if (modulus.len == 1) {
        const radix = (@as(u128, 1) << 64) % modulus[0];
        out[0] = @intCast(radix * radix % modulus[0]);
        return;
    }

    // B^(n-1) < m for an odd n-limb modulus greater than one, with B=2^64.
    // Append n+1 zero digits to reach B^(2n), reducing after each digit.
    @memset(out, 0);
    out[out.len - 1] = @as(u64, 1) << shift;
    for (0..out.len + 1) |_| reduceDigit(out, 0, normalized, shift);
    _ = shiftRight(out, shift);
}

fn montInverse(modulus: u64) u64 {
    // The square of any odd number is 1 modulo 8, so the seed has three
    // correct bits. Each of the five iterations doubles the precision.
    var inv = modulus;
    inline for (0..5) |_| inv *%= 2 -% modulus *% inv;
    return 0 -% inv;
}

inline fn mac(lhs: u64, rhs: u64, sum: u64, carry: *u64) u64 {
    // A full limb product plus two limbs fits exactly in 128 bits.
    const wide = @as(u128, lhs) * rhs +% sum +% carry.*;
    carry.* = @truncate(wide >> 64);
    return @truncate(wide);
}

inline fn montMulFixed(comptime n: usize, lhs: [n]u64, rhs: [n]u64, modulus: [n]u64, inv: u64) [n]u64 {
    var acc = [_]u64{0} ** n;
    var top: u64 = 0;
    inline for (rhs) |digit| {
        var mul_carry: u64 = 0;
        var red_carry: u64 = 0;
        const low = mac(lhs[0], digit, acc[0], &mul_carry);
        const factor = low *% inv;
        _ = mac(modulus[0], factor, low, &red_carry);
        inline for (1..n) |j| {
            const product = mac(lhs[j], digit, acc[j], &mul_carry);
            acc[j - 1] = mac(modulus[j], factor, product, &red_carry);
        }
        const folded = @as(u128, mul_carry) + red_carry + top;
        acc[n - 1] = @truncate(folded);
        top = @truncate(folded >> 64);
    }

    var reduced: [n]u64 = undefined;
    var borrow: u1 = 0;
    inline for (0..n) |i| reduced[i] = subWord(acc[i], modulus[i], &borrow);
    return if (top != 0 or borrow == 0) reduced else acc;
}

inline fn montMul4(lhs: [4]u64, rhs: [4]u64, modulus: [4]u64, inv: u64) [4]u64 {
    return montMulFixed(4, lhs, rhs, modulus, inv);
}

fn montMulN(out: []u64, lhs: []const u64, rhs: []const u64, modulus: []const u64, inv: u64, acc: []u64) void {
    const n = modulus.len;
    @memset(acc, 0);
    var top: u64 = 0;
    for (rhs) |digit| {
        var mul_carry: u64 = 0;
        var red_carry: u64 = 0;
        const low = mac(lhs[0], digit, acc[0], &mul_carry);
        const factor = low *% inv;
        // The factor cancels the low word. Store the remaining words one
        // position lower and fold the two carry chains and prior top bit.
        _ = mac(modulus[0], factor, low, &red_carry);
        for (1..n) |j| {
            const product = mac(lhs[j], digit, acc[j], &mul_carry);
            acc[j - 1] = mac(modulus[j], factor, product, &red_carry);
        }
        const folded = @as(u128, mul_carry) + red_carry + top;
        acc[n - 1] = @truncate(folded);
        top = @truncate(folded >> 64);
    }

    // Reduced inputs bound the n+1-word result to less than twice the modulus.
    if (top != 0 or !lessThan(acc, modulus)) {
        subtract(out, acc, modulus);
    } else {
        @memcpy(out, acc);
    }
}

const Montgomery = struct {
    modulus: []const u64,
    inv: u64,
    scratch: []u64,

    // Output may alias either input. The accumulator lives in registers for
    // fixed sizes, and in a separate scratch slice for the general case.
    fn mul(self: Montgomery, out: []u64, lhs: []const u64, rhs: []const u64) void {
        switch (self.modulus.len) {
            1 => out[0..1].* = montMulFixed(1, lhs[0..1].*, rhs[0..1].*, self.modulus[0..1].*, self.inv),
            4 => out[0..4].* = montMul4(lhs[0..4].*, rhs[0..4].*, self.modulus[0..4].*, self.inv),
            else => montMulN(out, lhs, rhs, self.modulus, self.inv, self.scratch),
        }
    }
};

fn bitAt(bytes: []const u8, index: usize) bool {
    const byte = bytes[bytes.len - 1 - index / 8];
    return (byte >> @as(u3, @truncate(index))) & 1 != 0;
}

fn oddWindow(exponent: []const u8, end: usize, width: usize) struct { index: usize, len: usize } {
    const count = @min(end, width);
    const start = end - count;
    const byte = exponent.len - 1 - start / 8;
    var pair: u16 = exponent[byte];
    if (byte != 0) pair |= @as(u16, exponent[byte - 1]) << 8;

    const mask = (@as(u16, 1) << @as(u3, @intCast(count))) - 1;
    const value = (pair >> @as(u3, @truncate(start))) & mask;
    // The leading bit is set. Drop zeros from the low end to make the
    // window odd and leave those bits for the next iteration.
    const zeros: u4 = @intCast(@ctz(value));
    return .{ .index = (value >> zeros) / 2, .len = count - zeros };
}

fn powerOdd(out: []u64, base: []const u8, exponent: []const u8, exp_bits: usize, modulus: []const u64, work: []u64) void {
    const n = modulus.len;
    const mont: Montgomery = .{ .modulus = modulus, .inv = montInverse(modulus[0]), .scratch = work[0..n] };
    const temp = work[n..][0..n];
    const powers = work[2 * n ..];
    const base_mont = powers[0..n];

    const shift = normalizeModulus(temp, modulus);
    reduceBase(out, base, modulus, temp, shift);
    radixSquared(base_mont, modulus, temp, shift);
    mont.mul(base_mont, out, base_mont);

    const width: usize = if (exp_bits >= 16) 4 else 1;
    if (width == 4) {
        mont.mul(temp, base_mont, base_mont);
        for (1..window_powers) |i| {
            mont.mul(powers[i * n ..][0..n], powers[(i - 1) * n ..][0..n], temp);
        }
    }

    const first = oddWindow(exponent, exp_bits, width);
    @memcpy(out, powers[first.index * n ..][0..n]);
    var remaining = exp_bits - first.len;
    while (remaining != 0) {
        if (!bitAt(exponent, remaining - 1)) {
            mont.mul(out, out, out);
            remaining -= 1;
            continue;
        }
        const window = oddWindow(exponent, remaining, width);
        for (0..window.len) |_| mont.mul(out, out, out);
        mont.mul(out, out, powers[window.index * n ..][0..n]);
        remaining -= window.len;
    }

    @memset(temp, 0);
    temp[0] = 1;
    mont.mul(out, out, temp);
}

fn maskHigh(words: []u64, bits: usize) void {
    const shift: u6 = @truncate(bits);
    if (shift != 0) words[words.len - 1] &= (@as(u64, 1) << shift) - 1;
}

// Only the low out.len words of the product are needed. Output is separate
// from the inputs so a buffer can be reused across successive multiplies.
fn multiply(out: []u64, lhs: []const u64, rhs: []const u64) void {
    @memset(out, 0);
    for (rhs[0..@min(rhs.len, out.len)], 0..) |digit, i| {
        const row = out[i..];
        const width = @min(lhs.len, row.len);
        var carry: u64 = 0;
        for (row[0..width], lhs[0..width]) |*word, part| {
            word.* = mac(part, digit, word.*, &carry);
        }
        if (width < row.len) row[width] = carry;
    }
}

fn powerOfTwo(out: []u64, base: []const u8, exponent: []const u8, exp_bits: usize, bits: usize, work: []u64) void {
    @memset(out, 0);
    var remaining = exp_bits;
    if (base[base.len - 1] & 1 == 0) {
        var valuation: usize = 0;
        while (valuation < bits) {
            const byte = base[base.len - 1 - valuation / 8];
            valuation += @ctz(byte);
            if (byte != 0) break;
        }
        // Compare against ceil(bits / valuation) without multiplying or
        // decoding an exponent that does not fit in usize.
        if (valuation >= bits or exponent.len > @sizeOf(usize)) return;
        if (unaudited_bytesToU64(exponent) >= 1 + (bits - 1) / valuation) return;
    } else {
        // The unit group modulo 2^bits has exponent 1, 2, or 2^(bits-2).
        const period_bits = if (bits <= 2) bits - 1 else bits - 2;
        remaining = @min(remaining, period_bits);
        while (remaining != 0 and !bitAt(exponent, remaining - 1)) remaining -= 1;
        if (remaining == 0) {
            out[0] = 1;
            return;
        }
    }

    const n = out.len;
    const factor = work[0..n];
    readWords(factor, base);
    maskHigh(factor, bits);

    var current = out;
    var next = work[n..][0..n];
    @memcpy(current, factor);
    remaining -= 1;
    while (remaining != 0) {
        remaining -= 1;
        multiply(next, current, current);
        if (bitAt(exponent, remaining)) {
            multiply(current, next, factor);
        } else {
            std.mem.swap([]u64, &current, &next);
        }
        maskHigh(current, bits);
    }
    if (current.ptr != out.ptr) @memcpy(out, current);
}

fn inversePowerOfTwo(inv: []u64, odd: []const u64, bits: usize, product: []u64, next: []u64) void {
    @memset(inv, 0);
    inv[0] = 0 -% montInverse(odd[0]);
    var precision: usize = 64;
    while (precision < bits) {
        precision += @min(precision, bits - precision);
        const n = limbCount(precision, 64);
        const correction = product[0..n];
        multiply(correction, inv[0..n], odd);
        subtract(correction, &.{2}, correction);
        multiply(next[0..n], inv[0..n], correction);
        @memcpy(inv[0..n], next[0..n]);
    }
    maskHigh(inv, bits);
}

fn powerEven(out: []u64, base: []const u8, exponent: []const u8, exp_bits: usize, modulus: []u64, work: []u64) void {
    var bits: usize = 0;
    for (modulus) |word| {
        bits += @ctz(word);
        if (word != 0) break;
    }

    const odd = shiftRight(modulus, bits);
    const n = limbCount(bits, 64);
    @memset(out, 0);
    if (odd.len == 1 and odd[0] == 1) {
        powerOfTwo(out[0..n], base, exponent, exp_bits, bits, work);
        return;
    }

    const x_odd = out[0..odd.len];
    powerOdd(x_odd, base, exponent, exp_bits, odd, work);

    const x_even = work[0..n];
    const inv = work[n..][0..n];
    const factor = work[2 * n ..][0..n];
    const next = work[3 * n ..][0..n];
    powerOfTwo(x_even, base, exponent, exp_bits, bits, work[n..]);
    inversePowerOfTwo(inv, odd, bits, factor, next);

    // t = (x_even - x_odd) / odd mod 2^bits. The reconstructed value
    // x_odd + odd*t is below odd*2^bits and fits in the original modulus width.
    subtract(x_even, x_even, x_odd);
    multiply(factor, x_even, inv);
    maskHigh(factor, bits);
    const product = work[4 * n ..][0..out.len];
    multiply(product, odd, factor);
    add(out, product);
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

fn unaudited_isOne(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes[0 .. bytes.len - 1]) |byte| {
        if (byte != 0) return false;
    }
    return bytes[bytes.len - 1] == 1;
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

fn clampU128ToU64(value: u128) u64 {
    const max_u64 = @as(u128, std.math.maxInt(u64));
    return if (value > max_u64) std.math.maxInt(u64) else @intCast(value);
}

fn mulDivToU64(lhs: u64, rhs: u64, divisor: u64) u64 {
    return clampU128ToU64((@as(u128, lhs) * @as(u128, rhs)) / @as(u128, divisor));
}

/// ⚠️ UNAUDITED - NOT SECURITY AUDITED ⚠️
/// Calculates multiplication complexity for gas cost
/// WARNING: Custom gas calculation logic not audited
pub fn unaudited_calculateMultiplicationComplexity(x: usize) u64 {
    const x128: u128 = @intCast(x);

    if (x <= GAS_QUADRATIC_THRESHOLD) {
        return clampU128ToU64(x128 * x128);
    } else if (x <= GAS_LINEAR_THRESHOLD) {
        // x^2/4 + 96*x - 3072
        return clampU128ToU64((x128 * x128) / 4 + 96 * x128 - 3072);
    } else {
        // x^2/16 + 480*x - 199680
        return clampU128ToU64((x128 * x128) / 16 + 480 * x128 - 199680);
    }
}

fn calculateEip2565MultiplicationComplexity(x: usize) u64 {
    const words = (@as(u128, @intCast(x)) + 7) / 8;
    return clampU128ToU64(words * words);
}

fn exponentHeadBitLength(exp_bytes: []const u8) u64 {
    const head = exp_bytes[0..@min(exp_bytes.len, 32)];
    var leading_zeros: usize = 0;
    for (head) |byte| {
        if (byte != 0) break;
        leading_zeros += 1;
    }
    if (leading_zeros == head.len) return 0;

    const first_non_zero = head[leading_zeros];
    const first_byte_bits: u64 = 8 - @as(u64, @intCast(@clz(first_non_zero)));
    return @as(u64, @intCast((head.len - leading_zeros - 1) * 8)) + first_byte_bits;
}

fn calculateModexpIterations(exp_len: usize, exp_bytes: []const u8, long_byte_cost: u64) u64 {
    const head_bits = exponentHeadBitLength(exp_bytes);
    const head_iterations = if (head_bits == 0) 0 else head_bits - 1;
    const adjusted = if (exp_len <= 32)
        head_iterations
    else
        clampU128ToU64(@as(u128, @intCast(exp_len - 32)) * long_byte_cost + head_iterations);
    return @max(adjusted, 1);
}

fn gasForkAtLeast(hardfork: anytype, target: @import("voltaire").Hardfork) bool {
    return switch (@typeInfo(@TypeOf(hardfork))) {
        .@"enum" => hardfork.isAtLeast(target),
        .enum_literal => @as(@import("voltaire").Hardfork, hardfork).isAtLeast(target),
        // Preserve the legacy marker API's Berlin gas schedule.
        else => @import("voltaire").Hardfork.BERLIN.isAtLeast(target),
    };
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
    /// Calculates MODEXP gas using EIP-198 before Berlin, EIP-2565 from Berlin,
    /// and EIP-7883 from Osaka. exp_bytes contains the right-padded exponent head
    /// (at most 32 bytes); exp_len is the full declared exponent length.
    /// Length bounds belong to the precompile. Costs saturate at maxInt(u64).
    /// WARNING: Custom gas calculation logic not audited
    pub fn calculateGas(
        base_len: usize,
        exp_len: usize,
        mod_len: usize,
        exp_bytes: []const u8,
        hardfork: anytype,
    ) u64 {
        // Calculate maximum length for multiplication complexity
        const max_len = @max(base_len, mod_len);
        const osaka = gasForkAtLeast(hardfork, .OSAKA);
        const iteration_count = calculateModexpIterations(exp_len, exp_bytes, if (osaka) 16 else 8);
        if (osaka) {
            const words = (@as(u128, @intCast(max_len)) + 7) / 8;
            const complexity = if (max_len <= 32) 16 else clampU128ToU64(2 * words * words);
            return @max(500, mulDivToU64(complexity, iteration_count, 1));
        }

        if (gasForkAtLeast(hardfork, .BERLIN)) {
            const mult_complexity = calculateEip2565MultiplicationComplexity(max_len);
            const gas_cost = mulDivToU64(mult_complexity, iteration_count, 3);
            return @max(200, gas_cost);
        }

        const mult_complexity = unaudited_calculateMultiplicationComplexity(max_len);
        return mulDivToU64(mult_complexity, iteration_count, 20);
    }
};

test "ModExp gas schedules match EIP-198, EIP-2565 and EIP-7883 boundaries" {
    const Hardfork = @import("voltaire").Hardfork;
    const head = [_]u8{0xff} ** 32;
    try std.testing.expectEqual(@as(u64, 13056), ModExp.calculateGas(32, 32, 32, &head, Hardfork.BYZANTIUM));
    try std.testing.expectEqual(@as(u64, 1360), ModExp.calculateGas(32, 32, 32, &head, Hardfork.PRAGUE));
    try std.testing.expectEqual(@as(u64, 4080), ModExp.calculateGas(32, 32, 32, &head, Hardfork.OSAKA));
    try std.testing.expectEqual(@as(u64, 12750), ModExp.calculateGas(33, 32, 33, &head, Hardfork.OSAKA));
    // EELS treats a zero exponent head's bit contribution as zero, including
    // long exponents: 16 * (33 - 32) iterations, not a negative bit contribution.
    try std.testing.expectEqual(@as(u64, 2048), ModExp.calculateGas(64, 33, 64, &.{0}, Hardfork.OSAKA));
    try std.testing.expectEqual(@as(u64, 34688), ModExp.calculateGas(64, 33, 64, &head, Hardfork.OSAKA));
}

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

    // Parse hex string back to bytes. Big-int formatting omits a leading zero
    // nibble, so pad odd-width values before hex decoding.
    const padded_hex = if (hex_string.len % 2 == 0) hex_string else blk: {
        const buf = try big.allocator.alloc(u8, hex_string.len + 1);
        buf[0] = '0';
        @memcpy(buf[1..], hex_string);
        break :blk buf;
    };
    defer if (padded_hex.ptr != hex_string.ptr) big.allocator.free(padded_hex);

    const hex_bytes = try big.allocator.alloc(u8, padded_hex.len / 2);
    defer big.allocator.free(hex_bytes);
    _ = try std.fmt.hexToBytes(hex_bytes, padded_hex);

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

    // 2^255 is an exact multiple of 2^128; the remainder is zero.
    const expected: [17]u8 = .{0} ** 17;

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

test "modexp: zero exponent is reduced modulo one" {
    const allocator = std.testing.allocator;

    const base = [_]u8{0};
    const exp = [_]u8{0};
    const mod = [_]u8{1};
    var output: [1]u8 = undefined;

    try unauditedModexp(allocator, &base, &exp, &mod, &output);
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

test "modexp: odd-width hex result is padded before output" {
    const allocator = std.testing.allocator;

    const base = [_]u8{3};
    const exp = [_]u8{3};
    const mod = [_]u8{0x0d};

    const result = try ModExp.modexp(allocator, &base, &exp, &mod);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(u8, 1), result[0]);
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

fn referenceModexp(base_bytes: []const u8, exponent: []const u8, modulus: []const u8, output: []u8) !void {
    const Managed = std.math.big.int.Managed;
    const allocator = std.testing.allocator;
    var base = try Managed.init(allocator);
    defer base.deinit();
    var mod = try Managed.init(allocator);
    defer mod.deinit();
    var result = try Managed.initSet(allocator, 1);
    defer result.deinit();
    var product = try Managed.init(allocator);
    defer product.deinit();
    var quotient = try Managed.init(allocator);
    defer quotient.deinit();

    try readBigEndian(&base, base_bytes);
    try readBigEndian(&mod, modulus);
    for (exponent) |byte| {
        for (0..8) |bit| {
            try product.sqr(&result);
            try quotient.divFloor(&result, &product, &mod);
            if (byte & (@as(u8, 0x80) >> @as(u3, @intCast(bit))) != 0) {
                try product.mul(&result, &base);
                try quotient.divFloor(&result, &product, &mod);
            }
        }
    }
    try writeBigEndian(&result, output);
}

test "modexp: BN254 scalar inversion with no scratch allocation" {
    var modulus: [32]u8 = undefined;
    var exponent: [32]u8 = undefined;
    var base: [32]u8 = undefined;
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&modulus, "30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001");
    _ = try std.fmt.hexToBytes(&exponent, "30644e72e131a029b85045b68181585d2833e84879b9709143e1f593efffffff");
    _ = try std.fmt.hexToBytes(&base, "0000000000000000123456789abcdef0123456789abcdef0123456789abcdef0");
    _ = try std.fmt.hexToBytes(&expected, "1ebcd54aa646bbcfbc979955f998aa1076248b18d8883ffc27b98f6098239a19");
    var output: [32]u8 = undefined;
    try unauditedModexp(std.testing.failing_allocator, &base, &exponent, &modulus, &output);
    try std.testing.expectEqualSlices(u8, &expected, &output);
}

test "modexp: wide odd moduli and scratch allocation boundary" {
    var prng = std.Random.DefaultPrng.init(0x68db90c3);
    const random = prng.random();
    var base: [530]u8 = undefined;
    var modulus: [513]u8 = undefined;
    var output: [513]u8 = undefined;
    var expected: [513]u8 = undefined;

    for ([_]usize{ 64, 128, 256, 512, 513 }) |len| {
        random.bytes(base[0 .. len + 17]);
        random.bytes(modulus[0..len]);
        modulus[0] |= 0x80;
        modulus[len - 1] |= 1;
        const allocator = if (len <= 512) std.testing.failing_allocator else std.testing.allocator;
        const exponent = if (len <= 256) &([_]u8{0xe7} ** 32) else &[_]u8{ 1, 0, 1 };
        try referenceModexp(base[0 .. len + 17], exponent, modulus[0..len], expected[0..len]);
        try unauditedModexp(allocator, base[0 .. len + 17], exponent, modulus[0..len], output[0..len]);
        try std.testing.expectEqualSlices(u8, expected[0..len], output[0..len]);
    }
    try std.testing.expectError(error.OutOfMemory, unauditedModexp(std.testing.failing_allocator, &base, &.{3}, &modulus, &output));

    // A leading zero byte does not push a 4096-bit modulus into heap scratch.
    modulus[0] = 0;
    try referenceModexp(&base, &.{3}, &modulus, &expected);
    try unauditedModexp(std.testing.failing_allocator, &base, &.{3}, &modulus, &output);
    try std.testing.expectEqualSlices(u8, &expected, &output);
}

test "modexp: Montgomery carry and exponent window boundary" {
    // m = R-1 and base = m-1. The Montgomery accumulator after squaring
    // is R, so its extra carry bit triggers the final subtraction.
    const modulus = [_]u8{0xff} ** 32;
    const base = ([_]u8{0xff} ** 31) ++ [_]u8{0xfe};
    var output: [32]u8 = undefined;
    for ([_][]const u8{ &.{2}, &.{ 0x7f, 0xfe }, &.{ 0x80, 0 } }) |exponent| {
        try unauditedModexp(std.testing.failing_allocator, &base, exponent, &modulus, &output);
        try std.testing.expect(unaudited_isOne(&output));
    }
    try unauditedModexp(std.testing.failing_allocator, &base, &.{ 0x80, 1 }, &modulus, &output);
    try std.testing.expectEqualSlices(u8, &base, &output);
}

test "modexp: even modulus valuation, exponent reduction and CRT" {
    const allocator = std.testing.failing_allocator;
    const exponent = [_]u8{0xff} ** 32;
    var modulus: [64]u8 = undefined;
    var output: [64]u8 = undefined;
    var expected: [64]u8 = undefined;

    for ([_]usize{ 1, 2, 3, 63, 64, 65, 100, 127, 128, 129, 255, 256, 257 }) |k| {
        @memset(&modulus, 0);
        modulus[modulus.len - 1 - k / 8] = @as(u8, 1) << @as(u3, @truncate(k));
        for ([_]u8{ 5, 12 }) |base| {
            try referenceModexp(&.{base}, &exponent, &modulus, &expected);
            try unauditedModexp(allocator, &.{base}, &exponent, &modulus, &output);
            try std.testing.expectEqualSlices(u8, &expected, &output);
        }
    }

    // v2(12) = 2. Exponent 49 stays below the valuation threshold for 2^100.
    const pow2 = [_]u8{0x10} ++ ([_]u8{0} ** 12);
    try referenceModexp(&.{12}, &.{49}, &pow2, &expected);
    try unauditedModexp(allocator, &.{12}, &.{49}, &pow2, &output);
    try std.testing.expectEqualSlices(u8, &expected, &output);
    try std.testing.expect(!unaudited_isZero(&output));
    try unauditedModexp(allocator, &.{12}, &.{50}, &pow2, &output);
    try std.testing.expect(unaudited_isZero(&output));
    try unauditedModexp(allocator, &.{5}, &([_]u8{0x80} ++ ([_]u8{0} ** 31)), &pow2, &output);
    try std.testing.expect(unaudited_isOne(&output));

    const mixed = [_]u8{0x30} ++ ([_]u8{0} ** 12); // 3 * 2^100
    _ = try std.fmt.hexToBytes(modulus[0..32], "30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001");
    @memset(modulus[32..], 0); // BN254 scalar modulus times 2^256
    const wide_base = [_]u8{0xcd} ** 65;
    for ([_][]const u8{ &mixed, &modulus }) |mod| {
        for ([_][]const u8{ &wide_base, &.{12} }) |base| {
            try referenceModexp(base, &exponent, mod, &expected);
            try unauditedModexp(allocator, base, &exponent, mod, &output);
            try std.testing.expectEqualSlices(u8, &expected, &output);
        }
    }
}

test "modexp: deterministic randomized cross-check against std.math.big" {
    var prng = std.Random.DefaultPrng.init(0x72801810);
    const random = prng.random();
    var base: [129]u8 = undefined;
    var exponent: [40]u8 = undefined;
    var modulus: [97]u8 = undefined;
    var output: [97]u8 = undefined;
    var expected: [97]u8 = undefined;

    for (0..128) |i| {
        const base_len = random.intRangeAtMost(usize, 1, base.len);
        const exp_len = random.intRangeAtMost(usize, 1, exponent.len);
        const mod_len = random.intRangeAtMost(usize, 1, modulus.len);
        const mod = modulus[0..mod_len];
        random.bytes(base[0..base_len]);
        random.bytes(exponent[0..exp_len]);
        random.bytes(mod);
        switch (i % 4) {
            0 => mod[mod_len - 1] |= 3,
            1 => mod[mod_len - 1] &= 0xfc,
            2 => {
                const zero_bytes = random.intRangeLessThan(usize, 0, mod_len);
                mod[mod_len - 1 - zero_bytes] |= 3;
                @memset(mod[mod_len - zero_bytes ..], 0);
            },
            3 => mod[0] = 0,
            else => unreachable,
        }
        if (unaudited_isZero(mod)) mod[mod_len - 1] = 2;
        try referenceModexp(base[0..base_len], exponent[0..exp_len], mod, expected[0..mod_len]);
        try unauditedModexp(std.testing.allocator, base[0..base_len], exponent[0..exp_len], mod, output[0..mod_len]);
        try std.testing.expectEqualSlices(u8, expected[0..mod_len], output[0..mod_len]);
    }
}

test "modexp: padded trivial operands retain the modulus width" {
    const modulus = [_]u8{ 0, 0, 0, 7 };
    const cases = [_]struct { base: u8, exp: u8, value: u8 }{
        .{ .base = 0, .exp = 0, .value = 1 },
        .{ .base = 0, .exp = 5, .value = 0 },
        .{ .base = 1, .exp = 5, .value = 1 },
        .{ .base = 10, .exp = 1, .value = 3 },
    };
    var buf: [4]u8 = undefined;
    for (cases) |case| {
        var allocator = std.heap.FixedBufferAllocator.init(&buf);
        const result = try ModExp.modexp(allocator.allocator(), &.{ 0, case.base }, &.{ 0, case.exp }, &modulus);
        defer allocator.allocator().free(result);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, case.value }, result);
    }
    var output: [4]u8 = undefined;
    try unauditedModexp(std.testing.failing_allocator, &.{5}, &.{0}, &.{ 0, 0, 0, 1 }, &output);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &output);
    try std.testing.expectError(error.DivisionByZero, unauditedModexp(std.testing.failing_allocator, &.{5}, &.{0}, &.{ 0, 0, 0, 0 }, &output));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &output);
}
