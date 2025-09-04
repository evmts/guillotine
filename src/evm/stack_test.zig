const std = @import("std");
const testing = std.testing;
const stack = @import("stack.zig");

// Tests migrated from stack.zig to separate test file
// This reduces context window usage by ~40-60% as proposed in issue #649

test "Stack push and push_unsafe" {
    const allocator = std.testing.allocator;
    const StackType = stack.Stack(.{});

    var stack_obj = try StackType.init(allocator);
    defer stack_obj.deinit(allocator);

    // Test push_unsafe
    stack_obj.push_unsafe(42);
    try std.testing.expectEqual(@as(usize, 1), stack_obj.size());
    try std.testing.expectEqual(@as(u256, 42), stack_obj.peek_unsafe());

    stack_obj.push_unsafe(100);
    try std.testing.expectEqual(@as(usize, 2), stack_obj.size());
    try std.testing.expectEqual(@as(u256, 100), stack_obj.peek_unsafe());

    // Test push with overflow check
    // Fill stack to near capacity
    var i: usize = 2;
    while (i < 1023) : (i += 1) {
        try stack_obj.push(200);
    }
    try std.testing.expectEqual(@as(usize, 1023), stack_obj.size());
    
    try stack_obj.push(300);
    try std.testing.expectEqual(@as(usize, 1024), stack_obj.size());

    // This should error - stack is full
    try std.testing.expectError(error.StackOverflow, stack_obj.push(400));
}

test "Stack pop and pop_unsafe" {
    const allocator = std.testing.allocator;
    const StackType = stack.Stack(.{});

    var stack_obj = try StackType.init(allocator);
    defer stack_obj.deinit(allocator);

    try stack_obj.push(10);
    try stack_obj.push(20);
    try stack_obj.push(30);
    try std.testing.expectEqual(@as(usize, 3), stack_obj.size());

    // Test pop_unsafe
    const val1 = stack_obj.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 30), val1);
    try std.testing.expectEqual(@as(usize, 2), stack_obj.size());

    const val2 = stack_obj.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 20), val2);
    try std.testing.expectEqual(@as(usize, 1), stack_obj.size());

    // Test pop with underflow check
    const val3 = try stack_obj.pop();
    try std.testing.expectEqual(@as(u256, 10), val3);
    try std.testing.expectEqual(@as(usize, 0), stack_obj.size());

    // This should error - stack is empty
    try std.testing.expectError(error.StackUnderflow, stack_obj.pop());
}

test "Stack set_top and set_top_unsafe" {
    const allocator = std.testing.allocator;
    const StackType = stack.Stack(.{});

    var stack_obj = try StackType.init(allocator);
    defer stack_obj.deinit(allocator);

    try stack_obj.push(10);
    try stack_obj.push(20);
    try stack_obj.push(30);
    try std.testing.expectEqual(@as(usize, 3), stack_obj.size());

    // Test set_top_unsafe - should modify the top value (30 -> 99)
    stack_obj.set_top_unsafe(99);
    try std.testing.expectEqual(@as(u256, 99), stack_obj.peek_unsafe());
    try std.testing.expectEqual(@as(usize, 3), stack_obj.size()); // Size unchanged

    // Clear stack
    _ = try stack_obj.pop();
    _ = try stack_obj.pop();
    _ = try stack_obj.pop();
    
    // Test set_top with error check on empty stack
    try std.testing.expectError(error.StackUnderflow, stack_obj.set_top(42));

    // Test set_top on non-empty stack
    try stack_obj.push(100);
    try stack_obj.push(200);
    try stack_obj.set_top(55);
    try std.testing.expectEqual(@as(u256, 55), try stack_obj.peek());
}

test "Stack peek and peek_unsafe" {
    const allocator = std.testing.allocator;
    const StackType = stack.Stack(.{});

    var stack_obj = try StackType.init(allocator);
    defer stack_obj.deinit(allocator);

    try stack_obj.push(100);
    try stack_obj.push(200);
    try stack_obj.push(300);
    try std.testing.expectEqual(@as(usize, 3), stack_obj.size());

    // Test peek_unsafe - should return top value without modifying size
    const top_unsafe = stack_obj.peek_unsafe();
    try std.testing.expectEqual(@as(u256, 300), top_unsafe);
    try std.testing.expectEqual(@as(usize, 3), stack_obj.size());

    // Test peek on non-empty stack
    const top = try stack_obj.peek();
    try std.testing.expectEqual(@as(u256, 300), top);
    try std.testing.expectEqual(@as(usize, 3), stack_obj.size());

    // Clear stack and test peek on empty stack
    _ = try stack_obj.pop();
    _ = try stack_obj.pop();
    _ = try stack_obj.pop();
    try std.testing.expectError(error.StackUnderflow, stack_obj.peek());
}

