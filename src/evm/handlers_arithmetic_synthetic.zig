const std = @import("std");
const FrameConfig = @import("frame_config.zig").FrameConfig;
const log = @import("log.zig");

/// Synthetic arithmetic opcode handlers for the EVM stack frame.
/// These handle fused PUSH+arithmetic operations for optimization.
pub fn Handlers(comptime FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;

        /// PUSH_ADD_INLINE - Fused PUSH+ADD with inline value (≤8 bytes).
        /// Pushes a value and immediately adds it to the top of stack.
        pub fn push_add_inline(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor, .jump_table = null };
            // Extract inline value from schedule metadata
            const metadata = dispatch.getInlineMetadata();
            const push_value = metadata.value;

            // Pop top value and add the pushed value
            const a = try self.stack.pop();
            const result = a +% push_value;
            try self.stack.push(result);

            // Continue to next operation (skip metadata)
            const next = dispatch.skipMetadata();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next.cursor });
        }

        /// PUSH_ADD_POINTER - Fused PUSH+ADD with pointer value (>8 bytes).
        pub fn push_add_pointer(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor, .jump_table = null };
            // Extract pointer value from schedule metadata
            const metadata = dispatch.getPointerMetadata();
            const push_value = metadata.value.*;

            // Pop top value and add the pushed value
            const a = try self.stack.pop();
            const result = a +% push_value;
            try self.stack.push(result);

            // Continue to next operation (skip metadata)
            const next = dispatch.skipMetadata();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next.cursor });
        }

        /// PUSH_MUL_INLINE - Fused PUSH+MUL with inline value (≤8 bytes).
        pub fn push_mul_inline(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor, .jump_table = null };
            const metadata = dispatch.getInlineMetadata();
            const push_value = metadata.value;

            const a = try self.stack.pop();
            const result = a *% push_value;
            try self.stack.push(result);

            const next = dispatch.skipMetadata();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next.cursor });
        }

        /// PUSH_MUL_POINTER - Fused PUSH+MUL with pointer value (>8 bytes).
        pub fn push_mul_pointer(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor, .jump_table = null };
            const metadata = dispatch.getPointerMetadata();
            const push_value = metadata.value.*;

            const a = try self.stack.pop();
            const result = a *% push_value;
            try self.stack.push(result);

            const next = dispatch.skipMetadata();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next.cursor });
        }

        /// PUSH_DIV_INLINE - Fused PUSH+DIV with inline value (≤8 bytes).
        pub fn push_div_inline(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor, .jump_table = null };
            const metadata = dispatch.getInlineMetadata();
            const divisor = metadata.value;

            const dividend = try self.stack.pop();
            const result = if (divisor == 0) 0 else dividend / divisor;
            try self.stack.push(result);

            const next = dispatch.skipMetadata();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next.cursor });
        }

        /// PUSH_DIV_POINTER - Fused PUSH+DIV with pointer value (>8 bytes).
        pub fn push_div_pointer(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor, .jump_table = null };
            const metadata = dispatch.getPointerMetadata();
            const divisor = metadata.value.*;

            const dividend = try self.stack.pop();
            const result = if (divisor == 0) 0 else dividend / divisor;
            try self.stack.push(result);

            const next = dispatch.skipMetadata();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next.cursor });
        }

        /// PUSH_SUB_INLINE - Fused PUSH+SUB with inline value (≤8 bytes).
        pub fn push_sub_inline(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor, .jump_table = null };
            const metadata = dispatch.getInlineMetadata();
            const push_value = metadata.value;

            const a = try self.stack.pop();
            const result = a -% push_value;
            try self.stack.push(result);

            const next = dispatch.skipMetadata();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next.cursor });
        }

        /// PUSH_SUB_POINTER - Fused PUSH+SUB with pointer value (>8 bytes).
        pub fn push_sub_pointer(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor, .jump_table = null };
            const metadata = dispatch.getPointerMetadata();
            const push_value = metadata.value.*;

            const a = try self.stack.pop();
            const result = a -% push_value;
            try self.stack.push(result);

            const next = dispatch.skipMetadata();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next.cursor });
        }
    };
}

// ====== TESTS ======

const testing = std.testing;
const Frame = @import("frame.zig").Frame;
const dispatch_mod = @import("dispatch.zig");
const NoOpTracer = @import("tracer.zig").NoOpTracer;
const bytecode_mod = @import("bytecode.zig");

// Test configuration
const test_config = FrameConfig{
    .stack_size = 1024,
    .WordType = u256,
    .max_bytecode_size = 1024,
    .block_gas_limit = 30_000_000,
    .has_database = false,
    .TracerType = NoOpTracer,
    .memory_initial_capacity = 4096,
    .memory_limit = 0xFFFFFF,
};

const TestFrame = Frame(test_config);
const TestBytecode = bytecode_mod.Bytecode(.{ .max_bytecode_size = test_config.max_bytecode_size });

fn createTestFrame(allocator: std.mem.Allocator) !TestFrame {
    const bytecode = TestBytecode.initEmpty();
    return try TestFrame.init(allocator, bytecode, 1_000_000, null, null);
}

