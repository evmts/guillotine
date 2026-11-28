const std = @import("std");
const log = @import("log.zig");
const verified_ops = @import("core/verified_ops.zig");

/// An arena for one EVM call tree, with three sizes that mean different things:
///
/// - `initial_capacity`: bytes reserved by `init` and the size an oversized arena
///   is trimmed back to by `resetRetainCapacity`.
/// - `max_capacity`: the RETAIN limit. It bounds what `resetRetainCapacity` keeps
///   for the next call and how far the arena reserves ahead of demand. It is not
///   a limit on one call: a call may use more, and that memory is released at
///   the next reset.
/// - `MAX_ABSOLUTE_CAPACITY`: the HARD limit on the bytes served between two
///   resets. A request that would pass it, or whose size would overflow `usize`,
///   fails with `error.OutOfMemory`.
///
/// Growth between resets is `std.heap.ArenaAllocator`'s: a request that does not
/// fit takes a new block half again as large as the last one plus the request.
/// A request the backing allocator refuses fails as it is; nothing larger is
/// tried in its place and the arena keeps every block it already holds.
pub const GrowingArenaAllocator = struct {
    const Self = @This();

    /// Hard limit on the bytes served between two resets: 16 GiB, or a quarter of
    /// the address space on a target where 16 GiB is not a `usize`. Requests are
    /// checked against it before they reach `std.heap.ArenaAllocator`, whose node
    /// size arithmetic is unchecked.
    pub const MAX_ABSOLUTE_CAPACITY: usize = @min(16 * 1024 * 1024 * 1024, std.math.maxInt(usize) / 4);

    pub const Error = error{
        InvalidCapacity,
        MaxCapacityExceeded,
    };

    /// The underlying arena allocator
    arena: std.heap.ArenaAllocator,
    /// The base allocator used by the arena
    base_allocator: std.mem.Allocator,
    /// Capacity known to be reserved: refreshed at every reset and whenever the
    /// live bytes outgrow it.
    current_capacity: usize,
    /// Live bytes: requested since the last reset and not freed. Never exceeds
    /// `MAX_ABSOLUTE_CAPACITY`.
    used: usize,
    /// Bytes reserved by `init`; an oversized arena is trimmed back to this.
    initial_capacity: usize,
    /// Most capacity kept across `resetRetainCapacity` (the retain limit).
    max_capacity: usize,
    /// Optional tracer for debugging and visibility
    tracer: ?*anyopaque,

    /// An arena that reserves `initial_capacity` bytes and retains no more than
    /// that across `resetRetainCapacity`.
    pub fn init(base_allocator: std.mem.Allocator, initial_capacity: usize) !Self {
        return initWithMaxCapacity(base_allocator, initial_capacity, initial_capacity);
    }

    /// Initialize with separate initial and max (retained) capacities
    pub fn initWithMaxCapacity(base_allocator: std.mem.Allocator, initial_capacity: usize, max_capacity: usize) !Self {
        return initWithMaxCapacityAndTracer(base_allocator, initial_capacity, max_capacity, null);
    }

    /// Initialize with separate initial and max (retained) capacities and optional tracer
    pub fn initWithMaxCapacityAndTracer(
        base_allocator: std.mem.Allocator,
        initial_capacity: usize,
        max_capacity: usize,
        tracer: ?*anyopaque,
    ) !Self {
        if (max_capacity > MAX_ABSOLUTE_CAPACITY) {
            log.warn("max_capacity={d} exceeds MAX_ABSOLUTE_CAPACITY={d}", .{ max_capacity, MAX_ABSOLUTE_CAPACITY });
            return Error.MaxCapacityExceeded;
        }
        if (max_capacity < initial_capacity) {
            log.warn("max_capacity={d} must be >= initial_capacity={d}", .{ max_capacity, initial_capacity });
            return Error.InvalidCapacity;
        }

        var arena = std.heap.ArenaAllocator.init(base_allocator);
        errdefer arena.deinit();

        if (initial_capacity > 0) {
            _ = try arena.allocator().alloc(u8, initial_capacity);
            _ = arena.reset(.retain_capacity);
        }

        const result = Self{
            .arena = arena,
            .base_allocator = base_allocator,
            .current_capacity = arena.queryCapacity(),
            .used = 0,
            .initial_capacity = initial_capacity,
            .max_capacity = max_capacity,
            .tracer = tracer,
        };

        if (tracer) |t| {
            const Tracer = @import("tracer/tracer.zig").Tracer;
            const tracer_ptr = @as(*Tracer, @ptrCast(@alignCast(t)));
            tracer_ptr.onArenaInit(initial_capacity, max_capacity);
        }

        return result;
    }

    /// Deinitialize the allocator
    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    /// Get the allocator interface
    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = remap,
            },
        };
    }

    /// Reset the arena with one of `std.heap.ArenaAllocator`'s modes.
    pub fn reset(self: *Self, mode: std.heap.ArenaAllocator.ResetMode) bool {
        const capacity_before = self.arena.queryCapacity();
        const result = self.arena.reset(mode);
        const capacity_after = self.arena.queryCapacity();
        self.current_capacity = capacity_after;
        self.used = 0;

        const mode_name = switch (mode) {
            .retain_capacity => "retain_capacity",
            .retain_with_limit => "retain_with_limit",
            .free_all => "free_all",
        };
        self.traceReset(mode_name, capacity_before, capacity_after);
        return result;
    }

    /// Reset the arena to initial capacity
    /// This frees all memory and then pre-allocates the initial capacity again
    pub fn resetToInitialCapacity(self: *Self) !void {
        const capacity_before = self.arena.queryCapacity();

        _ = self.arena.reset(.free_all);
        self.current_capacity = 0;
        self.used = 0;

        if (self.initial_capacity > 0) {
            _ = try self.arena.allocator().alloc(u8, self.initial_capacity);
            _ = self.arena.reset(.retain_capacity);
        }
        self.current_capacity = self.arena.queryCapacity();
        self.traceReset("reset_to_initial", capacity_before, self.current_capacity);
    }

    /// Reset the arena for the next call.
    ///
    /// An arena within `max_capacity` keeps its capacity as it is, so a later
    /// reset does not touch the backing allocator. An arena that one call grew
    /// past `max_capacity` is trimmed back to `initial_capacity`: the retain
    /// limit says the grown block must go, and re-reserving the whole limit (64 MiB
    /// by default) for every EVM that once ran a large call would waste it.
    ///
    /// When the backing allocator can neither shrink the block in place nor
    /// provide a smaller one, the arena releases the memory instead and a small
    /// block is reserved again. The arena stays usable in every case; the next
    /// call allocates what it needs.
    pub fn resetRetainCapacity(self: *Self) void {
        const capacity_before = self.arena.queryCapacity();
        self.used = 0;
        if (capacity_before <= self.max_capacity) {
            @branchHint(.likely);
            // Within the limit: `retain_with_limit` only rewinds the arena.
            const kept = self.arena.reset(.{ .retain_with_limit = self.max_capacity });
            self.current_capacity = if (kept) capacity_before else self.arena.queryCapacity();
            self.traceReset(if (kept) "retain_with_limit" else "released", capacity_before, self.current_capacity);
            return;
        }
        self.trimToInitialCapacity(capacity_before);
    }

    /// Cold half of `resetRetainCapacity`: shrink an oversized arena.
    fn trimToInitialCapacity(self: *Self, capacity_before: usize) void {
        @branchHint(.cold);
        const trimmed = self.arena.reset(.{ .retain_with_limit = self.initial_capacity });
        var capacity_after = self.arena.queryCapacity();
        if (capacity_after == 0 and self.initial_capacity > 0) {
            // The oversized block could not shrink in place and was freed. Reserve a
            // small block that stays within max_capacity after ArenaAllocator's
            // rounding (1.5x plus its header), so later small calls reuse it.
            const safe_budget = self.max_capacity -| (@sizeOf(usize) * 4);
            const warm_target = @min(self.initial_capacity, safe_budget / 2);
            if (warm_target > 0) {
                if (self.arena.allocator().alloc(u8, warm_target)) |_| {
                    _ = self.arena.reset(.retain_capacity);
                    capacity_after = self.arena.queryCapacity();
                } else |err| {
                    log.debug("Arena warm re-seed skipped after release: {}", .{err});
                }
            }
        }
        self.current_capacity = capacity_after;
        self.traceReset(if (trimmed) "trimmed_to_initial" else "released", capacity_before, capacity_after);
    }

    /// Query the current capacity
    pub fn queryCapacity(self: *const Self) usize {
        return self.arena.queryCapacity();
    }

    /// Refresh `current_capacity` after a request outgrew it.
    fn noteGrowth(self: *Self, len: usize) void {
        @branchHint(.cold);
        const old_capacity = self.current_capacity;
        self.current_capacity = self.arena.queryCapacity();
        if (self.tracer) |t| {
            const Tracer = @import("tracer/tracer.zig").Tracer;
            const tracer_ptr = @as(*Tracer, @ptrCast(@alignCast(t)));
            tracer_ptr.onArenaGrow(old_capacity, self.current_capacity, len);
        }
    }

    fn traceReset(self: *Self, mode_name: []const u8, capacity_before: usize, capacity_after: usize) void {
        const t = self.tracer orelse return;
        const Tracer = @import("tracer/tracer.zig").Tracer;
        const tracer_ptr = @as(*Tracer, @ptrCast(@alignCast(t)));
        tracer_ptr.onArenaReset(mode_name, capacity_before, capacity_after);
    }

    fn traceAlloc(self: *Self, len: usize, ptr_align: std.mem.Alignment) void {
        const t = self.tracer orelse return;
        const Tracer = @import("tracer/tracer.zig").Tracer;
        const tracer_ptr = @as(*Tracer, @ptrCast(@alignCast(t)));
        tracer_ptr.onArenaAlloc(len, @backingInt(ptr_align), self.current_capacity);
    }

    fn traceAllocFailed(self: *Self, len: usize) void {
        @branchHint(.cold);
        const t = self.tracer orelse return;
        const Tracer = @import("tracer/tracer.zig").Tracer;
        const tracer_ptr = @as(*Tracer, @ptrCast(@alignCast(t)));
        tracer_ptr.onArenaAllocFailed(len, self.current_capacity, self.max_capacity);
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Checked: a `len` near maxInt(usize) is refused here, before any sum with it
        // can wrap in this allocator or in the arena under it.
        const used_after = verified_ops.checkedCapacityAdd(self.used, len, MAX_ABSOLUTE_CAPACITY) orelse {
            self.traceAllocFailed(len);
            return null;
        };
        // A failure here leaves the arena as it was: nothing larger is requested
        // in its place, and every block the arena holds stays owned by it.
        const ptr = self.arena.allocator().rawAlloc(len, ptr_align, ret_addr) orelse {
            self.traceAllocFailed(len);
            return null;
        };
        self.used = used_after;
        if (used_after > self.current_capacity) self.noteGrowth(len);
        self.traceAlloc(len, ptr_align);
        return ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (new_len <= buf.len) {
            if (!self.arena.allocator().rawResize(buf, buf_align, new_len, ret_addr)) return false;
            self.used -|= buf.len - new_len;
            return true;
        }
        const used_after = verified_ops.checkedCapacityAdd(self.used, new_len - buf.len, MAX_ABSOLUTE_CAPACITY) orelse
            return false;
        if (!self.arena.allocator().rawResize(buf, buf_align, new_len, ret_addr)) return false;
        self.used = used_after;
        return true;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        // The arena reclaims only its most recent allocation; `used` counts live bytes.
        self.arena.allocator().rawFree(buf, buf_align, ret_addr);
        self.used -|= buf.len;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_size: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = buf;
        _ = alignment;
        _ = new_size;
        _ = ret_addr;
        // Arena allocator doesn't support remapping
        return null;
    }
};

