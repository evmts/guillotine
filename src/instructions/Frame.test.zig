/// Tests for shared Frame implementation
/// Phase 1.1 - Foundation tests for minimal frame with stack
const std = @import("std");
const testing = std.testing;
const Frame = @import("Frame.zig");
const Stack = @import("Stack.zig");

test "Frame: init creates frame with empty stack" {
    const allocator = testing.allocator;
    var frame = try Frame.init(allocator);
    defer frame.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), frame.stack.len());
}

test "Frame: stack operations through frame" {
    const allocator = testing.allocator;
    var frame = try Frame.init(allocator);
    defer frame.deinit(allocator);

    try frame.stack.push(100);
    try frame.stack.push(200);

    try testing.expectEqual(@as(usize, 2), frame.stack.len());
    try testing.expectEqual(@as(u256, 200), try frame.stack.pop());
    try testing.expectEqual(@as(u256, 100), try frame.stack.pop());
}

test "Frame: Error union matches stack errors" {
    const allocator = testing.allocator;
    var frame = try Frame.init(allocator);
    defer frame.deinit(allocator);

    // Test that Frame.Error contains stack errors
    const result = frame.stack.pop();
    try testing.expectError(error.StackUnderflow, result);
}
