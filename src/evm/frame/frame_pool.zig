const std = @import("std");
const Frame = @import("frame.zig");
const FrameFat = @import("frame_fat.zig");
const Vm = @import("../evm.zig");
const Contract = @import("contract.zig");
const primitives = @import("primitives");

/// Fixed-size pool for managing execution frames.
///
/// This pool provides index-based frame management to improve cache locality
/// and enable better memory management. Instead of using pointers, frames
/// reference each other using indices into this pool.
///
/// ## Design
/// - Fixed array of 1024 frames (matching EVM call depth limit)
/// - Frames are allocated/deallocated using indices
/// - Free list tracks available frame slots
/// - Zero-copy frame reuse between calls
///
/// ## Performance Benefits
/// - Better cache locality (all frames in contiguous memory)
/// - Predictable memory usage (no dynamic allocations during execution)
/// - Faster frame allocation (simple index manipulation)
/// - Easier serialization/debugging (indices vs pointers)
pub const FramePool = struct {
    const Self = @This();
    
    /// Maximum number of frames (matches EVM call depth limit)
    pub const MAX_FRAMES = 1024;
    
    /// Invalid frame index marker
    pub const INVALID_INDEX: u16 = 0xFFFF;
    
    /// Frame index type (u16 is sufficient for 1024 frames)
    pub const FrameIndex = u16;
    
    /// Pool of pre-allocated frames
    frames: [MAX_FRAMES]FrameFat,
    
    /// Tracks which frames are in use
    used_mask: std.StaticBitSet(MAX_FRAMES),
    
    /// Stack of free frame indices for O(1) allocation
    free_stack: std.BoundedArray(FrameIndex, MAX_FRAMES),
    
    /// Current active frame count
    active_count: u16,
    
    /// Memory allocator for frame internals
    allocator: std.mem.Allocator,
    
    /// Initialize a new frame pool.
    ///
    /// Pre-allocates all frames and initializes the free list.
    /// This is called once during VM initialization.
    pub fn init(allocator: std.mem.Allocator) !Self {
        var pool = Self{
            .frames = undefined,
            .used_mask = std.StaticBitSet(MAX_FRAMES).initEmpty(),
            .free_stack = try std.BoundedArray(FrameIndex, MAX_FRAMES).init(0),
            .active_count = 0,
            .allocator = allocator,
        };
        
        // Initialize free stack with all indices in reverse order
        // This way, we allocate from index 0 upward
        var i: FrameIndex = MAX_FRAMES;
        while (i > 0) {
            i -= 1;
            try pool.free_stack.append(i);
        }
        
        return pool;
    }
    
    /// Deinitialize the pool, cleaning up any remaining frames.
    pub fn deinit(self: *Self) void {
        // Clean up any active frames
        var iter = self.used_mask.iterator(.{});
        while (iter.next()) |idx| {
            self.frames[idx].deinit();
        }
    }
    
    /// Allocate a new frame from the pool.
    ///
    /// Returns the index of the allocated frame, or error if pool is exhausted.
    pub fn allocate(
        self: *Self,
        vm: *Vm,
        gas_limit: u64,
        contract: *Contract,
        caller: primitives.Address.Address,
        input: []const u8,
    ) !FrameIndex {
        // Check if we have free frames
        if (self.free_stack.len == 0) {
            return error.FramePoolExhausted;
        }
        
        // Pop a free index
        const idx = self.free_stack.pop();
        
        // Mark as used
        self.used_mask.set(idx);
        self.active_count += 1;
        
        // Initialize the frame at this index
        self.frames[idx] = try FrameFat.init(
            self.allocator,
            vm,
            gas_limit,
            contract,
            caller,
            input,
        );
        
        return idx;
    }
    
    /// Allocate a child frame that shares the parent's memory buffer.
    ///
    /// Used for CALL/DELEGATECALL operations to create nested execution contexts.
    pub fn allocate_child(
        self: *Self,
        parent_idx: FrameIndex,
        gas_limit: u64,
        contract: *Contract,
        caller: primitives.Address.Address,
        input: []const u8,
    ) !FrameIndex {
        // Validate parent index
        if (parent_idx >= MAX_FRAMES or !self.used_mask.isSet(parent_idx)) {
            return error.InvalidFrameIndex;
        }
        
        // Check if we have free frames
        if (self.free_stack.len == 0) {
            return error.FramePoolExhausted;
        }
        
        // Pop a free index
        const idx = self.free_stack.pop();
        
        // Mark as used
        self.used_mask.set(idx);
        self.active_count += 1;
        
        // Initialize as child frame
        self.frames[idx] = try FrameFat.init_child(
            &self.frames[parent_idx],
            gas_limit,
            contract,
            caller,
            input,
        );
        
        return idx;
    }
    
    /// Deallocate a frame back to the pool.
    ///
    /// Cleans up the frame and returns it to the free list.
    pub fn deallocate(self: *Self, idx: FrameIndex) void {
        // Validate index
        if (idx >= MAX_FRAMES or !self.used_mask.isSet(idx)) {
            return; // Invalid index, ignore
        }
        
        // Clean up the frame
        self.frames[idx].deinit();
        
        // Mark as free
        self.used_mask.unset(idx);
        self.active_count -= 1;
        
        // Return to free stack
        self.free_stack.append(idx) catch {
            // This should never fail as we're returning a previously allocated index
            unreachable;
        };
    }
    
    /// Get a frame by index.
    ///
    /// Returns null if the index is invalid or the frame is not allocated.
    pub fn get(self: *Self, idx: FrameIndex) ?*FrameFat {
        if (idx >= MAX_FRAMES or !self.used_mask.isSet(idx)) {
            return null;
        }
        return &self.frames[idx];
    }
    
    /// Get a frame by index (const version).
    pub fn get_const(self: *const Self, idx: FrameIndex) ?*const FrameFat {
        if (idx >= MAX_FRAMES or !self.used_mask.isSet(idx)) {
            return null;
        }
        return &self.frames[idx];
    }
    
    /// Get a frame by index, asserting it exists.
    ///
    /// Use this when you know the index is valid (e.g., during execution).
    pub inline fn get_unchecked(self: *Self, idx: FrameIndex) *FrameFat {
        std.debug.assert(idx < MAX_FRAMES);
        std.debug.assert(self.used_mask.isSet(idx));
        return &self.frames[idx];
    }
    
    /// Check if a frame index is valid and allocated.
    pub fn is_valid(self: *const Self, idx: FrameIndex) bool {
        return idx < MAX_FRAMES and self.used_mask.isSet(idx);
    }
    
    /// Get the current number of active frames.
    pub fn active_frames(self: *const Self) u16 {
        return self.active_count;
    }
    
    /// Get the number of available frames.
    pub fn available_frames(self: *const Self) u16 {
        return @intCast(self.free_stack.len);
    }
    
    /// Reset the pool, deallocating all frames.
    ///
    /// Used between transactions to ensure clean state.
    pub fn reset(self: *Self) void {
        // Clean up all active frames
        var iter = self.used_mask.iterator(.{});
        while (iter.next()) |idx| {
            self.frames[idx].deinit();
        }
        
        // Reset state
        self.used_mask = std.StaticBitSet(MAX_FRAMES).initEmpty();
        self.active_count = 0;
        
        // Reinitialize free stack
        self.free_stack.len = 0;
        var i: FrameIndex = MAX_FRAMES;
        while (i > 0) {
            i -= 1;
            self.free_stack.append(i) catch unreachable;
        }
    }
};

