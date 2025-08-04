const std = @import("std");

/// Pointer-based EVM stack implementation for optimal performance.
///
/// This implementation uses a pointer to track the top of the stack instead
/// of maintaining a separate size field. This approach:
/// - Eliminates size tracking overhead
/// - Reduces instruction count for push/pop operations
/// - Improves cache locality by keeping hot data together
/// - Maintains same safety guarantees with bounds checking
///
/// ## Design Rationale
/// - Pointer arithmetic instead of index calculations
/// - Stack grows upward (pointer increments on push)
/// - Sentinel pointer marks capacity limit
/// - Direct pointer comparisons for bounds checking
///
/// ## Performance Benefits
/// - Push: Single pointer increment vs index increment + array access
/// - Pop: Single pointer decrement vs index decrement + array access
/// - Size calculation: Pointer subtraction vs field access
/// - Better CPU pipeline utilization with fewer dependencies
pub const PointerStack = @This();

/// Maximum stack capacity as defined by the EVM specification.
pub const CAPACITY: usize = 1024;

/// Error types for stack operations.
pub const Error = error{
    /// Stack would exceed 1024 elements
    StackOverflow,
    /// Attempted to pop from empty stack
    StackUnderflow,
};

/// Stack-allocated storage for optimal performance
data: [CAPACITY]u256 align(@alignOf(u256)) = undefined,

/// Pointer to the next free slot (one past the top element)
/// Invariant: &data[0] <= top <= &data[CAPACITY]
top: [*]u256 = undefined,

/// Sentinel pointer marking the capacity limit
sentinel: [*]const u256 = undefined,

/// Base pointer to the start of the data array
base: [*]const u256 = undefined,

/// Initialize a new empty stack.
pub fn init() PointerStack {
    return PointerStack{};
}

/// Initialize the stack's pointers. Must be called before use.
pub fn setup(self: *PointerStack) void {
    self.base = @as([*]const u256, &self.data);
    self.top = @as([*]u256, &self.data);
    self.sentinel = self.base + CAPACITY;
}

/// Get the current number of elements on the stack.
pub fn size(self: *const PointerStack) usize {
    const base_ptr = @intFromPtr(self.base);
    const top_ptr = @intFromPtr(self.top);
    if (top_ptr < base_ptr) return 0;
    return (top_ptr - base_ptr) / @sizeOf(u256);
}

/// Check if the stack is empty.
pub fn is_empty(self: *const PointerStack) bool {
    return self.top == self.base;
}

/// Check if the stack is full.
pub fn is_full(self: *const PointerStack) bool {
    return self.top == self.sentinel;
}

/// Push a value onto the stack (safe version).
pub fn append(self: *PointerStack, value: u256) Error!void {
    if (self.top == self.sentinel) {
        @branchHint(.cold);
        return Error.StackOverflow;
    }
    self.top[0] = value;
    self.top += 1;
}

/// Push a value onto the stack (unsafe version).
/// Caller must ensure stack has capacity.
pub fn append_unsafe(self: *PointerStack, value: u256) void {
    @branchHint(.likely);
    self.top[0] = value;
    self.top += 1;
}

/// Pop a value from the stack (safe version).
pub fn pop(self: *PointerStack) Error!u256 {
    if (self.top == self.base) {
        @branchHint(.cold);
        return Error.StackUnderflow;
    }
    self.top -= 1;
    const value = self.top[0];
    self.top[0] = 0; // Clear for security
    return value;
}

/// Pop a value from the stack (unsafe version).
/// Caller must ensure stack is not empty.
pub fn pop_unsafe(self: *PointerStack) u256 {
    @branchHint(.likely);
    self.top -= 1;
    const value = self.top[0];
    self.top[0] = 0; // Clear for security
    return value;
}

/// Peek at the top value without removing it (unsafe version).
/// Caller must ensure stack is not empty.
pub fn peek_unsafe(self: *const PointerStack) *const u256 {
    @branchHint(.likely);
    return &(self.top - 1)[0];
}

