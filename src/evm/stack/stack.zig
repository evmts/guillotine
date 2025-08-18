const std = @import("std");
const builtin = @import("builtin");
const stack_constants = @import("../constants/stack_constants.zig");

const CLEAR_ON_POP = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
pub const CAPACITY: usize = stack_constants.CAPACITY;

pub const Stack = @This();

const Pop2 = struct { a: u256, b: u256 };
const Pop3 = struct { a: u256, b: u256, c: u256 };

pub const Error = error{
    StackOverflow,
    StackUnderflow,
};

current: [*]u256,
base: [*]u256,
limit: [*]u256,

data: *[CAPACITY]u256,

pub fn init(allocator: std.mem.Allocator) !Stack {
    const data: *[CAPACITY]u256 = try allocator.create([CAPACITY]u256);
    errdefer allocator.free(data);
    const base: [*]u256 = @ptrCast(&data[0]);
    return Stack{
        .data = data,
        .current = base,
        .base = base,
        .limit = base + CAPACITY,
    };
}

pub fn deinit(self: *Stack, allocator: std.mem.Allocator) void {
    allocator.free(self.data);
}

pub fn clear(self: *Stack) void {
    self.debug_is_in_bounds();
    self.current = self.base;
    if (comptime CLEAR_ON_POP) {
        @memset(std.mem.sliceAsBytes(self.data), 0);
    }
    self.debug_is_in_bounds();
}

pub fn size(self: *const Stack) usize {
    self.debug_is_in_bounds();
    return (@intFromPtr(self.current) - @intFromPtr(self.base)) / @sizeOf(u256);
}

pub fn is_empty(self: *const Stack) bool {
    self.debug_is_in_bounds();
    return self.current == self.base;
}

pub fn is_full(self: *const Stack) bool {
    self.debug_is_in_bounds();
    return @intFromPtr(self.current) >= @intFromPtr(self.limit);
}

pub fn debug_is_in_bounds(self: *const Stack) void {
    std.debug.assert(@intFromPtr(self.current) >= @intFromPtr(self.base));
    std.debug.assert(@intFromPtr(self.current) <= @intFromPtr(self.limit));
}

pub fn append(self: *Stack, value: u256) Error!void {
    if (@intFromPtr(self.current) >= @intFromPtr(self.limit)) {
        @branchHint(.cold);
        return Error.StackOverflow;
    }
    self.append_unsafe(value);
}
pub fn append_unsafe(self: *Stack, value: u256) void {
    self.debug_is_in_bounds();
    self.current[0] = value;
    self.current += 1;
    self.debug_is_in_bounds();
}

pub fn pop(self: *Stack) Error!u256 {
    if (@intFromPtr(self.current) <= @intFromPtr(self.base)) {
        @branchHint(.cold);
        return Error.StackUnderflow;
    }
    return self.pop_unsafe();
}
pub fn pop_unsafe(self: *Stack) u256 {
    self.debug_is_in_bounds();
    self.current -= 1;
    const value = self.current[0];
    if (comptime CLEAR_ON_POP) self.current[0] = 0;
    self.debug_is_in_bounds();
    return value;
}

pub fn dup(self: *Stack, n: usize) Error!void {
    if (n == 0) {
        @branchHint(.cold);
        return Error.StackUnderflow;
    }
    if (@intFromPtr(self.current) >= @intFromPtr(self.limit)) {
        @branchHint(.cold);
        return Error.StackOverflow;
    }
    self.dup_unsafe(n);
}
pub fn dup_unsafe(self: *Stack, n: usize) void {
    self.debug_is_in_bounds();
    const value = (self.current - n)[0];
    self.append_unsafe(value);
    self.debug_is_in_bounds();
}

