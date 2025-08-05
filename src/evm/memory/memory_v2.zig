const std = @import("std");
const constants = @import("constants.zig");

/// Memory implementation for EVM execution contexts with type-safe ownership.
/// This design eliminates the owns_buffer boolean by using separate types
/// for owned and borrowed memory, providing compile-time ownership guarantees.

// Re-export error types and constants for convenience
pub const MemoryError = @import("errors.zig").MemoryError;
pub const INITIAL_CAPACITY = constants.INITIAL_CAPACITY;
pub const DEFAULT_MEMORY_LIMIT = constants.DEFAULT_MEMORY_LIMIT;
pub const calculate_num_words = constants.calculate_num_words;

/// Common memory operations interface shared by both owned and borrowed memory.
/// This allows code to work with either type through a common interface.
pub const MemoryInterface = union(enum) {
    owned: *OwnedMemory,
    borrowed: *BorrowedMemory,
    
    /// Get the context size for this memory instance
    pub fn context_size(self: MemoryInterface) usize {
        return switch (self) {
            .owned => |m| m.context_size(),
            .borrowed => |m| m.context_size(),
        };
    }
    
    /// Get expansion cost for new size
    pub fn get_expansion_cost(self: MemoryInterface, new_size: u64) u64 {
        return switch (self) {
            .owned => |m| m.get_expansion_cost(new_size),
            .borrowed => |m| m.get_expansion_cost(new_size),
        };
    }
    
    /// Ensure capacity for the given size
    pub fn ensure_context_capacity(self: MemoryInterface, size: usize) !void {
        return switch (self) {
            .owned => |m| m.ensure_context_capacity(size),
            .borrowed => |m| m.ensure_context_capacity(size),
        };
    }
    
    // Add other common operations as needed
};

/// Core memory state shared between owned and borrowed memory
const MemoryCore = struct {
    /// Memory checkpoint for child memory isolation
    my_checkpoint: usize,
    
    /// Maximum memory size limit
    memory_limit: u64,
    
    /// Reference to shared buffer for all memory contexts
    shared_buffer_ref: *std.ArrayList(u8),
    
    /// Memory allocator for dynamic allocations
    allocator: std.mem.Allocator,
    
    /// Cache for memory expansion gas cost calculations
    cached_expansion: struct {
        /// Last calculated memory size in bytes
        last_size: u64,
        /// Gas cost for the last calculated size
        last_cost: u64,
    } = .{ .last_size = 0, .last_cost = 0 },
};

/// Memory that owns its buffer and is responsible for cleanup.
/// This is created by init() and must call deinit() to free resources.
pub const OwnedMemory = struct {
    core: MemoryCore,
    
    /// Initialize owned memory with a new buffer
    pub fn init(
        allocator: std.mem.Allocator,
        initial_capacity: usize,
        memory_limit: u64,
    ) !OwnedMemory {
        const shared_buffer = try allocator.create(std.ArrayList(u8));
        errdefer allocator.destroy(shared_buffer);
        
        shared_buffer.* = std.ArrayList(u8).init(allocator);
        errdefer shared_buffer.deinit();
        try shared_buffer.ensureTotalCapacity(initial_capacity);

        return OwnedMemory{
            .core = .{
                .my_checkpoint = 0,
                .memory_limit = memory_limit,
                .shared_buffer_ref = shared_buffer,
                .allocator = allocator,
            },
        };
    }
    
    pub fn init_default(allocator: std.mem.Allocator) !OwnedMemory {
        return try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    }
    
    /// Clean up owned resources
    pub fn deinit(self: *OwnedMemory) void {
        self.core.shared_buffer_ref.deinit();
        self.core.allocator.destroy(self.core.shared_buffer_ref);
    }
    
    /// Create a borrowed child memory that shares this buffer
    pub fn create_child(self: *OwnedMemory, checkpoint: usize) BorrowedMemory {
        return BorrowedMemory{
            .core = .{
                .my_checkpoint = checkpoint,
                .memory_limit = self.core.memory_limit,
                .shared_buffer_ref = self.core.shared_buffer_ref,
                .allocator = self.core.allocator,
                .cached_expansion = .{ .last_size = 0, .last_cost = 0 },
            },
        };
    }
    
    /// Convert to interface for polymorphic usage
    pub fn to_interface(self: *OwnedMemory) MemoryInterface {
        return .{ .owned = self };
    }
    
    // Import method implementations
    pub usingnamespace MemoryOperations(@This(), "core");
};

