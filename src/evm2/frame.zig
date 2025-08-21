const std = @import("std");
const builtin = @import("builtin");

pub const FrameOptions = struct {
    stack_size: usize = 1024,
    word_type: type = u256,
};

pub fn ColdFrame(comptime options: FrameOptions) type {
    if (options.stack_size > 4095) {
        @compileError("Stack size cannot exceed 4095");
    }
    
    if (@bitSizeOf(options.word_type) > 256) {
        @compileError("Word size cannot exceed 256 bits");
    }
    

    return struct {
        const Self = @This();
        
        pub const Error = error{
            StackOverflow,
            StackUnderflow,
        };
        
        // Cacheline 1
        // 8 bytes
        next_stack_pointer: *options.word_type,
        // 8 bytes
        stack: *[options.stack_size]options.word_type,
        
        pub fn push_unsafe(self: *Self, value: options.word_type) void {
            @branchHint(.likely);
            self.next_stack_pointer.* = value;
            self.next_stack_pointer = @ptrFromInt(@intFromPtr(self.next_stack_pointer) + @sizeOf(options.word_type));
            
            if (comptime builtin.mode == .Debug) {
                const stack_end = @intFromPtr(self.stack) + @sizeOf(options.word_type) * options.stack_size;
                if (@intFromPtr(self.next_stack_pointer) > stack_end) unreachable;
            }
        }
        
        pub fn push(self: *Self, value: options.word_type) Error!void {
            self.next_stack_pointer.* = value;
            self.next_stack_pointer = @ptrFromInt(@intFromPtr(self.next_stack_pointer) + @sizeOf(options.word_type));
            
            const stack_end = @intFromPtr(self.stack) + @sizeOf(options.word_type) * options.stack_size;
            if (@intFromPtr(self.next_stack_pointer) > stack_end) {
                @branchHint(.cold);
                // Rollback the pointer
                self.next_stack_pointer = @ptrFromInt(@intFromPtr(self.next_stack_pointer) - @sizeOf(options.word_type));
                return Error.StackOverflow;
            }
        }
        
        pub fn pop_unsafe(self: *Self) options.word_type {
            @branchHint(.likely);
            self.next_stack_pointer = @ptrFromInt(@intFromPtr(self.next_stack_pointer) - @sizeOf(options.word_type));
            
            if (comptime builtin.mode == .Debug) {
                const stack_start = @intFromPtr(&self.stack[0]);
                if (@intFromPtr(self.next_stack_pointer) < stack_start) unreachable;
            }
            
            return self.next_stack_pointer.*;
        }
        
        pub fn pop(self: *Self) Error!options.word_type {
            self.next_stack_pointer = @ptrFromInt(@intFromPtr(self.next_stack_pointer) - @sizeOf(options.word_type));
            
            const stack_start = @intFromPtr(&self.stack[0]);
            if (@intFromPtr(self.next_stack_pointer) < stack_start) {
                @branchHint(.cold);
                // Rollback the pointer
                self.next_stack_pointer = @ptrFromInt(@intFromPtr(self.next_stack_pointer) + @sizeOf(options.word_type));
                return Error.StackUnderflow;
            }
            
            return self.next_stack_pointer.*;
        }
        
        pub fn set_top_unsafe(self: *Self, value: options.word_type) void {
            @branchHint(.likely);
            const top_ptr = @as(*options.word_type, @ptrFromInt(@intFromPtr(self.next_stack_pointer) - @sizeOf(options.word_type)));
            top_ptr.* = value;
            
            if (comptime builtin.mode == .Debug) {
                const stack_start = @intFromPtr(&self.stack[0]);
                if (@intFromPtr(top_ptr) < stack_start) unreachable;
            }
        }
        
        pub fn set_top(self: *Self, value: options.word_type) Error!void {
            const stack_start = @intFromPtr(&self.stack[0]);
            if (@intFromPtr(self.next_stack_pointer) <= stack_start) {
                @branchHint(.cold);
                return Error.StackUnderflow;
            }
            
            const top_ptr = @as(*options.word_type, @ptrFromInt(@intFromPtr(self.next_stack_pointer) - @sizeOf(options.word_type)));
            top_ptr.* = value;
        }
        
        pub fn peek_unsafe(self: *const Self) options.word_type {
            @branchHint(.likely);
            const top_ptr = @as(*const options.word_type, @ptrFromInt(@intFromPtr(self.next_stack_pointer) - @sizeOf(options.word_type)));
            
            if (comptime builtin.mode == .Debug) {
                const stack_start = @intFromPtr(&self.stack[0]);
                if (@intFromPtr(top_ptr) < stack_start) unreachable;
            }
            
            return top_ptr.*;
        }
        
        pub fn peek(self: *const Self) Error!options.word_type {
            const stack_start = @intFromPtr(&self.stack[0]);
            if (@intFromPtr(self.next_stack_pointer) <= stack_start) {
                @branchHint(.cold);
                return Error.StackUnderflow;
            }
            
            const top_ptr = @as(*const options.word_type, @ptrFromInt(@intFromPtr(self.next_stack_pointer) - @sizeOf(options.word_type)));
            return top_ptr.*;
        }
    };
}

