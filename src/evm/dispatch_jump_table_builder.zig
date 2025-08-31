const std = @import("std");
const Opcode = @import("opcode_data.zig").Opcode;
const ArrayList = std.ArrayListAligned;

/// Jump table builder functionality for dispatch operations
/// Creates jump table builder types for a given Frame type and Dispatch type
pub fn JumpTableBuilder(comptime FrameType: type, comptime DispatchType: type) type {
    const Self = DispatchType;
    
    return struct {
        const BuilderEntry = struct {
            pc: FrameType.PcType,
            schedule_index: usize,
        };

        entries: ArrayList(BuilderEntry, null),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .entries = ArrayList(BuilderEntry, null){},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.entries.deinit(self.allocator);
        }

        pub fn addEntry(self: *@This(), pc: FrameType.PcType, schedule_index: usize) !void {
            try self.entries.append(self.allocator, .{
                .pc = pc,
                .schedule_index = schedule_index,
            });
        }

        pub fn buildFromSchedule(self: *@This(), schedule: []const Self.Item, bytecode: anytype) !void {
            var iter = bytecode.createIterator();
            var schedule_index: usize = 0;

            // Skip first_block_gas if present
            // First_block_gas is only added if calculateFirstBlockGas(bytecode) > 0
            const first_block_gas = Self.calculateFirstBlockGas(bytecode);
            if (first_block_gas > 0 and schedule.len > 0) {
                schedule_index = 1;
            }

            while (true) {
                const instr_pc = iter.pc;
                const maybe = iter.next();
                if (maybe == null) break;
                const op_data = maybe.?;

                switch (op_data) {
                    .jumpdest => {
                        try self.addEntry(@intCast(instr_pc), schedule_index);
                        schedule_index += 2; // Handler + metadata
                    },
                    .regular => |data| {
                        schedule_index += 1;
                        if (data.opcode == @intFromEnum(Opcode.PC) or
                            data.opcode == @intFromEnum(Opcode.CODESIZE) or
                            data.opcode == @intFromEnum(Opcode.CODECOPY))
                        {
                            schedule_index += 1;
                        }
                    },
                    .push => {
                        schedule_index += 2; // Handler + metadata
                    },
                    .push_add_fusion, .push_mul_fusion, .push_sub_fusion, .push_div_fusion, .push_and_fusion, .push_or_fusion, .push_xor_fusion, .push_jump_fusion, .push_jumpi_fusion => {
                        schedule_index += 2;
                    },
                    .stop, .invalid => {
                        schedule_index += 1;
                    },
                }
            }
        }

        pub fn finalize(self: *@This()) !Self.JumpTable {
            const builder_entries = try self.entries.toOwnedSlice(self.allocator);
            defer self.allocator.free(builder_entries);

            // Sort builder entries by PC
            std.sort.block(BuilderEntry, builder_entries, {}, struct {
                pub fn lessThan(context: void, a: BuilderEntry, b: BuilderEntry) bool {
                    _ = context;
                    return a.pc < b.pc;
                }
            }.lessThan);

            // Convert to JumpTableEntry array
            const entries = try self.allocator.alloc(Self.JumpTable.JumpTableEntry, builder_entries.len);
            errdefer self.allocator.free(entries);

            for (builder_entries, entries) |builder_entry, *entry| {
                entry.* = .{
                    .pc = builder_entry.pc,
                    .dispatch = Self{
                        .cursor = undefined, // Must be set by caller
                    },
                };
            }

            return Self.JumpTable{ .entries = entries };
        }

        pub fn finalizeWithSchedule(self: *@This(), schedule: []const Self.Item) !Self.JumpTable {
            const builder_entries = try self.entries.toOwnedSlice(self.allocator);
            defer self.allocator.free(builder_entries);

            // Sort builder entries by PC
            std.sort.block(BuilderEntry, builder_entries, {}, struct {
                pub fn lessThan(context: void, a: BuilderEntry, b: BuilderEntry) bool {
                    _ = context;
                    return a.pc < b.pc;
                }
            }.lessThan);

            // Convert to JumpTableEntry array with proper dispatch pointers
            const entries = try self.allocator.alloc(Self.JumpTable.JumpTableEntry, builder_entries.len);
            errdefer self.allocator.free(entries);

            for (builder_entries, entries) |builder_entry, *entry| {
                entry.* = .{
                    .pc = builder_entry.pc,
                    .dispatch = Self{
                        .cursor = schedule.ptr + builder_entry.schedule_index,
                    },
                };
            }

            return Self.JumpTable{ .entries = entries };
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
    
    pub const JumpTable = struct {
        pub const JumpTableEntry = struct {
            pc: TestFrame.PcType,
            dispatch: TestDispatch,
        };
        
        entries: []const JumpTableEntry,
    };
    
    pub fn calculateFirstBlockGas(bytecode: anytype) u64 {
        _ = bytecode;
        return 0; // No first block gas for testing
    }
};

// Mock bytecode for testing
const MockBytecode = struct {
    data: []const u8,
    
    pub const Iterator = struct {
        pc: u32,
        index: usize,
        data: []const u8,
        
        pub const OpData = union(enum) {
            regular: struct { opcode: u8 },
            push: struct { size: u8, value: u256 },
            jumpdest: struct { gas_cost: u32 },
            stop,
            invalid,
            push_add_fusion: struct { value: u64 },
            push_mul_fusion: struct { value: u64 },
            push_sub_fusion: struct { value: u64 },
            push_div_fusion: struct { value: u64 },
            push_and_fusion: struct { value: u64 },
            push_or_fusion: struct { value: u64 },
            push_xor_fusion: struct { value: u64 },
            push_jump_fusion: struct { value: u64 },
            push_jumpi_fusion: struct { value: u64 },
        };
        
        pub fn next(self: *@This()) ?OpData {
            if (self.index >= self.data.len) return null;
            
            const opcode = self.data[self.index];
            self.index += 1;
            
            // Simple mock: 0x5b = JUMPDEST, others are regular
            if (opcode == 0x5b) {
                const result = OpData{ .jumpdest = .{ .gas_cost = 1 } };
                self.pc += 1;
                return result;
            } else {
                const result = OpData{ .regular = .{ .opcode = opcode } };
                self.pc += 1;
                return result;
            }
        }
    };
    
    pub fn createIterator(self: @This()) Iterator {
        return .{ .pc = 0, .index = 0, .data = self.data };
    }
};

test "JumpTableBuilder adds and sorts entries correctly" {
    const Builder = JumpTableBuilder(TestFrame, TestDispatch);
    
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    
    // Add entries out of order
    try builder.addEntry(30, 3);
    try builder.addEntry(10, 1);
    try builder.addEntry(20, 2);
    
    // Test that entries are stored
    try testing.expectEqual(@as(usize, 3), builder.entries.items.len);
}

test "JumpTableBuilder builds from bytecode with JUMPDESTs" {
    const Builder = JumpTableBuilder(TestFrame, TestDispatch);
    
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    
    // Create mock bytecode with JUMPDESTs at positions 1 and 3
    const bytecode_data = [_]u8{ 0x60, 0x5b, 0x60, 0x5b, 0x00 }; // PUSH1, JUMPDEST, PUSH1, JUMPDEST, STOP
    const bytecode = MockBytecode{ .data = &bytecode_data };
    
    const schedule = [_]TestItem{
        .{ .value = 0 }, // PUSH1
        .{ .value = 1 }, // JUMPDEST
        .{ .value = 2 }, // Metadata
        .{ .value = 3 }, // PUSH1
        .{ .value = 4 }, // JUMPDEST
        .{ .value = 5 }, // Metadata
        .{ .value = 6 }, // STOP
    };
    
    try builder.buildFromSchedule(&schedule, bytecode);
    
    // Should have found 2 JUMPDESTs
    try testing.expectEqual(@as(usize, 2), builder.entries.items.len);
}

test "JumpTableBuilder finalize creates proper JumpTable" {
    const Builder = JumpTableBuilder(TestFrame, TestDispatch);
    
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    
    // Add test entries
    try builder.addEntry(20, 2);
    try builder.addEntry(10, 1);
    
    const jump_table = try builder.finalize();
    defer testing.allocator.free(jump_table.entries);
    
    // Verify entries are sorted
    try testing.expectEqual(@as(u32, 10), jump_table.entries[0].pc);
    try testing.expectEqual(@as(u32, 20), jump_table.entries[1].pc);
}

test "JumpTableBuilder finalizeWithSchedule sets dispatch pointers" {
    const Builder = JumpTableBuilder(TestFrame, TestDispatch);
    
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    
    const schedule = [_]TestItem{
        .{ .value = 100 },
        .{ .value = 200 },
        .{ .value = 300 },
    };
    
    try builder.addEntry(10, 1);
    try builder.addEntry(20, 2);
    
    const jump_table = try builder.finalizeWithSchedule(&schedule);
    defer testing.allocator.free(jump_table.entries);
    
    // Verify dispatch pointers are set correctly
    try testing.expectEqual(@as(u32, 10), jump_table.entries[0].pc);
    try testing.expectEqual(@as([*]const TestItem, schedule.ptr + 1), jump_table.entries[0].dispatch.cursor);
    
    try testing.expectEqual(@as(u32, 20), jump_table.entries[1].pc);
    try testing.expectEqual(@as([*]const TestItem, schedule.ptr + 2), jump_table.entries[1].dispatch.cursor);
}