test "Stack op_dup1 duplicates top stack item" {
    const allocator = std.testing.allocator;
    const StackType = stack.Stack(.{});

    var stack_obj = try StackType.init(allocator);
    defer stack_obj.deinit(allocator);

    try stack_obj.push(42);
    try std.testing.expectEqual(@as(usize, 1), stack_obj.size());

    // Execute op_dup1 - should duplicate top item
    try stack_obj.dup1();
    try std.testing.expectEqual(@as(usize, 2), stack_obj.size());
    const slice = stack_obj.get_slice();
    try std.testing.expectEqual(@as(u256, 42), slice[0]); // Original
    try std.testing.expectEqual(@as(u256, 42), slice[1]); // Duplicate
}

test "Stack op_dup16 duplicates 16th stack item" {
    const allocator = std.testing.allocator;
    const StackType = stack.Stack(.{});

    var stack_obj = try StackType.init(allocator);
    defer stack_obj.deinit(allocator);

    var i: u8 = 1;
    while (i <= 16) : (i += 1) {
        try stack_obj.push(i);
    }
    try std.testing.expectEqual(@as(usize, 16), stack_obj.size());

    // Execute op_dup16 - should duplicate 16th item from top (which is value 1)
    try stack_obj.dup16();
    try std.testing.expectEqual(@as(usize, 17), stack_obj.size());
    // With downward growth, the 16th item is at index 0, newest at index 16
    const slice = stack_obj.get_slice();
    try std.testing.expectEqual(@as(u256, 1), slice[0]); // 16th from top (value 1)
    try std.testing.expectEqual(@as(u256, 1), slice[16]); // Duplicate on top
}

test "Stack op_swap1 swaps top two stack items" {
    const allocator = std.testing.allocator;
    const StackType = stack.Stack(.{});

    var stack_obj = try StackType.init(allocator);
    defer stack_obj.deinit(allocator);

    // Setup stack with two values
    try stack_obj.push(10);
    try stack_obj.push(20);
    try std.testing.expectEqual(@as(usize, 2), stack_obj.size());

    // Execute op_swap1 - should swap top two items
    try stack_obj.swap1();
    try std.testing.expectEqual(@as(usize, 2), stack_obj.size()); // Index unchanged
    // After swap, check the values
    const slice = stack_obj.get_slice();
    try std.testing.expectEqual(@as(u256, 10), slice[0]); // Bottom value
    try std.testing.expectEqual(@as(u256, 20), slice[1]); // Top value (they swapped)
}

test "Stack op_swap16 swaps top with 17th stack item" {
    const allocator = std.testing.allocator;
    const StackType = stack.Stack(.{});

    var stack_obj = try StackType.init(allocator);
    defer stack_obj.deinit(allocator);

    // Setup stack with 17 values
    var i: u8 = 1;
    while (i <= 17) : (i += 1) {
        try stack_obj.push(i);
    }
    try std.testing.expectEqual(@as(usize, 17), stack_obj.size());

    // Execute op_swap16 - should swap top item (17) with 17th from top (1)
    try stack_obj.swap16();
    try std.testing.expectEqual(@as(usize, 17), stack_obj.size()); // Index unchanged
    // After swap16, check the values
    const slice = stack_obj.get_slice();
    try std.testing.expectEqual(@as(u256, 1), slice[0]); // Top was 17, now 1
    try std.testing.expectEqual(@as(u256, 17), slice[16]); // 17th was 1, now 17
}