/// Memory that borrows a buffer from another memory instance.
/// This has no cleanup responsibilities and cannot outlive the owner.
pub const BorrowedMemory = struct {
    core: MemoryCore,
    
    /// Create another borrowed child memory that shares the same buffer
    pub fn create_child(self: *BorrowedMemory, checkpoint: usize) BorrowedMemory {
        return BorrowedMemory{
            .core = .{
                .my_checkpoint = checkpoint,
                .memory_limit = self.core.memory_limit,
                .shared_buffer_ref = self.core.shared_buffer_ref,
                .allocator = self.core.allocator,
                .cached_expansion = .{ .last_size = 0, .last_cost = 0 },
            },
        };
    }
    
    /// Convert to interface for polymorphic usage
    pub fn to_interface(self: *BorrowedMemory) MemoryInterface {
        return .{ .borrowed = self };
    }
    
    // Import method implementations
    pub usingnamespace MemoryOperations(@This(), "core");
};

/// Mixin providing common memory operations for both owned and borrowed types
fn MemoryOperations(comptime Self: type, comptime core_field: []const u8) type {
    return struct {
        // Context operations
        pub fn context_size(self: *const Self) usize {
            const core = @field(self, core_field);
            return core.shared_buffer_ref.items.len -| core.my_checkpoint;
        }
        
        pub fn ensure_context_capacity(self: *Self, size: usize) !void {
            const core = &@field(self, core_field);
            const total_size = core.my_checkpoint + size;
            
            if (total_size > core.memory_limit) {
                return MemoryError.MemoryLimitExceeded;
            }
            
            if (total_size > core.shared_buffer_ref.items.len) {
                try ensure_context_capacity_slow(self, size);
            }
        }
        
        fn ensure_context_capacity_slow(self: *Self, size: usize) !void {
            const core = &@field(self, core_field);
            const required_size = core.my_checkpoint + size;
            try core.shared_buffer_ref.resize(required_size);
            @memset(core.shared_buffer_ref.items[core.my_checkpoint..], 0);
        }
        
        pub fn resize_context(self: *Self, new_size: usize) !void {
            const core = &@field(self, core_field);
            const total_size = core.my_checkpoint + new_size;
            
            if (total_size > core.memory_limit) {
                return MemoryError.MemoryLimitExceeded;
            }
            
            const old_len = core.shared_buffer_ref.items.len;
            try core.shared_buffer_ref.resize(total_size);
            
            if (total_size > old_len) {
                @memset(core.shared_buffer_ref.items[old_len..], 0);
            }
        }
        
        pub fn size(self: *const Self) u64 {
            return @intCast(self.context_size());
        }
        
        pub fn total_size(self: *const Self) usize {
            const core = @field(self, core_field);
            return core.shared_buffer_ref.items.len;
        }
        
        // Read operations
        pub fn get_u256(self: *const Self, offset: u64) u256 {
            const core = @field(self, core_field);
            const abs_offset = core.my_checkpoint + @as(usize, @intCast(offset));
            
            if (abs_offset + 32 <= core.shared_buffer_ref.items.len) {
                const bytes = core.shared_buffer_ref.items[abs_offset..][0..32];
                return std.mem.readInt(u256, bytes, .big);
            }
            
            // Handle partial reads with zero padding
            var result: u256 = 0;
            const available = core.shared_buffer_ref.items.len -| abs_offset;
            if (available > 0) {
                const copy_len = @min(available, 32);
                const src = core.shared_buffer_ref.items[abs_offset..][0..copy_len];
                
                var temp_buf: [32]u8 = [_]u8{0} ** 32;
                @memcpy(temp_buf[0..copy_len], src);
                result = std.mem.readInt(u256, &temp_buf, .big);
            }
            
            return result;
        }
        
        pub fn get_slice(self: *const Self, offset: u64, size: u64) []const u8 {
            const core = @field(self, core_field);
            const abs_offset = core.my_checkpoint + @as(usize, @intCast(offset));
            const end = abs_offset + @as(usize, @intCast(size));
            
            if (end <= core.shared_buffer_ref.items.len) {
                return core.shared_buffer_ref.items[abs_offset..end];
            }
            
            const available = core.shared_buffer_ref.items.len -| abs_offset;
            return if (available > 0) 
                core.shared_buffer_ref.items[abs_offset..][0..available] 
            else 
                &[_]u8{};
        }
        
        pub fn get_byte(self: *const Self, offset: u64) u8 {
            const core = @field(self, core_field);
            const abs_offset = core.my_checkpoint + @as(usize, @intCast(offset));
            
            if (abs_offset < core.shared_buffer_ref.items.len) {
                return core.shared_buffer_ref.items[abs_offset];
            }
            return 0;
        }
        
        // Write operations
        pub fn set_data(self: *Self, offset: u64, data: []const u8) !void {
            if (data.len == 0) return;
            
            const size_needed = offset + data.len;
            try self.ensure_context_capacity(@intCast(size_needed));
            
            const core = &@field(self, core_field);
            const abs_offset = core.my_checkpoint + @as(usize, @intCast(offset));
            @memcpy(core.shared_buffer_ref.items[abs_offset..][0..data.len], data);
        }
        
        pub fn set_data_bounded(self: *Self, offset: u64, data: []const u8, pad_len: u64) !void {
            const bounded_len = @min(data.len, pad_len);
            if (bounded_len == 0) return;
            
            const size_needed = offset + bounded_len;
            try self.ensure_context_capacity(@intCast(size_needed));
            
            const core = &@field(self, core_field);
            const abs_offset = core.my_checkpoint + @as(usize, @intCast(offset));
            @memcpy(
                core.shared_buffer_ref.items[abs_offset..][0..@intCast(bounded_len)], 
                data[0..@intCast(bounded_len)]
            );
        }
        
        pub fn set_u256(self: *Self, offset: u64, value: u256) !void {
            const size_needed = offset + 32;
            try self.ensure_context_capacity(@intCast(size_needed));
            
            const core = &@field(self, core_field);
            const abs_offset = core.my_checkpoint + @as(usize, @intCast(offset));
            std.mem.writeInt(u256, core.shared_buffer_ref.items[abs_offset..][0..32], value, .big);
        }
        
        // Slice operations
        pub fn slice(self: *Self, offset: u64, size: u64, dest: []u8) void {
            const slice_data = self.get_slice(offset, size);
            
            const copy_len = @min(slice_data.len, dest.len);
            if (copy_len > 0) {
                @memcpy(dest[0..copy_len], slice_data[0..copy_len]);
            }
            
            if (dest.len > copy_len) {
                @memset(dest[copy_len..], 0);
            }
        }
        
        // Gas cost calculation
        pub fn get_expansion_cost(self: *Self, new_size: u64) u64 {
            const core = &@field(self, core_field);
            const current_size = @as(u64, @intCast(self.context_size()));
            
            if (new_size <= current_size) {
                return 0;
            }
            
            const new_words = (new_size + 31) / 32;
            const current_words = (current_size + 31) / 32;
            
            // Use lookup table for small memory sizes
            if (new_words <= SMALL_MEMORY_LOOKUP_SIZE and current_words <= SMALL_MEMORY_LOOKUP_SIZE) {
                return SMALL_MEMORY_LOOKUP_TABLE[@intCast(new_words)] - SMALL_MEMORY_LOOKUP_TABLE[@intCast(current_words)];
            }
            
            // Check if we can use cached calculation
            if (new_size == core.cached_expansion.last_size) {
                const current_cost = if (current_size == 0) 0 else calculate_memory_total_cost(current_size);
                return core.cached_expansion.last_cost -| current_cost;
            }
            
            // Calculate new cost and update cache
            const new_cost = calculate_memory_total_cost(new_size);
            const current_cost = if (current_size == 0) 0 else calculate_memory_total_cost(current_size);
            const expansion_cost = new_cost - current_cost;
            
            core.cached_expansion.last_size = new_size;
            core.cached_expansion.last_cost = new_cost;
            
            return expansion_cost;
        }
    };
}

