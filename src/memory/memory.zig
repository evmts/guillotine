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
const FAST_PATH_THRESHOLD = 32;

pub const MemoryError = error{
    OutOfMemory,
    MemoryOverflow,
    OutOfBounds,
};

/// Creates a configured memory type.
///
/// Memory configuration controls initial capacity and maximum size limits.
/// The implementation uses ArrayList for dynamic growth with efficient resizing.
/// Read a big-endian 256-bit word as four 64-bit limbs.
/// A generic `std.mem.readInt(u256, ..., .big)` lowers to a long scalar byte shuffle;
/// this form is four loads and, on a little-endian host, four `bswap`.
/// `std.mem.bigToNative` is `@byteSwap` on a little-endian host and the identity on a
/// big-endian one, so the word is right on both.
pub inline fn loadWordBigEndian(bytes: *const [WORD_SIZE]u8) u256 {
    const limb3 = std.mem.bigToNative(u64, @bitCast(bytes[0..8].*));
    const limb2 = std.mem.bigToNative(u64, @bitCast(bytes[8..16].*));
    const limb1 = std.mem.bigToNative(u64, @bitCast(bytes[16..24].*));
    const limb0 = std.mem.bigToNative(u64, @bitCast(bytes[24..32].*));
    return (@as(u256, limb3) << 192) | (@as(u256, limb2) << 128) | (@as(u256, limb1) << 64) | @as(u256, limb0);
}

/// Write a 256-bit word big-endian as four 64-bit limbs (`bswap` on a little-endian
/// host only; see `loadWordBigEndian`).
pub inline fn storeWordBigEndian(bytes: *[WORD_SIZE]u8, value: u256) void {
    bytes[0..8].* = @bitCast(std.mem.nativeToBig(u64, @truncate(value >> 192)));
    bytes[8..16].* = @bitCast(std.mem.nativeToBig(u64, @truncate(value >> 128)));
    bytes[16..24].* = @bitCast(std.mem.nativeToBig(u64, @truncate(value >> 64)));
    bytes[24..32].* = @bitCast(std.mem.nativeToBig(u64, @truncate(value)));
}

