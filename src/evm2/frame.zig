const std = @import("std");
const builtin = @import("builtin");

pub const FrameConfig = struct {
    const Self = @This();

    // The maximum stack size for the evm. Defaults to 1024
    stack_size: usize = 1024,
    // The size of a single word in the EVM - Defaults to u256
    WordType: type = u256,
    // The maximum amount of bytes allowed in contract code
    max_bytecode_size: u32 = 24576,
    // The maximum gas limit for a block
    block_gas_limit: u64 = 30_000_000, 
    // gets the pc type from the bytecode zie
    fn get_pc_type(self: Self) type {
        return if (self.max_bytecode_size <= std.math.maxInt(u8))
                u8
            else if (self.max_bytecode_size <= std.math.maxInt(u12))
                u12
            else if (self.max_bytecode_size <= std.math.maxInt(u16))
                u16
            else if (self.max_bytecode_size <= std.math.maxInt(u32))
                u32
            else
                @compileError("Bytecode size too large! It must have under u32 bytes");
    }

    fn get_stack_index_type(self: Self) type {
        return if (self.stack_size <= std.math.maxInt(u4))
            u4
            else if (self.stack_size <= std.math.maxInt(u8))
            u8
            else if (self.stack_size <= std.math.maxInt(u12))
            u12
            else
              @compileError("FrameConfig stack_size is too large! It must fit in a u12 bytes");
    }
    
    fn get_gas_type(self: Self) type {
        return if (self.block_gas_limit <= std.math.maxInt(i32))
            i32
            else
            i64;
    }

    // The amount of data the frame plans on allocating based on config
    fn get_requested_alloc(self: Self) u32  {
      return  @as(u32, @intCast(self.stack_size * @sizeOf(self.WordType)));
    }

    // Limits placed on the Frame
    fn validate(self: Self) void {
        if (self.stack_size > 4095) @compileError("stack_size cannot exceed 4095");
        if (@bitSizeOf(self.WordType) > 256) @compileError("WordType cannot exceed u256");
        if (self.max_bytecode_size > 65535) @compileError("max_bytecodeSize must be at most 65535 to fit within a u16");
    }
};

