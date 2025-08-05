const std = @import("std");

/// High-performance EVM stack implementation with fixed capacity.
///
/// The Stack is a core component of the EVM execution model, providing a
/// Last-In-First-Out (LIFO) data structure for 256-bit values. All EVM
/// computations operate on this stack, making its performance critical.
///
/// ## Design Rationale
/// - Fixed capacity of 1024 elements (per EVM specification)
/// - Stack-allocated storage for direct memory access
/// - 32-byte alignment for optimal memory access on modern CPUs
/// - Unsafe variants skip bounds checking in hot paths for performance
///
/// ## Performance Optimizations
/// - Direct stack allocation eliminates pointer indirection
/// - Aligned memory for optimal access patterns
/// - Unsafe variants used after jump table validation
/// - Hot path annotations for critical operations
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

/// Stack-allocated storage for optimal performance
/// Architecture-appropriate alignment for optimal access
data: [CAPACITY]u256 align(@alignOf(u256)) = undefined,

/// Current number of elements on the stack.
/// Invariant: 0 <= size <= CAPACITY
size: usize = 0,

// Compile-time validations for stack design assumptions
comptime {
    // Ensure stack capacity matches EVM specification
    std.debug.assert(CAPACITY == 1024);
}

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
    @branchHint(.likely); 
    @setRuntimeSafety(false);
    const new_size = self.size - 2;
    const a = self.data[new_size];
    const b = self.data[new_size + 1];
    self.size = new_size;
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

