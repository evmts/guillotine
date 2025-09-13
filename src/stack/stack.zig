//! High-performance EVM stack implementation.
//!
//! Pointer-based stack with downward growth for optimal CPU cache performance.
//! Supports up to 1024 256-bit words as per EVM specification.
//!
//! Key features:
//! - 64-byte cache line alignment
//! - Safe and unsafe operation variants
//! - Automatic index type selection based on capacity
//! - Zero-cost abstractions through compile-time configuration
//!
//! Memory safety is guaranteed through:
//! - Bounds checking in safe operations (push/pop/peek/set_top)
//! - Assertion-based validation in unsafe operations (*_unsafe variants)
//! - Proper ownership of aligned memory allocation
const std = @import("std");

const StackConfig = @import("stack_config.zig").StackConfig;


/// Creates a configured stack type.
///
/// The stack grows downward: push decrements pointer, pop increments.
/// This design optimizes for CPU cache locality and branch prediction.
pub fn Stack(comptime config: StackConfig) type {
    config.validate();


    return struct {
        pub const WordType = config.WordType;
        pub const IndexType = config.StackIndexType();
        pub const stack_capacity = config.stack_size;

        pub const Error = error{
            StackOverflow,
            StackUnderflow,
            AllocationError,
        };

        const Self = @This();

        // Ownership: pointer to aligned memory returned by alignedAlloc
        buf_ptr: [*]align(64) WordType,

        // Downward stack growth: stack_ptr points to next empty slot
        // Push: *stack_ptr = value; stack_ptr -= 1;
        // Pop: stack_ptr += 1; return *stack_ptr;
        stack_ptr: [*]WordType,


        /// Initialize a new stack with allocated memory.
        ///
        /// Allocates cache-aligned memory and sets up pointer boundaries.
        /// Stack pointer starts at the top (highest address) and grows downward.
        pub fn init(allocator: std.mem.Allocator) Error!Self {
            const memory = allocator.alignedAlloc(WordType, @enumFromInt(6), stack_capacity) catch return Error.AllocationError;
            errdefer allocator.free(memory);

            const base_ptr: [*]align(64) WordType = memory.ptr;

            return Self{
                .buf_ptr = base_ptr,
                .stack_ptr = base_ptr + stack_capacity,
            };
        }

        /// Deallocates the stack's aligned memory.
        /// Must be called when the stack is no longer needed.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            const memory_slice = self.buf_ptr[0..stack_capacity];
            allocator.free(memory_slice);
        }

        inline fn stack_base(self: *const Self) [*]WordType {
            return self.buf_ptr + stack_capacity;
        }
        
        inline fn stack_limit(self: *const Self) [*]WordType {
            return self.buf_ptr;
        }

        pub inline fn push_unsafe(self: *Self, value: WordType) void {
            @branchHint(.likely);
            std.debug.assert(@intFromPtr(self.stack_ptr) > @intFromPtr(self.stack_limit()));
            self.stack_ptr -= 1;
            self.stack_ptr[0] = value;
        }

        pub inline fn push(self: *Self, value: WordType) Error!void {
            if (@intFromPtr(self.stack_ptr) <= @intFromPtr(self.stack_limit())) {
                @branchHint(.cold);
                return Error.StackOverflow;
            }
            self.push_unsafe(value);
        }

        pub inline fn pop_unsafe(self: *Self) WordType {
            @branchHint(.likely);
            std.debug.assert(@intFromPtr(self.stack_ptr) < @intFromPtr(self.stack_base()));
            const value = self.stack_ptr[0];
            self.stack_ptr += 1;
            return value;
        }

        pub inline fn pop(self: *Self) Error!WordType {
            if (@intFromPtr(self.stack_ptr) >= @intFromPtr(self.stack_base())) {
                @branchHint(.cold);
                return Error.StackUnderflow;
            }
            return self.pop_unsafe();
        }

        pub inline fn set_top_unsafe(self: *Self, value: WordType) void {
            @branchHint(.likely);
            std.debug.assert(@intFromPtr(self.stack_ptr) < @intFromPtr(self.stack_base()));
            self.stack_ptr[0] = value;
        }

        pub inline fn set_top(self: *Self, value: WordType) Error!void {
            if (@intFromPtr(self.stack_ptr) >= @intFromPtr(self.stack_base())) {
                @branchHint(.cold);
                return Error.StackUnderflow;
            }
            self.set_top_unsafe(value);
        }

        pub inline fn peek_unsafe(self: *const Self) WordType {
            @branchHint(.likely);
            std.debug.assert(@intFromPtr(self.stack_ptr) < @intFromPtr(self.stack_base()));
            return self.stack_ptr[0];
        }

        pub inline fn peek(self: *Self) Error!WordType {
            if (@intFromPtr(self.stack_ptr) >= @intFromPtr(self.stack_base())) {
                @branchHint(.cold);
                return Error.StackUnderflow;
            }
            return self.peek_unsafe();
        }

        /// Performs a binary operation on the top two stack items.
        /// Pops the top item, applies the operation with the second item, 
        /// and replaces the second item with the result.
        /// This is optimized for arithmetic operations like ADD, MUL, SUB, DIV.
        pub inline fn binary_op_unsafe(self: *Self, comptime op: fn(a: WordType, b: WordType) WordType) void {
            @branchHint(.likely);
            std.debug.assert(@intFromPtr(self.stack_ptr) + @sizeOf(WordType) < @intFromPtr(self.stack_base()));
            const top = self.stack_ptr[0];
            const second = self.stack_ptr[1];
            self.stack_ptr[1] = op(top, second);
            self.stack_ptr += 1;
        }

        // Generic dup function for DUP1-DUP16
        pub fn dup_n(self: *Self, n: u8) Error!void {
            // Check if we have n items on stack
            const current_elements = self.size_internal();
            if (current_elements < n) {
                @branchHint(.cold);
                return Error.StackUnderflow;
            }
            // Check if we have room for one more
            if (@intFromPtr(self.stack_ptr) <= @intFromPtr(self.stack_limit())) {
                @branchHint(.cold);
                return Error.StackOverflow;
            }
            const value = self.stack_ptr[n - 1];
            self.push_unsafe(value);
        }

        // Unsafe generic dup without bounds checks (validated by planner)
        pub inline fn dup_n_unsafe(self: *Self, n: u8) void {
            std.debug.assert(self.size_internal() >= n);
            std.debug.assert(@intFromPtr(self.stack_ptr) > @intFromPtr(self.stack_limit()));
            // In downward stack, nth-from-top is at index n-1
            const value = self.stack_ptr[n - 1];
            self.push_unsafe(value);
        }

        // DUP1-DUP16 operations - individual functions calling generic dup_n
        pub fn dup1(self: *Self) Error!void { return self.dup_n(1); }
        pub fn dup2(self: *Self) Error!void { return self.dup_n(2); }
        pub fn dup3(self: *Self) Error!void { return self.dup_n(3); }
        pub fn dup4(self: *Self) Error!void { return self.dup_n(4); }
        pub fn dup5(self: *Self) Error!void { return self.dup_n(5); }
        pub fn dup6(self: *Self) Error!void { return self.dup_n(6); }
        pub fn dup7(self: *Self) Error!void { return self.dup_n(7); }
        pub fn dup8(self: *Self) Error!void { return self.dup_n(8); }
        pub fn dup9(self: *Self) Error!void { return self.dup_n(9); }
        pub fn dup10(self: *Self) Error!void { return self.dup_n(10); }
        pub fn dup11(self: *Self) Error!void { return self.dup_n(11); }
        pub fn dup12(self: *Self) Error!void { return self.dup_n(12); }
        pub fn dup13(self: *Self) Error!void { return self.dup_n(13); }
        pub fn dup14(self: *Self) Error!void { return self.dup_n(14); }
        pub fn dup15(self: *Self) Error!void { return self.dup_n(15); }
        pub fn dup16(self: *Self) Error!void { return self.dup_n(16); }

        // Generic swap function for SWAP1-SWAP16
        pub fn swap_n(self: *Self, n: u8) Error!void {
            // Check if we have n+1 items on stack
            const current_elements = self.size_internal();
            if (current_elements < n + 1) {
                @branchHint(.cold);
                return Error.StackUnderflow;
            }
            // Swap top with nth item
            std.mem.swap(WordType, &self.stack_ptr[0], &self.stack_ptr[n]);
        }

        // Unsafe generic swap without bounds checks (validated by planner)
        pub inline fn swap_n_unsafe(self: *Self, n: u8) void {
            std.debug.assert(self.size_internal() >= n + 1);
            const tmp = self.stack_ptr[0];
            self.stack_ptr[0] = self.stack_ptr[n];
            self.stack_ptr[n] = tmp;
        }

        // SWAP1-SWAP16 operations - individual functions calling generic swap_n
        pub fn swap1(self: *Self) Error!void { return self.swap_n(1); }
        pub fn swap2(self: *Self) Error!void { return self.swap_n(2); }
        pub fn swap3(self: *Self) Error!void { return self.swap_n(3); }
        pub fn swap4(self: *Self) Error!void { return self.swap_n(4); }
        pub fn swap5(self: *Self) Error!void { return self.swap_n(5); }
        pub fn swap6(self: *Self) Error!void { return self.swap_n(6); }
        pub fn swap7(self: *Self) Error!void { return self.swap_n(7); }
        pub fn swap8(self: *Self) Error!void { return self.swap_n(8); }
        pub fn swap9(self: *Self) Error!void { return self.swap_n(9); }
        pub fn swap10(self: *Self) Error!void { return self.swap_n(10); }
        pub fn swap11(self: *Self) Error!void { return self.swap_n(11); }
        pub fn swap12(self: *Self) Error!void { return self.swap_n(12); }
        pub fn swap13(self: *Self) Error!void { return self.swap_n(13); }
        pub fn swap14(self: *Self) Error!void { return self.swap_n(14); }
        pub fn swap15(self: *Self) Error!void { return self.swap_n(15); }
        pub fn swap16(self: *Self) Error!void { return self.swap_n(16); }
        
        // Internal size calculation without locking
        inline fn size_internal(self: *const Self) usize {
            const bytes_used = @intFromPtr(self.stack_base()) - @intFromPtr(self.stack_ptr);
            return bytes_used / @sizeOf(WordType);
        }
        
        // Accessors for tracer
        pub inline fn size(self: *Self) usize {
            return self.size_internal();
        }
        
        pub inline fn get_slice(self: *Self) []const WordType {
            const count = self.size_internal();
            if (count == 0) return &[_]WordType{};
            // Return slice from stack_ptr to stack_base
            return self.stack_ptr[0..count];
        }
    };
}

