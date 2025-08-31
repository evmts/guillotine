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