pub fn Memory(config: MemoryConfig) type {
    config.validate();

    return struct {
        const Self = @This();

        pub const INITIAL_CAPACITY = config.initial_capacity;
        pub const MEMORY_LIMIT = config.memory_limit;
        pub const is_owned = config.owned;

        /// True when this type keeps the address and size of its bytes inline
        /// (`MemoryConfig.flat`).
        pub const is_flat = config.flat;

        /// Inline copy of where this memory's bytes are: `data` is the address of
        /// byte 0 (the buffer's start plus the checkpoint) and `len` the number of
        /// bytes past the checkpoint. Empty unless `is_flat`. `sync` refreshes it.
        const Flat = if (is_flat) struct { data: [*]u8, len: usize } else struct {};

        flat: Flat,
        checkpoint: u32,
        /// True only for a value made by `init`, which allocated `buffer_ptr` and
        /// its bytes. A view made by `init_borrowed` or `init_child` never owns
        /// them, whatever `is_owned` says: `deinit` frees nothing through it.
        /// The flag sits in the padding after `checkpoint`.
        owns_buffer: bool,
        buffer_ptr: *std.ArrayList(u8),

        /// Words a `Memory` value takes: on 64-bit, `checkpoint` (u32) + `owns_buffer` (bool)
        /// fit in one 8-byte word alongside `buffer_ptr` (2 words, +2 when `is_flat`); on
        /// 32-bit targets `owns_buffer` requires an extra word (3 words, +2 when `is_flat`).
        pub const size_in_words: usize = 1 + (if (@sizeOf(usize) >= 8) @as(usize, 1) else 2) + (if (is_flat) @as(usize, 2) else 0);

        comptime {
            if (@sizeOf(Self) != size_in_words * @sizeOf(usize)) {
                @compileError(std.fmt.comptimePrint(
                    "Memory must remain compact ({d} bytes), found {d}",
                    .{ size_in_words * @sizeOf(usize), @sizeOf(Self) },
                ));
            }
        }

        /// Refresh the inline copy from the buffer. Every function that can change
        /// the buffer's address or length ends with it. A no-op unless `is_flat`.
        inline fn sync(self: *Self) void {
            if (comptime !is_flat) return;
            const items = self.buffer_ptr.items;
            const checkpoint_usize = @as(usize, self.checkpoint);
            if (items.len <= checkpoint_usize) {
                // No byte is addressable, so `data` is never dereferenced.
                self.flat = .{ .data = items.ptr, .len = 0 };
                return;
            }
            self.flat = .{ .data = items.ptr + checkpoint_usize, .len = items.len - checkpoint_usize };
        }

        /// A view of `buffer_ptr` starting at `checkpoint`, with its inline copy set.
        inline fn view(buffer_ptr: *std.ArrayList(u8), checkpoint: u32, owns_buffer: bool) Self {
            var self = Self{
                .flat = if (comptime is_flat) .{ .data = buffer_ptr.items.ptr, .len = 0 } else .{},
                .checkpoint = checkpoint,
                .owns_buffer = owns_buffer,
                .buffer_ptr = buffer_ptr,
            };
            self.sync();
            return self;
        }

        pub fn init(allocator: std.mem.Allocator) !Self {
            if (is_owned) {
                const buffer_ptr = try allocator.create(std.ArrayList(u8));
                errdefer allocator.destroy(buffer_ptr);
                buffer_ptr.* = std.ArrayList(u8).empty;
                errdefer buffer_ptr.deinit(allocator);
                try buffer_ptr.ensureTotalCapacity(allocator, INITIAL_CAPACITY);
                return view(buffer_ptr, 0, true);
            } else {
                @compileError("Cannot call init() on borrowed memory type. Use init_borrowed() instead.");
            }
        }

        /// A view of a buffer the caller keeps. The view never owns the buffer, on
        /// an owned memory type too: `deinit` on it frees nothing, and the caller
        /// releases the buffer the way it was acquired (for a frame, to its pool).
        pub fn init_borrowed(buffer_ptr: *std.ArrayList(u8), checkpoint: u32) !Self {
            return view(buffer_ptr, checkpoint, false);
        }

        /// True when `deinit` frees this value's buffer.
        pub inline fn ownsBuffer(self: *const Self) bool {
            if (comptime !is_owned) return false;
            return self.owns_buffer;
        }

        /// Free the buffer when this value owns it; a no-op for a borrowed view.
        /// The value owns nothing afterwards, so a second call is a no-op too.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (!self.ownsBuffer()) return;
            self.owns_buffer = false;
            self.buffer_ptr.deinit(allocator);
            allocator.destroy(self.buffer_ptr);
        }

        pub fn init_child(self: *Self) !Memory(.{
            .initial_capacity = config.initial_capacity,
            .memory_limit = config.memory_limit,
            .owned = false,
        }) {
            // A child grows the buffer it shares with its parent, which the parent's
            // inline copy would not see.
            if (comptime is_flat) @compileError("a flat Memory is its buffer's only user; it cannot have child views");
            // Children are always borrowed memory types
            const BorrowedMemType = Memory(.{
                .initial_capacity = config.initial_capacity,
                .memory_limit = config.memory_limit,
                .owned = false,
            });
            return BorrowedMemType{
                .flat = .{},
                .owns_buffer = false,
                .checkpoint = std.math.cast(u32, self.buffer_ptr.*.items.len) orelse return MemoryError.MemoryOverflow,
                .buffer_ptr = self.buffer_ptr,
            };
        }

        // Internal size calculation without locking
        inline fn size_internal(self: *const Self) usize {
            if (comptime is_flat) return self.flat.len;
            const total = self.buffer_ptr.*.items.len;
            const checkpoint_usize = @as(usize, self.checkpoint);
            if (total <= checkpoint_usize) return 0;
            return total - checkpoint_usize;
        }

        // Common methods that work on the inner Self type
        pub fn size(self: *Self) usize {
            return self.size_internal();
        }

        /// Grow memory to at least `new_size` bytes past the checkpoint, rounded up to a
        /// whole 32-byte word. Any size whose rounded end overflows `usize` or exceeds
        /// `MEMORY_LIMIT` returns `MemoryOverflow` and leaves memory unchanged.
        pub inline fn ensure_capacity(self: *Self, allocator: std.mem.Allocator, new_size: usize) !void {
            if (comptime is_flat) {
                // Already large enough: nothing to grow and nothing to refresh.
                if (new_size <= self.flat.len) return;
            }
            try self.growBuffer(allocator, new_size);
            self.sync();
        }

        /// `ensure_capacity` on the buffer itself.
        inline fn growBuffer(self: *Self, allocator: std.mem.Allocator, new_size: usize) !void {
            const checkpoint_usize = @as(usize, self.checkpoint);
            // EVM memory only ever grows in whole 32-byte words (MSIZE is a multiple of 32).
            const rounded, const round_overflow = @addWithOverflow(new_size, 31);
            if (round_overflow != 0) {
                @branchHint(.unlikely);
                return MemoryError.MemoryOverflow;
            }
            const new_size_usize = rounded & ~@as(usize, 31);
            const required_total, const total_overflow = @addWithOverflow(checkpoint_usize, new_size_usize);
            if (total_overflow != 0 or required_total > MEMORY_LIMIT) {
                @branchHint(.unlikely);
                return MemoryError.MemoryOverflow;
            }

            const current_len = self.buffer_ptr.*.items.len;
            if (required_total <= current_len) return;

            // Fast path for small growth (common for single word operations)
            const growth = required_total - current_len;
            if (growth <= FAST_PATH_THRESHOLD) {
                @branchHint(.likely);
                // For small growth, try to use existing capacity first
                if (required_total <= self.buffer_ptr.*.capacity) {
                    @branchHint(.likely);
                    // We have capacity, just extend length and zero
                    const old_len = current_len;
                    self.buffer_ptr.*.items.len = required_total;

                    // Use SIMD for zeroing if vector_length > 1 and data is large enough
                    if (config.vector_length > 1) {
                        const slice = self.buffer_ptr.*.items[old_len..required_total];
                        // Only use SIMD if we have enough data AND proper alignment
                        const ptr_addr = @intFromPtr(slice.ptr);
                        const alignment_ok = (ptr_addr % @alignOf(@Vector(config.vector_length, u8))) == 0;

                        if (slice.len >= config.vector_length and alignment_ok and config.vector_length > 1) {
                            const VectorType = @Vector(config.vector_length, u8);
                            const zero_vec: VectorType = @splat(0);

                            // SIMD-aligned chunks
                            var i: usize = 0;
                            while (i + config.vector_length <= slice.len) : (i += config.vector_length) {
                                const ptr: *VectorType = @ptrCast(@alignCast(slice.ptr + i));
                                ptr.* = zero_vec;
                            }
                            // Handle remainder
                            if (i < slice.len) {
                                @memset(slice[i..], 0);
                            }
                        } else {
                            @memset(slice, 0);
                        }
                    } else {
                        @memset(self.buffer_ptr.*.items[old_len..required_total], 0);
                    }
                    return;
                }
            }

            // Standard path for larger growth
            const old_len = current_len;
            // Use ensureTotalCapacity + manual growth to control zeroing
            try self.buffer_ptr.*.ensureTotalCapacity(allocator, required_total);
            self.buffer_ptr.*.items.len = required_total;

            // Zero only the new portion with SIMD if applicable
            if (config.vector_length > 1) {
                const slice = self.buffer_ptr.*.items[old_len..required_total];
                if (slice.len >= config.vector_length * 4) { // Only use SIMD for larger buffers
                    // Check alignment before attempting SIMD
                    const ptr_addr = @intFromPtr(slice.ptr);
                    const alignment_ok = (ptr_addr % @alignOf(@Vector(config.vector_length, u8))) == 0;

                    if (alignment_ok) {
                        const VectorType = @Vector(config.vector_length, u8);
                        const zero_vec: VectorType = @splat(0);

                        // SIMD-aligned chunks
                        var i: usize = 0;
                        while (i + config.vector_length <= slice.len) : (i += config.vector_length) {
                            const ptr: *VectorType = @ptrCast(@alignCast(slice.ptr + i));
                            ptr.* = zero_vec;
                        }
                        // Handle remainder
                        if (i < slice.len) {
                            @memset(slice[i..], 0);
                        }
                    } else {
                        // Fallback to scalar if not aligned
                        @memset(slice, 0);
                    }
                } else {
                    @memset(slice, 0);
                }
            } else {
                @memset(self.buffer_ptr.*.items[old_len..required_total], 0);
            }
        }

        // EVM-compliant memory operations that expand to word boundaries
        pub fn set_data_evm(self: *Self, allocator: std.mem.Allocator, offset: usize, data: []const u8) !void {
            const offset_usize = offset;
            const end, const end_overflow = @addWithOverflow(offset_usize, data.len);
            if (end_overflow != 0) {
                @branchHint(.unlikely);
                return MemoryError.MemoryOverflow;
            }
            // ensure_capacity rounds up to the next 32-byte word boundary for EVM compliance
            // and bounds checkpoint + end by MEMORY_LIMIT, so the indexing below is in range.
            try self.ensure_capacity(allocator, end);
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

        pub fn set_byte_evm(self: *Self, allocator: std.mem.Allocator, offset: usize, value: u8) !void {
            const bytes = [_]u8{value};
            try self.set_data_evm(allocator, offset, &bytes);
        }

        fn u256_to_bytes(value: u256) [WORD_SIZE]u8 {
            var bytes: [WORD_SIZE]u8 = undefined;
            storeWordBigEndian(&bytes, value);
            return bytes;
        }

        /// True when the 32-byte word at `offset` lies entirely inside the current
        /// memory, so reading or writing it needs no expansion and costs no expansion
        /// gas. When false the caller takes the general path.
        ///
        /// A flat memory decides this with one comparison against its own `len`: no
        /// load through `buffer_ptr` and no checkpoint addition. `len -| 31` is the
        /// number of offsets at which a whole word fits, and zero for a memory
        /// shorter than a word.
        pub inline fn word_in_bounds(self: *const Self, offset: u256) bool {
            if (comptime is_flat) return offset < self.flat.len -| (WORD_SIZE - 1);
            const items = self.buffer_ptr.*.items;
            const checkpoint_usize = @as(usize, self.checkpoint);
            if (items.len < checkpoint_usize + WORD_SIZE) return false;
            return offset <= items.len - checkpoint_usize - WORD_SIZE;
        }

        /// The word at `offset`, which `word_in_bounds` has accepted. A flat memory
        /// indexes from its own `data`. Asking first and fetching second, instead
        /// of returning an optional pointer, spares the caller a null test.
        pub inline fn word_ptr_unchecked(self: *const Self, offset: u256) *[WORD_SIZE]u8 {
            // An accepted offset is below the memory's length, so no bit is lost.
            const offset_usize: usize = @truncate(offset);
            if (comptime is_flat) return @ptrCast(self.flat.data + offset_usize);
            return @ptrCast(self.buffer_ptr.*.items.ptr + @as(usize, self.checkpoint) + offset_usize);
        }

        /// True when the byte at `offset` lies inside the current memory.
        pub inline fn byte_in_bounds(self: *const Self, offset: u256) bool {
            if (comptime is_flat) return offset < self.flat.len;
            const items = self.buffer_ptr.*.items;
            const checkpoint_usize = @as(usize, self.checkpoint);
            if (items.len <= checkpoint_usize) return false;
            return offset < items.len - checkpoint_usize;
        }

        /// The byte at `offset`, which `byte_in_bounds` has accepted.
        pub inline fn byte_ptr_unchecked(self: *const Self, offset: u256) *u8 {
            const offset_usize: usize = @truncate(offset);
            if (comptime is_flat) return &self.flat.data[offset_usize];
            return &self.buffer_ptr.*.items.ptr[@as(usize, self.checkpoint) + offset_usize];
        }

        /// Pointer to the 32-byte word at `offset` when it lies entirely inside the
        /// current memory, null otherwise.
        pub inline fn word_ptr_in_bounds(self: *const Self, offset: u256) ?*[WORD_SIZE]u8 {
            if (!self.word_in_bounds(offset)) return null;
            return self.word_ptr_unchecked(offset);
        }

        /// Pointer to the byte at `offset` when it lies inside the current memory.
        pub inline fn byte_ptr_in_bounds(self: *const Self, offset: u256) ?*u8 {
            if (!self.byte_in_bounds(offset)) return null;
            return self.byte_ptr_unchecked(offset);
        }

        pub fn set_u256_evm(self: *Self, allocator: std.mem.Allocator, offset: usize, value: u256) !void {
            const bytes = u256_to_bytes(value);
            try self.set_data_evm(allocator, offset, &bytes);
        }

        pub fn get_slice(self: *Self, offset: usize, len: usize) MemoryError![]const u8 {
            const offset_usize = offset;
            const len_usize = len;
            const end, const end_overflow = @addWithOverflow(offset_usize, len_usize);
            if (end_overflow != 0 or end > self.size_internal()) {
                @branchHint(.unlikely);
                return MemoryError.OutOfBounds;
            }
            const checkpoint_usize = @as(usize, self.checkpoint);
            const start_idx = checkpoint_usize + offset_usize;
            return self.buffer_ptr.*.items[start_idx .. start_idx + len_usize];
        }

        pub fn set_data(self: *Self, allocator: std.mem.Allocator, offset: usize, data: []const u8) !void {
            const offset_usize = offset;
            const end, const end_overflow = @addWithOverflow(offset_usize, data.len);
            if (end_overflow != 0) {
                @branchHint(.unlikely);
                return MemoryError.MemoryOverflow;
            }
            try self.ensure_capacity(allocator, end);
            const checkpoint_usize = @as(usize, self.checkpoint);
            const start_idx = checkpoint_usize + offset_usize;
            @memcpy(self.buffer_ptr.*.items[start_idx .. start_idx + data.len], data);
        }

        /// Clears memory: empties a buffer this value owns; for a borrowed view,
        /// moves the checkpoint to the end of the buffer and leaves the owner's
        /// bytes alone.
        pub fn clear(self: *Self) void {
            if (self.ownsBuffer()) {
                self.buffer_ptr.*.items.len = 0;
                self.checkpoint = 0;
            } else {
                // items.len never exceeds MEMORY_LIMIT (ensure_capacity is the only way
                // memory grows) and `validate` bounds MEMORY_LIMIT by maxInt(u32).
                self.checkpoint = @as(u32, @intCast(self.buffer_ptr.*.items.len));
            }
            self.sync();
        }

        /// Refresh the inline copy after the buffer was changed without going
        /// through this value (a test that edits `buffer_ptr` directly). A no-op
        /// unless `is_flat`.
        pub fn resync(self: *Self) void {
            self.sync();
        }

        fn bytes_to_u256(bytes: []const u8) u256 {
            if (bytes.len != WORD_SIZE) {
                // Fallback for non-standard sizes
                var result: u256 = 0;
                for (bytes) |byte| result = std.math.shl(u256, result, 8) | byte;
                return result;
            }
            return loadWordBigEndian(bytes[0..WORD_SIZE]);
        }

        pub fn get_u256(self: *Self, offset: usize) !u256 {
            const slice = try self.get_slice(offset, 32);
            return bytes_to_u256(slice);
        }

        // EVM-compliant read that expands memory if needed
        pub fn get_u256_evm(self: *Self, allocator: std.mem.Allocator, offset: usize) !u256 {
            const end, const end_overflow = @addWithOverflow(offset, @as(usize, WORD_SIZE));
            if (end_overflow != 0) {
                @branchHint(.unlikely);
                return MemoryError.MemoryOverflow;
            }
            try self.ensure_capacity(allocator, end);
            const slice = try self.get_slice_internal(offset, 32);
            return bytes_to_u256(slice);
        }

        // Internal get_slice without locking
        inline fn get_slice_internal(self: *const Self, offset: usize, len: usize) MemoryError![]const u8 {
            const offset_usize = offset;
            const len_usize = len;
            const end, const end_overflow = @addWithOverflow(offset_usize, len_usize);
            if (end_overflow != 0 or end > self.size_internal()) {
                @branchHint(.unlikely);
                return MemoryError.OutOfBounds;
            }
            const checkpoint_usize = @as(usize, self.checkpoint);
            const start_idx = checkpoint_usize + offset_usize;
            return self.buffer_ptr.*.items[start_idx .. start_idx + len_usize];
        }

        pub fn set_u256(self: *Self, allocator: std.mem.Allocator, offset: usize, value: u256) !void {
            const bytes = u256_to_bytes(value);
            try self.set_data(allocator, offset, &bytes);
        }

        pub fn get_byte(self: *Self, offset: usize) !u8 {
            const slice = try self.get_slice(offset, 1);
            return slice[0];
        }

        pub fn set_byte(self: *Self, allocator: std.mem.Allocator, offset: usize, value: u8) !void {
            const bytes = [_]u8{value};
            try self.set_data(allocator, offset, &bytes);
        }

        fn calculate_memory_cost(words: u64) u64 {
            // Prevent overflow for very large word counts
            // Memory limit is configurable (default 16MB = 0xFFFFFF bytes = 524287 words)
            // Sizes past the 4 GiB memory limit bound (134217727 words) are unpayable
            // We guard against overflow in the quadratic term (words * words)
            if (words > 134217727) {
                @branchHint(.unlikely);
                // Return max cost for unrealistic memory sizes
                return std.math.maxInt(u64);
            }
            return 3 * words + std.math.shr(u64, words * words, 9); // Using std.math.shr instead of / 512
        }
        /// Gas to grow memory to `new_size` bytes. Sizes whose word count overflows
        /// cost `maxInt(u64)`, which no gas limit can pay.
        pub fn get_expansion_cost(self: *Self, new_size: usize) u64 {
            const new_size_u64 = @as(u64, new_size);
            const current_size = @as(u64, self.size_internal());
            if (new_size_u64 <= current_size) {
                @branchHint(.likely);
                return 0;
            }
            const new_size_rounded, const round_overflow = @addWithOverflow(new_size_u64, 31);
            if (round_overflow != 0) {
                @branchHint(.unlikely);
                return std.math.maxInt(u64);
            }
            const new_words = std.math.shr(u64, new_size_rounded, 5); // Using std.math.shr instead of / 32
            const current_words = std.math.shr(u64, current_size + 31, 5); // Using std.math.shr instead of / 32
            const new_cost = calculate_memory_cost(new_words);
            const current_cost = calculate_memory_cost(current_words);
            return new_cost - current_cost;
        }

        /// Returns reference to underlying buffer (used for shared memory access)
        pub inline fn get_buffer_ref(self: *Self) *std.ArrayList(u8) {
            return self.buffer_ptr;
        }
    };
}

