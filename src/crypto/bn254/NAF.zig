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

test "naf computation" {
    const std = @import("std");

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
