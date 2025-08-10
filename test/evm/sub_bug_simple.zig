const std = @import("std");

test "SUB opcode calculation bug" {
    // This reproduces the exact calculation that fails in ERC20
    const a: u256 = 0x10000000000000000; // (1 << 64)
    const b: u256 = 0x1;

    const result = a -% b; // Wrapping subtraction
    const expected: u256 = 0xffffffffffffffff;

    std.debug.print("\nSUB operation test:\n", .{});
    std.debug.print("  a = 0x{x}\n", .{a});
    std.debug.print("  b = 0x{x}\n", .{b});
    std.debug.print("  a - b = 0x{x}\n", .{result});
    std.debug.print("  Expected: 0x{x}\n", .{expected});
    std.debug.print("  Correct: {}\n", .{result == expected});

    try std.testing.expectEqual(expected, result);
}
