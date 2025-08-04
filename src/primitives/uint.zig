const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

pub fn nlimbs(bits: usize) usize {
    if (bits == 0) return 1;
    return (bits + 63) / 64;
}

pub fn mask(bits: usize) u64 {
    if (bits == 0) return 0;
    const remainder = bits % 64;
    if (remainder == 0) return std.math.maxInt(u64);
    return (@as(u64, 1) << @intCast(remainder)) - 1;
}

// Optimized carry operations using compiler intrinsics when available
pub inline fn addWithCarry(a: u64, b: u64, carry: u8) struct { sum: u64, carry: u8 } {
    if (comptime builtin.cpu.arch == .x86_64 and builtin.mode != .Debug) {
        // Use x86-64 ADCX/ADOX instructions when available
        var sum: u64 = undefined;
        var new_carry: u8 = undefined;
        asm volatile (
            \\add %[carry], %[carry]  # Set CF from carry
            \\adc %[b], %[a]          # Add with carry
            \\setc %[new_carry]       # Extract carry
            : [a] "=r" (sum),
              [new_carry] "=r" (new_carry),
            : [a] "0" (a),
              [b] "r" (b),
              [carry] "r" (carry),
            : "cc"
        );
        return .{ .sum = sum, .carry = new_carry };
    } else {
        // Fallback implementation
        const sum = a +% b;
        const carry1 = @intFromBool(sum < a);
        const sum2 = sum +% carry;
        const carry2 = @intFromBool(sum2 < sum);
        return .{ .sum = sum2, .carry = carry1 | carry2 };
    }
}

pub inline fn subWithBorrow(a: u64, b: u64, borrow: u8) struct { diff: u64, borrow: u8 } {
    if (comptime builtin.cpu.arch == .x86_64 and builtin.mode != .Debug) {
        // Use x86-64 SBB instruction
        var diff: u64 = undefined;
        var new_borrow: u8 = undefined;
        asm volatile (
            \\add %[borrow], %[borrow]  # Set CF from borrow
            \\sbb %[b], %[a]            # Subtract with borrow
            \\setc %[new_borrow]        # Extract borrow
            : [a] "=r" (diff),
              [new_borrow] "=r" (new_borrow),
            : [a] "0" (a),
              [b] "r" (b),
              [borrow] "r" (borrow),
            : "cc"
        );
        return .{ .diff = diff, .borrow = new_borrow };
    } else {
        // Fallback implementation
        const diff = a -% b;
        const borrow1 = @intFromBool(a < b);
        const diff2 = diff -% borrow;
        const borrow2 = @intFromBool(diff < borrow);
        return .{ .diff = diff2, .borrow = borrow1 | borrow2 };
    }
}

// Fast multiplication producing 128-bit result
pub inline fn mul64x64(a: u64, b: u64) struct { low: u64, high: u64 } {
    if (@sizeOf(u128) == 16 and builtin.mode != .Debug) {
        // Use native u128 multiplication when available
        const product = @as(u128, a) * @as(u128, b);
        return .{
            .low = @truncate(product),
            .high = @truncate(product >> 64),
        };
    } else {
        // Karatsuba-style multiplication for better performance
        const al = a & 0xFFFFFFFF;
        const ah = a >> 32;
        const bl = b & 0xFFFFFFFF;
        const bh = b >> 32;

        const t0 = al * bl;
        const t1 = ah * bl;
        const t2 = al * bh;
        const t3 = ah * bh;

        const sum1 = t1 +% (t0 >> 32);
        const sum2 = t2 +% (sum1 & 0xFFFFFFFF);

        return .{
            .low = (sum2 << 32) | (t0 & 0xFFFFFFFF),
            .high = t3 +% (sum2 >> 32) +% (sum1 >> 32),
        };
    }
}