test "word helpers match std big-endian conversion" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const value = random.int(u256);
        var expected: [WORD_SIZE]u8 = undefined;
        std.mem.writeInt(u256, &expected, value, .big);
        var actual: [WORD_SIZE]u8 = undefined;
        storeWordBigEndian(&actual, value);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
        try std.testing.expectEqual(value, loadWordBigEndian(&expected));
    }
}

test "in-bounds pointers cover exactly the current memory" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);
    try std.testing.expect(memory.word_ptr_in_bounds(0) == null);
    try std.testing.expect(memory.byte_ptr_in_bounds(0) == null);
    try memory.set_u256_evm(allocator, 32, 0xAABB);
    try std.testing.expectEqual(@as(usize, 64), memory.size());
    try std.testing.expectEqual(@as(u256, 0xAABB), loadWordBigEndian(memory.word_ptr_in_bounds(32).?));
    try std.testing.expect(memory.word_ptr_in_bounds(33) == null);
    try std.testing.expect(memory.word_ptr_in_bounds(std.math.maxInt(u256)) == null);
    try std.testing.expect(memory.word_ptr_in_bounds(@as(u256, 1) << 64) == null);
    try std.testing.expectEqual(@as(u8, 0xBB), memory.byte_ptr_in_bounds(63).?.*);
    try std.testing.expect(memory.byte_ptr_in_bounds(64) == null);
    try std.testing.expect(memory.byte_ptr_in_bounds(std.math.maxInt(u256)) == null);
}

