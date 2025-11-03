/// Tests for shared Stack implementation
/// Phase 1.1 - Foundation tests for stack operations
const std = @import("std");
const testing = std.testing;
const Stack = @import("Stack.zig");

test "Stack: init creates empty stack" {
    const allocator = testing.allocator;
    var stack = try Stack.init(allocator);
    defer stack.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), stack.len());
}

test "Stack: push and pop single value" {
    const allocator = testing.allocator;
    var stack = try Stack.init(allocator);
    defer stack.deinit(allocator);

    try stack.push(42);
    try testing.expectEqual(@as(usize, 1), stack.len());

    const value = try stack.pop();
    try testing.expectEqual(@as(u256, 42), value);
    try testing.expectEqual(@as(usize, 0), stack.len());
}

test "Stack: peek returns top without removing" {
    const allocator = testing.allocator;
    var stack = try Stack.init(allocator);
    defer stack.deinit(allocator);

    try stack.push(100);
    try stack.push(200);

    const top = try stack.peek();
    try testing.expectEqual(@as(u256, 200), top);
    try testing.expectEqual(@as(usize, 2), stack.len());
}

test "Stack: set_top modifies top value" {
    const allocator = testing.allocator;
    var stack = try Stack.init(allocator);
    defer stack.deinit(allocator);

    try stack.push(100);
    try stack.set_top(999);

    const top = try stack.peek();
    try testing.expectEqual(@as(u256, 999), top);
    try testing.expectEqual(@as(usize, 1), stack.len());
}

test "Stack: underflow errors on empty pop" {
    const allocator = testing.allocator;
    var stack = try Stack.init(allocator);
    defer stack.deinit(allocator);

    const result = stack.pop();
    try testing.expectError(error.StackUnderflow, result);
}

test "Stack: underflow errors on empty peek" {
    const allocator = testing.allocator;
    var stack = try Stack.init(allocator);
    defer stack.deinit(allocator);

    const result = stack.peek();
    try testing.expectError(error.StackUnderflow, result);
}

test "Stack: underflow errors on empty set_top" {
    const allocator = testing.allocator;
    var stack = try Stack.init(allocator);
    defer stack.deinit(allocator);

    const result = stack.set_top(42);
    try testing.expectError(error.StackUnderflow, result);
}

test "Stack: overflow at 1024 limit" {
    const allocator = testing.allocator;
    var stack = try Stack.init(allocator);
    defer stack.deinit(allocator);

    // Fill stack to capacity (1024)
    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        try stack.push(@as(u256, @intCast(i)));
    }

    // Next push should fail
    const result = stack.push(9999);
    try testing.expectError(error.StackOverflow, result);
}

test "Stack: LIFO order (push multiple, pop in reverse)" {
    const allocator = testing.allocator;
    var stack = try Stack.init(allocator);
    defer stack.deinit(allocator);

    try stack.push(1);
    try stack.push(2);
    try stack.push(3);

    try testing.expectEqual(@as(u256, 3), try stack.pop());
    try testing.expectEqual(@as(u256, 2), try stack.pop());
    try testing.expectEqual(@as(u256, 1), try stack.pop());
}