pub fn Uint(comptime bits: usize, comptime limbs: usize) type {
    return struct {
        const Self = @This();

        limbs: [limbs]u64,

        pub const BITS = bits;
        pub const LIMBS = limbs;
        pub const MASK = mask(bits);

        pub const ZERO: Self = Self.from_limbs(.{0} ** limbs);
        pub const ONE: Self = if (bits == 0) ZERO else if (limbs == 0) ZERO else Self.from_limbs(.{1} ++ .{0} ** (limbs - 1));
        pub const MIN: Self = ZERO;
        pub const MAX: Self = blk: {
            var max_limbs = .{std.math.maxInt(u64)} ** limbs;
            if (limbs > 0 and MASK != std.math.maxInt(u64)) {
                max_limbs[limbs - 1] = MASK;
            }
            break :blk Self.from_limbs(max_limbs);
        };

        pub const DivRemResult = struct { quotient: Self, remainder: Self };

        pub fn from_limbs(limbs_arr: [limbs]u64) Self {
            const result = Self{ .limbs = limbs_arr };
            if (bits > 0 and MASK != std.math.maxInt(u64) and limbs > 0) {
                std.debug.assert(result.limbs[limbs - 1] <= MASK);
            }
            return result;
        }

        pub fn from_u64(value: u64) Self {
            if (bits == 0) return ZERO;
            if (limbs == 0) return ZERO;
            var limbs_arr: [limbs]u64 = .{0} ** limbs;
            limbs_arr[0] = value;
            return Self.from_limbs(limbs_arr).masked();
        }

        pub fn as_limbs(self: *const Self) *const [limbs]u64 {
            return &self.limbs;
        }

        pub fn into_limbs(self: Self) [limbs]u64 {
            return self.limbs;
        }

        fn masked(self: Self) Self {
            if (bits == 0) return ZERO;
            if (limbs == 0) return self;
            if (MASK == std.math.maxInt(u64)) return self;

            var result = self;
            result.limbs[limbs - 1] &= MASK;
            return result;
        }

        pub fn is_zero(self: Self) bool {
            if (bits == 0) return true;
            for (self.limbs) |limb| {
                if (limb != 0) return false;
            }
            return true;
        }

        pub fn eq(self: Self, other: Self) bool {
            if (bits == 0) return true;

            // For 256-bit or smaller, use native u256 operations for better performance
            if (comptime bits <= 256) {
                const self_u256 = self.to_u256() orelse unreachable;
                const other_u256 = other.to_u256() orelse unreachable;
                return self_u256 == other_u256;
            }

            for (0..limbs) |i| {
                if (self.limbs[i] != other.limbs[i]) return false;
            }
            return true;
        }

        pub fn overflowing_add(self: Self, rhs: Self) struct { result: Self, overflow: bool } {
            if (bits == 0) return .{ .result = ZERO, .overflow = false };

            var result: Self = undefined;
            var carry: u8 = 0;

            // Use optimized carry operations
            for (0..limbs) |i| {
                const add_result = addWithCarry(self.limbs[i], rhs.limbs[i], carry);
                result.limbs[i] = add_result.sum;
                carry = add_result.carry;
            }

            const overflow = carry != 0 or (limbs > 0 and result.limbs[limbs - 1] > MASK);
            return .{ .result = result.masked(), .overflow = overflow };
        }

        pub fn checked_add(self: Self, rhs: Self) ?Self {
            const result = self.overflowing_add(rhs);
            if (result.overflow) return null;
            return result.result;
        }

        pub fn wrapping_add(self: Self, rhs: Self) Self {
            return self.overflowing_add(rhs).result;
        }

        pub fn overflowing_sub(self: Self, rhs: Self) struct { result: Self, overflow: bool } {
            if (bits == 0) return .{ .result = ZERO, .overflow = false };

            var result: Self = undefined;
            var borrow: u8 = 0;

            // Use optimized borrow operations
            for (0..limbs) |i| {
                const sub_result = subWithBorrow(self.limbs[i], rhs.limbs[i], borrow);
                result.limbs[i] = sub_result.diff;
                borrow = sub_result.borrow;
            }

            const overflow = borrow != 0;
            return .{ .result = result.masked(), .overflow = overflow };
        }

        pub fn checked_sub(self: Self, rhs: Self) ?Self {
            const result = self.overflowing_sub(rhs);
            if (result.overflow) return null;
            return result.result;
        }

        pub fn wrapping_sub(self: Self, rhs: Self) Self {
            return self.overflowing_sub(rhs).result;
        }

        pub fn overflowing_neg(self: Self) struct { result: Self, overflow: bool } {
            return ZERO.overflowing_sub(self);
        }

        pub fn checked_neg(self: Self) ?Self {
            const result = self.overflowing_neg();
            if (result.overflow) return null;
            return result.result;
        }

        pub fn wrapping_neg(self: Self) Self {
            return self.overflowing_neg().result;
        }

        pub fn abs_diff(self: Self, other: Self) Self {
            if (self.lt(other)) {
                return other.wrapping_sub(self);
            } else {
                return self.wrapping_sub(other);
            }
        }

        pub fn lt(self: Self, other: Self) bool {
            if (bits == 0) return false;

            // For 256-bit or smaller, use native u256 operations for better performance
            if (comptime bits <= 256) {
                const self_u256 = self.to_u256() orelse unreachable;
                const other_u256 = other.to_u256() orelse unreachable;
                return self_u256 < other_u256;
            }

            var i = limbs;
            while (i > 0) {
                i -= 1;
                if (self.limbs[i] < other.limbs[i]) return true;
                if (self.limbs[i] > other.limbs[i]) return false;
            }
            return false;
        }

        pub fn gt(self: Self, other: Self) bool {
            // For 256-bit or smaller, use native u256 operations for better performance
            if (comptime bits <= 256) {
                const self_u256 = self.to_u256() orelse unreachable;
                const other_u256 = other.to_u256() orelse unreachable;
                return self_u256 > other_u256;
            }

            return other.lt(self);
        }

        pub fn le(self: Self, other: Self) bool {
            return !self.gt(other);
        }

        pub fn ge(self: Self, other: Self) bool {
            return !self.lt(other);
        }

        pub fn cmp(self: Self, other: Self) std.math.Order {
            if (bits == 0) return .eq;
            var i = limbs;
            while (i > 0) {
                i -= 1;
                if (self.limbs[i] < other.limbs[i]) return .lt;
                if (self.limbs[i] > other.limbs[i]) return .gt;
            }
            return .eq;
        }

        pub fn min(self: Self, other: Self) Self {
            return if (self.lt(other)) self else other;
        }

        pub fn max(self: Self, other: Self) Self {
            return if (self.gt(other)) self else other;
        }

        // Branch-free comparison operations for better performance
        pub fn ltBranchFree(self: Self, other: Self) bool {
            if (bits == 0) return false;

            // For 256-bit numbers, use specialized half-width optimization
            if (comptime bits == 256 and limbs == 4) {
                const xhi = (@as(u128, self.limbs[3]) << 64) | @as(u128, self.limbs[2]);
                const xlo = (@as(u128, self.limbs[1]) << 64) | @as(u128, self.limbs[0]);
                const yhi = (@as(u128, other.limbs[3]) << 64) | @as(u128, other.limbs[2]);
                const ylo = (@as(u128, other.limbs[1]) << 64) | @as(u128, other.limbs[0]);

                return (@intFromBool(xhi < yhi) | (@intFromBool(xhi == yhi) & @intFromBool(xlo < ylo))) != 0;
            }

            // General branch-free comparison using XOR folding
            var eq_mask: u64 = std.math.maxInt(u64);
            var lt_flag: u64 = 0;

            var i = limbs;
            while (i > 0) {
                i -= 1;
                const a = self.limbs[i];
                const b = other.limbs[i];
                const is_lt = @intFromBool(a < b);
                const is_eq = @intFromBool(a == b);

                lt_flag = (lt_flag & eq_mask) | (is_lt & eq_mask);
                eq_mask = eq_mask & (is_eq | ~@as(u64, 1));
            }

            return lt_flag != 0;
        }

        pub fn gtBranchFree(self: Self, other: Self) bool {
            return other.ltBranchFree(self);
        }

        pub fn leBranchFree(self: Self, other: Self) bool {
            return !self.gtBranchFree(other);
        }

        pub fn geBranchFree(self: Self, other: Self) bool {
            return !self.ltBranchFree(other);
        }

        pub fn clamp(self: Self, min_val: Self, max_val: Self) Self {
            if (self.lt(min_val)) return min_val;
            if (self.gt(max_val)) return max_val;
            return self;
        }

        pub fn overflowing_mul(self: Self, rhs: Self) struct { result: Self, overflow: bool } {
            if (bits == 0) return .{ .result = ZERO, .overflow = false };

            var result = ZERO;
            var overflow = false;

            // Schoolbook multiplication algorithm
            for (0..limbs) |i| {
                if (self.limbs[i] == 0) continue;

                var carry: u64 = 0;
                for (0..limbs) |j| {
                    if (i + j >= limbs) {
                        if (rhs.limbs[j] != 0) {
                            overflow = true;
                        }
                        break;
                    }

                    // Use optimized multiplication
                    const mul_result = mul64x64(self.limbs[i], rhs.limbs[j]);

                    // Add to result with carry
                    const add1 = addWithCarry(result.limbs[i + j], mul_result.low, 0);
                    const add2 = addWithCarry(mul_result.high, carry, add1.carry);

                    result.limbs[i + j] = add1.sum;
                    carry = add2.sum + add2.carry;
                }

                if (carry != 0) {
                    if (i + limbs < limbs) {
                        result.limbs[i + limbs] = carry;
                    } else {
                        overflow = true;
                    }
                }
            }

            // Check if result exceeds mask
            if (limbs > 0 and MASK != std.math.maxInt(u64) and result.limbs[limbs - 1] > MASK) {
                overflow = true;
            }

            return .{ .result = result.masked(), .overflow = overflow };
        }

        pub fn checked_mul(self: Self, rhs: Self) ?Self {
            const result = self.overflowing_mul(rhs);
            if (result.overflow) return null;
            return result.result;
        }

        pub fn wrapping_mul(self: Self, rhs: Self) Self {
            return self.overflowing_mul(rhs).result;
        }

        pub fn saturating_mul(self: Self, rhs: Self) Self {
            const result = self.overflowing_mul(rhs);
            if (result.overflow) return MAX;
            return result.result;
        }

        pub fn mul_single(self: Self, rhs: u64) struct { result: Self, carry: u64 } {
            if (bits == 0 or rhs == 0) return .{ .result = ZERO, .carry = 0 };

            var result = ZERO;
            var carry: u64 = 0;

            for (0..limbs) |i| {
                const prod = @as(u128, self.limbs[i]) * @as(u128, rhs) + carry;
                result.limbs[i] = @truncate(prod);
                carry = @truncate(prod >> 64);
            }

            return .{ .result = result.masked(), .carry = carry };
        }

        pub fn div_rem(self: Self, divisor: Self) DivRemResult {
            if (bits == 0) return .{ .quotient = ZERO, .remainder = ZERO };
            if (divisor.is_zero()) @panic("division by zero");

            // Fast path: divisor is power of 2
            if (divisor.count_ones() == 1) {
                const shift = divisor.trailing_zeros();
                return .{
                    .quotient = self.wrapping_shr(shift),
                    .remainder = self.bit_and(divisor.wrapping_sub(ONE)),
                };
            }

            // Special case: divisor > dividend
            if (self.lt(divisor)) {
                return .{ .quotient = ZERO, .remainder = self };
            }

            // Special case: single limb division
            if (limbs == 1) {
                return .{
                    .quotient = Self.from_u64(self.limbs[0] / divisor.limbs[0]),
                    .remainder = Self.from_u64(self.limbs[0] % divisor.limbs[0]),
                };
            }

            // Fast path: single-word divisor
            if (limbs > 1) {
                var is_single_word = true;
                for (1..limbs) |i| {
                    if (divisor.limbs[i] != 0) {
                        is_single_word = false;
                        break;
                    }
                }
                if (is_single_word) {
                    return self.divRemBy64(divisor.limbs[0]);
                }
            }

            // Long division algorithm
            var quotient = ZERO;
            var remainder = self;

            // Find the highest set bit in divisor
            var divisor_bits: usize = 0;
            var i = limbs;
            while (i > 0) {
                i -= 1;
                if (divisor.limbs[i] != 0) {
                    divisor_bits = i * 64 + (64 - @clz(divisor.limbs[i]));
                    break;
                }
            }

            // Find the highest set bit in dividend
            var dividend_bits: usize = 0;
            i = limbs;
            while (i > 0) {
                i -= 1;
                if (remainder.limbs[i] != 0) {
                    dividend_bits = i * 64 + (64 - @clz(remainder.limbs[i]));
                    break;
                }
            }

            if (dividend_bits < divisor_bits) {
                return .{ .quotient = ZERO, .remainder = self };
            }

            // Shift divisor left to align with dividend
            var shift = dividend_bits - divisor_bits;
            var shifted_divisor = divisor.wrapping_shl(@intCast(shift));

            // Perform long division
            while (true) {
                if (!remainder.lt(shifted_divisor)) {
                    remainder = remainder.wrapping_sub(shifted_divisor);
                    quotient = quotient.set_bit(@intCast(shift), true);
                }

                if (shift == 0) break;
                shift -= 1;
                shifted_divisor = shifted_divisor.wrapping_shr(1);
            }

            return .{ .quotient = quotient, .remainder = remainder };
        }

        // Optimized division by a single u64
        fn divRemBy64(self: Self, divisor: u64) DivRemResult {
            if (divisor == 0) @panic("division by zero");

            var quotient = ZERO;
            var remainder: u64 = 0;

            var i = limbs;
            while (i > 0) {
                i -= 1;
                const dividend = (@as(u128, remainder) << 64) | @as(u128, self.limbs[i]);
                quotient.limbs[i] = @truncate(dividend / divisor);
                remainder = @truncate(dividend % divisor);
            }

            return .{
                .quotient = quotient,
                .remainder = Self.from_u64(remainder),
            };
        }

        pub fn wrapping_div(self: Self, rhs: Self) Self {
            return self.div_rem(rhs).quotient;
        }

        pub fn wrapping_rem(self: Self, rhs: Self) Self {
            return self.div_rem(rhs).remainder;
        }

        pub fn checked_div(self: Self, rhs: Self) ?Self {
            if (rhs.is_zero()) return null;
            return self.wrapping_div(rhs);
        }

        pub fn checked_rem(self: Self, rhs: Self) ?Self {
            if (rhs.is_zero()) return null;
            return self.wrapping_rem(rhs);
        }

        pub fn div_ceil(self: Self, rhs: Self) Self {
            const result = self.div_rem(rhs);
            if (result.remainder.is_zero()) {
                return result.quotient;
            } else {
                return result.quotient.wrapping_add(ONE);
            }
        }

        pub fn wrapping_shl(self: Self, shift: u32) Self {
            if (bits == 0 or shift >= bits) return ZERO;
            if (shift == 0) return self;

            // For 256-bit or smaller, use native u256 operations for better performance
            if (comptime bits <= 256) {
                const self_u256 = self.to_u256() orelse unreachable;
                const shifted = if (shift >= 256) 0 else self_u256 << @intCast(shift);
                return Self.from_u256(shifted);
            }

            // Optimized path for 256-bit numbers (fallback for larger types)
            if (comptime bits == 256 and limbs == 4) {
                return self.shl256Optimized(shift);
            }

            var result = ZERO;
            const word_shift = shift / 64;
            const bit_shift = shift % 64;

            if (bit_shift == 0) {
                // Simple word shift
                var j: usize = 0;
                while (j < limbs - word_shift) : (j += 1) {
                    result.limbs[j + word_shift] = self.limbs[j];
                }
            } else {
                // Bit shift with carry
                const inv_bit_shift = 64 - bit_shift;
                var carry: u64 = 0;
                var j: usize = 0;
                while (j < limbs) : (j += 1) {
                    const new_carry = self.limbs[j] >> @intCast(inv_bit_shift);
                    if (j + word_shift < limbs) {
                        result.limbs[j + word_shift] = (self.limbs[j] << @intCast(bit_shift)) | carry;
                    }
                    carry = new_carry;
                }
                if (word_shift + limbs < limbs and carry != 0) {
                    result.limbs[word_shift + limbs] = carry;
                }
            }

            return result.masked();
        }

        // Optimized left shift for 256-bit numbers
        fn shl256Optimized(self: Self, shift: u32) Self {
            const half_bits = 128;

            if (shift < half_bits) {
                // Shift within lower 128 bits affects both halves
                const lo = (@as(u128, self.limbs[1]) << 64) | @as(u128, self.limbs[0]);
                const hi = (@as(u128, self.limbs[3]) << 64) | @as(u128, self.limbs[2]);

                const shifted_lo = lo << @intCast(shift);
                const carry = lo >> @intCast(128 - shift);
                const shifted_hi = (hi << @intCast(shift)) | carry;

                return Self.from_limbs(.{
                    @truncate(shifted_lo),
                    @truncate(shifted_lo >> 64),
                    @truncate(shifted_hi),
                    @truncate(shifted_hi >> 64),
                });
            } else if (shift < 256) {
                // Shift moves lower half to upper half
                const lo = (@as(u128, self.limbs[1]) << 64) | @as(u128, self.limbs[0]);
                const shifted_hi = lo << @intCast(shift - half_bits);

                return Self.from_limbs(.{
                    0,                     0,
                    @truncate(shifted_hi), @truncate(shifted_hi >> 64),
                });
            } else {
                return ZERO;
            }
        }

        pub fn wrapping_shr(self: Self, shift: u32) Self {
            if (bits == 0 or shift >= bits) return ZERO;
            if (shift == 0) return self;

            // For 256-bit or smaller, use native u256 operations for better performance
            if (comptime bits <= 256) {
                const self_u256 = self.to_u256() orelse unreachable;
                const shifted = if (shift >= 256) 0 else self_u256 >> @intCast(shift);
                return Self.from_u256(shifted);
            }

            var result = ZERO;
            const word_shift = shift / 64;
            const bit_shift = shift % 64;

            if (bit_shift == 0) {
                // Simple word shift
                var j: usize = word_shift;
                while (j < limbs) : (j += 1) {
                    result.limbs[j - word_shift] = self.limbs[j];
                }
            } else {
                // Bit shift with carry
                const inv_bit_shift = 64 - bit_shift;
                var carry: u64 = 0;
                var j: usize = limbs;
                while (j > word_shift) {
                    j -= 1;
                    const new_carry = self.limbs[j] << @intCast(inv_bit_shift);
                    result.limbs[j - word_shift] = (self.limbs[j] >> @intCast(bit_shift)) | carry;
                    carry = new_carry;
                }
            }

            return result;
        }

        pub fn set_bit(self: Self, index: usize, value: bool) Self {
            if (index >= bits) return self;

            var result = self;
            const word_index = index / 64;
            const bit_index = @as(u6, @intCast(index % 64));
            const bit_mask = @as(u64, 1) << bit_index;

            if (value) {
                result.limbs[word_index] |= bit_mask;
            } else {
                result.limbs[word_index] &= ~bit_mask;
            }

            return result;
        }

        pub fn get_bit(self: Self, index: usize) bool {
            if (index >= bits) return false;

            const word_index = index / 64;
            const bit_index = @as(u6, @intCast(index % 64));
            const bit_mask = @as(u64, 1) << bit_index;

            return (self.limbs[word_index] & bit_mask) != 0;
        }

        pub fn bit_and(self: Self, rhs: Self) Self {
            // For 256-bit or smaller, use native u256 operations for better performance
            if (comptime bits <= 256) {
                const self_u256 = self.to_u256() orelse unreachable;
                const rhs_u256 = rhs.to_u256() orelse unreachable;
                return Self.from_u256(self_u256 & rhs_u256);
            }

            var result = ZERO;
            for (0..limbs) |i| {
                result.limbs[i] = self.limbs[i] & rhs.limbs[i];
            }
            return result;
        }

        pub fn bit_or(self: Self, rhs: Self) Self {
            // For 256-bit or smaller, use native u256 operations for better performance
            if (comptime bits <= 256) {
                const self_u256 = self.to_u256() orelse unreachable;
                const rhs_u256 = rhs.to_u256() orelse unreachable;
                return Self.from_u256(self_u256 | rhs_u256);
            }

            var result = ZERO;
            for (0..limbs) |i| {
                result.limbs[i] = self.limbs[i] | rhs.limbs[i];
            }
            return result.masked();
        }

        pub fn bit_xor(self: Self, rhs: Self) Self {
            // For 256-bit or smaller, use native u256 operations for better performance
            if (comptime bits <= 256) {
                const self_u256 = self.to_u256() orelse unreachable;
                const rhs_u256 = rhs.to_u256() orelse unreachable;
                return Self.from_u256(self_u256 ^ rhs_u256);
            }

            var result = ZERO;
            for (0..limbs) |i| {
                result.limbs[i] = self.limbs[i] ^ rhs.limbs[i];
            }
            return result.masked();
        }

        pub fn bit_not(self: Self) Self {
            var result = ZERO;
            for (0..limbs) |i| {
                result.limbs[i] = ~self.limbs[i];
            }
            return result.masked();
        }

        pub fn count_ones(self: Self) u32 {
            var count: u32 = 0;
            for (0..limbs) |i| {
                count += @popCount(self.limbs[i]);
            }
            return count;
        }

        pub fn count_zeros(self: Self) u32 {
            if (bits == 0) return 0;
            return @as(u32, @intCast(bits)) - self.count_ones();
        }

        pub fn leading_zeros(self: Self) u32 {
            if (bits == 0) return 0;

            var zeros: u32 = 0;
            var i = limbs;
            while (i > 0) {
                i -= 1;
                if (self.limbs[i] == 0) {
                    zeros += 64;
                } else {
                    zeros += @clz(self.limbs[i]);
                    break;
                }
            }

            // Adjust for non-limb-aligned sizes
            const total_bits = limbs * 64;
            if (zeros > total_bits - bits) {
                zeros = @intCast(total_bits - bits);
            }

            return zeros;
        }

        pub fn bit_len(self: Self) usize {
            if (bits == 0) return 0;
            return bits - self.leading_zeros();
        }

        pub fn byte_len(self: Self) usize {
            const bit_length = self.bit_len();
            return (bit_length + 7) / 8;
        }

        pub fn log2(self: Self) usize {
            std.debug.assert(!self.is_zero());
            return self.bit_len() - 1;
        }

        pub fn checked_log2(self: Self) ?usize {
            if (self.is_zero()) return null;
            return self.log2();
        }

        pub fn log10(self: Self) usize {
            return self.log(Self.from_u64(10));
        }

        pub fn checked_log10(self: Self) ?usize {
            if (self.is_zero()) return null;
            return self.log10();
        }

        pub fn log(self: Self, base: Self) usize {
            std.debug.assert(!self.is_zero());
            std.debug.assert(base.ge(Self.from_u64(2)));

            if (base.eq(Self.from_u64(2))) {
                return self.log2();
            }

            var result: usize = 0;
            var n = self;
            while (n.ge(base)) {
                n = n.wrapping_div(base);
                result += 1;
            }
            return result;
        }

        pub fn checked_log(self: Self, base: Self) ?usize {
            if (self.is_zero() or base.lt(Self.from_u64(2))) return null;
            return self.log(base);
        }

        pub fn gcd(self: Self, other: Self) Self {
            if (self.is_zero()) return other;
            if (other.is_zero()) return self;

            var a = self;
            var b = other;

            // Use binary GCD algorithm (Stein's algorithm)
            const shift = @min(a.trailing_zeros(), b.trailing_zeros());
            a = a.wrapping_shr(a.trailing_zeros());

            while (!b.is_zero()) {
                b = b.wrapping_shr(b.trailing_zeros());
                if (a.gt(b)) {
                    const temp = a;
                    a = b;
                    b = temp;
                }
                b = b.wrapping_sub(a);
            }

            return a.wrapping_shl(shift);
        }

        pub fn lcm(self: Self, other: Self) ?Self {
            if (self.is_zero() or other.is_zero()) return Self.ZERO;
            const gcd_val = self.gcd(other);
            const div_result = other.checked_div(gcd_val);
            if (div_result) |div| {
                return self.checked_mul(div);
            }
            return null;
        }

        pub fn reduce_mod(self: Self, modulus: Self) Self {
            if (modulus.is_zero()) return Self.ZERO;
            if (self.lt(modulus)) return self;
            return self.wrapping_rem(modulus);
        }

        pub fn add_mod(self: Self, rhs: Self, modulus: Self) Self {
            if (modulus.is_zero()) return Self.ZERO;

            // Fast path for large modulus (>= 2^192)
            if (limbs >= 3 and modulus.limbs[limbs - 1] != 0 and
                self.limbs[limbs - 1] <= modulus.limbs[limbs - 1] and
                rhs.limbs[limbs - 1] <= modulus.limbs[limbs - 1])
            {

                // Normalize operands in case they exceed modulus
                const x_norm = if (self.ge(modulus)) self.wrapping_sub(modulus) else self;
                const y_norm = if (rhs.ge(modulus)) rhs.wrapping_sub(modulus) else rhs;

                const sum_result = x_norm.overflowing_add(y_norm);
                const sum = sum_result.result;

                const mod_result = sum.overflowing_sub(modulus);

                if (sum_result.overflow or !mod_result.overflow) {
                    return mod_result.result;
                } else {
                    return sum;
                }
            }

            // Fast path for small values
            if (self.lt(modulus) and rhs.lt(modulus)) {
                const sum = self.wrapping_add(rhs);
                if (sum.lt(self) or sum.ge(modulus)) {
                    // Overflow occurred or sum >= modulus
                    return sum.wrapping_sub(modulus);
                }
                return sum;
            }

            // Reduce operands first
            const a = self.reduce_mod(modulus);
            const b = rhs.reduce_mod(modulus);
            const sum = a.wrapping_add(b);
            return sum.reduce_mod(modulus);
        }

        pub fn mul_mod(self: Self, rhs: Self, modulus: Self) Self {
            if (modulus.is_zero()) return Self.ZERO;

            // Reduce operands first
            const a = self.reduce_mod(modulus);
            const b = rhs.reduce_mod(modulus);

            // For small modulus, we can use direct multiplication
            if (modulus.bit_len() <= bits / 2) {
                const product = a.wrapping_mul(b);
                return product.reduce_mod(modulus);
            }

            // Use Russian peasant multiplication for larger values
            var result = Self.ZERO;
            var x = a;
            var y = b;

            while (!y.is_zero()) {
                if (y.get_bit(0)) {
                    result = result.add_mod(x, modulus);
                }
                x = x.add_mod(x, modulus);
                y = y.wrapping_shr(1);
            }

            return result;
        }

        pub fn pow_mod(self: Self, exp: Self, modulus: Self) Self {
            if (modulus.is_zero()) return Self.ZERO;
            if (modulus.eq(Self.ONE)) return Self.ZERO;

            var result = Self.ONE;
            var base = self.reduce_mod(modulus);
            var exponent = exp;

            while (!exponent.is_zero()) {
                if (exponent.get_bit(0)) {
                    result = result.mul_mod(base, modulus);
                }
                base = base.mul_mod(base, modulus);
                exponent = exponent.wrapping_shr(1);
            }

            return result;
        }

        pub fn trailing_zeros(self: Self) u32 {
            if (bits == 0) return 0;

            // For 256-bit or smaller, use native u256 operations for better performance
            if (comptime bits <= 256) {
                const self_u256 = self.to_u256() orelse unreachable;
                const result = @ctz(self_u256);
                return @min(result, @as(u32, @intCast(bits)));
            }

            var zeros: u32 = 0;
            for (0..limbs) |i| {
                if (self.limbs[i] == 0) {
                    zeros += 64;
                } else {
                    zeros += @ctz(self.limbs[i]);
                    break;
                }
            }

            if (zeros > bits) {
                zeros = @intCast(bits);
            }

            return zeros;
        }

        pub fn leading_ones(self: Self) u32 {
            return self.bit_not().leading_zeros();
        }

        pub fn trailing_ones(self: Self) u32 {
            return self.bit_not().trailing_zeros();
        }

        pub fn byte(self: Self, index: usize) u8 {
            const byte_index = index % 8;
            const limb_index = index / 8;
            if (limb_index >= limbs) return 0;

            return @truncate(self.limbs[limb_index] >> @intCast(byte_index * 8));
        }

        pub fn set_byte(self: Self, index: usize, value: u8) Self {
            const byte_index = index % 8;
            const limb_index = index / 8;
            if (limb_index >= limbs) return self;

            var result = self;
            const shift = @as(u6, @intCast(byte_index * 8));
            const byte_mask = ~(@as(u64, 0xFF) << shift);
            result.limbs[limb_index] = (result.limbs[limb_index] & byte_mask) | (@as(u64, value) << shift);
            return result;
        }

        pub fn reverse_bits(self: Self) Self {
            var result = ZERO;
            for (0..limbs) |i| {
                result.limbs[limbs - 1 - i] = @bitReverse(self.limbs[i]);
            }

            // Adjust for non-limb-aligned sizes
            if (bits % 64 != 0) {
                const extra_bits = limbs * 64 - bits;
                result = result.wrapping_shr(@intCast(extra_bits));
            }

            return result.masked();
        }

        pub fn swap_bytes(self: Self) Self {
            var result = ZERO;
            for (0..limbs) |i| {
                result.limbs[limbs - 1 - i] = @byteSwap(self.limbs[i]);
            }

            // Adjust for non-limb-aligned sizes
            if (bits % 64 != 0) {
                const extra_bytes = (limbs * 8) - (bits / 8);
                result = result.wrapping_shr(@intCast(extra_bytes * 8));
            }

            return result.masked();
        }

        pub fn rotate_left(self: Self, n: u32) Self {
            if (bits == 0) return ZERO;
            const normalized = n % bits;
            if (normalized == 0) return self;

            const left = self.wrapping_shl(normalized);
            const right = self.wrapping_shr(@intCast(bits - normalized));
            return left.bit_or(right);
        }

        pub fn rotate_right(self: Self, n: u32) Self {
            if (bits == 0) return ZERO;
            const normalized = n % bits;
            if (normalized == 0) return self;

            const right = self.wrapping_shr(normalized);
            const left = self.wrapping_shl(@intCast(bits - normalized));
            return left.bit_or(right);
        }

        pub fn pow(self: Self, exp: u32) Self {
            return self.overflowing_pow(exp).result;
        }

        pub fn overflowing_pow(self: Self, exp: u32) struct { result: Self, overflow: bool } {
            if (bits == 0) return .{ .result = ZERO, .overflow = false };
            if (exp == 0) return .{ .result = ONE, .overflow = false };
            if (self.is_zero()) return .{ .result = ZERO, .overflow = false };
            if (self.eq(ONE)) return .{ .result = ONE, .overflow = false };

            var result = ONE;
            var base = self;
            var exponent = exp;
            var overflow = false;

            while (exponent > 0) {
                if (exponent & 1 == 1) {
                    const mul_result = result.overflowing_mul(base);
                    result = mul_result.result;
                    overflow = overflow or mul_result.overflow;
                }

                if (exponent > 1) {
                    const sq_result = base.overflowing_mul(base);
                    base = sq_result.result;
                    overflow = overflow or sq_result.overflow;
                }

                exponent >>= 1;
            }

            return .{ .result = result, .overflow = overflow };
        }

        pub fn checked_pow(self: Self, exp: u32) ?Self {
            const result = self.overflowing_pow(exp);
            if (result.overflow) return null;
            return result.result;
        }

        pub fn saturating_pow(self: Self, exp: u32) Self {
            const result = self.overflowing_pow(exp);
            if (result.overflow) return MAX;
            return result.result;
        }

        pub fn wrapping_pow(self: Self, exp: u32) Self {
            return self.overflowing_pow(exp).result;
        }

        pub fn sqrt(self: Self) Self {
            if (bits == 0 or self.is_zero()) return ZERO;
            if (self.eq(ONE)) return ONE;

            // Newton's method for integer square root
            var x = self;
            var y = (x.wrapping_add(ONE)).wrapping_shr(1);

            while (y.lt(x)) {
                x = y;
                y = (x.wrapping_add(self.wrapping_div(x))).wrapping_shr(1);
            }

            return x;
        }

        pub fn is_power_of_two(self: Self) bool {
            if (self.is_zero()) return false;
            return self.bit_and(self.wrapping_sub(ONE)).is_zero();
        }

        pub fn next_power_of_two(self: Self) ?Self {
            if (self.is_zero()) return ONE;
            if (self.is_power_of_two()) return self;

            const ones = @as(u32, @intCast(bits)) - self.leading_zeros();
            if (ones >= bits) return null;

            return ONE.wrapping_shl(ones);
        }

        pub fn checked_next_power_of_two(self: Self) ?Self {
            return self.next_power_of_two();
        }

        pub const ParseError = error{
            InvalidDigit,
            InvalidRadix,
            Overflow,
        };

        pub fn from_str_radix(src: []const u8, radix: u64) ParseError!Self {
            if (radix < 2) return error.InvalidRadix;
            if (radix > 64) return error.InvalidRadix;
            if (bits == 0) {
                for (src) |c| {
                    const digit = parse_digit(c, radix) catch return error.InvalidDigit;
                    if (digit != 0) return error.Overflow;
                }
                return ZERO;
            }

            var result = ZERO;
            const base = Self.from_u64(radix);

            for (src) |c| {
                if (c == '_' and radix <= 36) continue;

                const digit = parse_digit(c, radix) catch |err| {
                    if (err == error.Ignored) continue;
                    return error.InvalidDigit;
                };
                if (digit >= radix) return error.InvalidDigit;

                const mul_result = result.overflowing_mul(base);
                if (mul_result.overflow) return error.Overflow;
                result = mul_result.result;

                const add_result = result.overflowing_add(Self.from_u64(digit));
                if (add_result.overflow) return error.Overflow;
                result = add_result.result;
            }

            return result;
        }

        fn parse_digit(c: u8, radix: u64) !u64 {
            const digit = if (radix <= 36) blk: {
                break :blk switch (c) {
                    '0'...'9' => c - '0',
                    'a'...'z' => c - 'a' + 10,
                    'A'...'Z' => c - 'A' + 10,
                    '_' => return error.Ignored,
                    else => return error.InvalidDigit,
                };
            } else blk: {
                break :blk switch (c) {
                    'A'...'Z' => c - 'A',
                    'a'...'z' => c - 'a' + 26,
                    '0'...'9' => c - '0' + 52,
                    '+', '-' => 62,
                    '/', ',', '_' => 63,
                    '=', '\r', '\n' => return error.Ignored,
                    else => return error.InvalidDigit,
                };
            };
            return digit;
        }

        pub fn from_str(src: []const u8) ParseError!Self {
            if (src.len >= 2) {
                const prefix = src[0..2];
                if (std.mem.eql(u8, prefix, "0x") or std.mem.eql(u8, prefix, "0X")) {
                    return from_str_radix(src[2..], 16);
                } else if (std.mem.eql(u8, prefix, "0o") or std.mem.eql(u8, prefix, "0O")) {
                    return from_str_radix(src[2..], 8);
                } else if (std.mem.eql(u8, prefix, "0b") or std.mem.eql(u8, prefix, "0B")) {
                    return from_str_radix(src[2..], 2);
                }
            }
            return from_str_radix(src, 10);
        }

        pub fn to_string_radix(self: Self, allocator: std.mem.Allocator, radix: u64) ![]u8 {
            if (radix < 2 or radix > 36) return error.InvalidRadix;
            if (self.is_zero()) {
                const result = try allocator.alloc(u8, 1);
                result[0] = '0';
                return result;
            }

            var digits = std.ArrayList(u8).init(allocator);
            defer digits.deinit();

            var n = self;
            const base = Self.from_u64(radix);

            while (!n.is_zero()) {
                const div_result = n.div_rem(base);
                n = div_result.quotient;
                const digit = @as(u8, @intCast(div_result.remainder.to_u64()));
                const c = if (digit < 10) '0' + digit else 'a' + digit - 10;
                try digits.append(c);
            }

            const result = try allocator.alloc(u8, digits.items.len);
            for (digits.items, 0..) |digit, i| {
                result[result.len - 1 - i] = digit;
            }
            return result;
        }

        pub fn to_u64(self: Self) u64 {
            if (bits == 0) return 0;
            return self.limbs[0];
        }

        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = options;

            if (fmt.len == 0) {
                try self.format_decimal(writer);
            } else if (fmt.len == 1) {
                switch (fmt[0]) {
                    'b' => try self.format_binary(writer),
                    'o' => try self.format_octal(writer),
                    'x' => try self.format_hex(writer, false),
                    'X' => try self.format_hex(writer, true),
                    else => try self.format_decimal(writer),
                }
            } else {
                try self.format_decimal(writer);
            }
        }

        fn format_decimal(self: Self, writer: anytype) !void {
            if (self.is_zero()) {
                try writer.writeAll("0");
                return;
            }

            var buffer: [80]u8 = undefined;
            var index: usize = buffer.len;
            var n = self;
            const base = Self.from_u64(10);

            while (!n.is_zero()) {
                const div_result = n.div_rem(base);
                n = div_result.quotient;
                const digit = @as(u8, @intCast(div_result.remainder.to_u64()));
                index -= 1;
                buffer[index] = '0' + digit;
            }

            try writer.writeAll(buffer[index..]);
        }

        fn format_binary(self: Self, writer: anytype) !void {
            if (self.is_zero()) {
                try writer.writeAll("0b0");
                return;
            }

            try writer.writeAll("0b");
            var started = false;
            var i: usize = limbs;
            while (i > 0) : (i -= 1) {
                const limb = self.limbs[i - 1];
                if (!started and limb == 0) continue;

                if (!started) {
                    const lz = @clz(limb);
                    var j: u6 = 63 - @as(u6, @intCast(lz));
                    started = true;
                    while (j < 64) : (j -%= 1) {
                        const bit = (limb >> j) & 1;
                        try writer.print("{}", .{bit});
                        if (j == 0) break;
                    }
                } else {
                    var j: u6 = 63;
                    while (j < 64) : (j -%= 1) {
                        const bit = (limb >> j) & 1;
                        try writer.print("{}", .{bit});
                        if (j == 0) break;
                    }
                }
            }
        }

        fn format_octal(self: Self, writer: anytype) !void {
            if (self.is_zero()) {
                try writer.writeAll("0o0");
                return;
            }

            try writer.writeAll("0o");
            var buffer: [90]u8 = undefined;
            var index: usize = buffer.len;
            var n = self;
            const base = Self.from_u64(8);

            while (!n.is_zero()) {
                const div_result = n.div_rem(base);
                n = div_result.quotient;
                const digit = @as(u8, @intCast(div_result.remainder.to_u64()));
                index -= 1;
                buffer[index] = '0' + digit;
            }

            try writer.writeAll(buffer[index..]);
        }

        fn format_hex(self: Self, writer: anytype, uppercase: bool) !void {
            if (self.is_zero()) {
                try writer.writeAll("0x0");
                return;
            }

            try writer.writeAll("0x");
            const chars = if (uppercase) "0123456789ABCDEF" else "0123456789abcdef";

            var started = false;
            var i: usize = limbs;
            while (i > 0) : (i -= 1) {
                const limb = self.limbs[i - 1];
                if (!started and limb == 0) continue;

                if (!started) {
                    const lz = @clz(limb);
                    const nibbles_to_skip = @divFloor(lz, 4);
                    started = true;

                    var j: usize = 15 - nibbles_to_skip;
                    while (j < 16) : (j -%= 1) {
                        const nibble = @as(u8, @intCast((limb >> (j * 4)) & 0xF));
                        try writer.print("{c}", .{chars[nibble]});
                        if (j == 0) break;
                    }
                } else {
                    var j: usize = 15;
                    while (j < 16) : (j -%= 1) {
                        const nibble = @as(u8, @intCast((limb >> (j * 4)) & 0xF));
                        try writer.print("{c}", .{chars[nibble]});
                        if (j == 0) break;
                    }
                }
            }
        }

        pub fn to_le_bytes(self: Self, bytes: []u8) void {
            const bytes_len = @min(bytes.len, (bits + 7) / 8);
            const full_limbs = bytes_len / 8;
            const extra_bytes = bytes_len % 8;

            var byte_idx: usize = 0;

            for (0..full_limbs) |limb_idx| {
                const limb = if (limb_idx < limbs) self.limbs[limb_idx] else 0;
                for (0..8) |b| {
                    bytes[byte_idx] = @truncate(limb >> @intCast(b * 8));
                    byte_idx += 1;
                }
            }

            if (extra_bytes > 0 and full_limbs < limbs) {
                const limb = self.limbs[full_limbs];
                for (0..extra_bytes) |idx| {
                    bytes[byte_idx] = @truncate(limb >> @intCast(idx * 8));
                    byte_idx += 1;
                }
            }
        }

        pub fn to_be_bytes(self: Self, bytes: []u8) void {
            const bytes_len = @min(bytes.len, (bits + 7) / 8);
            const full_limbs = bytes_len / 8;
            const extra_bytes = bytes_len % 8;

            var byte_idx: usize = 0;

            if (extra_bytes > 0 and full_limbs < limbs) {
                const limb = self.limbs[full_limbs];
                var i: usize = extra_bytes;
                while (i > 0) : (i -= 1) {
                    bytes[byte_idx] = @truncate(limb >> @intCast((i - 1) * 8));
                    byte_idx += 1;
                }
            }

            var limb_idx = full_limbs;
            while (limb_idx > 0) {
                limb_idx -= 1;
                const limb = if (limb_idx < limbs) self.limbs[limb_idx] else 0;
                var i: usize = 8;
                while (i > 0) : (i -= 1) {
                    bytes[byte_idx] = @truncate(limb >> @intCast((i - 1) * 8));
                    byte_idx += 1;
                }
            }
        }

        pub fn from_le_bytes(bytes: []const u8) Self {
            if (bits == 0) return ZERO;

            var result = ZERO;
            const max_bytes = (bits + 7) / 8;
            const bytes_len = @min(bytes.len, max_bytes);

            var byte_idx: usize = 0;
            var limb_idx: usize = 0;

            while (byte_idx < bytes_len and limb_idx < limbs) {
                var limb: u64 = 0;
                const bytes_in_limb = @min(8, bytes_len - byte_idx);

                for (0..bytes_in_limb) |b| {
                    limb |= @as(u64, bytes[byte_idx]) << @intCast(b * 8);
                    byte_idx += 1;
                }

                result.limbs[limb_idx] = limb;
                limb_idx += 1;
            }

            return result.masked();
        }

        pub fn from_be_bytes(bytes: []const u8) Self {
            if (bits == 0) return ZERO;

            var result = ZERO;
            const max_bytes = (bits + 7) / 8;
            const bytes_len = @min(bytes.len, max_bytes);

            var byte_idx: usize = 0;

            const full_limbs = bytes_len / 8;
            const extra_bytes = bytes_len % 8;

            if (extra_bytes > 0 and full_limbs < limbs) {
                var limb: u64 = 0;
                for (0..extra_bytes) |_| {
                    limb = (limb << 8) | bytes[byte_idx];
                    byte_idx += 1;
                }
                result.limbs[full_limbs] = limb;
            }

            var limb_idx = full_limbs;
            while (limb_idx > 0) {
                limb_idx -= 1;
                if (limb_idx < limbs) {
                    var limb: u64 = 0;
                    for (0..8) |_| {
                        limb = (limb << 8) | bytes[byte_idx];
                        byte_idx += 1;
                    }
                    result.limbs[limb_idx] = limb;
                } else {
                    byte_idx += 8;
                }
            }

            return result.masked();
        }

        pub fn to_le_bytes_exact(self: Self) [(bits + 7) / 8]u8 {
            const bytes_needed = (bits + 7) / 8;
            var bytes: [bytes_needed]u8 = undefined;
            self.to_le_bytes(&bytes);
            return bytes;
        }

        pub fn to_be_bytes_exact(self: Self) [(bits + 7) / 8]u8 {
            const bytes_needed = (bits + 7) / 8;
            var bytes: [bytes_needed]u8 = undefined;
            self.to_be_bytes(&bytes);
            return bytes;
        }

        // Optimized memory-aligned load from big-endian bytes
        pub fn loadBE(bytes: *const [(bits + 7) / 8]u8) Self {
            if (bits == 0) return ZERO;

            var result = ZERO;
            const byte_count = (bits + 7) / 8;

            // For aligned 256-bit loads, use optimized path
            if (comptime bits == 256 and limbs == 4 and byte_count == 32) {
                const src_ptr = @as([*]const u64, @ptrCast(@alignCast(bytes)));
                // Load in reverse order for big-endian
                result.limbs[0] = @byteSwap(src_ptr[3]);
                result.limbs[1] = @byteSwap(src_ptr[2]);
                result.limbs[2] = @byteSwap(src_ptr[1]);
                result.limbs[3] = @byteSwap(src_ptr[0]);
                return result;
            }

            // General case
            return Self.from_be_bytes(bytes);
        }

        // Optimized memory-aligned store to big-endian bytes
        pub fn storeBE(self: Self, bytes: *[(bits + 7) / 8]u8) void {
            if (bits == 0) return;

            const byte_count = (bits + 7) / 8;

            // For aligned 256-bit stores, use optimized path
            if (comptime bits == 256 and limbs == 4 and byte_count == 32) {
                const dst_ptr = @as([*]u64, @ptrCast(@alignCast(bytes)));
                // Store in reverse order for big-endian
                dst_ptr[0] = @byteSwap(self.limbs[3]);
                dst_ptr[1] = @byteSwap(self.limbs[2]);
                dst_ptr[2] = @byteSwap(self.limbs[1]);
                dst_ptr[3] = @byteSwap(self.limbs[0]);
                return;
            }

            // General case
            self.to_be_bytes(bytes);
        }

        pub fn inv_ring(self: Self) ?Self {
            if (bits == 0 or self.limbs[0] & 1 == 0) {
                return null;
            }

            // Compute inverse of first limb using Hensel's lemma
            var result = Self.ZERO;
            result.limbs[0] = blk: {
                const n = self.limbs[0];
                var inv = (n *% 3) ^ 2; // Correct on 4 bits
                inv *%= 2 -% n *% inv; // Correct on 8 bits
                inv *%= 2 -% n *% inv; // Correct on 16 bits
                inv *%= 2 -% n *% inv; // Correct on 32 bits
                inv *%= 2 -% n *% inv; // Correct on 64 bits
                break :blk inv;
            };

            // Continue with rest of limbs using Newton's method
            var correct_limbs: usize = 1;
            while (correct_limbs < limbs) : (correct_limbs *= 2) {
                result = result.wrapping_mul(Self.from_int(2).wrapping_sub(self.wrapping_mul(result)));
            }

            return result;
        }

        pub fn widening_mul(self: Self, comptime bits_rhs: usize, comptime limbs_rhs: usize, comptime bits_res: usize, comptime limbs_res: usize, rhs: Uint(bits_rhs, limbs_rhs)) Uint(bits_res, limbs_res) {
            comptime {
                std.debug.assert(bits_res == bits + bits_rhs);
                std.debug.assert(limbs_res == nlimbs(bits_res));
            }

            const Result = Uint(bits_res, limbs_res);
            var result = Result.ZERO;

            // Perform multiplication into the larger result
            var carry: u128 = 0;
            for (self.limbs, 0..) |a_limb, i| {
                carry = 0;
                for (rhs.limbs, 0..) |b_limb, j| {
                    if (i + j < limbs_res) {
                        const prod = @as(u128, a_limb) * @as(u128, b_limb) + carry + result.limbs[i + j];
                        result.limbs[i + j] = @truncate(prod);
                        carry = prod >> 64;
                    }
                }
                if (i + limbs_rhs < limbs_res) {
                    result.limbs[i + limbs_rhs] = @truncate(carry);
                }
            }

            return result;
        }

        pub fn root(self: Self, degree: usize) Self {
            std.debug.assert(degree > 0);

            // Handle zero case
            if (self.is_zero()) {
                return Self.ZERO;
            }

            // Handle case where degree > bits
            if (degree >= bits) {
                return Self.ONE;
            }

            // Handle case where degree == 1
            if (degree == 1) {
                return self;
            }

            // Create first guess using bit length
            const bit_length = self.bit_len();
            var result = Self.ONE.shl(bit_length / degree);

            const deg_m1 = Self.from_int(degree - 1);

            // Newton's method iteration
            var decreasing = false;
            while (true) {
                const power = result.pow(deg_m1);
                if (power.is_zero()) {
                    result = Self.ZERO;
                    break;
                }

                const division = self.div(power);
                const iter = division.add(deg_m1.mul(result)).div(Self.from_int(degree));

                if (iter.eq(result)) {
                    break;
                }

                if (iter.lt(result)) {
                    decreasing = true;
                    result = iter;
                } else if (!decreasing) {
                    // Cap increase at 2x to prevent overshooting
                    const double = result.shl(1);
                    result = if (iter.gt(double)) double else iter;
                } else {
                    // If we were decreasing and now would increase, we're done
                    break;
                }
            }

            return result;
        }

        pub fn gcd_extended(self: Self, other: Self) struct { gcd: Self, x: Self, y: Self, sign: bool } {
            // Handle zero cases
            if (self.is_zero()) {
                return .{ .gcd = other, .x = Self.ZERO, .y = Self.ONE, .sign = false };
            }
            if (other.is_zero()) {
                return .{ .gcd = self, .x = Self.ONE, .y = Self.ZERO, .sign = true };
            }

            // Extended Euclidean algorithm
            var a = self;
            var b = other;
            var x0 = Self.ONE;
            var x1 = Self.ZERO;
            var y0 = Self.ZERO;
            var y1 = Self.ONE;
            var sign = true;

            while (!b.is_zero()) {
                const q_r = a.div_rem(b);
                const q = q_r.quotient;
                const r = q_r.remainder;

                a = b;
                b = r;

                const new_x = if (x0.ge(q.mul(x1))) x0.sub(q.mul(x1)) else q.mul(x1).sub(x0);
                x0 = x1;
                x1 = new_x;

                const new_y = if (y0.ge(q.mul(y1))) y0.sub(q.mul(y1)) else q.mul(y1).sub(y0);
                y0 = y1;
                y1 = new_y;

                sign = !sign;
            }

            return .{ .gcd = a, .x = x0, .y = y0, .sign = sign };
        }

        pub fn inv_mod(self: Self, modulus: Self) ?Self {
            if (modulus.is_zero() or modulus.eq(Self.ONE)) {
                return null;
            }

            const extended = self.gcd_extended(modulus);
            if (!extended.gcd.eq(Self.ONE)) {
                return null;
            }

            // Compute the inverse
            if (extended.sign) {
                return extended.x.reduce_mod(modulus);
            } else {
                return modulus.sub(extended.y.reduce_mod(modulus));
            }
        }

        pub fn from_u256(value: u256) Self {
            if (bits == 0) return Self.ZERO;
            if (bits < 256 and value >= (@as(u256, 1) << bits)) {
                @panic("Value too large for this Uint");
            }

            var result = Self.ZERO;
            const u256_limbs = 4; // u256 has 4 64-bit limbs
            const copy_limbs = @min(limbs, u256_limbs);

            var i: usize = 0;
            while (i < copy_limbs) : (i += 1) {
                result.limbs[i] = @truncate(value >> @intCast(i * 64));
            }

            return result.masked();
        }

        pub fn to_u256(self: Self) ?u256 {
            // Check if value fits in u256
            if (bits > 256) {
                // Check if high limbs are zero
                var i: usize = 4;
                while (i < limbs) : (i += 1) {
                    if (self.limbs[i] != 0) {
                        return null;
                    }
                }
            }

            var result: u256 = 0;
            const u256_limbs = @min(limbs, 4);

            var i: usize = 0;
            while (i < u256_limbs) : (i += 1) {
                result |= @as(u256, self.limbs[i]) << @intCast(i * 64);
            }

            return result;
        }
    };
}

