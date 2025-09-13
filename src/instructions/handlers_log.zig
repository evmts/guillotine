const std = @import("std");
const FrameConfig = @import("../frame/frame_config.zig").FrameConfig;
const log = @import("../log.zig");
const primitives = @import("primitives");
const Address = primitives.Address;
const GasConstants = primitives.GasConstants;
const Log = @import("../frame/call_result.zig").Log;
const Opcode = @import("../opcodes/opcode_data.zig").Opcode;

/// Log opcode handlers for the EVM stack frame.
/// These handle event emission (LOG0-LOG4).
pub fn Handlers(comptime FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;

        /// Generate a log handler for LOG0-LOG4
        pub fn generateLogHandler(comptime topic_count: u8) FrameType.OpcodeHandler {
            if (topic_count > 4) @compileError("Only LOG0 to LOG4 is supported");
            return &struct {
                pub fn logHandler(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
                    const dispatch = Dispatch{ .cursor = cursor };
                    // EIP-214: WriteProtection is handled by host interface for static calls

                    // LOG0 requires 2 items, LOG1 requires 3, LOG2 requires 4, LOG3 requires 5, LOG4 requires 6
                    std.debug.assert(self.stack.size() >= 2 + topic_count);

                    // Pop offset and length first (they're on top of stack)
                    const offset = self.stack.pop_unsafe();
                    const length = self.stack.pop_unsafe();
                    
                    // Pop topics in order (topic1 is deepest, topicN is shallowest)
                    var topics: [4]WordType = [_]WordType{0} ** 4;
                    for (0..topic_count) |j| {
                        topics[j] = self.stack.pop_unsafe();
                    }

                    // Check bounds
                    if (offset > std.math.maxInt(usize) or length > std.math.maxInt(usize)) {
                        return Error.OutOfBounds;
                    }

                    const offset_usize = @as(usize, @intCast(offset));
                    const length_usize = @as(usize, @intCast(length));

                    // Calculate memory expansion cost if reading data
                    var memory_expansion_cost: u64 = 0;
                    if (length_usize > 0) {
                        const end_offset = offset_usize + length_usize;
                        if (end_offset > std.math.maxInt(u24)) {
                            return Error.OutOfBounds;
                        }
                        memory_expansion_cost = self.memory.get_expansion_cost(@as(u24, @intCast(end_offset)));
                    }

                    // Calculate dynamic gas cost: data gas + memory expansion
                    const data_gas_cost = @as(u64, length_usize) * GasConstants.LogDataGas;
                    const total_dynamic_gas = data_gas_cost + memory_expansion_cost;
                    
                    // Check gas and consume dynamic gas
                    // Use negative gas pattern for single-branch out-of-gas detection
                    self.gas_remaining -= @intCast(total_dynamic_gas);
                    if (self.gas_remaining < 0) {
                        return Error.OutOfGas;
                    }

                    // Ensure memory capacity
                    if (length_usize > 0) {
                        const memory_end = offset_usize + length_usize;
                        self.memory.ensure_capacity(self.getAllocator(), @as(u24, @intCast(memory_end))) catch return Error.OutOfBounds;
                    }

                    // Get data from memory
                    const data = if (length_usize > 0)
                        self.memory.get_slice(@as(u24, @intCast(offset_usize)), @as(u24, @intCast(length_usize))) catch return Error.OutOfBounds
                    else
                        &[_]u8{};

                    // Write log directly to EVM using EVM's main allocator for proper memory ownership
                    const evm = self.getEvm();
                    
                    // Use EVM's main allocator (not arena) for log data that will be freed later
                    const data_copy = if (data.len > 0)
                        evm.allocator.dupe(u8, data) catch return Error.AllocationError
                    else
                        &[_]u8{};

                    const topics_array = if (topic_count > 0) blk: {
                        const arr = evm.allocator.alloc(u256, topic_count) catch {
                            if (data_copy.len > 0) evm.allocator.free(data_copy);
                            return Error.AllocationError;
                        };
                        for (0..topic_count) |j| {
                            arr[j] = @as(u256, topics[j]);
                        }
                        break :blk arr;
                    } else evm.allocator.alloc(u256, 0) catch {
                        if (data_copy.len > 0) evm.allocator.free(data_copy);
                        return Error.AllocationError;
                    };

                    const log_entry = Log{
                        .address = self.contract_address,
                        .topics = topics_array,
                        .data = data_copy,
                    };
                    evm.logs.append(evm.allocator, log_entry) catch {
                        // Clean up on failure
                        if (topics_array.len > 0) evm.allocator.free(topics_array);
                        if (data_copy.len > 0) evm.allocator.free(data_copy);
                        return Error.AllocationError;
                    };

                    // Map topic_count to the appropriate LOG opcode
                    switch (topic_count) {
                        0 => {
                            const op_data = dispatch.getOpData(.LOG0);
                            // Use op_data.next_handler and op_data.next_cursor directly
                            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                        },
                        1 => {
                            const op_data = dispatch.getOpData(.LOG1);
                            // Use op_data.next_handler and op_data.next_cursor directly
                            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                        },
                        2 => {
                            const op_data = dispatch.getOpData(.LOG2);
                            // Use op_data.next_handler and op_data.next_cursor directly
                            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                        },
                        3 => {
                            const op_data = dispatch.getOpData(.LOG3);
                            // Use op_data.next_handler and op_data.next_cursor directly
                            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                        },
                        4 => {
                            const op_data = dispatch.getOpData(.LOG4);
                            // Use op_data.next_handler and op_data.next_cursor directly
                            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                        },
                        else => unreachable,
                    }
                }
            }.logHandler;
        }

        /// LOG0 opcode (0xA0) - Emit log with no topics
        pub const log0: FrameType.OpcodeHandler = generateLogHandler(0);

        /// LOG1 opcode (0xA1) - Emit log with one topic
        pub const log1: FrameType.OpcodeHandler = generateLogHandler(1);

        /// LOG2 opcode (0xA2) - Emit log with two topics
        pub const log2: FrameType.OpcodeHandler = generateLogHandler(2);

        /// LOG3 opcode (0xA3) - Emit log with three topics
        pub const log3: FrameType.OpcodeHandler = generateLogHandler(3);

        /// LOG4 opcode (0xA4) - Emit log with four topics
        pub const log4: FrameType.OpcodeHandler = generateLogHandler(4);
    };
}

