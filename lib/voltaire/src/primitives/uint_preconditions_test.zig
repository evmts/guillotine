//! Regression tests for `Uint` preconditions (R2-58). uint.zig's own tests do
//! not compile yet, so lib/voltaire/build.zig runs this file as its own test
//! module that imports `voltaire`, which keeps uint.zig's tests out of it.
const std = @import("std");
const testing = std.testing;
const Uint = @import("voltaire").Uint;

test "wrapping_shl truncates narrow types instead of trapping" {
    const U64 = Uint(64, 1);
    const all = U64.from_u64(std.math.maxInt(u64));
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FFF0), all.wrapping_shl(4).to_u64());
    try testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), all.wrapping_shl(63).to_u64());

    const U8 = Uint(8, 1);
    try testing.expectEqual(@as(u64, 0xA0), U8.from_u64(0xFA).wrapping_shl(4).to_u64());
}

test "logarithm preconditions return errors" {
    const U64 = Uint(64, 1);
    try testing.expectError(error.LogOfZero, U64.ZERO.log2());
    try testing.expectError(error.LogOfZero, U64.ZERO.log10());
    try testing.expectError(error.LogOfZero, U64.ZERO.log(U64.from_u64(3)));
    try testing.expectError(error.InvalidLogBase, U64.from_u64(9).log(U64.ONE));
    try testing.expectError(error.InvalidLogBase, U64.from_u64(9).log(U64.ZERO));
    try testing.expectEqual(@as(usize, 3), try U64.from_u64(8).log2());
    try testing.expectEqual(@as(usize, 2), try U64.from_u64(26).log(U64.from_u64(3)));
    try testing.expectEqual(@as(usize, 3), try U64.from_u64(27).log(U64.from_u64(3)));
    try testing.expectEqual(@as(usize, 3), try U64.from_u64(1000).log10());
    try testing.expectEqual(@as(?usize, null), U64.ZERO.checked_log10());

    // A 3-bit type cannot hold 10, so base-10 logarithms are rejected.
    const U3 = Uint(3, 1);
    try testing.expectError(error.InvalidLogBase, U3.from_u64(7).log10());
    try testing.expectEqual(@as(?usize, null), U3.from_u64(7).checked_log10());
}

test "from_u256 reports overflow instead of trapping" {
    const U128 = Uint(128, 2);
    try testing.expectError(error.Overflow, U128.from_u256(@as(u256, 1) << 128));
    const max = try U128.from_u256(std.math.maxInt(u128));
    try testing.expectEqual(@as(u256, std.math.maxInt(u128)), max.to_native());

    const U256 = Uint(256, 4);
    const top = try U256.from_u256(std.math.maxInt(u256));
    try testing.expectEqual(@as(u256, std.math.maxInt(u256)), top.to_native());
}

test "leading_zeros and bit_len count from the type width" {
    const U64 = Uint(64, 1);
    try testing.expectEqual(@as(u32, 64), U64.ZERO.leading_zeros());
    try testing.expectEqual(@as(u32, 60), U64.from_u64(8).leading_zeros());
    try testing.expectEqual(@as(usize, 4), U64.from_u64(8).bit_len());

    const U256 = Uint(256, 4);
    try testing.expectEqual(@as(u32, 256), U256.ZERO.leading_zeros());
    try testing.expectEqual(@as(u32, 255), U256.ONE.leading_zeros());
    try testing.expectEqual(@as(usize, 129), U256.from_native(@as(u256, 1) << 128).bit_len());

    // Widths that do not fill the top limb.
    const U8 = Uint(8, 1);
    try testing.expectEqual(@as(u32, 8), U8.ZERO.leading_zeros());
    try testing.expectEqual(@as(u32, 0), U8.from_u64(0x80).leading_zeros());
    const U100 = Uint(100, 2);
    try testing.expectEqual(@as(u32, 100), U100.ZERO.leading_zeros());
    try testing.expectEqual(@as(u32, 35), U100.from_native(@as(u256, 1) << 64).leading_zeros());
}
