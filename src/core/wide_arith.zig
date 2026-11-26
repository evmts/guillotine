//! Exact multi-limb division for the 256-bit arithmetic opcodes (DIV, SDIV, MOD, SMOD,
//! ADDMOD, MULMOD).
//!
//! LLVM lowers `u256 / u256` and `u512 % u512` to a bit-at-a-time loop, and it lowers
//! `u128 / u64` to a compiler-rt call. Both are wrong for a `preserve_none` opcode
//! handler: the loop needs a large stack frame, and the call forces the handler to
//! spill its pinned register arguments. The routines here use one hardware division
//! per quotient limb (Knuth, TAOCP volume 2, algorithm D) and contain no calls.
//!
//! Every routine follows the EVM convention that division by zero yields zero.
const std = @import("std");
const builtin = @import("builtin");

/// True when `divWide(u64, ...)` is a single `divq` instruction.
const has_divq = builtin.cpu.arch == .x86_64 and builtin.os.tag != .windows and builtin.zig_backend == .stage2_llvm;

/// Divide the two-limb value `hi:lo` by `d`, store the remainder in `remainder` and return the
/// quotient. The caller guarantees `hi < d`, so the quotient fits one limb.
pub inline fn divWide(comptime Limb: type, hi: Limb, lo: Limb, d: Limb, remainder: *Limb) Limb {
    if (Limb == u64) {
        if (comptime has_divq) {
            var r: u64 = undefined;
            const q = asm (
                \\divq %[d]
                : [_] "={rax}" (-> u64),
                  [_] "={rdx}" (r),
                : [d] "r" (d),
                  [_] "{rax}" (lo),
                  [_] "{rdx}" (hi),
            );
            remainder.* = r;
            return q;
        }
        return divWideSoft(hi, lo, d, remainder);
    }
    const bits = @bitSizeOf(Limb);
    const Double = @Int(.unsigned, 2 * bits);
    const n = (@as(Double, hi) << bits) | lo;
    remainder.* = @intCast(n % d);
    return @intCast(n / d);
}

/// `divWide` for 64-bit limbs without a 128-by-64 divide instruction: two 64-by-32
/// divisions (Hacker's Delight, `divlu`). The caller guarantees `hi < d`.
pub inline fn divWideSoft(hi: u64, lo: u64, d: u64, remainder: *u64) u64 {
    const b: u64 = 1 << 32;
    const mask: u64 = b - 1;

    // Normalize so the divisor's top bit is set. `hi < d` implies `d != 0`.
    const s: u6 = @intCast(@clz(d));
    const v = d << s;
    const vn1 = v >> 32;
    const vn0 = v & mask;
    const un32 = if (s == 0) hi else (hi << s) | (lo >> @intCast(@as(u7, 64) - s));
    const un10 = lo << s;
    const un1 = un10 >> 32;
    const un0 = un10 & mask;

    // First quotient digit. The estimate is at most 2 too large.
    var q1 = un32 / vn1;
    var rhat = un32 - q1 * vn1;
    while (q1 >= b or q1 * vn0 > (rhat << 32) + un1) {
        q1 -= 1;
        rhat += vn1;
        if (rhat >= b) break;
    }
    const un21 = (un32 << 32) +% un1 -% q1 *% v;

    // Second quotient digit.
    var q0 = un21 / vn1;
    rhat = un21 - q0 * vn1;
    while (q0 >= b or q0 * vn0 > (rhat << 32) + un0) {
        q0 -= 1;
        rhat += vn1;
        if (rhat >= b) break;
    }

    remainder.* = ((un21 << 32) +% un0 -% q0 *% v) >> s;
    return (q1 << 32) +% q0;
}

