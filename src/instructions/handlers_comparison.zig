const std = @import("std");
const FrameConfig = @import("../frame/frame_config.zig").FrameConfig;
const log = @import("../log.zig");

/// Comparison opcode handlers for the EVM stack frame.
/// These are generic structs that return static handlers for a given FrameType.
pub fn Handlers(comptime FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;

        /// LT opcode (0x10) - Less than comparison.
        pub fn lt(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            std.debug.assert(self.stack.size() >= 2); // LT requires 2 stack items
            const a = self.stack.pop_unsafe(); // Top of stack (second pushed value)
            const b = self.stack.peek_unsafe(); // Second from top (first pushed value)
            // EVM: pops a (top), then b; pushes (a < b)
            const result: WordType = @intFromBool(a < b);
            self.stack.set_top_unsafe(result);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }

        /// GT opcode (0x11) - Greater than comparison.
        pub fn gt(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            std.debug.assert(self.stack.size() >= 2); // GT requires 2 stack items
            const a = self.stack.pop_unsafe(); // Top of stack (second pushed value)
            const b = self.stack.peek_unsafe(); // Second from top (first pushed value)
            // EVM: pops a (top), then b; pushes (a > b)
            const result: WordType = @intFromBool(a > b);
            self.stack.set_top_unsafe(result);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }

        /// SLT opcode (0x12) - Signed less than comparison.
        pub fn slt(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            std.debug.assert(self.stack.size() >= 2); // SLT requires 2 stack items
            const a = self.stack.pop_unsafe(); // Top of stack (second pushed value)
            const b = self.stack.peek_unsafe(); // Second from top (first pushed value)
            const a_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(a));
            const b_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(b));
            // EVM: pops a (top), then b; pushes (a < b) with signed comparison
            const result: WordType = @intFromBool(a_signed < b_signed);
            self.stack.set_top_unsafe(result);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }

        /// SGT opcode (0x13) - Signed greater than comparison.
        pub fn sgt(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            std.debug.assert(self.stack.size() >= 2); // SGT requires 2 stack items
            const a = self.stack.pop_unsafe(); // Top of stack (second pushed value)
            const b = self.stack.peek_unsafe(); // Second from top (first pushed value)
            const a_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(a));
            const b_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(b));
            // EVM: pops a (top), then b; pushes (a > b) with signed comparison
            const result: WordType = @intFromBool(a_signed > b_signed);
            self.stack.set_top_unsafe(result);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }

        /// EQ opcode (0x14) - Equality comparison.
        pub fn eq(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            std.debug.assert(self.stack.size() >= 2); // EQ requires 2 stack items
            const b = self.stack.pop_unsafe(); // Top of stack - second operand
            const a = self.stack.peek_unsafe(); // Second from top - first operand
            // EVM: pops b, then a, and pushes (a == b)
            const result: WordType = @intFromBool(a == b);
            self.stack.set_top_unsafe(result);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }

        /// ISZERO opcode (0x15) - Check if value is zero.
        pub fn iszero(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            std.debug.assert(self.stack.size() >= 1); // ISZERO requires 1 stack item
            const value = self.stack.peek_unsafe();
            const result: WordType = @intFromBool(value == 0);
            self.stack.set_top_unsafe(result);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }
    };
}

// ====== TESTS ======

const testing = std.testing;
const Frame = @import("../frame/frame.zig").Frame;
const dispatch_mod = @import("../preprocessor/dispatch.zig");
const NoOpTracer = @import("../tracer/tracer.zig").NoOpTracer;
const MemoryDatabase = @import("../storage/memory_database.zig").MemoryDatabase;
const Address = @import("primitives").Address;

// Test configuration
const test_config = FrameConfig{
    .stack_size = 1024,
    .WordType = u256,
    .max_bytecode_size = 1024,
    .block_gas_limit = 30_000_000,
    .DatabaseType = MemoryDatabase,
    .memory_initial_capacity = 4096,
    .memory_limit = 0xFFFFFF,
};

const TestFrame = Frame(test_config);

fn createTestFrame(allocator: std.mem.Allocator) !TestFrame {
    const database = MemoryDatabase.init(allocator);
    const value = try allocator.create(u256);
    value.* = 0;
    const evm_ptr = @as(*anyopaque, @ptrFromInt(0x1000));
    var frame = try TestFrame.init(allocator, 1_000_000, database, Address.ZERO_ADDRESS, value, &[_]u8{}, evm_ptr);
    frame.code = &[_]u8{};
    return frame;
}

// Mock dispatch that simulates successful execution flow
fn createMockDispatch() TestFrame.Dispatch {
    const mock_handler = struct {
        fn handler(frame: TestFrame, dispatch: TestFrame.Dispatch) TestFrame.Error!TestFrame.Success {
            _ = frame;
            _ = dispatch;
            return TestFrame.Success.stop;
        }
    }.handler;

    var cursor: [1]dispatch_mod.ScheduleElement(TestFrame) = undefined;
    cursor[0] = .{ .opcode_handler = &mock_handler };

    return TestFrame.Dispatch{
        .cursor = &cursor,
        .bytecode_length = 0,
    };
}

