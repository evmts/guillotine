//! EVM-compliant memory management.
//!
//! Provides byte-addressable memory with lazy expansion and hierarchical
//! isolation for nested execution contexts. Memory expands to 32-byte
//! word boundaries as per EVM specification.
//!
//! Key features:
//! - Lazy allocation on first access
//! - Zero-initialization guarantee
//! - Checkpoint system for nested calls
//! - Cached gas cost calculations
//! - Configurable memory limits
const std = @import("std");
const builtin = @import("builtin");
pub const MemoryConfig = @import("memory_config.zig").MemoryConfig;

// EVM memory constants
const WORD_SIZE = 32;
const WORD_SHIFT = 5; // log2(32)
const WORD_MASK = 31; // 32 - 1

pub const MemoryError = error{
    OutOfMemory,
    MemoryOverflow,
    OutOfBounds,
};

/// Creates a configured memory type.
///
/// Memory configuration controls initial capacity and maximum size limits.
/// The implementation uses ArrayList for dynamic growth with efficient resizing.
pub fn Memory(config: MemoryConfig) type {
    config.validate();

    return struct {
        const Self = @This();

        pub const INITIAL_CAPACITY = config.initial_capacity;
        pub const MEMORY_LIMIT = config.memory_limit;
        pub const is_owned = config.owned;

        checkpoint: u32,
        buffer_ptr: *std.ArrayList(u8),
        /// Word count (ceil(size / 32)) whose quadratic gas cost is cached in `cached_cost`.
        /// The cache is validated by word count on every lookup, so a stale entry
        /// (e.g. after a child frame grows the shared buffer) is simply a miss.
        cached_words: usize = 0,
        /// Memory gas cost of `cached_words` words: 3 * words + words^2 / 512.
        cached_cost: u64 = 0,
        /// When true, `buffer_ptr` belongs to an external pool and `deinit` must not free it.
        pooled: bool = false,
        /// Allocator that owns a pooled buffer. When set, every buffer growth uses it instead
        /// of the caller-supplied allocator, so a pool that outlives a per-call arena never
        /// holds arena memory after the arena resets.
        pool_allocator: ?std.mem.Allocator = null,

        pub fn init(allocator: std.mem.Allocator) !Self {
            if (is_owned) {
                const buffer_ptr = try allocator.create(std.ArrayList(u8));
                errdefer allocator.destroy(buffer_ptr);
                buffer_ptr.* = std.ArrayList(u8){};
                errdefer buffer_ptr.deinit(allocator);
                try buffer_ptr.ensureTotalCapacity(allocator, INITIAL_CAPACITY);
                return Self{
                    .checkpoint = 0,
                    .buffer_ptr = buffer_ptr,
                    .cached_words = 0,
                    .cached_cost = 0,
                    .pooled = false,
                };
            } else {
                @compileError("Cannot call init() on borrowed memory type. Use init_borrowed() instead.");
            }
        }

        pub fn init_borrowed(buffer_ptr: *std.ArrayList(u8), checkpoint: u32) !Self {
            // For backward compatibility on owned memory types, we just ignore ownership and return borrowed-like behavior
            return Self{
                .checkpoint = checkpoint,
                .buffer_ptr = buffer_ptr,
                .cached_words = 0,
                .cached_cost = 0,
                .pooled = false,
            };
        }

        /// Creates a memory view backed by a pooled buffer. The buffer is emptied
        /// (capacity retained) and is never freed by `deinit`; the pool owns it.
        /// `pool_allocator` must be the allocator that owns `buffer_ptr`; all growth uses it.
        pub fn init_pooled(buffer_ptr: *std.ArrayList(u8), pool_allocator: std.mem.Allocator) Self {
            buffer_ptr.items.len = 0;
            return Self{
                .checkpoint = 0,
                .buffer_ptr = buffer_ptr,
                .cached_words = 0,
                .cached_cost = 0,
                .pooled = true,
                .pool_allocator = pool_allocator,
            };
        }

        /// Empties the buffer (keeping its capacity) and resets checkpoint and gas cache.
        pub fn reset_for_reuse(self: *Self) void {
            self.buffer_ptr.items.len = 0;
            self.checkpoint = 0;
            self.cached_words = 0;
            self.cached_cost = 0;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (is_owned and !self.pooled) {
                self.buffer_ptr.deinit(allocator);
                allocator.destroy(self.buffer_ptr);
            }
            // No-op for borrowed or pooled memory
        }

        pub fn init_child(self: *Self) !Memory(.{ .initial_capacity = config.initial_capacity, .memory_limit = config.memory_limit, .owned = false }) {
            // Children are always borrowed memory types
            const BorrowedMemType = Memory(.{ .initial_capacity = config.initial_capacity, .memory_limit = config.memory_limit, .owned = false });
            return BorrowedMemType{
                .checkpoint = @as(u32, @intCast(self.buffer_ptr.*.items.len)),
                .buffer_ptr = self.buffer_ptr,
                .cached_words = 0,
                .cached_cost = 0,
                .pooled = false,
            };
        }

        // Internal size calculation without locking
        inline fn size_internal(self: *const Self) usize {
            const total = self.buffer_ptr.*.items.len;
            const checkpoint_usize = @as(usize, self.checkpoint);
            if (total <= checkpoint_usize) return 0;
            return total - checkpoint_usize;
        }

        // Common methods that work on the inner Self type
        pub fn size(self: *const Self) usize {
            return self.size_internal();
        }

        pub inline fn ensure_capacity(self: *Self, allocator: std.mem.Allocator, new_size: u32) !void {
            const checkpoint_usize = @as(usize, self.checkpoint);
            // EVM memory only ever grows in whole 32-byte words (MSIZE is a multiple of 32).
            const new_size_usize = (@as(usize, new_size) + 31) & ~@as(usize, 31);
            const required_total = checkpoint_usize + new_size_usize;
            if (required_total > MEMORY_LIMIT) {
                @branchHint(.unlikely);
                return MemoryError.MemoryOverflow;
            }

            const current_len = self.buffer_ptr.*.items.len;
            if (required_total <= current_len) return;

            if (required_total > self.buffer_ptr.*.capacity) {
                @branchHint(.unlikely);
                const alloc = self.pool_allocator orelse allocator;
                try self.buffer_ptr.*.ensureTotalCapacity(alloc, required_total);
            }
            self.buffer_ptr.*.items.len = required_total;
            // LLVM lowers @memset to optimal vectorized zeroing.
            @memset(self.buffer_ptr.*.items[current_len..required_total], 0);

            const words = (new_size_usize + WORD_MASK) >> WORD_SHIFT;
            self.cached_words = words;
            self.cached_cost = calculate_memory_cost(@as(u64, @intCast(words)));
        }

        /// Reads a big-endian word at `offset` without bounds checks.
        /// Caller must guarantee `offset + 32 <= self.size()`.
        pub inline fn get_u256_unchecked(self: *const Self, offset: usize) u256 {
            return std.mem.readInt(u256, (self.buffer_ptr.items.ptr + self.checkpoint + offset)[0..32], .big);
        }

        /// Writes a big-endian word at `offset` without bounds checks.
        /// Caller must guarantee `offset + 32 <= self.size()`.
        pub inline fn set_u256_unchecked(self: *Self, offset: usize, value: u256) void {
            std.mem.writeInt(u256, (self.buffer_ptr.items.ptr + self.checkpoint + offset)[0..32], value, .big);
        }

        /// Writes one byte at `offset` without bounds checks.
        /// Caller must guarantee `offset < self.size()`.
        pub inline fn set_byte_unchecked(self: *Self, offset: usize, value: u8) void {
            self.buffer_ptr.items.ptr[@as(usize, self.checkpoint) + offset] = value;
        }

        /// Overlap-safe in-place copy of `len` bytes from `src_offset` to `dst_offset`.
        /// Caller must have grown memory (via `ensure_capacity`) so both ranges are in bounds.
        pub fn copy_within(self: *Self, dst_offset: usize, src_offset: usize, len: usize) void {
            if (len == 0 or dst_offset == src_offset) return;
            const base = @as(usize, self.checkpoint);
            const items = self.buffer_ptr.items;
            const dst = items[base + dst_offset ..][0..len];
            const src = items[base + src_offset ..][0..len];
            if (dst_offset < src_offset) {
                std.mem.copyForwards(u8, dst, src);
            } else {
                std.mem.copyBackwards(u8, dst, src);
            }
        }

        // EVM-compliant memory operations that expand to word boundaries
        pub fn set_data_evm(self: *Self, allocator: std.mem.Allocator, offset: u32, data: []const u8) !void {
            const offset_usize = @as(usize, offset);
            const end = offset_usize + data.len;
            // Round up to next 32-byte word boundary for EVM compliance
            const word_aligned_end = std.math.shl(usize, std.math.shr(usize, end + 31, 5), 5);
            try self.ensure_capacity(allocator, @as(u32, @intCast(word_aligned_end)));
            const checkpoint_usize = @as(usize, self.checkpoint);
            const start_idx = checkpoint_usize + offset_usize;
            
            // Use SIMD for copying if vector_length > 1 and data is large enough
            if (config.vector_length > 1) {
                if (data.len >= config.vector_length * 4) { // Only use SIMD for larger copies
                    const dst = self.buffer_ptr.*.items[start_idx .. start_idx + data.len];
                    // Check alignment before attempting SIMD
                    const dst_addr = @intFromPtr(dst.ptr);
                    const src_addr = @intFromPtr(data.ptr);
                    const alignment_ok = (dst_addr % @alignOf(@Vector(config.vector_length, u8))) == 0 and
                                        (src_addr % @alignOf(@Vector(config.vector_length, u8))) == 0;

                    if (alignment_ok) {
                        const VectorType = @Vector(config.vector_length, u8);

                        // SIMD-aligned chunks
                        var i: usize = 0;
                        while (i + config.vector_length <= data.len) : (i += config.vector_length) {
                            const src_vec: VectorType = data[i..][0..config.vector_length].*;
                            const dst_ptr: *VectorType = @ptrCast(@alignCast(dst.ptr + i));
                            dst_ptr.* = src_vec;
                        }
                        // Handle remainder
                        if (i < data.len) {
                            @memcpy(dst[i..], data[i..]);
                        }
                    } else {
                        // Fallback to scalar if not aligned
                        @memcpy(self.buffer_ptr.*.items[start_idx .. start_idx + data.len], data);
                    }
                } else {
                    @memcpy(self.buffer_ptr.*.items[start_idx .. start_idx + data.len], data);
                }
            } else {
                @memcpy(self.buffer_ptr.*.items[start_idx .. start_idx + data.len], data);
            }
        }

        pub fn set_byte_evm(self: *Self, allocator: std.mem.Allocator, offset: u32, value: u8) !void {
            const bytes = [_]u8{value};
            try self.set_data_evm(allocator, offset, &bytes);
        }

        fn u256_to_bytes(value: u256) [WORD_SIZE]u8 {
            var bytes: [WORD_SIZE]u8 = undefined;
            std.mem.writeInt(u256, &bytes, value, .big);
            return bytes;
        }

        pub fn set_u256_evm(self: *Self, allocator: std.mem.Allocator, offset: u32, value: u256) !void {
            const bytes = u256_to_bytes(value);
            try self.set_data_evm(allocator, offset, &bytes);
        }

        pub fn get_slice(self: *Self, offset: u32, len: u32) MemoryError![]const u8 {
            const offset_usize = @as(usize, offset);
            const len_usize = @as(usize, len);
            const end = offset_usize + len_usize;
            if (end > self.size_internal()) {
                @branchHint(.unlikely);
                return MemoryError.OutOfBounds;
            }
            const checkpoint_usize = @as(usize, self.checkpoint);
            const start_idx = checkpoint_usize + offset_usize;
            return self.buffer_ptr.*.items[start_idx .. start_idx + len_usize];
        }

        pub fn set_data(self: *Self, allocator: std.mem.Allocator, offset: u32, data: []const u8) !void {
            const offset_usize = @as(usize, offset);
            const end = offset_usize + data.len;
            try self.ensure_capacity(allocator, @as(u32, @intCast(end)));
            const checkpoint_usize = @as(usize, self.checkpoint);
            const start_idx = checkpoint_usize + offset_usize;
            @memcpy(self.buffer_ptr.*.items[start_idx .. start_idx + data.len], data);
        }

        /// Clears memory: resets owned memory to empty, sets checkpoint for borrowed memory
        pub fn clear(self: *Self) void {
            self.cached_words = 0;
            self.cached_cost = 0;
            if (is_owned) {
                self.buffer_ptr.*.items.len = 0;
                self.checkpoint = 0;
            } else {
                self.checkpoint = @as(u32, @intCast(self.buffer_ptr.*.items.len));
            }
        }

        fn bytes_to_u256(bytes: []const u8) u256 {
            if (bytes.len != WORD_SIZE) {
                // Fallback for non-standard sizes
                var result: u256 = 0;
                for (bytes) |byte| result = std.math.shl(u256, result, 8) | byte;
                return result;
            }
            return std.mem.readInt(u256, bytes[0..WORD_SIZE], .big);
        }

        pub fn get_u256(self: *Self, offset: u32) !u256 {
            const slice = try self.get_slice(offset, 32);
            return bytes_to_u256(slice);
        }

        // EVM-compliant read that expands memory if needed
        pub fn get_u256_evm(self: *Self, allocator: std.mem.Allocator, offset: u32) !u256 {
            const offset_usize = @as(usize, offset);
            const word_aligned_end = std.math.shl(usize, std.math.shr(usize, offset_usize + 32 + 31, 5), 5);
            try self.ensure_capacity(allocator, @as(u32, @intCast(word_aligned_end)));
            const slice = try self.get_slice_internal(offset, 32);
            return bytes_to_u256(slice);
        }
        
        // Internal get_slice without locking
        inline fn get_slice_internal(self: *const Self, offset: u32, len: u32) MemoryError![]const u8 {
            const offset_usize = @as(usize, offset);
            const len_usize = @as(usize, len);
            const end = offset_usize + len_usize;
            if (end > self.size_internal()) {
                @branchHint(.unlikely);
                return MemoryError.OutOfBounds;
            }
            const checkpoint_usize = @as(usize, self.checkpoint);
            const start_idx = checkpoint_usize + offset_usize;
            return self.buffer_ptr.*.items[start_idx .. start_idx + len_usize];
        }

        pub fn set_u256(self: *Self, allocator: std.mem.Allocator, offset: u32, value: u256) !void {
            const bytes = u256_to_bytes(value);
            try self.set_data(allocator, offset, &bytes);
        }

        pub fn get_byte(self: *Self, offset: u32) !u8 {
            const slice = try self.get_slice(offset, 1);
            return slice[0];
        }

        pub fn set_byte(self: *Self, allocator: std.mem.Allocator, offset: u32, value: u8) !void {
            const bytes = [_]u8{value};
            try self.set_data(allocator, offset, &bytes);
        }

        fn calculate_memory_cost(words: u64) u64 {
            // Prevent overflow for very large word counts
            // Memory limit is configurable (default 16MB = 0xFFFFFF bytes = 524287 words)
            // With u32 size parameters, max possible is ~4GB = 134217727 words
            // We guard against overflow in the quadratic term (words * words)
            if (words > 134217727) {
                @branchHint(.unlikely);
                // Return max cost for unrealistic memory sizes
                return std.math.maxInt(u64);
            }
            return 3 * words + std.math.shr(u64, words * words, 9); // Using std.math.shr instead of / 512
        }
        pub fn get_expansion_cost(self: *const Self, new_size: u32) u64 {
            const new_size_u64 = @as(u64, new_size);
            const current_size = @as(u64, @intCast(self.size_internal()));
            if (new_size_u64 <= current_size) {
                @branchHint(.likely);
                return 0;
            }
            const new_words = (new_size_u64 + WORD_MASK) >> WORD_SHIFT;
            const current_words = (current_size + WORD_MASK) >> WORD_SHIFT;
            const new_cost = calculate_memory_cost(new_words);
            // The cache is keyed by word count, so it is only used when it describes
            // exactly the current memory size; otherwise recompute.
            const current_cost = if (current_words == self.cached_words)
                self.cached_cost
            else
                calculate_memory_cost(current_words);
            return new_cost - current_cost;
        }

        /// Returns reference to underlying buffer (used for shared memory access)
        pub inline fn get_buffer_ref(self: *Self) *std.ArrayList(u8) {
            return self.buffer_ptr;
        }
    };
}