/// Backing allocator that counts every call that reaches it.
const CountingBacking = struct {
    child: std.mem.Allocator,
    allocations: usize = 0,
    resizes: usize = 0,
    frees: usize = 0,

    fn allocator(self: *CountingBacking) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = countAlloc, .resize = countResize, .remap = countRemap, .free = countFree } };
    }

    fn countAlloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *CountingBacking = @ptrCast(@alignCast(context));
        self.allocations += 1;
        return self.child.rawAlloc(len, alignment, return_address);
    }

    fn countResize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *CountingBacking = @ptrCast(@alignCast(context));
        self.resizes += 1;
        return self.child.rawResize(memory, alignment, new_len, return_address);
    }

    fn countRemap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *CountingBacking = @ptrCast(@alignCast(context));
        self.resizes += 1;
        return self.child.rawRemap(memory, alignment, new_len, return_address);
    }

    fn countFree(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *CountingBacking = @ptrCast(@alignCast(context));
        self.frees += 1;
        self.child.rawFree(memory, alignment, return_address);
    }
};

test "resetRetainCapacity: one oversized call, then small calls never reach the backing allocator" {
    const max_capacity = 64 * 1024;
    var counting = CountingBacking{ .child = std.testing.allocator };
    var gaa = try GrowingArenaAllocator.initWithMaxCapacity(counting.allocator(), 4096, max_capacity);
    defer gaa.deinit();

    // One transaction that needs far more than the arena may keep.
    const oversized = try gaa.allocator().alloc(u8, 5 * max_capacity);
    @memset(oversized, 0xAA);
    try std.testing.expect(gaa.queryCapacity() > max_capacity);

    gaa.resetRetainCapacity();
    const retained = gaa.queryCapacity();
    try std.testing.expect(retained <= max_capacity);
    try std.testing.expect(retained > 0);
    try std.testing.expectEqual(retained, gaa.current_capacity);

    // Ten small transactions: the capacity kept is at or below the limit, so no
    // reset frees and re-allocates it, and no allocation needs a new block.
    const allocations = counting.allocations;
    const resizes = counting.resizes;
    const frees = counting.frees;
    for (0..10) |round| {
        const bytes = try gaa.allocator().alloc(u8, 100 + round * 37);
        @memset(bytes, @truncate(round));
        const words = try gaa.allocator().alloc(u64, 16);
        @memset(words, round);
        gaa.resetRetainCapacity();
        try std.testing.expectEqual(retained, gaa.queryCapacity());
        try std.testing.expect(gaa.queryCapacity() <= max_capacity);
    }
    try std.testing.expectEqual(allocations, counting.allocations);
    try std.testing.expectEqual(resizes, counting.resizes);
    try std.testing.expectEqual(frees, counting.frees);
}

