const std = @import("std");

/// Jump table functionality for dispatch operations
/// Creates jump table types for a given Frame type and Dispatch type
pub fn JumpTable(comptime FrameType: type, comptime DispatchType: type) type {
    const Self = DispatchType;

    // The table is an open-addressed hash table of 8-byte buckets, `{ pc, offset }`,
    // probed linearly. A dynamic JUMP costs one multiply, one shift and, almost
    // always, one bucket read: no division and no search loop over a sorted array.
    //
    // It is the only record of the code's JUMPDESTs the schedule keeps. With at
    // most two thirds of the buckets in use it takes 12 to 24 bytes per JUMPDEST;
    // the sorted array it replaces took 16 bytes per JUMPDEST next to a second
    // 16-byte list of the same positions.
    return struct {
        const Table = @This();
        const CursorPtr = @FieldType(Self, "cursor");

        /// One bucket: a JUMPDEST's PC and the schedule index of its handler.
        pub const Bucket = extern struct {
            pc: u32,
            offset: u32,
        };

        /// `Bucket.pc` of an unused bucket. No JUMPDEST can have this PC: code that
        /// long is rejected before analysis (`insert` checks it again).
        pub const EMPTY_PC: u32 = std.math.maxInt(u32);
        /// Fibonacci hashing multiplier: 2^32 divided by the golden ratio.
        pub const HASH_MULT: u32 = 0x9E3779B1;

        pub const Error = error{ JumpTableFull, JumpDestOutOfRange, DuplicateJumpDest };

        /// Power-of-two bucket array; empty when the code has no JUMPDEST.
        buckets: []Bucket = &.{},
        /// First item of the schedule the offsets index.
        schedule_base: ?CursorPtr = null,
        /// Right shift that maps a 32-bit hash to a bucket index.
        shift: u5 = 0,
        /// Number of JUMPDESTs in the table.
        len: u32 = 0,

        /// A table without JUMPDESTs: every lookup misses.
        pub const empty: Table = .{};

        /// Number of buckets for `jumpdest_count` JUMPDESTs: a power of two that
        /// leaves at least one third of the buckets unused, so every probe sequence
        /// ends at an unused bucket.
        pub fn bucketCapacity(jumpdest_count: usize) usize {
            if (jumpdest_count == 0) return 0;
            const needed = @max(jumpdest_count + jumpdest_count / 2 + 1, 4);
            return std.math.ceilPowerOfTwoAssert(usize, needed);
        }

        /// An empty table over `buckets`, whose length is `bucketCapacity` of the
        /// number of JUMPDESTs that will be inserted.
        pub fn init(buckets: []Bucket, schedule_base: CursorPtr) Table {
            if (buckets.len == 0) return .{ .schedule_base = schedule_base };
            @memset(buckets, .{ .pc = EMPTY_PC, .offset = 0 });
            const log2_capacity: u6 = @intCast(@ctz(buckets.len));
            return .{
                .buckets = buckets,
                .schedule_base = schedule_base,
                .shift = @intCast(32 - log2_capacity),
                .len = 0,
            };
        }

        /// Allocate a table for `jumpdest_count` JUMPDESTs.
        pub fn create(allocator: std.mem.Allocator, jumpdest_count: usize, schedule_base: CursorPtr) std.mem.Allocator.Error!Table {
            const buckets = try allocator.alloc(Bucket, bucketCapacity(jumpdest_count));
            return init(buckets, schedule_base);
        }

        /// Free a table made by `create`.
        pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
            allocator.free(self.buckets);
            self.* = empty;
        }

        /// Number of JUMPDESTs in the table.
        pub fn count(self: Table) usize {
            return self.len;
        }

        /// Bytes of bucket storage the table holds.
        pub fn byteSize(self: Table) usize {
            return std.mem.sliceAsBytes(self.buckets).len;
        }

        inline fn slot(self: Table, key: u32) usize {
            return @intCast((key *% HASH_MULT) >> self.shift);
        }

        /// Record that the JUMPDEST at `pc` has its handler at `schedule_index`.
        pub fn insert(self: *Table, pc: FrameType.PcType, schedule_index: usize) Error!void {
            if (pc >= EMPTY_PC) return Error.JumpDestOutOfRange;
            const offset = std.math.cast(u32, schedule_index) orelse return Error.JumpDestOutOfRange;
            // One bucket must stay unused, or a miss would probe forever.
            if (@as(usize, self.len) + 1 >= self.buckets.len) return Error.JumpTableFull;
            const key: u32 = @intCast(pc);
            const mask = self.buckets.len - 1;
            var index = self.slot(key);
            while (self.buckets[index].pc != EMPTY_PC) : (index = (index + 1) & mask) {
                if (self.buckets[index].pc == key) return Error.DuplicateJumpDest;
            }
            self.buckets[index] = .{ .pc = key, .offset = offset };
            self.len += 1;
        }

        /// Schedule index of the JUMPDEST at `target_pc`, or null when there is none.
        pub inline fn findOffset(self: Table, target_pc: FrameType.PcType) ?u32 {
            if (self.buckets.len == 0) return null;
            if (target_pc >= EMPTY_PC) return null;
            const key: u32 = @intCast(target_pc);
            const mask = self.buckets.len - 1;
            var index = self.slot(key);
            // Ends at an unused bucket: `insert` keeps at least one.
            while (true) : (index = (index + 1) & mask) {
                const bucket = self.buckets[index];
                if (bucket.pc == key) return bucket.offset;
                if (bucket.pc == EMPTY_PC) return null;
            }
        }

        /// The dispatch of the JUMPDEST at `target_pc`, or null when `target_pc` is
        /// not a JUMPDEST.
        pub inline fn findJumpTarget(self: Table, target_pc: FrameType.PcType) ?Self {
            const offset = self.findOffset(target_pc) orelse return null;
            return Self{ .cursor = self.schedule_base.? + offset };
        }

        /// Find the PC for a given dispatch pointer
        /// This is used by tracers to determine the current PC when landing on a jump destination
        pub fn findPc(self: Table, dispatch: Self) ?FrameType.PcType {
            const base = self.schedule_base orelse return null;
            const target_addr = @intFromPtr(dispatch.cursor);
            const base_addr = @intFromPtr(base);
            if (target_addr < base_addr) return null;
            const item_size = @sizeOf(std.meta.Child(CursorPtr));
            const distance = target_addr - base_addr;
            if (distance % item_size != 0) return null;
            const target_offset = distance / item_size;
            for (self.buckets) |bucket| {
                if (bucket.pc != EMPTY_PC and bucket.offset == target_offset) return @intCast(bucket.pc);
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
    cursor: [*]const u64,
};

const TestTable = JumpTable(TestFrame, TestDispatch);

test "JumpTable finds every inserted JUMPDEST and nothing else" {
    var schedule: [64]u64 = @splat(0);
    var table = try TestTable.create(testing.allocator, 4, &schedule);
    defer table.deinit(testing.allocator);

    try table.insert(10, 1);
    try table.insert(20, 7);
    try table.insert(30, 9);
    try table.insert(40, 63);
    try testing.expectEqual(@as(usize, 4), table.count());

    try testing.expectEqual(@intFromPtr(&schedule[7]), @intFromPtr(table.findJumpTarget(20).?.cursor));
    try testing.expectEqual(@intFromPtr(&schedule[63]), @intFromPtr(table.findJumpTarget(40).?.cursor));
    try testing.expectEqual(@as(?u32, 1), table.findOffset(10));
    for ([_]u32{ 0, 5, 11, 19, 21, 50, 0xFFFF, std.math.maxInt(u32) }) |pc| {
        try testing.expect(table.findJumpTarget(pc) == null);
    }
}

test "JumpTable without JUMPDESTs allocates nothing and misses" {
    var schedule: [1]u64 = .{0};
    var table = try TestTable.create(testing.allocator, 0, &schedule);
    defer table.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), table.byteSize());
    try testing.expect(table.findJumpTarget(0) == null);
    try testing.expect(table.findJumpTarget(100) == null);
    try testing.expect(TestTable.empty.findJumpTarget(0) == null);
    try testing.expectError(TestTable.Error.JumpTableFull, table.insert(0, 0));
}