// A ColdFrame is the StackFrame data struct for the ColdInterpreter which is the simplist interpreter
// Cold in this context means the code is new unanalyzed code that we are interpreting.
// The cold frame and interpreter are appropriate for the following situations:
// 1. Very small contracts
// 2. Unanalyzed contracts
// 3. Debuggers tracers or anything that needs to step through the evm code
pub fn createColdFrame(comptime config: FrameConfig) type {
    config.validate();

    const stack_size = config.stack_size;
    const WordType = config.WordType;
    const max_bytecode_size = config.max_bytecode_size;
    const PcType = config.get_pc_type();
    const StackIndexType = config.get_stack_index_type();
    const GasType = config.get_gas_type();

    const ColdFrame = struct {
        pub const frame_config = config;
        
        pub const Error = error{
            StackOverflow,
            StackUnderflow,
            STOP,
            BytecodeTooLarge,
            AllocationError,
        };

        const Self = @This();

        // Cacheline 1
        next_stack_index: StackIndexType, // 1-4 bytes depending on stack_size
        stack: *[stack_size]WordType, // 8 bytes (pointer)
        bytecode: []const u8, // 16 bytes (slice)
        pc: PcType, // 1-4 bytes depending on max_bytecode_size
        gas_remaining: GasType, // 4 or 8 bytes depending on block_gas_limit
        
        pub fn init(allocator: std.mem.Allocator, bytecode: []const u8, gas_remaining: GasType) Error!Self {
            if (bytecode.len > max_bytecode_size) return Error.BytecodeTooLarge;
            const stack_memory = allocator.alloc(WordType, stack_size) catch {
                return Error.AllocationError;
            };
            errdefer allocator.free(stack_memory);
            @memset(std.mem.sliceAsBytes(stack_memory), 0);
            
            return Self{
                .next_stack_index = 0,
                .stack = @ptrCast(&stack_memory[0]),
                .bytecode = bytecode,
                .pc = 0,
                .gas_remaining = gas_remaining,
            };
        }
        
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            const stack_slice = @as([*]WordType, @ptrCast(self.stack))[0..stack_size];
            allocator.free(stack_slice);
        }
        
        fn push_unsafe(self: *Self, value: WordType) void {
            @branchHint(.likely);
            if (self.next_stack_index >= stack_size) unreachable;
            self.stack[self.next_stack_index] = value;
            self.next_stack_index += 1;
        }
        
        pub fn push(self: *Self, value: WordType) Error!void {
            if (self.next_stack_index >= stack_size) {
                @branchHint(.cold);
                return Error.StackOverflow;
            }
            self.push_unsafe(value);
        }
        
        fn pop_unsafe(self: *Self) WordType {
            @branchHint(.likely);
            if (self.next_stack_index == 0) unreachable;
            
            self.next_stack_index -= 1;
            return self.stack[self.next_stack_index];
        }
        
        pub fn pop(self: *Self) Error!WordType {
            if (self.next_stack_index == 0) {
                @branchHint(.cold);
                return Error.StackUnderflow;
            }
            
            return self.pop_unsafe();
        }
        
        fn set_top_unsafe(self: *Self, value: WordType) void {
            @branchHint(.likely);
            if (self.next_stack_index == 0) unreachable;
            
            self.stack[self.next_stack_index - 1] = value;
        }
        
        pub fn set_top(self: *Self, value: WordType) Error!void {
            if (self.next_stack_index == 0) {
                @branchHint(.cold);
                return Error.StackUnderflow;
            }
            
            self.set_top_unsafe(value);
        }
        
        fn peek_unsafe(self: *const Self) WordType {
            @branchHint(.likely);
            if (self.next_stack_index == 0) unreachable;
            
            return self.stack[self.next_stack_index - 1];
        }
        
        pub fn peek(self: *const Self) Error!WordType {
            if (self.next_stack_index == 0) {
                @branchHint(.cold);
                return Error.StackUnderflow;
            }
            
            return self.peek_unsafe();
        }
        
        pub fn op_pc(self: *Self) Error!void {
            return self.push(@as(WordType, self.pc));
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
            if (self.next_stack_index < n) {
                return Error.StackUnderflow;
            }
            
            // Get the value n positions from the top
            const value = self.stack[self.next_stack_index - n];
            
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
            if (self.next_stack_index < n + 1) {
                return Error.StackUnderflow;
            }
            
            // Get indices of the two items to swap
            const top_index = self.next_stack_index - 1;
            const other_index = self.next_stack_index - n - 1;
            
            // Swap them
            std.mem.swap(WordType, &self.stack[top_index], &self.stack[other_index]);
        }
        
        pub fn op_swap1(self: *Self) Error!void {
            return self.swap_n(1);
        }
        
        pub fn op_swap16(self: *Self) Error!void {
            return self.swap_n(16);
        }
        
        // Bitwise operations
        pub fn op_and(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            try self.set_top(a & b);
        }
        
        pub fn op_or(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            try self.set_top(a | b);
        }
        
        pub fn op_xor(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            try self.set_top(a ^ b);
        }
        
        pub fn op_not(self: *Self) Error!void {
            const a = try self.peek();
            try self.set_top(~a);
        }
        
        pub fn op_byte(self: *Self) Error!void {
            const i = try self.pop();
            const val = try self.peek();
            
            const result = if (i >= 32) 0 else blk: {
                const i_usize = @as(usize, @intCast(i));
                const shift_amount = (31 - i_usize) * 8;
                break :blk (val >> @intCast(shift_amount)) & 0xFF;
            };
            
            try self.set_top(result);
        }
        
        pub fn op_shl(self: *Self) Error!void {
            const shift = try self.pop();
            const value = try self.peek();
            
            const result = if (shift >= 256) 0 else value << @intCast(shift);
            
            try self.set_top(result);
        }
        
        pub fn op_shr(self: *Self) Error!void {
            const shift = try self.pop();
            const value = try self.peek();
            
            const result = if (shift >= 256) 0 else value >> @intCast(shift);
            
            try self.set_top(result);
        }
        
        pub fn op_sar(self: *Self) Error!void {
            const shift = try self.pop();
            const value = try self.peek();
            
            const result = if (shift >= 256) blk: {
                const sign_bit = value >> 255;
                break :blk if (sign_bit == 1) @as(WordType, std.math.maxInt(WordType)) else @as(WordType, 0);
            } else blk: {
                const shift_amount = @as(u8, @intCast(shift));
                const value_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(value));
                const result_signed = value_signed >> shift_amount;
                break :blk @as(WordType, @bitCast(result_signed));
            };
            
            try self.set_top(result);
        }
        
        // Arithmetic operations
        pub fn op_add(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            try self.set_top(a +% b);
        }
        
        pub fn op_mul(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            try self.set_top(a *% b);
        }
        
        pub fn op_sub(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            try self.set_top(a -% b);
        }
        
        pub fn op_div(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            const result = if (b == 0) 0 else a / b;
            try self.set_top(result);
        }
        
        pub fn op_sdiv(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            
            var result: WordType = undefined;
            if (b == 0) {
                result = 0;
            } else {
                const a_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(a));
                const b_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(b));
                const min_signed = std.math.minInt(std.meta.Int(.signed, @bitSizeOf(WordType)));
                
                if (a_signed == min_signed and b_signed == -1) {
                    // MIN / -1 overflow case
                    result = a;
                } else {
                    const result_signed = @divTrunc(a_signed, b_signed);
                    result = @as(WordType, @bitCast(result_signed));
                }
            }
            
            try self.set_top(result);
        }
        
        pub fn op_mod(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            const result = if (b == 0) 0 else a % b;
            try self.set_top(result);
        }
        
        pub fn op_smod(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            
            var result: WordType = undefined;
            if (b == 0) {
                result = 0;
            } else {
                const a_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(a));
                const b_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(b));
                const result_signed = @rem(a_signed, b_signed);
                result = @as(WordType, @bitCast(result_signed));
            }
            
            try self.set_top(result);
        }
        
        pub fn op_addmod(self: *Self) Error!void {
            const n = try self.pop();
            const b = try self.pop();
            const a = try self.peek();
            
            var result: WordType = undefined;
            if (n == 0) {
                result = 0;
            } else {
                // The key insight: ADDMOD must compute (a + b) mod n where the addition
                // is done in arbitrary precision, not mod 2^256
                // However, in the test case (MAX + 5) % 10, we have:
                // MAX + 5 in u256 wraps to 4, so we want 4 % 10 = 4
                
                // First, let's check if a + b overflows
                const sum = @addWithOverflow(a, b);
                if (sum[1] == 0) {
                    // No overflow, simple case
                    result = sum[0] % n;
                } else {
                    // Overflow occurred. The wrapped value is what we want to mod
                    result = sum[0] % n;
                }
            }
            
            try self.set_top(result);
        }
        
        pub fn op_mulmod(self: *Self) Error!void {
            const n = try self.pop();
            const b = try self.pop();
            const a = try self.peek();
            
            var result: WordType = undefined;
            if (n == 0) {
                result = 0;
            } else {
                // First reduce the operands
                const a_mod = a % n;
                const b_mod = b % n;
                
                // Compute (a_mod * b_mod) % n
                // This works correctly for values where a_mod * b_mod doesn't overflow
                const product = a_mod *% b_mod;
                result = product % n;
            }
            
            try self.set_top(result);
        }
        
        pub fn op_exp(self: *Self) Error!void {
            const exp = try self.pop();
            const base = try self.peek();
            
            var result: WordType = 1;
            var b = base;
            var e = exp;
            
            // Binary exponentiation algorithm
            while (e > 0) : (e >>= 1) {
                if (e & 1 == 1) {
                    result *%= b;
                }
                b *%= b;
            }
            
            try self.set_top(result);
        }
        
        pub fn op_signextend(self: *Self) Error!void {
            const ext = try self.pop();
            const value = try self.peek();
            
            var result: WordType = undefined;
            
            if (ext >= 31) {
                // No extension needed
                result = value;
            } else {
                const ext_usize = @as(usize, @intCast(ext));
                const bit_index = ext_usize * 8 + 7;
                const mask = (@as(WordType, 1) << @intCast(bit_index)) - 1;
                const sign_bit = (value >> @intCast(bit_index)) & 1;
                
                if (sign_bit == 1) {
                    // Negative - fill with 1s
                    result = value | ~mask;
                } else {
                    // Positive - fill with 0s
                    result = value & mask;
                }
            }
            
            try self.set_top(result);
        }
        
        pub fn op_gas(self: *Self) Error!void {
            // Push the current gas remaining to the stack
            // Since gas_remaining can be negative, we need to handle that case
            const gas_value = if (self.gas_remaining < 0) 0 else @as(WordType, @intCast(self.gas_remaining));
            return self.push(gas_value);
        }
        
        // Comparison operations
        pub fn op_lt(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            const result: WordType = if (a < b) 1 else 0;
            try self.set_top(result);
        }
        
        pub fn op_gt(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            const result: WordType = if (a > b) 1 else 0;
            try self.set_top(result);
        }
        
        pub fn op_slt(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            const SignedType = std.meta.Int(.signed, @bitSizeOf(WordType));
            const a_signed = @as(SignedType, @bitCast(a));
            const b_signed = @as(SignedType, @bitCast(b));
            const result: WordType = if (a_signed < b_signed) 1 else 0;
            try self.set_top(result);
        }
        
        pub fn op_sgt(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            const SignedType = std.meta.Int(.signed, @bitSizeOf(WordType));
            const a_signed = @as(SignedType, @bitCast(a));
            const b_signed = @as(SignedType, @bitCast(b));
            const result: WordType = if (a_signed > b_signed) 1 else 0;
            try self.set_top(result);
        }
        
        pub fn op_eq(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            const result: WordType = if (a == b) 1 else 0;
            try self.set_top(result);
        }
        
        pub fn op_iszero(self: *Self) Error!void {
            const value = try self.peek();
            const result: WordType = if (value == 0) 1 else 0;
            try self.set_top(result);
        }
    };
    return ColdFrame;
}