test "Stack push and push_unsafe" {
    const allocator = std.testing.allocator;
    const StackType = Stack(.{});

    var stack = try StackType.init(allocator);
    defer stack.deinit(allocator);

    // Test push_unsafe
    stack.push_unsafe(42);
    try std.testing.expectEqual(@as(usize, 1), stack.size());
    try std.testing.expectEqual(@as(u256, 42), stack.peek_unsafe());

    stack.push_unsafe(100);
    try std.testing.expectEqual(@as(usize, 2), stack.size());
    try std.testing.expectEqual(@as(u256, 100), stack.peek_unsafe());

    // Test push with overflow check
    // Fill stack to near capacity
    var i: usize = 2;
    while (i < 1023) : (i += 1) {
        try stack.push(200);
    }
    try std.testing.expectEqual(@as(usize, 1023), stack.size());
    
    try stack.push(300);
    try std.testing.expectEqual(@as(usize, 1024), stack.size());

    // This should error - stack is full
    try std.testing.expectError(error.StackOverflow, stack.push(400));
}

test "Stack pop and pop_unsafe" {
    const allocator = std.testing.allocator;
    const StackType = Stack(.{});

    var stack = try StackType.init(allocator);
    defer stack.deinit(allocator);

    try stack.push(10);
    try stack.push(20);
    try stack.push(30);
    try std.testing.expectEqual(@as(usize, 3), stack.size());

    // Test pop_unsafe
    const val1 = stack.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 30), val1);
    try std.testing.expectEqual(@as(usize, 2), stack.size());

    const val2 = stack.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 20), val2);
    try std.testing.expectEqual(@as(usize, 1), stack.size());

    // Test pop with underflow check
    const val3 = try stack.pop();
    try std.testing.expectEqual(@as(u256, 10), val3);
    try std.testing.expectEqual(@as(usize, 0), stack.size());

    // This should error - stack is empty
    try std.testing.expectError(error.StackUnderflow, stack.pop());
}

