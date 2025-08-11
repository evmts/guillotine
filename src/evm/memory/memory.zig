//! EVM memory implementation with hierarchical isolation
//!
//! This module provides the memory abstraction for EVM execution contexts.
//! Memory is byte-addressable, dynamically expandable, and supports hierarchical
//! isolation for nested calls through a checkpoint system.
//!
//! ## Design Features
//! - Shared buffer with checkpoints for efficient nested calls
//! - Lazy expansion with gas cost calculation
//! - Zero-initialized on expansion
//! - Bounded memory operations for safe partial copies
//!
//! ## Gas Model
//! Memory expansion follows the quadratic gas cost formula:
//! - cost = (memory_size_word ^ 2) / 512 + (3 * memory_size_word)
//! - Gas is only charged when expanding beyond current size

const std = @import("std");
const builtin = @import("builtin");
const constants = @import("constants.zig");

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
    /// Last calculated memory size in words (cached to avoid division)
    last_words: u64,
    /// Gas cost for the last calculated size
    last_cost: u64,
} = .{ .last_size = 0, .last_words = 0, .last_cost = 0 },

/// Initializes the root Memory context that owns the shared buffer.
/// This is the safe API that eliminates the undefined pointer footgun.
pub fn init(
    allocator: std.mem.Allocator,
    initial_capacity: usize,
    memory_limit: u64,
) !Memory {
    const shared_buffer = try allocator.create(std.ArrayList(u8));
    errdefer allocator.destroy(shared_buffer);
    
    shared_buffer.* = std.ArrayList(u8).init(allocator);
    errdefer shared_buffer.deinit();
    
    try shared_buffer.ensureTotalCapacity(initial_capacity);

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
    return try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
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
    self.cached_expansion = .{ .last_size = 0, .last_words = 0, .last_cost = 0 };
}

// Read operations
pub const get_u256 = read_ops.get_u256;
pub const get_slice = read_ops.get_slice;
pub const get_byte = read_ops.get_byte;

// Write operations
pub const set_data = write_ops.set_data;
pub const set_data_bounded = write_ops.set_data_bounded;
pub const set_u256 = write_ops.set_u256;

// Slice operations
pub const slice = slice_ops.slice;

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
    
    // Update cache with both size and word count
    self.cached_expansion.last_size = new_size;
    self.cached_expansion.last_words = new_words;
    self.cached_expansion.last_cost = new_cost;

    return expansion_cost;
}

/// Calculate total memory cost for a given size (internal helper)
inline fn calculate_memory_total_cost(size_bytes: u64) u64 {
    const words = (size_bytes + 31) / 32;
    return 3 * words + (words * words) / 512;
}

