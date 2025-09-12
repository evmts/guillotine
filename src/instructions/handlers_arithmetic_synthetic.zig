const std = @import("std");
const FrameConfig = @import("../frame/frame_config.zig").FrameConfig;
const log = @import("../log.zig");

/// Synthetic arithmetic opcode handlers for the EVM stack frame.
/// These handle fused PUSH+arithmetic operations for optimization.
pub fn Handlers(comptime FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;

        const dispatch = @import("../preprocessor/dispatch_opcode_data.zig");

        /// Validate stack constraints
        pub inline fn validate_stack(self: *FrameType) void {
            std.debug.assert(self.stack.size() >= 1); 
            std.debug.assert(self.stack.size() < @TypeOf(self.stack).stack_capacity); 
        }

        /// PUSH_ADD_INLINE - Fused PUSH+ADD with inline value (≤8 bytes).
        /// Pushes a value and immediately adds it to the top of stack.
        pub fn push_add_inline(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            @branchHint(.likely);
            validate_stack(self);
            
            const op_data = dispatch.getOpData(.PUSH_ADD_INLINE, Dispatch, Dispatch.Item, cursor);
            const top = self.stack.peek_unsafe();
            self.stack.set_top_unsafe(op_data.metadata.value +% top);

            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// PUSH_ADD_POINTER - Fused PUSH+ADD with pointer value (>8 bytes).
        pub fn push_add_pointer(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            validate_stack(self);

            const op_data = dispatch.getOpData(.PUSH_ADD_POINTER, Dispatch, Dispatch.Item, cursor);
            const top = self.stack.peek_unsafe();
            self.stack.set_top_unsafe(op_data.metadata.value.* +% top);
            
            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// PUSH_MUL_INLINE - Fused PUSH+MUL with inline value (≤8 bytes).
        pub fn push_mul_inline(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            validate_stack(self);
            
            const op_data = dispatch.getOpData(.PUSH_MUL_INLINE, Dispatch, Dispatch.Item, cursor);
            const top = self.stack.peek_unsafe();
            self.stack.set_top_unsafe(op_data.metadata.value *% top);

            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// PUSH_MUL_POINTER - Fused PUSH+MUL with pointer value (>8 bytes).
        pub fn push_mul_pointer(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            validate_stack(self);

            const op_data = dispatch.getOpData(.PUSH_MUL_POINTER, Dispatch, Dispatch.Item, cursor);
            const top = self.stack.peek_unsafe();
            self.stack.set_top_unsafe(op_data.metadata.value.* *% top);

            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// PUSH_DIV_INLINE - Fused PUSH+DIV with inline value (≤8 bytes).
        pub fn push_div_inline(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const op_data = dispatch.getOpData(.PUSH_DIV_INLINE, Dispatch, Dispatch.Item, cursor);
            const dividend = op_data.metadata.value;

            const divisor = self.stack.peek_unsafe();
            
            const Uint = @import("primitives").Uint;
            const U256 = Uint(256, 4);
            const dividend_u256 = U256.from_native(dividend);
            const divisor_u256 = U256.from_native(divisor);
            
            const result_u256 = dividend_u256.wrapping_div(divisor_u256);
            const result = result_u256.to_native();
            
            self.stack.set_top_unsafe(result);

            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// PUSH_DIV_POINTER - Fused PUSH+DIV with pointer value (>8 bytes).
        pub fn push_div_pointer(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const op_data = dispatch.getOpData(.PUSH_DIV_POINTER, Dispatch, Dispatch.Item, cursor);
            const dividend = op_data.metadata.value.*;

            std.debug.assert(self.stack.size() >= 1); // PUSH_DIV_POINTER requires 1 stack item
            const divisor = self.stack.peek_unsafe();
            
            // Convert to U256 for optimized division
            const Uint = @import("primitives").Uint;
            const U256 = Uint(256, 4);
            const dividend_u256 = U256.from_native(dividend);
            const divisor_u256 = U256.from_native(divisor);
            
            const result_u256 = dividend_u256.wrapping_div(divisor_u256);
            const result = result_u256.to_native();
            
            self.stack.set_top_unsafe(result);

            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// PUSH_SUB_INLINE - Fused PUSH+SUB with inline value (≤8 bytes).
        pub fn push_sub_inline(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const op_data = dispatch.getOpData(.PUSH_SUB_INLINE, Dispatch, Dispatch.Item, cursor);
            const push_value = op_data.metadata.value;
            std.debug.assert(self.stack.size() >= 1); // PUSH_SUB_INLINE requires 1 stack item
            const top = self.stack.peek_unsafe();
            const result = push_value -% top;
            self.stack.set_top_unsafe(result);
            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// PUSH_SUB_POINTER - Fused PUSH+SUB with pointer value (>8 bytes).
        pub fn push_sub_pointer(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const op_data = dispatch.getOpData(.PUSH_SUB_POINTER, Dispatch, Dispatch.Item, cursor);
            std.debug.assert(self.stack.size() >= 1); 
            const top = self.stack.peek_unsafe();
            const result = op_data.metadata.value.* -% top;
            self.stack.set_top_unsafe(result);
            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }
    };
}

// ====== TESTS ======

const testing = std.testing;
const Frame = @import("../frame/frame.zig").Frame;
const dispatch_mod = @import("../preprocessor/dispatch.zig");
const NoOpTracer = @import("../tracer/tracer.zig").NoOpTracer;
const bytecode_mod = @import("../bytecode/bytecode.zig");

// Test configuration
const test_config = FrameConfig{
    .stack_size = 1024,
    .WordType = u256,
    .max_bytecode_size = 1024,
    .block_gas_limit = 30_000_000,
    .DatabaseType = @import("../storage/memory_database.zig").MemoryDatabase,
    .TracerType = NoOpTracer,
    .memory_initial_capacity = 4096,
    .memory_limit = 0xFFFFFF,
};

const TestFrame = Frame(test_config);
const TestBytecode = bytecode_mod.Bytecode(.{ .max_bytecode_size = test_config.max_bytecode_size });
const Address = @import("primitives").Address.Address;
const MemoryDatabase = @import("../storage/memory_database.zig").MemoryDatabase;

fn createTestFrame(allocator: std.mem.Allocator) !TestFrame {
    const database = MemoryDatabase.init(allocator);
    const value = try allocator.create(u256);
    value.* = 0;
    var frame = try TestFrame.init(allocator, 1_000_000, database, Address.ZERO_ADDRESS, value, &[_]u8{}, @ptrFromInt(1));
    // Initialize empty code
    frame.code = &[_]u8{};
    return frame;
}

fn destroyTestFrame(frame: *TestFrame, allocator: std.mem.Allocator) void {
    frame.database.deinit();
    allocator.destroy(@ptrCast(@alignCast(frame.value)));
    frame.deinit(allocator);
}

// Test helpers to create proper dispatch items
var test_cursor_storage: [3]TestFrame.Dispatch.Item = undefined;
var test_value_storage: u256 = undefined;

fn stopHandler(frame: *TestFrame, cursor: [*]const TestFrame.Dispatch.Item) TestFrame.Error!noreturn {
    _ = frame;
    _ = cursor;
    return TestFrame.Error.Stop;
}

fn createTestCursorInline(value: u256) [*]TestFrame.Dispatch.Item {
    // Store value as u64 (truncating for inline metadata)
    const inline_value = @as(u64, @truncate(value));
    
    test_cursor_storage[0] = .{ .opcode_handler = undefined }; // Will be set by caller
    test_cursor_storage[1] = .{ .push_inline = .{ .value = inline_value } };
    test_cursor_storage[2] = .{ .opcode_handler = &stopHandler };
    
    return &test_cursor_storage;
}

fn createTestCursorPointer(value: u256) [*]TestFrame.Dispatch.Item {
    test_value_storage = value;
    
    test_cursor_storage[0] = .{ .opcode_handler = undefined }; // Will be set by caller
    test_cursor_storage[1] = .{ .push_pointer = .{ .value = &test_value_storage } };
    test_cursor_storage[2] = .{ .opcode_handler = &stopHandler };
    
    return &test_cursor_storage;
}

test "PUSH_ADD_INLINE - basic addition" {
    var frame = try createTestFrame(testing.allocator);
    defer destroyTestFrame(&frame, testing.allocator);

    // Stack: [10], then PUSH 5 + ADD = 15
    try frame.stack.push(10);

    const cursor = createTestCursorInline(5);
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_add_inline;
    
    const result = TestFrame.ArithmeticSyntheticHandlers.push_add_inline(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);

    try testing.expectEqual(@as(u256, 15), try frame.stack.pop());
}

test "PUSH_ADD_POINTER - large value addition" {
    var frame = try createTestFrame(testing.allocator);
    defer destroyTestFrame(&frame, testing.allocator);

    const large_value = std.math.maxInt(u256) - 100;
    try frame.stack.push(50);

    const cursor = createTestCursorPointer(large_value);
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_add_pointer;
    
    const result = TestFrame.ArithmeticSyntheticHandlers.push_add_pointer(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);

    // Should wrap around
    try testing.expectEqual(@as(u256, std.math.maxInt(u256) - 50), try frame.stack.pop());
}

test "PUSH_MUL_INLINE - multiplication" {
    var frame = try createTestFrame(testing.allocator);
    defer destroyTestFrame(&frame, testing.allocator);

    try frame.stack.push(7);

    const cursor = createTestCursorInline(6);
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_mul_inline;
    
    const result = TestFrame.ArithmeticSyntheticHandlers.push_mul_inline(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);

    try testing.expectEqual(@as(u256, 42), try frame.stack.pop());
}

test "PUSH_DIV_INLINE - division" {
    var frame = try createTestFrame(testing.allocator);
    defer destroyTestFrame(&frame, testing.allocator);

    try frame.stack.push(100);

    const cursor = createTestCursorInline(4);
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_div_inline;
    
    const result = TestFrame.ArithmeticSyntheticHandlers.push_div_inline(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);

    try testing.expectEqual(@as(u256, 25), try frame.stack.pop());
}

test "PUSH_DIV_INLINE - division by zero" {
    var frame = try createTestFrame(testing.allocator);
    defer destroyTestFrame(&frame, testing.allocator);

    try frame.stack.push(42);

    const cursor = createTestCursorInline(0);
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_div_inline;
    
    const result = TestFrame.ArithmeticSyntheticHandlers.push_div_inline(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);

    // EVM spec: division by zero returns 0
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "PUSH_SUB_INLINE - subtraction" {
    var frame = try createTestFrame(testing.allocator);
    defer destroyTestFrame(&frame, testing.allocator);

    try frame.stack.push(100);

    const cursor = createTestCursorInline(30);
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_sub_inline;
    
    const result = TestFrame.ArithmeticSyntheticHandlers.push_sub_inline(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);

    try testing.expectEqual(@as(u256, 70), try frame.stack.pop());
}

test "PUSH_SUB_INLINE - underflow" {
    var frame = try createTestFrame(testing.allocator);
    defer destroyTestFrame(&frame, testing.allocator);

    try frame.stack.push(10);

    const cursor = createTestCursorInline(20);
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_sub_inline;
    
    const result = TestFrame.ArithmeticSyntheticHandlers.push_sub_inline(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);

    // Should wrap around
    try testing.expectEqual(std.math.maxInt(u256) - 9, try frame.stack.pop());
}

test "synthetic arithmetic - all pointer variants" {
    var frame = try createTestFrame(testing.allocator);
    defer destroyTestFrame(&frame, testing.allocator);

    // Test PUSH_MUL_POINTER
    const mul_value: u256 = 1000;
    try frame.stack.push(5);
    var cursor = createTestCursorPointer(mul_value);
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_mul_pointer;
    var result = TestFrame.ArithmeticSyntheticHandlers.push_mul_pointer(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);
    try testing.expectEqual(@as(u256, 5000), try frame.stack.pop());

    // Test PUSH_DIV_POINTER
    const div_value: u256 = 8;
    try frame.stack.push(64);
    cursor = createTestCursorPointer(div_value);
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_div_pointer;
    result = TestFrame.ArithmeticSyntheticHandlers.push_div_pointer(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);
    try testing.expectEqual(@as(u256, 8), try frame.stack.pop());

    // Test PUSH_SUB_POINTER
    const sub_value: u256 = 150;
    try frame.stack.push(200);
    cursor = createTestCursorPointer(sub_value);
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_sub_pointer;
    result = TestFrame.ArithmeticSyntheticHandlers.push_sub_pointer(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);
    try testing.expectEqual(@as(u256, 50), try frame.stack.pop());
}

test "PUSH_ADD_INLINE - overflow wrapping" {
    var frame = try createTestFrame(testing.allocator);
    defer destroyTestFrame(&frame, testing.allocator);

    // Test: MAX + 1 = 0 (wraps around)
    const max = std.math.maxInt(u256);
    try frame.stack.push(max);

    const cursor = createTestCursorInline(1);
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_add_inline;
    
    const result = TestFrame.ArithmeticSyntheticHandlers.push_add_inline(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "PUSH_MUL_INLINE - overflow wrapping" {
    var frame = try createTestFrame(testing.allocator);
    defer destroyTestFrame(&frame, testing.allocator);

    // Test: MAX * 2 = MAX - 1 (overflow wraps)
    const max = std.math.maxInt(u256);
    try frame.stack.push(max);

    const cursor = createTestCursorInline(2);
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_mul_inline;
    
    const result = TestFrame.ArithmeticSyntheticHandlers.push_mul_inline(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);

    try testing.expectEqual(max - 1, try frame.stack.pop());
}

test "PUSH_SUB_POINTER - underflow wrapping" {
    var frame = try createTestFrame(testing.allocator);
    defer destroyTestFrame(&frame, testing.allocator);

    // Test: 5 - 10 = MAX - 4 (underflow wraps)
    const sub_value: u256 = 10;
    try frame.stack.push(5);

    const cursor = createTestCursorPointer(sub_value);
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_sub_pointer;
    
    const result = TestFrame.ArithmeticSyntheticHandlers.push_sub_pointer(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);

    try testing.expectEqual(std.math.maxInt(u256) - 4, try frame.stack.pop());
}

test "PUSH_DIV_POINTER - division by zero" {
    var frame = try createTestFrame(testing.allocator);
    defer destroyTestFrame(&frame, testing.allocator);

    // Test: 42 / 0 = 0 (EVM specification)
    const zero_value: u256 = 0;
    try frame.stack.push(42);

    const cursor = createTestCursorPointer(zero_value);
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_div_pointer;
    
    const result = TestFrame.ArithmeticSyntheticHandlers.push_div_pointer(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "PUSH_MUL_POINTER - large value multiplication" {
    var frame = try createTestFrame(testing.allocator);
    defer destroyTestFrame(&frame, testing.allocator);

    // Test: (2^128) * (2^128) = 0 (overflow wraps)
    const large: u256 = @as(u256, 1) << 128;
    try frame.stack.push(large);

    const cursor = createTestCursorPointer(large);
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_mul_pointer;
    
    const result = TestFrame.ArithmeticSyntheticHandlers.push_mul_pointer(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "synthetic arithmetic - maximum value operations" {
    var frame = try createTestFrame(testing.allocator);
    defer destroyTestFrame(&frame, testing.allocator);

    const max = std.math.maxInt(u256);

    // Test PUSH_ADD with maximum values
    try frame.stack.push(max);
    var cursor = createTestCursorInline(@truncate(max));
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_add_inline;
    var result = TestFrame.ArithmeticSyntheticHandlers.push_add_inline(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);
    try testing.expectEqual(max - 1, try frame.stack.pop());

    // Test PUSH_SUB with maximum values
    try frame.stack.push(max);
    cursor = createTestCursorInline(@truncate(max));
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_sub_inline;
    result = TestFrame.ArithmeticSyntheticHandlers.push_sub_inline(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());

    // Test PUSH_DIV with maximum values
    try frame.stack.push(max);
    cursor = createTestCursorInline(@truncate(max));
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_div_inline;
    result = TestFrame.ArithmeticSyntheticHandlers.push_div_inline(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "synthetic arithmetic - zero operations" {
    var frame = try createTestFrame(testing.allocator);
    defer destroyTestFrame(&frame, testing.allocator);

    // Test all operations with zero
    try frame.stack.push(0);
    var cursor = createTestCursorInline(42);
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_add_inline;
    var result = TestFrame.ArithmeticSyntheticHandlers.push_add_inline(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);
    try testing.expectEqual(@as(u256, 42), try frame.stack.pop());

    try frame.stack.push(0);
    cursor = createTestCursorInline(42);
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_mul_inline;
    result = TestFrame.ArithmeticSyntheticHandlers.push_mul_inline(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());

    try frame.stack.push(0);
    cursor = createTestCursorInline(42);
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_sub_inline;
    result = TestFrame.ArithmeticSyntheticHandlers.push_sub_inline(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);
    try testing.expectEqual(std.math.maxInt(u256) - 41, try frame.stack.pop());

    try frame.stack.push(0);
    cursor = createTestCursorInline(42);
    cursor[0].opcode_handler = &TestFrame.ArithmeticSyntheticHandlers.push_div_inline;
    result = TestFrame.ArithmeticSyntheticHandlers.push_div_inline(&frame, cursor);
    try testing.expectError(TestFrame.Error.Stop, result);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}