test "nlimbs calculation" {
    try testing.expectEqual(@as(usize, 1), nlimbs(0));
    try testing.expectEqual(@as(usize, 1), nlimbs(1));
    try testing.expectEqual(@as(usize, 1), nlimbs(63));
    try testing.expectEqual(@as(usize, 1), nlimbs(64));
    try testing.expectEqual(@as(usize, 2), nlimbs(65));
    try testing.expectEqual(@as(usize, 2), nlimbs(128));
    try testing.expectEqual(@as(usize, 4), nlimbs(256));
    try testing.expectEqual(@as(usize, 8), nlimbs(512));
}

test "mask calculation" {
    try testing.expectEqual(@as(u64, 0), mask(0));
    try testing.expectEqual(@as(u64, 1), mask(1));
    try testing.expectEqual(@as(u64, 3), mask(2));
    try testing.expectEqual(@as(u64, 0x7FFFFFFF), mask(31));
    try testing.expectEqual(@as(u64, 0xFFFFFFFF), mask(32));
    try testing.expectEqual(@as(u64, 0x7FFFFFFFFFFFFFFF), mask(63));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), mask(64));
    try testing.expectEqual(@as(u64, 1), mask(65));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), mask(128));
}

test "Uint constants" {
    const U0 = Uint(0, 1);
    try testing.expect(U0.ZERO.is_zero());
    try testing.expect(U0.ONE.is_zero());
    try testing.expect(U0.MIN.is_zero());
    try testing.expect(U0.MAX.is_zero());

    const U64 = Uint(64, 1);
    try testing.expect(U64.ZERO.is_zero());
    try testing.expect(!U64.ONE.is_zero());
    try testing.expectEqual(@as(u64, 1), U64.ONE.limbs[0]);
    try testing.expectEqual(@as(u64, 0), U64.MIN.limbs[0]);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), U64.MAX.limbs[0]);

    const U128 = Uint(128, 2);
    try testing.expect(U128.ZERO.is_zero());
    try testing.expect(!U128.ONE.is_zero());
    try testing.expectEqual(@as(u64, 1), U128.ONE.limbs[0]);
    try testing.expectEqual(@as(u64, 0), U128.ONE.limbs[1]);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), U128.MAX.limbs[0]);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), U128.MAX.limbs[1]);

    const U256 = Uint(256, 4);
    try testing.expect(U256.ZERO.is_zero());
    try testing.expect(!U256.ONE.is_zero());
    try testing.expectEqual(@as(u64, 1), U256.ONE.limbs[0]);
    for (1..4) |i| {
        try testing.expectEqual(@as(u64, 0), U256.ONE.limbs[i]);
    }
    for (0..4) |i| {
        try testing.expectEqual(@as(u64, std.math.maxInt(u64)), U256.MAX.limbs[i]);
    }
}

