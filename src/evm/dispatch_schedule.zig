const std = @import("std");

/// RAII wrapper for dispatch schedule that automatically cleans up push pointers
pub fn DispatchSchedule(comptime FrameType: type, comptime DispatchType: type) type {
    return struct {
        const Self = @This();
        
        items: []DispatchType.Item,
        allocator: std.mem.Allocator,
        push_pointers: []const *FrameType.WordType = &.{},

        /// Create a dispatch schedule from a BuildOwned result
        pub fn fromOwned(allocator: std.mem.Allocator, owned: DispatchType.BuildOwned) Self {
            return Self{
                .items = owned.items,
                .allocator = allocator,
                .push_pointers = owned.push_pointers,
            };
        }

        /// Clean up the schedule including all heap-allocated push pointers
        pub fn deinit(self: *Self) void {
            // Free push pointers
            for (self.push_pointers) |ptr| {
                self.allocator.destroy(ptr);
            }
            if (self.push_pointers.len > 0) self.allocator.free(self.push_pointers);

            // Free schedule itself
            self.allocator.free(self.items);
        }

        /// Get a Dispatch instance pointing to the start of the schedule
        pub fn getDispatch(self: *const Self) DispatchType {
            return DispatchType{
                .cursor = self.items.ptr,
            };
        }
    };
}