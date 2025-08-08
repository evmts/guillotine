const std = @import("std");
const constants = @import("constants.zig");
const builtin = @import("builtin");

/// Memory implementation for EVM execution contexts.
/// Generic over a config subset.
/// Config must have: word_type, small_memory_lookup_size
pub fn Memory(comptime config: anytype) type {
    const WordType = config.word_type;
    const SMALL_MEMORY_LOOKUP_SIZE_VAL = config.small_memory_lookup_size;
    
    return struct {
        const Self = @This();

        // Re-export error types and constants for convenience
        pub const MemoryError = @import("errors.zig").MemoryError;
        pub const INITIAL_CAPACITY = constants.INITIAL_CAPACITY;
        pub const DEFAULT_MEMORY_LIMIT = constants.DEFAULT_MEMORY_LIMIT;
        pub const calculate_num_words = constants.calculate_num_words;

        // Core memory struct fields optimized for cache locality and minimal padding
        /// Memory checkpoint for child memory isolation
        /// Frequently accessed during memory operations
        my_checkpoint: usize,

        /// Maximum memory size limit
        /// Used for bounds checking, frequently accessed
        memory_limit: u64,

        /// Reference to shared buffer for all memory contexts
        /// Frequently accessed for actual memory operations
        shared_buffer_ref: *std.ArrayList(u8),

        /// Memory allocator for dynamic allocations
        /// Less frequently accessed
        allocator: std.mem.Allocator,

        /// Whether this Memory instance owns the buffer
        /// Small bool field placed last to minimize padding
        owns_buffer: bool,

        /// Cache for memory expansion gas cost calculations
        /// Stores the last expansion calculation to avoid redundant quadratic computations
        cached_expansion: struct {
            /// Last calculated memory size in bytes
            last_size: u64,
            /// Gas cost for the last calculated size
            last_cost: u64,
        } = .{ .last_size = 0, .last_cost = 0 },

        /// Initializes the root Memory context that owns the shared buffer.
        /// This is the safe API that eliminates the undefined pointer footgun.
        pub fn init(
            allocator: std.mem.Allocator,
            initial_capacity: usize,
            memory_limit: u64,
        ) !Self {
    std.log.debug("Memory.init: Starting, initial_capacity={}, memory_limit={}", .{initial_capacity, memory_limit});
    
    std.log.debug("Memory.init: About to create shared_buffer", .{});
    const shared_buffer = try allocator.create(std.ArrayList(u8));
    errdefer allocator.destroy(shared_buffer);
    std.log.debug("Memory.init: Created shared_buffer ptr={*}", .{shared_buffer});
    
    std.log.debug("Memory.init: Initializing ArrayList", .{});
    shared_buffer.* = std.ArrayList(u8).init(allocator);
    errdefer shared_buffer.deinit();
    
    std.log.debug("Memory.init: About to ensureTotalCapacity({})", .{initial_capacity});
    try shared_buffer.ensureTotalCapacity(initial_capacity);
    std.log.debug("Memory.init: ensureTotalCapacity complete", .{});

            std.log.debug("Memory.init: Returning Memory struct", .{});
            return Self{
        .my_checkpoint = 0,
        .memory_limit = memory_limit,
        .shared_buffer_ref = shared_buffer,
        .allocator = allocator,
        .owns_buffer = true,
    };
}

        /// Creates a child Memory that shares the buffer with a different checkpoint.
        /// Child memory has a view of the shared buffer starting from its checkpoint.
        pub fn init_child_memory(self: *Self, checkpoint: usize) !Self {
            return Self{
        .my_checkpoint = checkpoint,
        .memory_limit = self.memory_limit,
        .shared_buffer_ref = self.shared_buffer_ref,
        .allocator = self.allocator,
        .owns_buffer = false,
    };
}

        pub fn init_default(allocator: std.mem.Allocator) !Self {
    std.log.debug("Memory.init_default: Called with allocator={*}", .{allocator.ptr});
    const result = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    std.log.debug("Memory.init_default: Returning", .{});
    return result;
}

        /// Deinitializes the Memory. Only root Memory instances clean up the shared buffer.
        pub fn deinit(self: *Self) void {
    if (self.owns_buffer) {
        self.shared_buffer_ref.deinit();
        self.allocator.destroy(self.shared_buffer_ref);
    }
}

        // Import and re-export all method implementations
        const context_ops = @import("context.zig");
        const read_ops = @import("read.zig");
        const write_ops = @import("write.zig");
        const slice_ops = @import("slice.zig");

        // Context operations
        pub const context_size = context_ops.context_size;
        pub const ensure_context_capacity = context_ops.ensure_context_capacity;
        pub const ensure_context_capacity_slow = context_ops.ensure_context_capacity_slow;
        pub const resize_context = context_ops.resize_context;
        pub const size = context_ops.size;
        pub const total_size = context_ops.total_size;

        /// Clear the memory by resetting size to 0 (for call frame reuse)
        pub fn clear(self: *Self) void {
    // For shared buffer memory, we can't actually clear the buffer
    // since other contexts might be using it. Instead we reset our checkpoint
    // to the current buffer end, effectively giving us a "fresh" view
    if (self.owns_buffer) {
        // If we own the buffer, we can actually clear it
        self.shared_buffer_ref.items.len = 0;
    } else {
        // If we don't own the buffer, reset our checkpoint to current end
        // This effectively gives us a clean slate from this point forward
        self.my_checkpoint = self.shared_buffer_ref.items.len;
    }
    
    // Reset cached expansion calculations
    self.cached_expansion = .{ .last_size = 0, .last_cost = 0 };
}

        // Read operations - need to be generic aware
        pub fn get_word(self: *const Self, relative_offset: usize) MemoryError!WordType {
            if (relative_offset + @sizeOf(WordType) > self.context_size()) {
                return MemoryError.InvalidOffset;
            }
            const abs_offset = self.my_checkpoint + relative_offset;
            const bytes = self.shared_buffer_ref.items[abs_offset .. abs_offset + @sizeOf(WordType)];
            return std.mem.readInt(WordType, bytes[0..@sizeOf(WordType)], .big);
        }
        
        pub const get_u256 = get_word; // Alias for backward compatibility
        pub const get_slice = read_ops.get_slice;
        pub const get_byte = read_ops.get_byte;

        // Write operations - need to be generic aware
        pub fn set_word(self: *Self, relative_offset: usize, value: WordType) MemoryError!void {
            _ = try self.ensure_context_capacity(relative_offset + @sizeOf(WordType));
            const abs_offset = self.my_checkpoint + relative_offset;
            const bytes_ptr: *[@sizeOf(WordType)]u8 = @ptrCast(self.shared_buffer_ref.items[abs_offset..abs_offset + @sizeOf(WordType)].ptr);
            std.mem.writeInt(WordType, bytes_ptr, value, .big);
        }
        
        pub const set_u256 = set_word; // Alias for backward compatibility
        pub const set_data = write_ops.set_data;
        pub const set_data_bounded = write_ops.set_data_bounded;

        // Slice operations
        pub const slice = slice_ops.slice;

        /// Lookup table for small memory sizes (0-4KB in 32-byte increments)
        /// Provides O(1) access for common small memory allocations
        const SMALL_MEMORY_LOOKUP_TABLE = generate_memory_expansion_lut: {
            var table: [SMALL_MEMORY_LOOKUP_SIZE_VAL + 1]u64 = undefined;
            for (&table, 0..) |*cost, words| {
                const word_count = @as(u64, @intCast(words));
                cost.* = 3 * word_count + (word_count * word_count) / 512;
            }
            break :generate_memory_expansion_lut table;
        };

        /// Get memory expansion gas cost with caching optimization
        /// Returns the gas cost for expanding memory from current size to new_size.
        /// Uses lookup table for small sizes and cached values for larger sizes.
        pub fn get_expansion_cost(self: *Self, new_size: u64) u64 {
    const current_size = @as(u64, @intCast(self.context_size()));
    
    // No expansion needed if new size is not larger than current
    if (new_size <= current_size) {
        return 0;
    }
    
    const new_words = (new_size + 31) / 32;
    const current_words = (current_size + 31) / 32;
    
            // Use lookup table for small memory sizes
            if (new_words <= SMALL_MEMORY_LOOKUP_SIZE_VAL and current_words <= SMALL_MEMORY_LOOKUP_SIZE_VAL) {
        return SMALL_MEMORY_LOOKUP_TABLE[@intCast(new_words)] - SMALL_MEMORY_LOOKUP_TABLE[@intCast(current_words)];
    }
    
    // Check if we can use cached calculation for larger sizes
    if (new_size == self.cached_expansion.last_size) {
        // Return cached cost minus cost for current size
        const current_cost = if (current_size == 0) 0 else calculate_memory_total_cost(current_size);
        return self.cached_expansion.last_cost -| current_cost;
    }
    
    // Calculate new cost and update cache for larger sizes
    const new_cost = calculate_memory_total_cost(new_size);
    const current_cost = if (current_size == 0) 0 else calculate_memory_total_cost(current_size);
    const expansion_cost = new_cost - current_cost;
    
    // Update cache
    self.cached_expansion.last_size = new_size;
    self.cached_expansion.last_cost = new_cost;
    
    return expansion_cost;
}

        /// Calculate total memory cost for a given size (internal helper)
        inline fn calculate_memory_total_cost(size_bytes: u64) u64 {
            const words = (size_bytes + 31) / 32;
            return 3 * words + (words * words) / 512;
        }
    };
}