// ====== TESTS ======

const testing = std.testing;
const Frame = @import("../frame/frame.zig").Frame;
const dispatch_mod = @import("../preprocessor/dispatch.zig");
const bytecode_mod = @import("../bytecode/bytecode.zig");
const NoOpTracer = @import("../tracer/tracer.zig").NoOpTracer;
const MemoryDatabase = @import("../storage/memory_database.zig").MemoryDatabase;
// const host_mod = @import("host.zig");

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

// Mock EVM for testing
const MockEvm = struct {
    allocator: std.mem.Allocator,
    is_static: bool = false,
    logs: std.ArrayList(Log),

    pub fn init(allocator: std.mem.Allocator) MockEvm {
        return .{
            .allocator = allocator,
            .is_static = false,
            .logs = std.ArrayList(Log).init(allocator),
        };
    }

    pub fn deinit(self: *MockEvm) void {
        // Free the logs list
        self.logs.deinit();
    }

    pub fn get_is_static(self: *const MockEvm) bool {
        return self.is_static;
    }

    pub fn emit_log(self: *MockEvm, log_entry: Log) !void {
        try self.logs.append(log_entry);
    }
};

fn createTestFrame(allocator: std.mem.Allocator, evm: ?*MockEvm) !TestFrame {
    const database = MemoryDatabase.init(allocator);
    const value = try allocator.create(u256);
    value.* = 0;
    const evm_ptr = if (evm) |e| @as(*anyopaque, @ptrCast(e)) else @as(*anyopaque, @ptrFromInt(0x1000));
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

test "LOG0 opcode - empty data" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();

    const evm = &mock_evm;
    const test_address = Address.fromBytes([_]u8{0x12} ++ [_]u8{0} ** 19) catch unreachable;
    var frame = try createTestFrame(testing.allocator, evm);
    defer frame.deinit(testing.allocator);
    frame.contract_address = test_address;

    // LOG0 with empty data
    try frame.stack.push(0); // offset
    try frame.stack.push(0); // length

    const dispatch = createMockDispatch();
    _ = try TestFrame.LogHandlers.log0(frame, dispatch);

    try testing.expectEqual(@as(usize, 1), mock_evm.logs.items.len);
    const log_entry = mock_evm.logs.items[0];
    try testing.expect(log_entry.address.eql(test_address));
    try testing.expectEqual(@as(usize, 0), log_entry.topics.len);
    try testing.expectEqual(@as(usize, 0), log_entry.data.len);
}