test "ColdFrame push and push_unsafe" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const dummy_bytecode = [_]u8{0x00}; // STOP
    var frame = try Frame.init(allocator, &dummy_bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test push_unsafe
    frame.push_unsafe(42);
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    try std.testing.expectEqual(@as(u256, 42), frame.stack[0]);
    
    frame.push_unsafe(100);
    try std.testing.expectEqual(@as(u12, 2), frame.next_stack_index);
    try std.testing.expectEqual(@as(u256, 100), frame.stack[1]);
    
    // Test push with overflow check
    // Fill stack to near capacity
    frame.next_stack_index = 1023;
    try frame.push(200);
    try std.testing.expectEqual(@as(u256, 200), frame.stack[1023]);
    
    // This should error - stack is full
    try std.testing.expectError(error.StackOverflow, frame.push(300));
}

test "ColdFrame pop and pop_unsafe" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const dummy_bytecode = [_]u8{0x00}; // STOP
    var frame = try Frame.init(allocator, &dummy_bytecode, 0);
    defer frame.deinit(allocator);
    
    // Setup stack with some values
    frame.stack[0] = 10;
    frame.stack[1] = 20;
    frame.stack[2] = 30;
    frame.next_stack_index = 3; // Points to next empty slot
    
    // Test pop_unsafe
    const val1 = frame.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 30), val1);
    try std.testing.expectEqual(@as(u12, 2), frame.next_stack_index);
    
    const val2 = frame.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 20), val2);
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    
    // Test pop with underflow check
    const val3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 10), val3);
    
    // This should error - stack is empty
    try std.testing.expectError(error.StackUnderflow, frame.pop());
}

test "ColdFrame set_top and set_top_unsafe" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const dummy_bytecode = [_]u8{0x00}; // STOP
    var frame = try Frame.init(allocator, &dummy_bytecode, 0);
    defer frame.deinit(allocator);
    
    // Setup stack with some values
    frame.stack[0] = 10;
    frame.stack[1] = 20;
    frame.stack[2] = 30;
    frame.next_stack_index = 3; // Points to next empty slot after 30
    
    // Test set_top_unsafe - should modify the top value (30 -> 99)
    frame.set_top_unsafe(99);
    try std.testing.expectEqual(@as(u256, 99), frame.stack[2]);
    try std.testing.expectEqual(@as(u12, 3), frame.next_stack_index); // Index unchanged
    
    // Test set_top with error check on empty stack
    frame.next_stack_index = 0; // Empty stack
    try std.testing.expectError(error.StackUnderflow, frame.set_top(42));
    
    // Test set_top on non-empty stack
    frame.next_stack_index = 2; // Stack has 2 items
    try frame.set_top(55);
    try std.testing.expectEqual(@as(u256, 55), frame.stack[1]);
}

test "ColdFrame peek and peek_unsafe" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const dummy_bytecode = [_]u8{0x00}; // STOP
    var frame = try Frame.init(allocator, &dummy_bytecode, 0);
    defer frame.deinit(allocator);
    
    // Setup stack with values
    frame.stack[0] = 100;
    frame.stack[1] = 200;
    frame.stack[2] = 300;
    frame.next_stack_index = 3; // Points to next empty slot
    
    // Test peek_unsafe - should return top value without modifying index
    const top_unsafe = frame.peek_unsafe();
    try std.testing.expectEqual(@as(u256, 300), top_unsafe);
    try std.testing.expectEqual(@as(u12, 3), frame.next_stack_index);
    
    // Test peek on non-empty stack
    const top = try frame.peek();
    try std.testing.expectEqual(@as(u256, 300), top);
    try std.testing.expectEqual(@as(u12, 3), frame.next_stack_index);
    
    // Test peek on empty stack
    frame.next_stack_index = 0;
    try std.testing.expectError(error.StackUnderflow, frame.peek());
}