pub fn pop2(self: *Stack) Error!Pop2 {
    const cur_size = (@intFromPtr(self.current) - @intFromPtr(self.base)) / @sizeOf(u256);
    if (cur_size < 2) {
        @branchHint(.cold);
        return Error.StackUnderflow;
    }
    return self.pop2_unsafe();
}
pub fn pop2_unsafe(self: *Stack) Pop2 {
    self.debug_is_in_bounds();
    self.current -= 2;
    const top_minus_1 = self.current[0];
    const top = self.current[1];
    if (comptime CLEAR_ON_POP) {
        self.current[0] = 0;
        self.current[1] = 0;
    }
    return .{ .a = top_minus_1, .b = top };
}

pub fn pop3(self: *Stack) Error!Pop3 {
    self.debug_is_in_bounds();
    const cur_size = (@intFromPtr(self.current) - @intFromPtr(self.base)) / @sizeOf(u256);
    if (cur_size < 3) {
        @branchHint(.cold);
        return Error.StackUnderflow;
    }
    return self.pop3_unsafe();
}
pub fn pop3_unsafe(self: *Stack) Pop3 {
    self.debug_is_in_bounds();
    self.current -= 3;
    const top_minus_2 = self.current[0];
    const top_minus_1 = self.current[1];
    const top = self.current[2];
    if (comptime CLEAR_ON_POP) {
        self.current[0] = 0;
        self.current[1] = 0;
        self.current[2] = 0;
    }
    return .{ .a = top_minus_2, .b = top_minus_1, .c = top };
}

pub fn set_top(self: *Stack, value: u256) Error!void {
    if (@intFromPtr(self.current) <= @intFromPtr(self.base)) {
        @branchHint(.cold);
        return Error.StackUnderflow;
    }
    (self.current - 1)[0] = value;
}
pub fn set_top_unsafe(self: *Stack, value: u256) void {
    self.debug_is_in_bounds();
    (self.current - 1)[0] = value;
}

/// Safely set the logical size of the stack to `new_size` elements.
/// Returns StackOverflow if `new_size` exceeds capacity.
pub fn set_size(self: *Stack, new_size: usize) Error!void {
    if (new_size > CAPACITY) {
        @branchHint(.cold);
        return Error.StackOverflow;
    }
    self.set_size_unsafe(new_size);
}

/// Unsafely set the logical size of the stack to `new_size` elements.
/// Preconditions: new_size <= CAPACITY
pub fn set_size_unsafe(self: *Stack, new_size: usize) void {
    // Clamp to capacity in debug builds
    if (comptime builtin.mode != .ReleaseFast and builtin.mode != .ReleaseSmall) {
        std.debug.assert(new_size <= CAPACITY);
    }

    const previous_size = self.size();
    const new_current: [*]u256 = self.base + new_size;

    // If we're shrinking and clearing is enabled, zero the removed slots
    if (comptime CLEAR_ON_POP) {
        if (new_size < previous_size) {
            const start = self.base + new_size;
            const count = previous_size - new_size;
            @memset(std.mem.sliceAsBytes(start[0..count]), 0);
        }
    }

    self.current = new_current;
}

pub fn swap(self: *Stack, n: usize) Error!void {
    if (n < 1) {
        @branchHint(.cold);
        return Error.StackUnderflow;
    }
    self.swap_unsafe(n);
}
pub fn swap_unsafe(self: *Stack, n: usize) void {
    self.debug_is_in_bounds();
    std.mem.swap(u256, &(self.current - 1)[0], &(self.current - 1 - n)[0]);
}

pub fn peek_n(self: *const Stack, n: usize) Error!u256 {
    const stack_size = self.size();
    if (n >= stack_size) {
        @branchHint(.cold);
        return Error.StackUnderflow;
    }
    return self.peek_n_unsafe(n);
}
pub fn peek_n_unsafe(self: *const Stack, n: usize) u256 {
    self.debug_is_in_bounds();
    return (self.current - 1 - n)[0];
}

pub fn peek(self: *const Stack) Error!u256 {
    return self.peek_n(0);
}
pub fn peek_unsafe(self: *const Stack) u256 {
    return self.peek_n_unsafe(0);
}

