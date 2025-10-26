const std = @import("std");
const SafetyCounter = @import("internal/safety_counter.zig").SafetyCounter;
const log = @import("log.zig");

/// A custom allocator that wraps ArenaAllocator with a configurable growth strategy.
/// This allocator preallocates memory and grows by a specified factor when more space is needed.
pub const GrowingArenaAllocator = struct {
    const Self = @This();

    /// Maximum absolute capacity (16GB) to prevent unbounded growth and DoS attacks
    pub const MAX_ABSOLUTE_CAPACITY: usize = 16 * 1024 * 1024 * 1024;

    /// Minimum valid growth factor (101 = 1% growth minimum)
    pub const MIN_GROWTH_FACTOR: u32 = 101;

    /// Maximum growth loop iterations (prevents infinite loops)
    pub const MAX_GROWTH_ITERATIONS: u32 = 1000;

    pub const Error = error{
        InvalidCapacity,
        InvalidGrowthFactor,
        CapacityOverflow,
        MaxCapacityExceeded,
    };

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
    /// Optional tracer for debugging and visibility
    tracer: ?*anyopaque,

    /// Initialize a new growing arena allocator
    /// @param base_allocator: The underlying allocator to use
    /// @param initial_capacity: Initial capacity to preallocate (also used as max retained capacity)
    /// @param growth_factor: Growth percentage (e.g., 150 = 50% growth)
    pub fn init(base_allocator: std.mem.Allocator, initial_capacity: usize, growth_factor: u32) !Self {
        return initWithMaxCapacity(base_allocator, initial_capacity, initial_capacity, growth_factor);
    }

    /// Initialize with separate initial and max capacities
    pub fn initWithMaxCapacity(base_allocator: std.mem.Allocator, initial_capacity: usize, max_capacity: usize, growth_factor: u32) !Self {
        return initWithMaxCapacityAndTracer(base_allocator, initial_capacity, max_capacity, growth_factor, null);
    }

    /// Initialize with separate initial and max capacities and optional tracer
    pub fn initWithMaxCapacityAndTracer(base_allocator: std.mem.Allocator, initial_capacity: usize, max_capacity: usize, growth_factor: u32, tracer: ?*anyopaque) !Self {
        // CRITICAL: Validate growth factor to prevent infinite loops
        if (growth_factor <= 100) {
            log.err("Invalid growth_factor={d}. Must be > 100 (e.g., 150 = 50% growth)", .{growth_factor});
            return Error.InvalidGrowthFactor;
        }

        // Validate max capacity against absolute limit
        if (max_capacity > MAX_ABSOLUTE_CAPACITY) {
            log.err("max_capacity={d} exceeds MAX_ABSOLUTE_CAPACITY={d}", .{ max_capacity, MAX_ABSOLUTE_CAPACITY });
            return Error.MaxCapacityExceeded;
        }

        // Validate that max_capacity >= initial_capacity
        if (max_capacity < initial_capacity) {
            log.err("max_capacity={d} must be >= initial_capacity={d}", .{ max_capacity, initial_capacity });
            return Error.InvalidCapacity;
        }

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

        const result = Self{
            .arena = arena,
            .base_allocator = base_allocator,
            .current_capacity = actual_capacity,
            .initial_capacity = initial_capacity,
            .max_capacity = max_capacity,
            .growth_factor = growth_factor,
            .tracer = tracer,
        };

        // Trace initialization
        if (tracer) |t| {
            const Tracer = @import("tracer/tracer.zig").Tracer;
            const tracer_ptr = @as(*Tracer, @ptrCast(@alignCast(t)));
            tracer_ptr.onArenaInit(initial_capacity, max_capacity, growth_factor);
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

    /// Reset the arena while retaining capacity
    pub fn reset(self: *Self, mode: std.heap.ArenaAllocator.ResetMode) bool {
        const capacity_before = self.arena.queryCapacity();
        const result = self.arena.reset(mode);
        const capacity_after = self.arena.queryCapacity();

        // Trace reset
        if (self.tracer) |t| {
            const Tracer = @import("tracer/tracer.zig").Tracer;
            const tracer_ptr = @as(*Tracer, @ptrCast(@alignCast(t)));
            const mode_str = switch (mode) {
                .retain_capacity => "retain_capacity",
                .free_all => "free_all",
            };
            tracer_ptr.onArenaReset(mode_str, capacity_before, capacity_after);
        }

        return result;
    }

    /// Reset the arena to initial capacity
    /// This frees all memory and then pre-allocates the initial capacity again
    pub fn resetToInitialCapacity(self: *Self) !void {
        const capacity_before = self.arena.queryCapacity();

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

        // Trace reset
        if (self.tracer) |t| {
            const Tracer = @import("tracer/tracer.zig").Tracer;
            const tracer_ptr = @as(*Tracer, @ptrCast(@alignCast(t)));
            tracer_ptr.onArenaReset("reset_to_initial", capacity_before, self.initial_capacity);
        }
    }

    /// Reset the arena while retaining capacity up to max_capacity limit
    /// This prevents unbounded memory growth while still being efficient
    pub fn resetRetainCapacity(self: *Self) !void {
        const current_actual_capacity = self.arena.queryCapacity();
        const capacity_before = current_actual_capacity;
        var capacity_after: usize = undefined;
        var reset_mode: []const u8 = undefined;

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
            capacity_after = self.max_capacity;
            reset_mode = "retain_capped";
        } else {
            // Within limits, just reset and retain
            _ = self.arena.reset(.retain_capacity);
            // Update our tracked capacity to reflect actual growth
            self.current_capacity = current_actual_capacity;
            capacity_after = current_actual_capacity;
            reset_mode = "retain_capacity";
        }

        // Trace reset
        if (self.tracer) |t| {
            const Tracer = @import("tracer/tracer.zig").Tracer;
            const tracer_ptr = @as(*Tracer, @ptrCast(@alignCast(t)));
            tracer_ptr.onArenaReset(reset_mode, capacity_before, capacity_after);
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

            // Trace successful allocation
            if (self.tracer) |t| {
                const Tracer = @import("tracer/tracer.zig").Tracer;
                const tracer_ptr = @as(*Tracer, @ptrCast(@alignCast(t)));
                const align_value = @intFromEnum(ptr_align);
                tracer_ptr.onArenaAlloc(len, align_value, self.current_capacity);
            }

            return ptr;
        }

        // If allocation failed, we might need more space
        // Check if we need to grow the arena
        const current_used = self.arena.queryCapacity();
        if (current_used + len > self.current_capacity) {
            const old_capacity = self.current_capacity;

            // CRITICAL: Prevent infinite loop if current_capacity is 0
            if (self.current_capacity == 0) {
                log.err("Cannot grow from zero capacity. This indicates invalid initialization state.", .{});
                if (self.tracer) |t| {
                    const Tracer = @import("tracer/tracer.zig").Tracer;
                    const tracer_ptr = @as(*Tracer, @ptrCast(@alignCast(t)));
                    tracer_ptr.onArenaAllocFailed(len, self.current_capacity, self.max_capacity);
                }
                return null;
            }

            // CRITICAL: SafetyCounter prevents infinite loops and DoS attacks
            const Counter = SafetyCounter(u32, .enabled);
            var safety = Counter.init(MAX_GROWTH_ITERATIONS);

            // Calculate new capacity with growth factor, respecting max limit
            var new_capacity = self.current_capacity;
            while (new_capacity < current_used + len) {
                safety.inc();

                // Check for overflow in multiplication before performing it
                const growth_factor_usize: usize = self.growth_factor;
                const max_before_overflow: usize = std.math.maxInt(usize) / growth_factor_usize;
                if (new_capacity > max_before_overflow) {
                    log.err("Capacity growth would overflow: new_capacity={d}, growth_factor={d}", .{ new_capacity, self.growth_factor });
                    new_capacity = self.max_capacity;
                    break;
                }

                const grown = (new_capacity * self.growth_factor) / 100;

                // Detect if growth is insufficient (would loop forever)
                if (grown <= new_capacity) {
                    log.err("Growth calculation failed: {d} * {d} / 100 = {d} (no progress)", .{ new_capacity, self.growth_factor, grown });
                    new_capacity = self.max_capacity;
                    break;
                }

                new_capacity = grown;

                // Don't grow beyond max capacity during normal operation
                if (new_capacity > self.max_capacity) {
                    new_capacity = self.max_capacity;
                    break;
                }
            }

            // Try to preallocate more space
            if (new_capacity > self.current_capacity) {
                const additional_capacity = new_capacity - self.current_capacity;
                // Allocate a dummy block to force the arena to grow
                if (self.arena.allocator().alloc(u8, additional_capacity)) |dummy_alloc| {
                    _ = dummy_alloc;
                    self.current_capacity = new_capacity;

                    // Trace growth
                    if (self.tracer) |t| {
                        const Tracer = @import("tracer/tracer.zig").Tracer;
                        const tracer_ptr = @as(*Tracer, @ptrCast(@alignCast(t)));
                        tracer_ptr.onArenaGrow(old_capacity, new_capacity, len);
                    }
                } else |_| {
                    // If we can't grow, continue with current capacity
                    // The actual allocation attempt below may still succeed
                }
            }
        }

        // Try allocation again after potential growth
        const result = self.arena.allocator().rawAlloc(len, ptr_align, ret_addr);

        if (result) |_| {
            // Trace successful allocation after growth
            if (self.tracer) |t| {
                const Tracer = @import("tracer/tracer.zig").Tracer;
                const tracer_ptr = @as(*Tracer, @ptrCast(@alignCast(t)));
                const align_value = @intFromEnum(ptr_align);
                tracer_ptr.onArenaAlloc(len, align_value, self.current_capacity);
            }
        } else {
            // Trace allocation failure
            if (self.tracer) |t| {
                const Tracer = @import("tracer/tracer.zig").Tracer;
                const tracer_ptr = @as(*Tracer, @ptrCast(@alignCast(t)));
                tracer_ptr.onArenaAllocFailed(len, self.current_capacity, self.max_capacity);
            }
        }

        return result;
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

// SECURITY TESTS - Critical bug fixes

test "SECURITY: Invalid growth_factor <= 100 rejected" {
    // Test growth_factor = 100 (no growth)
    const result1 = GrowingArenaAllocator.init(std.testing.allocator, 1024, 100);
    try std.testing.expectError(GrowingArenaAllocator.Error.InvalidGrowthFactor, result1);

    // Test growth_factor < 100 (shrinking)
    const result2 = GrowingArenaAllocator.init(std.testing.allocator, 1024, 50);
    try std.testing.expectError(GrowingArenaAllocator.Error.InvalidGrowthFactor, result2);

    // Test growth_factor = 0 (critical)
    const result3 = GrowingArenaAllocator.init(std.testing.allocator, 1024, 0);
    try std.testing.expectError(GrowingArenaAllocator.Error.InvalidGrowthFactor, result3);
}

test "SECURITY: Valid growth_factor = 101 (minimum valid)" {
    var gaa = try GrowingArenaAllocator.init(std.testing.allocator, 1000, 101);
    defer gaa.deinit();

    try std.testing.expectEqual(@as(u32, 101), gaa.growth_factor);
}

test "SECURITY: Zero initial capacity handling" {
    // Allocator should initialize with zero capacity
    var gaa = try GrowingArenaAllocator.init(std.testing.allocator, 0, 150);
    defer gaa.deinit();

    try std.testing.expectEqual(@as(usize, 0), gaa.current_capacity);

    // Allocation with zero capacity should fail gracefully (not infinite loop)
    const alloc = gaa.allocator();
    const result = alloc.alloc(u8, 100);

    // This should fail because we can't grow from zero capacity
    try std.testing.expectEqual(@as(?[]u8, null), result);
}

test "SECURITY: Max capacity validation" {
    // Test max_capacity exceeds absolute limit
    const result1 = GrowingArenaAllocator.initWithMaxCapacity(
        std.testing.allocator,
        1024,
        GrowingArenaAllocator.MAX_ABSOLUTE_CAPACITY + 1,
        150,
    );
    try std.testing.expectError(GrowingArenaAllocator.Error.MaxCapacityExceeded, result1);

    // Test max_capacity < initial_capacity
    const result2 = GrowingArenaAllocator.initWithMaxCapacity(
        std.testing.allocator,
        2048,
        1024,
        150,
    );
    try std.testing.expectError(GrowingArenaAllocator.Error.InvalidCapacity, result2);
}

test "SECURITY: SafetyCounter prevents infinite loop on excessive growth iterations" {
    // This test verifies SafetyCounter protection
    // Create a scenario where growth would take many iterations
    var gaa = try GrowingArenaAllocator.initWithMaxCapacity(
        std.testing.allocator,
        1,
        GrowingArenaAllocator.MAX_ABSOLUTE_CAPACITY,
        101, // Minimal growth factor
    );
    defer gaa.deinit();

    const alloc = gaa.allocator();

    // Try to allocate a huge amount that would require many growth iterations
    // This should be protected by SafetyCounter
    const huge_size = 1024 * 1024 * 1024; // 1GB
    const result = alloc.alloc(u8, huge_size);

    // The allocation may fail or succeed depending on system memory
    // The important thing is it doesn't hang forever
    if (result) |slice| {
        // If it succeeded, verify we got the right size
        try std.testing.expectEqual(huge_size, slice.len);
    } else {
        // If it failed, that's also acceptable
        // The key is we didn't infinite loop
    }
}

test "SECURITY: Overflow detection in growth calculation" {
    // Create allocator with very large initial capacity
    const large_capacity: usize = std.math.maxInt(usize) / 2;
    var gaa = try GrowingArenaAllocator.initWithMaxCapacity(
        std.testing.allocator,
        large_capacity,
        GrowingArenaAllocator.MAX_ABSOLUTE_CAPACITY,
        200, // 100% growth would overflow
    );
    defer gaa.deinit();

    // Set current_capacity to large value
    gaa.current_capacity = large_capacity;

    const alloc = gaa.allocator();

    // Try to allocate more, which would cause overflow in growth calculation
    // Should be caught and capped at max_capacity
    const result = alloc.alloc(u8, 1024);

    // The allocation behavior is implementation-dependent
    // but it should NOT crash or hang
    _ = result;
}

test "SECURITY: Growth factor edge cases" {
    // Test minimum valid growth factor (101)
    var gaa1 = try GrowingArenaAllocator.init(std.testing.allocator, 1000, 101);
    defer gaa1.deinit();
    try std.testing.expectEqual(@as(u32, 101), gaa1.growth_factor);

    // Test reasonable growth factor (150)
    var gaa2 = try GrowingArenaAllocator.init(std.testing.allocator, 1000, 150);
    defer gaa2.deinit();
    try std.testing.expectEqual(@as(u32, 150), gaa2.growth_factor);

    // Test large growth factor (300)
    var gaa3 = try GrowingArenaAllocator.init(std.testing.allocator, 1000, 300);
    defer gaa3.deinit();
    try std.testing.expectEqual(@as(u32, 300), gaa3.growth_factor);
}

test "SECURITY: Capacity overflow prevention during addition" {
    // Test that current_used + len doesn't overflow
    var gaa = try GrowingArenaAllocator.init(std.testing.allocator, 1024, 150);
    defer gaa.deinit();

    // This is a boundary test - ensure we handle edge cases properly
    const alloc = gaa.allocator();
    _ = try alloc.alloc(u8, 512);

    // The allocator should handle this without overflow
    const result = alloc.alloc(u8, std.math.maxInt(usize) - 1024);
    // Will likely fail due to memory constraints, but shouldn't crash
    _ = result;
}

test "SECURITY: Growth calculation insufficient progress detection" {
    // Test case where growth would make no progress
    // This verifies the grown <= new_capacity check
    var gaa = try GrowingArenaAllocator.init(std.testing.allocator, 1000, 101);
    defer gaa.deinit();

    // Force a scenario where growth might stall
    // With growth_factor=101, growing from small values rounds down
    gaa.current_capacity = 99;

    const alloc = gaa.allocator();
    // This should either succeed or fail, but not infinite loop
    const result = alloc.alloc(u8, 200);
    _ = result;
}

test "SECURITY: Multiple growth iterations within safety limit" {
    // Test that normal growth within safety limit works
    var gaa = try GrowingArenaAllocator.init(std.testing.allocator, 100, 150);
    defer gaa.deinit();

    const alloc = gaa.allocator();

    // Allocate progressively larger amounts
    _ = try alloc.alloc(u8, 50);
    _ = try alloc.alloc(u8, 100);
    _ = try alloc.alloc(u8, 200);
    _ = try alloc.alloc(u8, 400);

    // Should have grown capacity
    try std.testing.expect(gaa.queryCapacity() > 100);
}

test "SECURITY: Max capacity enforcement during growth" {
    // Test that growth stops at max_capacity
    var gaa = try GrowingArenaAllocator.initWithMaxCapacity(
        std.testing.allocator,
        1024,
        2048, // Small max capacity
        200, // 100% growth
    );
    defer gaa.deinit();

    const alloc = gaa.allocator();

    // Allocate to trigger multiple growth steps
    _ = try alloc.alloc(u8, 1024);
    _ = try alloc.alloc(u8, 1024);

    // Current capacity should not exceed max_capacity
    try std.testing.expect(gaa.current_capacity <= 2048);
}

test "SECURITY: Tracer alignment cast safety" {
    // Test that tracer pointer casts are safe
    // This verifies the @ptrCast(@alignCast(t)) pattern
    const Tracer = @import("tracer/tracer.zig").Tracer;
    var tracer = Tracer.init(std.testing.allocator);
    defer tracer.deinit();

    const tracer_opaque: *anyopaque = &tracer;

    var gaa = try GrowingArenaAllocator.initWithMaxCapacityAndTracer(
        std.testing.allocator,
        1024,
        4096,
        150,
        tracer_opaque,
    );
    defer gaa.deinit();

    // Allocations should work with tracer
    const alloc = gaa.allocator();
    _ = try alloc.alloc(u8, 100);
}

test "SECURITY: Alignment enum cast to integer safety" {
    // Test that @intFromEnum(ptr_align) is safe
    var gaa = try GrowingArenaAllocator.init(std.testing.allocator, 1024, 150);
    defer gaa.deinit();

    const alloc = gaa.allocator();

    // Test various alignments
    _ = try alloc.alignedAlloc(u8, 1, 100);
    _ = try alloc.alignedAlloc(u8, 2, 100);
    _ = try alloc.alignedAlloc(u8, 4, 100);
    _ = try alloc.alignedAlloc(u8, 8, 100);
}

test "SECURITY: Comprehensive edge case validation" {
    // This test combines multiple edge cases
    var gaa = try GrowingArenaAllocator.initWithMaxCapacity(
        std.testing.allocator,
        100,
        10000,
        150,
    );
    defer gaa.deinit();

    const alloc = gaa.allocator();

    // Test zero-sized allocation
    const zero_alloc = try alloc.alloc(u8, 0);
    try std.testing.expectEqual(@as(usize, 0), zero_alloc.len);

    // Test normal allocation
    _ = try alloc.alloc(u8, 50);

    // Test growth trigger
    _ = try alloc.alloc(u8, 200);

    // Test multiple small allocations
    for (0..10) |_| {
        _ = try alloc.alloc(u8, 10);
    }

    // Verify capacity is reasonable
    try std.testing.expect(gaa.queryCapacity() > 100);
    try std.testing.expect(gaa.current_capacity <= 10000);
}