test "resetRetainCapacity: capacity within the limit is kept as it is" {
    var counting = CountingBacking{ .child = std.testing.allocator };
    var gaa = try GrowingArenaAllocator.initWithMaxCapacity(counting.allocator(), 1024, 1024 * 1024);
    defer gaa.deinit();

    // Grow to several blocks below the limit; the first reset merges them into one.
    for (0..8) |_| _ = try gaa.allocator().alloc(u8, 10_000);
    const used = gaa.queryCapacity();
    try std.testing.expect(used >= 80_000);
    try std.testing.expect(used <= 1024 * 1024);
    gaa.resetRetainCapacity();
    const retained = gaa.queryCapacity();
    try std.testing.expect(retained >= 80_000);
    try std.testing.expect(retained <= 1024 * 1024);

    // The same workload now fits the one block that was kept.
    const allocations = counting.allocations;
    for (0..5) |_| {
        for (0..8) |_| _ = try gaa.allocator().alloc(u8, 10_000);
        gaa.resetRetainCapacity();
        try std.testing.expectEqual(retained, gaa.queryCapacity());
    }
    try std.testing.expectEqual(allocations, counting.allocations);
}

test "GrowingArenaAllocator: serves requests and grows past its initial capacity" {
    var gaa = try GrowingArenaAllocator.init(std.testing.allocator, 1024);
    defer gaa.deinit();
    try std.testing.expect(gaa.queryCapacity() >= 1024);
    try std.testing.expectEqual(gaa.queryCapacity(), gaa.current_capacity);

    const first = try gaa.allocator().alloc(u8, 100);
    @memset(first, 0x11);
    const second = try gaa.allocator().alloc(u64, 400);
    @memset(second, 0x22);
    try std.testing.expectEqual(@as(u8, 0x11), first[99]);
    try std.testing.expect(gaa.queryCapacity() >= 100 + 400 * @sizeOf(u64));
    // The tracked capacity follows the growth and the live bytes are what was requested.
    try std.testing.expectEqual(gaa.queryCapacity(), gaa.current_capacity);
    try std.testing.expectEqual(@as(usize, 100 + 400 * @sizeOf(u64)), gaa.used);
}