// Default Memory type for backward compatibility
pub const DefaultMemory = Memory(.{
    .word_type = u256,
    .small_memory_lookup_size = 128,
});

// Import fuzz tests to ensure they are compiled and run
// test {
//     _ = @import("fuzz_tests.zig");
// }

test "memory expansion gas cost lookup table" {
    const allocator = std.testing.allocator;
    var memory = try DefaultMemory.init_default(allocator);
    defer memory.deinit();
    
    // Test small memory sizes use lookup table
    const test_cases = [_]struct { size: u64, expected_words: u64 }{
        .{ .size = 0, .expected_words = 0 },
        .{ .size = 32, .expected_words = 1 },     // 1 word
        .{ .size = 64, .expected_words = 2 },     // 2 words
        .{ .size = 1024, .expected_words = 32 },  // 32 words
        .{ .size = 4096, .expected_words = 128 }, // 128 words (at lookup table boundary)
    };
    
    for (test_cases) |tc| {
        const cost = memory.get_expansion_cost(tc.size);
        
        // Verify lookup table calculation matches manual calculation
        const expected_cost = 3 * tc.expected_words + (tc.expected_words * tc.expected_words) / 512;
        try std.testing.expectEqual(expected_cost, cost);
        
        // Verify subsequent calls return 0 (no expansion needed)
        const no_expansion = memory.get_expansion_cost(tc.size);
        try std.testing.expectEqual(@as(u64, 0), no_expansion);
    }
}