test "Memory owner basic operations" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), memory.size());
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    try memory.set_data(allocator, 0, &data);
    try std.testing.expectEqual(@as(usize, 4), memory.size());
    const slice = try memory.get_slice(0, 4);
    try std.testing.expectEqualSlices(u8, &data, slice);
    memory.clear();
    try std.testing.expectEqual(@as(usize, 0), memory.size());
}

test "Memory borrowed operations" {
    const allocator = std.testing.allocator;
    const OwnerMem = Memory(.{ .owned = true });
    var owner = try OwnerMem.init(allocator);
    defer owner.deinit(allocator);
    const data1 = [_]u8{ 0xAA, 0xBB, 0xCC };
    try owner.set_data(allocator, 0, &data1);
    const BorrowedMem = Memory(.{ .owned = false });
    const checkpoint = @as(u32, @intCast(@min(owner.buffer_ptr.*.items.len, std.math.maxInt(u32))));
    var borrowed = try BorrowedMem.init_borrowed(owner.buffer_ptr, checkpoint);
    defer borrowed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), borrowed.size());
    const data2 = [_]u8{ 0xDD, 0xEE, 0xFF };
    try borrowed.set_data(allocator, 0, &data2);
    try std.testing.expectEqual(@as(usize, 3), borrowed.size());
    try std.testing.expectEqual(@as(usize, 6), owner.buffer_ptr.*.items.len);
    try std.testing.expectEqualSlices(u8, &data1, owner.buffer_ptr.*.items[0..3]);
    try std.testing.expectEqualSlices(u8, &data2, owner.buffer_ptr.*.items[3..6]);
}

