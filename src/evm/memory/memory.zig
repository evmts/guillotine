const std = @import("std");
const builtin = @import("builtin");
const constants = @import("constants.zig");
const Log = @import("../log.zig");

// Safety check constants - only enabled in Debug and ReleaseSafe modes
// These checks are redundant after analysis.zig validates memory operations
const SAFE_MEMORY_BOUNDS = builtin.mode != .ReleaseFast and builtin.mode != .ReleaseSmall;

/// Memory implementation for EVM execution contexts.
pub const Memory = @This();

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
) !Memory {
    Log.debug("Memory.init: Starting, initial_capacity={}, memory_limit={}", .{ initial_capacity, memory_limit });

    Log.debug("Memory.init: About to create shared_buffer", .{});
    // MEMORY ALLOCATION: ArrayList structure for shared buffer
    // Expected size: sizeof(ArrayList) ≈ 24 bytes
    // Lifetime: Per root Memory instance
    // Frequency: Once per frame
    const shared_buffer = try allocator.create(std.ArrayList(u8));
    errdefer allocator.destroy(shared_buffer);
    Log.debug("Memory.init: Created shared_buffer ptr={*}", .{shared_buffer});

    Log.debug("Memory.init: Initializing ArrayList", .{});
    shared_buffer.* = std.ArrayList(u8).init(allocator);
    errdefer shared_buffer.deinit();

    Log.debug("Memory.init: About to ensureTotalCapacity({})", .{initial_capacity});
    // MEMORY ALLOCATION: Shared buffer data
    // Expected initial size: initial_capacity (typically 4KB)
    // Lifetime: Per root Memory instance
    // Frequency: Once per frame (shared among child memories)
    // Growth: Doubles when capacity exceeded, up to memory_limit
    try shared_buffer.ensureTotalCapacity(initial_capacity);
    Log.debug("Memory.init: ensureTotalCapacity complete", .{});

    if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        // Verify initial allocation is reasonable
        std.debug.assert(shared_buffer.capacity >= initial_capacity);
        // Note: We allow initial_capacity > memory_limit for test compatibility
        // The memory_limit will be enforced on actual memory operations

        // Default initial capacity should be 4KB
        if (initial_capacity == INITIAL_CAPACITY) {
            std.debug.assert(INITIAL_CAPACITY == 4096); // 4KB default
        }
        // Default memory limit should be 32MB
        if (memory_limit == DEFAULT_MEMORY_LIMIT) {
            std.debug.assert(DEFAULT_MEMORY_LIMIT == 32 * 1024 * 1024); // 32MB default
        }
    }

    Log.debug("Memory.init: Returning Memory struct", .{});
    return Memory{
        .my_checkpoint = 0,
        .memory_limit = memory_limit,
        .shared_buffer_ref = shared_buffer,
        .allocator = allocator,
        .owns_buffer = true,
    };
}

/// Creates a child Memory that shares the buffer with a different checkpoint.
/// Child memory has a view of the shared buffer starting from its checkpoint.
pub fn init_child_memory(self: *Memory, checkpoint: usize) !Memory {
    return Memory{
        .my_checkpoint = checkpoint,
        .memory_limit = self.memory_limit,
        .shared_buffer_ref = self.shared_buffer_ref,
        .allocator = self.allocator,
        .owns_buffer = false,
    };
}

pub fn init_default(allocator: std.mem.Allocator) !Memory {
    Log.debug("Memory.init_default: Called with allocator={*}", .{allocator.ptr});
    const result = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    Log.debug("Memory.init_default: Returning", .{});
    return result;
}