test "GrowingArenaAllocator: init rejects inconsistent capacities" {
    try std.testing.expectError(
        GrowingArenaAllocator.Error.InvalidCapacity,
        GrowingArenaAllocator.initWithMaxCapacity(std.testing.allocator, 4096, 1024),
    );
    if (GrowingArenaAllocator.MAX_ABSOLUTE_CAPACITY < std.math.maxInt(usize)) {
        try std.testing.expectError(
            GrowingArenaAllocator.Error.MaxCapacityExceeded,
            GrowingArenaAllocator.initWithMaxCapacity(
                std.testing.allocator,
                1024,
                GrowingArenaAllocator.MAX_ABSOLUTE_CAPACITY + 1,
            ),
        );
    }
    var empty = try GrowingArenaAllocator.init(std.testing.allocator, 0);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.queryCapacity());
    const bytes = try empty.allocator().alloc(u8, 64);
    try std.testing.expectEqual(@as(usize, 64), bytes.len);
}

test "W3-11: a request near maxInt(usize) is refused without overflow and without reaching the backing allocator" {
    var counting = CountingBacking{ .child = std.testing.allocator };
    var gaa = try GrowingArenaAllocator.initWithMaxCapacity(counting.allocator(), 1024, 4096);
    defer gaa.deinit();
    _ = try gaa.allocator().alloc(u8, 512);

    const allocations = counting.allocations;
    const capacity = gaa.queryCapacity();
    const huge = [_]usize{
        std.math.maxInt(usize),
        std.math.maxInt(usize) - 1,
        std.math.maxInt(usize) - 511,
        std.math.maxInt(usize) - 512,
        std.math.maxInt(usize) / 2 + 1,
        GrowingArenaAllocator.MAX_ABSOLUTE_CAPACITY,
        GrowingArenaAllocator.MAX_ABSOLUTE_CAPACITY - 511,
    };
    for (huge) |len| {
        try std.testing.expectError(error.OutOfMemory, gaa.allocator().alloc(u8, len));
    }
    try std.testing.expectEqual(allocations, counting.allocations);
    try std.testing.expectEqual(capacity, gaa.queryCapacity());
    try std.testing.expectEqual(@as(usize, 512), gaa.used);

    // Growing an existing block by that much is refused the same way.
    const block = try gaa.allocator().alloc(u8, 16);
    try std.testing.expect(!gaa.allocator().resize(block, std.math.maxInt(usize) - 1));
    try std.testing.expectEqual(@as(usize, 528), gaa.used);

    // The arena still serves ordinary requests.
    const after = try gaa.allocator().alloc(u8, 2048);
    @memset(after, 0x7E);
}

