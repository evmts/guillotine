const std = @import("std");
const FrameConfig = @import("../frame/frame_config.zig").FrameConfig;
const log = @import("../log.zig");
const wide_arith = @import("../core/wide_arith.zig");
const verified_ops = @import("../core/verified_ops.zig");

/// Synthetic arithmetic opcode handlers for the EVM stack frame.
/// These handle fused PUSH+arithmetic operations for optimization.
pub fn Handlers(FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;

        const dispatch_next = @import("dispatch_next.zig");
        const handler_abi = @import("../preprocessor/handler_abi.zig");
        const N = handler_abi.Native(FrameType);
        const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");

        /// PUSH_ADD_INLINE - Fused PUSH+ADD with inline value (≤8 bytes).
        /// Basic-block entry validation guarantees stack.size() >= 1 (proven by BLOCK-SOUND).
        pub fn push_add_inline(
            self: *FrameType,
            cursor: [*]const Dispatch.Item,
            sp: [*]WordType,
            gas: FrameType.GasType,
            t0: u64,
            t1: u64,
            t2: u64,
            t3: u64,
        ) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            N.before(self, .PUSH_ADD_INLINE, cursor, s, gas);
            const op_data = dispatch_opcode_data.getOpData(.PUSH_ADD_INLINE, Dispatch, Dispatch.Item, cursor);
            s.set_top_unsafe(op_data.metadata.value +% s.peek_unsafe());
            return N.next(self, .PUSH_ADD_INLINE, cursor, s, gas);
        }

        /// PUSH_ADD_POINTER - Fused PUSH+ADD with pointer value (>8 bytes).
        /// Basic-block entry validation guarantees stack.size() >= 1 (proven by BLOCK-SOUND).
        pub fn push_add_pointer(
            self: *FrameType,
            cursor: [*]const Dispatch.Item,
            sp: [*]WordType,
            gas: FrameType.GasType,
            t0: u64,
            t1: u64,
            t2: u64,
            t3: u64,
        ) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            N.before(self, .PUSH_ADD_POINTER, cursor, s, gas);
            const op_data = dispatch_opcode_data.getOpData(.PUSH_ADD_POINTER, Dispatch, Dispatch.Item, cursor);
            const top = s.peek_unsafe();
            s.set_top_unsafe(op_data.metadata.value_ptr.* +% top);
            return N.next(self, .PUSH_ADD_POINTER, cursor, s, gas);
        }

        /// PUSH_MUL_INLINE - Fused PUSH+MUL with inline value (≤8 bytes).
        pub fn push_mul_inline(
            self: *FrameType,
            cursor: [*]const Dispatch.Item,
            sp: [*]WordType,
            gas: FrameType.GasType,
            t0: u64,
            t1: u64,
            t2: u64,
            t3: u64,
        ) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            N.before(self, .PUSH_MUL_INLINE, cursor, s, gas);

            const op_data = dispatch_opcode_data.getOpData(.PUSH_MUL_INLINE, Dispatch, Dispatch.Item, cursor);
            const top = s.peek_unsafe();
            s.set_top_unsafe(op_data.metadata.value *% top);

            return N.next(self, .PUSH_MUL_INLINE, cursor, s, gas);
        }

        /// PUSH_MUL_POINTER - Fused PUSH+MUL with pointer value (>8 bytes).
        pub fn push_mul_pointer(
            self: *FrameType,
            cursor: [*]const Dispatch.Item,
            sp: [*]WordType,
            gas: FrameType.GasType,
            t0: u64,
            t1: u64,
            t2: u64,
            t3: u64,
        ) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            N.before(self, .PUSH_MUL_POINTER, cursor, s, gas);

            const op_data = dispatch_opcode_data.getOpData(.PUSH_MUL_POINTER, Dispatch, Dispatch.Item, cursor);
            const top = s.peek_unsafe();
            s.set_top_unsafe(op_data.metadata.value_ptr.* *% top);

            return N.next(self, .PUSH_MUL_POINTER, cursor, s, gas);
        }

        /// PUSH_DIV_INLINE - Fused PUSH+DIV with inline value (≤8 bytes).
        ///
        /// The pushed dividend fits 64 bits, so a divisor of 2^64 or more gives 0 and
        /// every other divisor needs one hardware divide. Division by zero gives 0.
        pub fn push_div_inline(
            self: *FrameType,
            cursor: [*]const Dispatch.Item,
            sp: [*]WordType,
            gas: FrameType.GasType,
            t0: u64,
            t1: u64,
            t2: u64,
            t3: u64,
        ) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            N.before(self, .PUSH_DIV_INLINE, cursor, s, gas);
            const op_data = dispatch_opcode_data.getOpData(.PUSH_DIV_INLINE, Dispatch, Dispatch.Item, cursor);
            // PUSH puts its value on top and DIV computes `top / second`, so the pushed
            // value is the dividend and the item it replaces is the divisor.
            const dividend: u64 = op_data.metadata.value;
            const divisor = s.peek_unsafe();
            s.set_top_unsafe(verified_ops.pushDivU64(dividend, divisor));

            return N.next(self, .PUSH_DIV_INLINE, cursor, s, gas);
        }

        /// PUSH_DIV_POINTER - Fused PUSH+DIV with pointer value (>8 bytes).
        ///
        /// Operands that both fit 64 bits take one hardware divide inline. Everything
        /// else tail-calls `push_div_pointer_wide`, so this handler has no stack frame.
        pub fn push_div_pointer(
            self: *FrameType,
            cursor: [*]const Dispatch.Item,
            sp: [*]WordType,
            gas: FrameType.GasType,
            t0: u64,
            t1: u64,
            t2: u64,
            t3: u64,
        ) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            N.before(self, .PUSH_DIV_POINTER, cursor, s, gas);
            const op_data = dispatch_opcode_data.getOpData(.PUSH_DIV_POINTER, Dispatch, Dispatch.Item, cursor);
            const dividend = op_data.metadata.value_ptr.*;

            const divisor = s.peek_unsafe();
            if (!wide_arith.fitsU64(dividend | divisor)) {
                return @call(
                    handler_abi.tail_mod,
                    N.outlined(&push_div_pointer_wide),
                    .{ self, cursor, sp, gas, t0, t1, t2, t3 },
                );
            }

            s.set_top_unsafe(wide_arith.div64(@truncate(dividend), @truncate(divisor)));

            return N.next(self, .PUSH_DIV_POINTER, cursor, s, gas);
        }

        /// PUSH_DIV_POINTER for operands wider than 64 bits. Entered by tail call from
        /// `push_div_pointer`, after it has run the pre-instruction hooks.
        fn push_div_pointer_wide(
            self: *FrameType,
            cursor: [*]const Dispatch.Item,
            sp: [*]WordType,
            gas: FrameType.GasType,
            t0: u64,
            t1: u64,
            t2: u64,
            t3: u64,
        ) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            const op_data = dispatch_opcode_data.getOpData(.PUSH_DIV_POINTER, Dispatch, Dispatch.Item, cursor);
            const dividend = op_data.metadata.value_ptr.*;

            const divisor = s.peek_unsafe();
            s.set_top_unsafe(@intCast(wide_arith.div(dividend, divisor)));

            return N.next(self, .PUSH_DIV_POINTER, cursor, s, gas);
        }

        /// PUSH_SUB_INLINE - Fused PUSH+SUB with inline value (≤8 bytes).
        pub fn push_sub_inline(
            self: *FrameType,
            cursor: [*]const Dispatch.Item,
            sp: [*]WordType,
            gas: FrameType.GasType,
            t0: u64,
            t1: u64,
            t2: u64,
            t3: u64,
        ) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            N.before(self, .PUSH_SUB_INLINE, cursor, s, gas);
            const op_data = dispatch_opcode_data.getOpData(.PUSH_SUB_INLINE, Dispatch, Dispatch.Item, cursor);
            const push_value = op_data.metadata.value;
            const top = s.peek_unsafe();
            const result = push_value -% top;
            s.set_top_unsafe(result);
            return N.next(self, .PUSH_SUB_INLINE, cursor, s, gas);
        }

        /// PUSH_SUB_POINTER - Fused PUSH+SUB with pointer value (>8 bytes).
        pub fn push_sub_pointer(
            self: *FrameType,
            cursor: [*]const Dispatch.Item,
            sp: [*]WordType,
            gas: FrameType.GasType,
            t0: u64,
            t1: u64,
            t2: u64,
            t3: u64,
        ) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            N.before(self, .PUSH_SUB_POINTER, cursor, s, gas);
            const op_data = dispatch_opcode_data.getOpData(.PUSH_SUB_POINTER, Dispatch, Dispatch.Item, cursor);
            const top = s.peek_unsafe();
            const result = op_data.metadata.value_ptr.* -% top;
            s.set_top_unsafe(result);
            return N.next(self, .PUSH_SUB_POINTER, cursor, s, gas);
        }
    };
}

