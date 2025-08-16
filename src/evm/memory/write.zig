const std = @import("std");
const builtin = @import("builtin");
const Log = @import("../log.zig");
const memory = @import("./memory.zig");
const errors = @import("errors.zig");
const context = @import("context.zig");

// Safety check constants - only enabled in Debug and ReleaseSafe modes
// These checks are redundant after analysis.zig validates memory operations
const SAFE_MEMORY_BOUNDS = builtin.mode != .ReleaseFast and builtin.mode != .ReleaseSmall;

// NOTE: This file has been reviewed for issue #8 optimization opportunities.
// All manual loops have been replaced with std.mem functions:
// - @memcpy is used for data copying (lines 21, 52-55)
// - @memset is used for zero-filling (lines 42, 60)
// - std.mem.writeInt is used for u256 conversion (line 69)
// No further optimizations are needed.

/// Write arbitrary data at context-relative offset.
pub fn set_data(self: *memory.Memory, relative_offset: usize, data: []const u8) errors.MemoryError!void {
    // Debug logging removed for fuzz testing compatibility
    if (data.len == 0) return;

    const end = std.math.add(usize, relative_offset, data.len) catch {
        // Debug logging removed for fuzz testing compatibility
        return errors.MemoryError.InvalidSize;
    };
    _ = try self.ensure_context_capacity(end);

    const abs_offset = self.my_checkpoint + relative_offset;
    const abs_end = abs_offset + data.len;
    // Debug logging removed for fuzz testing compatibility
    @memcpy(self.shared_buffer_ref.items[abs_offset..abs_end], data);
}

/// Write data with source offset and length (handles partial copies and zero-fills).
pub fn set_data_bounded(
    self: *memory.Memory,
    relative_memory_offset: usize,
    data: []const u8,
    data_offset: usize,
    len: usize,
) errors.MemoryError!void {
    if (len == 0) return;

    const end = std.math.add(usize, relative_memory_offset, len) catch return errors.MemoryError.InvalidSize;
    _ = try self.ensure_context_capacity(end);

    const abs_offset = self.my_checkpoint + relative_memory_offset;
    const abs_end = abs_offset + len;

    // If source offset is beyond data bounds, fill with zeros
    if (data_offset >= data.len) {
        @memset(self.shared_buffer_ref.items[abs_offset..abs_end], 0);
        return;
    }

    // Calculate how much we can actually copy
    const data_end = @min(data_offset + len, data.len);
    const copy_len = data_end - data_offset;

    // Copy available data
    if (copy_len > 0) {
        @memcpy(
            self.shared_buffer_ref.items[abs_offset .. abs_offset + copy_len],
            data[data_offset..data_end],
        );
    }

    // Zero-fill the rest
    if (copy_len < len) {
        @memset(self.shared_buffer_ref.items[abs_offset + copy_len .. abs_end], 0);
    }
}

/// Write u256 value at context-relative offset (for test compatibility)
pub fn set_u256(self: *memory.Memory, relative_offset: usize, value: u256) errors.MemoryError!void {
    _ = try self.ensure_context_capacity(relative_offset + 32);
    const abs_offset = self.my_checkpoint + relative_offset;
    const bytes_ptr: *[32]u8 = @ptrCast(self.shared_buffer_ref.items[abs_offset .. abs_offset + 32].ptr);
    std.mem.writeInt(u256, bytes_ptr, value, .big);
}

/// Write u256 value without capacity expansion.
/// SAFETY: Caller must ensure memory already has capacity for offset + 32
/// Use only for operations pre-validated by analysis.zig
pub fn set_u256_unsafe(self: *memory.Memory, relative_offset: usize, value: u256) void {
    if (SAFE_MEMORY_BOUNDS) {
        std.debug.assert(relative_offset + 32 <= self.context_size());
    }
    const abs_offset = self.my_checkpoint + relative_offset;
    const bytes_ptr: *[32]u8 = @ptrCast(self.shared_buffer_ref.items[abs_offset .. abs_offset + 32].ptr);
    std.mem.writeInt(u256, bytes_ptr, value, .big);
}

/// Write arbitrary data without capacity expansion.
/// SAFETY: Caller must ensure memory already has capacity for offset + data.len
/// Use only for operations pre-validated by analysis.zig
pub fn set_data_unsafe(self: *memory.Memory, relative_offset: usize, data: []const u8) void {
    if (data.len == 0) return;

    if (SAFE_MEMORY_BOUNDS) {
        std.debug.assert(relative_offset + data.len <= self.context_size());
    }

    const abs_offset = self.my_checkpoint + relative_offset;
    const abs_end = abs_offset + data.len;
    @memcpy(self.shared_buffer_ref.items[abs_offset..abs_end], data);
}