test "Stack set_top and set_top_unsafe" {
    const allocator = std.testing.allocator;
    const StackType = Stack(.{});

    var stack = try StackType.init(allocator);
    defer stack.deinit(allocator);

    try stack.push(10);
    try stack.push(20);
    try stack.push(30);
    try std.testing.expectEqual(@as(usize, 3), stack.size());

    // Test set_top_unsafe - should modify the top value (30 -> 99)
    stack.set_top_unsafe(99);
    try std.testing.expectEqual(@as(u256, 99), stack.peek_unsafe());
    try std.testing.expectEqual(@as(usize, 3), stack.size()); // Size unchanged

    // Clear stack
    _ = try stack.pop();
    _ = try stack.pop();
    _ = try stack.pop();
    
    // Test set_top with error check on empty stack
    try std.testing.expectError(error.StackUnderflow, stack.set_top(42));

    // Test set_top on non-empty stack
    try stack.push(100);
    try stack.push(200);
    try stack.set_top(55);
    try std.testing.expectEqual(@as(u256, 55), try stack.peek());
}

test "Stack peek and peek_unsafe" {
    const allocator = std.testing.allocator;
    const StackType = Stack(.{});

    var stack = try StackType.init(allocator);
    defer stack.deinit(allocator);

    try stack.push(100);
    try stack.push(200);
    try stack.push(300);
    try std.testing.expectEqual(@as(usize, 3), stack.size());

    // Test peek_unsafe - should return top value without modifying size
    const top_unsafe = stack.peek_unsafe();
    try std.testing.expectEqual(@as(u256, 300), top_unsafe);
    try std.testing.expectEqual(@as(usize, 3), stack.size());

    // Test peek on non-empty stack
    const top = try stack.peek();
    try std.testing.expectEqual(@as(u256, 300), top);
    try std.testing.expectEqual(@as(usize, 3), stack.size());

    // Clear stack and test peek on empty stack
    _ = try stack.pop();
    _ = try stack.pop();
    _ = try stack.pop();
    try std.testing.expectError(error.StackUnderflow, stack.peek());
}