test "W3-11: a request the backing allocator refuses fails once, leaks nothing and leaves the arena usable" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var counting = CountingBacking{ .child = failing.allocator() };
    var gaa = try GrowingArenaAllocator.initWithMaxCapacity(counting.allocator(), 1024, 1 << 20);
    defer gaa.deinit();

    const kept = try gaa.allocator().alloc(u8, 256);
    @memset(kept, 0xC3);
    const capacity = gaa.queryCapacity();
    const allocations = counting.allocations;
    const allocated_bytes = failing.allocated_bytes;

    // Every backing allocation fails from here on.
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, gaa.allocator().alloc(u8, 64 * 1024));
    // One refused request, not a second and larger one in its place.
    try std.testing.expectEqual(allocations + 1, counting.allocations);
    try std.testing.expectEqual(allocated_bytes, failing.allocated_bytes);
    try std.testing.expectEqual(capacity, gaa.queryCapacity());
    try std.testing.expectEqual(@as(usize, 256), gaa.used);

    // What was allocated before is intact.
    try std.testing.expectEqual(@as(u8, 0xC3), kept[0]);
    try std.testing.expectEqual(@as(u8, 0xC3), kept[255]);

    // Once the backing allocator recovers, so does the arena: small and large
    // requests are both served and the earlier block is still intact.
    failing.fail_index = std.math.maxInt(usize);
    const small = try gaa.allocator().alloc(u8, 128);
    @memset(small, 0x01);
    try std.testing.expectEqual(@as(usize, 256 + 128), gaa.used);
    const large = try gaa.allocator().alloc(u8, 64 * 1024);
    @memset(large, 0x02);
}