test "LOG0 opcode - with data" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();

    const evm = &mock_evm;
    const test_address = Address.fromBytes([_]u8{0x34} ++ [_]u8{0} ** 19) catch unreachable;
    var frame = try createTestFrame(testing.allocator, evm);
    defer frame.deinit(testing.allocator);
    frame.contract_address = test_address;

    // Write test data to memory
    const test_data = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    try frame.memory.set_data(testing.allocator, 0, &test_data);

    // LOG0 with data
    try frame.stack.push(0); // offset
    try frame.stack.push(4); // length

    const dispatch = createMockDispatch();
    _ = try TestFrame.LogHandlers.log0(frame, dispatch);

    try testing.expectEqual(@as(usize, 1), mock_evm.logs.items.len);
    const log_entry = mock_evm.logs.items[0];
    try testing.expect(log_entry.address.eql(test_address));
    try testing.expectEqual(@as(usize, 0), log_entry.topics.len);
    try testing.expectEqualSlices(u8, &test_data, log_entry.data);
}

test "LOG1 opcode - with topic" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();

    const evm = &mock_evm;
    var frame = try createTestFrame(testing.allocator, evm);
    defer frame.deinit(testing.allocator);

    // Write test data to memory
    const test_data = [_]u8{ 0x11, 0x22 };
    try frame.memory.set_data(testing.allocator, 0, &test_data);

    // LOG1 with one topic
    try frame.stack.push(0); // offset
    try frame.stack.push(2); // length
    try frame.stack.push(0x1234); // topic1

    const dispatch = createMockDispatch();
    _ = try TestFrame.LogHandlers.log1(frame, dispatch);

    try testing.expectEqual(@as(usize, 1), mock_evm.logs.items.len);
    const log_entry = mock_evm.logs.items[0];
    try testing.expectEqual(@as(usize, 1), log_entry.topics.len);
    try testing.expectEqual(@as(u256, 0x1234), log_entry.topics[0]);
    try testing.expectEqualSlices(u8, &test_data, log_entry.data);
}

test "LOG2 opcode - with two topics" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();

    const evm = &mock_evm;
    var frame = try createTestFrame(testing.allocator, evm);
    defer frame.deinit(testing.allocator);

    // LOG2 with two topics
    try frame.stack.push(0); // offset
    try frame.stack.push(0); // length (empty data)
    try frame.stack.push(0xAAAA); // topic1
    try frame.stack.push(0xBBBB); // topic2

    const dispatch = createMockDispatch();
    _ = try TestFrame.LogHandlers.log2(frame, dispatch);

    try testing.expectEqual(@as(usize, 1), mock_evm.logs.items.len);
    const log_entry = mock_evm.logs.items[0];
    try testing.expectEqual(@as(usize, 2), log_entry.topics.len);
    try testing.expectEqual(@as(u256, 0xAAAA), log_entry.topics[0]);
    try testing.expectEqual(@as(u256, 0xBBBB), log_entry.topics[1]);
}