test "JumpTable dense table: a JUMPDEST at every PC" {
    const n = 5000;
    const schedule = try testing.allocator.alloc(u64, n * 2);
    defer testing.allocator.free(schedule);
    var table = try TestTable.create(testing.allocator, n, schedule.ptr);
    defer table.deinit(testing.allocator);

    for (0..n) |pc| try table.insert(@intCast(pc), pc * 2);
    for (0..n) |pc| try testing.expectEqual(@as(?u32, @intCast(pc * 2)), table.findOffset(@intCast(pc)));
    for (n..n + 2000) |pc| try testing.expect(table.findOffset(@intCast(pc)) == null);
    // At most two thirds of the buckets are in use and each is eight bytes.
    try testing.expect(table.count() * 3 <= table.buckets.len * 2);
    try testing.expect(table.byteSize() <= 24 * n);
}

test "JumpTable sparse table: PCs far apart and colliding" {
    var schedule: [8]u64 = @splat(0);
    const pcs = [_]u32{ 0, 1 << 8, 1 << 16, 1 << 24, (1 << 31) + 5, std.math.maxInt(u32) - 1 };
    var table = try TestTable.create(testing.allocator, pcs.len, &schedule);
    defer table.deinit(testing.allocator);
    for (pcs, 0..) |pc, index| try table.insert(pc, index);
    for (pcs, 0..) |pc, index| {
        try testing.expectEqual(@as(?u32, @intCast(index)), table.findOffset(pc));
        try testing.expect(table.findOffset(pc + 1) == null or std.mem.indexOfScalar(u32, &pcs, pc + 1) != null);
    }
}