// Tests
test "FramePool init and deinit" {
    const allocator = std.testing.allocator;
    
    var pool = try FramePool.init(allocator);
    defer pool.deinit();
    
    try std.testing.expectEqual(@as(u16, 0), pool.active_frames());
    try std.testing.expectEqual(@as(u16, FramePool.MAX_FRAMES), pool.available_frames());
}

test "FramePool allocate and deallocate" {
    const allocator = std.testing.allocator;
    const Address = primitives.Address;
    
    var pool = try FramePool.init(allocator);
    defer pool.deinit();
    
    // Create a test VM and contract
    var memory_db = @import("../state/memory_database.zig").MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try Contract.init(allocator, &[_]u8{0x00}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    // Allocate a frame
    const idx = try pool.allocate(&vm, 1000000, &contract, Address.ZERO, &[_]u8{});
    try std.testing.expectEqual(@as(u16, 0), idx);
    try std.testing.expectEqual(@as(u16, 1), pool.active_frames());
    
    // Get the frame
    const frame = pool.get(idx);
    try std.testing.expect(frame != null);
    
    // Deallocate
    pool.deallocate(idx);
    try std.testing.expectEqual(@as(u16, 0), pool.active_frames());
    try std.testing.expectEqual(@as(u16, FramePool.MAX_FRAMES), pool.available_frames());
}

test "FramePool child frame allocation" {
    const allocator = std.testing.allocator;
    const Address = primitives.Address;
    
    var pool = try FramePool.init(allocator);
    defer pool.deinit();
    
    // Create test environment
    var memory_db = @import("../state/memory_database.zig").MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try Contract.init(allocator, &[_]u8{0x00}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    // Allocate parent frame
    const parent_idx = try pool.allocate(&vm, 1000000, &contract, Address.ZERO, &[_]u8{});
    
    // Allocate child frame
    const child_idx = try pool.allocate_child(parent_idx, 500000, &contract, Address.ZERO, &[_]u8{});
    try std.testing.expectEqual(@as(u16, 1), child_idx);
    try std.testing.expectEqual(@as(u16, 2), pool.active_frames());
    
    // Verify child shares parent's memory buffer
    const parent = pool.get_unchecked(parent_idx);
    const child = pool.get_unchecked(child_idx);
    try std.testing.expectEqual(parent.memory_buffer, child.memory_buffer);
    try std.testing.expect(!child.owns_memory);
    
    // Clean up in reverse order
    pool.deallocate(child_idx);
    pool.deallocate(parent_idx);
}

test "FramePool exhaustion" {
    const allocator = std.testing.allocator;
    const Address = primitives.Address;
    
    var pool = try FramePool.init(allocator);
    defer pool.deinit();
    
    // Create test environment
    var memory_db = @import("../state/memory_database.zig").MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try Contract.init(allocator, &[_]u8{0x00}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    // Allocate all frames
    var indices = std.ArrayList(FramePool.FrameIndex).init(allocator);
    defer indices.deinit();
    
    var i: usize = 0;
    while (i < FramePool.MAX_FRAMES) : (i += 1) {
        const idx = try pool.allocate(&vm, 1000, &contract, Address.ZERO, &[_]u8{});
        try indices.append(idx);
    }
    
    // Next allocation should fail
    try std.testing.expectError(error.FramePoolExhausted, pool.allocate(&vm, 1000, &contract, Address.ZERO, &[_]u8{}));
    
    // Clean up
    for (indices.items) |idx| {
        pool.deallocate(idx);
    }
}

test "FramePool reset" {
    const allocator = std.testing.allocator;
    const Address = primitives.Address;
    
    var pool = try FramePool.init(allocator);
    defer pool.deinit();
    
    // Create test environment
    var memory_db = @import("../state/memory_database.zig").MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try Contract.init(allocator, &[_]u8{0x00}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    // Allocate some frames
    _ = try pool.allocate(&vm, 1000, &contract, Address.ZERO, &[_]u8{});
    _ = try pool.allocate(&vm, 1000, &contract, Address.ZERO, &[_]u8{});
    _ = try pool.allocate(&vm, 1000, &contract, Address.ZERO, &[_]u8{});
    
    try std.testing.expectEqual(@as(u16, 3), pool.active_frames());
    
    // Reset pool
    pool.reset();
    
    try std.testing.expectEqual(@as(u16, 0), pool.active_frames());
    try std.testing.expectEqual(@as(u16, FramePool.MAX_FRAMES), pool.available_frames());
}