/// Deinitializes the Memory. Only root Memory instances clean up the shared buffer.
pub fn deinit(self: *Memory) void {
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
pub fn clear(self: *Memory) void {
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

// Read operations
pub const get_u256 = read_ops.get_u256;
pub const get_u256_unsafe = read_ops.get_u256_unsafe;
pub const get_slice = read_ops.get_slice;
pub const get_slice_unsafe = read_ops.get_slice_unsafe;
pub const get_byte = read_ops.get_byte;

// Write operations
pub const set_data = write_ops.set_data;
pub const set_data_unsafe = write_ops.set_data_unsafe;
pub const set_data_bounded = write_ops.set_data_bounded;
pub const set_u256 = write_ops.set_u256;
pub const set_u256_unsafe = write_ops.set_u256_unsafe;

// Slice operations
pub const slice = slice_ops.slice;

/// Get direct access to the memory buffer for pre-validated operations.
/// SAFETY: Caller must ensure all accesses are within bounds (my_checkpoint + offset < buffer.len)
/// Use only for operations pre-validated by analysis.zig
pub inline fn get_memory_ptr(self: *const Memory) [*]u8 {
    return self.shared_buffer_ref.items.ptr;
}

/// Get the checkpoint offset for this context.
/// Used with get_memory_ptr for direct memory access.
pub inline fn get_checkpoint(self: *const Memory) usize {
    return self.my_checkpoint;
}

/// Lookup table for small memory sizes (0-4KB in 32-byte increments)
/// Provides O(1) access for common small memory allocations
const SMALL_MEMORY_LOOKUP_SIZE = 128; // Covers 0-4KB in 32-byte words
const SMALL_MEMORY_LOOKUP_TABLE = generate_memory_expansion_lut: {
    var table: [SMALL_MEMORY_LOOKUP_SIZE + 1]u64 = undefined;
    for (&table, 0..) |*cost, words| {
        const word_count = @as(u64, @intCast(words));
        cost.* = 3 * word_count + (word_count * word_count) / 512;
    }
    break :generate_memory_expansion_lut table;
};

/// Get memory expansion gas cost with caching optimization
/// Returns the gas cost for expanding memory from current size to new_size.
/// Uses lookup table for small sizes and cached values for larger sizes.
pub fn get_expansion_cost(self: *Memory, new_size: u64) u64 {
    const current_size = @as(u64, @intCast(self.context_size()));

    // No expansion needed if new size is not larger than current
    if (new_size <= current_size) {
        return 0;
    }

    const new_words = (new_size + 31) / 32;
    const current_words = (current_size + 31) / 32;

    // Use lookup table for small memory sizes
    if (new_words <= SMALL_MEMORY_LOOKUP_SIZE and current_words <= SMALL_MEMORY_LOOKUP_SIZE) {
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

// Import fuzz tests to ensure they are compiled and run
test {
    _ = @import("fuzz_tests.zig");
}

test "memory expansion gas cost lookup table" {
    const allocator = std.testing.allocator;
    var memory = try Memory.init_default(allocator);
    defer memory.deinit();

    // Test small memory sizes use lookup table
    const test_cases = [_]struct { size: u64, expected_words: u64 }{
        .{ .size = 0, .expected_words = 0 },
        .{ .size = 32, .expected_words = 1 }, // 1 word
        .{ .size = 64, .expected_words = 2 }, // 2 words
        .{ .size = 1024, .expected_words = 32 }, // 32 words
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
    var memory = try Memory.init_default(allocator);
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
    var memory = try Memory.init_default(allocator);
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
    var memory = try Memory.init_default(allocator);
    defer memory.deinit();

    // Test exactly at lookup table boundary
    const boundary_words = SMALL_MEMORY_LOOKUP_SIZE;
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
        var memory = try Memory.init_default(allocator);
        defer memory.deinit();

        const start_time = std.time.nanoTimestamp();

        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            // Simulate typical small memory operations (1-64 words)
            const test_size = @as(u64, @intCast((i % 64 + 1) * 32));
            _ = memory.get_expansion_cost(test_size);

            // Reset memory occasionally to test fresh calculations
            if (i % 100 == 0) {
                memory = try Memory.init_default(allocator);
            }
        }

        const end_time = std.time.nanoTimestamp();
        const lookup_duration = end_time - start_time;

        std.debug.print("Lookup table performance: {} ns total, {} ns avg per operation\n", .{ lookup_duration, @divTrunc(lookup_duration, iterations) });
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

        std.debug.print("Pure calculation performance: {} ns total, {} ns avg per operation\n", .{ calc_duration, @divTrunc(calc_duration, iterations) });
    }
}
