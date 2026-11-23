const std = @import("std");

/// Jump table functionality for dispatch operations
/// Creates jump table types for a given Frame type and Dispatch type
pub fn JumpTable(comptime FrameType: type, comptime DispatchType: type) type {
    const Self = DispatchType;

    const Cursor = @FieldType(Self, "cursor");

    return struct {
        /// Jump table entry for dynamic jumps
        pub const JumpTableEntry = struct {
            pc: FrameType.PcType,
            dispatch: Self,
        };

        entries: []const JumpTableEntry = &.{},
        /// Each slot is one plus the schedule index, with zero marking an invalid target.
        dense_indices: []const u32 = &.{},
        schedule_base: ?Cursor = null,

        pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.dense_indices);
            allocator.free(self.entries);
        }

        /// Check the full stack operand before narrowing it to a PC or dense index.
        pub inline fn findJumpTargetU256(self: *const @This(), dest: u256) ?Self {
            if (self.schedule_base) |base| {
                @branchHint(.likely);
                if (dest >= self.dense_indices.len) return null;
                const slot = self.dense_indices[@as(usize, @intCast(dest))];
                if (slot == 0) return null;
                return .{ .cursor = base + (slot - 1) };
            }

            if (dest > std.math.maxInt(FrameType.PcType)) return null;
            const entry = self.findEntry(@intCast(dest)) orelse return null;
            return entry.dispatch;
        }

        /// Find the handler cursor for a valid JUMPDEST PC.
        pub fn find_jump_target(self: *const @This(), target: FrameType.PcType) ?Cursor {
            if (self.schedule_base) |base| {
                @branchHint(.likely);
                if (target >= self.dense_indices.len) return null;
                const slot = self.dense_indices[@intCast(target)];
                if (slot == 0) return null;
                return base + (slot - 1);
            }

            const entry = self.findEntry(target) orelse return null;
            return entry.dispatch.cursor;
        }

        fn findEntry(self: *const @This(), target: FrameType.PcType) ?*const JumpTableEntry {
            var left: usize = 0;
            var right = self.entries.len;
            while (left < right) {
                const mid = left + ((right - left) >> 1);
                const entry = &self.entries[mid];
                if (entry.pc == target) return entry;
                if (entry.pc < target) {
                    left = mid + 1;
                } else {
                    right = mid;
                }
            }
            return null;
        }

        /// Find the dispatch for a given PC.
        pub inline fn findJumpTarget(self: @This(), target_pc: FrameType.PcType) ?Self {
            if (self.schedule_base != null) {
                const cursor = self.find_jump_target(target_pc) orelse return null;
                return .{ .cursor = cursor };
            }
            const entry = self.findEntry(target_pc) orelse return null;
            return entry.dispatch;
        }

        /// Find the PC for a given dispatch pointer
        /// This is used by tracers to determine the current PC when landing on a jump destination
        pub fn findPc(self: @This(), dispatch: Self) ?FrameType.PcType {
            // Linear search through entries to find matching dispatch
            // This is OK since jump tables are typically small and this is only called on jumps
            for (self.entries) |entry| {
                // Compare dispatch cursors
                if (@intFromPtr(entry.dispatch.cursor) == @intFromPtr(dispatch.cursor)) {
                    return entry.pc;
                }
            }
            return null;
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

const TestDispatch = struct {
    cursor: [*]const u8,
};

test "JumpTable dense lookup decodes the first schedule slot and rejects holes" {
    const JumpTableType = JumpTable(TestFrame, TestDispatch);
    const schedule = [_]u8{ 1, 2, 3, 4 };
    const indices = [_]u32{ 1, 0, 4 };
    const jump_table = JumpTableType{
        .schedule_base = &schedule,
        .dense_indices = &indices,
    };

    try testing.expectEqual(@as([*]const u8, &schedule), jump_table.find_jump_target(0).?);
    try testing.expect(jump_table.find_jump_target(1) == null);
    try testing.expectEqual(@as([*]const u8, &schedule) + 3, jump_table.findJumpTarget(2).?.cursor);
    try testing.expect(jump_table.find_jump_target(3) == null);
    try testing.expectEqual(@as([*]const u8, &schedule) + 3, jump_table.findJumpTargetU256(2).?.cursor);
    try testing.expect(jump_table.findJumpTargetU256(1) == null);
    try testing.expect(jump_table.findJumpTargetU256((@as(u256, 1) << 128) + 2) == null);
}

test "JumpTable binary search finds existing entries" {
    const JumpTableType = JumpTable(TestFrame, TestDispatch);
    
    // Create test entries
    const entries = [_]JumpTableType.JumpTableEntry{
        .{ .pc = 10, .dispatch = .{ .cursor = @as([*]const u8, @ptrFromInt(0x1000)) } },
        .{ .pc = 20, .dispatch = .{ .cursor = @as([*]const u8, @ptrFromInt(0x2000)) } },
        .{ .pc = 30, .dispatch = .{ .cursor = @as([*]const u8, @ptrFromInt(0x3000)) } },
        .{ .pc = 40, .dispatch = .{ .cursor = @as([*]const u8, @ptrFromInt(0x4000)) } },
    };
    
    const jump_table = JumpTableType{ .entries = &entries };
    
    // Test finding existing entries
    const result1 = jump_table.findJumpTarget(20);
    try testing.expect(result1 != null);
    try testing.expectEqual(@as(usize, 0x2000), @intFromPtr(result1.?.cursor));
    
    const result2 = jump_table.findJumpTarget(40);
    try testing.expect(result2 != null);
    try testing.expectEqual(@as(usize, 0x4000), @intFromPtr(result2.?.cursor));
}

test "JumpTable binary search returns null for non-existent entries" {
    const JumpTableType = JumpTable(TestFrame, TestDispatch);
    
    const entries = [_]JumpTableType.JumpTableEntry{
        .{ .pc = 10, .dispatch = .{ .cursor = @as([*]const u8, @ptrFromInt(0x1000)) } },
        .{ .pc = 30, .dispatch = .{ .cursor = @as([*]const u8, @ptrFromInt(0x3000)) } },
    };
    
    const jump_table = JumpTableType{ .entries = &entries };
    
    // Test searching for non-existent entries
    try testing.expect(jump_table.findJumpTarget(5) == null);
    try testing.expect(jump_table.findJumpTarget(20) == null);
    try testing.expect(jump_table.findJumpTarget(50) == null);
    try testing.expect(jump_table.findJumpTargetU256((@as(u256, 1) << 32) + 10) == null);
}

test "JumpTable handles empty entries" {
    const JumpTableType = JumpTable(TestFrame, TestDispatch);
    
    const entries = [_]JumpTableType.JumpTableEntry{};
    const jump_table = JumpTableType{ .entries = &entries };
    
    try testing.expect(jump_table.findJumpTarget(0) == null);
    try testing.expect(jump_table.findJumpTarget(100) == null);
}

test "JumpTable binary search across a large table" {
    const JumpTableType = JumpTable(TestFrame, TestDispatch);
    
    // Create a large table with evenly distributed PCs to test interpolation
    var entries: [100]JumpTableType.JumpTableEntry = undefined;
    for (0..100) |i| {
        entries[i] = .{
            .pc = @intCast(i * 10), // PCs at 0, 10, 20, ..., 990
            .dispatch = .{ .cursor = @as([*]const u8, @ptrFromInt(0x1000 + i * 0x100)) },
        };
    }
    
    const jump_table = JumpTableType{ .entries = &entries };
    
    // Test finding entries at various positions
    
    // Test near beginning
    const result1 = jump_table.findJumpTarget(20);
    try testing.expect(result1 != null);
    try testing.expectEqual(@as(usize, 0x1200), @intFromPtr(result1.?.cursor));
    
    // Test near middle
    const result2 = jump_table.findJumpTarget(500);
    try testing.expect(result2 != null);
    try testing.expectEqual(@as(usize, 0x1000 + 50 * 0x100), @intFromPtr(result2.?.cursor));
    
    // Test near end
    const result3 = jump_table.findJumpTarget(980);
    try testing.expect(result3 != null);
    try testing.expectEqual(@as(usize, 0x1000 + 98 * 0x100), @intFromPtr(result3.?.cursor));
    
    // Test an interior entry
    const result4 = jump_table.findJumpTarget(450); // Exactly at index 45
    try testing.expect(result4 != null);
    try testing.expectEqual(@as(usize, 0x1000 + 45 * 0x100), @intFromPtr(result4.?.cursor));
    
    // Test non-existent entries
    try testing.expect(jump_table.findJumpTarget(25) == null);
    try testing.expect(jump_table.findJumpTarget(505) == null);
    try testing.expect(jump_table.findJumpTarget(1000) == null); // Beyond max
    
    // Test boundary checks
    try testing.expect(jump_table.findJumpTarget(0xFFFF) == null); // Way beyond max
    try testing.expect(jump_table.findJumpTarget(0) != null); // First element
    try testing.expect(jump_table.findJumpTarget(990) != null); // Last element
}