test "Memory capacity limits" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .initial_capacity = 50, .memory_limit = 100, .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);
    try memory.ensure_capacity(allocator, 50);
    try std.testing.expectEqual(@as(usize, 50), memory.buffer_ptr.*.items.len);
    try memory.ensure_capacity(allocator, 100);
    try std.testing.expectEqual(@as(usize, 100), memory.buffer_ptr.*.items.len);
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.ensure_capacity(allocator, 101));
}

test "Memory child creation" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var parent = try Mem.init(allocator);
    defer parent.deinit(allocator);
    const data1 = [_]u8{ 0x11, 0x22, 0x33 };
    try parent.set_data(allocator, 0, &data1);
    try std.testing.expectEqual(@as(usize, 3), parent.size());
    var child = try parent.init_child();
    defer child.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), child.size());
    const data2 = [_]u8{ 0x44, 0x55 };
    try child.set_data(allocator, 0, &data2);
    try std.testing.expectEqual(@as(usize, 0), parent.checkpoint);
    try std.testing.expectEqual(@as(u32, 3), child.checkpoint);
    try std.testing.expectEqual(@as(usize, 5), parent.buffer_ptr.*.items.len);
    try std.testing.expectEqual(@as(usize, 5), parent.size());
    try std.testing.expectEqual(@as(usize, 2), child.size());
    try std.testing.expectEqual(@as(usize, 5), parent.buffer_ptr.*.items.len);
}

