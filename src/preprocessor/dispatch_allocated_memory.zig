const std = @import("std");
const ArrayList = std.ArrayListAligned;

/// Manages heap-allocated memory for dispatch operations, particularly for large PUSH values
/// that don't fit in inline metadata (values > u64).
///
/// Tracks all allocated pointers to ensure proper cleanup and prevent memory leaks.
pub fn AllocatedMemory(comptime WordType: type) type {
    return struct {
        const Self = @This();

        pointers: ArrayList(*WordType, null),

        pub fn init() Self {
            return .{
                .pointers = ArrayList(*WordType, null).empty,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.pointers.items) |ptr| {
                allocator.destroy(ptr);
            }
            self.pointers.deinit(allocator);
        }
    };
}

test "AllocatedMemory tracks and frees allocated words without leaking" {
    const allocator = std.testing.allocator;
    var mem = AllocatedMemory(u256).init();
    defer mem.deinit(allocator);

    const p1 = try allocator.create(u256);
    errdefer allocator.destroy(p1);
    p1.* = 0x123456789abcdef0123456789abcdef0;
    try mem.pointers.append(allocator, p1);

    try std.testing.expectEqual(@as(usize, 1), mem.pointers.items.len);
    try std.testing.expectEqual(@as(u256, 0x123456789abcdef0123456789abcdef0), mem.pointers.items[0].*);
}