/// Lookup table for small memory sizes (0-4KB in 32-byte increments)
const SMALL_MEMORY_LOOKUP_SIZE = 128;
const SMALL_MEMORY_LOOKUP_TABLE = generate_memory_expansion_lut: {
    var table: [SMALL_MEMORY_LOOKUP_SIZE + 1]u64 = undefined;
    for (&table, 0..) |*cost, words| {
        const word_count = @as(u64, @intCast(words));
        cost.* = 3 * word_count + (word_count * word_count) / 512;
    }
    break :generate_memory_expansion_lut table;
};

/// Calculate total memory cost for a given size
inline fn calculate_memory_total_cost(size_bytes: u64) u64 {
    const words = (size_bytes + 31) / 32;
    return 3 * words + (words * words) / 512;
}

// Tests
test "owned and borrowed memory type safety" {
    const allocator = std.testing.allocator;
    
    // Create owned memory
    var owned = try OwnedMemory.init_default(allocator);
    defer owned.deinit();
    
    // Write some data
    try owned.set_u256(0, 0x1234);
    try std.testing.expectEqual(@as(u256, 0x1234), owned.get_u256(0));
    
    // Create borrowed child
    var borrowed = owned.create_child(32);
    
    // Borrowed memory can also read/write
    try borrowed.set_u256(0, 0x5678);
    try std.testing.expectEqual(@as(u256, 0x5678), borrowed.get_u256(0));
    
    // Original data is still there at different offset
    try std.testing.expectEqual(@as(u256, 0x1234), owned.get_u256(0));
    
    // No explicit cleanup needed for borrowed memory
}