pub fn fuzz_stack_operations(allocator: std.mem.Allocator, operations: []const FuzzOperation) !void {
    var stack = try Stack.init(allocator);
    defer stack.deinit(std.testing.allocator);
    const testing = std.testing;

    for (operations) |op| {
        switch (op) {
            .push => |value| {
                const old_size = stack.size();
                const result = stack.append(value);

                if (old_size < CAPACITY) {
                    try result;
                    try testing.expectEqual(old_size + 1, stack.size());
                    try testing.expectEqual(value, (stack.current - 1)[0]);
                } else {
                    try testing.expectError(Error.StackOverflow, result);
                    try testing.expectEqual(old_size, stack.size());
                }
            },
            .pop => {
                const old_size = stack.size();
                const result = stack.pop();

                if (old_size > 0) {
                    _ = try result;
                    try testing.expectEqual(old_size - 1, stack.size());
                } else {
                    try testing.expectError(Error.StackUnderflow, result);
                    try testing.expectEqual(@as(usize, 0), stack.size());
                }
            },
            .peek => {
                const result = stack.peek();
                if (stack.size() > 0) {
                    const value = try result;
                    try testing.expectEqual((stack.current - 1)[0], value);
                } else {
                    try testing.expectError(Error.StackUnderflow, result);
                }
            },
            .clear => {
                stack.clear();
                try testing.expectEqual(@as(usize, 0), stack.size());
            },
        }

        try validate_stack_invariants(&stack);
    }
}

const FuzzOperation = union(enum) {
    push: u256,
    pop: void,
    peek: void,
    clear: void,
};

fn validate_stack_invariants(stack: *const Stack) !void {
    const testing = std.testing;

    // Check pointer relationships
    try testing.expect(@intFromPtr(stack.current) >= @intFromPtr(stack.base));
    try testing.expect(@intFromPtr(stack.current) <= @intFromPtr(stack.limit));
    try testing.expect(stack.size() <= CAPACITY);
}

test "fuzz_stack_basic_operations" {
    const operations = [_]FuzzOperation{
        .{ .push = 100 },
        .{ .push = 200 },
        .{ .peek = {} },
        .{ .pop = {} },
        .{ .pop = {} },
        .{ .pop = {} },
        .clear,
        .{ .push = 42 },
    };

    try fuzz_stack_operations(std.testing.allocator, &operations);
}

test "fuzz_stack_overflow_boundary" {
    var operations = std.ArrayList(FuzzOperation).init(std.testing.allocator);
    defer operations.deinit();

    var i: usize = 0;
    while (i <= CAPACITY + 10) : (i += 1) {
        try operations.append(.{ .push = @as(u256, i) });
    }

    try fuzz_stack_operations(std.testing.allocator, operations.items);
}

test "fuzz_stack_underflow_boundary" {
    const operations = [_]FuzzOperation{
        .{ .pop = {} },
        .{ .pop = {} },
        .{ .peek = {} },
        .{ .push = 1 },
        .{ .pop = {} },
        .{ .pop = {} },
    };

    try fuzz_stack_operations(std.testing.allocator, &operations);
}

test "pointer_arithmetic_correctness" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // Test initial state
    try std.testing.expectEqual(@as(usize, 0), stack.size());
    try std.testing.expect(stack.is_empty());
    try std.testing.expect(!stack.is_full());

    // Test single push
    stack.append_unsafe(42);
    try std.testing.expectEqual(@as(usize, 1), stack.size());
    try std.testing.expect(!stack.is_empty());
    try std.testing.expectEqual(@as(u256, 42), stack.peek_unsafe());

    // Test multiple pushes
    stack.append_unsafe(100);
    stack.append_unsafe(200);
    try std.testing.expectEqual(@as(usize, 3), stack.size());
    try std.testing.expectEqual(@as(u256, 200), stack.peek_unsafe());

    // Test pop
    const popped = stack.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 200), popped);
    try std.testing.expectEqual(@as(usize, 2), stack.size());
    try std.testing.expectEqual(@as(u256, 100), stack.peek_unsafe());
}