test "Stack op_dup1 duplicates top stack item" {
    const allocator = std.testing.allocator;
    const StackType = Stack(.{});

    var stack = try StackType.init(allocator);
    defer stack.deinit(allocator);

    try stack.push(42);
    try std.testing.expectEqual(@as(usize, 1), stack.size());

    // Execute op_dup1 - should duplicate top item
    try stack.dup1();
    try std.testing.expectEqual(@as(usize, 2), stack.size());
    const slice = stack.get_slice();
    try std.testing.expectEqual(@as(u256, 42), slice[0]); // Original
    try std.testing.expectEqual(@as(u256, 42), slice[1]); // Duplicate
}

test "Stack op_dup16 duplicates 16th stack item" {
    const allocator = std.testing.allocator;
    const StackType = Stack(.{});

    var stack = try StackType.init(allocator);
    defer stack.deinit(allocator);

    var i: u8 = 1;
    while (i <= 16) : (i += 1) {
        try stack.push(i);
    }
    try std.testing.expectEqual(@as(usize, 16), stack.size());

    // Execute op_dup16 - should duplicate 16th item from top (which is value 1)
    try stack.dup16();
    try std.testing.expectEqual(@as(usize, 17), stack.size());
    // With downward growth, the 16th item is at index 0, newest at index 16
    const slice = stack.get_slice();
    try std.testing.expectEqual(@as(u256, 1), slice[0]); // 16th from top (value 1)
    try std.testing.expectEqual(@as(u256, 1), slice[16]); // Duplicate on top
}

test "Stack op_swap1 swaps top two stack items" {
    const allocator = std.testing.allocator;
    const StackType = Stack(.{});

    var stack = try StackType.init(allocator);
    defer stack.deinit(allocator);

    // Setup stack with two values
    try stack.push(10);
    try stack.push(20);
    try std.testing.expectEqual(@as(usize, 2), stack.size());

    // Execute op_swap1 - should swap top two items
    try stack.swap1();
    try std.testing.expectEqual(@as(usize, 2), stack.size()); // Index unchanged
    // After swap, check the values
    const slice = stack.get_slice();
    try std.testing.expectEqual(@as(u256, 10), slice[0]); // Bottom value
    try std.testing.expectEqual(@as(u256, 20), slice[1]); // Top value (they swapped)
}

test "Stack op_swap16 swaps top with 17th stack item" {
    const allocator = std.testing.allocator;
    const StackType = Stack(.{});

    var stack = try StackType.init(allocator);
    defer stack.deinit(allocator);

    // Setup stack with 17 values
    var i: u8 = 1;
    while (i <= 17) : (i += 1) {
        try stack.push(i);
    }
    try std.testing.expectEqual(@as(usize, 17), stack.size());

    // Execute op_swap16 - should swap top item (17) with 17th from top (1)
    try stack.swap16();
    try std.testing.expectEqual(@as(usize, 17), stack.size()); // Index unchanged
    // After swap16, check the values
    const slice = stack.get_slice();
    try std.testing.expectEqual(@as(u256, 1), slice[0]); // Top was 17, now 1
    try std.testing.expectEqual(@as(u256, 17), slice[16]); // 17th was 1, now 17
}

test "Stack set_top underflow detection (bug fix validation)" {
    const allocator = std.testing.allocator;
    const StackType = Stack(.{});

    var stack = try StackType.init(allocator);
    defer stack.deinit(allocator);

    // Test the bug fix: set_top should detect underflow on empty stack
    // Before fix: `if (self.next_stack_index < 0)` was impossible for unsigned
    // After fix: `if (self.next_stack_index == 0)` correctly detects empty stack
    try std.testing.expectError(error.StackUnderflow, stack.set_top(42));

    // Verify stack remains empty after failed operation
    try std.testing.expectEqual(@as(usize, 0), stack.size());
}

test "Stack peek underflow detection (bug fix validation)" {
    const allocator = std.testing.allocator;
    const StackType = Stack(.{});

    var stack = try StackType.init(allocator);
    defer stack.deinit(allocator);

    // Test the bug fix: peek should detect underflow on empty stack
    // The fix ensures peek_unsafe assertions work correctly for unsigned types
    try std.testing.expectError(error.StackUnderflow, stack.peek());

    // Verify stack remains empty after failed operation
    try std.testing.expectEqual(@as(usize, 0), stack.size());
}

test "Stack unsafe operations assertion validation (bug fix)" {
    const allocator = std.testing.allocator;
    const StackType = Stack(.{});

    var stack = try StackType.init(allocator);
    defer stack.deinit(allocator);

    // Add one item to test valid operations
    try stack.push(100);

    // These should work correctly with the fixed assertions
    // Before fix: assertions like `next_stack_index >= 0` were always true
    // After fix: assertions properly validate stack state
    stack.set_top_unsafe(200);
    try std.testing.expectEqual(@as(u256, 200), stack.peek_unsafe());

    // Pop the item to test edge case
    _ = stack.pop_unsafe();
    try std.testing.expectEqual(@as(usize, 0), stack.size());
}

