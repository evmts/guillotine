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
const std = @import("std");
const builtin = @import("builtin");

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
        /// outermost frame's buffer is always kept.
        pub const nested_retain_limit = 256 * 1024;

        allocator: std.mem.Allocator,
        /// Buffers `[0..in_use]` belong to live frames; the rest are free.
        buffers: std.ArrayList(*std.ArrayList(u8)),
        in_use: usize,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, .buffers = .empty, .in_use = 0 };
        }

        pub fn deinit(self: *Self) void {
            for (self.buffers.items) |buffer| self.destroy(buffer);
            self.buffers.deinit(self.allocator);
            self.in_use = 0;
        }

        fn destroy(self: *Self, buffer: *std.ArrayList(u8)) void {
            std.heap.page_allocator.free(buffer.allocatedSlice());
            self.allocator.destroy(buffer);
        }

        /// Take an empty buffer whose capacity covers the whole memory limit.
        pub fn acquire(self: *Self) !*std.ArrayList(u8) {
            if (self.in_use == self.buffers.items.len) {
                const buffer = try self.allocator.create(std.ArrayList(u8));
                errdefer self.allocator.destroy(buffer);
                const mapping = try std.heap.page_allocator.alloc(u8, reserve);
                errdefer std.heap.page_allocator.free(mapping);
                buffer.* = std.ArrayList(u8).initBuffer(mapping);
                try self.buffers.append(self.allocator, buffer);
            }
            const buffer = self.buffers.items[self.in_use];
            self.in_use += 1;
            buffer.items.len = 0;
            return buffer;
        }

        /// Return a buffer to the pool. Returns false when the buffer did not come from
        /// this pool; the caller then owns its cleanup.
        pub fn release(self: *Self, buffer: *std.ArrayList(u8)) bool {
            var index = self.in_use;
            while (index > 0) {
                index -= 1;
                if (self.buffers.items[index] != buffer) continue;

                const last_in_use = self.in_use - 1;
                self.buffers.items[index] = self.buffers.items[last_in_use];
                self.buffers.items[last_in_use] = buffer;
                self.in_use = last_in_use;

                const touched = buffer.items.len;
                buffer.items.len = 0;
                if (last_in_use > 0 and touched > nested_retain_limit) {
                    const last = self.buffers.items.len - 1;
                    self.buffers.items[last_in_use] = self.buffers.items[last];
                    self.buffers.items.len = last;
                    self.destroy(buffer);
                }
                return true;
            }
            return false;
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