/// Multi-limb arithmetic on little-endian arrays of `Limb`. The opcodes use `u64` limbs.
/// The tests also instantiate `u8` limbs, where the rare correction steps of algorithm D
/// run often enough to be checked against native division.
pub fn Wide(comptime Limb: type) type {
    return struct {
        const bits = @bitSizeOf(Limb);
        const Double = @Int(.unsigned, 2 * bits);
        const Shift = std.math.Log2Int(Limb);
        const limb_max: Limb = std.math.maxInt(Limb);

        /// Number of limbs up to and including the most significant non-zero limb.
        inline fn significant(comptime len: usize, x: [len]Limb) usize {
            var n: usize = len;
            while (n > 0 and x[n - 1] == 0) n -= 1;
            return n;
        }

        /// Divide `u` by `v`. Stores the quotient in `q` and returns the remainder.
        /// A zero `v` gives a zero quotient and a zero remainder.
        pub inline fn divRem(comptime N: usize, comptime M: usize, u: [N]Limb, v: [M]Limb, q: *[N]Limb) [M]Limb {
            comptime if (M > N) @compileError("divRem needs a dividend at least as long as the divisor");
            var r: [M]Limb = @splat(0);
            q.* = @splat(0);

            const n = significant(M, v);
            if (n == 0) return r;

            // One-limb divisor: schoolbook division, one hardware divide per limb.
            if (n == 1) {
                var carry: Limb = 0;
                var i: usize = N;
                while (i > 0) {
                    i -= 1;
                    q[i] = divWide(Limb, carry, u[i], v[0], &carry);
                }
                r[0] = carry;
                return r;
            }

            // Dividend shorter than the divisor: the quotient is zero.
            // Limbs of `u` above `m` are zero, so copying `M` limbs copies all of `u`.
            const m = significant(N, u);
            if (m < n) {
                for (0..M) |i| r[i] = u[i];
                return r;
            }

            // D1: shift both operands left so the divisor's top limb has its top bit set.
            // `un` gets one extra limb for the bits shifted out of the dividend. The loops
            // run over every limb, not just the significant ones: the limbs above are zero
            // and stay zero, and fixed bounds keep the loops free of `memcpy` calls.
            const s = @clz(v[n - 1]);
            var vn: [M]Limb = v;
            var un: [N + 1]Limb = @splat(0);
            if (s == 0) {
                for (0..N) |i| un[i] = u[i];
            } else {
                const left: Shift = @intCast(s);
                const right: Shift = @intCast(bits - @as(usize, s));
                vn[0] = v[0] << left;
                inline for (1..M) |i| vn[i] = (v[i] << left) | (v[i - 1] >> right);
                un[0] = u[0] << left;
                inline for (1..N) |i| un[i] = (u[i] << left) | (u[i - 1] >> right);
                un[N] = u[N - 1] >> right;
            }

            const v_top = vn[n - 1];
            const v_next = vn[n - 2];
            var j: usize = m - n;
            while (true) {
                // D3: estimate the quotient limb from the top two limbs of the running
                // remainder. The invariant `un[j + n] <= v_top` holds, and equality means
                // the estimate saturates at the largest limb.
                var qhat: Limb = undefined;
                var rhat: Limb = undefined;
                var rhat_fits = true;
                if (un[j + n] >= v_top) {
                    qhat = limb_max;
                    const sum = @addWithOverflow(un[j + n - 1], v_top);
                    rhat = sum[0];
                    rhat_fits = sum[1] == 0;
                } else {
                    qhat = divWide(Limb, un[j + n], un[j + n - 1], v_top, &rhat);
                }
                // Lower the estimate while it is provably too large. Each step adds
                // `v_top >= 2^(bits-1)` to `rhat`, so `rhat` overflows a limb and the loop
                // stops after at most two steps.
                while (rhat_fits) {
                    const lhs = @as(Double, qhat) * v_next;
                    const rhs = (@as(Double, rhat) << bits) | un[j + n - 2];
                    if (lhs <= rhs) break;
                    qhat -= 1;
                    const sum = @addWithOverflow(rhat, v_top);
                    rhat = sum[0];
                    rhat_fits = sum[1] == 0;
                }

                // D4: subtract `qhat * vn` from the running remainder.
                var carry: Limb = 0;
                var borrow: u1 = 0;
                for (0..n) |i| {
                    const product = @as(Double, qhat) * vn[i] + carry;
                    carry = @intCast(product >> bits);
                    const d1 = @subWithOverflow(un[i + j], @as(Limb, @truncate(product)));
                    const d2 = @subWithOverflow(d1[0], @as(Limb, borrow));
                    un[i + j] = d2[0];
                    borrow = d1[1] | d2[1];
                }
                const t1 = @subWithOverflow(un[j + n], carry);
                const t2 = @subWithOverflow(t1[0], @as(Limb, borrow));
                un[j + n] = t2[0];

                // D5/D6: the estimate was one too large; add the divisor back once.
                if ((t1[1] | t2[1]) != 0) {
                    qhat -= 1;
                    var c: u1 = 0;
                    for (0..n) |i| {
                        const a1 = @addWithOverflow(un[i + j], vn[i]);
                        const a2 = @addWithOverflow(a1[0], @as(Limb, c));
                        un[i + j] = a2[0];
                        c = a1[1] | a2[1];
                    }
                    un[j + n] +%= c;
                }

                q[j] = qhat;
                if (j == 0) break;
                j -= 1;
            }

            // D8: undo the normalization shift. The remainder is in `un[0..n]`, and every
            // limb of `un` above it is zero.
            if (s == 0) {
                for (0..M) |i| r[i] = un[i];
            } else {
                const right: Shift = @intCast(s);
                const left: Shift = @intCast(bits - @as(usize, s));
                for (0..M) |i| r[i] = (un[i] >> right) | (un[i + 1] << left);
            }
            return r;
        }
    };
}

