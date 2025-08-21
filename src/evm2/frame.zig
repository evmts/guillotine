const std = @import("std");
const builtin = @import("builtin");

pub const FrameOptions = struct {
    stack_size: usize = 1024,
    word_type: type = u256,
    max_bytecode_size: usize = 65535,
};

pub fn ColdFrame(comptime options: FrameOptions) type {
    if (options.stack_size > 4095) {
        @compileError("Stack size cannot exceed 4095");
    }
    
    if (@bitSizeOf(options.word_type) > 256) {
        @compileError("Word size cannot exceed 256 bits");
    }
    
    const PcType = if (options.max_bytecode_size <= std.math.maxInt(u8))
        u8
    else if (options.max_bytecode_size <= std.math.maxInt(u12))
        u12
    else if (options.max_bytecode_size <= std.math.maxInt(u16))
        u16
    else if (options.max_bytecode_size <= std.math.maxInt(u32))
        u32
    else
        @compileError("Bytecode size too large! It must have under u32 bytes");

    return struct {
        const Self = @This();
        
        pub const Error = error{
            StackOverflow,
            StackUnderflow,
            STOP,
            BytecodeTooLarge,
            OutOfMemory,
        };
        
        // Calculate total memory needed for pre-allocation
        pub const REQUESTED_PREALLOCATION = blk: {
            const stack_bytes = options.stack_size * @sizeOf(options.word_type);
            const frame_bytes = @sizeOf(Self);
            break :blk stack_bytes + frame_bytes;
        };
        
        // Cacheline 1
        // 8 bytes
        next_stack_pointer: *options.word_type,
        // 8 bytes
        stack: *[options.stack_size]options.word_type,
        // 8 bytes
        bytecode: []const u8,
        // 1-4 bytes depending on max_bytecode_size
        pc: PcType,
        
        pub fn push_unsafe(self: *Self, value: options.word_type) void {
            @branchHint(.likely);
            const stack_end = @intFromPtr(self.stack) + @sizeOf(options.word_type) * options.stack_size;
            if (@intFromPtr(self.next_stack_pointer) >= stack_end) unreachable;
            
            self.next_stack_pointer.* = value;
            self.next_stack_pointer = @ptrFromInt(@intFromPtr(self.next_stack_pointer) + @sizeOf(options.word_type));
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
            const stack_start = @intFromPtr(&self.stack[0]);
            if (@intFromPtr(self.next_stack_pointer) <= stack_start) unreachable;
            
            self.next_stack_pointer = @ptrFromInt(@intFromPtr(self.next_stack_pointer) - @sizeOf(options.word_type));
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
            const stack_start = @intFromPtr(&self.stack[0]);
            if (@intFromPtr(self.next_stack_pointer) <= stack_start) unreachable;
            
            const top_ptr = @as(*options.word_type, @ptrFromInt(@intFromPtr(self.next_stack_pointer) - @sizeOf(options.word_type)));
            top_ptr.* = value;
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
            const stack_start = @intFromPtr(&self.stack[0]);
            if (@intFromPtr(self.next_stack_pointer) <= stack_start) unreachable;
            
            const top_ptr = @as(*const options.word_type, @ptrFromInt(@intFromPtr(self.next_stack_pointer) - @sizeOf(options.word_type)));
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
        
        pub fn op_pc(self: *Self) Error!void {
            return self.push(@as(options.word_type, self.pc));
        }
        
        pub fn op_stop(self: *Self) Error!void {
            _ = self;
            return Error.STOP;
        }
        
        pub fn op_pop(self: *Self) Error!void {
            _ = try self.pop();
        }
        
        pub fn op_push0(self: *Self) Error!void {
            return self.push(0);
        }
        
        pub fn op_push1(self: *Self) Error!void {
            // Read one byte from bytecode after the opcode
            const value = self.bytecode[self.pc + 1];
            self.pc += 2; // Advance PC past opcode and data byte
            return self.push(value);
        }
        
        // Generic push function for PUSH2-PUSH32
        fn push_n(self: *Self, comptime n: u8) Error!void {
            const start = self.pc + 1;
            var value: u256 = 0;
            
            // Handle different sizes using std.mem.readInt
            if (n <= 8) {
                // For sizes that fit in standard integer types
                const bytes = self.bytecode[start..start + n];
                var buffer: [@divExact(64, 8)]u8 = [_]u8{0} ** 8;
                // Copy to right-aligned position for big-endian
                @memcpy(buffer[8 - n..], bytes);
                const small_value = std.mem.readInt(u64, &buffer, .big);
                value = small_value;
            } else {
                // For larger sizes, read in chunks
                var temp_buffer: [32]u8 = [_]u8{0} ** 32;
                @memcpy(temp_buffer[32 - n..], self.bytecode[start..start + n]);
                
                // Read as four u64s and combine
                var result: u256 = 0;
                var i: usize = 0;
                while (i < 4) : (i += 1) {
                    const chunk = std.mem.readInt(u64, temp_buffer[i * 8..][0..8], .big);
                    result = (result << 64) | chunk;
                }
                value = result;
            }
            
            self.pc += n + 1; // Advance PC past opcode and data bytes
            return self.push(value);
        }
        
        pub fn op_push2(self: *Self) Error!void {
            return self.push_n(2);
        }
        
        pub fn op_push32(self: *Self) Error!void {
            return self.push_n(32);
        }
        
        // Generic dup function for DUP1-DUP16
        fn dup_n(self: *Self, comptime n: u8) Error!void {
            // Check if we have enough items on stack
            const stack_size = (@intFromPtr(self.next_stack_pointer) - @intFromPtr(&self.stack[0])) / @sizeOf(options.word_type);
            if (stack_size < n) {
                return Error.StackUnderflow;
            }
            
            // Get the value n positions from the top
            const offset = @as(usize, @sizeOf(options.word_type)) * @as(usize, n);
            const value_ptr = @as(*const options.word_type, @ptrFromInt(@intFromPtr(self.next_stack_pointer) - offset));
            const value = value_ptr.*;
            
            // Push the duplicate
            return self.push(value);
        }
        
        pub fn op_dup1(self: *Self) Error!void {
            return self.dup_n(1);
        }
        
        pub fn op_dup16(self: *Self) Error!void {
            return self.dup_n(16);
        }
        
        // Generic swap function for SWAP1-SWAP16
        fn swap_n(self: *Self, comptime n: u8) Error!void {
            // Check if we have enough items on stack (need n+1 items)
            const stack_size = (@intFromPtr(self.next_stack_pointer) - @intFromPtr(&self.stack[0])) / @sizeOf(options.word_type);
            if (stack_size < n + 1) {
                return Error.StackUnderflow;
            }
            
            // Get pointers to the two items to swap
            const top_ptr = @as(*options.word_type, @ptrFromInt(@intFromPtr(self.next_stack_pointer) - @sizeOf(options.word_type)));
            const offset = @as(usize, @sizeOf(options.word_type)) * @as(usize, n + 1);
            const other_ptr = @as(*options.word_type, @ptrFromInt(@intFromPtr(self.next_stack_pointer) - offset));
            
            // Swap them
            std.mem.swap(options.word_type, top_ptr, other_ptr);
        }
        
        pub fn op_swap1(self: *Self) Error!void {
            return self.swap_n(1);
        }
        
        pub fn op_swap16(self: *Self) Error!void {
            return self.swap_n(16);
        }
        
        pub fn init(allocator: std.mem.Allocator, bytecode: []const u8) Error!*Self {
            // Validate bytecode size
            if (bytecode.len > options.max_bytecode_size) {
                return Error.BytecodeTooLarge;
            }
            
            // Allocate frame
            const self = allocator.create(Self) catch return Error.OutOfMemory;
            errdefer allocator.destroy(self);
            
            // Allocate stack on heap
            const stack_memory = allocator.alloc(options.word_type, options.stack_size) catch {
                allocator.destroy(self);
                return Error.OutOfMemory;
            };
            errdefer allocator.free(stack_memory);
            
            // Initialize all stack slots to 0
            @memset(std.mem.sliceAsBytes(stack_memory), 0);
            
            // Initialize frame
            self.* = Self{
                .next_stack_pointer = &stack_memory[0],
                .stack = @ptrCast(&stack_memory[0]),
                .bytecode = bytecode,
                .pc = 0,
            };
            
            return self;
        }
        
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            const stack_slice = @as([*]options.word_type, @ptrCast(self.stack))[0..options.stack_size];
            allocator.free(stack_slice);
            allocator.destroy(self);
        }
    };
}