test "memory expansion gas cost cache behavior" {
    const allocator = std.testing.allocator;
    var memory = try DefaultMemory.init_default(allocator);
    defer memory.deinit();
    
    // Test large memory sizes use cache
    const large_size: u64 = 8192; // 256 words, beyond lookup table
    const first_cost = memory.get_expansion_cost(large_size);
    
    // Manual calculation for verification
    const words = large_size / 32;
    const expected_cost = 3 * words + (words * words) / 512;
    try std.testing.expectEqual(expected_cost, first_cost);
    
    // Verify cache is used for same size
    try std.testing.expectEqual(@as(u64, 0), memory.get_expansion_cost(large_size));
    
    // Test cache works for incremental expansion
    const larger_size: u64 = 16384; // 512 words
    const expansion_cost = memory.get_expansion_cost(larger_size);
    
    const larger_words = larger_size / 32;
    const larger_total_cost = 3 * larger_words + (larger_words * larger_words) / 512;
    const expected_expansion = larger_total_cost - expected_cost;
    try std.testing.expectEqual(expected_expansion, expansion_cost);
}

test "memory expansion gas cost mixed lookup and cache" {
    const allocator = std.testing.allocator;
    var memory = try DefaultMemory.init_default(allocator);
    defer memory.deinit();
    
    // Start with small memory (uses lookup table)
    const small_size: u64 = 1024; // 32 words
    const small_cost = memory.get_expansion_cost(small_size);
    try std.testing.expectEqual(@as(u64, 3 * 32 + (32 * 32) / 512), small_cost);
    
    // Expand to large memory (uses cache)
    const large_size: u64 = 16384; // 512 words
    const expansion_cost = memory.get_expansion_cost(large_size);
    
    const large_words = large_size / 32;
    const small_words = small_size / 32;
    const expected_expansion = (3 * large_words + (large_words * large_words) / 512) - 
                              (3 * small_words + (small_words * small_words) / 512);
    try std.testing.expectEqual(expected_expansion, expansion_cost);
    
    // Verify subsequent expansion from large size
    const huge_size: u64 = 32768; // 1024 words
    const huge_expansion = memory.get_expansion_cost(huge_size);
    
    const huge_words = huge_size / 32;
    const expected_huge_expansion = (3 * huge_words + (huge_words * huge_words) / 512) - 
                                   (3 * large_words + (large_words * large_words) / 512);
    try std.testing.expectEqual(expected_huge_expansion, huge_expansion);
}