test "LOG3 opcode - with three topics" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();

    const evm = &mock_evm;
    var frame = try createTestFrame(testing.allocator, evm);
    defer frame.deinit(testing.allocator);

    // LOG3 with three topics
    try frame.stack.push(0); // offset
    try frame.stack.push(0); // length
    try frame.stack.push(0x1111); // topic1
    try frame.stack.push(0x2222); // topic2
    try frame.stack.push(0x3333); // topic3

    const dispatch = createMockDispatch();
    _ = try TestFrame.LogHandlers.log3(frame, dispatch);

    try testing.expectEqual(@as(usize, 1), mock_evm.logs.items.len);
    const log_entry = mock_evm.logs.items[0];
    try testing.expectEqual(@as(usize, 3), log_entry.topics.len);
    try testing.expectEqual(@as(u256, 0x1111), log_entry.topics[0]);
    try testing.expectEqual(@as(u256, 0x2222), log_entry.topics[1]);
    try testing.expectEqual(@as(u256, 0x3333), log_entry.topics[2]);
}

test "LOG4 opcode - with four topics" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();

    const evm = &mock_evm;
    var frame = try createTestFrame(testing.allocator, evm);
    defer frame.deinit(testing.allocator);

    // LOG4 with four topics
    try frame.stack.push(0); // offset
    try frame.stack.push(0); // length
    try frame.stack.push(0xAAAA); // topic1
    try frame.stack.push(0xBBBB); // topic2
    try frame.stack.push(0xCCCC); // topic3
    try frame.stack.push(0xDDDD); // topic4

    const dispatch = createMockDispatch();
    _ = try TestFrame.LogHandlers.log4(frame, dispatch);

    try testing.expectEqual(@as(usize, 1), mock_evm.logs.items.len);
    const log_entry = mock_evm.logs.items[0];
    try testing.expectEqual(@as(usize, 4), log_entry.topics.len);
    try testing.expectEqual(@as(u256, 0xAAAA), log_entry.topics[0]);
    try testing.expectEqual(@as(u256, 0xBBBB), log_entry.topics[1]);
    try testing.expectEqual(@as(u256, 0xCCCC), log_entry.topics[2]);
    try testing.expectEqual(@as(u256, 0xDDDD), log_entry.topics[3]);
}

test "LOG opcodes - static context error" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();
    mock_evm.is_static = true;

    const evm = &mock_evm;
    var frame = try createTestFrame(testing.allocator, evm);
    defer frame.deinit(testing.allocator);

    // Try LOG0 in static context
    try frame.stack.push(0); // offset
    try frame.stack.push(0); // length

    const dispatch = createMockDispatch();
    const result = TestFrame.LogHandlers.log0(frame, dispatch);

    try testing.expectError(TestFrame.Error.WriteProtection, result);
    try testing.expectEqual(@as(usize, 0), mock_evm.logs.items.len);
}

test "LOG opcodes - out of bounds" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();

    const evm = &mock_evm;
    var frame = try createTestFrame(testing.allocator, evm);
    defer frame.deinit(testing.allocator);

    // Try LOG0 with out of bounds offset
    const huge_offset = std.math.maxInt(u256);
    try frame.stack.push(huge_offset); // offset
    try frame.stack.push(10); // length

    const dispatch = createMockDispatch();
    const result = TestFrame.LogHandlers.log0(frame, dispatch);

    try testing.expectError(TestFrame.Error.OutOfBounds, result);
}

test "LOG opcodes - large data" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();

    const evm = &mock_evm;
    var frame = try createTestFrame(testing.allocator, evm);
    defer frame.deinit(testing.allocator);

    // Create large data in memory
    var large_data: [256]u8 = undefined;
    for (&large_data, 0..) |*byte, i| {
        byte.* = @intCast(i & 0xFF);
    }
    try frame.memory.set_data(testing.allocator, 0, &large_data);

    // LOG1 with large data
    try frame.stack.push(0); // offset
    try frame.stack.push(256); // length
    try frame.stack.push(0x12345678); // topic

    const dispatch = createMockDispatch();
    _ = try TestFrame.LogHandlers.log1(frame, dispatch);

    try testing.expectEqual(@as(usize, 1), mock_evm.logs.items.len);
    const log_entry = mock_evm.logs.items[0];
    try testing.expectEqualSlices(u8, &large_data, log_entry.data);
}

// ====== COMPREHENSIVE TESTS ======