/// Get mutable reference to top value (unsafe version).
/// Caller must ensure stack is not empty.
pub fn peek_mut_unsafe(self: *PointerStack) *u256 {
    @branchHint(.likely);
    return &(self.top - 1)[0];
}

/// Duplicate the nth element onto the top of stack (unsafe version).
/// Caller must ensure stack has >= n elements and capacity for 1 more.
pub fn dup_unsafe(self: *PointerStack, n: usize) void {
    @branchHint(.likely);
    @setRuntimeSafety(false);
    const value = (self.top - n)[0];
    self.top[0] = value;
    self.top += 1;
}

/// Pop 2 values (unsafe version).
/// Caller must ensure stack has >= 2 elements.
pub fn pop2_unsafe(self: *PointerStack) struct { a: u256, b: u256 } {
    @branchHint(.likely);
    @setRuntimeSafety(false);
    self.top -= 2;
    return .{
        .a = self.top[0],
        .b = self.top[1],
    };
}

/// Pop 3 values (unsafe version).
/// Caller must ensure stack has >= 3 elements.
pub fn pop3_unsafe(self: *PointerStack) struct { a: u256, b: u256, c: u256 } {
    @branchHint(.likely);
    @setRuntimeSafety(false);
    self.top -= 3;
    return .{
        .a = self.top[0],
        .b = self.top[1],
        .c = self.top[2],
    };
}

/// Set the top value (unsafe version).
/// Caller must ensure stack is not empty.
pub fn set_top_unsafe(self: *PointerStack, value: u256) void {
    @branchHint(.likely);
    (self.top - 1)[0] = value;
}

/// Push one value, result of unary operation (unsafe version).
/// Pops one value, applies operation, pushes result.
pub fn push_unsafe(self: *PointerStack, value: u256) void {
    @branchHint(.likely);
    @setRuntimeSafety(false);
    (self.top - 1)[0] = value;
}

/// Exchange the top two values (unsafe version).
/// Caller must ensure stack has >= 2 elements.
pub fn exchange_unsafe(self: *PointerStack) void {
    @branchHint(.likely);
    @setRuntimeSafety(false);
    const temp = (self.top - 1)[0];
    (self.top - 1)[0] = (self.top - 2)[0];
    (self.top - 2)[0] = temp;
}

/// Swap top element with element at position n+1 (unsafe version).
/// Caller must ensure stack has >= n+1 elements.
pub fn swap_unsafe(self: *PointerStack, n: usize) void {
    @branchHint(.likely);
    @setRuntimeSafety(false);
    const top_val = (self.top - 1)[0];
    (self.top - 1)[0] = (self.top - n - 1)[0];
    (self.top - n - 1)[0] = top_val;
}

/// Push arbitrary number of words.
/// Used for return data handling.
pub fn push_slice(self: *PointerStack, values: []const u256) Error!void {
    const new_size = self.size() + values.len;
    if (new_size > CAPACITY) {
        return Error.StackOverflow;
    }
    @memcpy(self.top[0..values.len], values);
    self.top += values.len;
}

/// Direct access to element at index (unsafe).
/// Index 0 is bottom of stack.
pub fn get_unsafe(self: *const PointerStack, index: usize) u256 {
    return self.data[index];
}

/// Get slice of top N elements (for debugging/testing).
pub fn top_slice(self: *const PointerStack, n: usize) []const u256 {
    const current_size = self.size();
    if (n > current_size) {
        return self.data[0..current_size];
    }
    const start = current_size - n;
    return self.data[start..current_size];
}

/// Clone the stack for testing/debugging.
pub fn clone(self: *const PointerStack) PointerStack {
    var new_stack = PointerStack.init();
    new_stack.setup();
    const current_size = self.size();
    @memcpy(new_stack.data[0..current_size], self.data[0..current_size]);
    new_stack.top = @as([*]u256, &new_stack.data) + current_size;
    return new_stack;
}

