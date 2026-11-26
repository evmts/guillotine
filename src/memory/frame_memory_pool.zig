//! Reusable backing buffers for frame memory.
//!
//! EVM memory only grows, and Solidity code never frees it, so a long-running frame
//! grows its memory thousands of times. Backing it with the per-call arena makes each
//! growth beyond capacity copy the whole memory into a new block.
//!
//! The pool instead reserves one address range per active call depth, large enough for
//! the configured memory limit. Physical pages are committed lazily by the OS as memory
//! is touched, so a reservation costs nothing until it is used. Growth never moves or
//! copies the buffer and never calls an allocator, and a released buffer keeps its
//! pages for the next frame at that depth.
//!
//! Resident memory is bounded three ways:
//! - `release` unmaps a nested buffer that touched more than `nested_retain_limit`.
//! - `release` keeps at most `max_retained_buffers` free buffers and unmaps the rest.
//! - `trim`, called at transaction end, returns to the OS the pages of a large kept
//!   buffer that the transaction just ended did not use (`madvise(MADV_DONTNEED)` on
//!   Linux, unmapping elsewhere). Pages the transaction did use stay resident, so a
//!   workload that needs the same memory every transaction never faults them back in;
//!   memory left by one unusually large transaction is returned after the next one.
const std = @import("std");
const builtin = @import("builtin");
const log = @import("../log.zig");