test "LOG opcodes - boundary value topics" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();

    const evm = &mock_evm;
    var frame = try createTestFrame(testing.allocator, evm);
    defer frame.deinit(testing.allocator);

    // Test with maximum u256 value topics
    try frame.stack.push(0); // offset
    try frame.stack.push(0); // length
    try frame.stack.push(0); // topic1 = 0
    try frame.stack.push(std.math.maxInt(u256)); // topic2 = max

    const dispatch = createMockDispatch();
    _ = try TestFrame.LogHandlers.log2(frame, dispatch);

    try testing.expectEqual(@as(usize, 1), mock_evm.logs.items.len);
    const log_entry = mock_evm.logs.items[0];
    try testing.expectEqual(@as(u256, 0), log_entry.topics[0]);
    try testing.expectEqual(std.math.maxInt(u256), log_entry.topics[1]);
}

test "LOG opcodes - all topics patterns" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();

    const evm = &mock_evm;
    var frame = try createTestFrame(testing.allocator, evm);
    defer frame.deinit(testing.allocator);

    // Test LOG4 with various topic patterns
    try frame.stack.push(0); // offset
    try frame.stack.push(0); // length
    try frame.stack.push(0xFF); // topic1 - small value
    try frame.stack.push(0x8000000000000000); // topic2 - high bit set
    try frame.stack.push(std.math.shl(u256, 1, 128) - 1); // topic3 - max 128-bit
    try frame.stack.push(std.math.maxInt(u256) - 1); // topic4 - almost max

    const dispatch = createMockDispatch();
    _ = try TestFrame.LogHandlers.log4(frame, dispatch);

    const log_entry = mock_evm.logs.items[0];
    try testing.expectEqual(@as(u256, 0xFF), log_entry.topics[0]);
    try testing.expectEqual(@as(u256, 0x8000000000000000), log_entry.topics[1]);
    try testing.expectEqual(std.math.shl(u256, @as(u256, 1), 128) - 1, log_entry.topics[2]);
    try testing.expectEqual(std.math.maxInt(u256) - 1, log_entry.topics[3]);
}

test "LOG opcodes - memory boundary access" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();

    const evm = &mock_evm;
    var frame = try createTestFrame(testing.allocator, evm);
    defer frame.deinit(testing.allocator);

    // Write data at various memory locations
    try frame.memory.set_byte(testing.allocator, 31, 0xAA); // Last byte of first word
    try frame.memory.set_byte(testing.allocator, 32, 0xBB); // First byte of second word
    try frame.memory.set_byte(testing.allocator, 33, 0xCC); // Second byte of second word

    // LOG0 crossing word boundary
    try frame.stack.push(31); // offset
    try frame.stack.push(3); // length

    const dispatch = createMockDispatch();
    _ = try TestFrame.LogHandlers.log0(frame, dispatch);

    const log_entry = mock_evm.logs.items[0];
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC }, log_entry.data);
}

test "LOG opcodes - zero length edge cases" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();

    const evm = &mock_evm;

    // Test with various offset values and zero length
    const test_cases = [_]u256{
        0, // Zero offset
        100, // Normal offset
        std.math.maxInt(u32), // Large but valid offset
        std.math.maxInt(u64), // Very large offset
    };

    for (test_cases) |offset| {
        var frame = try createTestFrame(testing.allocator, evm);
        defer frame.deinit(testing.allocator);

        try frame.stack.push(offset); // offset
        try frame.stack.push(0); // length = 0

        const dispatch = createMockDispatch();
        _ = try TestFrame.LogHandlers.log0(frame, dispatch);

        // Should succeed with empty data regardless of offset
        const log_entry = mock_evm.logs.items[mock_evm.logs.items.len - 1];
        try testing.expectEqual(@as(usize, 0), log_entry.data.len);
    }
}