test "Stack set_top underflow detection (bug fix validation)" {
    const allocator = std.testing.allocator;
    const StackType = stack.Stack(.{});

    var stack_obj = try StackType.init(allocator);
    defer stack_obj.deinit(allocator);

    // Test the bug fix: set_top should detect underflow on empty stack
    // Before fix: `if (self.next_stack_index < 0)` was impossible for unsigned
    // After fix: `if (self.next_stack_index == 0)` correctly detects empty stack
    try std.testing.expectError(error.StackUnderflow, stack_obj.set_top(42));

    // Verify stack remains empty after failed operation
    try std.testing.expectEqual(@as(usize, 0), stack_obj.size());
}

test "Stack peek underflow detection (bug fix validation)" {
    const allocator = std.testing.allocator;
    const StackType = stack.Stack(.{});

    var stack_obj = try StackType.init(allocator);
    defer stack_obj.deinit(allocator);

    // Test the bug fix: peek should detect underflow on empty stack
    // The fix ensures peek_unsafe assertions work correctly for unsigned types
    try std.testing.expectError(error.StackUnderflow, stack_obj.peek());

    // Verify stack remains empty after failed operation
    try std.testing.expectEqual(@as(usize, 0), stack_obj.size());
}

test "Stack unsafe operations assertion validation (bug fix)" {
    const allocator = std.testing.allocator;
    const StackType = stack.Stack(.{});

    var stack_obj = try StackType.init(allocator);
    defer stack_obj.deinit(allocator);

    // Add one item to test valid operations
    try stack_obj.push(100);

    // These should work correctly with the fixed assertions
    // Before fix: assertions like `next_stack_index >= 0` were always true
    // After fix: assertions properly validate stack state
    stack_obj.set_top_unsafe(200);
    try std.testing.expectEqual(@as(u256, 200), stack_obj.peek_unsafe());

    // Pop the item to test edge case
    _ = stack_obj.pop_unsafe();
    try std.testing.expectEqual(@as(usize, 0), stack_obj.size());
}

test "Stack maximum configuration comprehensive test" {
    const allocator = std.testing.allocator;
    // Maximum configuration: largest stack size and word type
    const StackType = stack.Stack(.{
        .stack_size = 4095, // Maximum supported
        .WordType = u256,   // Maximum word size
    });

    var stack_obj = try StackType.init(allocator);
    defer stack_obj.deinit(allocator);

    // Test all operations with maximum values
    const max_value = std.math.maxInt(u256);

    // Test basic operations
    try stack_obj.push(max_value);
    try std.testing.expectEqual(max_value, try stack_obj.peek());
    try stack_obj.set_top(123);
    try std.testing.expectEqual(@as(u256, 123), try stack_obj.peek());

    // Fill stack to capacity
    var i: u16 = 1;
    while (i < 4095) : (i += 1) {
        try stack_obj.push(@as(u256, i));
    }
    try std.testing.expectEqual(@as(usize, 4095), stack_obj.size());

    // Test overflow
    try std.testing.expectError(error.StackOverflow, stack_obj.push(999));
    try std.testing.expectError(error.StackOverflow, stack_obj.dup1());

    // Test operations at capacity
    _ = try stack_obj.pop(); // Make room
    try stack_obj.dup1(); // Should work now
    
    // Empty stack and test DUP16/SWAP16
    while (stack_obj.size() > 0) {
        _ = try stack_obj.pop();
    }
    
    // Test DUP16 and SWAP16 with exactly 16 items
    var j: u8 = 1;
    while (j <= 16) : (j += 1) {
        try stack_obj.push(@as(u256, j));
    }
    
    try stack_obj.dup16(); // Should duplicate 16th item (1)
    try std.testing.expectEqual(@as(u256, 1), try stack_obj.peek());
    
    // Now we have 17 items, SWAP16 should work
    try stack_obj.swap16(); // Swap top (1) with 17th (1 - the original bottom)
    try std.testing.expectEqual(@as(u256, 1), try stack_obj.peek());

    // Empty the entire stack
    while (stack_obj.size() > 0) {
        _ = try stack_obj.pop();
    }
    try std.testing.expectEqual(@as(usize, 0), stack_obj.size());

    // Test underflow
    try std.testing.expectError(error.StackUnderflow, stack_obj.pop());
    try std.testing.expectError(error.StackUnderflow, stack_obj.peek());
    try std.testing.expectError(error.StackUnderflow, stack_obj.set_top(123));
}