test "Memory owner basic operations" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), memory.size());
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    try memory.set_data(allocator, 0, &data);
    // Memory grows in whole 32-byte words.
    try std.testing.expectEqual(@as(usize, 32), memory.size());
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
    // The owner grew to one word (checkpoint 32); the borrowed view adds one more.
    try std.testing.expectEqual(@as(u32, 32), checkpoint);
    try std.testing.expectEqual(@as(usize, 32), borrowed.size());
    try std.testing.expectEqual(@as(usize, 64), owner.buffer_ptr.*.items.len);
    try std.testing.expectEqualSlices(u8, &data1, owner.buffer_ptr.*.items[0..3]);
    try std.testing.expectEqualSlices(u8, &data2, owner.buffer_ptr.*.items[32..35]);
}

test "Memory capacity limits" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .initial_capacity = 50, .memory_limit = 96, .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);
    try memory.ensure_capacity(allocator, 50);
    try std.testing.expectEqual(@as(usize, 64), memory.buffer_ptr.*.items.len);
    try memory.ensure_capacity(allocator, 96);
    try std.testing.expectEqual(@as(usize, 96), memory.buffer_ptr.*.items.len);
    // 97 bytes round up to 128, past the limit.
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.ensure_capacity(allocator, 97));
    try std.testing.expectEqual(@as(usize, 96), memory.buffer_ptr.*.items.len);
}

