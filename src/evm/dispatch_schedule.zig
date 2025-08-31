const std = @import("std");

/// RAII wrapper for dispatch schedule with automatic cleanup
pub fn DispatchSchedule(comptime _: type, comptime DispatchType: type) type {
    const Self = DispatchType;
    
    return struct {
        items: []Self.Item,
        allocator: std.mem.Allocator,

        /// Initialize a dispatch schedule from bytecode with automatic cleanup
        pub fn init(allocator: std.mem.Allocator, bytecode: anytype, opcode_handlers: *const [256]Self.OpcodeHandler) !@This() {
            const items = try Self.init(allocator, bytecode, opcode_handlers);
            return @This(){
                .items = items,
                .allocator = allocator,
            };
        }

        /// Initialize a dispatch schedule with tracing support
        pub fn initWithTracing(
            allocator: std.mem.Allocator,
            bytecode: anytype,
            opcode_handlers: *const [256]Self.OpcodeHandler,
            comptime TracerType: type,
            tracer_instance: *TracerType,
        ) !@This() {
            const items = try Self.initWithTracing(allocator, bytecode, opcode_handlers, TracerType, tracer_instance);
            return @This(){
                .items = items,
                .allocator = allocator,
            };
        }

        /// Clean up the schedule including all heap-allocated push pointers
        pub fn deinit(self: *@This()) void {
            Self.deinitSchedule(self.allocator, self.items);
        }

        /// Get a Dispatch instance pointing to the start of the schedule
        pub fn getDispatch(self: *const @This()) Self {
            return Self{
                .cursor = self.items.ptr,
            };
        }
    };
}

/// Iterator for traversing schedule alongside bytecode
pub fn ScheduleIterator(comptime FrameType: type, comptime DispatchType: type) type {
    const Self = DispatchType;
    
    return struct {
        schedule: []const Self.Item,
        bytecode: *const anyopaque,
        pc: FrameType.PcType = 0,
        schedule_index: usize = 0,

        pub const Entry = struct {
            pc: FrameType.PcType,
            schedule_index: usize,
            op_data: enum { regular, push, jumpdest, stop, invalid, fusion },
        };

        pub fn init(schedule: []const Self.Item, bytecode: anytype) @This() {
            return .{
                .schedule = schedule,
                .bytecode = bytecode,
                .pc = 0,
                .schedule_index = 0,
            };
        }

        pub fn next(self: *@This()) ?Entry {
            if (self.schedule_index >= self.schedule.len) return null;

            // Skip first_block_gas if present
            if (self.schedule_index == 0) {
                // First_block_gas is only added if calculateFirstBlockGas(bytecode) > 0
                const first_block_gas = Self.calculateFirstBlockGas(self.bytecode);
                if (first_block_gas > 0) {
                    self.schedule_index = 1;
                    if (self.schedule_index >= self.schedule.len) return null;
                }
            }

            const current_pc = self.pc;
            const current_index = self.schedule_index;

            // Determine operation type from schedule
            const item = self.schedule[self.schedule_index];
            const op_type: Entry.op_data = switch (item) {
                .opcode_handler => blk: {
                    // Look at the actual bytecode to determine type
                    // This is simplified - in real implementation would need proper bytecode access
                    break :blk .regular;
                },
                .jump_dest => .jumpdest,
                .push_inline, .push_pointer => .push,
                else => .regular,
            };

            // Advance schedule index
            self.schedule_index += 1;

            // Skip metadata items
            if (self.schedule_index < self.schedule.len) {
                switch (self.schedule[self.schedule_index]) {
                    .jump_dest, .push_inline, .push_pointer, .pc, .codesize, .codecopy, .trace_before, .trace_after => {
                        self.schedule_index += 1;
                    },
                    else => {},
                }
            }

            // Update PC based on operation type
            // This is simplified - would need actual bytecode parsing
            self.pc += 1;

            return Entry{
                .pc = current_pc,
                .schedule_index = current_index,
                .op_data = op_type,
            };
        }
    };
}

// ============================
// Tests
// ============================

const testing = std.testing;

// Mock types for testing
const TestFrame = struct {
    pub const PcType = u32;
};

const TestItem = struct {
    value: u64,
};

const TestDispatch = struct {
    cursor: [*]const TestItem,
    
    pub const Item = TestItem;
    pub const OpcodeHandler = *const fn () void;
    
    pub fn init(allocator: std.mem.Allocator, bytecode: anytype, opcode_handlers: *const [256]OpcodeHandler) ![]Item {
        _ = bytecode;
        _ = opcode_handlers;
        // Return a simple test schedule
        const items = try allocator.alloc(Item, 3);
        items[0] = .{ .value = 100 };
        items[1] = .{ .value = 200 };
        items[2] = .{ .value = 300 };
        return items;
    }
    
    pub fn initWithTracing(
        allocator: std.mem.Allocator,
        bytecode: anytype,
        opcode_handlers: *const [256]OpcodeHandler,
        comptime TracerType: type,
        tracer_instance: *TracerType,
    ) ![]Item {
        _ = tracer_instance;
        _ = TracerType;
        // Reuse the init function for simplicity
        return init(allocator, bytecode, opcode_handlers);
    }
    
    pub fn deinitSchedule(allocator: std.mem.Allocator, schedule: []const Item) void {
        allocator.free(schedule);
    }
    
    pub fn calculateFirstBlockGas(bytecode: anytype) u64 {
        _ = bytecode;
        return 0;
    }
};