test "stack_dup_operations" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    stack.append_unsafe(100);
    stack.append_unsafe(200);
    stack.append_unsafe(300);

    stack.dup_unsafe(1);
    try std.testing.expectEqual(@as(usize, 4), stack.size());
    try std.testing.expectEqual(@as(u256, 300), stack.peek_unsafe());

    stack.dup_unsafe(2);
    try std.testing.expectEqual(@as(usize, 5), stack.size());
    try std.testing.expectEqual(@as(u256, 300), stack.peek_unsafe());
}

test "stack_swap_operations" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    stack.append_unsafe(100);
    stack.append_unsafe(200);
    stack.append_unsafe(300);

    // Before swap: [100, 200, 300] (300 on top)
    stack.swap_unsafe(1);
    // After SWAP1: [100, 300, 200] (200 on top)

    try std.testing.expectEqual(@as(u256, 200), (stack.current - 1)[0]); // top
    try std.testing.expectEqual(@as(u256, 300), (stack.current - 2)[0]); // second
    try std.testing.expectEqual(@as(u256, 100), (stack.current - 3)[0]); // bottom
}

test "stack_multi_pop_operations" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    stack.append_unsafe(100);
    stack.append_unsafe(200);
    stack.append_unsafe(300);
    stack.append_unsafe(400);
    stack.append_unsafe(500);

    const result2 = stack.pop2_unsafe();
    try std.testing.expectEqual(@as(u256, 400), result2.a);
    try std.testing.expectEqual(@as(u256, 500), result2.b);
    try std.testing.expectEqual(@as(usize, 3), stack.size());

    const result3 = stack.pop3_unsafe();
    try std.testing.expectEqual(@as(u256, 100), result3.a);
    try std.testing.expectEqual(@as(u256, 200), result3.b);
    try std.testing.expectEqual(@as(u256, 300), result3.c);
    try std.testing.expectEqual(@as(usize, 0), stack.size());
}

test "performance_comparison_pointer_vs_indexing" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // Fill stack for testing
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        stack.append_unsafe(i);
    }

    const Timer = std.time.Timer;
    var timer = try Timer.start();

    // Test pointer arithmetic performance
    timer.reset();
    i = 0;
    while (i < 1000000) : (i += 1) {
        if (stack.size() < CAPACITY / 2) {
            stack.append_unsafe(i);
        } else {
            _ = stack.pop_unsafe();
        }
    }
    const pointer_time = timer.read();

    // Verify pointer approach completed
    try std.testing.expect(pointer_time > 0);

    std.debug.print("Pointer-based stack operations: {} ns for 1M ops\n", .{pointer_time});
}

test "memory_layout_verification" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // Verify pointer setup
    try std.testing.expectEqual(@intFromPtr(stack.base), @intFromPtr(&stack.data[0]));
    try std.testing.expectEqual(@intFromPtr(stack.current), @intFromPtr(stack.base));
    try std.testing.expectEqual(@intFromPtr(stack.limit), @intFromPtr(stack.base + CAPACITY));

    // Verify data layout
    const data_ptr = @intFromPtr(&stack.data[0]);
    try std.testing.expectEqual(@as(usize, 0), data_ptr % @alignOf(u256));

    // Test that pointers are at start of struct for cache efficiency
    const stack_ptr = @intFromPtr(&stack);
    const current_ptr = @intFromPtr(&stack.current);
    try std.testing.expectEqual(stack_ptr, current_ptr);
}

// ============================================================================
// COMPREHENSIVE TESTS FOR STACK MODULE
// ============================================================================