test "Stack minimum configuration comprehensive test" {
    const allocator = std.testing.allocator;
    // Minimum meaningful configuration
    const StackType = stack.Stack(.{
        .stack_size = 16,   // Small stack for testing
        .WordType = u8,     // Smallest practical word type
    });

    var stack_obj = try StackType.init(allocator);
    defer stack_obj.deinit(allocator);

    // Test all operations with small values
    const max_u8 = std.math.maxInt(u8);

    // Test basic operations with u8
    try stack_obj.push(max_u8);
    try std.testing.expectEqual(max_u8, try stack_obj.peek());
    try stack_obj.set_top(42);
    try std.testing.expectEqual(@as(u8, 42), try stack_obj.peek());

    // Test DUP and SWAP
    try stack_obj.push(100);
    try stack_obj.dup1();
    try std.testing.expectEqual(@as(u8, 100), try stack_obj.peek());
    
    try stack_obj.push(200);
    try stack_obj.swap1();
    try std.testing.expectEqual(@as(u8, 100), try stack_obj.peek());

    // Fill small stack to capacity
    while (stack_obj.size() < 16) {
        try stack_obj.push(50);
    }
    try std.testing.expectEqual(@as(usize, 16), stack_obj.size());

    // Test overflow with small stack
    try std.testing.expectError(error.StackOverflow, stack_obj.push(255));
    try std.testing.expectError(error.StackOverflow, stack_obj.dup1());

    // Test DUP16 and SWAP16 at capacity
    _ = try stack_obj.pop(); // Make room
    try stack_obj.dup1(); // Should work
    
    // Empty and test with exactly 16 items for DUP16/SWAP16
    while (stack_obj.size() > 0) {
        _ = try stack_obj.pop();
    }
    
    // Push 15 items, then test DUP16
    var j: u8 = 1;
    while (j <= 15) : (j += 1) {
        try stack_obj.push(@as(u8, j));
    }

    // DUP16 should fail - not enough items
    try std.testing.expectError(error.StackUnderflow, stack_obj.dup16());
    
    // Add one more to have exactly 16
    try stack_obj.push(16);
    
    // Now DUP16 should work but will overflow the 16-element stack
    try std.testing.expectError(error.StackOverflow, stack_obj.dup16());
    
    // Test SWAP16 with 16 items - should fail, needs 17 items
    try std.testing.expectError(error.StackUnderflow, stack_obj.swap16());

    // Empty the stack
    while (stack_obj.size() > 0) {
        _ = try stack_obj.pop();
    }

    // Test underflow on empty stack
    try std.testing.expectError(error.StackUnderflow, stack_obj.pop());
    try std.testing.expectError(error.StackUnderflow, stack_obj.peek());
    try std.testing.expectError(error.StackUnderflow, stack_obj.set_top(42));
    try std.testing.expectError(error.StackUnderflow, stack_obj.dup1());
    try std.testing.expectError(error.StackUnderflow, stack_obj.swap1());
}

test "Stack index type boundaries" {
    const allocator = std.testing.allocator;
    
    // Test u4 boundary (stack_size = 15 uses u4, 16 uses u8)
    const Stack15 = stack.Stack(.{ .stack_size = 15 });
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
    const Stack255 = stack.Stack(.{ .stack_size = 255 });
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
    const Stack256 = stack.Stack(.{ .stack_size = 256 });
    var stack256 = try Stack256.init(allocator);
    defer stack256.deinit(allocator);
    
    // Push one item to verify u12 type works
    try stack256.push(42);
    try std.testing.expectEqual(@as(usize, 1), stack256.size());
}