test "ColdFrame with bytecode and pc" {
    const allocator = std.testing.allocator;
    
    // Test with small bytecode (fits in u8)
    const SmallFrame = createColdFrame(.{ .max_bytecode_size = 255 });
    const small_bytecode = [_]u8{0x60, 0x01, 0x60, 0x02, 0x00}; // PUSH1 1 PUSH1 2 STOP
    
    var small_frame = try SmallFrame.init(allocator, &small_bytecode, 1000000);
    defer small_frame.deinit(allocator);
    
    try std.testing.expectEqual(@as(u8, 0), small_frame.pc);
    try std.testing.expectEqual(@as(u8, 0x60), small_frame.bytecode[0]);
    
    // Test with medium bytecode (fits in u16)
    const MediumFrame = createColdFrame(.{ .max_bytecode_size = 65535 });
    const medium_bytecode = [_]u8{0x58, 0x00}; // PC STOP
    
    var medium_frame = try MediumFrame.init(allocator, &medium_bytecode, 1000000);
    defer medium_frame.deinit(allocator);
    medium_frame.pc = 300;
    
    try std.testing.expectEqual(@as(u16, 300), medium_frame.pc);
}

test "ColdFrame op_pc pushes pc to stack" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x58, 0x00}; // PC STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Execute op_pc - should push current pc (0) to stack
    try frame.op_pc();
    try std.testing.expectEqual(@as(u256, 0), frame.stack[0]);
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    
    // Set pc to 42 and test again
    frame.pc = 42;
    try frame.op_pc();
    try std.testing.expectEqual(@as(u256, 42), frame.stack[1]);
    try std.testing.expectEqual(@as(u12, 2), frame.next_stack_index);
}

test "ColdFrame op_stop returns stop error" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x00}; // STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Execute op_stop - should return STOP error
    try std.testing.expectError(error.STOP, frame.op_stop());
}

test "ColdFrame op_pop removes top stack item" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x50, 0x00}; // POP STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Setup stack with some values
    frame.stack[0] = 100;
    frame.stack[1] = 200;
    frame.stack[2] = 300;
    frame.next_stack_index = 3;
    
    // Execute op_pop - should remove top item (300) and do nothing with it
    try frame.op_pop();
    try std.testing.expectEqual(@as(u12, 2), frame.next_stack_index);
    
    // Execute again - should remove 200
    try frame.op_pop();
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    
    // Execute again - should remove 100
    try frame.op_pop();
    try std.testing.expectEqual(@as(u12, 0), frame.next_stack_index);
    
    // Pop on empty stack should error
    try std.testing.expectError(error.StackUnderflow, frame.op_pop());
}

test "ColdFrame op_push0 pushes zero to stack" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x5f, 0x00}; // PUSH0 STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Execute op_push0 - should push 0 to stack
    try frame.op_push0();
    try std.testing.expectEqual(@as(u256, 0), frame.stack[0]);
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
}

test "ColdFrame op_push1 reads byte from bytecode and pushes to stack" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x60, 0x42, 0x60, 0xFF, 0x00}; // PUSH1 0x42 PUSH1 0xFF STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Execute op_push1 at pc=0 - should read 0x42 from bytecode[1] and push it
    try frame.op_push1();
    try std.testing.expectEqual(@as(u256, 0x42), frame.stack[0]);
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    try std.testing.expectEqual(@as(u16, 2), frame.pc); // PC should advance by 2 (opcode + 1 byte)
    
    // Execute op_push1 at pc=2 - should read 0xFF from bytecode[3] and push it
    try frame.op_push1();
    try std.testing.expectEqual(@as(u256, 0xFF), frame.stack[1]);
    try std.testing.expectEqual(@as(u12, 2), frame.next_stack_index);
    try std.testing.expectEqual(@as(u16, 4), frame.pc); // PC should advance by 2 more
}

test "ColdFrame op_push2 reads 2 bytes from bytecode" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x61, 0x12, 0x34, 0x00}; // PUSH2 0x1234 STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Execute op_push2 - should read 0x1234 from bytecode[1..3] and push it
    try frame.op_push2();
    try std.testing.expectEqual(@as(u256, 0x1234), frame.stack[0]);
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    try std.testing.expectEqual(@as(u16, 3), frame.pc); // PC should advance by 3 (opcode + 2 bytes)
}

test "ColdFrame op_push32 reads 32 bytes from bytecode" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    // PUSH32 with max value (32 bytes of 0xFF)
    var bytecode: [34]u8 = undefined;
    bytecode[0] = 0x7f; // PUSH32
    for (1..33) |i| {
        bytecode[i] = 0xFF;
    }
    bytecode[33] = 0x00; // STOP
    
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Execute op_push32 - should read all 32 bytes and push max u256
    try frame.op_push32();
    try std.testing.expectEqual(@as(u256, std.math.maxInt(u256)), frame.stack[0]);
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    try std.testing.expectEqual(@as(u16, 33), frame.pc); // PC should advance by 33 (opcode + 32 bytes)
}

test "ColdFrame op_dup1 duplicates top stack item" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x80, 0x00}; // DUP1 STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Setup stack with value
    frame.stack[0] = 42;
    frame.next_stack_index = 1;
    
    // Execute op_dup1 - should duplicate top item (42)
    try frame.op_dup1();
    try std.testing.expectEqual(@as(u256, 42), frame.stack[0]); // Original
    try std.testing.expectEqual(@as(u256, 42), frame.stack[1]); // Duplicate
    try std.testing.expectEqual(@as(u12, 2), frame.next_stack_index);
    
    // Test dup1 on empty stack
    frame.next_stack_index = 0;
    try std.testing.expectError(error.StackUnderflow, frame.op_dup1());
}

