const std = @import("std");

/// Jump table functionality for dispatch operations
/// Creates jump table types for a given Frame type and Dispatch type
pub fn JumpTable(comptime FrameType: type, comptime DispatchType: type) type {
    const Self = DispatchType;

    // Performance note: JumpTable is a compact array of structs rather than a sparse bitmap.
    // A sparse bitmap would provide O(1) lookups at the cost of CPU cache utilization.
    // For contract jump table sizes, a compact cache-line-friendly array with binary search is faster.
    //
    // Optimization: We use interpolated search to start at an estimated position based on the assumption that
    // JUMPDESTs are roughly evenly distributed through bytecode. This reduces average search iterations significantly
    // for large jump tables while maintaining O(log n) worst case performance
    return struct {
        const CursorPtr = @FieldType(Self, "cursor");

        /// Jump table entry for dynamic jumps (legacy sorted-array representation)
        pub const JumpTableEntry = struct {
            pc: FrameType.PcType,
            dispatch: Self,
        };

        /// Compact 8-byte open-addressed hash bucket for O(1) dynamic JUMP lookup.
        pub const Bucket = extern struct {
            pc: u32,
            offset: u32,
        };

        pub const EMPTY_PC: u32 = std.math.maxInt(u32);
        pub const HASH_MULT: u32 = 0x9E3779B1;

        entries: []const JumpTableEntry = &.{},
        buckets: []const Bucket = &.{},
        schedule_base: ?CursorPtr = null,
        mask: usize = 0,
        shift: u5 = 0,

        /// Compute power-of-2 bucket count for `jumpdest_count` entries (<=50% load factor).
        pub fn bucketCapacity(jumpdest_count: usize) usize {
            if (jumpdest_count == 0) return 0;
            const needed = @max(jumpdest_count * 2, 4);
            return std.math.ceilPowerOfTwoAssert(usize, needed);
        }

        /// Populate `buckets` with `EMPTY_PC` and insert all `(pc, schedule_index)` pairs.
        pub fn initBuckets(
            buckets: []Bucket,
            schedule_base: CursorPtr,
            jumpdests: anytype,
        ) @This() {
            if (buckets.len == 0) {
                return .{ .entries = &.{}, .buckets = &.{}, .schedule_base = schedule_base, .mask = 0, .shift = 0 };
            }
            @memset(buckets, .{ .pc = EMPTY_PC, .offset = 0 });
            const mask = buckets.len - 1;
            const log2_cap: u6 = @intCast(@ctz(buckets.len));
            const shift: u5 = @intCast(32 - log2_cap);
            for (jumpdests) |jd| {
                const key: u32 = @intCast(jd.pc);
                var idx: usize = @intCast((key *% HASH_MULT) >> shift);
                while (buckets[idx].pc != EMPTY_PC) {
                    idx = (idx + 1) & mask;
                }
                buckets[idx] = .{ .pc = key, .offset = @intCast(jd.schedule_index) };
            }
            return .{
                .entries = &.{},
                .buckets = buckets,
                .schedule_base = schedule_base,
                .mask = mask,
                .shift = shift,
            };
        }

        /// Find the dispatch for a given PC: O(1) hash lookup when `buckets` is populated,
        /// falling back to binary search over `entries` for legacy/test tables.
        pub inline fn findJumpTarget(self: @This(), target_pc: FrameType.PcType) ?Self {
            if (self.buckets.len > 0) {
                const key: u32 = @intCast(target_pc);
                var idx: usize = @intCast((key *% HASH_MULT) >> self.shift);
                while (true) {
                    const b = self.buckets[idx];
                    if (b.pc == key) return Self{ .cursor = self.schedule_base.? + b.offset };
                    if (b.pc == EMPTY_PC) return null;
                    idx = (idx + 1) & self.mask;
                }
            }
            return self.findJumpTargetLegacy(target_pc);
        }

        fn findJumpTargetLegacy(self: @This(), target_pc: FrameType.PcType) ?Self {
            if (self.entries.len == 0) return null;
            if (target_pc < self.entries[0].pc or target_pc > self.entries[self.entries.len - 1].pc) {
                return null;
            }
            var left: usize = 0;
            var right: usize = self.entries.len;
            const has_frame_config = @hasField(FrameType, "frame_config");
            var loop_counter = if (has_frame_config)
                FrameType.frame_config.createLoopSafetyCounter().init(FrameType.frame_config.loop_quota orelse 0)
            else {};
            while (left < right) {
                if (has_frame_config) loop_counter.inc();
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
            if (self.buckets.len > 0) {
                const base = self.schedule_base orelse return null;
                const target_addr = @intFromPtr(dispatch.cursor);
                const base_addr = @intFromPtr(base);
                if (target_addr < base_addr) return null;
                const elem_size = @sizeOf(std.meta.Child(CursorPtr));
                const diff = target_addr - base_addr;
                if (diff % elem_size != 0) return null;
                const target_off = diff / elem_size;
                for (self.buckets) |b| {
                    if (b.pc != EMPTY_PC and b.offset == target_off) return @intCast(b.pc);
                }
                return null;
            }
            for (self.entries) |entry| {
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