test "LOG opcodes - maximum data sizes" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();

    const evm = &mock_evm;
    var frame = try createTestFrame(testing.allocator, evm);
    defer frame.deinit(testing.allocator);

    // Test various data sizes
    const sizes = [_]usize{
        1, // Single byte
        31, // Just under word boundary
        32, // Exactly one word
        33, // Just over word boundary
        64, // Two words
        1024, // 1KB
        4096, // 4KB
    };

    for (sizes) |size| {
        // Ensure memory capacity and fill with test pattern
        try frame.memory.ensure_capacity(testing.allocator, size);
        for (0..size) |i| {
            try frame.memory.set_byte(testing.allocator, i, @intCast((i * 17) & 0xFF)); // Test pattern
        }

        try frame.stack.push(0); // offset
        try frame.stack.push(size); // length

        const dispatch = createMockDispatch();
        _ = try TestFrame.LogHandlers.log0(frame, dispatch);

        const log_entry = mock_evm.logs.items[mock_evm.logs.items.len - 1];
        try testing.expectEqual(size, log_entry.data.len);

        // Verify data pattern
        for (log_entry.data, 0..) |byte, i| {
            try testing.expectEqual(@as(u8, @intCast((i * 17) & 0xFF)), byte);
        }
    }
}

test "LOG opcodes - stack underflow protection" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();

    const evm = &mock_evm;
    var frame = try createTestFrame(testing.allocator, evm);
    defer frame.deinit(testing.allocator);

    const dispatch = createMockDispatch();

    // LOG0 needs 2 stack items
    var result = TestFrame.LogHandlers.log0(frame, dispatch);
    try testing.expectError(TestFrame.Error.StackUnderflow, result);

    try frame.stack.push(0);
    result = TestFrame.LogHandlers.log0(frame, dispatch);
    try testing.expectError(TestFrame.Error.StackUnderflow, result);

    // LOG1 needs 3 stack items
    try frame.stack.push(0);
    result = TestFrame.LogHandlers.log1(frame, dispatch);
    try testing.expectError(TestFrame.Error.StackUnderflow, result);

    // LOG4 needs 6 stack items
    try frame.stack.push(0);
    try frame.stack.push(0);
    try frame.stack.push(0);
    result = TestFrame.LogHandlers.log4(frame, dispatch);
    try testing.expectError(TestFrame.Error.StackUnderflow, result);
}

test "LOG opcodes - memory expansion" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();

    const evm = &mock_evm;
    var frame = try createTestFrame(testing.allocator, evm);
    defer frame.deinit(testing.allocator);

    // Initially memory is empty
    try testing.expectEqual(@as(usize, 0), frame.memory.size());

    // LOG0 with data at offset 1000, length 100
    try frame.stack.push(1000); // offset
    try frame.stack.push(100); // length

    const dispatch = createMockDispatch();
    _ = try TestFrame.LogHandlers.log0(frame, dispatch);

    // Memory should have expanded to at least 1100 bytes
    try testing.expect(frame.memory.size() >= 1100);

    // Log should contain zeros (uninitialized memory)
    const log_entry = mock_evm.logs.items[0];
    try testing.expectEqual(@as(usize, 100), log_entry.data.len);
    for (log_entry.data) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "LOG opcodes - multiple logs in sequence" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();

    const evm = &mock_evm;
    var frame = try createTestFrame(testing.allocator, evm);
    defer frame.deinit(testing.allocator);

    // Write different data patterns
    try frame.memory.set_data(testing.allocator, 0, &[_]u8{ 0x11, 0x11 });
    try frame.memory.set_data(testing.allocator, 10, &[_]u8{ 0x22, 0x22 });
    try frame.memory.set_data(testing.allocator, 20, &[_]u8{ 0x33, 0x33 });

    const dispatch = createMockDispatch();

    // LOG0
    try frame.stack.push(0); // offset
    try frame.stack.push(2); // length
    _ = try TestFrame.LogHandlers.log0(frame, dispatch);

    // LOG1
    try frame.stack.push(10); // offset
    try frame.stack.push(2); // length
    try frame.stack.push(0xAA); // topic
    _ = try TestFrame.LogHandlers.log1(frame, dispatch);

    // LOG2
    try frame.stack.push(20); // offset
    try frame.stack.push(2); // length
    try frame.stack.push(0xBB); // topic1
    try frame.stack.push(0xCC); // topic2
    _ = try TestFrame.LogHandlers.log2(frame, dispatch);

    // Verify all logs
    try testing.expectEqual(@as(usize, 3), mock_evm.logs.items.len);

    // First log (LOG0)
    try testing.expectEqual(@as(usize, 0), mock_evm.logs.items[0].topics.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x11 }, mock_evm.logs.items[0].data);

    // Second log (LOG1)
    try testing.expectEqual(@as(usize, 1), mock_evm.logs.items[1].topics.len);
    try testing.expectEqual(@as(u256, 0xAA), mock_evm.logs.items[1].topics[0]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x22, 0x22 }, mock_evm.logs.items[1].data);

    // Third log (LOG2)
    try testing.expectEqual(@as(usize, 2), mock_evm.logs.items[2].topics.len);
    try testing.expectEqual(@as(u256, 0xBB), mock_evm.logs.items[2].topics[0]);
    try testing.expectEqual(@as(u256, 0xCC), mock_evm.logs.items[2].topics[1]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x33, 0x33 }, mock_evm.logs.items[2].data);
}