test "Uint from_u64" {
    const U64 = Uint(64, 1);
    const val1 = U64.from_u64(42);
    try testing.expectEqual(@as(u64, 42), val1.limbs[0]);

    const U128 = Uint(128, 2);
    const val2 = U128.from_u64(12345);
    try testing.expectEqual(@as(u64, 12345), val2.limbs[0]);
    try testing.expectEqual(@as(u64, 0), val2.limbs[1]);

    const U256 = Uint(256, 4);
    const val3 = U256.from_u64(std.math.maxInt(u64));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), val3.limbs[0]);
    for (1..4) |i| {
        try testing.expectEqual(@as(u64, 0), val3.limbs[i]);
    }
}

test "Uint from_limbs" {
    const U128 = Uint(128, 2);
    const val1 = U128.from_limbs(.{ 0x1234567890ABCDEF, 0xFEDCBA0987654321 });
    try testing.expectEqual(@as(u64, 0x1234567890ABCDEF), val1.limbs[0]);
    try testing.expectEqual(@as(u64, 0xFEDCBA0987654321), val1.limbs[1]);

    const U256 = Uint(256, 4);
    const val2 = U256.from_limbs(.{ 1, 2, 3, 4 });
    try testing.expectEqual(@as(u64, 1), val2.limbs[0]);
    try testing.expectEqual(@as(u64, 2), val2.limbs[1]);
    try testing.expectEqual(@as(u64, 3), val2.limbs[2]);
    try testing.expectEqual(@as(u64, 4), val2.limbs[3]);
}

test "Uint equality" {
    const U64 = Uint(64, 1);
    try testing.expect(U64.ZERO.eq(U64.ZERO));
    try testing.expect(U64.ONE.eq(U64.ONE));
    try testing.expect(!U64.ZERO.eq(U64.ONE));
    try testing.expect(!U64.ONE.eq(U64.ZERO));

    const U128 = Uint(128, 2);
    const a = U128.from_limbs(.{ 123, 456 });
    const b = U128.from_limbs(.{ 123, 456 });
    const c = U128.from_limbs(.{ 123, 457 });
    try testing.expect(a.eq(b));
    try testing.expect(!a.eq(c));
}

test "Uint masking for non-limb-aligned sizes" {
    const U65 = Uint(65, 2);
    try testing.expectEqual(@as(u64, 1), U65.MASK);

    const val1 = U65.from_limbs(.{ std.math.maxInt(u64), 0xFF });
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), val1.limbs[0]);
    try testing.expectEqual(@as(u64, 1), val1.limbs[1]);

    const U127 = Uint(127, 2);
    try testing.expectEqual(@as(u64, 0x7FFFFFFFFFFFFFFF), U127.MASK);
    try testing.expectEqual(@as(u64, 0x7FFFFFFFFFFFFFFF), U127.MAX.limbs[1]);
}

test "Uint addition operations" {
    const U64 = Uint(64, 1);

    // Basic addition
    const a = U64.from_u64(10);
    const b = U64.from_u64(20);
    const sum = a.wrapping_add(b);
    try testing.expectEqual(@as(u64, 30), sum.limbs[0]);

    // Checked addition - no overflow
    const checked = a.checked_add(b);
    try testing.expect(checked != null);
    try testing.expectEqual(@as(u64, 30), checked.?.limbs[0]);

    // Overflowing addition
    const max = U64.MAX;
    const one = U64.ONE;
    const overflow_result = max.overflowing_add(one);
    try testing.expect(overflow_result.overflow);
    try testing.expectEqual(@as(u64, 0), overflow_result.result.limbs[0]);

    // Checked addition - overflow
    const checked_overflow = max.checked_add(one);
    try testing.expect(checked_overflow == null);

    // U128 multi-limb addition
    const U128 = Uint(128, 2);
    const c = U128.from_limbs(.{ std.math.maxInt(u64), 0 });
    const d = U128.from_limbs(.{ 1, 0 });
    const sum2 = c.wrapping_add(d);
    try testing.expectEqual(@as(u64, 0), sum2.limbs[0]);
    try testing.expectEqual(@as(u64, 1), sum2.limbs[1]);

    // U128 overflow
    const max128 = U128.MAX;
    const overflow128 = max128.overflowing_add(U128.ONE);
    try testing.expect(overflow128.overflow);
    try testing.expectEqual(@as(u64, 0), overflow128.result.limbs[0]);
    try testing.expectEqual(@as(u64, 0), overflow128.result.limbs[1]);
}

test "Uint subtraction operations" {
    const U64 = Uint(64, 1);

    // Basic subtraction
    const a = U64.from_u64(30);
    const b = U64.from_u64(10);
    const diff = a.wrapping_sub(b);
    try testing.expectEqual(@as(u64, 20), diff.limbs[0]);

    // Checked subtraction - no underflow
    const checked = a.checked_sub(b);
    try testing.expect(checked != null);
    try testing.expectEqual(@as(u64, 20), checked.?.limbs[0]);

    // Underflow
    const underflow_result = b.overflowing_sub(a);
    try testing.expect(underflow_result.overflow);

    // Checked subtraction - underflow
    const checked_underflow = b.checked_sub(a);
    try testing.expect(checked_underflow == null);

    // Wrapping subtraction with underflow
    const zero = U64.ZERO;
    const one = U64.ONE;
    const wrapped = zero.wrapping_sub(one);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), wrapped.limbs[0]);

    // U128 multi-limb subtraction
    const U128 = Uint(128, 2);
    const c = U128.from_limbs(.{ 0, 1 });
    const d = U128.from_limbs(.{ 1, 0 });
    const diff2 = c.wrapping_sub(d);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), diff2.limbs[0]);
    try testing.expectEqual(@as(u64, 0), diff2.limbs[1]);
}

test "Uint negation operations" {
    const U64 = Uint(64, 1);

    // Negate zero
    const zero_neg = U64.ZERO.overflowing_neg();
    try testing.expect(!zero_neg.overflow);
    try testing.expectEqual(@as(u64, 0), zero_neg.result.limbs[0]);

    // Negate one
    const one_neg = U64.ONE.overflowing_neg();
    try testing.expect(one_neg.overflow);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), one_neg.result.limbs[0]);

    // Checked negation
    const checked_zero = U64.ZERO.checked_neg();
    try testing.expect(checked_zero != null);
    try testing.expectEqual(@as(u64, 0), checked_zero.?.limbs[0]);

    const checked_one = U64.ONE.checked_neg();
    try testing.expect(checked_one == null);

    // Wrapping negation
    const a = U64.from_u64(42);
    const neg_a = a.wrapping_neg();
    const back = neg_a.wrapping_neg();
    try testing.expectEqual(@as(u64, 42), back.limbs[0]);
}

test "Uint abs_diff" {
    const U64 = Uint(64, 1);

    const a = U64.from_u64(30);
    const b = U64.from_u64(10);

    const diff1 = a.abs_diff(b);
    try testing.expectEqual(@as(u64, 20), diff1.limbs[0]);

    const diff2 = b.abs_diff(a);
    try testing.expectEqual(@as(u64, 20), diff2.limbs[0]);

    const diff3 = a.abs_diff(a);
    try testing.expectEqual(@as(u64, 0), diff3.limbs[0]);
}

test "Uint comparison lt" {
    const U64 = Uint(64, 1);

    const a = U64.from_u64(10);
    const b = U64.from_u64(20);

    try testing.expect(a.lt(b));
    try testing.expect(!b.lt(a));
    try testing.expect(!a.lt(a));

    const U128 = Uint(128, 2);
    const c = U128.from_limbs(.{ 0, 1 });
    const d = U128.from_limbs(.{ std.math.maxInt(u64), 0 });

    try testing.expect(d.lt(c));
    try testing.expect(!c.lt(d));

    const e = U128.from_limbs(.{ 100, 1 });
    const f = U128.from_limbs(.{ 200, 1 });

    try testing.expect(e.lt(f));
    try testing.expect(!f.lt(e));
}

test "Uint multiplication operations" {
    const U64 = Uint(64, 1);

    // Basic multiplication
    const a = U64.from_u64(10);
    const b = U64.from_u64(20);
    const product = a.wrapping_mul(b);
    try testing.expectEqual(@as(u64, 200), product.limbs[0]);

    // Checked multiplication - no overflow
    const checked = a.checked_mul(b);
    try testing.expect(checked != null);
    try testing.expectEqual(@as(u64, 200), checked.?.limbs[0]);

    // Multiplication by zero
    const zero_result = a.wrapping_mul(U64.ZERO);
    try testing.expect(zero_result.is_zero());

    // Multiplication by one
    const one_result = a.wrapping_mul(U64.ONE);
    try testing.expectEqual(@as(u64, 10), one_result.limbs[0]);

    // Overflowing multiplication
    const large = U64.from_u64(std.math.maxInt(u64) / 2 + 1);
    const overflow_result = large.overflowing_mul(U64.from_u64(2));
    try testing.expect(overflow_result.overflow);
    try testing.expectEqual(@as(u64, 2), overflow_result.result.limbs[0]);

    // Saturating multiplication
    const saturated = large.saturating_mul(U64.from_u64(3));
    try testing.expectEqual(U64.MAX.limbs[0], saturated.limbs[0]);

    // Single limb multiplication
    const single_result = U64.from_u64(100).mul_single(50);
    try testing.expectEqual(@as(u64, 5000), single_result.result.limbs[0]);
    try testing.expectEqual(@as(u64, 0), single_result.carry);

    // Single limb multiplication with carry
    const max_single = U64.MAX.mul_single(2);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64) - 1), max_single.result.limbs[0]);
    try testing.expectEqual(@as(u64, 1), max_single.carry);
}

test "Uint multi-limb multiplication" {
    const U128 = Uint(128, 2);

    // Basic multi-limb multiplication
    const a = U128.from_limbs(.{ 100, 0 });
    const b = U128.from_limbs(.{ 200, 0 });
    const product = a.wrapping_mul(b);
    try testing.expectEqual(@as(u64, 20000), product.limbs[0]);
    try testing.expectEqual(@as(u64, 0), product.limbs[1]);

    // Cross-limb multiplication
    const c = U128.from_limbs(.{ std.math.maxInt(u64), 0 });
    const d = U128.from_limbs(.{ 2, 0 });
    const cross_product = c.wrapping_mul(d);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64) - 1), cross_product.limbs[0]);
    try testing.expectEqual(@as(u64, 1), cross_product.limbs[1]);

    // Multiplication that fills all limbs
    const e = U128.from_limbs(.{ std.math.maxInt(u64), 0 });
    const f = U128.from_limbs(.{ std.math.maxInt(u64), 0 });
    const full_product = e.wrapping_mul(f);
    try testing.expectEqual(@as(u64, 1), full_product.limbs[0]);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64) - 1), full_product.limbs[1]);

    // Overflow detection in multi-limb
    const g = U128.from_limbs(.{ 0, std.math.maxInt(u64) });
    const h = U128.from_limbs(.{ 2, 0 });
    const overflow_result = g.overflowing_mul(h);
    try testing.expect(overflow_result.overflow);

    const U256 = Uint(256, 4);

    // 256-bit multiplication
    const i = U256.from_limbs(.{ 1000, 0, 0, 0 });
    const j = U256.from_limbs(.{ 2000, 0, 0, 0 });
    const product256 = i.wrapping_mul(j);
    try testing.expectEqual(@as(u64, 2000000), product256.limbs[0]);
    for (1..4) |idx| {
        try testing.expectEqual(@as(u64, 0), product256.limbs[idx]);
    }
}