test "ColdFrame push and push_unsafe" {
    const allocator = std.testing.allocator;
    const DefaultFrame = ColdFrame(.{});
    
    const stack_memory = try allocator.create([1024]u256);
    defer allocator.destroy(stack_memory);
    @memset(std.mem.sliceAsBytes(stack_memory), 0);
    
    var frame = DefaultFrame{
        .next_stack_pointer = &stack_memory[0],
        .stack = stack_memory,
    };
    
    // Test push_unsafe
    frame.push_unsafe(42);
    try std.testing.expectEqual(@intFromPtr(&stack_memory[1]), @intFromPtr(frame.next_stack_pointer));
    try std.testing.expectEqual(@as(u256, 42), stack_memory[0]);
    
    frame.push_unsafe(100);
    try std.testing.expectEqual(@intFromPtr(&stack_memory[2]), @intFromPtr(frame.next_stack_pointer));
    try std.testing.expectEqual(@as(u256, 100), stack_memory[1]);
    
    // Test push with overflow check
    // Fill stack to near capacity
    frame.next_stack_pointer = &stack_memory[1023];
    try frame.push(200);
    try std.testing.expectEqual(@as(u256, 200), stack_memory[1023]);
    
    // This should error - stack is full
    try std.testing.expectError(error.StackOverflow, frame.push(300));
}

test "ColdFrame pop and pop_unsafe" {
    const allocator = std.testing.allocator;
    const DefaultFrame = ColdFrame(.{});
    
    const stack_memory = try allocator.create([1024]u256);
    defer allocator.destroy(stack_memory);
    
    // Setup stack with some values
    stack_memory[0] = 10;
    stack_memory[1] = 20;
    stack_memory[2] = 30;
    
    var frame = DefaultFrame{
        .next_stack_pointer = &stack_memory[3], // Points to next empty slot
        .stack = stack_memory,
    };
    
    // Test pop_unsafe
    const val1 = frame.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 30), val1);
    try std.testing.expectEqual(@intFromPtr(&stack_memory[2]), @intFromPtr(frame.next_stack_pointer));
    
    const val2 = frame.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 20), val2);
    try std.testing.expectEqual(@intFromPtr(&stack_memory[1]), @intFromPtr(frame.next_stack_pointer));
    
    // Test pop with underflow check
    const val3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 10), val3);
    
    // This should error - stack is empty
    try std.testing.expectError(error.StackUnderflow, frame.pop());
}

test "ColdFrame set_top and set_top_unsafe" {
    const allocator = std.testing.allocator;
    const DefaultFrame = ColdFrame(.{});
    
    const stack_memory = try allocator.create([1024]u256);
    defer allocator.destroy(stack_memory);
    
    // Setup stack with some values
    stack_memory[0] = 10;
    stack_memory[1] = 20;
    stack_memory[2] = 30;
    
    var frame = DefaultFrame{
        .next_stack_pointer = &stack_memory[3], // Points to next empty slot after 30
        .stack = stack_memory,
    };
    
    // Test set_top_unsafe - should modify the top value (30 -> 99)
    frame.set_top_unsafe(99);
    try std.testing.expectEqual(@as(u256, 99), stack_memory[2]);
    try std.testing.expectEqual(@intFromPtr(&stack_memory[3]), @intFromPtr(frame.next_stack_pointer)); // Pointer unchanged
    
    // Test set_top with error check on empty stack
    frame.next_stack_pointer = &stack_memory[0]; // Empty stack
    try std.testing.expectError(error.StackUnderflow, frame.set_top(42));
    
    // Test set_top on non-empty stack
    frame.next_stack_pointer = &stack_memory[2]; // Stack has 2 items
    try frame.set_top(55);
    try std.testing.expectEqual(@as(u256, 55), stack_memory[1]);
}

test "ColdFrame peek and peek_unsafe" {
    const allocator = std.testing.allocator;
    const DefaultFrame = ColdFrame(.{});
    
    const stack_memory = try allocator.create([1024]u256);
    defer allocator.destroy(stack_memory);
    
    // Setup stack with values
    stack_memory[0] = 100;
    stack_memory[1] = 200;
    stack_memory[2] = 300;
    
    var frame = DefaultFrame{
        .next_stack_pointer = &stack_memory[3], // Points to next empty slot
        .stack = stack_memory,
    };
    
    // Test peek_unsafe - should return top value without modifying pointer
    const top_unsafe = frame.peek_unsafe();
    try std.testing.expectEqual(@as(u256, 300), top_unsafe);
    try std.testing.expectEqual(@intFromPtr(&stack_memory[3]), @intFromPtr(frame.next_stack_pointer));
    
    // Test peek on non-empty stack
    const top = try frame.peek();
    try std.testing.expectEqual(@as(u256, 300), top);
    try std.testing.expectEqual(@intFromPtr(&stack_memory[3]), @intFromPtr(frame.next_stack_pointer));
    
    // Test peek on empty stack
    frame.next_stack_pointer = &stack_memory[0];
    try std.testing.expectError(error.StackUnderflow, frame.peek());
}