test "Memory zero initialization on expansion" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);
    try memory.ensure_capacity(allocator, 10);
    const slice = try memory.get_slice(0, 10);
    for (slice) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "Memory out of bounds access" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);
    const data = [_]u8{ 0x01, 0x02, 0x03 };
    try memory.set_data(allocator, 0, &data);
    _ = try memory.get_slice(0, 3);
    try std.testing.expectError(MemoryError.OutOfBounds, memory.get_slice(0, 4));
    try std.testing.expectError(MemoryError.OutOfBounds, memory.get_slice(2, 2));
}

test "Memory configuration validation" {
    _ = Memory(.{ .owned = true });
    _ = Memory(.{ .initial_capacity = 1024, .memory_limit = 2048, .owned = true });
}

test "Memory u256 operations" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);
    const value1: u256 = 0x123456789ABCDEF0;
    try memory.set_u256(allocator, 0, value1);
    const read1 = try memory.get_u256(0);
    try std.testing.expectEqual(value1, read1);
    const max_value = std.math.maxInt(u256);
    try memory.set_u256(allocator, 32, max_value);
    const read2 = try memory.get_u256(32);
    try std.testing.expectEqual(max_value, read2);
    try memory.set_u256(allocator, 64, 0);
    const read3 = try memory.get_u256(64);
    try std.testing.expectEqual(@as(u256, 0), read3);
}