test "memory expansion gas cost boundary conditions" {
    const allocator = std.testing.allocator;
    var memory = try DefaultMemory.init_default(allocator);
    defer memory.deinit();
    
    // Test exactly at lookup table boundary
    const boundary_words = 128; // Default small_memory_lookup_size
    const boundary_size = boundary_words * 32;
    
    const boundary_cost = memory.get_expansion_cost(boundary_size);
    const expected_boundary = 3 * boundary_words + (boundary_words * boundary_words) / 512;
    try std.testing.expectEqual(expected_boundary, boundary_cost);
    
    // Test just beyond lookup table boundary
    const beyond_boundary_size = boundary_size + 32;
    const beyond_cost = memory.get_expansion_cost(beyond_boundary_size);
    
    const beyond_words = beyond_boundary_size / 32;
    const expected_beyond_total = 3 * beyond_words + (beyond_words * beyond_words) / 512;
    const expected_beyond_expansion = expected_beyond_total - expected_boundary;
    try std.testing.expectEqual(expected_beyond_expansion, beyond_cost);
}

test "memory expansion gas cost performance benchmark" {
    const allocator = std.testing.allocator;
    const iterations = 10000;
    
    // Benchmark lookup table performance for small sizes
    {
        var memory = try DefaultMemory.init_default(allocator);
        defer memory.deinit();
        
        const start_time = std.time.nanoTimestamp();
        
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            // Simulate typical small memory operations (1-64 words)
            const test_size = @as(u64, @intCast((i % 64 + 1) * 32));
            _ = memory.get_expansion_cost(test_size);
            
            // Reset memory occasionally to test fresh calculations
            if (i % 100 == 0) {
                memory = try DefaultMemory.init_default(allocator);
            }
        }
        
        const end_time = std.time.nanoTimestamp();
        const lookup_duration = end_time - start_time;
        
        std.debug.print("Lookup table performance: {} ns total, {} ns avg per operation\n", 
                       .{ lookup_duration, @divTrunc(lookup_duration, iterations) });
    }
    
    // Benchmark pure calculation performance for comparison
    {
        const start_time = std.time.nanoTimestamp();
        
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const words = @as(u64, @intCast(i % 64 + 1));
            _ = 3 * words + (words * words) / 512;
        }
        
        const end_time = std.time.nanoTimestamp();
        const calc_duration = end_time - start_time;
        
        std.debug.print("Pure calculation performance: {} ns total, {} ns avg per operation\n", 
                       .{ calc_duration, @divTrunc(calc_duration, iterations) });
    }
}

