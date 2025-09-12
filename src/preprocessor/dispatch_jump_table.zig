const std = @import("std");

/// Jump table functionality for dispatch operations
/// Creates jump table types for a given Frame type and Dispatch type
pub fn JumpTable(comptime FrameType: type, comptime DispatchType: type) type {
    const Self = DispatchType;

    // Performance note: JumpTable is a compact array of structs rather than a sparse bitmap. A sparse bitmap would provide O(1) lookups
    // But at the cost of cpu cache utilization. For the scale of how many jump destinations contracts have it is more performant to
    // Create a compact data structure where all to most of the items fit in a single cache line and can be quickly binary searched
    // 
    // Optimization: We use interpolated search to start at an estimated position based on the assumption that
    // JUMPDESTs are roughly evenly distributed through bytecode. This reduces average search iterations significantly
    // for large jump tables while maintaining O(log n) worst case performance
    return struct {
        /// Jump table entry for dynamic jumps
        pub const JumpTableEntry = struct {
            pc: FrameType.PcType,
            dispatch: Self,
        };

        entries: []const JumpTableEntry,

        /// Find the dispatch for a given PC using binary search with interpolated starting point
        pub fn findJumpTarget(self: @This(), target_pc: FrameType.PcType) ?Self {
            // Early return for empty table
            if (self.entries.len == 0) return null;
            
            // Quick check: if target is outside bounds, return early
            if (target_pc < self.entries[0].pc or target_pc > self.entries[self.entries.len - 1].pc) {
                return null;
            }
            
            var left: usize = 0;
            var right: usize = self.entries.len;
            
            // Interpolated search optimization: Start at the expected position
            // Since JUMPDESTs are roughly evenly distributed through bytecode,
            // we can estimate where the target_pc would be in our sorted array
            const max_pc = self.entries[self.entries.len - 1].pc;
            const min_pc = self.entries[0].pc;
            
            if (max_pc > min_pc) {
                // Calculate interpolated starting position
                const pc_range = max_pc - min_pc;
                const target_offset = target_pc - min_pc;
                const estimated_index = (target_offset * self.entries.len) / pc_range;
                
                // Start our search at the interpolated position
                // We'll expand outward from this point
                const start_idx = @min(estimated_index, self.entries.len - 1);
                
                // Check if we got lucky with our estimate
                if (self.entries[start_idx].pc == target_pc) {
                    return self.entries[start_idx].dispatch;
                }
                
                // Determine which direction to search based on our estimate
                if (self.entries[start_idx].pc < target_pc) {
                    left = start_idx + 1;
                } else {
                    right = start_idx;
                }
            }

            // Standard binary search from the adjusted bounds
            while (left < right) {
                const mid = left + (right - left) / 2;
                const entry = self.entries[mid];

                if (entry.pc == target_pc) return entry.dispatch;
                if (entry.pc < target_pc) {
                    left = mid + 1;
                } else {
                    right = mid;
                }
            }
            return null;
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
}

test "JumpTable handles empty entries" {
    const JumpTableType = JumpTable(TestFrame, TestDispatch);
    
    const entries = [_]JumpTableType.JumpTableEntry{};
    const jump_table = JumpTableType{ .entries = &entries };
    
    try testing.expect(jump_table.findJumpTarget(0) == null);
    try testing.expect(jump_table.findJumpTarget(100) == null);
}

test "JumpTable interpolated search optimization" {
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
    // The interpolated search should find these efficiently
    
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
    
    // Test exact interpolation hit (should return immediately)
    const result4 = jump_table.findJumpTarget(450); // Exactly at index 45
    try testing.expect(result4 != null);
    try testing.expectEqual(@as(usize, 0x1000 + 45 * 0x100), @intFromPtr(result4.?.cursor));
    
    // Test non-existent entries
    try testing.expect(jump_table.findJumpTarget(25) == null);
    try testing.expect(jump_table.findJumpTarget(505) == null);
    try testing.expect(jump_table.findJumpTarget(1000) == null); // Beyond max
    
    // Test boundary checks (early return optimization)
    try testing.expect(jump_table.findJumpTarget(0xFFFF) == null); // Way beyond max
    try testing.expect(jump_table.findJumpTarget(0) != null); // First element
    try testing.expect(jump_table.findJumpTarget(990) != null); // Last element
}