test "stack_boundary_empty" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // Test empty stack state
    try std.testing.expectEqual(@as(usize, 0), stack.size());
    try std.testing.expect(stack.is_empty());
    try std.testing.expect(!stack.is_full());

    // Test operations on empty stack
    try std.testing.expectError(Error.StackUnderflow, stack.pop());
    try std.testing.expectError(Error.StackUnderflow, stack.peek());
    try std.testing.expectError(Error.StackUnderflow, stack.peek_n(0));

    // Verify stack remains empty after failed operations
    try std.testing.expectEqual(@as(usize, 0), stack.size());
    try std.testing.expect(stack.is_empty());
}

test "stack_boundary_single_element" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // Push single element
    try stack.append(42);
    try std.testing.expectEqual(@as(usize, 1), stack.size());
    try std.testing.expect(!stack.is_empty());
    try std.testing.expect(!stack.is_full());

    // Peek operations
    try std.testing.expectEqual(@as(u256, 42), try stack.peek());
    try std.testing.expectEqual(@as(u256, 42), try stack.peek_n(0));
    try std.testing.expectError(Error.StackUnderflow, stack.peek_n(1));

    // Pop the element
    try std.testing.expectEqual(@as(u256, 42), try stack.pop());
    try std.testing.expectEqual(@as(usize, 0), stack.size());
    try std.testing.expect(stack.is_empty());
}

test "stack_boundary_near_capacity" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // Fill stack to capacity - 1 (1023 elements)
    var i: usize = 0;
    while (i < CAPACITY - 1) : (i += 1) {
        try stack.append(@as(u256, i));
    }

    try std.testing.expectEqual(@as(usize, 1023), stack.size());
    try std.testing.expect(!stack.is_empty());
    try std.testing.expect(!stack.is_full());

    // Add one more to reach capacity
    try stack.append(1023);
    try std.testing.expectEqual(@as(usize, 1024), stack.size());
    try std.testing.expect(!stack.is_empty());
    try std.testing.expect(stack.is_full());

    // Verify cannot exceed capacity
    try std.testing.expectError(Error.StackOverflow, stack.append(1024));
    try std.testing.expectEqual(@as(usize, 1024), stack.size());
}

test "stack_boundary_at_capacity" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // Fill stack to exact capacity
    var i: usize = 0;
    while (i < CAPACITY) : (i += 1) {
        try stack.append(@as(u256, i));
    }

    try std.testing.expectEqual(@as(usize, 1024), stack.size());
    try std.testing.expect(!stack.is_empty());
    try std.testing.expect(stack.is_full());

    // Verify overflow protection
    try std.testing.expectError(Error.StackOverflow, stack.append(9999));

    // Verify can still pop
    try std.testing.expectEqual(@as(u256, 1023), try stack.pop());
    try std.testing.expectEqual(@as(usize, 1023), stack.size());
    try std.testing.expect(!stack.is_full());

    // Verify can push again after pop
    try stack.append(9999);
    try std.testing.expectEqual(@as(usize, 1024), stack.size());
    try std.testing.expect(stack.is_full());
}

test "stack_error_conditions_comprehensive" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // Underflow on empty stack
    try std.testing.expectError(Error.StackUnderflow, stack.pop());
    try std.testing.expectError(Error.StackUnderflow, stack.peek());

    // Push and pop cycle
    try stack.append(100);
    try std.testing.expectEqual(@as(u256, 100), try stack.pop());

    // Underflow after becoming empty
    try std.testing.expectError(Error.StackUnderflow, stack.pop());

    // Fill to capacity
    var i: usize = 0;
    while (i < CAPACITY) : (i += 1) {
        try stack.append(@as(u256, i));
    }

    // Overflow at capacity
    try std.testing.expectError(Error.StackOverflow, stack.append(9999));

    // Clear and test underflow again
    stack.clear();
    try std.testing.expectError(Error.StackUnderflow, stack.pop());
}