test "Memory byte operations" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);
    try memory.set_byte(allocator, 0, 0xFF);
    const byte1 = try memory.get_byte(0);
    try std.testing.expectEqual(@as(u8, 0xFF), byte1);
    try memory.set_byte(allocator, 10, 0x42);
    const byte2 = try memory.get_byte(10);
    try std.testing.expectEqual(@as(u8, 0x42), byte2);
    const byte3 = try memory.get_byte(5);
    try std.testing.expectEqual(@as(u8, 0), byte3);
}

test "Memory gas expansion cost" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);
    var cost = memory.get_expansion_cost(0);
    try std.testing.expectEqual(@as(u64, 0), cost);
    cost = memory.get_expansion_cost(32);
    try std.testing.expectEqual(@as(u64, 3), cost);
    try memory.ensure_capacity(allocator, 32);
    cost = memory.get_expansion_cost(64);
    const expected = (3 * 2 + (2 * 2) / 512) - (3 * 1 + (1 * 1) / 512);
    try std.testing.expectEqual(expected, cost);
    cost = memory.get_expansion_cost(32);
    try std.testing.expectEqual(@as(u64, 0), cost);
}

test "Memory gas expansion cost caching" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);
    const cost1 = memory.get_expansion_cost(256);
    const expected_cost = 3 * 8 + (8 * 8) / 512;
    try std.testing.expectEqual(expected_cost, cost1);
    // After the first expansion, subsequent calls should return incremental cost
    try memory.ensure_capacity(allocator, 256);
    try std.testing.expectEqual(@as(u64, 0), memory.get_expansion_cost(256));
    try std.testing.expectEqual(@as(u64, 0), memory.get_expansion_cost(128));
}