test "Memory child creation" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var parent = try Mem.init(allocator);
    defer parent.deinit(allocator);
    const data1 = [_]u8{ 0x11, 0x22, 0x33 };
    try parent.set_data(allocator, 0, &data1);
    try std.testing.expectEqual(@as(usize, 32), parent.size());
    var child = try parent.init_child();
    defer child.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), child.size());
    const data2 = [_]u8{ 0x44, 0x55 };
    try child.set_data(allocator, 0, &data2);
    try std.testing.expectEqual(@as(usize, 0), parent.checkpoint);
    try std.testing.expectEqual(@as(u32, 32), child.checkpoint);
    try std.testing.expectEqual(@as(usize, 64), parent.buffer_ptr.*.items.len);
    try std.testing.expectEqual(@as(usize, 64), parent.size());
    try std.testing.expectEqual(@as(usize, 32), child.size());
    try std.testing.expectEqualSlices(u8, &data2, try child.get_slice(0, 2));
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
    // The write grew memory to one 32-byte word.
    _ = try memory.get_slice(0, 32);
    try std.testing.expectError(MemoryError.OutOfBounds, memory.get_slice(0, 33));
    try std.testing.expectError(MemoryError.OutOfBounds, memory.get_slice(31, 2));
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
    try std.testing.expectEqual(@as(usize, 32), parent.size());

    // Create first child memory and add data
    var child1 = try parent.init_child();
    defer child1.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), child1.size());
    try std.testing.expectEqual(@as(usize, 32), child1.checkpoint);

    const child1_data = [_]u8{ 0x11, 0x22 };
    try child1.set_data(allocator, 0, &child1_data);
    try std.testing.expectEqual(@as(usize, 32), child1.size());

    // Create second child from updated parent (checkpoint now at 64)
    var child2 = try parent.init_child();
    defer child2.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), child2.size());
    try std.testing.expectEqual(@as(u32, 64), child2.checkpoint);

    // Add data to second child
    const child2_data = [_]u8{ 0x33, 0x44, 0x55, 0x66 };
    try child2.set_data(allocator, 0, &child2_data);

    // After child2 writes, both children see the full buffer size from their checkpoint
    // child1: total(96) - checkpoint(32) = 64
    // child2: total(96) - checkpoint(64) = 32
    try std.testing.expectEqual(@as(usize, 64), child1.size());
    try std.testing.expectEqual(@as(usize, 32), child2.size());

    // Verify data is correctly positioned
    const read1 = try child1.get_slice(0, 2); // child1's data at buffer[32:34]
    const read2 = try child2.get_slice(0, 4); // child2's data at buffer[64:68]
    try std.testing.expectEqualSlices(u8, &child1_data, read1);
    try std.testing.expectEqualSlices(u8, &child2_data, read2);

    // Verify underlying buffer layout: three whole words
    try std.testing.expectEqual(@as(usize, 96), parent.buffer_ptr.*.items.len);

    // Parent should see all data in buffer
    try std.testing.expectEqual(@as(usize, 96), parent.size());
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
    try std.testing.expectEqual(@as(usize, 32), memory.buffer_ptr.*.items.len);

    // Growth larger than 32 bytes should use standard path
    try memory.ensure_capacity(allocator, 100);
    try std.testing.expectEqual(@as(usize, 128), memory.buffer_ptr.*.items.len);

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
    try std.testing.expectEqual(@as(usize, 32), memory.buffer_ptr.*.items.len);
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
    try std.testing.expectEqual(@as(usize, 64), memory.buffer_ptr.*.items.len);

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

