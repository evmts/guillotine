const std = @import("std");

// Returns a 128-bit integer in NAF representation
// The NAF representation is a 128 signed bit vector where most of the bits are 0, and a few are 1 or -1
// This is useful when the -1 case is fast (neg on ECs or inverse in certain fields subgroup)
pub fn naf(n: u128) [128]i2 {
    var result: [128]i2 = undefined;
    var w = n;
    var i: usize = 0;

    while (w > 0 and i < 128) : (i += 1) {
        if (w & 1 == 1) {
            // Check if w mod 4 == 3 (last two bits are 11)
            // If so, use -1, otherwise use 1
            const width: i2 = if ((w & 3) == 3) -1 else 1;
            result[i] = width;
            // Subtract the digit from w
            // If width is -1, we add 1 (subtract -1)
            // If width is 1, we subtract 1
            if (width == -1) {
                w = (w + 1) >> 1;
            } else {
                w = (w - 1) >> 1;
            }
        } else {
            result[i] = 0;
            w >>= 1;
        }
    }

    // Zero out the remaining elements
    while (i < 128) : (i += 1) {
        result[i] = 0;
    }

    return result;
}

/// wNAF decomposition for unsigned integer type `T`.
/// Returns an array of length `@bitSizeOf(T) + 1` of signed i16 digits.
/// Digits are in little-endian "bit index order": digit for 2^0 at index 0, etc.
/// Non-zero digits are odd and in ±{1,3,...,2^{w-1}-1}, with ≥(w-1) zeros between them.
pub fn wnaf(comptime w: comptime_int, comptime T: type, k: T) [@bitSizeOf(T) + 1]i8 {
    comptime {
        if (w < 2) @compileError("wNAF width must be at least 2");
        // With i16 digits, the max nonzero is 2^{w-1}-1; w up to 16 fits safely.
        if (w > 16) @compileError("wNAF width too large for i16 digits");
    }

    const nbits = @bitSizeOf(T);
    // Wide type to allow +/- digit adjustments safely
    const Wide = std.meta.Int(.unsigned, nbits + w + 1);

    var out: [nbits + 1]i8 = [_]i8{0} ** (nbits + 1);

    const base: Wide = @as(Wide, 1) << w; // 2^w
    const mask: Wide = base - 1; // (1<<w) - 1
    const half: Wide = base >> 1; // 2^(w-1)

    var remaining: Wide = @as(Wide, k);
    var i: usize = 0;

    while (remaining != 0 and i < out.len) : (i += 1) {
        if ((remaining & 1) == 1) {
            // Take the low w bits
            const chunk = remaining & mask;
            var d: i8 = @intCast(chunk);
            // Make it centered and odd in ±{1,3,...,2^{w-1}-1}
            if (chunk >= half) d -= @intCast(base);

            // Store digit (odd, within i16 range)
            out[i] = @intCast(d);

            // Update: (remaining - d) / 2
            if (d >= 0) {
                remaining = (remaining - @as(Wide, @intCast(d))) >> 1;
            } else {
                remaining = (remaining + @as(Wide, @intCast(-d))) >> 1;
            }
        } else {
            out[i] = 0;
            remaining >>= 1;
        }
    }

    // Remaining higher entries are already zero
    return out;
}

test "naf computation" {
    const test_values = [_]u128{
        0,
        1,
        2,
        54335648765,
        234567654324567876543,
        9875876465354765354324325478658675452,
    };

    for (test_values) |n| {
        const digits = naf(n);

        var val: u128 = 0;
        var pow: u128 = 1;
        for (digits) |digit| {
            if (digit == 1) {
                val +%= pow;
            } else if (digit == -1) {
                val -%= pow;
            }
            pow *%= 2;
        }

        try std.testing.expectEqual(n, val);
    }
}

test "wnaf decomposition" {
    const widths = [_]comptime_int{ 2, 3, 4 };
    const values = [_]u128{
        0,
        1,
        2,
        15,
        54335648765,
        274906013565423476266072906867506652922,
        0xffffffffffffffffffffffffffffffff,
    };

    // Big enough to hold reconstruction from i16 digits over 129 bits.
    const Signed = std.meta.Int(.signed, 256);

    inline for (widths) |w| {
        // Allowed absolute digit bound for wNAF(w): 2^{w-1} - 1
        const abs_bound: i16 = (@as(i16, 1) << (w - 1)) - 1;

        for (values) |scalar| {
            const digits = wnaf(w, u128, scalar);

            // Reconstruct and check invariants
            var recon: Signed = 0;

            // Track spacing between non-zeros
            var last_nz: ?usize = null;

            // Optional: stop after the highest nonzero digit to speed up
            var top: isize = @as(isize, @intCast(digits.len)) - 1;

            while (top >= 0 and digits[@intCast(top)] == 0) : (top -= 1) {}
            const hi = if (top < 0) 0 else @as(usize, @intCast(top));

            var i: usize = 0;
            while (i <= hi) : (i += 1) {
                const d = digits[i];

                // digits must be 0 or odd and within bound
                if (d != 0) {
                    // Oddness
                    try std.testing.expect((d & 1) != 0);

                    // Magnitude
                    const ad: i8 = if (d >= 0) d else -d;
                    try std.testing.expect(ad <= abs_bound);

                    // Sparsity: distance ≥ w between consecutive nonzeros
                    if (last_nz) |prev| {
                        try std.testing.expect(i - prev >= @as(usize, w));
                    }
                    last_nz = i;

                    // Recompose using bit index (not window index!)
                    const term: Signed = @as(Signed, d);
                    recon += term << @intCast(i); // shift by i, not i*w
                }
            }

            const expected: Signed = @intCast(scalar);
            try std.testing.expectEqual(expected, recon);
        }
    }
}
