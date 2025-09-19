const std = @import("std");
const FrameConfig = @import("../frame/frame_config.zig").FrameConfig;
const log = @import("../log.zig");
const memory_mod = @import("../memory/memory.zig");
const GasConstants = @import("primitives").GasConstants;
const OpcodeSynthetic = @import("../opcodes/opcode_synthetic.zig").OpcodeSynthetic;

/// Synthetic memory opcode handlers for the EVM stack frame.
/// These handle fused PUSH+memory operations for optimization.
pub fn Handlers(comptime FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;

        /// PUSH_MLOAD_INLINE - Fused PUSH+MLOAD with inline offset (≤8 bytes).
        /// Pushes an offset and immediately loads from that memory location.
        /// Gas costs are pre-calculated statically in dispatch.
        pub fn push_mload_inline(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.PUSH_MLOAD_INLINE, cursor);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.PUSH_MLOAD_INLINE, Dispatch, Dispatch.Item, cursor);

            // Cursor now points to metadata
            const offset = op_data.metadata.value;

            // Check if offset fits in usize
            if (offset > std.math.maxInt(usize)) {
                @branchHint(.unlikely);
                self.afterComplete(.PUSH_MLOAD_INLINE);
                return Error.OutOfBounds;
            }
            const offset_usize = @as(usize, @intCast(offset));

            // Gas costs are handled statically by dispatch - no dynamic calculation needed

            // Read 32 bytes from memory
            const value_u256 = self.memory.get_u256_evm(self.getAllocator(), @as(u24, @intCast(offset_usize))) catch |err| switch (err) {
                memory_mod.MemoryError.OutOfBounds => {
                    self.afterComplete(.PUSH_MLOAD_INLINE);
                    return Error.OutOfBounds;
                },
                memory_mod.MemoryError.MemoryOverflow => {
                    self.afterComplete(.PUSH_MLOAD_INLINE);
                    return Error.OutOfBounds;
                },
                else => {
                    self.afterComplete(.PUSH_MLOAD_INLINE);
                    return Error.AllocationError;
                },
            };

            const value = @as(WordType, @truncate(value_u256));
            {
                self.getTracer().assert(self.stack.size() < @TypeOf(self.stack).stack_capacity, "PUSH_MLOAD requires stack space");
            }
            self.stack.push_unsafe(value);

            self.afterInstruction(.PUSH_MLOAD_INLINE, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// PUSH_MLOAD_POINTER - Fused PUSH+MLOAD with pointer offset (>8 bytes).
        /// Gas costs are pre-calculated statically in dispatch.
        pub fn push_mload_pointer(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.PUSH_MLOAD_POINTER, cursor);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.PUSH_MLOAD_POINTER, Dispatch, Dispatch.Item, cursor);

            // Cursor now points to metadata
            const offset = op_data.metadata.value_ptr.*;

            // Check if offset fits in usize
            if (offset > std.math.maxInt(usize)) {
                @branchHint(.unlikely);
                self.afterComplete(.PUSH_MLOAD_POINTER);
                return Error.OutOfBounds;
            }
            const offset_usize = @as(usize, @intCast(offset));

            // Gas costs are handled statically by dispatch - no dynamic calculation needed

            // Read 32 bytes from memory
            const value_u256 = self.memory.get_u256_evm(self.getAllocator(), @as(u24, @intCast(offset_usize))) catch |err| switch (err) {
                memory_mod.MemoryError.OutOfBounds => {
                    self.afterComplete(.PUSH_MLOAD_POINTER);
                    return Error.OutOfBounds;
                },
                memory_mod.MemoryError.MemoryOverflow => {
                    self.afterComplete(.PUSH_MLOAD_POINTER);
                    return Error.OutOfBounds;
                },
                else => {
                    self.afterComplete(.PUSH_MLOAD_POINTER);
                    return Error.AllocationError;
                },
            };

            const value = @as(WordType, @truncate(value_u256));
            {
                self.getTracer().assert(self.stack.size() < @TypeOf(self.stack).stack_capacity, "PUSH_MLOAD requires stack space");
            }
            self.stack.push_unsafe(value);

            self.afterInstruction(.PUSH_MLOAD_POINTER, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// PUSH_MSTORE_INLINE - Fused PUSH+MSTORE with inline offset (≤8 bytes).
        /// Pushes an offset, then pops a value and stores it at that offset.
        /// Gas costs are pre-calculated statically in dispatch.
        pub fn push_mstore_inline(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.PUSH_MSTORE_INLINE, cursor);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.PUSH_MSTORE_INLINE, Dispatch, Dispatch.Item, cursor);

            // Cursor now points to metadata
            const offset = op_data.metadata.value;

            // Pop the value to store
            {
                self.getTracer().assert(self.stack.size() >= 1, "PUSH_MSTORE requires 1 stack item");
            }
            const value = self.stack.pop_unsafe();

            // Check if offset fits in usize
            if (offset > std.math.maxInt(usize)) {
                @branchHint(.unlikely);
                self.afterComplete(.PUSH_MSTORE_INLINE);
                return Error.OutOfBounds;
            }
            const offset_usize = @as(usize, @intCast(offset));

            // Gas costs are handled statically by dispatch - no dynamic calculation needed

            // Store 32 bytes to memory
            const value_u256 = @as(u256, value);
            self.memory.set_u256_evm(self.getAllocator(), @as(u24, @intCast(offset_usize)), value_u256) catch |err| switch (err) {
                memory_mod.MemoryError.OutOfBounds => {
                    self.afterComplete(.PUSH_MSTORE_INLINE);
                    return Error.OutOfBounds;
                },
                memory_mod.MemoryError.MemoryOverflow => {
                    self.afterComplete(.PUSH_MSTORE_INLINE);
                    return Error.OutOfBounds;
                },
                else => {
                    self.afterComplete(.PUSH_MSTORE_INLINE);
                    return Error.AllocationError;
                },
            };

            self.afterInstruction(.PUSH_MSTORE_INLINE, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// PUSH_MSTORE_POINTER - Fused PUSH+MSTORE with pointer offset (>8 bytes).
        /// Gas costs are pre-calculated statically in dispatch.
        pub fn push_mstore_pointer(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.PUSH_MSTORE_POINTER, cursor);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.PUSH_MSTORE_POINTER, Dispatch, Dispatch.Item, cursor);

            // Cursor now points to metadata
            const offset = op_data.metadata.value_ptr.*;

            // Pop the value to store
            {
                self.getTracer().assert(self.stack.size() >= 1, "PUSH_MSTORE requires 1 stack item");
            }
            const value = self.stack.pop_unsafe();

            {
                self.getTracer().assert(offset <= std.math.maxInt(usize), "PUSH_MSTORE offset must fit in usize");
            }
            const offset_usize = @as(usize, @intCast(offset));

            // Gas costs are handled statically by dispatch - no dynamic calculation needed

            // Store 32 bytes to memory
            const value_u256 = @as(u256, value);
            self.memory.set_u256_evm(self.getAllocator(), @as(u24, @intCast(offset_usize)), value_u256) catch |err| switch (err) {
                memory_mod.MemoryError.OutOfBounds => {
                    self.afterComplete(.PUSH_MSTORE_POINTER);
                    return Error.OutOfBounds;
                },
                memory_mod.MemoryError.MemoryOverflow => {
                    self.afterComplete(.PUSH_MSTORE_POINTER);
                    return Error.OutOfBounds;
                },
                else => {
                    self.afterComplete(.PUSH_MSTORE_POINTER);
                    return Error.AllocationError;
                },
            };

            self.afterInstruction(.PUSH_MSTORE_POINTER, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// PUSH_MSTORE8_INLINE - Fused PUSH+MSTORE8 with inline offset (≤8 bytes).
        /// Pushes an offset, then pops a value and stores the least significant byte.
        /// Gas costs are pre-calculated statically in dispatch.
        pub fn push_mstore8_inline(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.PUSH_MSTORE8_INLINE, cursor);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.PUSH_MSTORE8_INLINE, Dispatch, Dispatch.Item, cursor);

            // Cursor now points to metadata
            const offset = op_data.metadata.value;

            // Pop the value to store
            {
                self.getTracer().assert(self.stack.size() >= 1, "PUSH_MSTORE8 requires 1 stack item");
            }
            const value = self.stack.pop_unsafe();

            // Check if offset fits in usize
            if (offset > std.math.maxInt(usize)) {
                @branchHint(.unlikely);
                self.afterComplete(.PUSH_MSTORE8_INLINE);
                return Error.OutOfBounds;
            }
            const offset_usize = @as(usize, @intCast(offset));

            // Gas costs are handled statically by dispatch - no dynamic calculation needed

            // Store the least significant byte
            const byte_value = @as(u8, @truncate(value));
            self.memory.set_byte_evm(self.getAllocator(), @as(u24, @intCast(offset_usize)), byte_value) catch |err| switch (err) {
                memory_mod.MemoryError.OutOfBounds => {
                    self.afterComplete(.PUSH_MSTORE8_INLINE);
                    return Error.OutOfBounds;
                },
                memory_mod.MemoryError.MemoryOverflow => {
                    self.afterComplete(.PUSH_MSTORE8_INLINE);
                    return Error.OutOfBounds;
                },
                else => {
                    self.afterComplete(.PUSH_MSTORE8_INLINE);
                    return Error.AllocationError;
                },
            };

            self.afterInstruction(.PUSH_MSTORE8_INLINE, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// PUSH_MSTORE8_POINTER - Fused PUSH+MSTORE8 with pointer offset (>8 bytes).
        /// Gas costs are pre-calculated statically in dispatch.
        pub fn push_mstore8_pointer(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.PUSH_MSTORE8_POINTER, cursor);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.PUSH_MSTORE8_POINTER, Dispatch, Dispatch.Item, cursor);

            // Cursor now points to metadata
            const offset = op_data.metadata.value_ptr.*;

            // Pop the value to store
            {
                self.getTracer().assert(self.stack.size() >= 1, "PUSH_MSTORE8 requires 1 stack item");
            }
            const value = self.stack.pop_unsafe();

            // Check if offset fits in usize
            if (offset > std.math.maxInt(usize)) {
                @branchHint(.cold);
                self.afterComplete(.PUSH_MSTORE8_POINTER);
                return Error.OutOfBounds;
            }
            const offset_usize = @as(usize, @intCast(offset));

            // Gas costs are handled statically by dispatch - no dynamic calculation needed

            // Store the least significant byte
            const byte_value = @as(u8, @truncate(value));
            self.memory.set_byte_evm(self.getAllocator(), @as(u24, @intCast(offset_usize)), byte_value) catch |err| switch (err) {
                memory_mod.MemoryError.OutOfBounds => {
                    self.afterComplete(.PUSH_MSTORE8_POINTER);
                    return Error.OutOfBounds;
                },
                memory_mod.MemoryError.MemoryOverflow => {
                    self.afterComplete(.PUSH_MSTORE8_POINTER);
                    return Error.OutOfBounds;
                },
                else => {
                    self.afterComplete(.PUSH_MSTORE8_POINTER);
                    return Error.AllocationError;
                },
            };

            self.afterInstruction(.PUSH_MSTORE8_POINTER, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }
    };
}

