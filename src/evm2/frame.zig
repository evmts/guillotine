const std = @import("std");

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
            self.next_stack_pointer.* = value;
            self.next_stack_pointer = @ptrFromInt(@intFromPtr(self.next_stack_pointer) + @sizeOf(options.word_type));
        }
        
        pub fn push(self: *Self, value: options.word_type) Error!void {
            const stack_end = @intFromPtr(self.stack) + @sizeOf(options.word_type) * options.stack_size;
            if (@intFromPtr(self.next_stack_pointer) >= stack_end) {
                return Error.StackOverflow;
            }
            self.push_unsafe(value);
        }
        
        pub fn pop_unsafe(self: *Self) options.word_type {
            self.next_stack_pointer = @ptrFromInt(@intFromPtr(self.next_stack_pointer) - @sizeOf(options.word_type));
            return self.next_stack_pointer.*;
        }
        
        pub fn pop(self: *Self) Error!options.word_type {
            const stack_start = @intFromPtr(&self.stack[0]);
            if (@intFromPtr(self.next_stack_pointer) <= stack_start) {
                return Error.StackUnderflow;
            }
            return self.pop_unsafe();
        }
        
        pub fn pop_2_push_1_unsafe(self: *Self, value: options.word_type) void {
            // Pop 2 items by moving pointer back
            self.next_stack_pointer = @ptrFromInt(@intFromPtr(self.next_stack_pointer) - @sizeOf(options.word_type) * 2);
            // Push 1 item
            self.next_stack_pointer.* = value;
            self.next_stack_pointer = @ptrFromInt(@intFromPtr(self.next_stack_pointer) + @sizeOf(options.word_type));
        }
        
        pub fn pop_2_push_1(self: *Self, value: options.word_type) Error!void {
            const stack_start = @intFromPtr(&self.stack[0]);
            // Need at least 2 items on stack
            if (@intFromPtr(self.next_stack_pointer) < stack_start + @sizeOf(options.word_type) * 2) {
                return Error.StackUnderflow;
            }
            self.pop_2_push_1_unsafe(value);
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

test "ColdFrame pop_2_push_1 and pop_2_push_1_unsafe" {
    const allocator = std.testing.allocator;
    const DefaultFrame = ColdFrame(.{});
    
    const stack_memory = try allocator.create([1024]u256);
    defer allocator.destroy(stack_memory);
    
    // Setup stack: [10, 20, 30, 40]
    stack_memory[0] = 10;
    stack_memory[1] = 20;
    stack_memory[2] = 30;
    stack_memory[3] = 40;
    
    var frame = DefaultFrame{
        .next_stack_pointer = &stack_memory[4],
        .stack = stack_memory,
    };
    
    // Test pop_2_push_1_unsafe - should pop 40 and 30, push their sum
    frame.pop_2_push_1_unsafe(70); // 30 + 40 = 70
    try std.testing.expectEqual(@intFromPtr(&stack_memory[3]), @intFromPtr(frame.next_stack_pointer));
    try std.testing.expectEqual(@as(u256, 70), stack_memory[2]);
    
    // Test pop_2_push_1 with underflow check
    // Reset to have only one item
    frame.next_stack_pointer = &stack_memory[1];
    try std.testing.expectError(error.StackUnderflow, frame.pop_2_push_1(100));
}
