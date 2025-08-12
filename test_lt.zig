const std = @import("std");

pub fn main() \!void {
    // Test case: 5 < 10 should be 1
    const a: u256 = 5;
    const b: u256 = 10;
    
    // Our implementation: second_from_top < top
    const our_result = if (a < b) @as(u256, 1) else @as(u256, 0);
    
    // Reverse: top < second_from_top  
    const reverse_result = if (b < a) @as(u256, 1) else @as(u256, 0);
    
    std.debug.print("Stack: [5, 10] with 10 on top\n", .{});
    std.debug.print("Our LT (5 < 10): {}\n", .{our_result});
    std.debug.print("Reverse LT (10 < 5): {}\n", .{reverse_result});
}