// ====== TESTS ======

const testing = std.testing;
const Frame = @import("../frame/frame.zig").Frame;
const dispatch_mod = @import("../preprocessor/dispatch.zig");
const DefaultTracer = @import("../tracer/tracer.zig").DefaultTracer;
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

    cursor[0].metadata = .{ .value = value };

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

test "PUSH_MLOAD_INLINE - load from memory" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Pre-store a value at offset 32
    frame.memory.set_u256_evm(testing.allocator, 32, 0xDEADBEEF) catch unreachable;

    // PUSH 32 + MLOAD
    const dispatch = createInlineDispatch(32);
    _ = try TestFrame.MemorySyntheticHandlers.push_mload_inline(frame, dispatch);

    try testing.expectEqual(@as(u256, 0xDEADBEEF), try frame.stack.pop());
}

test "PUSH_MLOAD_INLINE - load from uninitialized memory" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // PUSH 100 + MLOAD (uninitialized memory should return 0)
    const dispatch = createInlineDispatch(100);
    _ = try TestFrame.MemorySyntheticHandlers.push_mload_inline(frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "PUSH_MSTORE_INLINE - store to memory" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Push value to store
    try frame.stack.push(0x1234567890ABCDEF);

    // PUSH 64 + MSTORE
    const dispatch = createInlineDispatch(64);
    _ = try TestFrame.MemorySyntheticHandlers.push_mstore_inline(frame, dispatch);

    // Verify the value was stored
    const stored = frame.memory.get_u256_evm(testing.allocator, 64) catch unreachable;
    try testing.expectEqual(@as(u256, 0x1234567890ABCDEF), stored);
}