test "memory interface polymorphism" {
    const allocator = std.testing.allocator;
    
    var owned = try OwnedMemory.init_default(allocator);
    defer owned.deinit();
    
    var borrowed = owned.create_child(0);
    
    // Both can be used through the interface
    const owned_interface = owned.to_interface();
    const borrowed_interface = borrowed.to_interface();
    
    // Test operations work through interface
    try std.testing.expectEqual(@as(usize, 0), owned_interface.context_size());
    try std.testing.expectEqual(@as(usize, 0), borrowed_interface.context_size());
    
    // Expansion cost calculation works
    try std.testing.expectEqual(@as(u64, 3), owned_interface.get_expansion_cost(32));
    try std.testing.expectEqual(@as(u64, 3), borrowed_interface.get_expansion_cost(32));
}

test "nested borrowed memory" {
    const allocator = std.testing.allocator;
    
    var owned = try OwnedMemory.init_default(allocator);
    defer owned.deinit();
    
    // Create chain of borrowed memories
    var borrowed1 = owned.create_child(0);
    var borrowed2 = borrowed1.create_child(32);
    var borrowed3 = borrowed2.create_child(64);
    
    // All share the same buffer but have different checkpoints
    try borrowed1.set_u256(0, 0x1111);
    try borrowed2.set_u256(0, 0x2222);
    try borrowed3.set_u256(0, 0x3333);
    
    // Each sees their own view
    try std.testing.expectEqual(@as(u256, 0x1111), borrowed1.get_u256(0));
    try std.testing.expectEqual(@as(u256, 0x2222), borrowed2.get_u256(0));
    try std.testing.expectEqual(@as(u256, 0x3333), borrowed3.get_u256(0));
}