const W = Wide(u64);

pub inline fn toLimbs(x: u256) [4]u64 {
    return .{
        @truncate(x),
        @truncate(x >> 64),
        @truncate(x >> 128),
        @truncate(x >> 192),
    };
}

pub inline fn fromLimbs(l: [4]u64) u256 {
    return @as(u256, l[0]) | (@as(u256, l[1]) << 64) | (@as(u256, l[2]) << 128) | (@as(u256, l[3]) << 192);
}

/// True when `x` has no bits above bit 63.
pub inline fn fitsU64(x: u256) bool {
    return (x >> 64) == 0;
}

/// `numerator / divisor`, or 0 when `divisor` is 0.
pub inline fn div(numerator: u256, divisor: u256) u256 {
    var q: [4]u64 = undefined;
    _ = W.divRem(4, 4, toLimbs(numerator), toLimbs(divisor), &q);
    return fromLimbs(q);
}

/// `numerator % divisor`, or 0 when `divisor` is 0.
pub inline fn rem(numerator: u256, divisor: u256) u256 {
    var q: [4]u64 = undefined;
    return fromLimbs(W.divRem(4, 4, toLimbs(numerator), toLimbs(divisor), &q));
}

/// `(a + b) % modulus` over the 257-bit sum, or 0 when `modulus` is 0.
pub inline fn addmod(a: u256, b: u256, modulus: u256) u256 {
    const sum = @addWithOverflow(a, b);
    const low = toLimbs(sum[0]);
    const numerator = [5]u64{ low[0], low[1], low[2], low[3], sum[1] };
    var q: [5]u64 = undefined;
    return fromLimbs(W.divRem(5, 4, numerator, toLimbs(modulus), &q));
}

/// `(a * b) % modulus` over the 512-bit product, or 0 when `modulus` is 0.
pub inline fn mulmod(a: u256, b: u256, modulus: u256) u256 {
    const x = toLimbs(a);
    const y = toLimbs(b);
    var product: [8]u64 = @splat(0);
    for (0..4) |i| {
        var carry: u64 = 0;
        for (0..4) |j| {
            // At most (2^64-1)^2 + 2*(2^64-1) = 2^128 - 1: no overflow.
            const t = @as(u128, x[i]) * y[j] + product[i + j] + carry;
            product[i + j] = @truncate(t);
            carry = @intCast(t >> 64);
        }
        product[i + 4] = carry;
    }
    var q: [8]u64 = undefined;
    return fromLimbs(W.divRem(8, 4, product, toLimbs(modulus), &q));
}

/// `a / b` for one-limb operands, or 0 when `b` is 0.
pub inline fn div64(a: u64, b: u64) u64 {
    return if (b == 0) 0 else a / b;
}

/// `a % b` for one-limb operands, or 0 when `b` is 0.
pub inline fn rem64(a: u64, b: u64) u64 {
    return if (b == 0) 0 else a % b;
}