test "Memory clear resets cache" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);
    const cost1 = memory.get_expansion_cost(256);
    try std.testing.expect(cost1 > 0);
    memory.clear();
    const cost2 = memory.get_expansion_cost(256);
    try std.testing.expectEqual(cost1, cost2);
}

test "Memory large data operations" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);
    var large_data: [1024]u8 = undefined;
    for (&large_data, 0..) |*byte, i| {
        byte.* = @truncate(i);
    }
    try memory.set_data(allocator, 0, &large_data);
    try std.testing.expectEqual(@as(usize, 1024), memory.size());
    const chunk1 = try memory.get_slice(0, 256);
    const chunk2 = try memory.get_slice(256, 256);
    const chunk3 = try memory.get_slice(512, 256);
    const chunk4 = try memory.get_slice(768, 256);
    try std.testing.expectEqualSlices(u8, large_data[0..256], chunk1);
    try std.testing.expectEqualSlices(u8, large_data[256..512], chunk2);
    try std.testing.expectEqualSlices(u8, large_data[512..768], chunk3);
    try std.testing.expectEqualSlices(u8, large_data[768..1024], chunk4);
}

test "Memory sequential child memories" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var parent = try Mem.init(allocator);
    defer parent.deinit(allocator);

    // Add data to parent
    const parent_data = [_]u8{ 0x01, 0x02, 0x03 };
    try parent.set_data(allocator, 0, &parent_data);
    try std.testing.expectEqual(@as(usize, 3), parent.size());

    // Create first child memory and add data
    var child1 = try parent.init_child();
    defer child1.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), child1.size());
    try std.testing.expectEqual(@as(usize, 3), child1.checkpoint);

    const child1_data = [_]u8{ 0x11, 0x22 };
    try child1.set_data(allocator, 0, &child1_data);
    try std.testing.expectEqual(@as(usize, 2), child1.size());

    // Create second child from updated parent (checkpoint now at 5)
    var child2 = try parent.init_child();
    defer child2.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), child2.size());
    try std.testing.expectEqual(@as(u32, 5), child2.checkpoint);

    // Add data to second child
    const child2_data = [_]u8{ 0x33, 0x44, 0x55, 0x66 };
    try child2.set_data(allocator, 0, &child2_data);

    // After child2 writes, both children see the full buffer size from their checkpoint
    // child1: total(9) - checkpoint(3) = 6
    // child2: total(9) - checkpoint(5) = 4
    try std.testing.expectEqual(@as(usize, 6), child1.size());
    try std.testing.expectEqual(@as(usize, 4), child2.size());

    // Verify data is correctly positioned
    const read1 = try child1.get_slice(0, 2); // child1's data at buffer[3:5]
    const read2 = try child2.get_slice(0, 4); // child2's data at buffer[5:9]
    try std.testing.expectEqualSlices(u8, &child1_data, read1);
    try std.testing.expectEqualSlices(u8, &child2_data, read2);

    // Verify underlying buffer layout
    try std.testing.expectEqual(@as(usize, 9), parent.buffer_ptr.*.items.len); // 3 + 2 + 4

    // Parent should see all data in buffer
    try std.testing.expectEqual(@as(usize, 9), parent.size());
    const parent_view = try parent.get_slice(0, 3);
    try std.testing.expectEqualSlices(u8, &parent_data, parent_view);
}