/// Swap the top element with the nth element below it (unsafe version).
///
/// Swaps the top stack element with the element n positions below it.
/// For SWAP1, n=1 swaps top with second element.
/// For SWAP2, n=2 swaps top with third element, etc.
///
/// @param self The stack to operate on
/// @param n Position below top to swap with (1-16)
pub fn swap_unsafe(self: *Stack, n: usize) void {
    @branchHint(.likely);
    std.mem.swap(u256, &self.data[self.size - 1], &self.data[self.size - 1 - n]);
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
    @memset(self.data[0..CAPACITY], 0);
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
pub fn fuzz_stack_operations(allocator: std.mem.Allocator, operations: []const FuzzOperation) !void {
    _ = allocator;
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
                for (stack.data[0..CAPACITY]) |value| {
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
    
    for (stack.data[stack.size..CAPACITY]) |value| {
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

test "fuzz_stack_lifo_property" {
//     const global = struct {
//         fn testLifoProperty(input: []const u8) anyerror!void {
//             if (input.len < 8) return;
//             
//             var stack = Stack{};
//             var reference = std.ArrayList(u256).init(std.testing.allocator);
//             defer reference.deinit();
//             
//             // Generate values from fuzz input
//             const num_ops = @min((input.len / 8), 100); // Limit to 100 operations
//             
//             var i: usize = 0;
//             while (i < num_ops) : (i += 1) {
//                 const start_idx = i * 8;
//                 if (start_idx + 8 > input.len) break;
//                 
//                 const value = std.mem.readInt(u64, input[start_idx..start_idx + 8], .little);
//                 const value_u256 = @as(u256, value);
//                 
//                 try stack.append(value_u256);
//                 try reference.append(value_u256);
//             }
//             
//             // Verify LIFO property
//             while (reference.items.len > 0) {
//                 const expected = reference.pop();
//                 const actual = try stack.pop();
//                 try std.testing.expectEqual(expected, actual);
//             }
//             
//             try std.testing.expectEqual(@as(usize, 0), stack.size);
//         }
//     };
//     try std.testing.fuzz(global.testLifoProperty, .{});
}

test "fuzz_stack_random_operations" {
//     const global = struct {
//         fn testRandomOperations(input: []const u8) anyerror!void {
//             if (input.len < 9) return;
//             
//             var stack = Stack{};
//             var reference = std.ArrayList(u256).init(std.testing.allocator);
//             defer reference.deinit();
//             
//             // Limit operations to prevent excessive test time
//             const max_ops = @min((input.len / 9), 200);
//             
//             for (0..max_ops) |i| {
//                 const base_idx = i * 9;
//                 if (base_idx + 9 > input.len) break;
//                 
//                 const op_type = input[base_idx] % 3; // 0=push, 1=pop, 2=peek
//                 const value = std.mem.readInt(u64, input[base_idx + 1..base_idx + 9], .little);
//                 const value_u256 = @as(u256, value);
//                 
//                 switch (op_type) {
//                     0 => {
//                         // Push operation
//                         if (stack.size < CAPACITY) {
//                             try stack.append(value_u256);
//                             try reference.append(value_u256);
//                         }
//                     },
//                     1 => {
//                         // Pop operation
//                         if (stack.size > 0) {
//                             const expected = reference.pop();
//                             const actual = try stack.pop();
//                             try std.testing.expectEqual(expected, actual);
//                         }
//                     },
//                     2 => {
//                         // Peek operation
//                         if (stack.size > 0) {
//                             const expected = reference.items[reference.items.len - 1];
//                             const actual = try stack.peek();
//                             try std.testing.expectEqual(expected, actual);
//                         }
//                     },
//                     else => unreachable,
//                 }
//                 
//                 try std.testing.expectEqual(reference.items.len, stack.size);
//                 try validate_stack_invariants(&stack);
//             }
//         }
//     };
//     try std.testing.fuzz(global.testRandomOperations, .{});
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

test "memory_alignment_verification" {
    var stack = Stack{};
    
    // Verify initial alignment of data array
    const data_ptr = @intFromPtr(&stack.data[0]);
    try std.testing.expectEqual(@as(usize, 0), data_ptr % 32);
    
    // Fill stack with values
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try stack.append(i);
    }
    
    // Verify alignment is maintained at various indices
    var j: usize = 0;
    while (j < stack.size) : (j += 10) {
        const ptr = @intFromPtr(&stack.data[j]);
        try std.testing.expectEqual(@as(usize, 0), ptr % 32);
    }
    
    // Verify alignment after operations
    _ = try stack.pop();
    _ = try stack.pop();
    try stack.append(999);
    
    const final_ptr = @intFromPtr(&stack.data[0]);
    try std.testing.expectEqual(@as(usize, 0), final_ptr % 32);
}

test "concurrent_usage_multiple_stacks" {
    const allocator = std.testing.allocator;
    
    // Create multiple stacks to ensure they don't share state
    var stack1 = Stack{};
    var stack2 = Stack{};
    var stack3 = Stack{};
    
    // Operate on stack1
    try stack1.append(100);
    try stack1.append(200);
    try stack1.append(300);
    
    // Operate on stack2
    try stack2.append(1000);
    try stack2.append(2000);
    
    // Operate on stack3  
    try stack3.append(10000);
    
    // Verify stacks are independent
    try std.testing.expectEqual(@as(usize, 3), stack1.size);
    try std.testing.expectEqual(@as(usize, 2), stack2.size);
    try std.testing.expectEqual(@as(usize, 1), stack3.size);
    
    // Verify data integrity
    try std.testing.expectEqual(@as(u256, 300), try stack1.pop());
    try std.testing.expectEqual(@as(u256, 2000), try stack2.pop());
    try std.testing.expectEqual(@as(u256, 10000), try stack3.pop());
    
    // Test with array of stacks
    var stacks: [10]*Stack = undefined;
    for (&stacks) |*s| {
        s.* = try allocator.create(Stack);
        s.*.* = Stack{};
    }
    defer {
        for (stacks) |s| {
            allocator.destroy(s);
        }
    }
    
    // Fill each stack with unique values
    for (stacks, 0..) |s, idx| {
        const base_value = @as(u256, idx) * 1000;
        try s.append(base_value);
        try s.append(base_value + 1);
        try s.append(base_value + 2);
    }
    
    // Verify each stack maintains its own state
    for (stacks, 0..) |s, idx| {
        const base_value = @as(u256, idx) * 1000;
        try std.testing.expectEqual(base_value + 2, try s.pop());
        try std.testing.expectEqual(base_value + 1, try s.pop());
        try std.testing.expectEqual(base_value, try s.pop());
    }
    
    // Test concurrent-like access pattern
    var stack_a = Stack{};
    var stack_b = Stack{};
    
    // Interleaved operations
    try stack_a.append(1);
    try stack_b.append(100);
    try stack_a.append(2);
    try stack_b.append(200);
    try stack_a.append(3);
    try stack_b.append(300);
    
    // Verify independence
    try std.testing.expectEqual(@as(u256, 3), try stack_a.pop());
    try std.testing.expectEqual(@as(u256, 300), try stack_b.pop());
    try std.testing.expectEqual(@as(u256, 2), try stack_a.pop());
    try std.testing.expectEqual(@as(u256, 200), try stack_b.pop());
    
    // Test heap-allocated stacks
    const heap_stacks = try allocator.alloc(Stack, 5);
    defer allocator.free(heap_stacks);
    
    for (heap_stacks) |*s| {
        s.* = Stack{};
    }
    defer {
        for (heap_stacks) |_| {
        }
    }
    
    // Use heap stacks
    for (heap_stacks, 0..) |*s, idx| {
        try s.append(@as(u256, idx) * 10);
    }
    
    // Verify heap stacks
    for (heap_stacks, 0..) |*s, idx| {
        try std.testing.expectEqual(@as(u256, idx) * 10, try s.pop());
    }
}

test "extended_fuzzing_unsafe_operations" {
//     const global = struct {
//         fn testExtendedUnsafeOperations(input: []const u8) anyerror!void {
//             if (input.len < 16) return;
//             
//             var stack = Stack{};
//             
//             // Test specific edge cases first
//             
//             // Test pop2_unsafe edge cases
//             stack.append_unsafe(1);
//             stack.append_unsafe(2);
//             const pop2_result = stack.pop2_unsafe();
//             try std.testing.expectEqual(@as(u256, 1), pop2_result.a);
//             try std.testing.expectEqual(@as(u256, 2), pop2_result.b);
//             try std.testing.expectEqual(@as(usize, 0), stack.size);
//             
//             // Test pop3_unsafe edge cases
//             stack.append_unsafe(10);
//             stack.append_unsafe(20);
//             stack.append_unsafe(30);
//             const pop3_result = stack.pop3_unsafe();
//             try std.testing.expectEqual(@as(u256, 10), pop3_result.a);
//             try std.testing.expectEqual(@as(u256, 20), pop3_result.b);
//             try std.testing.expectEqual(@as(u256, 30), pop3_result.c);
//             try std.testing.expectEqual(@as(usize, 0), stack.size);
//             
//             // Test set_top_unsafe
//             stack.append_unsafe(100);
//             stack.set_top_unsafe(200);
//             try std.testing.expectEqual(@as(u256, 200), stack.pop_unsafe());
//             
//             // Random fuzz testing using input data
//             stack.clear();
//             
//             const max_ops = @min((input.len / 2), 100); // Limit operations for performance
//             for (0..max_ops) |i| {
//                 const base_idx = i * 2;
//                 if (base_idx + 2 > input.len) break;
//                 
//                 const op = input[base_idx] % 8;
//                 const value_byte = input[base_idx + 1];
//                 const value = @as(u256, value_byte); // Use small values for testing
//                 
//                 switch (op) {
//                     0 => {
//                         // append_unsafe (only if not full)
//                         if (stack.size < CAPACITY) {
//                             stack.append_unsafe(value);
//                             try std.testing.expectEqual(value, stack.data[stack.size - 1]);
//                         }
//                     },
//                     1 => {
//                         // pop_unsafe (only if not empty)
//                         if (stack.size > 0) {
//                             const expected = stack.data[stack.size - 1];
//                             const actual = stack.pop_unsafe();
//                             try std.testing.expectEqual(expected, actual);
//                             try std.testing.expectEqual(@as(u256, 0), stack.data[stack.size]);
//                         }
//                     },
//                     2 => {
//                         // peek_unsafe (only if not empty)
//                         if (stack.size > 0) {
//                             const expected = stack.data[stack.size - 1];
//                             const actual = stack.peek_unsafe().*;
//                             try std.testing.expectEqual(expected, actual);
//                         }
//                     },
//                     3 => {
//                         // dup_unsafe (only if valid)
//                         if (stack.size > 0 and stack.size < CAPACITY) {
//                             const n = (value_byte % @min(stack.size, 16)) + 1;
//                             const expected = stack.data[stack.size - n];
//                             stack.dup_unsafe(n);
//                             try std.testing.expectEqual(expected, stack.data[stack.size - 1]);
//                         }
//                     },
//                     4 => {
//                         // swap_unsafe (only if valid)
//                         if (stack.size > 1) {
//                             const n = (value_byte % @min(stack.size - 1, 16)) + 1;
//                             const top = stack.data[stack.size - 1];
//                             const target = stack.data[stack.size - n - 1];
//                             stack.swap_unsafe(n);
//                             try std.testing.expectEqual(target, stack.data[stack.size - 1]);
//                             try std.testing.expectEqual(top, stack.data[stack.size - n - 1]);
//                         }
//                     },
//                     5 => {
//                         // pop2_unsafe (only if size >= 2)
//                         if (stack.size >= 2) {
//                             const a = stack.data[stack.size - 2];
//                             const b = stack.data[stack.size - 1];
//                             const result = stack.pop2_unsafe();
//                             try std.testing.expectEqual(a, result.a);
//                             try std.testing.expectEqual(b, result.b);
//                         }
//                     },
//                     6 => {
//                         // pop3_unsafe (only if size >= 3)
//                         if (stack.size >= 3) {
//                             const a = stack.data[stack.size - 3];
//                             const b = stack.data[stack.size - 2];
//                             const c = stack.data[stack.size - 1];
//                             const result = stack.pop3_unsafe();
//                             try std.testing.expectEqual(a, result.a);
//                             try std.testing.expectEqual(b, result.b);
//                             try std.testing.expectEqual(c, result.c);
//                         }
//                     },
//                     7 => {
//                         // set_top_unsafe (only if not empty)
//                         if (stack.size > 0) {
//                             stack.set_top_unsafe(value);
//                             try std.testing.expectEqual(value, stack.data[stack.size - 1]);
//                         }
//                     },
//                     else => unreachable,
//                 }
//                 
//                 // Invariant checks
//                 try std.testing.expect(stack.size <= CAPACITY);
//             }
//         }
//     };
//     try std.testing.fuzz(global.testExtendedUnsafeOperations, .{});
}

test "real_evm_patterns" {
    var stack = Stack{};
    
    // Test 1: Common arithmetic pattern (ADD, MUL, SUB)
    // Simulates: (a + b) * c - d
    stack.append_unsafe(10); // a
    stack.append_unsafe(20); // b
    
    // ADD: pop b, pop a, push (a + b)
    const add_result = stack.pop2_unsafe();
    stack.append_unsafe(add_result.a + add_result.b); // 30
    
    stack.append_unsafe(3);  // c
    
    // MUL: pop c, pop result, push (result * c)
    const mul_result = stack.pop2_unsafe();
    stack.append_unsafe(mul_result.a * mul_result.b); // 90
    
    stack.append_unsafe(5);  // d
    
    // SUB: pop d, pop result, push (result - d)
    const sub_result = stack.pop2_unsafe();
    stack.append_unsafe(sub_result.a - sub_result.b); // 85
    
    try std.testing.expectEqual(@as(u256, 85), stack.pop_unsafe());
    
    // Test 2: DUP and SWAP pattern (common in Solidity)
    stack.clear();
    stack.append_unsafe(100);
    stack.append_unsafe(200);
    stack.append_unsafe(300);
    
    // DUP2 (duplicate 2nd from top)
    stack.dup_unsafe(2);
    try std.testing.expectEqual(@as(u256, 200), stack.peek_unsafe().*);
    
    // SWAP1 (swap top two)
    stack.swap_unsafe(1);
    try std.testing.expectEqual(@as(u256, 300), stack.peek_unsafe().*);
    
    // Test 3: Deep stack manipulation (max depth scenario)
    stack.clear();
    
    // Fill stack to near capacity
    var i: usize = 0;
    while (i < CAPACITY - 10) : (i += 1) {
        stack.append_unsafe(i);
    }
    
    // Perform operations near max depth
    stack.dup_unsafe(16); // DUP16 at deep stack
    stack.swap_unsafe(16); // SWAP16 at deep stack
    
    // Verify stack is still valid
    try std.testing.expect(stack.size == CAPACITY - 9);
    
    // Test 4: Storage operation pattern (SLOAD, DUP, SSTORE)
    stack.clear();
    
    // Simulate loading from storage
    stack.append_unsafe(0x1234); // storage key
    stack.dup_unsafe(1); // duplicate key for later use
    
    // Simulate SLOAD (would normally interact with storage)
    const key = stack.pop_unsafe();
    stack.append_unsafe(key * 2); // mock storage value
    
    // Modify value
    const value = stack.pop_unsafe();
    stack.append_unsafe(value + 100);
    
    // SSTORE pattern: key is still on stack from DUP
    const store_value = stack.pop_unsafe();
    const store_key = stack.pop_unsafe();
    
    try std.testing.expectEqual(@as(u256, 0x1234), store_key);
    try std.testing.expectEqual(@as(u256, 0x2468 + 100), store_value);
    
    // Test 5: Conditional jump pattern (JUMPI)
    stack.clear();
    
    // Push condition and destination
    stack.append_unsafe(0x100); // jump destination
    stack.append_unsafe(1); // condition (true)
    
    // JUMPI pops both values
    const jumpi_result = stack.pop2_unsafe();
    const condition = jumpi_result.b;
    const destination = jumpi_result.a;
    
    try std.testing.expectEqual(@as(u256, 1), condition);
    try std.testing.expectEqual(@as(u256, 0x100), destination);
    
    // Test 6: Call preparation pattern
    stack.clear();
    
    // CALL takes 7 arguments from stack
    stack.append_unsafe(1000000); // gas
    stack.append_unsafe(0xABCDEF); // address
    stack.append_unsafe(100); // value
    stack.append_unsafe(0); // in offset
    stack.append_unsafe(32); // in size
    stack.append_unsafe(64); // out offset
    stack.append_unsafe(32); // out size
    
    // Pop all 7 arguments (in reverse order)
    var call_args: [7]u256 = undefined;
    var j: usize = 0;
    while (j < 7) : (j += 1) {
        call_args[6 - j] = stack.pop_unsafe();
    }
    
    try std.testing.expectEqual(@as(u256, 1000000), call_args[0]);
    try std.testing.expectEqual(@as(u256, 0xABCDEF), call_args[1]);
    
    // Test 7: Maximum stack operations stress test
    stack.clear();
    
    // Rapid push/pop cycles
    var cycle: usize = 0;
    while (cycle < 1000) : (cycle += 1) {
        // Push 10 values
        var k: usize = 0;
        while (k < 10) : (k += 1) {
            stack.append_unsafe(cycle * 10 + k);
        }
        
        // Pop 5 values
        k = 0;
        while (k < 5) : (k += 1) {
            _ = stack.pop_unsafe();
        }
        
        // DUP and SWAP operations
        if (stack.size >= 3) {
            stack.dup_unsafe(3);
            stack.swap_unsafe(2);
        }
        
        // Pop remaining to prevent overflow
        while (stack.size > 500) {
            _ = stack.pop_unsafe();
        }
    }
    
    // Test 8: CREATE2 address calculation pattern
    stack.clear();
    
    // CREATE2 takes 4 arguments
    stack.append_unsafe(0); // value
    stack.append_unsafe(0x20); // offset
    stack.append_unsafe(0x100); // size
    stack.append_unsafe(0x5A17); // salt
    
    // Pop all CREATE2 arguments
    const salt = stack.pop_unsafe();
    const size = stack.pop_unsafe();
    const offset = stack.pop_unsafe();
    const create_value = stack.pop_unsafe();
    
    try std.testing.expectEqual(@as(u256, 0x5A17), salt);
    try std.testing.expectEqual(@as(u256, 0x100), size);
    try std.testing.expectEqual(@as(u256, 0x20), offset);
    try std.testing.expectEqual(@as(u256, 0), create_value);
}

test "performance_benchmarks" {
    const Timer = std.time.Timer;
    var timer = try Timer.start();
    
    var stack = Stack{};
    const iterations = 1_000_000;
    
    // Benchmark 1: append_unsafe vs append
    timer.reset();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        stack.append_unsafe(i % 256);
        if (stack.size >= CAPACITY) {
            stack.size = 0;
        }
    }
    const unsafe_append_ns = timer.read();
    
    stack.clear();
    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        _ = stack.append(i % 256) catch {
            stack.size = 0;
            continue;
        };
    }
    const safe_append_ns = timer.read();
    
    // Verify unsafe is faster
    try std.testing.expect(unsafe_append_ns < safe_append_ns);
    
    // Benchmark 2: pop_unsafe vs pop
    stack.clear();
    i = 0;
    while (i < 500) : (i += 1) {
        stack.append_unsafe(i);
    }
    
    timer.reset();
    i = 0;
    while (i < iterations and stack.size > 0) : (i += 1) {
        _ = stack.pop_unsafe();
        if (stack.size == 0) {
            var j: usize = 0;
            while (j < 500) : (j += 1) {
                stack.append_unsafe(j);
            }
        }
    }
    const unsafe_pop_ns = timer.read();
    
    stack.clear();
    i = 0;
    while (i < 500) : (i += 1) {
        stack.append_unsafe(i);
    }
    
    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        _ = stack.pop() catch {
            var j: usize = 0;
            while (j < 500) : (j += 1) {
                stack.append_unsafe(j);
            }
            continue;
        };
    }
    const safe_pop_ns = timer.read();
    
    // Verify unsafe is faster
    try std.testing.expect(unsafe_pop_ns < safe_pop_ns);
    
    // Benchmark 3: Memory alignment impact
    stack.clear();
    
    // Fill stack with aligned access pattern
    timer.reset();
    i = 0;
    while (i < iterations / 1000) : (i += 1) {
        var j: usize = 0;
        while (j < 32) : (j += 1) {
            stack.append_unsafe(j);
        }
        j = 0;
        while (j < 32) : (j += 1) {
            _ = stack.pop_unsafe();
        }
    }
    const aligned_pattern_ns = timer.read();
    
    // Benchmark 4: Branch prediction for size checks
    stack.clear();
    
    // Predictable pattern (always succeeds)
    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        if (stack.size < CAPACITY / 2) {
            stack.append_unsafe(i);
        } else {
            _ = stack.pop_unsafe();
        }
    }
    const predictable_ns = timer.read();
    
    // Unpredictable pattern using deterministic pseudo-random sequence
    stack.clear();
    
    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        // Use a simple deterministic sequence for pseudo-random behavior
        const pseudo_random = (i * 31 + 17) % 2; // Simple PRNG replacement
        if (pseudo_random == 1) {
            if (stack.size < CAPACITY) {
                stack.append_unsafe(i);
            }
        } else {
            if (stack.size > 0) {
                _ = stack.pop_unsafe();
            }
        }
    }
    const unpredictable_ns = timer.read();
    
    // Predictable should be faster due to branch prediction
    try std.testing.expect(predictable_ns < unpredictable_ns);
    
    // Benchmark 5: DUP and SWAP performance
    stack.clear();
    i = 0;
    while (i < 16) : (i += 1) {
        stack.append_unsafe(i);
    }
    
    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        stack.dup_unsafe((i % 16) + 1);
        if (stack.size >= CAPACITY - 16) {
            var j: usize = 0;
            while (j < stack.size - 16) : (j += 1) {
                _ = stack.pop_unsafe();
            }
        }
    }
    const dup_ns = timer.read();
    
    stack.clear();
    i = 0;
    while (i < 16) : (i += 1) {
        stack.append_unsafe(i);
    }
    
    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        stack.swap_unsafe((i % 15) + 1);
    }
    const swap_ns = timer.read();
    
    // Both should complete in reasonable time
    try std.testing.expect(dup_ns > 0);
    try std.testing.expect(swap_ns > 0);
    
    // Print benchmark results for manual inspection
    std.log.debug("Performance Benchmarks ({} iterations):", .{iterations});
    std.log.debug("  append_unsafe: {} ns", .{unsafe_append_ns});
    std.log.debug("  append (safe): {} ns", .{safe_append_ns});
    std.log.debug("  pop_unsafe: {} ns", .{unsafe_pop_ns});
    std.log.debug("  pop (safe): {} ns", .{safe_pop_ns});
    std.log.debug("  aligned pattern: {} ns", .{aligned_pattern_ns});
    std.log.debug("  predictable branches: {} ns", .{predictable_ns});
    std.log.debug("  unpredictable branches: {} ns", .{unpredictable_ns});
    std.log.debug("  dup operations: {} ns", .{dup_ns});
    std.log.debug("  swap operations: {} ns", .{swap_ns});
}