test "Uint multiplication edge cases" {
    const U64 = Uint(64, 1);

    // MAX * 0 = 0
    const max_zero = U64.MAX.wrapping_mul(U64.ZERO);
    try testing.expect(max_zero.is_zero());

    // MAX * 1 = MAX
    const max_one = U64.MAX.wrapping_mul(U64.ONE);
    try testing.expect(max_one.eq(U64.MAX));

    // Commutative property
    const a = U64.from_u64(12345);
    const b = U64.from_u64(67890);
    const ab = a.wrapping_mul(b);
    const ba = b.wrapping_mul(a);
    try testing.expect(ab.eq(ba));

    // Associative property
    const c = U64.from_u64(7);
    const abc = a.wrapping_mul(b).wrapping_mul(c);
    const bca = b.wrapping_mul(c).wrapping_mul(a);
    try testing.expect(abc.eq(bca));

    // Non-limb-aligned multiplication
    const U65 = Uint(65, 2);
    const x = U65.from_limbs(.{ std.math.maxInt(u64), 0 });
    const y = U65.from_limbs(.{ 2, 0 });
    const xy = x.overflowing_mul(y);
    try testing.expect(!xy.overflow); // Should not overflow within 65 bits
    try testing.expectEqual(@as(u64, std.math.maxInt(u64) - 1), xy.result.limbs[0]);
    try testing.expectEqual(@as(u64, 1), xy.result.limbs[1]);
}

test "Uint division operations" {
    const U64 = Uint(64, 1);

    // Basic division
    const a = U64.from_u64(100);
    const b = U64.from_u64(10);
    const div_result = a.wrapping_div(b);
    try testing.expectEqual(@as(u64, 10), div_result.limbs[0]);

    // Basic remainder
    const rem_result = a.wrapping_rem(b);
    try testing.expectEqual(@as(u64, 0), rem_result.limbs[0]);

    // Division with remainder
    const c = U64.from_u64(103);
    const div_rem_result = c.div_rem(b);
    try testing.expectEqual(@as(u64, 10), div_rem_result.quotient.limbs[0]);
    try testing.expectEqual(@as(u64, 3), div_rem_result.remainder.limbs[0]);

    // Division by larger number
    const d = U64.from_u64(5);
    const e = U64.from_u64(10);
    const small_div = d.div_rem(e);
    try testing.expectEqual(@as(u64, 0), small_div.quotient.limbs[0]);
    try testing.expectEqual(@as(u64, 5), small_div.remainder.limbs[0]);

    // Checked division
    const checked_div = a.checked_div(b);
    try testing.expect(checked_div != null);
    try testing.expectEqual(@as(u64, 10), checked_div.?.limbs[0]);

    // Checked division by zero
    const div_by_zero = a.checked_div(U64.ZERO);
    try testing.expect(div_by_zero == null);

    // Checked remainder
    const checked_rem = c.checked_rem(b);
    try testing.expect(checked_rem != null);
    try testing.expectEqual(@as(u64, 3), checked_rem.?.limbs[0]);

    // Div ceil
    const ceil_result = c.div_ceil(b);
    try testing.expectEqual(@as(u64, 11), ceil_result.limbs[0]);

    const exact_ceil = a.div_ceil(b);
    try testing.expectEqual(@as(u64, 10), exact_ceil.limbs[0]);
}

test "Uint multi-limb division" {
    const U128 = Uint(128, 2);

    // Basic multi-limb division
    const a = U128.from_limbs(.{ 0, 1 }); // 2^64
    const b = U128.from_limbs(.{ 2, 0 });
    const div_result = a.wrapping_div(b);
    try testing.expectEqual(@as(u64, 0), div_result.limbs[0]);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64) / 2 + 1), div_result.limbs[1]);

    // Division with remainder
    const c = U128.from_limbs(.{ 100, 0 });
    const d = U128.from_limbs(.{ 7, 0 });
    const div_rem = c.div_rem(d);
    try testing.expectEqual(@as(u64, 14), div_rem.quotient.limbs[0]);
    try testing.expectEqual(@as(u64, 0), div_rem.quotient.limbs[1]);
    try testing.expectEqual(@as(u64, 2), div_rem.remainder.limbs[0]);
    try testing.expectEqual(@as(u64, 0), div_rem.remainder.limbs[1]);

    // Large number division
    const e = U128.from_limbs(.{ 0, 1000 });
    const f = U128.from_limbs(.{ 0, 10 });
    const large_div = e.wrapping_div(f);
    try testing.expectEqual(@as(u64, 0), large_div.limbs[0]);
    try testing.expectEqual(@as(u64, 100), large_div.limbs[1]);
}

test "Uint shift operations" {
    const U64 = Uint(64, 1);

    // Left shift
    const a = U64.from_u64(1);
    const shl_1 = a.wrapping_shl(1);
    try testing.expectEqual(@as(u64, 2), shl_1.limbs[0]);

    const shl_10 = a.wrapping_shl(10);
    try testing.expectEqual(@as(u64, 1024), shl_10.limbs[0]);

    // Right shift
    const b = U64.from_u64(1024);
    const shr_1 = b.wrapping_shr(1);
    try testing.expectEqual(@as(u64, 512), shr_1.limbs[0]);

    const shr_10 = b.wrapping_shr(10);
    try testing.expectEqual(@as(u64, 1), shr_10.limbs[0]);

    // Shift by zero
    const no_shift = a.wrapping_shl(0);
    try testing.expectEqual(@as(u64, 1), no_shift.limbs[0]);

    // Shift overflow
    const overflow_shl = a.wrapping_shl(64);
    try testing.expectEqual(@as(u64, 0), overflow_shl.limbs[0]);

    // Bit operations
    const c = U64.ZERO;
    const set_bit_5 = c.set_bit(5, true);
    try testing.expectEqual(@as(u64, 32), set_bit_5.limbs[0]);
    try testing.expect(set_bit_5.get_bit(5));
    try testing.expect(!set_bit_5.get_bit(4));

    const clear_bit = set_bit_5.set_bit(5, false);
    try testing.expectEqual(@as(u64, 0), clear_bit.limbs[0]);
}

test "Uint multi-limb shift operations" {
    const U128 = Uint(128, 2);

    // Shift across limb boundary
    const a = U128.from_limbs(.{ std.math.maxInt(u64), 0 });
    const shl_1 = a.wrapping_shl(1);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64) - 1), shl_1.limbs[0]);
    try testing.expectEqual(@as(u64, 1), shl_1.limbs[1]);

    // Large shift
    const b = U128.from_limbs(.{ 1, 0 });
    const shl_64 = b.wrapping_shl(64);
    try testing.expectEqual(@as(u64, 0), shl_64.limbs[0]);
    try testing.expectEqual(@as(u64, 1), shl_64.limbs[1]);

    // Right shift across limb boundary
    const c = U128.from_limbs(.{ 0, 1 });
    const shr_1 = c.wrapping_shr(1);
    try testing.expectEqual(@as(u64, 1 << 63), shr_1.limbs[0]);
    try testing.expectEqual(@as(u64, 0), shr_1.limbs[1]);

    const shr_64 = c.wrapping_shr(64);
    try testing.expectEqual(@as(u64, 1), shr_64.limbs[0]);
    try testing.expectEqual(@as(u64, 0), shr_64.limbs[1]);
}

test "Uint bitwise operations" {
    const U64 = Uint(64, 1);

    // AND operation
    const a = U64.from_u64(0b1010101010101010);
    const b = U64.from_u64(0b1100110011001100);
    const and_result = a.bit_and(b);
    try testing.expectEqual(@as(u64, 0b1000100010001000), and_result.limbs[0]);

    // OR operation
    const or_result = a.bit_or(b);
    try testing.expectEqual(@as(u64, 0b1110111011101110), or_result.limbs[0]);

    // XOR operation
    const xor_result = a.bit_xor(b);
    try testing.expectEqual(@as(u64, 0b0110011001100110), xor_result.limbs[0]);

    // NOT operation
    const not_result = a.bit_not();
    try testing.expectEqual(@as(u64, ~@as(u64, 0b1010101010101010)), not_result.limbs[0]);

    // Count ones
    const c = U64.from_u64(0b1111000011110000);
    try testing.expectEqual(@as(u32, 8), c.count_ones());

    // Count zeros
    try testing.expectEqual(@as(u32, 56), c.count_zeros());

    // Leading zeros
    const d = U64.from_u64(0x00FF000000000000);
    try testing.expectEqual(@as(u32, 8), d.leading_zeros());

    // Trailing zeros
    const e = U64.from_u64(0x0000000000FF0000);
    try testing.expectEqual(@as(u32, 16), e.trailing_zeros());

    // Leading ones
    const f = U64.from_u64(0xFF00000000000000);
    try testing.expectEqual(@as(u32, 8), f.leading_ones());

    // Trailing ones
    const g = U64.from_u64(0x00000000000000FF);
    try testing.expectEqual(@as(u32, 8), g.trailing_ones());
}

test "Uint byte operations" {
    const U64 = Uint(64, 1);

    // Get byte
    const a = U64.from_u64(0x123456789ABCDEF0);
    try testing.expectEqual(@as(u8, 0xF0), a.byte(0));
    try testing.expectEqual(@as(u8, 0xDE), a.byte(1));
    try testing.expectEqual(@as(u8, 0xBC), a.byte(2));
    try testing.expectEqual(@as(u8, 0x9A), a.byte(3));
    try testing.expectEqual(@as(u8, 0x78), a.byte(4));
    try testing.expectEqual(@as(u8, 0x56), a.byte(5));
    try testing.expectEqual(@as(u8, 0x34), a.byte(6));
    try testing.expectEqual(@as(u8, 0x12), a.byte(7));

    // Set byte
    const b = U64.ZERO;
    const set_byte_0 = b.set_byte(0, 0xFF);
    try testing.expectEqual(@as(u64, 0xFF), set_byte_0.limbs[0]);

    const set_byte_3 = b.set_byte(3, 0xAB);
    try testing.expectEqual(@as(u64, 0xAB000000), set_byte_3.limbs[0]);

    // Swap bytes
    const c = U64.from_u64(0x0123456789ABCDEF);
    const swapped = c.swap_bytes();
    try testing.expectEqual(@as(u64, 0xEFCDAB8967452301), swapped.limbs[0]);
}

test "Uint rotate operations" {
    const U64 = Uint(64, 1);

    // Rotate left
    const a = U64.from_u64(0x8000000000000001);
    const rot_left_1 = a.rotate_left(1);
    try testing.expectEqual(@as(u64, 0x0000000000000003), rot_left_1.limbs[0]);

    const rot_left_4 = a.rotate_left(4);
    try testing.expectEqual(@as(u64, 0x0000000000000018), rot_left_4.limbs[0]);

    // Rotate right
    const rot_right_1 = a.rotate_right(1);
    try testing.expectEqual(@as(u64, 0xC000000000000000), rot_right_1.limbs[0]);

    const rot_right_4 = a.rotate_right(4);
    try testing.expectEqual(@as(u64, 0x1800000000000000), rot_right_4.limbs[0]);

    // Rotate by 0
    const no_rotate = a.rotate_left(0);
    try testing.expectEqual(a.limbs[0], no_rotate.limbs[0]);

    // Rotate by bit size
    const full_rotate = a.rotate_left(64);
    try testing.expectEqual(a.limbs[0], full_rotate.limbs[0]);
}

test "Uint multi-limb bitwise operations" {
    const U128 = Uint(128, 2);

    // Multi-limb AND
    const a = U128.from_limbs(.{ 0xFFFF0000FFFF0000, 0x0000FFFF0000FFFF });
    const b = U128.from_limbs(.{ 0xFFFFFFFF00000000, 0xFFFFFFFF00000000 });
    const and_result = a.bit_and(b);
    try testing.expectEqual(@as(u64, 0xFFFF000000000000), and_result.limbs[0]);
    try testing.expectEqual(@as(u64, 0x0000FFFF00000000), and_result.limbs[1]);

    // Multi-limb NOT
    const c = U128.from_limbs(.{ 0x0F0F0F0F0F0F0F0F, 0xF0F0F0F0F0F0F0F0 });
    const not_result = c.bit_not();
    try testing.expectEqual(@as(u64, 0xF0F0F0F0F0F0F0F0), not_result.limbs[0]);
    try testing.expectEqual(@as(u64, 0x0F0F0F0F0F0F0F0F), not_result.limbs[1]);

    // Count operations across limbs
    const d = U128.from_limbs(.{ std.math.maxInt(u64), 0 });
    try testing.expectEqual(@as(u32, 64), d.count_ones());
    try testing.expectEqual(@as(u32, 64), d.count_zeros());
    try testing.expectEqual(@as(u32, 64), d.leading_zeros());
    try testing.expectEqual(@as(u32, 0), d.trailing_zeros());
}

test "Uint bit manipulation edge cases" {
    const U65 = Uint(65, 2);

    // Masking in non-limb-aligned sizes
    const a = U65.from_limbs(.{ std.math.maxInt(u64), std.math.maxInt(u64) });
    try testing.expectEqual(@as(u64, 1), a.limbs[1]); // Should be masked to 1 bit

    const not_a = a.bit_not();
    try testing.expectEqual(@as(u64, 0), not_a.limbs[0]);
    try testing.expectEqual(@as(u64, 0), not_a.limbs[1]);

    // Leading zeros in non-aligned size
    const b = U65.from_limbs(.{ 0, 1 });
    try testing.expectEqual(@as(u32, 0), b.leading_zeros());

    const c = U65.from_limbs(.{ std.math.maxInt(u64), 0 });
    try testing.expectEqual(@as(u32, 1), c.leading_zeros());
}

test "pow operations" {
    const U64 = Uint(64, 1);

    // Basic powers
    var n = U64.from_u64(2);
    try testing.expectEqual(U64.from_u64(1), n.pow(0));
    try testing.expectEqual(U64.from_u64(2), n.pow(1));
    try testing.expectEqual(U64.from_u64(4), n.pow(2));
    try testing.expectEqual(U64.from_u64(8), n.pow(3));
    try testing.expectEqual(U64.from_u64(16), n.pow(4));

    // Powers of zero
    n = U64.ZERO;
    try testing.expectEqual(U64.ONE, n.pow(0));
    try testing.expectEqual(U64.ZERO, n.pow(1));
    try testing.expectEqual(U64.ZERO, n.pow(10));

    // Powers of one
    n = U64.ONE;
    try testing.expectEqual(U64.ONE, n.pow(0));
    try testing.expectEqual(U64.ONE, n.pow(1));
    try testing.expectEqual(U64.ONE, n.pow(100));

    // Overflowing powers
    n = U64.from_u64(10);
    const overflow_result = n.overflowing_pow(20);
    try testing.expect(overflow_result.overflow);

    // Checked powers
    const checked_ok = n.checked_pow(2);
    try testing.expect(checked_ok != null);
    try testing.expectEqual(U64.from_u64(100), checked_ok.?);

    const checked_overflow = n.checked_pow(20);
    try testing.expect(checked_overflow == null);

    // Saturating powers
    const saturated = n.saturating_pow(20);
    try testing.expectEqual(U64.MAX, saturated);
}

test "sqrt operations" {
    const U64 = Uint(64, 1);
    const U256 = Uint(256, 4);

    // Perfect squares
    var n = U64.from_u64(0);
    try testing.expectEqual(U64.from_u64(0), n.sqrt());

    n = U64.from_u64(1);
    try testing.expectEqual(U64.from_u64(1), n.sqrt());

    n = U64.from_u64(4);
    try testing.expectEqual(U64.from_u64(2), n.sqrt());

    n = U64.from_u64(9);
    try testing.expectEqual(U64.from_u64(3), n.sqrt());

    n = U64.from_u64(16);
    try testing.expectEqual(U64.from_u64(4), n.sqrt());

    n = U64.from_u64(25);
    try testing.expectEqual(U64.from_u64(5), n.sqrt());

    // Non-perfect squares
    n = U64.from_u64(2);
    try testing.expectEqual(U64.from_u64(1), n.sqrt());

    n = U64.from_u64(3);
    try testing.expectEqual(U64.from_u64(1), n.sqrt());

    n = U64.from_u64(5);
    try testing.expectEqual(U64.from_u64(2), n.sqrt());

    n = U64.from_u64(8);
    try testing.expectEqual(U64.from_u64(2), n.sqrt());

    n = U64.from_u64(10);
    try testing.expectEqual(U64.from_u64(3), n.sqrt());

    n = U64.from_u64(27);
    try testing.expectEqual(U64.from_u64(5), n.sqrt());

    // Large numbers
    n = U64.from_u64(256);
    try testing.expectEqual(U64.from_u64(16), n.sqrt());

    n = U64.from_u64(65536);
    try testing.expectEqual(U64.from_u64(256), n.sqrt());

    // Multi-limb sqrt
    var big = U256.from_u64(16);
    try testing.expectEqual(U256.from_u64(4), big.sqrt());

    big = U256.from_u64(25);
    try testing.expectEqual(U256.from_u64(5), big.sqrt());

    big = U256.from_u64(256);
    try testing.expectEqual(U256.from_u64(16), big.sqrt());
}