test "stack_dup_comprehensive_DUP1_to_DUP16" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // Setup stack with values 1-16 (bottom to top)
    var i: usize = 1;
    while (i <= 16) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }

    // Test DUP1 (duplicate top)
    stack.dup_unsafe(1);
    try std.testing.expectEqual(@as(u256, 16), stack.pop_unsafe());
    try std.testing.expectEqual(@as(u256, 16), stack.pop_unsafe());

    // Restore stack
    stack.append_unsafe(16);

    // Test DUP2 (duplicate second from top)
    stack.dup_unsafe(2);
    try std.testing.expectEqual(@as(u256, 15), stack.pop_unsafe());

    // Test DUP16 (duplicate 16th from top)
    stack.dup_unsafe(16);
    try std.testing.expectEqual(@as(u256, 1), stack.pop_unsafe());

    // Verify stack size after operations
    try std.testing.expectEqual(@as(usize, 16), stack.size());
}

test "stack_dup_edge_cases" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // DUP with minimal stack
    stack.append_unsafe(42);
    stack.dup_unsafe(1);
    try std.testing.expectEqual(@as(u256, 42), stack.pop_unsafe());
    try std.testing.expectEqual(@as(u256, 42), stack.pop_unsafe());

    // DUP at near capacity
    var i: usize = 0;
    while (i < CAPACITY - 1) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }

    // Should succeed - one slot left
    stack.dup_unsafe(1);
    try std.testing.expectEqual(@as(usize, CAPACITY), stack.size());
    try std.testing.expect(stack.is_full());
}

test "stack_swap_comprehensive_SWAP1_to_SWAP16" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // Setup stack with values 1-17
    var i: usize = 1;
    while (i <= 17) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }

    // Test SWAP1 (swap top with second)
    // Before: [..., 16, 17] -> After: [..., 17, 16]
    stack.swap_unsafe(1);
    try std.testing.expectEqual(@as(u256, 16), stack.pop_unsafe());
    try std.testing.expectEqual(@as(u256, 17), stack.pop_unsafe());

    // Restore for next test
    stack.append_unsafe(16);
    stack.append_unsafe(17);

    // Test SWAP16 (swap top with 17th element)
    // Top is at position 17, swap with position 1
    stack.swap_unsafe(16);
    try std.testing.expectEqual(@as(u256, 1), stack.pop_unsafe());

    // Verify element at bottom
    while (stack.size() > 1) {
        _ = stack.pop_unsafe();
    }
    try std.testing.expectEqual(@as(u256, 17), stack.pop_unsafe());
}

test "stack_swap_edge_cases" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // SWAP1 with exactly 2 elements
    stack.append_unsafe(100);
    stack.append_unsafe(200);
    stack.swap_unsafe(1);
    try std.testing.expectEqual(@as(u256, 100), stack.pop_unsafe());
    try std.testing.expectEqual(@as(u256, 200), stack.pop_unsafe());

    // SWAP with same value
    stack.append_unsafe(42);
    stack.append_unsafe(42);
    stack.swap_unsafe(1);
    try std.testing.expectEqual(@as(u256, 42), stack.pop_unsafe());
    try std.testing.expectEqual(@as(u256, 42), stack.pop_unsafe());
}

test "stack_pop2_unsafe_edge_cases" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // Test with exactly 2 elements
    stack.append_unsafe(100);
    stack.append_unsafe(200);
    const result = stack.pop2_unsafe();
    try std.testing.expectEqual(@as(u256, 100), result.a);
    try std.testing.expectEqual(@as(u256, 200), result.b);
    try std.testing.expectEqual(@as(usize, 0), stack.size());

    // Test with more than 2 elements
    stack.append_unsafe(1);
    stack.append_unsafe(2);
    stack.append_unsafe(3);
    stack.append_unsafe(4);
    const result2 = stack.pop2_unsafe();
    try std.testing.expectEqual(@as(u256, 3), result2.a);
    try std.testing.expectEqual(@as(u256, 4), result2.b);
    try std.testing.expectEqual(@as(usize, 2), stack.size());

    // Verify remaining elements
    try std.testing.expectEqual(@as(u256, 2), stack.pop_unsafe());
    try std.testing.expectEqual(@as(u256, 1), stack.pop_unsafe());
}