test "LOG opcodes - contract address tracking" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();

    const evm = &mock_evm;

    // Test different contract addresses
    const addresses = [_]Address{
        Address.zero(),
        Address.fromBytes([_]u8{0xFF} ** 20) catch unreachable,
        Address.fromBytes([_]u8{ 0x12, 0x34, 0x56 } ++ [_]u8{0} ** 17) catch unreachable,
    };

    for (addresses) |addr| {
        var frame = try createTestFrame(testing.allocator, evm);
        defer frame.deinit(testing.allocator);

        frame.contract_address = addr;

        try frame.stack.push(0); // offset
        try frame.stack.push(0); // length

        const dispatch = createMockDispatch();
        _ = try TestFrame.LogHandlers.log0(frame, dispatch);
    }

    // Verify each log has correct address
    try testing.expectEqual(@as(usize, addresses.len), mock_evm.logs.items.len);
    for (mock_evm.logs.items, addresses) |log_entry, expected_addr| {
        try testing.expect(log_entry.address.eql(expected_addr));
    }
}

test "LOG opcodes - topic order preservation" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();

    const evm = &mock_evm;
    var frame = try createTestFrame(testing.allocator, evm);
    defer frame.deinit(testing.allocator);

    // Push topics in specific order (remember stack is LIFO)
    try frame.stack.push(0); // offset
    try frame.stack.push(0); // length
    try frame.stack.push(0x04); // topic1 (pushed last, popped first)
    try frame.stack.push(0x03); // topic2
    try frame.stack.push(0x02); // topic3
    try frame.stack.push(0x01); // topic4 (pushed first, popped last)

    const dispatch = createMockDispatch();
    _ = try TestFrame.LogHandlers.log4(frame, dispatch);

    const log_entry = mock_evm.logs.items[0];
    // Topics should be in correct order after reversal in handler
    try testing.expectEqual(@as(u256, 0x04), log_entry.topics[0]);
    try testing.expectEqual(@as(u256, 0x03), log_entry.topics[1]);
    try testing.expectEqual(@as(u256, 0x02), log_entry.topics[2]);
    try testing.expectEqual(@as(u256, 0x01), log_entry.topics[3]);
}

test "LOG opcodes - offset plus length overflow" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();

    const evm = &mock_evm;
    var frame = try createTestFrame(testing.allocator, evm);
    defer frame.deinit(testing.allocator);

    // Test cases where offset + length might overflow
    const test_cases = [_]struct { offset: u256, length: u256 }{
        .{ .offset = std.math.maxInt(u256) - 10, .length = 20 }, // Would overflow
        .{ .offset = std.math.maxInt(u64), .length = std.math.maxInt(u64) }, // Both large
    };

    for (test_cases) |tc| {
        // Clear stack
        while (frame.stack.len() > 0) {
            _ = try frame.stack.pop();
        }

        try frame.stack.push(tc.offset);
        try frame.stack.push(tc.length);

        const dispatch = createMockDispatch();
        const result = TestFrame.LogHandlers.log0(frame, dispatch);

        try testing.expectError(TestFrame.Error.OutOfBounds, result);
    }
}

