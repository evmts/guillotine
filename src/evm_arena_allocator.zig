const std = @import("std");

/// A custom allocator that wraps ArenaAllocator with a configurable growth strategy.
/// This allocator preallocates memory and grows by a specified factor when more space is needed.
pub const GrowingArenaAllocator = struct {
    const Self = @This();

    /// The underlying arena allocator
    arena: std.heap.ArenaAllocator,
    /// The base allocator used by the arena
    base_allocator: std.mem.Allocator,
    /// Current capacity that we've preallocated
    current_capacity: usize,
    /// Initial capacity to start with
    initial_capacity: usize,
    /// Maximum capacity we'll retain when resetting (prevents unbounded growth)
    max_capacity: usize,
    /// Growth factor (as a percentage, e.g., 150 = 50% growth)
    growth_factor: u32,

    /// Initialize a new growing arena allocator
    /// @param base_allocator: The underlying allocator to use
    /// @param initial_capacity: Initial capacity to preallocate (also used as max retained capacity)
    /// @param growth_factor: Growth percentage (e.g., 150 = 50% growth)
    pub fn init(base_allocator: std.mem.Allocator, initial_capacity: usize, growth_factor: u32) !Self {
        return initWithMaxCapacity(base_allocator, initial_capacity, initial_capacity, growth_factor);
    }

    /// Initialize with separate initial and max capacities
    pub fn initWithMaxCapacity(base_allocator: std.mem.Allocator, initial_capacity: usize, max_capacity: usize, growth_factor: u32) !Self {
        var arena = std.heap.ArenaAllocator.init(base_allocator);
        errdefer arena.deinit();
        
        // Preallocate the initial capacity
        var actual_capacity = initial_capacity;
        if (initial_capacity > 0) {
            const initial_alloc = arena.allocator().alloc(u8, initial_capacity) catch |err| {
                // If we can't preallocate the requested capacity, start with 0
                actual_capacity = 0;
                return err;
            };
            _ = initial_alloc;
            _ = arena.reset(.retain_capacity);
        }

        return Self{
            .arena = arena,
            .base_allocator = base_allocator,
            .current_capacity = actual_capacity,
            .initial_capacity = initial_capacity,
            .max_capacity = max_capacity,
            .growth_factor = growth_factor,
        };
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

    /// Reset the arena while retaining capacity
    pub fn reset(self: *Self, mode: std.heap.ArenaAllocator.ResetMode) bool {
        return self.arena.reset(mode);
    }

    /// Reset the arena to initial capacity
    /// This frees all memory and then pre-allocates the initial capacity again
    pub fn resetToInitialCapacity(self: *Self) !void {
        // Free all memory
        _ = self.arena.reset(.free_all);
        
        // Pre-allocate initial capacity again
        if (self.initial_capacity > 0) {
            const initial_alloc = try self.arena.allocator().alloc(u8, self.initial_capacity);
            _ = initial_alloc;
            _ = self.arena.reset(.retain_capacity);
        }
        
        // Reset current capacity tracker
        self.current_capacity = self.initial_capacity;
    }

    /// Reset the arena while retaining capacity up to max_capacity limit
    /// This prevents unbounded memory growth while still being efficient
    pub fn resetRetainCapacity(self: *Self) !void {
        const current_actual_capacity = self.arena.queryCapacity();
        
        // If we've grown beyond our max limit, reset to max capacity
        if (current_actual_capacity > self.max_capacity) {
            // Free all memory first
            _ = self.arena.reset(.free_all);
            
            // Pre-allocate to max capacity
            if (self.max_capacity > 0) {
                const max_alloc = try self.arena.allocator().alloc(u8, self.max_capacity);
                _ = max_alloc;
                _ = self.arena.reset(.retain_capacity);
            }
            
            self.current_capacity = self.max_capacity;
        } else {
            // Within limits, just reset and retain
            _ = self.arena.reset(.retain_capacity);
            // Update our tracked capacity to reflect actual growth
            self.current_capacity = current_actual_capacity;
        }
    }

    /// Query the current capacity
    pub fn queryCapacity(self: *const Self) usize {
        return self.arena.queryCapacity();
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        
        // First, try to allocate with the current arena
        if (self.arena.allocator().rawAlloc(len, ptr_align, ret_addr)) |ptr| {
            @branchHint(.likely);
            return ptr;
        }
        
        // If allocation failed, we might need more space
        // Check if we need to grow the arena
        const current_used = self.arena.queryCapacity();
        if (current_used + len > self.current_capacity) {
            // Calculate new capacity with growth factor, respecting max limit
            var new_capacity = self.current_capacity;
            while (new_capacity < current_used + len) {
                new_capacity = (new_capacity * self.growth_factor) / 100;
                // Don't grow beyond max capacity during normal operation
                if (new_capacity > self.max_capacity) {
                    new_capacity = self.max_capacity;
                    break;
                }
            }
            
            // Try to preallocate more space
            const additional_capacity = new_capacity - self.current_capacity;
            if (additional_capacity > 0) {
                // Allocate a dummy block to force the arena to grow
                if (self.arena.allocator().alloc(u8, additional_capacity)) |dummy_alloc| {
                    _ = dummy_alloc;
                    self.current_capacity = new_capacity;
                } else |_| {
                    // If we can't grow, continue with current capacity
                    // The actual allocation attempt below may still succeed
                }
            }
        }
        
        // Try allocation again after potential growth
        return self.arena.allocator().rawAlloc(len, ptr_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.arena.allocator().rawResize(buf, buf_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        // Arena allocator doesn't actually free individual allocations
        self.arena.allocator().rawFree(buf, buf_align, ret_addr);
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

test "GrowingArenaAllocator basic functionality" {
    var gaa = try GrowingArenaAllocator.init(std.testing.allocator, 1024, 150);
    defer gaa.deinit();

    const alloc = gaa.allocator();
    
    // Test basic allocation
    const data1 = try alloc.alloc(u8, 100);
    data1[0] = 42;
    
    // Test larger allocation that might trigger growth
    const data2 = try alloc.alloc(u8, 2000);
    data2[0] = 43;
    
    // Verify data is still accessible
    try std.testing.expectEqual(@as(u8, 42), data1[0]);
    try std.testing.expectEqual(@as(u8, 43), data2[0]);
}

test "GrowingArenaAllocator growth strategy" {
    var gaa = try GrowingArenaAllocator.init(std.testing.allocator, 1000, 150);
    defer gaa.deinit();

    const alloc = gaa.allocator();
    
    // Initial capacity should be around 1000
    const initial_cap = gaa.queryCapacity();
    try std.testing.expect(initial_cap >= 1000);
    
    // Allocate enough to trigger growth
    _ = try alloc.alloc(u8, 1500);
    
    // Capacity should have grown by at least 50%
    const new_cap = gaa.queryCapacity();
    try std.testing.expect(new_cap >= 1500);
}

test "GrowingArenaAllocator max capacity limit" {
    // Create allocator with 1KB initial and 4KB max
    var gaa = try GrowingArenaAllocator.initWithMaxCapacity(std.testing.allocator, 1024, 4096, 150);
    defer gaa.deinit();

    const alloc = gaa.allocator();
    
    // Allocate enough to potentially grow beyond max capacity
    _ = try alloc.alloc(u8, 2048);
    _ = try alloc.alloc(u8, 2048);
    _ = try alloc.alloc(u8, 2048);
    
    // Arena should have grown beyond initial capacity
    const grown_cap = gaa.queryCapacity();
    try std.testing.expect(grown_cap > 1024);
    
    // Track capacity before reset
    const before_reset = grown_cap;
    
    // Reset with capacity retention
    try gaa.resetRetainCapacity();
    
    // After reset, if we were over max_capacity, we should have reset
    const reset_cap = gaa.queryCapacity();
    if (before_reset > 4096) {
        // Should have reset to approximately max_capacity
        // Allow some overhead as allocator may round up
        try std.testing.expect(reset_cap <= 4096 * 2);
    } else {
        // Should have retained the capacity
        try std.testing.expect(reset_cap >= before_reset);
    }
    
    // Verify our tracked capacity matches expected
    try std.testing.expect(gaa.current_capacity <= 4096 or gaa.current_capacity == before_reset);
}