/// `(a * b) % modulus` for one-limb operands, or 0 when `modulus` is 0.
pub inline fn mulmod64(a: u64, b: u64, modulus: u64) u64 {
    if (modulus == 0) return 0;
    const product = @as(u128, a) * b;
    const hi: u64 = @intCast(product >> 64);
    const lo: u64 = @truncate(product);
    if (hi == 0) return lo % modulus;
    var r: u64 = undefined;
    _ = divWide(u64, hi % modulus, lo, modulus, &r);
    return r;
}

// ====== TESTS ======

const testing = std.testing;

/// Limbs that reach the boundary cases of algorithm D far more often than uniform
/// random limbs do.
fn edgeLimb(random: std.Random) u64 {
    return switch (random.uintLessThan(u8, 10)) {
        0 => 0,
        1 => 1,
        2 => std.math.maxInt(u64),
        3 => std.math.maxInt(u64) - 1,
        4 => 1 << 63,
        5 => (1 << 63) - 1,
        6 => (1 << 63) + 1,
        7 => random.int(u32),
        else => random.int(u64),
    };
}

/// A 256-bit value with a random number of significant limbs made of edge limbs.
fn edgeWord(random: std.Random) u256 {
    const count = random.uintLessThan(u8, 5);
    var limbs: [4]u64 = @splat(0);
    for (0..count) |i| limbs[i] = edgeLimb(random);
    return fromLimbs(limbs);
}

test "divWide matches native 128-bit division" {
    var prng = std.Random.DefaultPrng.init(0x5eed_d1f1_de00_0001);
    const random = prng.random();
    for (0..200_000) |_| {
        const d = @max(edgeLimb(random), 1);
        const hi = edgeLimb(random) % d;
        const lo = edgeLimb(random);
        const n = (@as(u128, hi) << 64) | lo;
        var r_soft: u64 = undefined;
        const q_soft = divWideSoft(hi, lo, d, &r_soft);
        var r: u64 = undefined;
        const q = divWide(u64, hi, lo, d, &r);
        try testing.expectEqual(@as(u64, @intCast(n / d)), q_soft);
        try testing.expectEqual(@as(u64, @intCast(n % d)), r_soft);
        try testing.expectEqual(q_soft, q);
        try testing.expectEqual(r_soft, r);
    }
}

test "divWideSoft handles the largest operands" {
    const max = std.math.maxInt(u64);
    var r: u64 = undefined;
    try testing.expectEqual(@as(u64, max), divWideSoft(max - 1, max, max, &r));
    try testing.expectEqual(@as(u64, max - 1), r);
    try testing.expectEqual(@as(u64, 0), divWideSoft(0, 0, 1, &r));
    try testing.expectEqual(@as(u64, 0), r);
    try testing.expectEqual(@as(u64, max), divWideSoft(0, max, 1, &r));
    try testing.expectEqual(@as(u64, 0), r);
    try testing.expectEqual(@as(u64, 1), divWideSoft(0, 1 << 63, 1 << 63, &r));
    try testing.expectEqual(@as(u64, 0), r);
}

test "algorithm D with 8-bit limbs: every 16-bit divisor against random 32-bit dividends" {
    const W8 = Wide(u8);
    var prng = std.Random.DefaultPrng.init(0x5eed_d1f1_de00_0002);
    const random = prng.random();
    var divisor: u32 = 0;
    while (divisor <= std.math.maxInt(u16)) : (divisor += 1) {
        for (0..24) |round| {
            // Mix uniform dividends with dividends just below and above multiples of the
            // divisor, where the quotient estimate is most often wrong.
            var dividend = random.int(u32);
            if (round % 3 == 1 and divisor != 0) dividend = (dividend / divisor) *% divisor -% @as(u32, @intCast(round % 5));
            if (round % 3 == 2) dividend |= 0xff00_0000;
            const u = [4]u8{ @truncate(dividend), @truncate(dividend >> 8), @truncate(dividend >> 16), @truncate(dividend >> 24) };
            const v = [2]u8{ @truncate(divisor), @truncate(divisor >> 8) };
            var q: [4]u8 = undefined;
            const r = W8.divRem(4, 2, u, v, &q);
            const got_q = @as(u32, q[0]) | (@as(u32, q[1]) << 8) | (@as(u32, q[2]) << 16) | (@as(u32, q[3]) << 24);
            const got_r = @as(u32, r[0]) | (@as(u32, r[1]) << 8);
            const want_q: u32 = if (divisor == 0) 0 else dividend / divisor;
            const want_r: u32 = if (divisor == 0) 0 else dividend % divisor;
            try testing.expectEqual(want_q, got_q);
            try testing.expectEqual(want_r, got_r);
        }
    }
}