test "JumpTable rejects duplicates, overflow and the reserved PC" {
    var schedule: [4]u64 = @splat(0);
    var table = try TestTable.create(testing.allocator, 2, &schedule);
    defer table.deinit(testing.allocator);
    try table.insert(3, 0);
    try testing.expectError(TestTable.Error.DuplicateJumpDest, table.insert(3, 1));
    try testing.expectError(TestTable.Error.JumpDestOutOfRange, table.insert(TestTable.EMPTY_PC, 1));
    try table.insert(4, 1);
    try table.insert(5, 2);
    try testing.expectError(TestTable.Error.JumpTableFull, table.insert(6, 3));
    try testing.expectEqual(@as(usize, 3), table.count());
}

test "JumpTable findPc maps a JUMPDEST cursor back to its PC" {
    var schedule: [16]u64 = @splat(0);
    var table = try TestTable.create(testing.allocator, 2, &schedule);
    defer table.deinit(testing.allocator);
    try table.insert(100, 4);
    try table.insert(200, 12);
    try testing.expectEqual(@as(?u32, 100), table.findPc(.{ .cursor = schedule[4..].ptr }));
    try testing.expectEqual(@as(?u32, 200), table.findPc(.{ .cursor = schedule[12..].ptr }));
    try testing.expect(table.findPc(.{ .cursor = schedule[5..].ptr }) == null);
}

test "JumpTable lookups match a linear reference for pseudo-random PCs" {
    var prng = std.Random.DefaultPrng.init(0x6a756d70);
    const random = prng.random();
    var reference: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer reference.deinit(testing.allocator);
    var schedule: [1]u64 = .{0};
    const n = 700;
    var table = try TestTable.create(testing.allocator, n, &schedule);
    defer table.deinit(testing.allocator);
    while (reference.count() < n) {
        const pc = random.uintLessThan(u32, 30_000);
        const entry = try reference.getOrPut(testing.allocator, pc);
        if (entry.found_existing) continue;
        entry.value_ptr.* = random.int(u32);
        try table.insert(pc, entry.value_ptr.*);
    }
    var pc: u32 = 0;
    while (pc < 30_100) : (pc += 1) {
        try testing.expectEqual(reference.get(pc), table.findOffset(pc));
    }
}
