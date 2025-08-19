const std = @import("std");

test "SUB opcode calculation bug" {
    // This reproduces the exact calculation that fails in ERC20
    const a: u256 = 0x10000000000000000;  // (1 << 64)
    const b: u256 = 0x1;
    
    const result = a -% b;  // Wrapping subtraction
    const expected: u256 = 0xffffffffffffffff;
    
    
    try std.testing.expectEqual(expected, result);
}