pub fn FrameMemoryPool(comptime memory_limit: usize) type {
    return struct {
        const Self = @This();

        /// Largest memory limit the pool reserves address space for.
        const max_reservable = 64 * 1024 * 1024;

        /// The pool needs lazily committed address space: a 64-bit target with an OS.
        /// Elsewhere frames fall back to arena-backed memory.
        pub const enabled = @sizeOf(usize) >= 8 and
            !builtin.cpu.arch.isWasm() and
            builtin.os.tag != .freestanding and
            builtin.os.tag != .windows and
            memory_limit <= max_reservable;

        /// Bytes reserved per buffer. Memory never exceeds `memory_limit`, so a buffer
        /// with this capacity never needs to grow.
        pub const reserve = std.mem.alignForward(usize, memory_limit + 1, 64 * 1024);

        /// A nested frame's buffer is unmapped on release when the frame touched more
        /// than this. It bounds the memory a deep call chain leaves resident. The
        /// outermost frame's buffer is kept until `trim`. `trim` also keeps this many
        /// leading bytes of a large buffer resident.
        pub const nested_retain_limit = 256 * 1024;

        /// Most free buffers kept after release. A deep call chain that unwinds
        /// unmaps every free buffer beyond this.
        pub const max_retained_buffers = 8;

        /// `trim` returns the pages of a kept buffer that touched more than this.
        pub const trim_threshold = 1024 * 1024;

        /// One reserved buffer.
        const Slot = struct {
            list: std.ArrayList(u8),
            /// Most bytes any frame has touched since the pages were last returned to
            /// the OS: an upper bound on what is resident.
            dirty: usize,
            /// Most bytes any frame has touched since the last `trim`: what the
            /// current transaction used.
            recent: usize,
        };

        allocator: std.mem.Allocator,
        /// Buffers `[0..in_use]` belong to live frames; the rest are free.
        buffers: std.ArrayList(*Slot),
        in_use: usize,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, .buffers = .empty, .in_use = 0 };
        }

        pub fn deinit(self: *Self) void {
            for (self.buffers.items) |slot| self.destroy(slot);
            self.buffers.deinit(self.allocator);
            self.in_use = 0;
        }

        /// Reserve `reserve` bytes of address space without touching them.
        ///
        /// This calls the page allocator's raw entry points. `Allocator.alloc` and
        /// `Allocator.free` fill the block with `undefined` (0xAA) in Debug and
        /// ReleaseSafe, which writes every page: each buffer would then commit its
        /// whole reservation when mapped and again when unmapped.
        fn map() ?[]u8 {
            const pointer = std.heap.page_allocator.rawAlloc(reserve, .of(u8), @returnAddress()) orelse return null;
            return pointer[0..reserve];
        }

        fn unmap(mapping: []u8) void {
            std.heap.page_allocator.rawFree(mapping, .of(u8), @returnAddress());
        }

        fn destroy(self: *Self, slot: *Slot) void {
            unmap(slot.list.allocatedSlice());
            self.allocator.destroy(slot);
        }

        /// Unmap the free buffer at `index`. Moves the last buffer into its place, so
        /// `index` must be at least `in_use`.
        fn destroyAt(self: *Self, index: usize) void {
            const slot = self.buffers.items[index];
            const last = self.buffers.items.len - 1;
            self.buffers.items[index] = self.buffers.items[last];
            self.buffers.items.len = last;
            self.destroy(slot);
        }

        /// Take an empty buffer whose capacity covers the whole memory limit.
        pub fn acquire(self: *Self) !*std.ArrayList(u8) {
            if (self.in_use == self.buffers.items.len) {
                const slot = try self.allocator.create(Slot);
                errdefer self.allocator.destroy(slot);
                const mapping = map() orelse return error.OutOfMemory;
                errdefer unmap(mapping);
                slot.* = .{ .list = std.ArrayList(u8).initBuffer(mapping), .dirty = 0, .recent = 0 };
                try self.buffers.append(self.allocator, slot);
            }
            const slot = self.buffers.items[self.in_use];
            self.in_use += 1;
            slot.list.items.len = 0;
            return &slot.list;
        }

        /// Return a buffer to the pool. Returns false when the buffer did not come from
        /// this pool; the caller then owns its cleanup.
        pub fn release(self: *Self, buffer: *std.ArrayList(u8)) bool {
            var index = self.in_use;
            while (index > 0) {
                index -= 1;
                const slot = self.buffers.items[index];
                if (&slot.list != buffer) continue;

                const last_in_use = self.in_use - 1;
                self.buffers.items[index] = self.buffers.items[last_in_use];
                self.buffers.items[last_in_use] = slot;
                self.in_use = last_in_use;

                const touched = buffer.items.len;
                buffer.items.len = 0;
                slot.dirty = @max(slot.dirty, touched);
                slot.recent = @max(slot.recent, touched);
                if (last_in_use > 0 and touched > nested_retain_limit) {
                    self.destroyAt(last_in_use);
                } else if (self.buffers.items.len - self.in_use > max_retained_buffers) {
                    // Unmap the last free buffer. It is never the outermost buffer at
                    // index 0 here, because more than one buffer is free.
                    self.destroyAt(self.buffers.items.len - 1);
                }
                return true;
            }
            return false;
        }

        /// Return the memory of large free buffers to the OS. Call at transaction end.
        ///
        /// The first free buffer (the outermost frame's, once every frame has returned)
        /// is kept. When it holds more than `trim_threshold` resident bytes, the pages
        /// past what the ending transaction touched (and past the first
        /// `nested_retain_limit` bytes) are released with `madvise(MADV_DONTNEED)` on
        /// Linux. When madvise is unavailable or fails, the buffer is unmapped instead,
        /// and the next `acquire` maps a fresh one. A buffer whose resident pages the
        /// transaction used in full is left alone: the next transaction of the same
        /// size reuses them without a page fault. Other free buffers that touched more
        /// than `nested_retain_limit` are unmapped. Live buffers are never touched.
        pub fn trim(self: *Self) void {
            var index = self.buffers.items.len;
            while (index > self.in_use) {
                index -= 1;
                const slot = self.buffers.items[index];
                const used = slot.recent;
                slot.recent = 0;
                if (index != self.in_use) {
                    if (slot.dirty > nested_retain_limit) self.destroyAt(index);
                    continue;
                }
                if (slot.dirty <= trim_threshold) continue;
                const keep = std.mem.alignForward(usize, @max(used, nested_retain_limit), std.heap.pageSize());
                if (slot.dirty <= keep) continue;
                if (!releasePages(slot, keep)) self.destroyAt(index);
            }
        }

        /// Drop the resident pages of `slot` from the page-aligned offset `keep` on.
        /// Returns false when the pages could not be released.
        fn releasePages(slot: *Slot, keep: usize) bool {
            if (comptime builtin.os.tag != .linux) return false;
            const mapping = slot.list.allocatedSlice();
            const end = @min(std.mem.alignForward(usize, slot.dirty, std.heap.pageSize()), mapping.len);
            if (end <= keep) return true;
            const first: [*]align(std.heap.page_size_min) u8 = @alignCast(mapping.ptr + keep);
            std.posix.madvise(first, end - keep, std.posix.MADV.DONTNEED) catch |err| {
                log.warn("Frame memory pool: madvise failed ({s}); unmapping the buffer", .{@errorName(err)});
                return false;
            };
            slot.dirty = keep;
            return true;
        }
    };
}