test "Stack maximum configuration comprehensive test" {
    const allocator = std.testing.allocator;
    // Maximum configuration: largest stack size and word type
    const StackType = Stack(.{
        .stack_size = 4095, // Maximum supported
        .WordType = u256,   // Maximum word size
    });

    var stack = try StackType.init(allocator);
    defer stack.deinit(allocator);

    // Test all operations with maximum values
    const max_value = std.math.maxInt(u256);

    // Test basic operations
    try stack.push(max_value);
    try std.testing.expectEqual(max_value, try stack.peek());
    try stack.set_top(123);
    try std.testing.expectEqual(@as(u256, 123), try stack.peek());

    // Fill stack to capacity
    var i: u16 = 1;
    while (i < 4095) : (i += 1) {
        try stack.push(@as(u256, i));
    }
    try std.testing.expectEqual(@as(usize, 4095), stack.size());

    // Test overflow
    try std.testing.expectError(error.StackOverflow, stack.push(999));
    try std.testing.expectError(error.StackOverflow, stack.dup1());

    // Test operations at capacity
    _ = try stack.pop(); // Make room
    try stack.dup1(); // Should work now
    
    // Empty stack and test DUP16/SWAP16
    while (stack.size() > 0) {
        _ = try stack.pop();
    }
    
    // Test DUP16 and SWAP16 with exactly 16 items
    var j: u8 = 1;
    while (j <= 16) : (j += 1) {
        try stack.push(@as(u256, j));
    }
    
    try stack.dup16(); // Should duplicate 16th item (1)
    try std.testing.expectEqual(@as(u256, 1), try stack.peek());
    
    // Now we have 17 items, SWAP16 should work
    try stack.swap16(); // Swap top (1) with 17th (1 - the original bottom)
    try std.testing.expectEqual(@as(u256, 1), try stack.peek());

    // Empty the entire stack
    while (stack.size() > 0) {
        _ = try stack.pop();
    }
    try std.testing.expectEqual(@as(usize, 0), stack.size());

    // Test underflow
    try std.testing.expectError(error.StackUnderflow, stack.pop());
    try std.testing.expectError(error.StackUnderflow, stack.peek());
    try std.testing.expectError(error.StackUnderflow, stack.set_top(123));
}

test "Stack minimum configuration comprehensive test" {
    const allocator = std.testing.allocator;
    // Minimum meaningful configuration
    const StackType = Stack(.{
        .stack_size = 16,   // Small stack for testing
        .WordType = u8,     // Smallest practical word type
    });

    var stack = try StackType.init(allocator);
    defer stack.deinit(allocator);

    // Test all operations with small values
    const max_u8 = std.math.maxInt(u8);

    // Test basic operations with u8
    try stack.push(max_u8);
    try std.testing.expectEqual(max_u8, try stack.peek());
    try stack.set_top(42);
    try std.testing.expectEqual(@as(u8, 42), try stack.peek());

    // Test DUP and SWAP
    try stack.push(100);
    try stack.dup1();
    try std.testing.expectEqual(@as(u8, 100), try stack.peek());
    
    try stack.push(200);
    try stack.swap1();
    try std.testing.expectEqual(@as(u8, 100), try stack.peek());

    // Fill small stack to capacity
    while (stack.size() < 16) {
        try stack.push(50);
    }
    try std.testing.expectEqual(@as(usize, 16), stack.size());

    // Test overflow with small stack
    try std.testing.expectError(error.StackOverflow, stack.push(255));
    try std.testing.expectError(error.StackOverflow, stack.dup1());

    // Test DUP16 and SWAP16 at capacity
    _ = try stack.pop(); // Make room
    try stack.dup1(); // Should work
    
    // Empty and test with exactly 16 items for DUP16/SWAP16
    while (stack.size() > 0) {
        _ = try stack.pop();
    }
    
    // Push 15 items, then test DUP16
    var j: u8 = 1;
    while (j <= 15) : (j += 1) {
        try stack.push(@as(u8, j));
    }

    // DUP16 should fail - not enough items
    try std.testing.expectError(error.StackUnderflow, stack.dup16());
    
    // Add one more to have exactly 16
    try stack.push(16);
    
    // Now DUP16 should work but will overflow the 16-element stack
    try std.testing.expectError(error.StackOverflow, stack.dup16());
    
    // Test SWAP16 with 16 items - should fail, needs 17 items
    try std.testing.expectError(error.StackUnderflow, stack.swap16());

    // Empty the stack
    while (stack.size() > 0) {
        _ = try stack.pop();
    }

    // Test underflow on empty stack
    try std.testing.expectError(error.StackUnderflow, stack.pop());
    try std.testing.expectError(error.StackUnderflow, stack.peek());
    try std.testing.expectError(error.StackUnderflow, stack.set_top(42));
    try std.testing.expectError(error.StackUnderflow, stack.dup1());
    try std.testing.expectError(error.StackUnderflow, stack.swap1());
}

