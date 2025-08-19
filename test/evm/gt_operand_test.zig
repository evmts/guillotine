const std = @import("std");
const testing = std.testing;

test "GT operand order check" {
    // Stack before GT: [..., 0x9, 0xffffffffffffffff, 0x9]
    // Top of stack: 0x9
    // Second from top: 0xffffffffffffffff
    
    const top: u256 = 0x9;
    const second: u256 = 0xffffffffffffffff;
    
    // Our implementation: second > top
    const our_result = if (second > top) @as(u256, 1) else 0;
    
    // REVM result is 0, which means it's doing: top > second
    const revm_style = if (top > second) @as(u256, 1) else 0;
    
    // Verify
    try testing.expectEqual(@as(u256, 0), revm_style);
}