test "is_power_of_two and next_power_of_two" {
    const U64 = Uint(64, 1);

    // is_power_of_two
    try testing.expect(!U64.ZERO.is_power_of_two());
    try testing.expect(U64.ONE.is_power_of_two());
    try testing.expect(U64.from_u64(2).is_power_of_two());
    try testing.expect(!U64.from_u64(3).is_power_of_two());
    try testing.expect(U64.from_u64(4).is_power_of_two());
    try testing.expect(!U64.from_u64(5).is_power_of_two());
    try testing.expect(U64.from_u64(8).is_power_of_two());
    try testing.expect(U64.from_u64(16).is_power_of_two());
    try testing.expect(U64.from_u64(32).is_power_of_two());
    try testing.expect(!U64.from_u64(33).is_power_of_two());
    try testing.expect(U64.from_u64(1 << 32).is_power_of_two());

    // next_power_of_two
    const zero_next = U64.ZERO.next_power_of_two();
    try testing.expect(zero_next != null);
    try testing.expectEqual(U64.ONE, zero_next.?);

    const one_next = U64.ONE.next_power_of_two();
    try testing.expect(one_next != null);
    try testing.expectEqual(U64.ONE, one_next.?);

    const two_next = U64.from_u64(2).next_power_of_two();
    try testing.expect(two_next != null);
    try testing.expectEqual(U64.from_u64(2), two_next.?);

    const three_next = U64.from_u64(3).next_power_of_two();
    try testing.expect(three_next != null);
    try testing.expectEqual(U64.from_u64(4), three_next.?);

    const five_next = U64.from_u64(5).next_power_of_two();
    try testing.expect(five_next != null);
    try testing.expectEqual(U64.from_u64(8), five_next.?);

    const large = U64.from_u64((1 << 32) + 1);
    const large_next = large.next_power_of_two();
    try testing.expect(large_next != null);
    try testing.expectEqual(U64.from_u64(1 << 33), large_next.?);

    // Overflow case
    const big = U64.from_u64((1 << 63) + 1);
    const big_next = big.next_power_of_two();
    try testing.expect(big_next == null);
}

test "string parsing from_str_radix" {
    const U64 = Uint(64, 1);
    const U128 = Uint(128, 2);

    // Decimal parsing
    const dec1 = try U64.from_str_radix("123", 10);
    try testing.expectEqual(U64.from_u64(123), dec1);

    const dec2 = try U64.from_str_radix("0", 10);
    try testing.expectEqual(U64.ZERO, dec2);

    const dec3 = try U128.from_str_radix("12345678901234567890", 10);
    const expected = U128.from_limbs(.{ 0xAB54A98CEB1F0AD2, 0xAB });
    try testing.expect(dec3.eq(expected));

    // Binary parsing
    const bin1 = try U64.from_str_radix("1111", 2);
    try testing.expectEqual(U64.from_u64(15), bin1);

    const bin2 = try U64.from_str_radix("10101010", 2);
    try testing.expectEqual(U64.from_u64(170), bin2);

    // Hexadecimal parsing
    const hex1 = try U64.from_str_radix("FF", 16);
    try testing.expectEqual(U64.from_u64(255), hex1);

    const hex2 = try U64.from_str_radix("abc", 16);
    try testing.expectEqual(U64.from_u64(2748), hex2);

    const hex3 = try U64.from_str_radix("ABC", 16);
    try testing.expectEqual(U64.from_u64(2748), hex3);

    // Octal parsing
    const oct1 = try U64.from_str_radix("777", 8);
    try testing.expectEqual(U64.from_u64(511), oct1);

    // With underscores
    const with_underscore = try U64.from_str_radix("1_234_567", 10);
    try testing.expectEqual(U64.from_u64(1234567), with_underscore);

    // Error cases
    try testing.expectError(error.InvalidRadix, U64.from_str_radix("123", 1));
    try testing.expectError(error.InvalidRadix, U64.from_str_radix("123", 65));
    try testing.expectError(error.InvalidDigit, U64.from_str_radix("xyz", 10));
    try testing.expectError(error.InvalidDigit, U64.from_str_radix("123g", 16));
    try testing.expectError(error.Overflow, U64.from_str_radix("99999999999999999999999999999", 10));
}

test "string parsing from_str" {
    const U64 = Uint(64, 1);

    // Decimal (default)
    const dec1 = try U64.from_str("123");
    try testing.expectEqual(U64.from_u64(123), dec1);

    // Binary prefix
    const bin1 = try U64.from_str("0b1111");
    try testing.expectEqual(U64.from_u64(15), bin1);

    const bin2 = try U64.from_str("0B10101010");
    try testing.expectEqual(U64.from_u64(170), bin2);

    // Octal prefix
    const oct1 = try U64.from_str("0o777");
    try testing.expectEqual(U64.from_u64(511), oct1);

    const oct2 = try U64.from_str("0O123");
    try testing.expectEqual(U64.from_u64(83), oct2);

    // Hexadecimal prefix
    const hex1 = try U64.from_str("0xFF");
    try testing.expectEqual(U64.from_u64(255), hex1);

    const hex2 = try U64.from_str("0xabc");
    try testing.expectEqual(U64.from_u64(2748), hex2);

    const hex3 = try U64.from_str("0XABC");
    try testing.expectEqual(U64.from_u64(2748), hex3);
}

test "string formatting to_string_radix" {
    const allocator = testing.allocator;
    const U64 = Uint(64, 1);
    const U128 = Uint(128, 2);

    // Decimal
    const dec1 = try U64.from_u64(123).to_string_radix(allocator, 10);
    defer allocator.free(dec1);
    try testing.expectEqualStrings("123", dec1);

    const dec2 = try U64.ZERO.to_string_radix(allocator, 10);
    defer allocator.free(dec2);
    try testing.expectEqualStrings("0", dec2);

    // Binary
    const bin1 = try U64.from_u64(15).to_string_radix(allocator, 2);
    defer allocator.free(bin1);
    try testing.expectEqualStrings("1111", bin1);

    // Hexadecimal
    const hex1 = try U64.from_u64(255).to_string_radix(allocator, 16);
    defer allocator.free(hex1);
    try testing.expectEqualStrings("ff", hex1);

    const hex2 = try U64.from_u64(2748).to_string_radix(allocator, 16);
    defer allocator.free(hex2);
    try testing.expectEqualStrings("abc", hex2);

    // Octal
    const oct1 = try U64.from_u64(511).to_string_radix(allocator, 8);
    defer allocator.free(oct1);
    try testing.expectEqualStrings("777", oct1);

    // Large number
    const large = U128.from_limbs(.{ 0xAB54A98CEB1F0AD2, 0xAB });
    const large_str = try large.to_string_radix(allocator, 10);
    defer allocator.free(large_str);
    try testing.expectEqualStrings("12345678901234567890", large_str);
}

test "formatting with format()" {
    const U64 = Uint(64, 1);
    const U128 = Uint(128, 2);

    // Decimal formatting
    const dec1 = U64.from_u64(123);
    var buf: [100]u8 = undefined;
    const result1 = try std.fmt.bufPrint(&buf, "{}", .{dec1});
    try testing.expectEqualStrings("123", result1);

    const dec2 = U64.ZERO;
    const result2 = try std.fmt.bufPrint(&buf, "{}", .{dec2});
    try testing.expectEqualStrings("0", result2);

    // Binary formatting
    const bin1 = U64.from_u64(15);
    const result3 = try std.fmt.bufPrint(&buf, "{b}", .{bin1});
    try testing.expectEqualStrings("0b1111", result3);

    // Octal formatting
    const oct1 = U64.from_u64(511);
    const result4 = try std.fmt.bufPrint(&buf, "{o}", .{oct1});
    try testing.expectEqualStrings("0o777", result4);

    // Hexadecimal formatting (lowercase)
    const hex1 = U64.from_u64(255);
    const result5 = try std.fmt.bufPrint(&buf, "{x}", .{hex1});
    try testing.expectEqualStrings("0xff", result5);

    // Hexadecimal formatting (uppercase)
    const hex2 = U64.from_u64(2748);
    const result6 = try std.fmt.bufPrint(&buf, "{X}", .{hex2});
    try testing.expectEqualStrings("0xABC", result6);

    // Large number formatting
    const large = U128.from_limbs(.{ 0x123456789ABCDEF0, 0xFEDCBA9876543210 });
    const result7 = try std.fmt.bufPrint(&buf, "{x}", .{large});
    try testing.expectEqualStrings("0xfedcba9876543210123456789abcdef0", result7);
}

test "round-trip string conversion" {
    const allocator = testing.allocator;
    const U64 = Uint(64, 1);
    const U128 = Uint(128, 2);

    // Test various numbers with round-trip conversion
    const test_cases = [_]u64{
        0,
        1,
        10,
        123,
        1234,
        12345,
        123456,
        1234567,
        12345678,
        123456789,
        1234567890,
        std.math.maxInt(u32),
        std.math.maxInt(u64),
    };

    for (test_cases) |val| {
        const n = U64.from_u64(val);

        // Test each radix
        const radices = [_]u64{ 2, 8, 10, 16 };
        for (radices) |radix| {
            const str = try n.to_string_radix(allocator, radix);
            defer allocator.free(str);

            const parsed = try U64.from_str_radix(str, radix);
            try testing.expect(n.eq(parsed));
        }
    }

    // Test large multi-limb number
    const large = U128.from_limbs(.{ 0x123456789ABCDEF0, 0xFEDCBA9876543210 });
    const large_str = try large.to_string_radix(allocator, 16);
    defer allocator.free(large_str);

    const large_parsed = try U128.from_str_radix(large_str, 16);
    try testing.expect(large.eq(large_parsed));
}

test "byte conversion to_le_bytes and from_le_bytes" {
    const U64 = Uint(64, 1);
    const U128 = Uint(128, 2);
    const U256 = Uint(256, 4);

    // U64 tests
    const val64 = U64.from_u64(0x0123456789ABCDEF);
    var bytes64: [8]u8 = undefined;
    val64.to_le_bytes(&bytes64);
    try testing.expectEqual(@as(u8, 0xEF), bytes64[0]);
    try testing.expectEqual(@as(u8, 0xCD), bytes64[1]);
    try testing.expectEqual(@as(u8, 0xAB), bytes64[2]);
    try testing.expectEqual(@as(u8, 0x89), bytes64[3]);
    try testing.expectEqual(@as(u8, 0x67), bytes64[4]);
    try testing.expectEqual(@as(u8, 0x45), bytes64[5]);
    try testing.expectEqual(@as(u8, 0x23), bytes64[6]);
    try testing.expectEqual(@as(u8, 0x01), bytes64[7]);

    const recovered64 = U64.from_le_bytes(&bytes64);
    try testing.expect(val64.eq(recovered64));

    // U128 tests
    const val128 = U128.from_limbs(.{ 0x0123456789ABCDEF, 0xFEDCBA9876543210 });
    var bytes128: [16]u8 = undefined;
    val128.to_le_bytes(&bytes128);

    const recovered128 = U128.from_le_bytes(&bytes128);
    try testing.expect(val128.eq(recovered128));

    // U256 tests with partial bytes
    const val256 = U256.from_limbs(.{
        0x0123456789ABCDEF,
        0xFEDCBA9876543210,
        0x123456789ABCDEF0,
        0xFEDCBA9876543210,
    });
    var bytes256: [32]u8 = undefined;
    val256.to_le_bytes(&bytes256);

    const recovered256 = U256.from_le_bytes(&bytes256);
    try testing.expect(val256.eq(recovered256));

    // Test with smaller buffer
    var small_bytes: [5]u8 = undefined;
    val64.to_le_bytes(&small_bytes);
    try testing.expectEqual(@as(u8, 0xEF), small_bytes[0]);
    try testing.expectEqual(@as(u8, 0xCD), small_bytes[1]);
    try testing.expectEqual(@as(u8, 0xAB), small_bytes[2]);
    try testing.expectEqual(@as(u8, 0x89), small_bytes[3]);
    try testing.expectEqual(@as(u8, 0x67), small_bytes[4]);
}

test "byte conversion to_be_bytes and from_be_bytes" {
    const U64 = Uint(64, 1);
    const U128 = Uint(128, 2);
    const U256 = Uint(256, 4);

    // U64 tests
    const val64 = U64.from_u64(0x0123456789ABCDEF);
    var bytes64: [8]u8 = undefined;
    val64.to_be_bytes(&bytes64);
    try testing.expectEqual(@as(u8, 0x01), bytes64[0]);
    try testing.expectEqual(@as(u8, 0x23), bytes64[1]);
    try testing.expectEqual(@as(u8, 0x45), bytes64[2]);
    try testing.expectEqual(@as(u8, 0x67), bytes64[3]);
    try testing.expectEqual(@as(u8, 0x89), bytes64[4]);
    try testing.expectEqual(@as(u8, 0xAB), bytes64[5]);
    try testing.expectEqual(@as(u8, 0xCD), bytes64[6]);
    try testing.expectEqual(@as(u8, 0xEF), bytes64[7]);

    const recovered64 = U64.from_be_bytes(&bytes64);
    try testing.expect(val64.eq(recovered64));

    // U128 tests
    const val128 = U128.from_limbs(.{ 0x0123456789ABCDEF, 0xFEDCBA9876543210 });
    var bytes128: [16]u8 = undefined;
    val128.to_be_bytes(&bytes128);

    // Check first few bytes
    try testing.expectEqual(@as(u8, 0xFE), bytes128[0]);
    try testing.expectEqual(@as(u8, 0xDC), bytes128[1]);
    try testing.expectEqual(@as(u8, 0xBA), bytes128[2]);
    try testing.expectEqual(@as(u8, 0x98), bytes128[3]);

    const recovered128 = U128.from_be_bytes(&bytes128);
    try testing.expect(val128.eq(recovered128));

    // U256 tests
    const val256 = U256.from_limbs(.{
        0x0123456789ABCDEF,
        0xFEDCBA9876543210,
        0x123456789ABCDEF0,
        0xFEDCBA9876543210,
    });
    var bytes256: [32]u8 = undefined;
    val256.to_be_bytes(&bytes256);

    const recovered256 = U256.from_be_bytes(&bytes256);
    try testing.expect(val256.eq(recovered256));
}

test "byte conversion exact functions" {
    const U64 = Uint(64, 1);
    const U128 = Uint(128, 2);
    const U256 = Uint(256, 4);

    // U64 exact bytes
    const val64 = U64.from_u64(0x0123456789ABCDEF);
    const le_bytes64 = val64.to_le_bytes_exact();
    const be_bytes64 = val64.to_be_bytes_exact();

    try testing.expectEqual(@as(usize, 8), le_bytes64.len);
    try testing.expectEqual(@as(usize, 8), be_bytes64.len);

    try testing.expectEqual(@as(u8, 0xEF), le_bytes64[0]);
    try testing.expectEqual(@as(u8, 0x01), be_bytes64[0]);

    // U128 exact bytes
    const val128 = U128.from_limbs(.{ 0x0123456789ABCDEF, 0xFEDCBA9876543210 });
    const le_bytes128 = val128.to_le_bytes_exact();
    const be_bytes128 = val128.to_be_bytes_exact();

    try testing.expectEqual(@as(usize, 16), le_bytes128.len);
    try testing.expectEqual(@as(usize, 16), be_bytes128.len);

    // U256 exact bytes
    const val256 = U256.from_limbs(.{
        0x0123456789ABCDEF,
        0xFEDCBA9876543210,
        0x123456789ABCDEF0,
        0xFEDCBA9876543210,
    });
    const le_bytes256 = val256.to_le_bytes_exact();
    const be_bytes256 = val256.to_be_bytes_exact();

    try testing.expectEqual(@as(usize, 32), le_bytes256.len);
    try testing.expectEqual(@as(usize, 32), be_bytes256.len);
}

test "byte conversion with non-aligned sizes" {
    const U65 = Uint(65, 2);
    const U127 = Uint(127, 2);

    // U65 - 9 bytes needed
    const val65 = U65.from_limbs(.{ 0xFFFFFFFFFFFFFFFF, 0x01 });
    const le_bytes65 = val65.to_le_bytes_exact();
    const be_bytes65 = val65.to_be_bytes_exact();

    try testing.expectEqual(@as(usize, 9), le_bytes65.len);
    try testing.expectEqual(@as(usize, 9), be_bytes65.len);

    // Check LE bytes
    for (0..8) |i| {
        try testing.expectEqual(@as(u8, 0xFF), le_bytes65[i]);
    }
    try testing.expectEqual(@as(u8, 0x01), le_bytes65[8]);

    // Check BE bytes
    try testing.expectEqual(@as(u8, 0x01), be_bytes65[0]);
    for (1..9) |i| {
        try testing.expectEqual(@as(u8, 0xFF), be_bytes65[i]);
    }

    // Round trip
    const recovered_le = U65.from_le_bytes(&le_bytes65);
    const recovered_be = U65.from_be_bytes(&be_bytes65);
    try testing.expect(val65.eq(recovered_le));
    try testing.expect(val65.eq(recovered_be));

    // U127 - 16 bytes needed
    const val127 = U127.from_limbs(.{ 0xFFFFFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFFF });
    const le_bytes127 = val127.to_le_bytes_exact();
    const be_bytes127 = val127.to_be_bytes_exact();

    try testing.expectEqual(@as(usize, 16), le_bytes127.len);
    try testing.expectEqual(@as(usize, 16), be_bytes127.len);

    // Round trip
    const recovered_le127 = U127.from_le_bytes(&le_bytes127);
    const recovered_be127 = U127.from_be_bytes(&be_bytes127);
    try testing.expect(val127.eq(recovered_le127));
    try testing.expect(val127.eq(recovered_be127));
}

test "byte conversion edge cases" {
    const U64 = Uint(64, 1);

    // Zero value
    const zero = U64.ZERO;
    var zero_bytes: [8]u8 = undefined;
    zero.to_le_bytes(&zero_bytes);
    for (zero_bytes) |b| {
        try testing.expectEqual(@as(u8, 0), b);
    }

    // Max value
    const max = U64.MAX;
    var max_bytes: [8]u8 = undefined;
    max.to_le_bytes(&max_bytes);
    for (max_bytes) |b| {
        try testing.expectEqual(@as(u8, 0xFF), b);
    }

    // From empty slice
    const empty_slice: []const u8 = &.{};
    const from_empty = U64.from_le_bytes(empty_slice);
    try testing.expect(from_empty.eq(U64.ZERO));

    // From partial slice
    const partial_bytes = [_]u8{ 0x12, 0x34, 0x56 };
    const from_partial = U64.from_le_bytes(&partial_bytes);
    try testing.expectEqual(U64.from_u64(0x563412), from_partial);

    // From oversized slice - should only use what's needed
    const big_bytes = [_]u8{0xFF} ** 20;
    const from_big = U64.from_le_bytes(&big_bytes);
    try testing.expect(from_big.eq(U64.MAX));
}