test "LT opcode - less than comparison" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 5 < 10 = 1 (true)
    try frame.stack.push(5);
    try frame.stack.push(10);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.lt(frame, dispatch);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "LT opcode - not less than" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 10 < 5 = 0 (false)
    try frame.stack.push(10);
    try frame.stack.push(5);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.lt(frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "LT opcode - equal values" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 5 < 5 = 0 (false)
    try frame.stack.push(5);
    try frame.stack.push(5);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.lt(frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "GT opcode - greater than comparison" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 10 > 5 = 1 (true)
    try frame.stack.push(10);
    try frame.stack.push(5);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.gt(frame, dispatch);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "GT opcode - not greater than" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 5 > 10 = 0 (false)
    try frame.stack.push(5);
    try frame.stack.push(10);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.gt(frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "SLT opcode - signed less than positive" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 5 < 10 = 1 (true)
    try frame.stack.push(5);
    try frame.stack.push(10);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.slt(frame, dispatch);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "SLT opcode - signed less than negative" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: -5 < 5 = 1 (true)
    // -5 in two's complement
    const neg_5 = std.math.maxInt(u256) - 4;
    try frame.stack.push(neg_5);
    try frame.stack.push(5);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.slt(frame, dispatch);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "SLT opcode - signed comparison with max values" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: MAX_SIGNED < MIN_SIGNED = 0 (false)
    // MAX_SIGNED = 0x7FFF...FFF
    // MIN_SIGNED = 0x8000...000
    const max_signed = std.math.shl(u256, @as(u256, 1), 255) - 1;
    const min_signed = std.math.shl(u256, @as(u256, 1), 255);

    try frame.stack.push(max_signed);
    try frame.stack.push(min_signed);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.slt(frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "SGT opcode - signed greater than positive" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 10 > 5 = 1 (true)
    try frame.stack.push(10);
    try frame.stack.push(5);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.sgt(frame, dispatch);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "SGT opcode - signed greater than negative" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 5 > -5 = 1 (true)
    const neg_5 = std.math.maxInt(u256) - 4;
    try frame.stack.push(5);
    try frame.stack.push(neg_5);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.sgt(frame, dispatch);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "SGT opcode - two negative numbers" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: -5 > -10 = 1 (true)
    const neg_5 = std.math.maxInt(u256) - 4;
    const neg_10 = std.math.maxInt(u256) - 9;

    try frame.stack.push(neg_5);
    try frame.stack.push(neg_10);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.sgt(frame, dispatch);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "EQ opcode - equal values" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 42 == 42 = 1 (true)
    try frame.stack.push(42);
    try frame.stack.push(42);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.eq(frame, dispatch);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "EQ opcode - not equal values" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 42 == 43 = 0 (false)
    try frame.stack.push(42);
    try frame.stack.push(43);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.eq(frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "EQ opcode - max value comparison" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: MAX == MAX = 1 (true)
    const max = std.math.maxInt(u256);
    try frame.stack.push(max);
    try frame.stack.push(max);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.eq(frame, dispatch);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "ISZERO opcode - zero value" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: is 0 zero? = 1 (true)
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.iszero(frame, dispatch);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "ISZERO opcode - non-zero value" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: is 42 zero? = 0 (false)
    try frame.stack.push(42);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.iszero(frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "ISZERO opcode - max value" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: is MAX_U256 zero? = 0 (false)
    const max = std.math.maxInt(u256);
    try frame.stack.push(max);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.iszero(frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// Edge case tests
test "comparison opcodes - boundary values" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test LT: 0 < 1 = 1
    try frame.stack.push(0);
    try frame.stack.push(1);
    var dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.lt(frame, dispatch);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());

    // Test GT: MAX > MAX-1 = 1
    const max = std.math.maxInt(u256);
    try frame.stack.push(max);
    try frame.stack.push(max - 1);
    dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.gt(frame, dispatch);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

// Additional comprehensive tests

test "LT opcode - max values" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: MAX-1 < MAX = 1
    const max = std.math.maxInt(u256);
    try frame.stack.push(max - 1);
    try frame.stack.push(max);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.lt(frame, dispatch);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "GT opcode - zero comparison" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 1 > 0 = 1
    try frame.stack.push(1);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.gt(frame, dispatch);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "GT opcode - equal values" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 42 > 42 = 0
    try frame.stack.push(42);
    try frame.stack.push(42);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.gt(frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "SLT opcode - mixed signs" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 5 < -5 = 0 (false, positive is greater than negative)
    const neg_5 = std.math.maxInt(u256) - 4;
    try frame.stack.push(5);
    try frame.stack.push(neg_5);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.slt(frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "SLT opcode - zero comparisons" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 0 < -1 = 0 (false, 0 is greater than -1)
    const neg_1 = std.math.maxInt(u256);
    try frame.stack.push(0);
    try frame.stack.push(neg_1);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.slt(frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "SLT opcode - edge case MIN and MAX" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: MIN_SIGNED < MAX_SIGNED = 1 (true)
    const min_signed = std.math.shl(u256, @as(u256, 1), 255);
    const max_signed = std.math.shl(u256, @as(u256, 1), 255) - 1;

    try frame.stack.push(min_signed);
    try frame.stack.push(max_signed);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.slt(frame, dispatch);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "SGT opcode - zero comparison" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: -1 > 0 = 0 (false)
    const neg_1 = std.math.maxInt(u256);
    try frame.stack.push(neg_1);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.sgt(frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "SGT opcode - equal negative values" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: -42 > -42 = 0
    const neg_42 = std.math.maxInt(u256) - 41;
    try frame.stack.push(neg_42);
    try frame.stack.push(neg_42);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.sgt(frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "EQ opcode - zero comparison" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 0 == 0 = 1
    try frame.stack.push(0);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.eq(frame, dispatch);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "EQ opcode - one off comparison" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 1000000 == 1000001 = 0
    try frame.stack.push(1000000);
    try frame.stack.push(1000001);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.eq(frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "ISZERO opcode - one value" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: is 1 zero? = 0
    try frame.stack.push(1);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.iszero(frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "ISZERO opcode - large value" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: is 2^200 zero? = 0
    const large = std.math.shl(u256, @as(u256, 1), 200);
    try frame.stack.push(large);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.iszero(frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// Cross-validation tests
test "comparison consistency - LT and GT" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // If a < b, then b > a
    // Test: 5 < 10 = 1
    try frame.stack.push(5);
    try frame.stack.push(10);
    var dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.lt(frame, dispatch);
    const lt_result = try frame.stack.pop();

    // Test: 10 > 5 = 1
    try frame.stack.push(10);
    try frame.stack.push(5);
    dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.gt(frame, dispatch);
    const gt_result = try frame.stack.pop();

    try testing.expectEqual(lt_result, gt_result);
}

test "comparison consistency - signed operations" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test SLT and SGT consistency
    const neg_10 = std.math.maxInt(u256) - 9;
    const neg_5 = std.math.maxInt(u256) - 4;

    // Test: -10 < -5 = 1
    try frame.stack.push(neg_10);
    try frame.stack.push(neg_5);
    var dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.slt(frame, dispatch);
    const slt_result = try frame.stack.pop();

    // Test: -5 > -10 = 1
    try frame.stack.push(neg_5);
    try frame.stack.push(neg_10);
    dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.sgt(frame, dispatch);
    const sgt_result = try frame.stack.pop();

    try testing.expectEqual(slt_result, sgt_result);
    try testing.expectEqual(@as(u256, 1), slt_result);
}

test "EQ and ISZERO relationship" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: (x == 0) should be same as ISZERO(x)
    try frame.stack.push(0);
    try frame.stack.push(0);
    var dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.eq(frame, dispatch);
    const eq_result = try frame.stack.pop();

    try frame.stack.push(0);
    dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.iszero(frame, dispatch);
    const iszero_result = try frame.stack.pop();

    try testing.expectEqual(eq_result, iszero_result);
    try testing.expectEqual(@as(u256, 1), eq_result);
}

test "LT and GT with extreme values" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    const max = std.math.maxInt(u256);

    // Test: 0 < MAX = 1
    try frame.stack.push(0);
    try frame.stack.push(max);
    var dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.lt(frame, dispatch);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());

    // Test: MAX > 0 = 1
    try frame.stack.push(max);
    try frame.stack.push(0);
    dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.gt(frame, dispatch);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "signed comparisons - boundary edge cases" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    const min_signed = std.math.shl(u256, @as(u256, 1), 255);
    const max_signed = std.math.shl(u256, @as(u256, 1), 255) - 1;

    // Test: MIN_SIGNED < 0 = 1 (most negative is less than 0)
    try frame.stack.push(min_signed);
    try frame.stack.push(0);
    var dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.slt(frame, dispatch);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());

    // Test: 0 > MIN_SIGNED = 1
    try frame.stack.push(0);
    try frame.stack.push(min_signed);
    dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.sgt(frame, dispatch);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());

    // Test: MAX_SIGNED > 0 = 1
    try frame.stack.push(max_signed);
    try frame.stack.push(0);
    dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.sgt(frame, dispatch);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "EQ opcode - negative values" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: -1 == -1 = 1
    const neg_1 = std.math.maxInt(u256);
    try frame.stack.push(neg_1);
    try frame.stack.push(neg_1);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ComparisonHandlers.eq(frame, dispatch);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}