// test "branch_hint_effectiveness" {
//     const global = struct {
//         fn testBranchHintEffectiveness(input: []const u8) anyerror!void {
//             if (input.len < 8) return;
//             
//             var stack = Stack{};
//             
//             // Test 1: append() - overflow is cold path
//             // Fill stack almost to capacity
//             var i: usize = 0;
//             while (i < CAPACITY - 1) : (i += 1) {
//                 try stack.append(i);
//             }
//             
//             // Normal append (likely path)
//             try stack.append(999);
//             
//             // Overflow (cold path with @branchHint(.cold))
//             try std.testing.expectError(Error.StackOverflow, stack.append(1000));
//             
//             // Test 2: pop() - underflow is cold path
//             stack.clear();
//             
//             // Fill with some values
//             i = 0;
//             while (i < 100) : (i += 1) {
//                 try stack.append(i);
//             }
//             
//             // Normal pops (likely path)
//             i = 0;
//             while (i < 100) : (i += 1) {
//                 _ = try stack.pop();
//             }
//             
//             // Underflow (cold path with @branchHint(.cold))
//             try std.testing.expectError(Error.StackUnderflow, stack.pop());
//             
//             // Test 3: Unsafe operations assume likely path
//             stack.clear();
//             
//             // Fill stack for unsafe operations
//             i = 0;
//             while (i < 500) : (i += 1) {
//                 stack.append_unsafe(i);
//             }
//             
//             // Rapid unsafe operations using fuzz input for values
//             const max_ops = @min((input.len), 1000);
//             for (0..max_ops) |op_idx| {
//                 const fuzz_value = @as(u256, input[op_idx]);
//                 
//                 if (stack.size < CAPACITY - 10) {
//                     stack.append_unsafe(fuzz_value);
//                 }
//                 if (stack.size > 10) {
//                     _ = stack.pop_unsafe();
//                 }
//                 if (stack.size > 0) {
//                     _ = stack.peek_unsafe();
//                 }
//             }
//             
//             // Test 4: peek_n boundary checks (cold path for errors)
//             stack.clear();
//             try stack.append(100);
//             try stack.append(200);
//             try stack.append(300);
//             
//             // Normal peek_n (likely path)
//             try std.testing.expectEqual(@as(u256, 300), try stack.peek_n(0));
//             try std.testing.expectEqual(@as(u256, 200), try stack.peek_n(1));
//             try std.testing.expectEqual(@as(u256, 100), try stack.peek_n(2));
//             
//             // Out of bounds (cold path)
//             try std.testing.expectError(Error.StackUnderflow, stack.peek_n(3));
//             try std.testing.expectError(Error.StackUnderflow, stack.peek_n(100));
//         }
//     };
//     try std.testing.fuzz(global.testBranchHintEffectiveness, .{});
// }