test "algorithm D with 8-bit limbs: 64-bit dividends by 32-bit divisors" {
    const W8 = Wide(u8);
    var prng = std.Random.DefaultPrng.init(0x5eed_d1f1_de00_0003);
    const random = prng.random();
    for (0..1_000_000) |round| {
        var dividend = random.int(u64);
        var divisor = random.int(u32);
        // Vary the number of significant limbs and saturate limbs to hit `qhat == max`.
        divisor >>= @intCast(8 * random.uintLessThan(u8, 4));
        dividend >>= @intCast(8 * random.uintLessThan(u8, 8));
        if (round % 4 == 0) divisor |= 0xff00_0000;
        if (round % 8 == 0) dividend |= 0xffff_0000_0000_0000;
        if (round % 16 == 0 and divisor != 0) dividend = (dividend / divisor) * divisor;
        var u: [8]u8 = undefined;
        var v: [4]u8 = undefined;
        for (0..8) |i| u[i] = @truncate(dividend >> @intCast(8 * i));
        for (0..4) |i| v[i] = @truncate(divisor >> @intCast(8 * i));
        var q: [8]u8 = undefined;
        const r = W8.divRem(8, 4, u, v, &q);
        var got_q: u64 = 0;
        var got_r: u64 = 0;
        for (0..8) |i| got_q |= @as(u64, q[i]) << @intCast(8 * i);
        for (0..4) |i| got_r |= @as(u64, r[i]) << @intCast(8 * i);
        const want_q: u64 = if (divisor == 0) 0 else dividend / divisor;
        const want_r: u64 = if (divisor == 0) 0 else dividend % divisor;
        try testing.expectEqual(want_q, got_q);
        try testing.expectEqual(want_r, got_r);
    }
}

test "div and rem match native u256 division" {
    var prng = std.Random.DefaultPrng.init(0x5eed_d1f1_de00_0004);
    const random = prng.random();
    for (0..200_000) |_| {
        const a = edgeWord(random);
        const b = edgeWord(random);
        const want_q: u256 = if (b == 0) 0 else a / b;
        const want_r: u256 = if (b == 0) 0 else a % b;
        try testing.expectEqual(want_q, div(a, b));
        try testing.expectEqual(want_r, rem(a, b));
    }
}

