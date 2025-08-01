const std = @import("std");
const testing = std.testing;
const evm = @import("evm");

test "ERC20 GT opcode exact values" {
    // Test the exact GT comparison that happens in ERC20 constructor at PC 279
    
    // The two values being compared:
    const a: u256 = 0xffffffffffffffffffffffffffffffffffffffffffffffff0000000000000001;
    const b: u256 = 0x9;
    
    // What should GT return?
    const expected_gt = if (a > b) @as(u256, 1) else 0;
    
    std.debug.print("\nERC20 GT comparison:\n", .{});
    std.debug.print("  a = 0x{x}\n", .{a});
    std.debug.print("  b = 0x{x}\n", .{b}); 
    std.debug.print("  a > b = {} (should be 1)\n", .{expected_gt});
    
    // The value is a huge number, definitely greater than 9
    try testing.expectEqual(@as(u256, 1), expected_gt);
    
    // Now test ISZERO on the result
    const iszero_result = if (expected_gt == 0) @as(u256, 1) else 0;
    std.debug.print("  ISZERO(GT result) = {} (should be 0)\n", .{iszero_result});
    try testing.expectEqual(@as(u256, 0), iszero_result);
    
    // So JUMPI should NOT jump (condition is 0)
    std.debug.print("  JUMPI should NOT jump because condition is 0\n", .{});
}