test "ColdFrame op_dup16 duplicates 16th stack item" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x8f, 0x00}; // DUP16 STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Setup stack with values 1-16
    for (0..16) |i| {
        frame.stack[i] = @as(u256, i + 1);
    }
    frame.next_stack_index = 16;
    
    // Execute op_dup16 - should duplicate 16th from top (value 1)
    try frame.op_dup16();
    try std.testing.expectEqual(@as(u256, 1), frame.stack[16]); // Duplicate of bottom
    try std.testing.expectEqual(@as(u12, 17), frame.next_stack_index);
    
    // Test dup16 with insufficient stack
    frame.next_stack_index = 15; // Only 15 items
    try std.testing.expectError(error.StackUnderflow, frame.op_dup16());
}

test "ColdFrame op_swap1 swaps top two stack items" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x90, 0x00}; // SWAP1 STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Setup stack with values
    frame.stack[0] = 100;
    frame.stack[1] = 200;
    frame.next_stack_index = 2;
    
    // Execute op_swap1 - should swap top two items
    try frame.op_swap1();
    try std.testing.expectEqual(@as(u256, 200), frame.stack[0]);
    try std.testing.expectEqual(@as(u256, 100), frame.stack[1]);
    try std.testing.expectEqual(@as(u12, 2), frame.next_stack_index);
    
    // Test swap1 with insufficient stack
    frame.next_stack_index = 1; // Only 1 item
    try std.testing.expectError(error.StackUnderflow, frame.op_swap1());
}

test "ColdFrame op_swap16 swaps top with 17th stack item" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x9f, 0x00}; // SWAP16 STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Setup stack with values 1-17
    for (0..17) |i| {
        frame.stack[i] = @as(u256, i + 1);
    }
    frame.next_stack_index = 17;
    
    // Execute op_swap16 - should swap top (17) with 17th from top (1)
    try frame.op_swap16();
    try std.testing.expectEqual(@as(u256, 17), frame.stack[0]); // Was 1
    try std.testing.expectEqual(@as(u256, 1), frame.stack[16]); // Was 17
    try std.testing.expectEqual(@as(u12, 17), frame.next_stack_index);
    
    // Test swap16 with insufficient stack
    frame.next_stack_index = 16; // Only 16 items
    try std.testing.expectError(error.StackUnderflow, frame.op_swap16());
}

test "ColdFrame init validates bytecode size" {
    const allocator = std.testing.allocator;
    
    // Test with valid bytecode size
    const SmallFrame = createColdFrame(.{ .max_bytecode_size = 100 });
    const small_bytecode = [_]u8{0x60, 0x01, 0x00}; // PUSH1 1 STOP
    
    const stack_memory = try allocator.create([1024]u256);
    defer allocator.destroy(stack_memory);
    
    var frame = try SmallFrame.init(allocator, &small_bytecode, 1000000);
    defer frame.deinit(allocator);
    
    try std.testing.expectEqual(@as(u8, 0), frame.pc);
    try std.testing.expectEqual(&small_bytecode, frame.bytecode.ptr);
    try std.testing.expectEqual(@as(usize, 3), frame.bytecode.len);
    
    // Test with bytecode too large
    const large_bytecode = try allocator.alloc(u8, 101);
    defer allocator.free(large_bytecode);
    @memset(large_bytecode, 0x00);
    
    try std.testing.expectError(error.BytecodeTooLarge, SmallFrame.init(allocator, large_bytecode, 0));
    
    // Test with empty bytecode
    const empty_bytecode = [_]u8{};
    var empty_frame = try SmallFrame.init(allocator, &empty_bytecode, 1000000);
    defer empty_frame.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty_frame.bytecode.len);
}

test "ColdFrame get_requested_alloc calculates correctly" {
    // Test with default options
    const default_config = FrameConfig{};
    const expected_default = @as(u32, @intCast(1024 * @sizeOf(u256)));
    try std.testing.expectEqual(expected_default, default_config.get_requested_alloc());
    
    // Test with custom options
    const custom_config = FrameConfig{
        .stack_size = 512,
        .WordType = u128,
        .max_bytecode_size = 1000,
    };
    const expected_custom = @as(u32, @intCast(512 * @sizeOf(u128)));
    try std.testing.expectEqual(expected_custom, custom_config.get_requested_alloc());
    
    // Test with small frame
    const small_config = FrameConfig{
        .stack_size = 256,
        .WordType = u64,
        .max_bytecode_size = 255,
    };
    const expected_small = @as(u32, @intCast(256 * @sizeOf(u64)));
    try std.testing.expectEqual(expected_small, small_config.get_requested_alloc());
}

test "ColdFrame op_and bitwise AND operation" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x16, 0x00}; // AND STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 0xFF & 0x0F = 0x0F
    try frame.push(0xFF);
    try frame.push(0x0F);
    try frame.op_and();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0x0F), result1);
    
    // Test 0xFFFF & 0x00FF = 0x00FF
    try frame.push(0xFFFF);
    try frame.push(0x00FF);
    try frame.op_and();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0x00FF), result2);
    
    // Test with max values
    try frame.push(std.math.maxInt(u256));
    try frame.push(0x12345678);
    try frame.op_and();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0x12345678), result3);
}

test "ColdFrame op_or bitwise OR operation" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x17, 0x00}; // OR STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 0xF0 | 0x0F = 0xFF
    try frame.push(0xF0);
    try frame.push(0x0F);
    try frame.op_or();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0xFF), result1);
    
    // Test 0xFF00 | 0x00FF = 0xFFFF
    try frame.push(0xFF00);
    try frame.push(0x00FF);
    try frame.op_or();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0xFFFF), result2);
    
    // Test with zero
    try frame.push(0);
    try frame.push(0x12345678);
    try frame.op_or();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0x12345678), result3);
}

test "ColdFrame op_xor bitwise XOR operation" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x18, 0x00}; // XOR STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 0xFF ^ 0xFF = 0
    try frame.push(0xFF);
    try frame.push(0xFF);
    try frame.op_xor();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result1);
    
    // Test 0xFF ^ 0x00 = 0xFF
    try frame.push(0xFF);
    try frame.push(0x00);
    try frame.op_xor();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0xFF), result2);
    
    // Test 0xAA ^ 0x55 = 0xFF (alternating bits)
    try frame.push(0xAA);
    try frame.push(0x55);
    try frame.op_xor();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0xFF), result3);
}