test "ColdFrame push and push_unsafe" {
    const allocator = std.testing.allocator;
    const DefaultFrame = ColdFrame(.{});
    
    const stack_memory = try allocator.create([1024]u256);
    defer allocator.destroy(stack_memory);
    @memset(std.mem.sliceAsBytes(stack_memory), 0);
    
    const dummy_bytecode = [_]u8{0x00}; // STOP
    var frame = DefaultFrame{
        .next_stack_pointer = &stack_memory[0],
        .stack = stack_memory,
        .bytecode = &dummy_bytecode,
        .pc = 0,
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
    
    const dummy_bytecode = [_]u8{0x00}; // STOP
    var frame = DefaultFrame{
        .next_stack_pointer = &stack_memory[3], // Points to next empty slot
        .stack = stack_memory,
        .bytecode = &dummy_bytecode,
        .pc = 0,
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
    
    const dummy_bytecode = [_]u8{0x00}; // STOP
    var frame = DefaultFrame{
        .next_stack_pointer = &stack_memory[3], // Points to next empty slot after 30
        .stack = stack_memory,
        .bytecode = &dummy_bytecode,
        .pc = 0,
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
    
    const dummy_bytecode = [_]u8{0x00}; // STOP
    var frame = DefaultFrame{
        .next_stack_pointer = &stack_memory[3], // Points to next empty slot
        .stack = stack_memory,
        .bytecode = &dummy_bytecode,
        .pc = 0,
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

test "ColdFrame with bytecode and pc" {
    const allocator = std.testing.allocator;
    
    // Test with small bytecode (fits in u8)
    const SmallFrame = ColdFrame(.{ .max_bytecode_size = 255 });
    const small_bytecode = [_]u8{0x60, 0x01, 0x60, 0x02, 0x00}; // PUSH1 1 PUSH1 2 STOP
    
    const small_stack = try allocator.create([1024]u256);
    defer allocator.destroy(small_stack);
    
    const small_frame = SmallFrame{
        .next_stack_pointer = &small_stack[0],
        .stack = small_stack,
        .bytecode = &small_bytecode,
        .pc = 0,
    };
    
    try std.testing.expectEqual(@as(u8, 0), small_frame.pc);
    try std.testing.expectEqual(@as(u8, 0x60), small_frame.bytecode[0]);
    
    // Test with medium bytecode (fits in u16)
    const MediumFrame = ColdFrame(.{ .max_bytecode_size = 65535 });
    const medium_bytecode = [_]u8{0x58, 0x00}; // PC STOP
    
    const medium_stack = try allocator.create([1024]u256);
    defer allocator.destroy(medium_stack);
    
    const medium_frame = MediumFrame{
        .next_stack_pointer = &medium_stack[0],
        .stack = medium_stack,
        .bytecode = &medium_bytecode,
        .pc = 300,
    };
    
    try std.testing.expectEqual(@as(u16, 300), medium_frame.pc);
}

test "ColdFrame op_pc pushes pc to stack" {
    const allocator = std.testing.allocator;
    const DefaultFrame = ColdFrame(.{});
    
    const bytecode = [_]u8{0x58, 0x00}; // PC STOP
    const stack_memory = try allocator.create([1024]u256);
    defer allocator.destroy(stack_memory);
    
    var frame = DefaultFrame{
        .next_stack_pointer = &stack_memory[0],
        .stack = stack_memory,
        .bytecode = &bytecode,
        .pc = 0,
    };
    
    // Execute op_pc - should push current pc (0) to stack
    try frame.op_pc();
    try std.testing.expectEqual(@as(u256, 0), stack_memory[0]);
    try std.testing.expectEqual(@intFromPtr(&stack_memory[1]), @intFromPtr(frame.next_stack_pointer));
    
    // Set pc to 42 and test again
    frame.pc = 42;
    try frame.op_pc();
    try std.testing.expectEqual(@as(u256, 42), stack_memory[1]);
    try std.testing.expectEqual(@intFromPtr(&stack_memory[2]), @intFromPtr(frame.next_stack_pointer));
}

test "ColdFrame op_stop returns stop error" {
    const allocator = std.testing.allocator;
    const DefaultFrame = ColdFrame(.{});
    
    const bytecode = [_]u8{0x00}; // STOP
    const stack_memory = try allocator.create([1024]u256);
    defer allocator.destroy(stack_memory);
    
    var frame = DefaultFrame{
        .next_stack_pointer = &stack_memory[0],
        .stack = stack_memory,
        .bytecode = &bytecode,
        .pc = 0,
    };
    
    // Execute op_stop - should return STOP error
    try std.testing.expectError(error.STOP, frame.op_stop());
}

test "ColdFrame op_pop removes top stack item" {
    const allocator = std.testing.allocator;
    const DefaultFrame = ColdFrame(.{});
    
    const bytecode = [_]u8{0x50, 0x00}; // POP STOP
    const stack_memory = try allocator.create([1024]u256);
    defer allocator.destroy(stack_memory);
    
    // Setup stack with some values
    stack_memory[0] = 100;
    stack_memory[1] = 200;
    stack_memory[2] = 300;
    
    var frame = DefaultFrame{
        .next_stack_pointer = &stack_memory[3],
        .stack = stack_memory,
        .bytecode = &bytecode,
        .pc = 0,
    };
    
    // Execute op_pop - should remove top item (300) and do nothing with it
    try frame.op_pop();
    try std.testing.expectEqual(@intFromPtr(&stack_memory[2]), @intFromPtr(frame.next_stack_pointer));
    
    // Execute again - should remove 200
    try frame.op_pop();
    try std.testing.expectEqual(@intFromPtr(&stack_memory[1]), @intFromPtr(frame.next_stack_pointer));
    
    // Execute again - should remove 100
    try frame.op_pop();
    try std.testing.expectEqual(@intFromPtr(&stack_memory[0]), @intFromPtr(frame.next_stack_pointer));
    
    // Pop on empty stack should error
    try std.testing.expectError(error.StackUnderflow, frame.op_pop());
}

test "ColdFrame op_push0 pushes zero to stack" {
    const allocator = std.testing.allocator;
    const DefaultFrame = ColdFrame(.{});
    
    const bytecode = [_]u8{0x5f, 0x00}; // PUSH0 STOP
    const stack_memory = try allocator.create([1024]u256);
    defer allocator.destroy(stack_memory);
    
    var frame = DefaultFrame{
        .next_stack_pointer = &stack_memory[0],
        .stack = stack_memory,
        .bytecode = &bytecode,
        .pc = 0,
    };
    
    // Execute op_push0 - should push 0 to stack
    try frame.op_push0();
    try std.testing.expectEqual(@as(u256, 0), stack_memory[0]);
    try std.testing.expectEqual(@intFromPtr(&stack_memory[1]), @intFromPtr(frame.next_stack_pointer));
}

test "ColdFrame op_push1 reads byte from bytecode and pushes to stack" {
    const allocator = std.testing.allocator;
    const DefaultFrame = ColdFrame(.{});
    
    const bytecode = [_]u8{0x60, 0x42, 0x60, 0xFF, 0x00}; // PUSH1 0x42 PUSH1 0xFF STOP
    const stack_memory = try allocator.create([1024]u256);
    defer allocator.destroy(stack_memory);
    
    var frame = DefaultFrame{
        .next_stack_pointer = &stack_memory[0],
        .stack = stack_memory,
        .bytecode = &bytecode,
        .pc = 0,
    };
    
    // Execute op_push1 at pc=0 - should read 0x42 from bytecode[1] and push it
    try frame.op_push1();
    try std.testing.expectEqual(@as(u256, 0x42), stack_memory[0]);
    try std.testing.expectEqual(@intFromPtr(&stack_memory[1]), @intFromPtr(frame.next_stack_pointer));
    try std.testing.expectEqual(@as(u16, 2), frame.pc); // PC should advance by 2 (opcode + 1 byte)
    
    // Execute op_push1 at pc=2 - should read 0xFF from bytecode[3] and push it
    try frame.op_push1();
    try std.testing.expectEqual(@as(u256, 0xFF), stack_memory[1]);
    try std.testing.expectEqual(@intFromPtr(&stack_memory[2]), @intFromPtr(frame.next_stack_pointer));
    try std.testing.expectEqual(@as(u16, 4), frame.pc); // PC should advance by 2 more
}

test "ColdFrame op_push2 reads 2 bytes from bytecode" {
    const allocator = std.testing.allocator;
    const DefaultFrame = ColdFrame(.{});
    
    const bytecode = [_]u8{0x61, 0x12, 0x34, 0x00}; // PUSH2 0x1234 STOP
    const stack_memory = try allocator.create([1024]u256);
    defer allocator.destroy(stack_memory);
    
    var frame = DefaultFrame{
        .next_stack_pointer = &stack_memory[0],
        .stack = stack_memory,
        .bytecode = &bytecode,
        .pc = 0,
    };
    
    // Execute op_push2 - should read 0x1234 from bytecode[1..3] and push it
    try frame.op_push2();
    try std.testing.expectEqual(@as(u256, 0x1234), stack_memory[0]);
    try std.testing.expectEqual(@intFromPtr(&stack_memory[1]), @intFromPtr(frame.next_stack_pointer));
    try std.testing.expectEqual(@as(u16, 3), frame.pc); // PC should advance by 3 (opcode + 2 bytes)
}

test "ColdFrame op_push32 reads 32 bytes from bytecode" {
    const allocator = std.testing.allocator;
    const DefaultFrame = ColdFrame(.{});
    
    // PUSH32 with max value (32 bytes of 0xFF)
    var bytecode: [34]u8 = undefined;
    bytecode[0] = 0x7f; // PUSH32
    for (1..33) |i| {
        bytecode[i] = 0xFF;
    }
    bytecode[33] = 0x00; // STOP
    
    const stack_memory = try allocator.create([1024]u256);
    defer allocator.destroy(stack_memory);
    
    var frame = DefaultFrame{
        .next_stack_pointer = &stack_memory[0],
        .stack = stack_memory,
        .bytecode = &bytecode,
        .pc = 0,
    };
    
    // Execute op_push32 - should read all 32 bytes and push max u256
    try frame.op_push32();
    try std.testing.expectEqual(@as(u256, std.math.maxInt(u256)), stack_memory[0]);
    try std.testing.expectEqual(@intFromPtr(&stack_memory[1]), @intFromPtr(frame.next_stack_pointer));
    try std.testing.expectEqual(@as(u16, 33), frame.pc); // PC should advance by 33 (opcode + 32 bytes)
}

test "ColdFrame op_dup1 duplicates top stack item" {
    const allocator = std.testing.allocator;
    const DefaultFrame = ColdFrame(.{});
    
    const bytecode = [_]u8{0x80, 0x00}; // DUP1 STOP
    const stack_memory = try allocator.create([1024]u256);
    defer allocator.destroy(stack_memory);
    
    // Setup stack with value
    stack_memory[0] = 42;
    
    var frame = DefaultFrame{
        .next_stack_pointer = &stack_memory[1],
        .stack = stack_memory,
        .bytecode = &bytecode,
        .pc = 0,
    };
    
    // Execute op_dup1 - should duplicate top item (42)
    try frame.op_dup1();
    try std.testing.expectEqual(@as(u256, 42), stack_memory[0]); // Original
    try std.testing.expectEqual(@as(u256, 42), stack_memory[1]); // Duplicate
    try std.testing.expectEqual(@intFromPtr(&stack_memory[2]), @intFromPtr(frame.next_stack_pointer));
    
    // Test dup1 on empty stack
    frame.next_stack_pointer = &stack_memory[0];
    try std.testing.expectError(error.StackUnderflow, frame.op_dup1());
}

test "ColdFrame op_dup16 duplicates 16th stack item" {
    const allocator = std.testing.allocator;
    const DefaultFrame = ColdFrame(.{});
    
    const bytecode = [_]u8{0x8f, 0x00}; // DUP16 STOP
    const stack_memory = try allocator.create([1024]u256);
    defer allocator.destroy(stack_memory);
    
    // Setup stack with values 1-16
    for (0..16) |i| {
        stack_memory[i] = @as(u256, i + 1);
    }
    
    var frame = DefaultFrame{
        .next_stack_pointer = &stack_memory[16],
        .stack = stack_memory,
        .bytecode = &bytecode,
        .pc = 0,
    };
    
    // Execute op_dup16 - should duplicate 16th from top (value 1)
    try frame.op_dup16();
    try std.testing.expectEqual(@as(u256, 1), stack_memory[16]); // Duplicate of bottom
    try std.testing.expectEqual(@intFromPtr(&stack_memory[17]), @intFromPtr(frame.next_stack_pointer));
    
    // Test dup16 with insufficient stack
    frame.next_stack_pointer = &stack_memory[15]; // Only 15 items
    try std.testing.expectError(error.StackUnderflow, frame.op_dup16());
}

test "ColdFrame op_swap1 swaps top two stack items" {
    const allocator = std.testing.allocator;
    const DefaultFrame = ColdFrame(.{});
    
    const bytecode = [_]u8{0x90, 0x00}; // SWAP1 STOP
    const stack_memory = try allocator.create([1024]u256);
    defer allocator.destroy(stack_memory);
    
    // Setup stack with values
    stack_memory[0] = 100;
    stack_memory[1] = 200;
    
    var frame = DefaultFrame{
        .next_stack_pointer = &stack_memory[2],
        .stack = stack_memory,
        .bytecode = &bytecode,
        .pc = 0,
    };
    
    // Execute op_swap1 - should swap top two items
    try frame.op_swap1();
    try std.testing.expectEqual(@as(u256, 200), stack_memory[0]);
    try std.testing.expectEqual(@as(u256, 100), stack_memory[1]);
    try std.testing.expectEqual(@intFromPtr(&stack_memory[2]), @intFromPtr(frame.next_stack_pointer));
    
    // Test swap1 with insufficient stack
    frame.next_stack_pointer = &stack_memory[1]; // Only 1 item
    try std.testing.expectError(error.StackUnderflow, frame.op_swap1());
}

test "ColdFrame op_swap16 swaps top with 17th stack item" {
    const allocator = std.testing.allocator;
    const DefaultFrame = ColdFrame(.{});
    
    const bytecode = [_]u8{0x9f, 0x00}; // SWAP16 STOP
    const stack_memory = try allocator.create([1024]u256);
    defer allocator.destroy(stack_memory);
    
    // Setup stack with values 1-17
    for (0..17) |i| {
        stack_memory[i] = @as(u256, i + 1);
    }
    
    var frame = DefaultFrame{
        .next_stack_pointer = &stack_memory[17],
        .stack = stack_memory,
        .bytecode = &bytecode,
        .pc = 0,
    };
    
    // Execute op_swap16 - should swap top (17) with 17th from top (1)
    try frame.op_swap16();
    try std.testing.expectEqual(@as(u256, 17), stack_memory[0]); // Was 1
    try std.testing.expectEqual(@as(u256, 1), stack_memory[16]); // Was 17
    try std.testing.expectEqual(@intFromPtr(&stack_memory[17]), @intFromPtr(frame.next_stack_pointer));
    
    // Test swap16 with insufficient stack
    frame.next_stack_pointer = &stack_memory[16]; // Only 16 items
    try std.testing.expectError(error.StackUnderflow, frame.op_swap16());
}

test "ColdFrame init validates bytecode size" {
    const allocator = std.testing.allocator;
    
    // Test with valid bytecode size
    const SmallFrame = ColdFrame(.{ .max_bytecode_size = 100 });
    const small_bytecode = [_]u8{0x60, 0x01, 0x00}; // PUSH1 1 STOP
    
    const stack_memory = try allocator.create([1024]u256);
    defer allocator.destroy(stack_memory);
    
    const frame = try SmallFrame.init(allocator, &small_bytecode);
    defer frame.deinit(allocator);
    
    try std.testing.expectEqual(@as(u8, 0), frame.pc);
    try std.testing.expectEqual(&small_bytecode, frame.bytecode.ptr);
    try std.testing.expectEqual(@as(usize, 3), frame.bytecode.len);
    
    // Test with bytecode too large
    const large_bytecode = try allocator.alloc(u8, 101);
    defer allocator.free(large_bytecode);
    @memset(large_bytecode, 0x00);
    
    try std.testing.expectError(error.BytecodeTooLarge, SmallFrame.init(allocator, large_bytecode));
    
    // Test with empty bytecode
    const empty_bytecode = [_]u8{};
    const empty_frame = try SmallFrame.init(allocator, &empty_bytecode);
    defer empty_frame.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty_frame.bytecode.len);
}

test "ColdFrame REQUESTED_PREALLOCATION calculates correctly" {
    // Test with default options
    const DefaultFrame = ColdFrame(.{});
    const expected_default = 1024 * @sizeOf(u256) + @sizeOf(DefaultFrame);
    try std.testing.expectEqual(expected_default, DefaultFrame.REQUESTED_PREALLOCATION);
    
    // Test with custom options
    const CustomFrame = ColdFrame(.{
        .stack_size = 512,
        .word_type = u128,
        .max_bytecode_size = 1000,
    });
    const expected_custom = 512 * @sizeOf(u128) + @sizeOf(CustomFrame);
    try std.testing.expectEqual(expected_custom, CustomFrame.REQUESTED_PREALLOCATION);
    
    // Test with small frame
    const SmallFrame = ColdFrame(.{
        .stack_size = 256,
        .word_type = u64,
        .max_bytecode_size = 255,
    });
    const expected_small = 256 * @sizeOf(u64) + @sizeOf(SmallFrame);
    try std.testing.expectEqual(expected_small, SmallFrame.REQUESTED_PREALLOCATION);
}