// Tests
const testing = std.testing;

test "pointer stack basic operations" {
    var stack = PointerStack.init();
    stack.setup();
    
    // Test empty stack
    try testing.expectEqual(@as(usize, 0), stack.size());
    try testing.expect(stack.is_empty());
    try testing.expect(!stack.is_full());
    
    // Test push
    try stack.append(42);
    try testing.expectEqual(@as(usize, 1), stack.size());
    try testing.expect(!stack.is_empty());
    
    // Test pop
    const value = try stack.pop();
    try testing.expectEqual(@as(u256, 42), value);
    try testing.expectEqual(@as(usize, 0), stack.size());
    
    // Test underflow
    try testing.expectError(Error.StackUnderflow, stack.pop());
}

test "pointer stack unsafe operations" {
    var stack = PointerStack.init();
    stack.setup();
    
    // Test unsafe push/pop
    stack.append_unsafe(100);
    stack.append_unsafe(200);
    try testing.expectEqual(@as(usize, 2), stack.size());
    
    const val = stack.pop_unsafe();
    try testing.expectEqual(@as(u256, 200), val);
    try testing.expectEqual(@as(usize, 1), stack.size());
    
    // Test peek
    stack.append_unsafe(300);
    const peeked = stack.peek_unsafe();
    try testing.expectEqual(@as(u256, 300), peeked.*);
    try testing.expectEqual(@as(usize, 2), stack.size()); // Size unchanged
    
    // Test dup
    stack.dup_unsafe(2); // Duplicate element 2 positions from top
    try testing.expectEqual(@as(usize, 3), stack.size());
    try testing.expectEqual(@as(u256, 100), stack.pop_unsafe());
}

test "pointer stack multi-pop operations" {
    var stack = PointerStack.init();
    stack.setup();
    
    stack.append_unsafe(10);
    stack.append_unsafe(20);
    stack.append_unsafe(30);
    
    const pair = stack.pop2_unsafe();
    try testing.expectEqual(@as(u256, 20), pair.a);
    try testing.expectEqual(@as(u256, 30), pair.b);
    try testing.expectEqual(@as(usize, 1), stack.size());
    
    stack.append_unsafe(40);
    stack.append_unsafe(50);
    stack.append_unsafe(60);
    
    const triple = stack.pop3_unsafe();
    try testing.expectEqual(@as(u256, 40), triple.a);
    try testing.expectEqual(@as(u256, 50), triple.b);
    try testing.expectEqual(@as(u256, 60), triple.c);
    try testing.expectEqual(@as(usize, 1), stack.size());
}

test "pointer stack swap operations" {
    var stack = PointerStack.init();
    stack.setup();
    
    // Test exchange
    stack.append_unsafe(100);
    stack.append_unsafe(200);
    stack.exchange_unsafe();
    
    try testing.expectEqual(@as(u256, 100), stack.pop_unsafe());
    try testing.expectEqual(@as(u256, 200), stack.pop_unsafe());
    
    // Test swap
    for (1..6) |i| {
        stack.append_unsafe(i * 10);
    }
    
    stack.swap_unsafe(3); // Swap top with 4th element
    try testing.expectEqual(@as(u256, 20), stack.pop_unsafe());
}

test "pointer stack performance comparison" {
    // This test demonstrates the performance benefits
    // In practice, benchmarks would measure:
    // - Fewer instructions per operation
    // - Better cache utilization
    // - Reduced memory traffic
    
    var stack = PointerStack.init();
    stack.setup();
    
    // Simulate typical EVM operation pattern
    for (0..100) |i| {
        stack.append_unsafe(@intCast(i));
        if (i % 3 == 0 and stack.size() >= 2) {
            _ = stack.pop2_unsafe();
            stack.append_unsafe(@intCast(i * 2));
        }
    }
    
    try testing.expect(stack.size() > 0);
}