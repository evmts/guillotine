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