test "LOG opcodes - static context protection for all variants" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();
    mock_evm.is_static = true;

    const evm = &mock_evm;

    // Test all LOG variants in static context
    const log_handlers = [_]struct {
        handler: *const TestFrame.OpcodeHandler,
        stack_items: u8,
    }{
        .{ .handler = TestFrame.LogHandlers.log0, .stack_items = 2 },
        .{ .handler = TestFrame.LogHandlers.log1, .stack_items = 3 },
        .{ .handler = TestFrame.LogHandlers.log2, .stack_items = 4 },
        .{ .handler = TestFrame.LogHandlers.log3, .stack_items = 5 },
        .{ .handler = TestFrame.LogHandlers.log4, .stack_items = 6 },
    };

    for (log_handlers) |lh| {
        var frame = try createTestFrame(testing.allocator, evm);
        defer frame.deinit(testing.allocator);

        // Push required number of items
        for (0..lh.stack_items) |_| {
            try frame.stack.push(0);
        }

        const dispatch = createMockDispatch();
        const result = lh.handler(frame, dispatch);

        try testing.expectError(TestFrame.Error.WriteProtection, result);
    }

    // Ensure no logs were created
    try testing.expectEqual(@as(usize, 0), mock_evm.logs.items.len);
}

test "LOG opcodes - memory limit enforcement" {
    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();

    const evm = &mock_evm;
    var frame = try createTestFrame(testing.allocator, evm);
    defer frame.deinit(testing.allocator);

    // Try to log data near memory limit
    const near_limit = test_config.memory_limit - 100;
    try frame.stack.push(near_limit); // offset
    try frame.stack.push(200); // length (would exceed limit)

    const dispatch = createMockDispatch();
    const result = TestFrame.LogHandlers.log0(frame, dispatch);

    try testing.expectError(TestFrame.Error.OutOfBounds, result);
}

test "LOG opcodes - WordType smaller than u256" {
    // Test with u64 word type
    const SmallWordConfig = FrameConfig{
        .stack_size = 1024,
        .WordType = u64,
        .max_bytecode_size = 1024,
        .block_gas_limit = 30_000_000,
        .DatabaseType = MemoryDatabase,
        .memory_initial_capacity = 4096,
        .memory_limit = 0xFFFFFF,
    };

    const SmallFrame = Frame(SmallWordConfig);

    var mock_evm = MockEvm.init(testing.allocator);
    defer mock_evm.deinit();

    const evm = &mock_evm;
    const database = MemoryDatabase.init(testing.allocator);
    const value = try testing.allocator.create(u64);
    defer testing.allocator.destroy(value);
    value.* = 0;
    var frame = try SmallFrame.init(testing.allocator, @intCast(1_000_000), database, Address.ZERO_ADDRESS, value, &[_]u8{}, @as(*anyopaque, @ptrCast(evm)));
    defer frame.deinit(testing.allocator);

    // Test LOG2 with u64 topics
    try frame.stack.push(0); // offset
    try frame.stack.push(0); // length
    try frame.stack.push(std.math.maxInt(u64)); // topic1
    try frame.stack.push(0x123456789ABCDEF); // topic2

    // Mock dispatch for SmallFrame
    const mock_handler = struct {
        fn handler(f: SmallFrame, d: SmallFrame.Dispatch) SmallFrame.Error!SmallFrame.Success {
            _ = f;
            _ = d;
            return SmallFrame.Success.stop;
        }
    }.handler;

    var cursor: [1]dispatch_mod.ScheduleElement(SmallFrame) = undefined;
    cursor[0] = .{ .opcode_handler = &mock_handler };

    const dispatch = SmallFrame.Dispatch{
        .cursor = &cursor,
        .bytecode_length = 0,
    };

    _ = try SmallFrame.LogHandlers.log2(frame, dispatch);

    const log_entry = mock_evm.logs.items[0];
    // Topics are stored as u256 in Log structure
    try testing.expectEqual(@as(usize, 2), log_entry.topics.len);
}