test "bit_len and byte_len" {
    const U64 = Uint(64, 1);
    const U128 = Uint(128, 2);

    // Zero
    try testing.expectEqual(@as(usize, 0), U64.ZERO.bit_len());
    try testing.expectEqual(@as(usize, 0), U64.ZERO.byte_len());

    // One
    try testing.expectEqual(@as(usize, 1), U64.ONE.bit_len());
    try testing.expectEqual(@as(usize, 1), U64.ONE.byte_len());

    // Powers of 2
    try testing.expectEqual(@as(usize, 8), U64.from_u64(255).bit_len());
    try testing.expectEqual(@as(usize, 1), U64.from_u64(255).byte_len());

    try testing.expectEqual(@as(usize, 9), U64.from_u64(256).bit_len());
    try testing.expectEqual(@as(usize, 2), U64.from_u64(256).byte_len());

    try testing.expectEqual(@as(usize, 16), U64.from_u64(65535).bit_len());
    try testing.expectEqual(@as(usize, 2), U64.from_u64(65535).byte_len());

    try testing.expectEqual(@as(usize, 17), U64.from_u64(65536).bit_len());
    try testing.expectEqual(@as(usize, 3), U64.from_u64(65536).byte_len());

    // Multi-limb
    const big = U128.from_limbs(.{ 0, 1 });
    try testing.expectEqual(@as(usize, 65), big.bit_len());
    try testing.expectEqual(@as(usize, 9), big.byte_len());
}

test "log functions" {
    const U64 = Uint(64, 1);

    // log2
    try testing.expectEqual(@as(usize, 0), U64.from_u64(1).log2());
    try testing.expectEqual(@as(usize, 1), U64.from_u64(2).log2());
    try testing.expectEqual(@as(usize, 1), U64.from_u64(3).log2());
    try testing.expectEqual(@as(usize, 2), U64.from_u64(4).log2());
    try testing.expectEqual(@as(usize, 3), U64.from_u64(8).log2());
    try testing.expectEqual(@as(usize, 10), U64.from_u64(1024).log2());

    // checked_log2
    try testing.expect(U64.ZERO.checked_log2() == null);
    try testing.expectEqual(@as(?usize, 0), U64.ONE.checked_log2());

    // log10
    try testing.expectEqual(@as(usize, 0), U64.from_u64(1).log10());
    try testing.expectEqual(@as(usize, 0), U64.from_u64(9).log10());
    try testing.expectEqual(@as(usize, 1), U64.from_u64(10).log10());
    try testing.expectEqual(@as(usize, 1), U64.from_u64(99).log10());
    try testing.expectEqual(@as(usize, 2), U64.from_u64(100).log10());
    try testing.expectEqual(@as(usize, 2), U64.from_u64(999).log10());
    try testing.expectEqual(@as(usize, 3), U64.from_u64(1000).log10());

    // general log
    try testing.expectEqual(@as(usize, 0), U64.from_u64(1).log(U64.from_u64(10)));
    try testing.expectEqual(@as(usize, 1), U64.from_u64(10).log(U64.from_u64(10)));
    try testing.expectEqual(@as(usize, 2), U64.from_u64(100).log(U64.from_u64(10)));

    try testing.expectEqual(@as(usize, 2), U64.from_u64(9).log(U64.from_u64(3)));
    try testing.expectEqual(@as(usize, 3), U64.from_u64(27).log(U64.from_u64(3)));

    // checked_log
    try testing.expect(U64.ZERO.checked_log(U64.from_u64(10)) == null);
    try testing.expect(U64.from_u64(10).checked_log(U64.from_u64(1)) == null);
    try testing.expectEqual(@as(?usize, 1), U64.from_u64(10).checked_log(U64.from_u64(10)));
}

test "gcd and lcm" {
    const U64 = Uint(64, 1);

    // GCD tests
    try testing.expectEqual(U64.from_u64(0), U64.from_u64(0).gcd(U64.from_u64(0)));
    try testing.expectEqual(U64.from_u64(5), U64.from_u64(0).gcd(U64.from_u64(5)));
    try testing.expectEqual(U64.from_u64(5), U64.from_u64(5).gcd(U64.from_u64(0)));
    try testing.expectEqual(U64.from_u64(1), U64.from_u64(1).gcd(U64.from_u64(1)));

    try testing.expectEqual(U64.from_u64(6), U64.from_u64(12).gcd(U64.from_u64(18)));
    try testing.expectEqual(U64.from_u64(6), U64.from_u64(18).gcd(U64.from_u64(12)));
    try testing.expectEqual(U64.from_u64(1), U64.from_u64(13).gcd(U64.from_u64(17)));
    try testing.expectEqual(U64.from_u64(5), U64.from_u64(25).gcd(U64.from_u64(15)));
    try testing.expectEqual(U64.from_u64(21), U64.from_u64(252).gcd(U64.from_u64(105)));

    // LCM tests
    try testing.expectEqual(U64.from_u64(0), U64.from_u64(0).lcm(U64.from_u64(0)).?);
    try testing.expectEqual(U64.from_u64(0), U64.from_u64(0).lcm(U64.from_u64(5)).?);
    try testing.expectEqual(U64.from_u64(0), U64.from_u64(5).lcm(U64.from_u64(0)).?);

    try testing.expectEqual(U64.from_u64(36), U64.from_u64(12).lcm(U64.from_u64(18)).?);
    try testing.expectEqual(U64.from_u64(36), U64.from_u64(18).lcm(U64.from_u64(12)).?);
    try testing.expectEqual(U64.from_u64(221), U64.from_u64(13).lcm(U64.from_u64(17)).?);
    try testing.expectEqual(U64.from_u64(75), U64.from_u64(25).lcm(U64.from_u64(15)).?);

    // LCM overflow
    const big = U64.MAX.wrapping_div(U64.from_u64(2));
    const lcm_overflow = big.lcm(U64.from_u64(3));
    try testing.expect(lcm_overflow == null);
}

test "modular arithmetic" {
    const U64 = Uint(64, 1);

    // reduce_mod
    try testing.expectEqual(U64.from_u64(0), U64.from_u64(10).reduce_mod(U64.from_u64(0)));
    try testing.expectEqual(U64.from_u64(5), U64.from_u64(5).reduce_mod(U64.from_u64(10)));
    try testing.expectEqual(U64.from_u64(5), U64.from_u64(15).reduce_mod(U64.from_u64(10)));
    try testing.expectEqual(U64.from_u64(3), U64.from_u64(23).reduce_mod(U64.from_u64(10)));

    // add_mod
    try testing.expectEqual(U64.from_u64(0), U64.from_u64(5).add_mod(U64.from_u64(3), U64.from_u64(0)));
    try testing.expectEqual(U64.from_u64(8), U64.from_u64(5).add_mod(U64.from_u64(3), U64.from_u64(10)));
    try testing.expectEqual(U64.from_u64(2), U64.from_u64(7).add_mod(U64.from_u64(5), U64.from_u64(10)));
    try testing.expectEqual(U64.from_u64(1), U64.from_u64(9).add_mod(U64.from_u64(9), U64.from_u64(17)));

    // add_mod with overflow
    const max = U64.MAX;
    try testing.expectEqual(U64.from_u64(0), max.add_mod(U64.ONE, max));
    try testing.expectEqual(U64.from_u64(2), max.add_mod(U64.from_u64(3), max));

    // mul_mod
    try testing.expectEqual(U64.from_u64(0), U64.from_u64(5).mul_mod(U64.from_u64(3), U64.from_u64(0)));
    try testing.expectEqual(U64.from_u64(15), U64.from_u64(5).mul_mod(U64.from_u64(3), U64.from_u64(20)));
    try testing.expectEqual(U64.from_u64(5), U64.from_u64(5).mul_mod(U64.from_u64(3), U64.from_u64(10)));
    try testing.expectEqual(U64.from_u64(2), U64.from_u64(7).mul_mod(U64.from_u64(5), U64.from_u64(11)));

    // mul_mod with large values
    const big1 = U64.from_u64(0x123456789ABCDEF);
    const big2 = U64.from_u64(0xFEDCBA987654321);
    const mod = U64.from_u64(0x1000000000000);
    const result = big1.mul_mod(big2, mod);
    try testing.expect(result.lt(mod));

    // pow_mod
    try testing.expectEqual(U64.from_u64(0), U64.from_u64(2).pow_mod(U64.from_u64(10), U64.from_u64(0)));
    try testing.expectEqual(U64.from_u64(0), U64.from_u64(2).pow_mod(U64.from_u64(10), U64.from_u64(1)));
    try testing.expectEqual(U64.from_u64(1), U64.from_u64(2).pow_mod(U64.from_u64(0), U64.from_u64(10)));
    try testing.expectEqual(U64.from_u64(2), U64.from_u64(2).pow_mod(U64.from_u64(1), U64.from_u64(10)));
    try testing.expectEqual(U64.from_u64(4), U64.from_u64(2).pow_mod(U64.from_u64(2), U64.from_u64(10)));
    try testing.expectEqual(U64.from_u64(8), U64.from_u64(2).pow_mod(U64.from_u64(3), U64.from_u64(10)));
    try testing.expectEqual(U64.from_u64(4), U64.from_u64(2).pow_mod(U64.from_u64(10), U64.from_u64(10)));

    // pow_mod with larger modulus
    try testing.expectEqual(U64.from_u64(445), U64.from_u64(3).pow_mod(U64.from_u64(100), U64.from_u64(1000)));
}

test "inv_ring" {
    const U64 = Uint(64, 1);
    const U128 = Uint(128, 2);

    // Test odd numbers have inverse
    const a = U64.from_u64(5);
    const inv_a = a.inv_ring().?;
    const prod_a = a.wrapping_mul(inv_a);
    try testing.expectEqual(U64.ONE, prod_a);

    // Test even numbers have no inverse
    const b = U64.from_u64(6);
    try testing.expectEqual(@as(?U64, null), b.inv_ring());

    // Test larger number
    const c = U128.from_int(999999999999);
    const inv_c = c.inv_ring().?;
    const prod_c = c.wrapping_mul(inv_c);
    try testing.expectEqual(U128.ONE, prod_c);
}

test "widening_mul" {
    const U64 = Uint(64, 1);

    const a = U64.from_u64(0xFFFF_FFFF_FFFF_FFFF);
    const b = U64.from_u64(2);
    const result = a.widening_mul(64, 1, 128, 2, b);

    // 0xFFFF_FFFF_FFFF_FFFF * 2 = 0x1_FFFF_FFFF_FFFF_FFFE
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FFFE), result.limbs[0]);
    try testing.expectEqual(@as(u64, 1), result.limbs[1]);
}

test "root" {
    const U256 = Uint(256, 4);

    // Test square root
    const a = U256.from_int(16);
    const sqrt_a = a.root(2);
    try testing.expectEqual(@as(u64, 4), sqrt_a.to_u64().?);

    // Test cube root
    const b = U256.from_int(27);
    const cbrt_b = b.root(3);
    try testing.expectEqual(@as(u64, 3), cbrt_b.to_u64().?);

    // Test 4th root
    const c = U256.from_int(625);
    const root4_c = c.root(4);
    try testing.expectEqual(@as(u64, 5), root4_c.to_u64().?);

    // Test root of 1
    const one = U256.ONE;
    try testing.expectEqual(U256.ONE, one.root(100));

    // Test root of 0
    const zero = U256.ZERO;
    try testing.expectEqual(U256.ZERO, zero.root(5));
}

test "gcd_extended" {
    const U128 = Uint(128, 2);

    // Test GCD extended: gcd(35, 15) = 5
    // 35 = 2*15 + 5, 15 = 3*5 + 0
    // 5 = 35*1 - 15*2
    const a = U128.from_int(35);
    const b = U128.from_int(15);
    const result = a.gcd_extended(b);

    try testing.expectEqual(@as(u64, 5), result.gcd.to_u64().?);

    // Verify Bezout identity
    if (result.sign) {
        const lhs = a.mul(result.x);
        const rhs = b.mul(result.y);
        try testing.expectEqual(result.gcd, lhs.sub(rhs));
    } else {
        const lhs = b.mul(result.y);
        const rhs = a.mul(result.x);
        try testing.expectEqual(result.gcd, lhs.sub(rhs));
    }
}

test "inv_mod" {
    const U128 = Uint(128, 2);

    // Test modular inverse: 3 * 5 ≡ 1 (mod 7)
    const a = U128.from_int(3);
    const modulus = U128.from_int(7);
    const inv = a.inv_mod(modulus).?;
    try testing.expectEqual(@as(u64, 5), inv.to_u64().?);

    // Verify inverse property
    const product = a.mul_mod(inv, modulus);
    try testing.expectEqual(U128.ONE, product);

    // Test no inverse exists (gcd != 1)
    const b = U128.from_int(6);
    const mod2 = U128.from_int(9); // gcd(6, 9) = 3
    try testing.expectEqual(@as(?U128, null), b.inv_mod(mod2));
}

test "div_ceil" {
    const U64 = Uint(64, 1);

    // Test exact division
    const a = U64.from_u64(20);
    const b = U64.from_u64(5);
    try testing.expectEqual(@as(u64, 4), a.div_ceil(b).to_u64() orelse unreachable);

    // Test division with remainder
    const c = U64.from_u64(21);
    const d = U64.from_u64(5);
    try testing.expectEqual(@as(u64, 5), c.div_ceil(d).to_u64() orelse unreachable); // ceil(21/5) = 5

    const e = U64.from_u64(19);
    try testing.expectEqual(@as(u64, 4), e.div_ceil(d).to_u64() orelse unreachable); // ceil(19/5) = 4
}

test "power of two operations" {
    const U64 = Uint(64, 1);

    // Test is_power_of_two
    try testing.expect(U64.from_u64(1).is_power_of_two());
    try testing.expect(U64.from_u64(2).is_power_of_two());
    try testing.expect(U64.from_u64(4).is_power_of_two());
    try testing.expect(U64.from_u64(8).is_power_of_two());
    try testing.expect(U64.from_u64(1 << 32).is_power_of_two());
    try testing.expect(!U64.from_u64(3).is_power_of_two());
    try testing.expect(!U64.from_u64(5).is_power_of_two());
    try testing.expect(!U64.from_u64(0).is_power_of_two());

    // Test next_power_of_two
    try testing.expectEqual(@as(u64, 1), U64.from_u64(0).next_power_of_two().to_u64().?);
    try testing.expectEqual(@as(u64, 1), U64.from_u64(1).next_power_of_two().to_u64().?);
    try testing.expectEqual(@as(u64, 2), U64.from_u64(2).next_power_of_two().to_u64().?);
    try testing.expectEqual(@as(u64, 4), U64.from_u64(3).next_power_of_two().to_u64().?);
    try testing.expectEqual(@as(u64, 8), U64.from_u64(5).next_power_of_two().to_u64().?);
    try testing.expectEqual(@as(u64, 16), U64.from_u64(9).next_power_of_two().to_u64().?);
    try testing.expectEqual(@as(u64, 16), U64.from_u64(15).next_power_of_two().to_u64().?);
    try testing.expectEqual(@as(u64, 16), U64.from_u64(16).next_power_of_two().to_u64().?);

    // Test checked_next_power_of_two overflow
    const max_power = U64.ONE.shl(63);
    try testing.expect(max_power.checked_next_power_of_two() != null);
    const overflow = max_power.add(U64.ONE);
    try testing.expectEqual(@as(?U64, null), overflow.checked_next_power_of_two());
}

test "next_multiple_of" {
    const U64 = Uint(64, 1);

    // Test exact multiple
    try testing.expectEqual(@as(u64, 16), U64.from_u64(16).checked_next_multiple_of(U64.from_u64(8)).to_u64().?);

    // Test rounding up
    try testing.expectEqual(@as(u64, 24), U64.from_u64(17).checked_next_multiple_of(U64.from_u64(8)).to_u64().?);
    try testing.expectEqual(@as(u64, 24), U64.from_u64(23).checked_next_multiple_of(U64.from_u64(8)).to_u64().?);

    // Test zero
    try testing.expectEqual(@as(u64, 0), U64.ZERO.checked_next_multiple_of(U64.from_u64(5)).to_u64().?);

    // Test division by zero
    try testing.expectEqual(@as(?U64, null), U64.from_u64(10).checked_next_multiple_of(U64.ZERO));
}

test "saturating arithmetic" {
    const U8 = Uint(8, 1);

    // Test saturating_add
    const max = U8.MAX;
    const one = U8.ONE;
    try testing.expectEqual(max, max.saturating_add(one));
    try testing.expectEqual(U8.from_int(100), U8.from_int(50).saturating_add(U8.from_int(50)));

    // Test saturating_sub
    const zero = U8.ZERO;
    try testing.expectEqual(zero, zero.saturating_sub(one));
    try testing.expectEqual(U8.from_int(50), U8.from_int(100).saturating_sub(U8.from_int(50)));

    // Test saturating_mul
    const big = U8.from_int(100);
    try testing.expectEqual(max, big.saturating_mul(big));
    try testing.expectEqual(U8.from_int(50), U8.from_int(10).saturating_mul(U8.from_int(5)));
}

