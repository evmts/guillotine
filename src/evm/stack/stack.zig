const std = @import("std");

/// High-performance EVM stack implementation with fixed capacity.
///
/// The Stack is a core component of the EVM execution model, providing a
/// Last-In-First-Out (LIFO) data structure for 256-bit values. All EVM
/// computations operate on this stack, making its performance critical.
///
/// ## Design Rationale
/// - Fixed capacity of 1024 elements (per EVM specification)
/// - 32-byte alignment for optimal memory access on modern CPUs
/// - Unsafe variants skip bounds checking in hot paths for performance
///
/// ## Performance Optimizations
/// - Aligned memory for SIMD-friendly access patterns
/// - Unsafe variants used after jump table validation
/// - Direct memory access patterns for maximum speed
///
/// ## SIZE OPTIMIZATION SAFETY MODEL
/// 
/// This stack provides two operation variants:
/// 1. **Safe operations** (`append()`, `pop()`) - Include bounds checking
/// 2. **Unsafe operations** (`append_unsafe()`, `pop_unsafe()`) - No bounds checking
/// 
/// The unsafe variants are used in opcode implementations after the jump table
/// performs comprehensive validation via `validate_stack_requirements()`. This
/// centralized validation approach:
/// 
/// - Eliminates redundant checks in individual opcodes (smaller binary)
/// - Maintains safety by validating ALL operations before execution
/// - Enables maximum performance in the hot path
/// 
/// **SAFETY GUARANTEE**: All unsafe operations assume preconditions are met:
/// - `pop_unsafe()`: Stack must not be empty
/// - `append_unsafe()`: Stack must have capacity  
/// - `dup_unsafe(n)`: Stack must have >= n items and capacity for +1
/// - `swap_unsafe(n)`: Stack must have >= n+1 items
/// 
/// These preconditions are enforced by jump table validation.
///
/// Example:
/// ```zig
/// var stack = Stack{};
/// try stack.append(100); // Safe variant (for error_mapping)
/// stack.append_unsafe(200); // Unsafe variant (for opcodes)
/// ```
pub const Stack = @This();

/// Maximum stack capacity as defined by the EVM specification.
/// This limit prevents stack-based DoS attacks.
pub const CAPACITY: usize = 1024;

/// Error types for stack operations.
/// These map directly to EVM execution errors.
pub const Error = error{
    /// Stack would exceed 1024 elements
    StackOverflow,
    /// Attempted to pop from empty stack
    StackUnderflow,
};

/// Stack storage aligned to 32-byte boundaries.
/// Alignment improves performance on modern CPUs by:
/// - Enabling SIMD operations
/// - Reducing cache line splits
/// - Improving memory prefetching
data: [CAPACITY]u256 align(32) = [_]u256{0} ** CAPACITY,

/// Current number of elements on the stack.
/// Invariant: 0 <= size <= CAPACITY
size: usize = 0,

/// Push a value onto the stack (safe version).
///
/// @param self The stack to push onto
/// @param value The 256-bit value to push
/// @throws Overflow if stack is at capacity
///
/// Example:
/// ```zig
/// try stack.append(0x1234);
/// ```
pub fn append(self: *Stack, value: u256) Error!void {
    if (self.size >= CAPACITY) {
        @branchHint(.cold);
        // Debug logging removed for fuzz testing compatibility
        return Error.StackOverflow;
    }
    // Debug logging removed for fuzz testing compatibility
    self.data[self.size] = value;
    self.size += 1;
}

/// Push a value onto the stack (unsafe version).
///
/// Caller must ensure stack has capacity. Used in hot paths
/// after validation has already been performed.
///
/// @param self The stack to push onto
/// @param value The 256-bit value to push
pub fn append_unsafe(self: *Stack, value: u256) void {
    @branchHint(.likely);
    self.data[self.size] = value;
    self.size += 1;
}

/// Pop a value from the stack (safe version).
///
/// Removes and returns the top element. Clears the popped
/// slot to prevent information leakage.
///
/// @param self The stack to pop from
/// @return The popped value
/// @throws Underflow if stack is empty
///
/// Example:
/// ```zig
/// const value = try stack.pop();
/// ```
pub fn pop(self: *Stack) Error!u256 {
    if (self.size == 0) {
        @branchHint(.cold);
        // Debug logging removed for fuzz testing compatibility
        return Error.StackUnderflow;
    }
    self.size -= 1;
    const value = self.data[self.size];
    self.data[self.size] = 0;
    // Debug logging removed for fuzz testing compatibility
    return value;
}

/// Pop a value from the stack (unsafe version).
///
/// Caller must ensure stack is not empty. Used in hot paths
/// after validation.
///
/// @param self The stack to pop from
/// @return The popped value
pub fn pop_unsafe(self: *Stack) u256 {
    @branchHint(.likely);
    self.size -= 1;
    const value = self.data[self.size];
    self.data[self.size] = 0;
    return value;
}

