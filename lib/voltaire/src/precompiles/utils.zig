const std = @import("std");

/// Calculate MSM discount factor for multi-scalar multiplication
/// Based on EIP-2537 discount table
pub fn msmDiscount(k: usize) u64 {
    return if (k >= 128)
        174
    else if (k >= 64)
        200
    else if (k >= 32)
        250
    else if (k >= 16)
        320
    else if (k >= 8)
        430
    else if (k >= 4)
        580
    else if (k >= 2)
        820
    else
        1000;
}

test "msmDiscount - discount table" {
    const testing = std.testing;

    try testing.expectEqual(@as(u64, 1000), msmDiscount(1));
    try testing.expectEqual(@as(u64, 820), msmDiscount(2));
    try testing.expectEqual(@as(u64, 580), msmDiscount(4));
    try testing.expectEqual(@as(u64, 430), msmDiscount(8));
    try testing.expectEqual(@as(u64, 320), msmDiscount(16));
    try testing.expectEqual(@as(u64, 250), msmDiscount(32));
    try testing.expectEqual(@as(u64, 200), msmDiscount(64));
    try testing.expectEqual(@as(u64, 174), msmDiscount(128));
}