// ====== TESTS ======

const testing = std.testing;
const Frame = @import("../frame/frame.zig").Frame;
const dispatch_mod = @import("../preprocessor/dispatch.zig");
const DefaultTracer = @import("../tracer/tracer.zig").DefaultTracer;
const bytecode_mod = @import("../bytecode/bytecode.zig");

// Test configuration
const test_config = FrameConfig{
    .stack_size = 1024,
    .WordType = u256,
    .max_bytecode_size = 1024,
    .block_gas_limit = 30_000_000,
    .DatabaseType = @import("../storage/memory_database.zig").MemoryDatabase,
    .memory_initial_capacity = 4096,
    .memory_limit = 0xFFFFFF,
};

const TestFrame = Frame(test_config);
const TestBytecode = bytecode_mod.Bytecode(.{ .max_bytecode_size = test_config.max_bytecode_size });
const Address = @import("voltaire").Address.Address;
const MemoryDatabase = @import("../storage/memory_database.zig").MemoryDatabase;

fn createTestFrame(allocator: std.mem.Allocator) !TestFrame {
    const database = MemoryDatabase.init(allocator);
    const value = try allocator.create(u256);
    value.* = 0;
    var frame = try TestFrame.init(
        allocator,
        1_000_000,
        database,
        Address.ZERO_ADDRESS,
        value,
        &[_]u8{},
        @ptrFromInt(1),
    );
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