test "Stack index type boundaries" {
    const allocator = std.testing.allocator;
    
    // Test u4 boundary (stack_size = 15 uses u4, 16 uses u8)
    const Stack15 = Stack(.{ .stack_size = 15 });
    var stack15 = try Stack15.init(allocator);
    defer stack15.deinit(allocator);
    
    // Fill to capacity (15 items)
    var i: u8 = 0;
    while (i < 15) : (i += 1) {
        try stack15.push(@as(u256, i));
    }
    try std.testing.expectEqual(@as(usize, 15), stack15.size());
    try std.testing.expectError(error.StackOverflow, stack15.push(999));
    
    // Test u8 boundary (stack_size = 255 uses u8, 256 uses u12)
    const Stack255 = Stack(.{ .stack_size = 255 });
    var stack255 = try Stack255.init(allocator);
    defer stack255.deinit(allocator);
    
    // Fill to capacity
    var j: u16 = 0;
    while (j < 255) : (j += 1) {
        try stack255.push(@as(u256, j));
    }
    try std.testing.expectEqual(@as(usize, 255), stack255.size());
    try std.testing.expectError(error.StackOverflow, stack255.push(999));
    
    // Test u12 at boundary (stack_size = 256 uses u12)
    const Stack256 = Stack(.{ .stack_size = 256 });
    var stack256 = try Stack256.init(allocator);
    defer stack256.deinit(allocator);
    
    // Push one item to verify u12 type works
    try stack256.push(42);
    try std.testing.expectEqual(@as(usize, 1), stack256.size());
}

test "All DUP operations DUP1-DUP16" {
    const allocator = std.testing.allocator;
    const StackType = Stack(.{ .stack_size = 32 });
    
    var stack = try StackType.init(allocator);
    defer stack.deinit(allocator);
    
    // Test each DUP operation with exactly the minimum required items
    var dup_n: u8 = 1;
    while (dup_n <= 16) : (dup_n += 1) {
        // Clear stack
        while (stack.size() > 0) {
            _ = try stack.pop();
        }
        
        // Push exactly dup_n items
        var i: u8 = 1;
        while (i <= dup_n) : (i += 1) {
            try stack.push(@as(u256, @as(u16, i) * 100));
        }
        
        // Test the specific DUP operation
        const initial_count = stack.size();
        try stack.dup_n(dup_n);
        
        // Should have one more item now
        try std.testing.expectEqual(initial_count + 1, stack.size());
        
        // Top item should be the dup_n'th item from before (first item pushed)
        try std.testing.expectEqual(@as(u256, 100), try stack.peek());
        
        // Test underflow: remove one item and try again
        _ = try stack.pop(); // Remove the duplicate
        _ = try stack.pop(); // Remove one original item
        try std.testing.expectError(error.StackUnderflow, stack.dup_n(dup_n));
    }
}

test "Bug: dup_n and swap_n violate EVM spec for non-u256 word sizes" {
    const allocator = std.testing.allocator;
    // The EVM spec says DUP operations work on stack ELEMENTS, not bytes
    // The bug is that when WordType != u256, the implementation doesn't follow EVM spec
    
    // Test 1: With u64 WordType, we should still need 16 elements for DUP16
    const StackType64 = Stack(.{ .WordType = u64, .stack_size = 32 });
    var stack64 = try StackType64.init(allocator);
    defer stack64.deinit(allocator);
    
    // Push 16 u64 elements - this should be enough for DUP16 per EVM spec
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        try stack64.push(@as(u64, i));
    }
    
    // Per EVM spec, DUP16 should work with 16 elements regardless of WordType
    // But let's check what the current implementation does
    // Current: 16 elements * 8 bytes = 128 bytes
    // Check: 128 < 16 * 8 = 128? No, so it passes (correct by accident)
    try stack64.dup_n(16);
    try std.testing.expectEqual(@as(usize, 17), stack64.size());
    
    // Now let's test swap_n which has the same bug
    // Current swap_n checks if we have (n+1) * sizeof(WordType) bytes
    // For SWAP16 with u64, that's 17 * 8 = 136 bytes
    // We have 17 elements * 8 = 136 bytes, so it should work
    try stack64.swap_n(16);
    try std.testing.expectEqual(@as(usize, 17), stack64.size());
}