test "Memory offsets near maxInt(u32) return MemoryOverflow instead of trapping" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);
    const max32: usize = std.math.maxInt(u32);
    const word: [32]u8 = @splat(0xAB);

    // Each of these rounds to a word end at or past 2^32, which the old
    // `@intCast` to u32 trapped on.
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.ensure_capacity(allocator, max32));
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.set_data_evm(allocator, max32, &word));
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.set_data_evm(allocator, max32 - 31, &word));
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.set_byte_evm(allocator, max32, 1));
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.set_u256_evm(allocator, max32 - 31, 7));
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.get_u256_evm(allocator, max32 - 31));
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.get_u256_evm(allocator, max32));
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.set_data(allocator, max32, &word));
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.set_u256(allocator, max32, 7));
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.set_byte(allocator, max32, 1));
    try std.testing.expectError(MemoryError.OutOfBounds, memory.get_slice(max32, 32));
    try std.testing.expectError(MemoryError.OutOfBounds, memory.get_u256(max32));
    try std.testing.expectError(MemoryError.OutOfBounds, memory.get_byte(max32));
    try std.testing.expectEqual(@as(usize, 0), memory.size());

    // A memory limit of exactly maxInt(u32) rejects the rounded end 2^32 before allocating.
    const Huge = Memory(.{ .initial_capacity = 0, .memory_limit = std.math.maxInt(u32), .owned = true });
    var huge = try Huge.init(allocator);
    defer huge.deinit(allocator);
    try std.testing.expectError(MemoryError.MemoryOverflow, huge.ensure_capacity(allocator, max32));
    try std.testing.expectEqual(@as(usize, 0), huge.size());
}

test "Memory offsets near maxInt(usize) return errors instead of overflowing" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);
    const max: usize = std.math.maxInt(usize);
    const word: [32]u8 = @splat(0xCD);

    try memory.set_u256_evm(allocator, 0, 0x1234);
    try std.testing.expectEqual(@as(usize, 32), memory.size());

    // Rounding up to a word overflows usize.
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.ensure_capacity(allocator, max));
    // Rounding fits, but the size is past the limit.
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.ensure_capacity(allocator, max - 31));
    // offset + len overflows usize.
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.set_data_evm(allocator, max, &word));
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.set_data_evm(allocator, max - 16, &word));
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.set_byte_evm(allocator, max, 1));
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.set_u256_evm(allocator, max, 1));
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.get_u256_evm(allocator, max));
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.get_u256_evm(allocator, max - 31));
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.set_data(allocator, max, &word));
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.set_u256(allocator, max, 1));
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.set_byte(allocator, max, 1));
    try std.testing.expectError(MemoryError.OutOfBounds, memory.get_slice(max, 2));
    try std.testing.expectError(MemoryError.OutOfBounds, memory.get_slice(1, max));
    try std.testing.expectError(MemoryError.OutOfBounds, memory.get_u256(max));
    try std.testing.expectError(MemoryError.OutOfBounds, memory.get_byte(max));
    try std.testing.expectEqual(std.math.maxInt(u64), memory.get_expansion_cost(max));

    // A child at a non-zero checkpoint overflows checkpoint + size.
    var child = try memory.init_child();
    defer child.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 32), child.checkpoint);
    try std.testing.expectError(MemoryError.MemoryOverflow, child.ensure_capacity(allocator, max - 40));
    try std.testing.expectError(MemoryError.MemoryOverflow, child.set_data_evm(allocator, max - 40, &word));

    // Failed operations left memory and its contents unchanged.
    try std.testing.expectEqual(@as(usize, 32), memory.size());
    try std.testing.expectEqual(@as(u256, 0x1234), try memory.get_u256(0));
}