test "div and rem: add-back and saturated-estimate vectors" {
    const max = std.math.maxInt(u64);
    const cases = [_][2][4]u64{
        // 64-bit forms of the Hacker's Delight `divmnu` vectors that need step D6.
        .{ .{ 3, 0, 1 << 63, 0 }, .{ 1, 0, 1 << 61, 0 } },
        .{ .{ 0, max - 1, 1 << 63, 0 }, .{ max, 1 << 63, 0, 0 } },
        .{ .{ 0, 0, 1 << 63, (1 << 63) - 1 }, .{ max, 0, 1 << 63, 0 } },
        .{ .{ 0, 0, 0, 1 << 63 }, .{ 1, 0, 1 << 63, 0 } },
        // Top limbs equal: the estimate saturates.
        .{ .{ 0, 0, max, max }, .{ max, max, 0, 0 } },
        .{ .{ max, max, max, max }, .{ max, max, max, 0 } },
        .{ .{ max, max, max, max }, .{ 1, max, 0, 0 } },
        .{ .{ 0, 0, 0, max }, .{ 0, 0, max, 0 } },
        .{ .{ max, max, max, max }, .{ max, max, max, max } },
        .{ .{ max - 1, max, max, max }, .{ max, max, max, max } },
        .{ .{ 0, 0, 0, 1 << 63 }, .{ max, max, max, (1 << 63) - 1 } },
        .{ .{ 0, 0, 0, 1 << 63 }, .{ 0, 0, 0, 1 << 63 } },
        .{ .{ 0, 0, 0, 1 }, .{ max, max, max, 0 } },
        .{ .{ 5, 0, 0, 0 }, .{ 0, 1, 0, 0 } },
        .{ .{ max, max, max, max }, .{ 0, 0, 0, 0 } },
        .{ .{ max, max, max, max }, .{ 1, 0, 0, 0 } },
        .{ .{ max, max, max, max }, .{ 2, 0, 0, 0 } },
        .{ .{ max, max, max, max }, .{ max, 0, 0, 0 } },
    };
    for (cases) |case| {
        const a = fromLimbs(case[0]);
        const b = fromLimbs(case[1]);
        const want_q: u256 = if (b == 0) 0 else a / b;
        const want_r: u256 = if (b == 0) 0 else a % b;
        try testing.expectEqual(want_q, div(a, b));
        try testing.expectEqual(want_r, rem(a, b));
        // The quotient and remainder reconstruct the dividend.
        if (b != 0) try testing.expectEqual(a, div(a, b) *% b +% rem(a, b));
    }
}

test "addmod matches 512-bit reference arithmetic" {
    var prng = std.Random.DefaultPrng.init(0x5eed_d1f1_de00_0005);
    const random = prng.random();
    for (0..100_000) |_| {
        const a = edgeWord(random);
        const b = edgeWord(random);
        const m = edgeWord(random);
        const want: u256 = if (m == 0) 0 else @intCast((@as(u512, a) + b) % m);
        try testing.expectEqual(want, addmod(a, b, m));
    }
    const max = std.math.maxInt(u256);
    try testing.expectEqual(@as(u256, 0), addmod(max, max, 0));
    try testing.expectEqual(@as(u256, 0), addmod(max, max, max));
    try testing.expectEqual(@as(u256, max - 1), addmod(max, max - 1, max));
    try testing.expectEqual(@as(u256, 0), addmod(max, 1, 1));
    try testing.expectEqual(@as(u256, 2), addmod(max, 2, max));
    try testing.expectEqual(@as(u256, 0), addmod(max, 1, 2));
}

test "mulmod matches 512-bit reference arithmetic" {
    var prng = std.Random.DefaultPrng.init(0x5eed_d1f1_de00_0006);
    const random = prng.random();
    for (0..50_000) |_| {
        const a = edgeWord(random);
        const b = edgeWord(random);
        const m = edgeWord(random);
        const want: u256 = if (m == 0) 0 else @intCast((@as(u512, a) * b) % m);
        try testing.expectEqual(want, mulmod(a, b, m));
    }
    const max = std.math.maxInt(u256);
    try testing.expectEqual(@as(u256, 0), mulmod(max, max, 0));
    try testing.expectEqual(@as(u256, 0), mulmod(max, max, 1));
    try testing.expectEqual(@as(u256, 0), mulmod(max, max, max));
    try testing.expectEqual(@as(u256, 1), mulmod(max, max, max - 1));
    try testing.expectEqual(@as(u256, 0), mulmod(0, max, 7));
}

test "one-limb fast paths match the wide routines" {
    var prng = std.Random.DefaultPrng.init(0x5eed_d1f1_de00_0007);
    const random = prng.random();
    for (0..200_000) |_| {
        const a = edgeLimb(random);
        const b = edgeLimb(random);
        const m = edgeLimb(random);
        try testing.expectEqual(div(a, b), @as(u256, div64(a, b)));
        try testing.expectEqual(rem(a, b), @as(u256, rem64(a, b)));
        try testing.expectEqual(mulmod(a, b, m), @as(u256, mulmod64(a, b, m)));
        const want: u64 = if (m == 0) 0 else @intCast((@as(u128, a) * b) % m);
        try testing.expectEqual(want, mulmod64(a, b, m));
        try testing.expect(fitsU64(a));
        try testing.expect(!fitsU64((@as(u256, 1) << 64) | a));
    }
}