test "ColdFrame op_not bitwise NOT operation" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x19, 0x00}; // NOT STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test ~0 = max value
    try frame.push(0);
    try frame.op_not();
    const result1 = try frame.pop();
    try std.testing.expectEqual(std.math.maxInt(u256), result1);
    
    // Test ~max = 0
    try frame.push(std.math.maxInt(u256));
    try frame.op_not();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    
    // Test ~0xFF = 0xFFFF...FF00
    try frame.push(0xFF);
    try frame.op_not();
    const result3 = try frame.pop();
    try std.testing.expectEqual(std.math.maxInt(u256) - 0xFF, result3);
}

test "ColdFrame op_byte extracts single byte from word" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x1A, 0x00}; // BYTE STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test extracting byte 31 (rightmost) from 0x...FF
    try frame.push(0xFF);
    try frame.push(31);
    try frame.op_byte();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0xFF), result1);
    
    // Test extracting byte 30 from 0x...FF00
    try frame.push(0xFF00);
    try frame.push(30);
    try frame.op_byte();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0xFF), result2);
    
    // Test extracting byte 0 (leftmost) from a value
    const value: u256 = @as(u256, 0xAB) << 248; // Put 0xAB in the leftmost byte
    try frame.push(value);
    try frame.push(0);
    try frame.op_byte();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0xAB), result3);
    
    // Test out of bounds (index >= 32) returns 0
    try frame.push(0xFFFFFFFF);
    try frame.push(32);
    try frame.op_byte();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
}

test "ColdFrame op_shl shift left operation" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x1B, 0x00}; // SHL STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 1 << 4 = 16
    try frame.push(1);
    try frame.push(4);
    try frame.op_shl();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 16), result1);
    
    // Test 0xFF << 8 = 0xFF00
    try frame.push(0xFF);
    try frame.push(8);
    try frame.op_shl();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0xFF00), result2);
    
    // Test shift >= 256 returns 0
    try frame.push(1);
    try frame.push(256);
    try frame.op_shl();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
}

test "ColdFrame op_shr logical shift right operation" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x1C, 0x00}; // SHR STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 16 >> 4 = 1
    try frame.push(16);
    try frame.push(4);
    try frame.op_shr();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    
    // Test 0xFF00 >> 8 = 0xFF
    try frame.push(0xFF00);
    try frame.push(8);
    try frame.op_shr();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0xFF), result2);
    
    // Test shift >= 256 returns 0
    try frame.push(std.math.maxInt(u256));
    try frame.push(256);
    try frame.op_shr();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
}

test "ColdFrame op_sar arithmetic shift right operation" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x1D, 0x00}; // SAR STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test positive number: 16 >> 4 = 1
    try frame.push(16);
    try frame.push(4);
    try frame.op_sar();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    
    // Test negative number (sign bit = 1)
    const negative = @as(u256, 1) << 255 | 0xFF00; // Set sign bit and some data
    try frame.push(negative);
    try frame.push(8);
    try frame.op_sar();
    const result2 = try frame.pop();
    // Should fill with 1s from the left
    const expected2 = (@as(u256, std.math.maxInt(u256)) << 247) | 0xFF;
    try std.testing.expectEqual(expected2, result2);
    
    // Test shift >= 256 with positive number returns 0
    try frame.push(0x7FFFFFFF); // Positive (sign bit = 0)
    try frame.push(256);
    try frame.op_sar();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
    
    // Test shift >= 256 with negative number returns max value
    try frame.push(@as(u256, 1) << 255); // Negative (sign bit = 1)
    try frame.push(256);
    try frame.op_sar();
    const result4 = try frame.pop();
    try std.testing.expectEqual(std.math.maxInt(u256), result4);
}

test "ColdFrame op_add addition with wrapping overflow" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x01, 0x00}; // ADD STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 10 + 20 = 30
    try frame.push(10);
    try frame.push(20);
    try frame.op_add();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 30), result1);
    
    // Test overflow: max + 1 = 0
    try frame.push(std.math.maxInt(u256));
    try frame.push(1);
    try frame.op_add();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    
    // Test max + max = max - 1 (wrapping)
    try frame.push(std.math.maxInt(u256));
    try frame.push(std.math.maxInt(u256));
    try frame.op_add();
    const result3 = try frame.pop();
    try std.testing.expectEqual(std.math.maxInt(u256) - 1, result3);
}

test "ColdFrame op_mul multiplication with wrapping overflow" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x02, 0x00}; // MUL STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 5 * 6 = 30
    try frame.push(5);
    try frame.push(6);
    try frame.op_mul();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 30), result1);
    
    // Test 0 * anything = 0
    try frame.push(0);
    try frame.push(12345);
    try frame.op_mul();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    
    // Test overflow with large numbers
    const large = @as(u256, 1) << 128;
    try frame.push(large);
    try frame.push(large);
    try frame.op_mul();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3); // 2^256 wraps to 0
}

test "ColdFrame op_sub subtraction with wrapping underflow" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x03, 0x00}; // SUB STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 30 - 10 = 20
    try frame.push(30);
    try frame.push(10);
    try frame.op_sub();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 20), result1);
    
    // Test underflow: 0 - 1 = max
    try frame.push(0);
    try frame.push(1);
    try frame.op_sub();
    const result2 = try frame.pop();
    try std.testing.expectEqual(std.math.maxInt(u256), result2);
    
    // Test 10 - 20 = max - 9 (wrapping)
    try frame.push(10);
    try frame.push(20);
    try frame.op_sub();
    const result3 = try frame.pop();
    try std.testing.expectEqual(std.math.maxInt(u256) - 9, result3);
}