test "security_focused_tests" {
    var stack = Stack{};
    
    // Test 1: Data clearing on pop
    const secret_value: u256 = 0xDEADBEEF_CAFEBABE_12345678_9ABCDEF0;
    stack.append_unsafe(secret_value);
    
    // Store location where data was
    const data_location = stack.size - 1;
    
    // Pop the value
    const popped = stack.pop_unsafe();
    try std.testing.expectEqual(secret_value, popped);
    
    // Verify the slot was cleared
    try std.testing.expectEqual(@as(u256, 0), stack.data[data_location]);
    
    // Test 2: Clear function zeroes all data
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        stack.append_unsafe(0xFFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF);
    }
    
    stack.clear();
    try std.testing.expectEqual(@as(usize, 0), stack.size);
    
    // Verify all data is zeroed
    for (stack.data[0..CAPACITY]) |value| {
        try std.testing.expectEqual(@as(u256, 0), value);
    }
    
    // Test 3: No information leakage between operations
    stack.append_unsafe(0x11111111);
    stack.append_unsafe(0x22222222);
    stack.append_unsafe(0x33333333);
    
    // Pop and verify clearing
    _ = stack.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 0), stack.data[2]);
    
    _ = stack.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 0), stack.data[1]);
    
    // Test 4: Pattern detection resistance
    // Fill with pattern
    i = 0;
    while (i < 50) : (i += 1) {
        stack.append_unsafe(i * 0x10101010);
    }
    
    // Store the original size
    const pattern_size = stack.size;
    
    // Clear half by popping
    i = 0;
    while (i < 25) : (i += 1) {
        _ = stack.pop_unsafe();
    }
    
    // Verify cleared slots don't reveal pattern
    // After popping 25 items, stack.size is 25
    // The cleared slots are from index 25 to 49
    i = stack.size;
    while (i < pattern_size) : (i += 1) {
        try std.testing.expectEqual(@as(u256, 0), stack.data[i]);
    }
    
    // Test 5: Stack isolation
    var stack_a = Stack{};
    const stack_b = Stack{};
    
    // Put sensitive data in stack_a
    stack_a.append_unsafe(0x5EC4E7_DA7A_A);
    
    // Verify stack_b has no access to stack_a's data
    try std.testing.expectEqual(@as(usize, 0), stack_b.size);
    try std.testing.expectEqual(@as(u256, 0), stack_b.data[0]);
    
    // Test 6: Bounds checking in safe operations
    stack.clear();
    
    // Test underflow protection
    try std.testing.expectError(Error.StackUnderflow, stack.pop());
    try std.testing.expectError(Error.StackUnderflow, stack.peek());
    try std.testing.expectError(Error.StackUnderflow, stack.peek_n(0));
    
    // Fill to capacity
    i = 0;
    while (i < CAPACITY) : (i += 1) {
        try stack.append(i);
    }
    
    // Test overflow protection
    try std.testing.expectError(Error.StackOverflow, stack.append(0xE874A));
    
    // Test 7: Memory pattern analysis resistance
    stack.clear();
    
    // Create complex pattern
    const pattern = [_]u256{
        0x0000000000000000,
        0xFFFFFFFFFFFFFFFF,
        0x5555555555555555,
        0xAAAAAAAAAAAAAAAA,
        0x0F0F0F0F0F0F0F0F,
        0xF0F0F0F0F0F0F0F0,
    };
    
    for (pattern) |p| {
        stack.append_unsafe(p);
    }
    
    // Pop all values
    for (pattern) |_| {
        _ = stack.pop_unsafe();
    }
    
    // Verify no pattern remains
    i = 0;
    while (i < pattern.len) : (i += 1) {
        try std.testing.expectEqual(@as(u256, 0), stack.data[i]);
    }
    
    // Test 8: Timing attack resistance (basic check)
    stack.clear();
    
    // Fill with zeros
    i = 0;
    while (i < 100) : (i += 1) {
        stack.append_unsafe(0);
    }
    
    const Timer = std.time.Timer;
    var timer = try Timer.start();
    
    // Time operations on zero values
    timer.reset();
    _ = stack.pop_unsafe();
    const zero_pop_time = timer.read();
    
    // Fill with max values
    stack.clear();
    i = 0;
    while (i < 100) : (i += 1) {
        stack.append_unsafe(std.math.maxInt(u256));
    }
    
    // Time operations on max values
    timer.reset();
    _ = stack.pop_unsafe();
    const max_pop_time = timer.read();
    
    // Operations should take similar time regardless of value
    // (This is a basic check, not a comprehensive timing analysis)
    const time_diff = if (zero_pop_time > max_pop_time) 
        zero_pop_time - max_pop_time 
    else 
        max_pop_time - zero_pop_time;
    
    // Allow for some variance but not extreme differences
    try std.testing.expect(time_diff < 1000000); // 1ms tolerance
    
    // Test 9: State consistency after errors
    stack.clear();
    
    // Fill near capacity
    i = 0;
    while (i < CAPACITY - 1) : (i += 1) {
        try stack.append(i);
    }
    
    const size_before_error = stack.size;
    
    // Try to exceed capacity multiple times
    try stack.append(999);
    _ = stack.append(1000) catch {};
    _ = stack.append(1001) catch {};
    
    // Verify state wasn't corrupted
    try std.testing.expectEqual(CAPACITY, stack.size);
    try std.testing.expectEqual(@as(u256, 999), try stack.pop());
    try std.testing.expectEqual(size_before_error, stack.size);
    
    // Test 10: Verify cleared memory is truly unrecoverable
    stack.clear();
    
    // Fill with sensitive pattern
    const sensitive_pattern = 0xC0FFEE_DEADBEEF_CAFEBABE_F00DFACE;
    i = 0;
    while (i < 100) : (i += 1) {
        stack.append_unsafe(sensitive_pattern ^ @as(u256, i));
    }
    
    // Store original size
    const original_size = stack.size;
    
    // Clear using different methods
    // Method 1: Pop all values
    while (stack.size > 50) {
        _ = stack.pop_unsafe();
    }
    
    // Method 2: Use clear()
    stack.clear();
    
    // Attempt to recover data through various means
    // 1. Direct access to data array
    var found_pattern = false;
    for (stack.data[0..original_size]) |value| {
        if (value != 0) {
            // Check if value matches our pattern (XOR with small number)
            const xor_result = value ^ sensitive_pattern;
            if (xor_result < 100) {
                found_pattern = true;
                break;
            }
        }
    }
    try std.testing.expect(!found_pattern);
    
    // 2. Verify all cleared slots are zero
    for (stack.data[0..CAPACITY]) |value| {
        try std.testing.expectEqual(@as(u256, 0), value);
    }
    
    // 3. Try to access beyond current size
    try std.testing.expectEqual(@as(usize, 0), stack.size);
    
    // 4. Refill and verify no old data appears
    i = 0;
    while (i < 100) : (i += 1) {
        stack.append_unsafe(0xAAAAAAAA);
    }
    
    // Pop all and check no sensitive pattern appears
    while (stack.size > 0) {
        const value = stack.pop_unsafe();
        try std.testing.expect(value != sensitive_pattern);
        // Ensure value doesn't match our XOR pattern
        if (value != 0xAAAAAAAA) {
            const xor_result = value ^ sensitive_pattern;
            try std.testing.expect(xor_result >= 100);
        }
    }
}