test "W3-11: every backing failure during growth leaves no leak" {
    var fail_index: usize = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var gaa = GrowingArenaAllocator.initWithMaxCapacity(failing.allocator(), 512, 4096) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        defer gaa.deinit();
        var size: usize = 256;
        while (size <= 64 * 1024) : (size *= 2) {
            const bytes = gaa.allocator().alloc(u8, size) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                break;
            };
            @memset(bytes, 0xEE);
        }
        gaa.resetRetainCapacity();
    }
}

test "W3-11: an arena grown past max_capacity is trimmed back to initial_capacity, not to max_capacity" {
    const initial_capacity = 4096;
    const max_capacity = 1024 * 1024;
    var gaa = try GrowingArenaAllocator.initWithMaxCapacity(std.testing.allocator, initial_capacity, max_capacity);
    defer gaa.deinit();

    const oversized = try gaa.allocator().alloc(u8, 3 * max_capacity);
    @memset(oversized, 0xAA);
    try std.testing.expect(gaa.queryCapacity() > max_capacity);

    gaa.resetRetainCapacity();
    const retained = gaa.queryCapacity();
    // Either the block shrank in place to initial_capacity or it was released and a
    // block of initial_capacity (plus the arena's rounding) was reserved again.
    try std.testing.expect(retained > 0);
    try std.testing.expect(retained <= 2 * initial_capacity);
    try std.testing.expectEqual(retained, gaa.current_capacity);
    try std.testing.expectEqual(@as(usize, 0), gaa.used);

    // The trimmed arena is stable: later small calls keep that capacity.
    for (0..4) |_| {
        _ = try gaa.allocator().alloc(u8, 512);
        gaa.resetRetainCapacity();
        try std.testing.expectEqual(retained, gaa.queryCapacity());
    }
}

test "W3-11: max_capacity is a retain limit, not a limit on one call" {
    var gaa = try GrowingArenaAllocator.initWithMaxCapacity(std.testing.allocator, 1024, 2048);
    defer gaa.deinit();
    // Four times the retain limit in one call succeeds.
    for (0..4) |_| {
        const bytes = try gaa.allocator().alloc(u8, 2048);
        @memset(bytes, 0x44);
    }
    try std.testing.expect(gaa.queryCapacity() > 2048);
    gaa.resetRetainCapacity();
    try std.testing.expect(gaa.queryCapacity() <= 2048);
}

test "W3-11: freed and shrunk blocks do not count against the hard limit" {
    var gaa = try GrowingArenaAllocator.init(std.testing.allocator, 4096);
    defer gaa.deinit();
    for (0..1000) |_| {
        const scratch = try gaa.allocator().alloc(u8, 1024);
        gaa.allocator().free(scratch);
    }
    try std.testing.expectEqual(@as(usize, 0), gaa.used);
    // The most recent block was reclaimed each time, so the arena never grew.
    try std.testing.expectEqual(gaa.current_capacity, gaa.queryCapacity());

    const block = try gaa.allocator().alloc(u8, 256);
    try std.testing.expect(gaa.allocator().resize(block, 64));
    try std.testing.expectEqual(@as(usize, 64), gaa.used);
    gaa.resetRetainCapacity();
    try std.testing.expectEqual(@as(usize, 0), gaa.used);
}

test "GrowingArenaAllocator: reset modes refresh the tracked capacity" {
    var gaa = try GrowingArenaAllocator.initWithMaxCapacity(std.testing.allocator, 1024, 8192);
    defer gaa.deinit();
    _ = try gaa.allocator().alloc(u8, 4000);
    try std.testing.expect(gaa.reset(.retain_capacity));
    try std.testing.expectEqual(gaa.queryCapacity(), gaa.current_capacity);
    try std.testing.expectEqual(@as(usize, 0), gaa.used);

    _ = try gaa.allocator().alloc(u8, 4000);
    try std.testing.expect(gaa.reset(.free_all));
    try std.testing.expectEqual(@as(usize, 0), gaa.queryCapacity());
    try std.testing.expectEqual(@as(usize, 0), gaa.current_capacity);

    try gaa.resetToInitialCapacity();
    try std.testing.expect(gaa.queryCapacity() >= 1024);
    try std.testing.expectEqual(gaa.queryCapacity(), gaa.current_capacity);
}