test "Memory accepts usize offsets up to the limit" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .initial_capacity = 0, .memory_limit = 1024, .owned = true });
    var memory = try Mem.init(allocator);
    defer memory.deinit(allocator);
    const offset: usize = 1024 - 32;
    try memory.set_u256_evm(allocator, offset, 0xBEEF);
    try std.testing.expectEqual(@as(usize, 1024), memory.size());
    try std.testing.expectEqual(@as(u256, 0xBEEF), try memory.get_u256_evm(allocator, offset));
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.set_byte_evm(allocator, 1024, 1));
}

test "flat memory: in-bounds pointers match the buffer-backed view at every boundary" {
    const allocator = std.testing.allocator;
    const Flat = Memory(.{ .initial_capacity = 64, .memory_limit = 1 << 20, .flat = true });
    const Plain = Memory(.{ .initial_capacity = 64, .memory_limit = 1 << 20 });
    try std.testing.expectEqual(4 * @sizeOf(usize), @sizeOf(Flat));
    try std.testing.expectEqual(2 * @sizeOf(usize), @sizeOf(Plain));

    var flat = try Flat.init(allocator);
    defer flat.deinit(allocator);
    var plain = try Plain.init(allocator);
    defer plain.deinit(allocator);

    // Empty memory: nothing is in bounds.
    try std.testing.expect(flat.word_ptr_in_bounds(0) == null);
    try std.testing.expect(flat.byte_ptr_in_bounds(0) == null);
    try std.testing.expectEqual(@as(usize, 0), flat.size());

    // Grow in steps, some of which move the buffer, and compare at each size.
    for ([_]usize{ 1, 32, 33, 64, 1000, 4096, 200_000 }) |new_size| {
        try flat.ensure_capacity(allocator, new_size);
        try plain.ensure_capacity(allocator, new_size);
        const len = plain.size();
        try std.testing.expectEqual(len, flat.size());
        try std.testing.expectEqual(@as(usize, 0), len % 32);

        // Wrapping keeps the offsets just below `len - 32` meaningful for a
        // one-word memory: they become huge and must be out of bounds.
        const wide_len: u256 = len;
        const offsets = [_]u256{
            0,
            1,
            31,
            wide_len -% 33,
            wide_len - 32,
            wide_len - 31,
            wide_len - 1,
            wide_len,
            wide_len + 1,
            1 << 32,
            1 << 64,
            (1 << 64) + wide_len - 32,
            std.math.maxInt(u256),
        };
        for (offsets) |offset| {
            const plain_word = plain.word_ptr_in_bounds(offset);
            const flat_word = flat.word_ptr_in_bounds(offset);
            try std.testing.expectEqual(plain_word != null, flat_word != null);
            try std.testing.expectEqual(offset <= len - 32, flat_word != null);
            if (flat_word) |word| {
                // The pointer addresses this memory's own bytes at `offset`.
                const index: usize = @intCast(offset);
                try std.testing.expectEqual(@intFromPtr(flat.buffer_ptr.items.ptr) + index, @intFromPtr(word));
            }

            const plain_byte = plain.byte_ptr_in_bounds(offset);
            const flat_byte = flat.byte_ptr_in_bounds(offset);
            try std.testing.expectEqual(plain_byte != null, flat_byte != null);
            try std.testing.expectEqual(offset < len, flat_byte != null);
            if (flat_byte) |byte| {
                const index: usize = @intCast(offset);
                byte.* = @truncate(index *% 7 +% 1);
                try std.testing.expectEqual(byte.*, flat.buffer_ptr.items[index]);
            }
        }

        // A word written through the pointer is what the checked reader returns.
        const last_word = flat.word_ptr_in_bounds(len - 32).?;
        storeWordBigEndian(last_word, 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20);
        try std.testing.expectEqual(
            @as(u256, 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20),
            try flat.get_u256(len - 32),
        );
    }

    // Asking for less than the memory holds changes nothing.
    const before = flat.size();
    try flat.ensure_capacity(allocator, 64);
    try std.testing.expectEqual(before, flat.size());

    flat.clear();
    try std.testing.expectEqual(@as(usize, 0), flat.size());
    try std.testing.expect(flat.word_ptr_in_bounds(0) == null);
    try std.testing.expect(flat.byte_ptr_in_bounds(0) == null);

    // Memory grown again after a clear starts zeroed.
    try flat.ensure_capacity(allocator, 64);
    try std.testing.expectEqual(@as(u256, 0), loadWordBigEndian(flat.word_ptr_in_bounds(32).?));
}

test "flat memory: a view over an existing buffer starts at its checkpoint" {
    const allocator = std.testing.allocator;
    const Flat = Memory(.{ .initial_capacity = 64, .memory_limit = 1 << 20, .flat = true });

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    try list.appendNTimes(allocator, 0xAB, 96);

    var view = try Flat.init_borrowed(&list, 32);
    try std.testing.expectEqual(@as(usize, 64), view.size());
    try std.testing.expectEqual(@intFromPtr(&list.items[32]), @intFromPtr(view.word_ptr_in_bounds(0).?));
    try std.testing.expectEqual(@intFromPtr(&list.items[64]), @intFromPtr(view.word_ptr_in_bounds(32).?));
    try std.testing.expect(view.word_ptr_in_bounds(33) == null);
    try std.testing.expectEqual(@intFromPtr(&list.items[95]), @intFromPtr(view.byte_ptr_in_bounds(63).?));
    try std.testing.expect(view.byte_ptr_in_bounds(64) == null);

    // Growth through the view keeps the checkpoint as byte 0.
    try view.ensure_capacity(allocator, 100);
    try std.testing.expectEqual(@as(usize, 128), view.size());
    try std.testing.expectEqual(@as(usize, 160), list.items.len);
    try std.testing.expectEqual(@intFromPtr(&list.items[32]), @intFromPtr(view.word_ptr_in_bounds(0).?));
    try std.testing.expectEqual(@as(u8, 0), view.byte_ptr_in_bounds(127).?.*);

    // An edit made behind the view's back is picked up by `resync`.
    list.items.len = 40;
    view.resync();
    try std.testing.expectEqual(@as(usize, 8), view.size());
    try std.testing.expect(view.word_ptr_in_bounds(0) == null);
    try std.testing.expect(view.byte_ptr_in_bounds(7) != null);
    try std.testing.expect(view.byte_ptr_in_bounds(8) == null);

    // A checkpoint at or past the end of the buffer is an empty memory.
    const empty = try Flat.init_borrowed(&list, 40);
    try std.testing.expectEqual(@as(usize, 0), empty.flat.len);
    try std.testing.expect(empty.byte_ptr_in_bounds(0) == null);
}

