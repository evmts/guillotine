const std = @import("std");
const FrameConfig = @import("frame_config.zig").FrameConfig;
const log = @import("log.zig");

/// Synthetic bitwise opcode handlers for the EVM stack frame.
/// These handle fused PUSH+bitwise operations for optimization.
pub fn Handlers(comptime FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;

        /// PUSH_AND_INLINE - Fused PUSH+AND with inline value (≤8 bytes).
        pub fn push_and_inline(self: *FrameType, dispatch: Dispatch) Error!noreturn {
            const metadata = dispatch.getInlineMetadata();
            const push_value = metadata.value;

            const a = try self.stack.pop();
            const result = a & push_value;
            try self.stack.push(result);

            const next = dispatch.skipMetadata();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next });
        }

        /// PUSH_AND_POINTER - Fused PUSH+AND with pointer value (>8 bytes).
        pub fn push_and_pointer(self: *FrameType, dispatch: Dispatch) Error!noreturn {
            const metadata = dispatch.getPointerMetadata();
            const push_value = metadata.value.*;

            const a = try self.stack.pop();
            const result = a & push_value;
            try self.stack.push(result);

            const next = dispatch.skipMetadata();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next });
        }

        /// PUSH_OR_INLINE - Fused PUSH+OR with inline value (≤8 bytes).
        pub fn push_or_inline(self: *FrameType, dispatch: Dispatch) Error!noreturn {
            const metadata = dispatch.getInlineMetadata();
            const push_value = metadata.value;

            const a = try self.stack.pop();
            const result = a | push_value;
            try self.stack.push(result);

            const next = dispatch.skipMetadata();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next });
        }

        /// PUSH_OR_POINTER - Fused PUSH+OR with pointer value (>8 bytes).
        pub fn push_or_pointer(self: *FrameType, dispatch: Dispatch) Error!noreturn {
            const metadata = dispatch.getPointerMetadata();
            const push_value = metadata.value.*;

            const a = try self.stack.pop();
            const result = a | push_value;
            try self.stack.push(result);

            const next = dispatch.skipMetadata();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next });
        }

        /// PUSH_XOR_INLINE - Fused PUSH+XOR with inline value (≤8 bytes).
        pub fn push_xor_inline(self: *FrameType, dispatch: Dispatch) Error!noreturn {
            const metadata = dispatch.getInlineMetadata();
            const push_value = metadata.value;

            const a = try self.stack.pop();
            const result = a ^ push_value;
            try self.stack.push(result);

            const next = dispatch.skipMetadata();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next });
        }

        /// PUSH_XOR_POINTER - Fused PUSH+XOR with pointer value (>8 bytes).
        pub fn push_xor_pointer(self: *FrameType, dispatch: Dispatch) Error!noreturn {
            const metadata = dispatch.getPointerMetadata();
            const push_value = metadata.value.*;

            const a = try self.stack.pop();
            const result = a ^ push_value;
            try self.stack.push(result);

            const next = dispatch.skipMetadata();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next });
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

test "PUSH_AND_INLINE - basic AND operation" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Stack: [0xFF], then PUSH 0xF0 & AND = 0xF0
    try frame.stack.push(0xFF);

    const dispatch = createInlineDispatch(0xF0);
    _ = try TestFrame.BitwiseSyntheticHandlers.push_and_inline(frame, dispatch);

    try testing.expectEqual(@as(u256, 0xF0), try frame.stack.pop());
}

test "PUSH_AND_POINTER - large value AND" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    const mask = @as(u256, 0xFFFFFFFFFFFFFFFF) << 192; // High 64 bits set
    try frame.stack.push(std.math.maxInt(u256));

    const dispatch = createPointerDispatch(&mask);
    _ = try TestFrame.BitwiseSyntheticHandlers.push_and_pointer(frame, dispatch);

    try testing.expectEqual(mask, try frame.stack.pop());
}

test "PUSH_OR_INLINE - basic OR operation" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Stack: [0xF0], then PUSH 0x0F | OR = 0xFF
    try frame.stack.push(0xF0);

    const dispatch = createInlineDispatch(0x0F);
    _ = try TestFrame.BitwiseSyntheticHandlers.push_or_inline(frame, dispatch);

    try testing.expectEqual(@as(u256, 0xFF), try frame.stack.pop());
}

test "PUSH_XOR_INLINE - basic XOR operation" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Stack: [0xFF], then PUSH 0xAA ^ XOR = 0x55
    try frame.stack.push(0xFF);

    const dispatch = createInlineDispatch(0xAA);
    _ = try TestFrame.BitwiseSyntheticHandlers.push_xor_inline(frame, dispatch);

    try testing.expectEqual(@as(u256, 0x55), try frame.stack.pop());
}

test "synthetic bitwise - all operations" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test masking with AND
    try frame.stack.push(0xDEADBEEF);
    var dispatch = createInlineDispatch(0xFFFF0000);
    _ = try TestFrame.BitwiseSyntheticHandlers.push_and_inline(frame, dispatch);
    try testing.expectEqual(@as(u256, 0xDEAD0000), try frame.stack.pop());

    // Test setting bits with OR
    try frame.stack.push(0x1000);
    dispatch = createInlineDispatch(0x0111);
    _ = try TestFrame.BitwiseSyntheticHandlers.push_or_inline(frame, dispatch);
    try testing.expectEqual(@as(u256, 0x1111), try frame.stack.pop());

    // Test toggling with XOR
    try frame.stack.push(0b1010);
    dispatch = createInlineDispatch(0b1100);
    _ = try TestFrame.BitwiseSyntheticHandlers.push_xor_inline(frame, dispatch);
    try testing.expectEqual(@as(u256, 0b0110), try frame.stack.pop());
}

test "synthetic bitwise - pointer variants" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test PUSH_OR_POINTER
    const or_value = @as(u256, 1) << 255; // Set highest bit
    try frame.stack.push(42);
    var dispatch = createPointerDispatch(&or_value);
    _ = try TestFrame.BitwiseSyntheticHandlers.push_or_pointer(frame, dispatch);
    try testing.expectEqual(42 | or_value, try frame.stack.pop());

    // Test PUSH_XOR_POINTER
    const xor_value = std.math.maxInt(u256); // All bits set
    try frame.stack.push(0x123456789ABCDEF0);
    dispatch = createPointerDispatch(&xor_value);
    _ = try TestFrame.BitwiseSyntheticHandlers.push_xor_pointer(frame, dispatch);
    try testing.expectEqual(~@as(u256, 0x123456789ABCDEF0), try frame.stack.pop());
}
