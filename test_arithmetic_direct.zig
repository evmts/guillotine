const std = @import("std");

test "test arithmetic operation directly" {
    // Test the basic arithmetic that the ADD opcode does
    const a: u256 = 42;
    const b: u256 = 42;
    const result = a +% b;
    
    std.log.debug("Direct arithmetic: {} + {} = {}", .{a, b, result});
    try std.testing.expectEqual(@as(u256, 84), result);
    
    std.log.debug("Basic arithmetic works fine", .{});
}