/// Peek at the top value without removing it (unsafe version).
///
/// Caller must ensure stack is not empty.
///
/// @param self The stack to peek at
/// @return Pointer to the top value
pub fn peek_unsafe(self: *const Stack) *const u256 {
    @branchHint(.likely);
    return &self.data[self.size - 1];
}

/// Duplicate the nth element onto the top of stack (unsafe version).
///
/// Caller must ensure preconditions are met.
///
/// @param self The stack to operate on
/// @param n Position to duplicate from (1-16)
pub fn dup_unsafe(self: *Stack, n: usize) void {
    @branchHint(.likely);
    @setRuntimeSafety(false);
    self.append_unsafe(self.data[self.size - n]);
}

/// Pop 2 values without pushing (unsafe version)
pub fn pop2_unsafe(self: *Stack) struct { a: u256, b: u256 } {
    @branchHint(.likely); @setRuntimeSafety(false);
    const a = self.data[self.size - 2];
    const b = self.data[self.size - 1];
    self.size -= 2;
    return .{ .a = a, .b = b };
}

/// Pop 3 values without pushing (unsafe version)
pub fn pop3_unsafe(self: *Stack) struct { a: u256, b: u256, c: u256 } {
    @branchHint(.likely);
    @setRuntimeSafety(false);
    self.size -= 3;
    return .{
        .a = self.data[self.size],
        .b = self.data[self.size + 1],
        .c = self.data[self.size + 2],
    };
}

pub fn set_top_unsafe(self: *Stack, value: u256) void {
    @branchHint(.likely);
    // Assumes stack is not empty; this should be guaranteed by jump_table validation
    // for opcodes that use this pattern (e.g., after a pop and peek on a stack with >= 2 items).
    self.data[self.size - 1] = value;
}

/// Swap unsafe function following snake_case convention
pub fn swap_unsafe(self: *Stack, n: usize) void {
    @branchHint(.likely);
    std.mem.swap(u256, &self.data[self.size - 1], &self.data[self.size - n - 1]);
}

/// Peek at the nth element from the top (for test compatibility)
pub fn peek_n(self: *const Stack, n: usize) Error!u256 {
    if (n >= self.size) {
        @branchHint(.cold);
        return Error.StackUnderflow;
    }
    return self.data[self.size - 1 - n];
}

/// Clear the stack (for test compatibility)
pub fn clear(self: *Stack) void {
    self.size = 0;
    // Zero out the data for security
    @memset(&self.data, 0);
}

/// Peek at the top value (for test compatibility)
pub fn peek(self: *const Stack) Error!u256 {
    if (self.size == 0) {
        @branchHint(.cold);
        return Error.StackUnderflow;
    }
    return self.data[self.size - 1];
}

// Fuzz testing functions
pub fn fuzz_stack_operations(operations: []const FuzzOperation) !void {
    var stack = Stack{};
    const testing = std.testing;
    
    for (operations) |op| {
        switch (op) {
            .push => |value| {
                const old_size = stack.size;
                const result = stack.append(value);
                
                if (old_size < CAPACITY) {
                    try result;
                    try testing.expectEqual(old_size + 1, stack.size);
                    try testing.expectEqual(value, stack.data[old_size]);
                } else {
                    try testing.expectError(Error.StackOverflow, result);
                    try testing.expectEqual(old_size, stack.size);
                }
            },
            .pop => {
                const old_size = stack.size;
                const result = stack.pop();
                
                if (old_size > 0) {
                    _ = try result;
                    try testing.expectEqual(old_size - 1, stack.size);
                    try testing.expectEqual(@as(u256, 0), stack.data[stack.size]);
                } else {
                    try testing.expectError(Error.StackUnderflow, result);
                    try testing.expectEqual(@as(usize, 0), stack.size);
                }
            },
            .peek => {
                const result = stack.peek();
                if (stack.size > 0) {
                    const value = try result;
                    try testing.expectEqual(stack.data[stack.size - 1], value);
                } else {
                    try testing.expectError(Error.StackUnderflow, result);
                }
            },
            .clear => {
                stack.clear();
                try testing.expectEqual(@as(usize, 0), stack.size);
                for (stack.data) |value| {
                    try testing.expectEqual(@as(u256, 0), value);
                }
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
    
    try testing.expect(stack.size <= CAPACITY);
    
    for (stack.data[stack.size..]) |value| {
        try testing.expectEqual(@as(u256, 0), value);
    }
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
    
    try fuzz_stack_operations(&operations);
}

test "fuzz_stack_overflow_boundary" {
    var operations = std.ArrayList(FuzzOperation).init(std.testing.allocator);
    defer operations.deinit();
    
    var i: usize = 0;
    while (i <= CAPACITY + 10) : (i += 1) {
        try operations.append(.{ .push = @as(u256, i) });
    }
    
    try fuzz_stack_operations(operations.items);
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
    
    try fuzz_stack_operations(&operations);
}

test "fuzz_stack_lifo_property" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    
    var stack = Stack{};
    var reference = std.ArrayList(u256).init(std.testing.allocator);
    defer reference.deinit();
    
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const value = random.int(u256);
        try stack.append(value);
        try reference.append(value);
    }
    
    while (reference.items.len > 0) {
        const expected = reference.pop();
        const actual = try stack.pop();
        try std.testing.expectEqual(expected, actual);
    }
    
    try std.testing.expectEqual(@as(usize, 0), stack.size);
}

test "fuzz_stack_random_operations" {
    var prng = std.Random.DefaultPrng.init(123);
    const random = prng.random();
    
    var stack = Stack{};
    var reference = std.ArrayList(u256).init(std.testing.allocator);
    defer reference.deinit();
    
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const op_type = random.intRangeAtMost(u8, 0, 2);
        
        switch (op_type) {
            0 => {
                if (stack.size < CAPACITY) {
                    const value = random.int(u256);
                    try stack.append(value);
                    try reference.append(value);
                }
            },
            1 => {
                if (stack.size > 0) {
                    const expected = reference.pop();
                    const actual = try stack.pop();
                    try std.testing.expectEqual(expected, actual);
                }
            },
            2 => {
                if (stack.size > 0) {
                    const expected = reference.items[reference.items.len - 1];
                    const actual = try stack.peek();
                    try std.testing.expectEqual(expected, actual);
                }
            },
            else => unreachable,
        }
        
        try std.testing.expectEqual(reference.items.len, stack.size);
        try validate_stack_invariants(&stack);
    }
}