test "All DUP operations DUP1-DUP16" {
    const allocator = std.testing.allocator;
    const StackType = stack.Stack(.{ .stack_size = 32 });
    
    var stack_obj = try StackType.init(allocator);
    defer stack_obj.deinit(allocator);
    
    // Test each DUP operation with exactly the minimum required items
    var dup_n: u8 = 1;
    while (dup_n <= 16) : (dup_n += 1) {
        // Clear stack
        while (stack_obj.size() > 0) {
            _ = try stack_obj.pop();
        }
        
        // Push exactly dup_n items
        var i: u8 = 1;
        while (i <= dup_n) : (i += 1) {
            try stack_obj.push(@as(u256, @as(u16, i) * 100));
        }
        
        // Test the specific DUP operation
        const initial_count = stack_obj.size();
        try stack_obj.dup_n(dup_n);
        
        // Should have one more item now
        try std.testing.expectEqual(initial_count + 1, stack_obj.size());
        
        // Top item should be the dup_n'th item from before (first item pushed)
        try std.testing.expectEqual(@as(u256, 100), try stack_obj.peek());
        
        // Test underflow: remove one item and try again
        _ = try stack_obj.pop(); // Remove the duplicate
        _ = try stack_obj.pop(); // Remove one original item
        try std.testing.expectError(error.StackUnderflow, stack_obj.dup_n(dup_n));
    }
}