test "pool reuses buffers and keeps capacity for the whole memory limit" {
    const Pool = FrameMemoryPool(0xFFFFFF);
    if (!Pool.enabled) return;
    var pool = Pool.init(std.testing.allocator);
    defer pool.deinit();

    const outer = try pool.acquire();
    try std.testing.expect(outer.capacity >= 0xFFFFFF);
    try std.testing.expectEqual(@as(usize, 0), outer.items.len);
    outer.items.len = 64;
    @memset(outer.items, 0xAA);

    const inner = try pool.acquire();
    try std.testing.expect(inner != outer);
    try std.testing.expectEqual(@as(usize, 2), pool.in_use);

    try std.testing.expect(pool.release(inner));
    try std.testing.expect(pool.release(outer));
    try std.testing.expectEqual(@as(usize, 0), pool.in_use);

    const again = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 0), again.items.len);
    try std.testing.expect(again == outer or again == inner);
    try std.testing.expect(pool.release(again));
}

test "pool rejects foreign buffers and unmaps large nested buffers" {
    const Pool = FrameMemoryPool(0xFFFFFF);
    if (!Pool.enabled) return;
    var pool = Pool.init(std.testing.allocator);
    defer pool.deinit();

    var foreign = std.ArrayList(u8).empty;
    try std.testing.expect(!pool.release(&foreign));

    const outer = try pool.acquire();
    const inner = try pool.acquire();
    inner.items.len = Pool.nested_retain_limit + 32;
    try std.testing.expect(pool.release(inner));
    try std.testing.expectEqual(@as(usize, 1), pool.buffers.items.len);

    outer.items.len = Pool.nested_retain_limit + 32;
    try std.testing.expect(pool.release(outer));
    try std.testing.expectEqual(@as(usize, 1), pool.buffers.items.len);
}

test "pool keeps at most max_retained_buffers free buffers after a deep call chain" {
    const Pool = FrameMemoryPool(0xFFFFFF);
    if (!Pool.enabled) return;
    var pool = Pool.init(std.testing.allocator);
    defer pool.deinit();

    const depth = Pool.max_retained_buffers * 4;
    var live: [depth]*std.ArrayList(u8) = undefined;
    for (&live) |*buffer| buffer.* = try pool.acquire();
    try std.testing.expectEqual(@as(usize, depth), pool.buffers.items.len);
    live[0].items.len = 64;

    var index: usize = depth;
    while (index > 0) {
        index -= 1;
        try std.testing.expect(pool.release(live[index]));
        try std.testing.expect(pool.buffers.items.len - pool.in_use <= Pool.max_retained_buffers);
    }
    try std.testing.expectEqual(@as(usize, 0), pool.in_use);
    try std.testing.expectEqual(@as(usize, Pool.max_retained_buffers), pool.buffers.items.len);
    // The outermost buffer survives and is handed out first.
    try std.testing.expect(&pool.buffers.items[0].list == live[0]);
    try std.testing.expect(try pool.acquire() == live[0]);
}

test "trim keeps the pages a transaction used and releases them after a smaller one" {
    const Pool = FrameMemoryPool(0xFFFFFF);
    if (!Pool.enabled) return;
    var pool = Pool.init(std.testing.allocator);
    defer pool.deinit();

    // A large transaction: its pages stay resident through its own trim, so an
    // equally large next transaction reuses them without faulting.
    const outer = try pool.acquire();
    const touched = Pool.trim_threshold * 4;
    outer.items.len = touched;
    @memset(outer.items, 0xAA);
    try std.testing.expect(pool.release(outer));
    try std.testing.expectEqual(touched, pool.buffers.items[0].dirty);
    pool.trim();
    try std.testing.expectEqual(@as(usize, 1), pool.buffers.items.len);
    try std.testing.expectEqual(touched, pool.buffers.items[0].dirty);
    try std.testing.expectEqual(@as(usize, 0), pool.buffers.items[0].recent);

    const same_size = try pool.acquire();
    try std.testing.expect(same_size == outer);
    same_size.items.len = touched;
    try std.testing.expectEqual(@as(u8, 0xAA), same_size.items[touched - 1]);
    try std.testing.expect(pool.release(same_size));
    pool.trim();
    try std.testing.expectEqual(touched, pool.buffers.items[0].dirty);

    // A small transaction follows: the pages it did not use go back to the OS.
    const small = try pool.acquire();
    small.items.len = 64;
    try std.testing.expect(pool.release(small));
    pool.trim();

    if (builtin.os.tag == .linux) {
        // The buffer is kept, its interior pages were dropped, and the first
        // `nested_retain_limit` bytes stay resident.
        try std.testing.expectEqual(@as(usize, 1), pool.buffers.items.len);
        try std.testing.expect(&pool.buffers.items[0].list == outer);
        try std.testing.expect(pool.buffers.items[0].dirty <= std.mem.alignForward(usize, Pool.nested_retain_limit, std.heap.pageSize()));
        const again = try pool.acquire();
        try std.testing.expect(again == outer);
        again.items.len = touched;
        // MADV_DONTNEED on private anonymous memory reads back as zero.
        try std.testing.expectEqual(@as(u8, 0), again.items[touched - 1]);
        try std.testing.expectEqual(@as(u8, 0xAA), again.items[0]);
        again.items.len = 0;
        try std.testing.expect(pool.release(again));
    } else {
        // Without madvise the large buffer is unmapped.
        try std.testing.expectEqual(@as(usize, 0), pool.buffers.items.len);
        const fresh = try pool.acquire();
        try std.testing.expect(pool.release(fresh));
    }

    // A second trim with nothing large is a no-op.
    const count = pool.buffers.items.len;
    pool.trim();
    try std.testing.expectEqual(count, pool.buffers.items.len);
}

