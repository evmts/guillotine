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