test "stack_pop3_unsafe_edge_cases" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // Test with exactly 3 elements
    stack.append_unsafe(100);
    stack.append_unsafe(200);
    stack.append_unsafe(300);
    const result = stack.pop3_unsafe();
    try std.testing.expectEqual(@as(u256, 100), result.a);
    try std.testing.expectEqual(@as(u256, 200), result.b);
    try std.testing.expectEqual(@as(u256, 300), result.c);
    try std.testing.expectEqual(@as(usize, 0), stack.size());

    // Test with more than 3 elements
    stack.append_unsafe(1);
    stack.append_unsafe(2);
    stack.append_unsafe(3);
    stack.append_unsafe(4);
    stack.append_unsafe(5);
    const result2 = stack.pop3_unsafe();
    try std.testing.expectEqual(@as(u256, 3), result2.a);
    try std.testing.expectEqual(@as(u256, 4), result2.b);
    try std.testing.expectEqual(@as(u256, 5), result2.c);
    try std.testing.expectEqual(@as(usize, 2), stack.size());

    // Verify remaining elements
    try std.testing.expectEqual(@as(u256, 2), stack.pop_unsafe());
    try std.testing.expectEqual(@as(u256, 1), stack.pop_unsafe());
}

test "stack_set_top_unsafe" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // Test with single element
    stack.append_unsafe(100);
    stack.set_top_unsafe(200);
    try std.testing.expectEqual(@as(u256, 200), stack.pop_unsafe());

    // Test with multiple elements
    stack.append_unsafe(1);
    stack.append_unsafe(2);
    stack.append_unsafe(3);
    stack.set_top_unsafe(999);
    try std.testing.expectEqual(@as(u256, 999), stack.pop_unsafe());
    try std.testing.expectEqual(@as(u256, 2), stack.pop_unsafe());
    try std.testing.expectEqual(@as(u256, 1), stack.pop_unsafe());
}

test "stack_peek_n_comprehensive" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // Setup stack with values 0-9
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }

    // Test peek_n for all valid positions
    i = 0;
    while (i < 10) : (i += 1) {
        try std.testing.expectEqual(@as(u256, 9 - i), try stack.peek_n(i));
    }

    // Test underflow
    try std.testing.expectError(Error.StackUnderflow, stack.peek_n(10));
    try std.testing.expectError(Error.StackUnderflow, stack.peek_n(100));

    // Verify stack unchanged
    try std.testing.expectEqual(@as(usize, 10), stack.size());
}

test "stack_clear_behavior" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // Fill with data
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }

    try std.testing.expectEqual(@as(usize, 100), stack.size());

    // Clear and verify
    stack.clear();
    try std.testing.expectEqual(@as(usize, 0), stack.size());
    try std.testing.expect(stack.is_empty());
    try std.testing.expect(!stack.is_full());

    // Verify can use after clear
    try stack.append(42);
    try std.testing.expectEqual(@as(u256, 42), try stack.pop());

    // Multiple clears
    stack.clear();
    stack.clear(); // Should be idempotent
    try std.testing.expectEqual(@as(usize, 0), stack.size());
}

test "stack_memory_cleanup_verification" {
    if (comptime !CLEAR_ON_POP) {
        return; // Skip test in release mode
    }

    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // Push sensitive value
    const sensitive_value: u256 = 0xDEADBEEFCAFEBABE;
    stack.append_unsafe(sensitive_value);

    // Pop and verify cleanup
    _ = stack.pop_unsafe();

    // Check that the memory was cleared (in debug/safe modes)
    const cleared_value = stack.base[0];
    try std.testing.expectEqual(@as(u256, 0), cleared_value);

    // Test pop2_unsafe cleanup
    stack.append_unsafe(0x1111);
    stack.append_unsafe(0x2222);
    _ = stack.pop2_unsafe();
    try std.testing.expectEqual(@as(u256, 0), stack.base[0]);
    try std.testing.expectEqual(@as(u256, 0), stack.base[1]);

    // Test pop3_unsafe cleanup
    stack.append_unsafe(0x3333);
    stack.append_unsafe(0x4444);
    stack.append_unsafe(0x5555);
    _ = stack.pop3_unsafe();
    try std.testing.expectEqual(@as(u256, 0), stack.base[0]);
    try std.testing.expectEqual(@as(u256, 0), stack.base[1]);
    try std.testing.expectEqual(@as(u256, 0), stack.base[2]);
}