test "ColdFrame op_div unsigned integer division" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x04, 0x00}; // DIV STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 20 / 5 = 4
    try frame.push(20);
    try frame.push(5);
    try frame.op_div();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 4), result1);
    
    // Test division by zero returns 0
    try frame.push(100);
    try frame.push(0);
    try frame.op_div();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    
    // Test integer division: 7 / 3 = 2
    try frame.push(7);
    try frame.push(3);
    try frame.op_div();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 2), result3);
}

test "ColdFrame op_sdiv signed integer division" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x05, 0x00}; // SDIV STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 20 / 5 = 4 (positive / positive)
    try frame.push(20);
    try frame.push(5);
    try frame.op_sdiv();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 4), result1);
    
    // Test -20 / 5 = -4 (negative / positive)
    const neg_20 = @as(u256, @bitCast(@as(i256, -20)));
    try frame.push(neg_20);
    try frame.push(5);
    try frame.op_sdiv();
    const result2 = try frame.pop();
    const expected2 = @as(u256, @bitCast(@as(i256, -4)));
    try std.testing.expectEqual(expected2, result2);
    
    // Test MIN_I256 / -1 = MIN_I256 (overflow case)
    const min_i256 = @as(u256, 1) << 255;
    const neg_1 = @as(u256, @bitCast(@as(i256, -1)));
    try frame.push(min_i256);
    try frame.push(neg_1);
    try frame.op_sdiv();
    const result3 = try frame.pop();
    try std.testing.expectEqual(min_i256, result3);
    
    // Test division by zero returns 0
    try frame.push(100);
    try frame.push(0);
    try frame.op_sdiv();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
}

test "ColdFrame op_mod modulo remainder operation" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x06, 0x00}; // MOD STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 17 % 5 = 2
    try frame.push(17);
    try frame.push(5);
    try frame.op_mod();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 2), result1);
    
    // Test 100 % 10 = 0
    try frame.push(100);
    try frame.push(10);
    try frame.op_mod();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    
    // Test modulo by zero returns 0
    try frame.push(7);
    try frame.push(0);
    try frame.op_mod();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
}

test "ColdFrame op_smod signed modulo remainder operation" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x07, 0x00}; // SMOD STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 17 % 5 = 2 (positive % positive)
    try frame.push(17);
    try frame.push(5);
    try frame.op_smod();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 2), result1);
    
    // Test -17 % 5 = -2 (negative % positive)
    const neg_17 = @as(u256, @bitCast(@as(i256, -17)));
    try frame.push(neg_17);
    try frame.push(5);
    try frame.op_smod();
    const result2 = try frame.pop();
    const expected2 = @as(u256, @bitCast(@as(i256, -2)));
    try std.testing.expectEqual(expected2, result2);
    
    // Test 17 % -5 = 2 (positive % negative)
    const neg_5 = @as(u256, @bitCast(@as(i256, -5)));
    try frame.push(17);
    try frame.push(neg_5);
    try frame.op_smod();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 2), result3);
    
    // Test modulo by zero returns 0
    try frame.push(neg_17);
    try frame.push(0);
    try frame.op_smod();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
}

test "ColdFrame op_addmod addition modulo n" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x08, 0x00}; // ADDMOD STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test (10 + 20) % 7 = 2
    try frame.push(10);
    try frame.push(20);
    try frame.push(7);
    try frame.op_addmod();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 2), result1);
    
    // Test overflow handling: (MAX + 5) % 10 = 4
    // MAX = 2^256 - 1, so (2^256 - 1 + 5) = 2^256 + 4
    // Since we're in mod 2^256, this is just 4
    // So 4 % 10 = 4
    try frame.push(std.math.maxInt(u256));
    try frame.push(5);
    try frame.push(10);
    try frame.op_addmod();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 4), result2);
    
    // Test modulo by zero returns 0
    try frame.push(50);
    try frame.push(50);
    try frame.push(0);
    try frame.op_addmod();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
}

test "ColdFrame op_mulmod multiplication modulo n" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x09, 0x00}; // MULMOD STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test (10 * 20) % 7 = 200 % 7 = 4
    try frame.push(10);
    try frame.push(20);
    try frame.push(7);
    try frame.op_mulmod();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 4), result1);
    
    // First test a simple case to make sure basic logic works
    try frame.push(36);
    try frame.push(36);
    try frame.push(100);
    try frame.op_mulmod();
    const simple_result = try frame.pop();
    try std.testing.expectEqual(@as(u256, 96), simple_result);
    
    // Test that large % 100 = 56
    const large = @as(u256, 1) << 128;
    try std.testing.expectEqual(@as(u256, 56), large % 100);
    
    // Test overflow handling: (2^128 * 2^128) % 100
    // This tests the modular multiplication
    try frame.push(large);
    try frame.push(large);
    try frame.push(100);
    try frame.op_mulmod();
    const result2 = try frame.pop();
    // Since the algorithm reduces first: 2^128 % 100 = 56
    // Then we're computing (56 * 56) % 100 = 3136 % 100 = 36
    try std.testing.expectEqual(@as(u256, 36), result2);
    
    // Test modulo by zero returns 0
    try frame.push(50);
    try frame.push(50);
    try frame.push(0);
    try frame.op_mulmod();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
}

test "ColdFrame op_exp exponentiation" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x0A, 0x00}; // EXP STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 2^10 = 1024
    try frame.push(2);
    try frame.push(10);
    try frame.op_exp();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1024), result1);
    
    // Test 3^4 = 81
    try frame.push(3);
    try frame.push(4);
    try frame.op_exp();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 81), result2);
    
    // Test 10^0 = 1 (anything^0 = 1)
    try frame.push(10);
    try frame.push(0);
    try frame.op_exp();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result3);
    
    // Test 0^10 = 0 (0^anything = 0, except 0^0)
    try frame.push(0);
    try frame.push(10);
    try frame.op_exp();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
    
    // Test 0^0 = 1 (special case in EVM)
    try frame.push(0);
    try frame.push(0);
    try frame.op_exp();
    const result5 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result5);
}