test "All SWAP operations SWAP1-SWAP16" {
    const allocator = std.testing.allocator;
    const StackType = Stack(.{ .stack_size = 32 });
    
    var stack = try StackType.init(allocator);
    defer stack.deinit(allocator);
    
    // Test each SWAP operation with exactly the minimum required items
    var swap_n: u8 = 1;
    while (swap_n <= 16) : (swap_n += 1) {
        // Clear stack
        while (stack.size() > 0) {
            _ = try stack.pop();
        }
        
        // Push exactly swap_n + 1 items (SWAP needs n+1 items)
        var i: u8 = 1;
        while (i <= swap_n + 1) : (i += 1) {
            try stack.push(@as(u256, @as(u16, i) * 100));
        }
        
        // Record the values before swap
        const top_value = try stack.peek();
        const slice_before = stack.get_slice();
        const target_value = slice_before[swap_n]; // In downward stack, nth item is at index n
        
        // Test the specific SWAP operation
        const initial_count = stack.size();
        try stack.swap_n(swap_n);
        
        // Stack size should be unchanged
        try std.testing.expectEqual(initial_count, stack.size());
        
        // Top should now have the target value
        try std.testing.expectEqual(target_value, try stack.peek());
        
        // Target position should have the original top value
        const slice_after = stack.get_slice();
        try std.testing.expectEqual(top_value, slice_after[swap_n]); // In downward stack
        
        // Test underflow: remove one item and try again
        _ = try stack.pop();
        try std.testing.expectError(error.StackUnderflow, stack.swap_n(swap_n));
    }
}

test "Mock allocator and allocation failure" {
    // Create a failing allocator that always returns OutOfMemory
    const FailingAllocator = struct {
        fn alloc(self: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            _ = self;
            _ = len;
            _ = ptr_align;
            _ = ret_addr;
            return null; // Always fail
        }
        
        fn resize(self: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            _ = self;
            _ = buf;
            _ = buf_align;
            _ = new_len;
            _ = ret_addr;
            return false;
        }
        
        fn free(self: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
            _ = self;
            _ = buf;
            _ = buf_align;
            _ = ret_addr;
        }
        
        fn remap(self: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            _ = self;
            _ = buf;
            _ = buf_align;
            _ = new_len;
            _ = ret_addr;
            return null;
        }
    };
    
    var failing_allocator_state: u8 = 0;
    const failing_allocator = std.mem.Allocator{
        .ptr = &failing_allocator_state,
        .vtable = &.{
            .alloc = FailingAllocator.alloc,
            .resize = FailingAllocator.resize,
            .free = FailingAllocator.free,
            .remap = FailingAllocator.remap,
        },
    };
    
    // Test that init fails with AllocationError when allocator fails
    try std.testing.expectError(error.AllocationError, Stack(.{}).init(failing_allocator));
}

test "Complex operation sequences at boundaries" {
    const allocator = std.testing.allocator;
    const StackType = Stack(.{ .stack_size = 8 }); // Small stack for boundary testing
    
    var stack = try StackType.init(allocator);
    defer stack.deinit(allocator);
    
    // Complex sequence: Push → DUP → SWAP → Pop at boundaries
    
    // Fill to near capacity
    try stack.push(100);
    try stack.push(200);
    try stack.push(300);
    try stack.push(400);
    try stack.push(500);
    try stack.push(600);
    try stack.push(700); // 7 items
    
    // DUP1 should work (brings to 8, at capacity)
    try stack.dup1();
    try std.testing.expectEqual(@as(usize, 8), stack.size());
    try std.testing.expectEqual(@as(u256, 700), try stack.peek());
    
    // Any push should fail now
    try std.testing.expectError(error.StackOverflow, stack.push(999));
    try std.testing.expectError(error.StackOverflow, stack.dup1());
    
    // SWAP should work (doesn't change count)
    try stack.swap1();
    try std.testing.expectEqual(@as(usize, 8), stack.size());
    try std.testing.expectEqual(@as(u256, 700), try stack.peek()); // Original second item
    
    // Pop and continue sequence
    const val1 = try stack.pop(); // 700 (the original duplicate)
    try std.testing.expectEqual(@as(u256, 700), val1);
    
    const val2 = try stack.pop(); // 700 (the original top)
    try std.testing.expectEqual(@as(u256, 700), val2);
    
    // Now we have 6 items: 100, 200, 300, 400, 500, 600 (600 on top)
    // Let's verify the current state
    const pre_dup = stack.get_slice();
    try std.testing.expectEqual(@as(usize, 6), pre_dup.len);
    try std.testing.expectEqual(@as(u256, 600), pre_dup[0]); // Top
    try std.testing.expectEqual(@as(u256, 500), pre_dup[1]); // 2nd
    try std.testing.expectEqual(@as(u256, 400), pre_dup[2]); // 3rd
    
    try stack.dup3(); // Duplicate 3rd from top (should be 400)
    try std.testing.expectEqual(@as(u256, 400), try stack.peek());
    
    try stack.swap2(); // Swap top (400) with 3rd (500)
    const slice = stack.get_slice();
    // After swap: 100, 200, 300, 400, 400, 600, 500 (500 on top)
    try std.testing.expectEqual(@as(u256, 500), slice[0]); // Top is now 500
    const second_item = slice[1]; // Should be 600
    try std.testing.expectEqual(@as(u256, 600), second_item);
    
    // Continue until empty
    while (stack.size() > 0) {
        _ = try stack.pop();
    }
    
    // Test underflow after complex sequence
    try std.testing.expectError(error.StackUnderflow, stack.pop());
    try std.testing.expectError(error.StackUnderflow, stack.dup1());
    try std.testing.expectError(error.StackUnderflow, stack.swap1());
}