test "trim leaves live and small buffers alone and unmaps large extra free buffers" {
    const Pool = FrameMemoryPool(0xFFFFFF);
    if (!Pool.enabled) return;
    var pool = Pool.init(std.testing.allocator);
    defer pool.deinit();

    const live = try pool.acquire();
    live.items.len = Pool.trim_threshold * 2;
    const small = try pool.acquire();
    const big = try pool.acquire();
    small.items.len = 128;
    try std.testing.expect(pool.release(big));
    try std.testing.expect(pool.release(small));
    try std.testing.expectEqual(@as(usize, 1), pool.in_use);
    try std.testing.expectEqual(@as(usize, 3), pool.buffers.items.len);

    // Mark the extra free buffer as large, as if a frame had touched it before
    // the retain rule applied.
    for (pool.buffers.items[pool.in_use..]) |slot| {
        if (&slot.list == big) slot.dirty = Pool.nested_retain_limit + 1;
    }
    pool.trim();
    try std.testing.expectEqual(@as(usize, 1), pool.in_use);
    try std.testing.expectEqual(@as(usize, 2), pool.buffers.items.len);
    try std.testing.expect(&pool.buffers.items[0].list == live);
    try std.testing.expectEqual(Pool.trim_threshold * 2, live.items.len);
    try std.testing.expect(&pool.buffers.items[1].list == small);
    live.items.len = 0;
    try std.testing.expect(pool.release(live));
}

test "a deep call chain reserves address space without committing it" {
    const Pool = FrameMemoryPool(0xFFFFFF);
    if (!Pool.enabled) return;
    if (builtin.os.tag != .linux and !builtin.os.tag.isDarwin()) return;
    var pool = Pool.init(std.testing.allocator);
    defer pool.deinit();

    const depth = 64;
    const page = std.heap.pageSize();
    const residency = try std.testing.allocator.alloc(u8, Pool.reserve / page + 1);
    defer std.testing.allocator.free(residency);
    const faults_before = std.posix.getrusage(std.posix.rusage.SELF).minflt;

    var live: [depth]*std.ArrayList(u8) = undefined;
    for (&live) |*buffer| buffer.* = try pool.acquire();

    // No page of a fresh reservation is resident.
    var resident: usize = 0;
    for (live) |buffer| {
        const mapping = buffer.allocatedSlice();
        try std.testing.expectEqual(Pool.reserve, mapping.len);
        const pages = std.mem.alignForward(usize, mapping.len, page) / page;
        @memset(residency[0..pages], 0);
        try std.posix.mincore(@alignCast(mapping.ptr), mapping.len, residency.ptr);
        for (residency[0..pages]) |state| resident += state & 1;
    }
    try std.testing.expectEqual(@as(usize, 0), resident);

    // Each frame touches one word: one page per buffer becomes resident.
    for (live) |buffer| {
        buffer.items.len = 32;
        @memset(buffer.items, 0x5A);
    }
    var index: usize = depth;
    while (index > 0) {
        index -= 1;
        try std.testing.expect(pool.release(live[index]));
    }

    // Mapping, using and unmapping 64 buffers faults a few pages each, not the
    // 4096 pages of each 16 MiB reservation.
    const faults = std.posix.getrusage(std.posix.rusage.SELF).minflt - faults_before;
    try std.testing.expect(faults < depth * 32);
}