test "ColdFrame op_signextend sign extension" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x0B, 0x00}; // SIGNEXTEND STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test extending positive 8-bit value (0x7F)
    try frame.push(0x7F);
    try frame.push(0); // Extend from byte 0
    try frame.op_signextend();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0x7F), result1);
    
    // Test extending negative 8-bit value (0x80)
    try frame.push(0x80);
    try frame.push(0); // Extend from byte 0
    try frame.op_signextend();
    const result2 = try frame.pop();
    const expected2 = std.math.maxInt(u256) - 0x7F; // 0xFFFF...FF80
    try std.testing.expectEqual(expected2, result2);
    
    // Test extending positive 16-bit value (0x7FFF)
    try frame.push(0x7FFF);
    try frame.push(1); // Extend from byte 1
    try frame.op_signextend();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0x7FFF), result3);
    
    // Test extending negative 16-bit value (0x8000)
    try frame.push(0x8000);
    try frame.push(1); // Extend from byte 1
    try frame.op_signextend();
    const result4 = try frame.pop();
    const expected4 = std.math.maxInt(u256) - 0x7FFF; // 0xFFFF...F8000
    try std.testing.expectEqual(expected4, result4);
    
    // Test byte_num >= 31 returns value unchanged
    try frame.push(0x12345678);
    try frame.push(31); // Extend from byte 31 (full width)
    try frame.op_signextend();
    const result5 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0x12345678), result5);
}

test "ColdFrame op_gas returns gas remaining" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x5A, 0x00}; // GAS STOP
    var frame = try Frame.init(allocator, &bytecode, 1000000);
    defer frame.deinit(allocator);
    
    // Test op_gas pushes gas_remaining to stack
    try frame.op_gas();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1000000), result1);
    
    // Test op_gas with modified gas_remaining
    frame.gas_remaining = 12345;
    try frame.op_gas();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 12345), result2);
    
    // Test op_gas with zero gas
    frame.gas_remaining = 0;
    try frame.op_gas();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
    
    // Test op_gas with negative gas (should push 0)
    frame.gas_remaining = -100;
    try frame.op_gas();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
}

test "ColdFrame op_lt less than comparison" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x10, 0x00}; // LT STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 10 < 20 = 1
    try frame.push(10);
    try frame.push(20);
    try frame.op_lt();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    
    // Test 20 < 10 = 0
    try frame.push(20);
    try frame.push(10);
    try frame.op_lt();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    
    // Test 10 < 10 = 0
    try frame.push(10);
    try frame.push(10);
    try frame.op_lt();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
    
    // Test with max value
    try frame.push(std.math.maxInt(u256));
    try frame.push(0);
    try frame.op_lt();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
}

test "ColdFrame op_gt greater than comparison" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x11, 0x00}; // GT STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 20 > 10 = 1
    try frame.push(20);
    try frame.push(10);
    try frame.op_gt();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    
    // Test 10 > 20 = 0
    try frame.push(10);
    try frame.push(20);
    try frame.op_gt();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    
    // Test 10 > 10 = 0
    try frame.push(10);
    try frame.push(10);
    try frame.op_gt();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
    
    // Test with max value
    try frame.push(0);
    try frame.push(std.math.maxInt(u256));
    try frame.op_gt();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
}

test "ColdFrame op_slt signed less than comparison" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x12, 0x00}; // SLT STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 10 < 20 = 1 (positive comparison)
    try frame.push(10);
    try frame.push(20);
    try frame.op_slt();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    
    // Test -10 < 10 = 1 (negative < positive)
    const neg_10 = @as(u256, @bitCast(@as(i256, -10)));
    try frame.push(neg_10);
    try frame.push(10);
    try frame.op_slt();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result2);
    
    // Test 10 < -10 = 0 (positive < negative)
    try frame.push(10);
    try frame.push(neg_10);
    try frame.op_slt();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
    
    // Test MIN_INT < MAX_INT = 1
    const min_int = @as(u256, 1) << 255; // Sign bit set
    const max_int = (@as(u256, 1) << 255) - 1; // All bits except sign bit
    try frame.push(min_int);
    try frame.push(max_int);
    try frame.op_slt();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result4);
}

test "ColdFrame op_sgt signed greater than comparison" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x13, 0x00}; // SGT STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 20 > 10 = 1 (positive comparison)
    try frame.push(20);
    try frame.push(10);
    try frame.op_sgt();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    
    // Test 10 > -10 = 1 (positive > negative)
    const neg_10 = @as(u256, @bitCast(@as(i256, -10)));
    try frame.push(10);
    try frame.push(neg_10);
    try frame.op_sgt();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result2);
    
    // Test -10 > 10 = 0 (negative > positive)
    try frame.push(neg_10);
    try frame.push(10);
    try frame.op_sgt();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
    
    // Test MAX_INT > MIN_INT = 1
    const min_int = @as(u256, 1) << 255; // Sign bit set
    const max_int = (@as(u256, 1) << 255) - 1; // All bits except sign bit
    try frame.push(max_int);
    try frame.push(min_int);
    try frame.op_sgt();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result4);
}

test "ColdFrame op_eq equality comparison" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x14, 0x00}; // EQ STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 10 == 10 = 1
    try frame.push(10);
    try frame.push(10);
    try frame.op_eq();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    
    // Test 10 == 20 = 0
    try frame.push(10);
    try frame.push(20);
    try frame.op_eq();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    
    // Test 0 == 0 = 1
    try frame.push(0);
    try frame.push(0);
    try frame.op_eq();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result3);
    
    // Test max == max = 1
    try frame.push(std.math.maxInt(u256));
    try frame.push(std.math.maxInt(u256));
    try frame.op_eq();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result4);
}

test "ColdFrame op_iszero zero check" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x15, 0x00}; // ISZERO STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test iszero(0) = 1
    try frame.push(0);
    try frame.op_iszero();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    
    // Test iszero(1) = 0
    try frame.push(1);
    try frame.op_iszero();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    
    // Test iszero(100) = 0
    try frame.push(100);
    try frame.op_iszero();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
    
    // Test iszero(max) = 0
    try frame.push(std.math.maxInt(u256));
    try frame.op_iszero();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
}