/// Unified helper to charge gas and ensure memory capacity in one operation.
/// This reduces branches and improves performance for memory operations.
/// 
/// Returns error if out of gas or memory limit exceeded.
pub inline fn charge_and_ensure(self: *Memory, frame: anytype, new_size: u64) !void {
    // Calculate gas cost for expansion
    const gas_cost = self.get_expansion_cost(new_size);
    
    // Charge gas if expansion is needed
    if (gas_cost > 0) {
        try frame.consume_gas(gas_cost);
    }
    
    // Ensure memory capacity
    _ = try self.ensure_context_capacity(@intCast(new_size));
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

test "memory expansion word count caching" {
    const allocator = std.testing.allocator;
    var memory = try Memory.init_default(allocator);
    defer memory.deinit();
    
    // Initial state verification
    try std.testing.expectEqual(@as(u64, 0), memory.cached_expansion.last_size);
    try std.testing.expectEqual(@as(u64, 0), memory.cached_expansion.last_words);
    try std.testing.expectEqual(@as(u64, 0), memory.cached_expansion.last_cost);
    
    // First expansion to 8192 bytes (256 words)
    const size1: u64 = 8192;
    const cost1 = memory.get_expansion_cost(size1);
    
    // Verify cache was updated with word count
    try std.testing.expectEqual(size1, memory.cached_expansion.last_size);
    try std.testing.expectEqual(@as(u64, 256), memory.cached_expansion.last_words);
    try std.testing.expectEqual(@as(u64, 3 * 256 + (256 * 256) / 512), memory.cached_expansion.last_cost);
    try std.testing.expectEqual(cost1, memory.cached_expansion.last_cost);
    
    // Second call with same size should use cache
    const cost2 = memory.get_expansion_cost(size1);
    try std.testing.expectEqual(@as(u64, 0), cost2);
    
    // Verify cache values remain unchanged
    try std.testing.expectEqual(size1, memory.cached_expansion.last_size);
    try std.testing.expectEqual(@as(u64, 256), memory.cached_expansion.last_words);
}

test "memory expansion word count caching with sequential expansions" {
    const allocator = std.testing.allocator;
    var memory = try Memory.init_default(allocator);
    defer memory.deinit();
    
    // Expand to 4096 bytes (128 words)
    const size1: u64 = 4096;
    _ = memory.get_expansion_cost(size1);
    
    // Verify initial cache state
    try std.testing.expectEqual(size1, memory.cached_expansion.last_size);
    try std.testing.expectEqual(@as(u64, 128), memory.cached_expansion.last_words);
    
    // Expand to 8192 bytes (256 words) - should update cache
    const size2: u64 = 8192;
    _ = memory.get_expansion_cost(size2);
    
    // Verify cache was updated with new word count
    try std.testing.expectEqual(size2, memory.cached_expansion.last_size);
    try std.testing.expectEqual(@as(u64, 256), memory.cached_expansion.last_words);
    
    // Expand to 16384 bytes (512 words) - should update cache again
    const size3: u64 = 16384;
    _ = memory.get_expansion_cost(size3);
    
    // Verify cache was updated with new word count
    try std.testing.expectEqual(size3, memory.cached_expansion.last_size);
    try std.testing.expectEqual(@as(u64, 512), memory.cached_expansion.last_words);
}

test "memory expansion word count cache reset on clear" {
    const allocator = std.testing.allocator;
    var memory = try Memory.init_default(allocator);
    defer memory.deinit();
    
    // Perform expansion to populate cache
    const test_size: u64 = 8192;
    _ = memory.get_expansion_cost(test_size);
    
    // Verify cache is populated
    try std.testing.expectEqual(test_size, memory.cached_expansion.last_size);
    try std.testing.expectEqual(@as(u64, 256), memory.cached_expansion.last_words);
    try std.testing.expect(memory.cached_expansion.last_cost > 0);
    
    // Clear memory
    memory.clear();
    
    // Verify cache was reset
    try std.testing.expectEqual(@as(u64, 0), memory.cached_expansion.last_size);
    try std.testing.expectEqual(@as(u64, 0), memory.cached_expansion.last_words);
    try std.testing.expectEqual(@as(u64, 0), memory.cached_expansion.last_cost);
}

test "charge_and_ensure helper basic functionality" {
    const allocator = std.testing.allocator;
    var memory = try Memory.init_default(allocator);
    defer memory.deinit();
    
    // Mock frame structure for testing
    const MockFrame = struct {
        gas_remaining: u64,
        memory: *Memory,
        
        pub fn consume_gas(self: *@This(), amount: u64) !void {
            if (self.gas_remaining < amount) return error.OutOfGas;
            self.gas_remaining -= amount;
        }
    };
    
    var frame = MockFrame{
        .gas_remaining = 10000,
        .memory = &memory,
    };
    
    // Test 1: Small memory access within lookup table
    try memory.charge_and_ensure(&frame, 64);
    try std.testing.expectEqual(@as(u64, 10000 - 6), frame.gas_remaining); // 2 words * 3 gas
    try std.testing.expectEqual(@as(usize, 64), memory.context_size());
    
    // Test 2: Expansion to larger size
    try memory.charge_and_ensure(&frame, 256);
    const expected_gas = 3 * 8 + (8 * 8) / 512 - (3 * 2 + (2 * 2) / 512);
    try std.testing.expectEqual(@as(u64, 10000 - 6 - expected_gas), frame.gas_remaining);
    try std.testing.expectEqual(@as(usize, 256), memory.context_size());
    
    // Test 3: No expansion needed (same size)
    const gas_before = frame.gas_remaining;
    try memory.charge_and_ensure(&frame, 256);
    try std.testing.expectEqual(gas_before, frame.gas_remaining); // No gas consumed
    try std.testing.expectEqual(@as(usize, 256), memory.context_size());
}

test "charge_and_ensure helper out of gas" {
    const allocator = std.testing.allocator;
    var memory = try Memory.init_default(allocator);
    defer memory.deinit();
    
    const MockFrame = struct {
        gas_remaining: u64,
        memory: *Memory,
        
        pub fn consume_gas(self: *@This(), amount: u64) !void {
            if (self.gas_remaining < amount) return error.OutOfGas;
            self.gas_remaining -= amount;
        }
    };
    
    var frame = MockFrame{
        .gas_remaining = 5, // Not enough gas for expansion
        .memory = &memory,
    };
    
    // Should fail with OutOfGas error
    try std.testing.expectError(error.OutOfGas, memory.charge_and_ensure(&frame, 64));
    try std.testing.expectEqual(@as(u64, 5), frame.gas_remaining); // Gas unchanged
    try std.testing.expectEqual(@as(usize, 0), memory.context_size()); // Memory unchanged
}

test "charge_and_ensure helper large expansion" {
    const allocator = std.testing.allocator;
    var memory = try Memory.init_default(allocator);
    defer memory.deinit();
    
    const MockFrame = struct {
        gas_remaining: u64,
        memory: *Memory,
        
        pub fn consume_gas(self: *@This(), amount: u64) !void {
            if (self.gas_remaining < amount) return error.OutOfGas;
            self.gas_remaining -= amount;
        }
    };
    
    var frame = MockFrame{
        .gas_remaining = 1_000_000, // Plenty of gas
        .memory = &memory,
    };
    
    // Large expansion beyond lookup table
    const large_size: u64 = 8192; // 256 words
    try memory.charge_and_ensure(&frame, large_size);
    
    const expected_gas = 3 * 256 + (256 * 256) / 512;
    try std.testing.expectEqual(@as(u64, 1_000_000 - expected_gas), frame.gas_remaining);
    try std.testing.expectEqual(@as(usize, 8192), memory.context_size());
    
    // Verify cache was populated
    try std.testing.expectEqual(large_size, memory.cached_expansion.last_size);
    try std.testing.expectEqual(@as(u64, 256), memory.cached_expansion.last_words);
}