// Mock bytecode
const MockBytecode = struct {
    data: []const u8,
};

// Mock tracer
const MockTracer = struct {
    traced: bool = false,
};

fn mockHandler() void {}

test "DispatchSchedule init and deinit" {
    const Schedule = DispatchSchedule(TestFrame, TestDispatch);
    
    const bytecode = MockBytecode{ .data = &[_]u8{0x60, 0x01} };
    var handlers: [256]TestDispatch.OpcodeHandler = undefined;
    for (&handlers) |*h| {
        h.* = &mockHandler;
    }
    
    var schedule = try Schedule.init(testing.allocator, bytecode, &handlers);
    defer schedule.deinit();
    
    try testing.expectEqual(@as(usize, 3), schedule.items.len);
    try testing.expectEqual(@as(u64, 100), schedule.items[0].value);
}

test "DispatchSchedule getDispatch" {
    const Schedule = DispatchSchedule(TestFrame, TestDispatch);
    
    const bytecode = MockBytecode{ .data = &[_]u8{0x60, 0x01} };
    var handlers: [256]TestDispatch.OpcodeHandler = undefined;
    for (&handlers) |*h| {
        h.* = &mockHandler;
    }
    
    var schedule = try Schedule.init(testing.allocator, bytecode, &handlers);
    defer schedule.deinit();
    
    const dispatch = schedule.getDispatch();
    try testing.expectEqual(schedule.items.ptr, dispatch.cursor);
}

test "DispatchSchedule initWithTracing" {
    const Schedule = DispatchSchedule(TestFrame, TestDispatch);
    
    const bytecode = MockBytecode{ .data = &[_]u8{0x60, 0x01} };
    var handlers: [256]TestDispatch.OpcodeHandler = undefined;
    for (&handlers) |*h| {
        h.* = &mockHandler;
    }
    
    var tracer = MockTracer{};
    
    var schedule = try Schedule.initWithTracing(
        testing.allocator,
        bytecode,
        &handlers,
        MockTracer,
        &tracer,
    );
    defer schedule.deinit();
    
    try testing.expectEqual(@as(usize, 3), schedule.items.len);
}

test "ScheduleIterator basic iteration" {
    const Iterator = ScheduleIterator(TestFrame, TestDispatch);
    
    const schedule = [_]TestItem{
        .{ .value = 100 },
        .{ .value = 200 },
        .{ .value = 300 },
    };
    
    const bytecode = MockBytecode{ .data = &[_]u8{0x60, 0x01, 0x02} };
    
    var iter = Iterator.init(&schedule, &bytecode);
    
    // First entry
    const entry1 = iter.next();
    try testing.expect(entry1 != null);
    try testing.expectEqual(@as(u32, 0), entry1.?.pc);
    try testing.expectEqual(@as(usize, 0), entry1.?.schedule_index);
    
    // Second entry
    const entry2 = iter.next();
    try testing.expect(entry2 != null);
    try testing.expectEqual(@as(u32, 1), entry2.?.pc);
    try testing.expectEqual(@as(usize, 1), entry2.?.schedule_index);
    
    // Third entry
    const entry3 = iter.next();
    try testing.expect(entry3 != null);
    try testing.expectEqual(@as(u32, 2), entry3.?.pc);
    try testing.expectEqual(@as(usize, 2), entry3.?.schedule_index);
    
    // End of iteration
    const entry4 = iter.next();
    try testing.expect(entry4 == null);
}

test "ScheduleIterator skips first_block_gas when present" {
    const MockDispatchWithGas = struct {
        pub const Item = TestItem;
        
        pub fn calculateFirstBlockGas(bytecode: anytype) u64 {
            _ = bytecode;
            return 100; // Non-zero first block gas
        }
    };
    
    const Iterator = ScheduleIterator(TestFrame, MockDispatchWithGas);
    
    const schedule = [_]TestItem{
        .{ .value = 999 }, // first_block_gas item
        .{ .value = 100 }, // actual first opcode
        .{ .value = 200 },
    };
    
    const bytecode = MockBytecode{ .data = &[_]u8{0x60, 0x01} };
    
    var iter = Iterator.init(&schedule, &bytecode);
    
    // Should skip first_block_gas and start at index 1
    const entry1 = iter.next();
    try testing.expect(entry1 != null);
    try testing.expectEqual(@as(usize, 1), entry1.?.schedule_index);
}

test "ScheduleIterator handles empty schedule" {
    const Iterator = ScheduleIterator(TestFrame, TestDispatch);
    
    const schedule = [_]TestItem{};
    const bytecode = MockBytecode{ .data = &[_]u8{} };
    
    var iter = Iterator.init(&schedule, &bytecode);
    
    const entry = iter.next();
    try testing.expect(entry == null);
}