test "PUSH_MSTORE8_INLINE - store single byte" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Push value to store (only LSB will be stored)
    try frame.stack.push(0x11FF);

    // PUSH 10 + MSTORE8
    const dispatch = createInlineDispatch(10);
    _ = try TestFrame.MemorySyntheticHandlers.push_mstore8_inline(frame, dispatch);

    // Verify only the least significant byte was stored
    const stored_byte = frame.memory.get_byte(10) catch unreachable;
    try testing.expectEqual(@as(u8, 0xFF), stored_byte);
}

test "synthetic memory - pointer variants" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test PUSH_MLOAD_POINTER
    frame.memory.set_u256_evm(1000, 0xCAFEBABE) catch unreachable;
    const load_offset: u256 = 1000;
    var dispatch = createPointerDispatch(&load_offset);
    _ = try TestFrame.MemorySyntheticHandlers.push_mload_pointer(frame, dispatch);
    try testing.expectEqual(@as(u256, 0xCAFEBABE), try frame.stack.pop());

    // Test PUSH_MSTORE_POINTER
    try frame.stack.push(0xDEADBEEF);
    const store_offset: u256 = 2000;
    dispatch = createPointerDispatch(&store_offset);
    _ = try TestFrame.MemorySyntheticHandlers.push_mstore_pointer(frame, dispatch);
    const stored = frame.memory.get_u256_evm(2000) catch unreachable;
    try testing.expectEqual(@as(u256, 0xDEADBEEF), stored);

    // Test PUSH_MSTORE8_POINTER
    try frame.stack.push(0x12AB);
    const store8_offset: u256 = 3000;
    dispatch = createPointerDispatch(&store8_offset);
    _ = try TestFrame.MemorySyntheticHandlers.push_mstore8_pointer(frame, dispatch);
    const stored_byte = frame.memory.get_byte(3000) catch unreachable;
    try testing.expectEqual(@as(u8, 0xAB), stored_byte);
}

test "synthetic memory - gas consumption" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    frame.gas_remaining = 100_000;
    const initial_gas = frame.gas_remaining;

    // PUSH_MSTORE to large offset should consume more gas
    try frame.stack.push(42);
    const dispatch = createInlineDispatch(10_000);
    _ = try TestFrame.MemorySyntheticHandlers.push_mstore_inline(frame, dispatch);

    // Gas should be consumed for memory expansion
    try testing.expect(frame.gas_remaining < initial_gas);
    const gas_consumed = initial_gas - frame.gas_remaining;
    try testing.expect(gas_consumed > GasConstants.GasFastestStep);
}

test "synthetic memory - out of bounds" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test with offset that exceeds usize
    const huge_offset = std.math.maxInt(u256);
    const dispatch = createPointerDispatch(&huge_offset);
    const result = TestFrame.MemorySyntheticHandlers.push_mload_pointer(frame, dispatch);

    try testing.expectError(TestFrame.Error.OutOfBounds, result);
}