test "Memory fast-path optimization for small growth" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);

    // Pre-allocate some capacity
    try memory.buffer_ptr.ensureTotalCapacity(allocator, 128);
    const initial_capacity = memory.buffer_ptr.*.capacity;
    try std.testing.expect(initial_capacity >= 128);

    // Small growth (32 bytes) should use existing capacity without reallocation
    try memory.ensure_capacity(allocator, 32);
    try std.testing.expectEqual(@as(usize, 32), memory.buffer_ptr.*.items.len);
    try std.testing.expectEqual(initial_capacity, memory.buffer_ptr.*.capacity);

    // Another small growth should still use existing capacity
    try memory.ensure_capacity(allocator, 64);
    try std.testing.expectEqual(@as(usize, 64), memory.buffer_ptr.*.items.len);
    try std.testing.expectEqual(initial_capacity, memory.buffer_ptr.*.capacity);

    // Verify zero initialization
    const slice = try memory.get_slice(0, 64);
    for (slice) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "Memory growth beyond fast-path threshold" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);

    // Start with small size
    try memory.ensure_capacity(allocator, 16);
    try std.testing.expectEqual(@as(usize, 16), memory.buffer_ptr.*.items.len);

    // Growth larger than 32 bytes should use standard path
    try memory.ensure_capacity(allocator, 100);
    try std.testing.expectEqual(@as(usize, 100), memory.buffer_ptr.*.items.len);

    // Verify zero initialization
    const slice = try memory.get_slice(0, 100);
    for (slice) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "Memory fast-path with insufficient capacity" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);

    // Force small initial capacity
    memory.buffer_ptr.shrinkAndFree(allocator, 0);
    try std.testing.expectEqual(@as(usize, 0), memory.buffer_ptr.*.capacity);

    // Small growth should still work but will need allocation
    try memory.ensure_capacity(allocator, 20);
    try std.testing.expectEqual(@as(usize, 20), memory.buffer_ptr.*.items.len);
    try std.testing.expect(memory.buffer_ptr.*.capacity >= 20);

    // Verify zero initialization
    const slice = try memory.get_slice(0, 20);
    for (slice) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "Memory fast-path edge case at 32 bytes" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);

    // Pre-allocate exact capacity for test
    try memory.buffer_ptr.ensureTotalCapacity(allocator, 64);
    const initial_capacity = memory.buffer_ptr.*.capacity;

    // Growth of exactly 32 bytes should use fast path
    try memory.ensure_capacity(allocator, 32);
    try std.testing.expectEqual(@as(usize, 32), memory.buffer_ptr.*.items.len);
    try std.testing.expectEqual(initial_capacity, memory.buffer_ptr.*.capacity);

    // Growth of 33 bytes from empty should use standard path
    memory.clear();
    try memory.ensure_capacity(allocator, 33);
    try std.testing.expectEqual(@as(usize, 33), memory.buffer_ptr.*.items.len);

    // Verify zero initialization
    const slice = try memory.get_slice(0, 33);
    for (slice) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "Memory struct size verification" {
    const OwnedMem = Memory(.{ .owned = true });
    const BorrowedMem = Memory(.{ .owned = false });

    // Both owned and borrowed should have the same size
    try std.testing.expectEqual(@sizeOf(OwnedMem), @sizeOf(BorrowedMem));

    // Check the actual size - without mutex
    // checkpoint (3) + padding (5) + buffer_ptr (8) = 16 bytes typical
    try std.testing.expect(@sizeOf(OwnedMem) >= 16);

    // Field offsets depend on struct padding and alignment
}