test "wrapping division" {
    const U64 = Uint(64, 1);

    // Test wrapping_div
    const a = U64.from_u64(20);
    const b = U64.from_u64(5);
    try testing.expectEqual(@as(u64, 4), a.wrapping_div(b).to_u64().?);

    // Division by zero returns zero
    try testing.expectEqual(U64.ZERO, a.wrapping_div(U64.ZERO));

    // Test wrapping_rem
    const c = U64.from_u64(23);
    const d = U64.from_u64(5);
    try testing.expectEqual(@as(u64, 3), c.wrapping_rem(d).to_u64().?);

    // Remainder by zero returns zero
    try testing.expectEqual(U64.ZERO, c.wrapping_rem(U64.ZERO));
}

test "u256 conversions" {
    const U256 = Uint(256, 4);
    const U128 = Uint(128, 2);
    const U512 = Uint(512, 8);

    // Test from_u256 for exact size
    const val: u256 = 0x123456789ABCDEF0_123456789ABCDEF0_123456789ABCDEF0_123456789ABCDEF0;
    const u256_val = U256.from_u256(val);
    try testing.expectEqual(val, u256_val.to_u256().?);

    // Test from_u256 for smaller size
    const small_val: u256 = 0xFFFF_FFFF_FFFF_FFFF;
    const u128_val = U128.from_u256(small_val);
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FFFF), u128_val.limbs[0]);
    try testing.expectEqual(@as(u64, 0), u128_val.limbs[1]);

    // Test from_u256 for larger size
    const u512_val = U512.from_u256(val);
    try testing.expectEqual(val, u512_val.to_u256().?);

    // Test to_u256 returns null for values that don't fit
    const big = U512.MAX;
    try testing.expectEqual(@as(?u256, null), big.to_u256());

    // Test roundtrip for various values
    const test_values = [_]u256{
        0,
        1,
        0xFF,
        0xFFFF,
        0xFFFF_FFFF,
        0xFFFF_FFFF_FFFF_FFFF,
        std.math.maxInt(u256),
    };

    for (test_values) |test_val| {
        const uint_val = U256.from_u256(test_val);
        try testing.expectEqual(test_val, uint_val.to_u256().?);
    }
}

// Comprehensive division test cases from intx
test "division edge cases from intx" {
    const U512 = Uint(512, 8);

    const DivTestCase = struct {
        numerator: U512,
        denominator: U512,
        quotient: U512,
        remainder: U512,
    };

    const test_cases = [_]DivTestCase{
        // Basic cases
        .{ .numerator = U512.from_int(2), .denominator = U512.from_int(1), .quotient = U512.from_int(2), .remainder = U512.ZERO },

        // Power of 2 division
        .{ .numerator = U512.from_u256(0x10000000000000000), .denominator = U512.from_int(2), .quotient = U512.from_u256(0x8000000000000000), .remainder = U512.ZERO },

        // Equal values
        .{ .numerator = U512.from_u256(0x8000000000000000), .denominator = U512.from_u256(0x8000000000000000), .quotient = U512.from_int(1), .remainder = U512.ZERO },

        // Numerator smaller than denominator
        .{ .numerator = U512.from_u256(0x7000000000000000), .denominator = U512.from_u256(0x8000000000000000), .quotient = U512.ZERO, .remainder = U512.from_u256(0x7000000000000000) },

        // Large division
        .{ .numerator = U512.init(.{ 0x0000000009000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000009000000, 0x0000000000000000, 0x0000001e00000000 }), .denominator = U512.from_int(0xa), .quotient = U512.init(.{ 0xcccccccccccccccc, 0x6666666674cccccc, 0x6666666666666666, 0x6666666666666666, 0x6666666666666666, 0x666666666e666666, 0x0000000000000000, 0x0000000300000000 }), .remainder = U512.from_int(8) },

        // Very large numbers with all words used
        .{ .numerator = U512.init(.{ 0xffffffffffffffee, 0x0000000000000200, 0x0000000001000000, 0x0000000000000000, 0xfffffffffffffffe, 0x0000000000000000, 0x0000000800000010, 0xffffffffffff0000 }), .denominator = U512.init(.{ 0x0000000000000000, 0xffffffff10000000, 0x0000000000000000, 0x0000000000000005, 0xffffffffffffff00, 0xffffffffffffffff, 0xfffffffffffffffb, 0xffffffffffffffff }), .quotient = U512.ZERO, .remainder = U512.init(.{ 0xffffffffffffffee, 0x0000000000000200, 0x0000000001000000, 0x0000000000000000, 0xfffffffffffffffe, 0x0000000000000000, 0x0000000800000010, 0xffffffffffff0000 }) },

        // Test case that triggers special reciprocal handling
        .{ .numerator = U512.from_u256(0x8000000000018002_8000000000000001), .denominator = U512.from_u256(0x8000000000018002_8000000000000000), .quotient = U512.from_int(1), .remainder = U512.from_int(1) },
    };

    for (test_cases) |tc| {
        const result = tc.numerator.div_rem(tc.denominator);
        try testing.expectEqual(tc.quotient, result.quotient);
        try testing.expectEqual(tc.remainder, result.remainder);

        // Verify: quotient * denominator + remainder = numerator
        const reconstructed = result.quotient.wrapping_mul(tc.denominator).wrapping_add(result.remainder);
        try testing.expectEqual(tc.numerator, reconstructed);
    }
}

// Comprehensive arithmetic tests from intx
test "arithmetic edge cases from intx" {
    const U256 = Uint(256, 4);

    // Test addition with carry propagation
    const a1 = U256.init(.{ 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0, 0 });
    const b1 = U256.from_int(1);
    const sum1 = a1.wrapping_add(b1);
    try testing.expectEqual(U256.init(.{ 0, 0, 1, 0 }), sum1);

    // Test subtraction with borrow propagation
    const a2 = U256.init(.{ 0, 0, 1, 0 });
    const b2 = U256.from_int(1);
    const diff2 = a2.wrapping_sub(b2);
    try testing.expectEqual(U256.init(.{ 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0, 0 }), diff2);

    // Test multiplication edge cases
    const max_u128 = U256.init(.{ 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0, 0 });
    const result_mul = max_u128.wrapping_mul(max_u128);
    try testing.expectEqual(U256.init(.{ 1, 0, 0xFFFFFFFFFFFFFFFE, 0xFFFFFFFFFFFFFFFF }), result_mul);

    // Test overflow detection
    const overflow_test = U256.MAX.overflowing_add(U256.ONE);
    try testing.expectEqual(U256.ZERO, overflow_test.value);
    try testing.expectEqual(true, overflow_test.overflow);

    // Test underflow detection
    const underflow_test = U256.ZERO.overflowing_sub(U256.ONE);
    try testing.expectEqual(U256.MAX, underflow_test.value);
    try testing.expectEqual(true, underflow_test.overflow);

    // Test multiplication overflow
    const mul_overflow = U256.MAX.overflowing_mul(U256.from_int(2));
    try testing.expectEqual(U256.MAX.wrapping_sub(U256.ONE), mul_overflow.value);
    try testing.expectEqual(true, mul_overflow.overflow);
}

// Comprehensive bitwise operation tests from intx
test "bitwise operations from intx" {
    const U256 = Uint(256, 4);

    // Test shift operations with various amounts
    const shift_test = U256.from_int(1);
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        const shifted_left = shift_test.shl(i);
        const shifted_back = shifted_left.shr(i);
        try testing.expectEqual(shift_test, shifted_back);
    }

    // Test shift overflow
    const all_ones = U256.MAX;
    try testing.expectEqual(U256.ZERO, all_ones.shl(256));
    try testing.expectEqual(U256.ZERO, all_ones.shr(256));

    // Test count leading zeros
    try testing.expectEqual(@as(u32, 256), U256.ZERO.clz());
    try testing.expectEqual(@as(u32, 0), U256.MAX.clz());
    try testing.expectEqual(@as(u32, 255), U256.ONE.clz());
    try testing.expectEqual(@as(u32, 128), U256.init(.{ 0, 0, 0x8000000000000000, 0 }).clz());

    // Test bit operations
    const bit_pattern = U256.init(.{ 0xAAAAAAAAAAAAAAAA, 0x5555555555555555, 0xFFFF0000FFFF0000, 0x0000FFFF0000FFFF });
    const inverted = bit_pattern.bit_not();
    try testing.expectEqual(U256.init(.{ 0x5555555555555555, 0xAAAAAAAAAAAAAAAA, 0x0000FFFF0000FFFF, 0xFFFF0000FFFF0000 }), inverted);

    // Test AND operation
    const and_mask = U256.init(.{ 0xFFFFFFFF00000000, 0xFFFFFFFF00000000, 0xFFFFFFFF00000000, 0xFFFFFFFF00000000 });
    const and_value = U256.init(.{ 0x123456789ABCDEF0, 0x123456789ABCDEF0, 0x123456789ABCDEF0, 0x123456789ABCDEF0 });
    const and_result = and_value.bit_and(and_mask);
    try testing.expectEqual(U256.init(.{ 0x1234567800000000, 0x1234567800000000, 0x1234567800000000, 0x1234567800000000 }), and_result);

    // Test OR operation
    const or_pattern1 = U256.init(.{ 0xF0F0F0F0F0F0F0F0, 0, 0, 0 });
    const or_pattern2 = U256.init(.{ 0x0F0F0F0F0F0F0F0F, 0, 0, 0 });
    const or_result = or_pattern1.bit_or(or_pattern2);
    try testing.expectEqual(U256.init(.{ 0xFFFFFFFFFFFFFFFF, 0, 0, 0 }), or_result);

    // Test XOR operation
    const xor_value = U256.init(.{ 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF });
    const xor_result = xor_value.bit_xor(xor_value);
    try testing.expectEqual(U256.ZERO, xor_result);
}

// Comprehensive modular arithmetic tests from intx
test "modular arithmetic edge cases from intx" {
    const U256 = Uint(256, 4);

    // Test add_mod with various cases
    const test_add_mod = struct {
        fn run(a: U256, b: U256, m: U256, expected: U256) !void {
            const result = a.add_mod(b, m);
            try testing.expectEqual(expected, result);
        }
    };

    // Basic cases
    try test_add_mod.run(U256.from_int(100), U256.from_int(200), U256.from_int(37), U256.from_int(4) // (100 + 200) % 37 = 4
    );

    // Case where sum equals modulus
    try test_add_mod.run(U256.from_int(20), U256.from_int(17), U256.from_int(37), U256.ZERO);

    // Large numbers
    const large_a = U256.init(.{ 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0, 0 });
    const large_b = U256.init(.{ 1, 0, 0, 0 });
    const large_m = U256.init(.{ 0, 0, 1, 0 });
    try test_add_mod.run(large_a, large_b, large_m, U256.ZERO);

    // Test sub_mod
    const test_sub_mod = struct {
        fn run(a: U256, b: U256, m: U256, expected: U256) !void {
            const result = a.sub_mod(b, m);
            try testing.expectEqual(expected, result);
        }
    };

    // a > b case
    try test_sub_mod.run(U256.from_int(100), U256.from_int(30), U256.from_int(37), U256.from_int(33) // (100 - 30) % 37 = 33
    );

    // a < b case (requires modular adjustment)
    try test_sub_mod.run(U256.from_int(10), U256.from_int(20), U256.from_int(37), U256.from_int(27) // (10 - 20 + 37) % 37 = 27
    );

    // Test mul_mod
    const test_mul_mod = struct {
        fn run(a: U256, b: U256, m: U256, expected: U256) !void {
            const result = a.mul_mod(b, m);
            try testing.expectEqual(expected, result);
        }
    };

    try test_mul_mod.run(U256.from_int(100), U256.from_int(200), U256.from_int(37), U256.from_int(1) // (100 * 200) % 37 = 1
    );

    // Test with MAX values
    const half_max = U256.MAX.shr(1);
    try test_mul_mod.run(half_max, U256.from_int(2), U256.MAX, U256.MAX.wrapping_sub(U256.ONE));
}

// More comprehensive edge case tests
test "additional edge cases from intx" {
    const U256 = Uint(256, 4);

    // Test signed less than (slt) equivalent
    const max_signed = U256.MAX.shr(1); // 0x7FFF...
    const min_signed = U256.ONE.shl(255); // 0x8000...

    // In unsigned comparison, min_signed > max_signed
    try testing.expect(min_signed.gt(max_signed));

    // Test reciprocal patterns (important for division optimization)
    const test_reciprocal_patterns = struct {
        fn run() !void {
            // Powers of 2 reciprocals
            var i: u32 = 1;
            while (i < 256) : (i += 1) {
                const power = U256.ONE.shl(i);
                const result = U256.MAX.div_rem(power);
                const expected_quot = U256.MAX.shr(i);
                const expected_rem = if (i == 0) U256.ZERO else U256.from_int((1 << i) - 1);

                try testing.expectEqual(expected_quot, result.quotient);
                try testing.expectEqual(expected_rem, result.remainder);
            }
        }
    };

    try test_reciprocal_patterns.run();

    // Test special multiplication patterns
    const all_ones_128 = U256.init(.{ 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0, 0 });
    const result = all_ones_128.wrapping_mul(all_ones_128);

    // (2^128 - 1)^2 = 2^256 - 2^129 + 1
    const expected = U256.init(.{ 1, 0, 0xFFFFFFFFFFFFFFFE, 0xFFFFFFFFFFFFFFFF });
    try testing.expectEqual(expected, result);

    // Test edge cases for nth_root
    const perfect_squares = [_]struct { n: U256, root: u64 }{
        .{ .n = U256.from_int(0), .root = 0 },
        .{ .n = U256.from_int(1), .root = 1 },
        .{ .n = U256.from_int(4), .root = 2 },
        .{ .n = U256.from_int(9), .root = 3 },
        .{ .n = U256.from_int(16), .root = 4 },
        .{ .n = U256.from_int(1024), .root = 32 },
        .{ .n = U256.from_int(1048576), .root = 1024 },
    };

    for (perfect_squares) |ps| {
        const sqrt_result = ps.n.sqrt();
        try testing.expectEqual(U256.from_int(ps.root), sqrt_result);
    }

    // Test edge cases for GCD
    const gcd_cases = [_]struct { a: U256, b: U256, expected: U256 }{
        .{ .a = U256.ZERO, .b = U256.from_int(10), .expected = U256.from_int(10) },
        .{ .a = U256.from_int(10), .b = U256.ZERO, .expected = U256.from_int(10) },
        .{ .a = U256.ONE, .b = U256.MAX, .expected = U256.ONE },
        .{ .a = U256.from_int(1024), .b = U256.from_int(768), .expected = U256.from_int(256) },
    };

    for (gcd_cases) |gc| {
        const gcd_result = gc.a.gcd(gc.b);
        try testing.expectEqual(gc.expected, gcd_result);
    }
}

// Test cases specifically for division edge cases that intx catches
test "division special cases from intx" {
    const U256 = Uint(256, 4);

    // Test division by 1
    const n = U256.MAX;
    const result = n.div_rem(U256.ONE);
    try testing.expectEqual(n, result.quotient);
    try testing.expectEqual(U256.ZERO, result.remainder);

    // Test division where quotient is exactly at boundary
    const boundary_cases = [_]struct {
        dividend: U256,
        divisor: U256,
        quot: U256,
        rem: U256,
    }{
        // 2^128 / 2^64 = 2^64
        .{
            .dividend = U256.ONE.shl(128),
            .divisor = U256.ONE.shl(64),
            .quot = U256.ONE.shl(64),
            .rem = U256.ZERO,
        },
        // (2^128 - 1) / 2^64 = 2^64 - 1, remainder 2^64 - 1
        .{
            .dividend = U256.ONE.shl(128).wrapping_sub(U256.ONE),
            .divisor = U256.ONE.shl(64),
            .quot = U256.ONE.shl(64).wrapping_sub(U256.ONE),
            .rem = U256.ONE.shl(64).wrapping_sub(U256.ONE),
        },
    };

    for (boundary_cases) |bc| {
        const div_result = bc.dividend.div_rem(bc.divisor);
        try testing.expectEqual(bc.quot, div_result.quotient);
        try testing.expectEqual(bc.rem, div_result.remainder);
    }

    // Test normalization edge cases (important for Knuth algorithm)
    const norm_cases = [_]struct {
        n: U256,
        d: U256,
    }{
        // Divisor with leading bit set
        .{
            .n = U256.MAX,
            .d = U256.ONE.shl(255),
        },
        // Divisor with leading bit not set
        .{
            .n = U256.MAX.shr(1),
            .d = U256.ONE.shl(254),
        },
    };

    for (norm_cases) |nc| {
        const div_result = nc.n.div_rem(nc.d);
        const reconstructed = div_result.quotient.wrapping_mul(nc.d).wrapping_add(div_result.remainder);
        try testing.expectEqual(nc.n, reconstructed);
    }
}

// Performance stress tests from intx
test "performance stress tests from intx" {
    if (@import("builtin").is_test) {
        // Skip intensive tests in normal test runs
        return;
    }

    const U256 = Uint(256, 4);

    // Test many sequential operations
    var accumulator = U256.ONE;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        accumulator = accumulator.wrapping_mul(U256.from_int(3)).wrapping_add(U256.from_int(7));
        accumulator = accumulator.wrapping_div(U256.from_int(2));
    }

    // Test large multiplication chains
    var factorial = U256.ONE;
    i = 1;
    while (i <= 50) : (i += 1) {
        factorial = factorial.wrapping_mul(U256.from_int(i));
    }

    // Test division with many different divisors
    const dividend = U256.MAX.shr(1);
    i = 1;
    while (i < 100) : (i += 1) {
        const divisor = U256.from_int(i);
        const result = dividend.div_rem(divisor);
        const check = result.quotient.wrapping_mul(divisor).wrapping_add(result.remainder);
        try testing.expectEqual(dividend, check);
    }
}