test "stack_set_size_unsafe" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // Test setting various sizes
    stack.set_size_unsafe(0);
    try std.testing.expectEqual(@as(usize, 0), stack.size());

    stack.set_size_unsafe(10);
    try std.testing.expectEqual(@as(usize, 10), stack.size());

    stack.set_size_unsafe(CAPACITY);
    try std.testing.expectEqual(@as(usize, CAPACITY), stack.size());
    try std.testing.expect(stack.is_full());

    stack.set_size_unsafe(0);
    try std.testing.expect(stack.is_empty());
}

test "stack_alternating_operations_stress" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // Stress test with alternating operations
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        // Push batch
        var j: usize = 0;
        while (j < 10 and stack.size() < CAPACITY) : (j += 1) {
            stack.append_unsafe(@as(u256, i * 10 + j));
        }

        // Pop some
        j = 0;
        while (j < 5 and !stack.is_empty()) : (j += 1) {
            _ = stack.pop_unsafe();
        }

        // Dup if possible
        if (stack.size() > 0 and stack.size() < CAPACITY) {
            stack.dup_unsafe(1);
        }

        // Swap if we have at least 2 elements
        if (stack.size() >= 2) {
            stack.swap_unsafe(1);
        }
    }

    // Verify stack is still valid
    try validate_stack_invariants(&stack);
}

test "stack_unsafe_operations_preconditions" {
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // Setup for unsafe operations
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        stack.append_unsafe(@as(u256, i));
    }

    // Test all unsafe operations work correctly with valid preconditions
    const peek_val = try stack.peek_unsafe();
    try std.testing.expectEqual(@as(u256, 19), peek_val);

    stack.set_top_unsafe(999);
    try std.testing.expectEqual(@as(u256, 999), try stack.peek_unsafe());

    stack.dup_unsafe(10);
    try std.testing.expectEqual(@as(u256, 999), stack.pop_unsafe());
    try std.testing.expectEqual(@as(u256, 999), stack.pop_unsafe());

    stack.swap_unsafe(5);
    const top = stack.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 13), top);
}

test "stack_concurrent_safety_simulation" {
    // This test simulates what would happen with concurrent access
    // Note: Stack is not thread-safe, this just tests state consistency
    var stack = try Stack.init(std.testing.allocator);
    defer stack.deinit(std.testing.allocator);

    // Simulate interleaved operations
    const operations = [_]struct { op: enum { push, pop, dup, swap }, val: u256 }{
        .{ .op = .push, .val = 1 },
        .{ .op = .push, .val = 2 },
        .{ .op = .push, .val = 3 },
        .{ .op = .dup, .val = 1 },
        .{ .op = .swap, .val = 1 },
        .{ .op = .pop, .val = 0 },
        .{ .op = .push, .val = 4 },
        .{ .op = .pop, .val = 0 },
    };

    for (operations) |op| {
        switch (op.op) {
            .push => stack.append_unsafe(op.val),
            .pop => {
                if (!stack.is_empty()) {
                    _ = stack.pop_unsafe();
                }
            },
            .dup => {
                if (stack.size() >= op.val and stack.size() < CAPACITY) {
                    stack.dup_unsafe(@intCast(op.val));
                }
            },
            .swap => {
                if (stack.size() > op.val) {
                    stack.swap_unsafe(@intCast(op.val));
                }
            },
        }

        // Verify invariants after each operation
        try validate_stack_invariants(&stack);
    }
}