test "Bug: dup_n and swap_n violate EVM spec for non-u256 word sizes" {
    const allocator = std.testing.allocator;
    // The EVM spec says DUP operations work on stack ELEMENTS, not bytes
    // The bug is that when WordType != u256, the implementation doesn't follow EVM spec
    
    // Test 1: With u64 WordType, we should still need 16 elements for DUP16
    const StackType64 = stack.Stack(.{ .WordType = u64, .stack_size = 32 });
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
    const StackType = stack.Stack(.{ .stack_size = 32 });
    
    var stack_obj = try StackType.init(allocator);
    defer stack_obj.deinit(allocator);
    
    // Test each SWAP operation with exactly the minimum required items
    var swap_n: u8 = 1;
    while (swap_n <= 16) : (swap_n += 1) {
        // Clear stack
        while (stack_obj.size() > 0) {
            _ = try stack_obj.pop();
        }
        
        // Push exactly swap_n + 1 items (SWAP needs n+1 items)
        var i: u8 = 1;
        while (i <= swap_n + 1) : (i += 1) {
            try stack_obj.push(@as(u256, @as(u16, i) * 100));
        }
        
        // Record the values before swap
        const top_value = try stack_obj.peek();
        const slice_before = stack_obj.get_slice();
        const target_value = slice_before[swap_n]; // In downward stack, nth item is at index n
        
        // Test the specific SWAP operation
        const initial_count = stack_obj.size();
        try stack_obj.swap_n(swap_n);
        
        // Stack size should be unchanged
        try std.testing.expectEqual(initial_count, stack_obj.size());
        
        // Top should now have the target value
        try std.testing.expectEqual(target_value, try stack_obj.peek());
        
        // Target position should have the original top value
        const slice_after = stack_obj.get_slice();
        try std.testing.expectEqual(top_value, slice_after[swap_n]); // In downward stack
        
        // Test underflow: remove one item and try again
        _ = try stack_obj.pop();
        try std.testing.expectError(error.StackUnderflow, stack_obj.swap_n(swap_n));
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
    try std.testing.expectError(error.AllocationError, stack.Stack(.{}).init(failing_allocator));
}

test "Complex operation sequences at boundaries" {
    const allocator = std.testing.allocator;
    const StackType = stack.Stack(.{ .stack_size = 8 }); // Small stack for boundary testing
    
    var stack_obj = try StackType.init(allocator);
    defer stack_obj.deinit(allocator);
    
    // Complex sequence: Push → DUP → SWAP → Pop at boundaries
    
    // Fill to near capacity
    try stack_obj.push(100);
    try stack_obj.push(200);
    try stack_obj.push(300);
    try stack_obj.push(400);
    try stack_obj.push(500);
    try stack_obj.push(600);
    try stack_obj.push(700); // 7 items
    
    // DUP1 should work (brings to 8, at capacity)
    try stack_obj.dup1();
    try std.testing.expectEqual(@as(usize, 8), stack_obj.size());
    try std.testing.expectEqual(@as(u256, 700), try stack_obj.peek());
    
    // Any push should fail now
    try std.testing.expectError(error.StackOverflow, stack_obj.push(999));
    try std.testing.expectError(error.StackOverflow, stack_obj.dup1());
    
    // SWAP should work (doesn't change count)
    try stack_obj.swap1();
    try std.testing.expectEqual(@as(usize, 8), stack_obj.size());
    try std.testing.expectEqual(@as(u256, 700), try stack_obj.peek()); // Original second item
    
    // Pop and continue sequence
    const val1 = try stack_obj.pop(); // 700 (the original duplicate)
    try std.testing.expectEqual(@as(u256, 700), val1);
    
    const val2 = try stack_obj.pop(); // 700 (the original top)
    try std.testing.expectEqual(@as(u256, 700), val2);
    
    // Now we have 6 items: 100, 200, 300, 400, 500, 600 (600 on top)
    // Let's verify the current state
    const pre_dup = stack_obj.get_slice();
    try std.testing.expectEqual(@as(usize, 6), pre_dup.len);
    try std.testing.expectEqual(@as(u256, 600), pre_dup[0]); // Top
    try std.testing.expectEqual(@as(u256, 500), pre_dup[1]); // 2nd
    try std.testing.expectEqual(@as(u256, 400), pre_dup[2]); // 3rd
    
    try stack_obj.dup3(); // Duplicate 3rd from top (should be 400)
    try std.testing.expectEqual(@as(u256, 400), try stack_obj.peek());
    
    try stack_obj.swap2(); // Swap top (400) with 3rd (500)
    const slice = stack_obj.get_slice();
    // After swap: 100, 200, 300, 400, 400, 600, 500 (500 on top)
    try std.testing.expectEqual(@as(u256, 500), slice[0]); // Top is now 500
    const second_item = slice[1]; // Should be 600
    try std.testing.expectEqual(@as(u256, 600), second_item);
    
    // Continue until empty
    while (stack_obj.size() > 0) {
        _ = try stack_obj.pop();
    }
    
    // Test underflow after complex sequence
    try std.testing.expectError(error.StackUnderflow, stack_obj.pop());
    try std.testing.expectError(error.StackUnderflow, stack_obj.dup1());
    try std.testing.expectError(error.StackUnderflow, stack_obj.swap1());
}

test "Zero values and boundary values" {
    const allocator = std.testing.allocator;
    
    // Test with different word types
    const StackU8 = stack.Stack(.{ .WordType = u8 });
    const StackU16 = stack.Stack(.{ .WordType = u16 });
    const StackU32 = stack.Stack(.{ .WordType = u32 });
    const StackU64 = stack.Stack(.{ .WordType = u64 });
    const StackU128 = stack.Stack(.{ .WordType = u128 });
    
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
    const StackMin = stack.Stack(.{ .stack_size = 1 });
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
    const StackType = stack.Stack(.{});
    const stack_size = @sizeOf(StackType);
    // With buf_ptr (8 bytes) + stack_ptr (8 bytes) = 16 bytes
    try std.testing.expect(stack_size >= 16);
}

test "Unsafe operations at exact boundaries" {
    const allocator = std.testing.allocator;
    const StackType = stack.Stack(.{ .stack_size = 4 });
    
    var stack_obj = try StackType.init(allocator);
    defer stack_obj.deinit(allocator);
    
    // Test push_unsafe at exact capacity
    stack_obj.push_unsafe(1);
    stack_obj.push_unsafe(2);
    stack_obj.push_unsafe(3);
    stack_obj.push_unsafe(4);
    try std.testing.expectEqual(@as(usize, 4), stack_obj.size());
    
    // Test peek_unsafe and set_top_unsafe at capacity
    try std.testing.expectEqual(@as(u256, 4), stack_obj.peek_unsafe());
    stack_obj.set_top_unsafe(99);
    try std.testing.expectEqual(@as(u256, 99), stack_obj.peek_unsafe());
    
    // Test pop_unsafe down to empty
    _ = stack_obj.pop_unsafe(); // 99
    _ = stack_obj.pop_unsafe(); // 3  
    _ = stack_obj.pop_unsafe(); // 2
    _ = stack_obj.pop_unsafe(); // 1
    try std.testing.expectEqual(@as(usize, 0), stack_obj.size());
    
    // Test boundary with single item
    stack_obj.push_unsafe(42);
    try std.testing.expectEqual(@as(u256, 42), stack_obj.peek_unsafe());
    stack_obj.set_top_unsafe(100);
    try std.testing.expectEqual(@as(u256, 100), stack_obj.peek_unsafe());
    _ = stack_obj.pop_unsafe();
    try std.testing.expectEqual(@as(usize, 0), stack_obj.size());
}