test "fuzz_stack_unsafe_operations" {
    var stack = Stack{};
    
    stack.append_unsafe(100);
    stack.append_unsafe(200);
    stack.append_unsafe(300);
    
    try std.testing.expectEqual(@as(usize, 3), stack.size);
    try std.testing.expectEqual(@as(u256, 300), stack.peek_unsafe().*);
    
    const val1 = stack.pop_unsafe();
    const val2 = stack.pop_unsafe();
    const val3 = stack.pop_unsafe();
    
    try std.testing.expectEqual(@as(u256, 300), val1);
    try std.testing.expectEqual(@as(u256, 200), val2);
    try std.testing.expectEqual(@as(u256, 100), val3);
    try std.testing.expectEqual(@as(usize, 0), stack.size);
}

test "fuzz_stack_dup_operations" {
    var stack = Stack{};
    
    stack.append_unsafe(100);
    stack.append_unsafe(200);
    stack.append_unsafe(300);
    
    stack.dup_unsafe(1);
    try std.testing.expectEqual(@as(usize, 4), stack.size);
    try std.testing.expectEqual(@as(u256, 300), stack.peek_unsafe().*);
    
    stack.dup_unsafe(2);
    try std.testing.expectEqual(@as(usize, 5), stack.size);
    try std.testing.expectEqual(@as(u256, 300), stack.peek_unsafe().*);
}

test "fuzz_stack_swap_operations" {
    var stack = Stack{};
    
    stack.append_unsafe(100);
    stack.append_unsafe(200);
    stack.append_unsafe(300);
    
    stack.swap_unsafe(1);
    
    try std.testing.expectEqual(@as(u256, 200), stack.data[2]);
    try std.testing.expectEqual(@as(u256, 300), stack.data[1]);
    try std.testing.expectEqual(@as(u256, 100), stack.data[0]);
}

test "fuzz_stack_multi_pop_operations" {
    var stack = Stack{};
    
    stack.append_unsafe(100);
    stack.append_unsafe(200);
    stack.append_unsafe(300);
    stack.append_unsafe(400);
    stack.append_unsafe(500);
    
    const result2 = stack.pop2_unsafe();
    try std.testing.expectEqual(@as(u256, 400), result2.a);
    try std.testing.expectEqual(@as(u256, 500), result2.b);
    try std.testing.expectEqual(@as(usize, 3), stack.size);
    
    const result3 = stack.pop3_unsafe();
    try std.testing.expectEqual(@as(u256, 100), result3.a);
    try std.testing.expectEqual(@as(u256, 200), result3.b);
    try std.testing.expectEqual(@as(u256, 300), result3.c);
    try std.testing.expectEqual(@as(usize, 0), stack.size);
}

test "fuzz_stack_edge_values" {
    var stack = Stack{};
    
    const edge_values = [_]u256{
        0,
        1,
        std.math.maxInt(u8),
        std.math.maxInt(u16),
        std.math.maxInt(u32),
        std.math.maxInt(u64),
        std.math.maxInt(u128),
        std.math.maxInt(u256),
        1 << 128,
        (1 << 255),
    };
    
    for (edge_values) |value| {
        try stack.append(value);
        const popped = try stack.pop();
        try std.testing.expectEqual(value, popped);
    }
}