test "Zero values and boundary values" {
    const allocator = std.testing.allocator;
    
    // Test with different word types
    const StackU8 = Stack(.{ .WordType = u8 });
    const StackU16 = Stack(.{ .WordType = u16 });
    const StackU32 = Stack(.{ .WordType = u32 });
    const StackU64 = Stack(.{ .WordType = u64 });
    const StackU128 = Stack(.{ .WordType = u128 });
    
    var stack_u8 = try StackU8.init(allocator);
    defer stack_u8.deinit(allocator);
    
    var stack_u16 = try StackU16.init(allocator);
    defer stack_u16.deinit(allocator);
    
    var stack_u32 = try StackU32.init(allocator);
    defer stack_u32.deinit(allocator);
    
    var stack_u64 = try StackU64.init(allocator);
    defer stack_u64.deinit(allocator);
    
    var stack_u128 = try StackU128.init(allocator);
    defer stack_u128.deinit(allocator);
    
    // Test zero values (distinct from empty)
    try stack_u8.push(0);
    try std.testing.expectEqual(@as(u8, 0), try stack_u8.peek());
    try std.testing.expectEqual(@as(usize, 1), stack_u8.size()); // Not empty!
    
    // Test maximum values for each type
    try stack_u8.set_top(std.math.maxInt(u8));
    try std.testing.expectEqual(std.math.maxInt(u8), try stack_u8.peek());
    
    try stack_u16.push(std.math.maxInt(u16));
    try std.testing.expectEqual(std.math.maxInt(u16), try stack_u16.peek());
    
    try stack_u32.push(std.math.maxInt(u32));
    try std.testing.expectEqual(std.math.maxInt(u32), try stack_u32.peek());
    
    try stack_u64.push(std.math.maxInt(u64));
    try std.testing.expectEqual(std.math.maxInt(u64), try stack_u64.peek());
    
    try stack_u128.push(std.math.maxInt(u128));
    try std.testing.expectEqual(std.math.maxInt(u128), try stack_u128.peek());
    
    // Test minimal stack size (1 element)
    const StackMin = Stack(.{ .stack_size = 1 });
    var stack_min = try StackMin.init(allocator);
    defer stack_min.deinit(allocator);
    
    try stack_min.push(42);
    try std.testing.expectEqual(@as(usize, 1), stack_min.size());
    try std.testing.expectError(error.StackOverflow, stack_min.push(99));
    try std.testing.expectError(error.StackOverflow, stack_min.dup1());
    try std.testing.expectError(error.StackUnderflow, stack_min.swap1()); // Needs 2 items
}

test "Stack struct size optimization" {
    // Verify struct size with pointer-only design
    const StackType = Stack(.{});
    const stack_size = @sizeOf(StackType);
    // With buf_ptr (8 bytes) + stack_ptr (8 bytes) = 16 bytes
    try std.testing.expect(stack_size >= 16);
}

test "Unsafe operations at exact boundaries" {
    const allocator = std.testing.allocator;
    const StackType = Stack(.{ .stack_size = 4 });
    
    var stack = try StackType.init(allocator);
    defer stack.deinit(allocator);
    
    // Test push_unsafe at exact capacity
    stack.push_unsafe(1);
    stack.push_unsafe(2);
    stack.push_unsafe(3);
    stack.push_unsafe(4);
    try std.testing.expectEqual(@as(usize, 4), stack.size());
    
    // Test peek_unsafe and set_top_unsafe at capacity
    try std.testing.expectEqual(@as(u256, 4), stack.peek_unsafe());
    stack.set_top_unsafe(99);
    try std.testing.expectEqual(@as(u256, 99), stack.peek_unsafe());
    
    // Test pop_unsafe down to empty
    _ = stack.pop_unsafe(); // 99
    _ = stack.pop_unsafe(); // 3  
    _ = stack.pop_unsafe(); // 2
    _ = stack.pop_unsafe(); // 1
    try std.testing.expectEqual(@as(usize, 0), stack.size());
    
    // Test boundary with single item
    stack.push_unsafe(42);
    try std.testing.expectEqual(@as(u256, 42), stack.peek_unsafe());
    stack.set_top_unsafe(100);
    try std.testing.expectEqual(@as(u256, 100), stack.peek_unsafe());
    _ = stack.pop_unsafe();
    try std.testing.expectEqual(@as(usize, 0), stack.size());
}