// Helper to create dispatch with inline metadata
fn createInlineDispatch(value: u256) TestFrame.Dispatch {
    const mock_handler = struct {
        fn handler(frame: TestFrame, dispatch: TestFrame.Dispatch) TestFrame.Error!TestFrame.Success {
            _ = frame;
            _ = dispatch;
            return TestFrame.Success.stop;
        }
    }.handler;

    var cursor: [2]dispatch_mod.ScheduleElement(TestFrame) = undefined;
    cursor[0] = .{ .opcode_handler = &mock_handler };
    cursor[1] = .{ .opcode_handler = &mock_handler };

    cursor[0].metadata = .{ .inline_value = value };

    return TestFrame.Dispatch{
        .cursor = &cursor,
        .bytecode_length = 0,
    };
}

// Helper to create dispatch with pointer metadata
fn createPointerDispatch(value: *const u256) TestFrame.Dispatch {
    const mock_handler = struct {
        fn handler(frame: TestFrame, dispatch: TestFrame.Dispatch) TestFrame.Error!TestFrame.Success {
            _ = frame;
            _ = dispatch;
            return TestFrame.Success.stop;
        }
    }.handler;

    var cursor: [2]dispatch_mod.ScheduleElement(TestFrame) = undefined;
    cursor[0] = .{ .opcode_handler = &mock_handler };
    cursor[1] = .{ .opcode_handler = &mock_handler };

    cursor[0].metadata = .{ .pointer_value = value };

    return TestFrame.Dispatch{
        .cursor = &cursor,
        .bytecode_length = 0,
    };
}

test "PUSH_ADD_INLINE - basic addition" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Stack: [10], then PUSH 5 + ADD = 15
    try frame.stack.push(10);

    const dispatch = createInlineDispatch(5);
    _ = try TestFrame.ArithmeticSyntheticHandlers.push_add_inline(frame, dispatch);

    try testing.expectEqual(@as(u256, 15), try frame.stack.pop());
}

test "PUSH_ADD_POINTER - large value addition" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    const large_value = std.math.maxInt(u256) - 100;
    try frame.stack.push(50);

    const dispatch = createPointerDispatch(&large_value);
    _ = try TestFrame.ArithmeticSyntheticHandlers.push_add_pointer(frame, dispatch);

    // Should wrap around
    try testing.expectEqual(@as(u256, std.math.maxInt(u256) - 50), try frame.stack.pop());
}

test "PUSH_MUL_INLINE - multiplication" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    try frame.stack.push(7);

    const dispatch = createInlineDispatch(6);
    _ = try TestFrame.ArithmeticSyntheticHandlers.push_mul_inline(frame, dispatch);

    try testing.expectEqual(@as(u256, 42), try frame.stack.pop());
}

test "PUSH_DIV_INLINE - division" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    try frame.stack.push(100);

    const dispatch = createInlineDispatch(4);
    _ = try TestFrame.ArithmeticSyntheticHandlers.push_div_inline(frame, dispatch);

    try testing.expectEqual(@as(u256, 25), try frame.stack.pop());
}

test "PUSH_DIV_INLINE - division by zero" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    try frame.stack.push(42);

    const dispatch = createInlineDispatch(0);
    _ = try TestFrame.ArithmeticSyntheticHandlers.push_div_inline(frame, dispatch);

    // EVM spec: division by zero returns 0
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "PUSH_SUB_INLINE - subtraction" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    try frame.stack.push(100);

    const dispatch = createInlineDispatch(30);
    _ = try TestFrame.ArithmeticSyntheticHandlers.push_sub_inline(frame, dispatch);

    try testing.expectEqual(@as(u256, 70), try frame.stack.pop());
}

test "PUSH_SUB_INLINE - underflow" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    try frame.stack.push(10);

    const dispatch = createInlineDispatch(20);
    _ = try TestFrame.ArithmeticSyntheticHandlers.push_sub_inline(frame, dispatch);

    // Should wrap around
    try testing.expectEqual(std.math.maxInt(u256) - 9, try frame.stack.pop());
}

test "synthetic arithmetic - all pointer variants" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test PUSH_MUL_POINTER
    const mul_value: u256 = 1000;
    try frame.stack.push(5);
    var dispatch = createPointerDispatch(&mul_value);
    _ = try TestFrame.ArithmeticSyntheticHandlers.push_mul_pointer(frame, dispatch);
    try testing.expectEqual(@as(u256, 5000), try frame.stack.pop());

    // Test PUSH_DIV_POINTER
    const div_value: u256 = 8;
    try frame.stack.push(64);
    dispatch = createPointerDispatch(&div_value);
    _ = try TestFrame.ArithmeticSyntheticHandlers.push_div_pointer(frame, dispatch);
    try testing.expectEqual(@as(u256, 8), try frame.stack.pop());

    // Test PUSH_SUB_POINTER
    const sub_value: u256 = 150;
    try frame.stack.push(200);
    dispatch = createPointerDispatch(&sub_value);
    _ = try TestFrame.ArithmeticSyntheticHandlers.push_sub_pointer(frame, dispatch);
    try testing.expectEqual(@as(u256, 50), try frame.stack.pop());
}