test "W3-8: loadWordBigEndian and storeWordBigEndian agree with the big-endian byte order on any host" {
    var bytes: [WORD_SIZE]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @intCast(i + 1);
    // Byte 0 is the most significant byte of the word, whatever the host's order.
    const expected: u256 = 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20;
    try std.testing.expectEqual(expected, loadWordBigEndian(&bytes));
    try std.testing.expectEqual(std.mem.readInt(u256, &bytes, .big), loadWordBigEndian(&bytes));

    var stored: [WORD_SIZE]u8 = undefined;
    storeWordBigEndian(&stored, expected);
    try std.testing.expectEqualSlices(u8, &bytes, &stored);

    const words = [_]u256{
        0,
        1,
        0xff,
        1 << 64,
        1 << 128,
        1 << 192,
        1 << 255,
        std.math.maxInt(u256),
        0xdeadbeef_00000000_cafebabe_11111111_22222222_33333333_44444444_55555555,
    };
    for (words) |word| {
        var buffer: [WORD_SIZE]u8 = undefined;
        storeWordBigEndian(&buffer, word);
        var reference: [WORD_SIZE]u8 = undefined;
        std.mem.writeInt(u256, &reference, word, .big);
        try std.testing.expectEqualSlices(u8, &reference, &buffer);
        try std.testing.expectEqual(word, loadWordBigEndian(&buffer));
    }
}

test "W3-8: limb conversion is a byte swap on little-endian hosts and the identity on big-endian hosts" {
    const limb: u64 = 0x0102030405060708;
    const native_is_little = @import("builtin").cpu.arch.endian() == .little;
    const expected: u64 = if (native_is_little) @byteSwap(limb) else limb;
    try std.testing.expectEqual(expected, std.mem.bigToNative(u64, limb));
    try std.testing.expectEqual(expected, std.mem.nativeToBig(u64, limb));

    // The value the helpers produce is the same one a per-byte big-endian read gives,
    // which does not depend on the host at all.
    const zeros: [24]u8 = @splat(0);
    const bytes = zeros ++ [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    var by_bytes: u256 = 0;
    for (bytes) |byte| by_bytes = (by_bytes << 8) | byte;
    try std.testing.expectEqual(by_bytes, loadWordBigEndian(&bytes));
}

test "W3-14: deinit of an init_borrowed view on an owned Memory type leaves the owner usable" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .initial_capacity = 64, .memory_limit = 1 << 20, .owned = true });

    var owner = try Mem.init(allocator);
    defer owner.deinit(allocator);
    try std.testing.expect(owner.ownsBuffer());
    try owner.set_data(allocator, 0, &.{ 0xAA, 0xBB, 0xCC });

    var borrowed = try Mem.init_borrowed(owner.buffer_ptr, 32);
    try std.testing.expect(!borrowed.ownsBuffer());
    try borrowed.set_data(allocator, 0, &.{ 0x11, 0x22 });
    // Twice: a borrowed view frees nothing however often it is released.
    borrowed.deinit(allocator);
    borrowed.deinit(allocator);

    // The owner's buffer is alive, holds both writes, and still grows.
    try std.testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB, 0xCC }, owner.buffer_ptr.items[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22 }, owner.buffer_ptr.items[32..34]);
    try owner.set_data(allocator, 96, &.{0xEE});
    try std.testing.expectEqual(@as(u8, 0xEE), owner.buffer_ptr.items[96]);
}

test "W3-14: a borrowed view of a caller-owned list is never freed and clear leaves the caller's bytes" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .initial_capacity = 64, .memory_limit = 1 << 20, .owned = true, .flat = true });

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    try list.appendNTimes(allocator, 0x5A, 64);

    var view = try Mem.init_borrowed(&list, 32);
    try std.testing.expect(!view.ownsBuffer());
    view.clear();
    try std.testing.expectEqual(@as(usize, 0), view.size());
    try std.testing.expectEqual(@as(usize, 64), list.items.len);
    try std.testing.expectEqual(@as(u8, 0x5A), list.items[0]);
    view.deinit(allocator);

    // `list` is still the caller's to use and to free (the deferred deinit above).
    try list.append(allocator, 0x01);
    try std.testing.expectEqual(@as(usize, 65), list.items.len);
}

test "W3-14: deinit of an owning Memory is idempotent" {
    const allocator = std.testing.allocator;
    const Mem = Memory(.{ .owned = true });
    var memory = try Mem.init(allocator);
    try memory.set_data(allocator, 0, &.{0x01});
    memory.deinit(allocator);
    try std.testing.expect(!memory.ownsBuffer());
    memory.deinit(allocator);
}