test "Memory expansion cost cache matches uncached formula" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);
    const sizes = [_]u32{ 1, 32, 33, 64, 1000, 4096, 4097, 100_000, 1_000_000 };
    for (sizes) |s| {
        const current: u64 = @intCast(memory.size());
        const target: u64 = @max(current, s);
        const new_words = (target + 31) / 32;
        const old_words = (current + 31) / 32;
        const expected = (3 * new_words + new_words * new_words / 512) - (3 * old_words + old_words * old_words / 512);
        try std.testing.expectEqual(expected, memory.get_expansion_cost(s));
        try memory.ensure_capacity(allocator, s);
        try std.testing.expectEqual(@as(usize, (target + 31) / 32), memory.cached_words);
    }
}

test "Memory expansion cost stays exact when a child grows the shared buffer" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var parent = try Mem.init(allocator);
    defer parent.deinit(allocator);
    try parent.ensure_capacity(allocator, 64);
    var child = try parent.init_child();
    defer child.deinit(allocator);
    try child.ensure_capacity(allocator, 96);
    // Parent now sees 160 bytes (5 words) but its cache describes 2 words.
    const expected: u64 = (3 * 6 + 36 / 512) - (3 * 5 + 25 / 512);
    try std.testing.expectEqual(expected, parent.get_expansion_cost(192));
}

test "Memory pooled init and reset_for_reuse" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(allocator);
    try buffer.appendSlice(allocator, &[_]u8{ 1, 2, 3 });
    var memory = Mem.init_pooled(&buffer, allocator);
    try std.testing.expectEqual(@as(usize, 0), memory.size());
    try memory.ensure_capacity(allocator, 64);
    try std.testing.expectEqual(@as(usize, 2), memory.cached_words);
    memory.reset_for_reuse();
    try std.testing.expectEqual(@as(usize, 0), memory.size());
    try std.testing.expectEqual(@as(usize, 0), memory.cached_words);
    try std.testing.expectEqual(@as(u64, 0), memory.cached_cost);
    // deinit must not free the pool-owned buffer (testing allocator detects double free).
    memory.deinit(allocator);
    try buffer.append(allocator, 9);
}

test "Memory pooled growth uses pool allocator, not the caller allocator" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(allocator);
    var memory = Mem.init_pooled(&buffer, allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    // Grow well past the empty buffer while passing a short-lived arena.
    try memory.ensure_capacity(arena.allocator(), 4096);
    arena.deinit();
    // The buffer must still be valid and owned by the pool allocator.
    try std.testing.expectEqual(@as(usize, 4096), memory.size());
    try std.testing.expect(buffer.capacity >= 4096);
    memory.set_u256_unchecked(4064, 0xdead);
    try std.testing.expectEqual(@as(u256, 0xdead), memory.get_u256_unchecked(4064));
}

test "Memory unchecked word accessors respect checkpoint" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var parent = try Mem.init(allocator);
    defer parent.deinit(allocator);
    try parent.ensure_capacity(allocator, 32);
    var child = try parent.init_child();
    try child.ensure_capacity(allocator, 64);
    child.set_u256_unchecked(1, 0xDEADBEEF);
    try std.testing.expectEqual(@as(u256, 0xDEADBEEF), child.get_u256_unchecked(1));
    try std.testing.expectEqual(@as(u256, 0xDEADBEEF), try child.get_u256(1));
    try std.testing.expectEqual(@as(u256, 0), try parent.get_u256(0));
}

test "Memory copy_within handles forward and backward overlap" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);
    try memory.set_data(allocator, 0, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    memory.copy_within(2, 0, 4);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 1, 2, 3, 4, 7, 8 }, try memory.get_slice(0, 8));
    memory.copy_within(0, 3, 5);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 2, 3, 4, 7, 8, 4, 7, 8 }, try memory.get_slice(0, 8));
}
