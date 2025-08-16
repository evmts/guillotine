const std = @import("std");
const builtin = @import("builtin");
const Log = @import("../log.zig");
const memory = @import("./memory.zig");
const errors = @import("errors.zig");
const context = @import("context.zig");

// Safety check constants - only enabled in Debug and ReleaseSafe modes
// These checks are redundant after analysis.zig validates memory operations
const SAFE_MEMORY_BOUNDS = builtin.mode != .ReleaseFast and builtin.mode != .ReleaseSmall;

/// Read 32 bytes as u256 at context-relative offset.
/// Includes bounds checking in Debug/ReleaseSafe modes.
pub fn get_u256(self: *const memory.Memory, relative_offset: usize) errors.MemoryError!u256 {
    if (SAFE_MEMORY_BOUNDS) {
        if (relative_offset + 32 > self.context_size()) {
            @branchHint(.cold);
            return errors.MemoryError.InvalidOffset;
        }
    }
    const abs_offset = self.my_checkpoint + relative_offset;
    const bytes = self.shared_buffer_ref.items[abs_offset .. abs_offset + 32];
    return std.mem.readInt(u256, bytes[0..32], .big);
}

/// Read 32 bytes as u256 at context-relative offset without bounds checking.
/// SAFETY: Caller must ensure offset + 32 <= context_size()
/// Use only for operations pre-validated by analysis.zig
pub fn get_u256_unsafe(self: *const memory.Memory, relative_offset: usize) u256 {
    if (SAFE_MEMORY_BOUNDS) {
        std.debug.assert(relative_offset + 32 <= self.context_size());
    }
    const abs_offset = self.my_checkpoint + relative_offset;
    const bytes = self.shared_buffer_ref.items[abs_offset .. abs_offset + 32];
    return std.mem.readInt(u256, bytes[0..32], .big);
}

/// Read arbitrary slice of memory at context-relative offset.
/// Includes bounds checking in Debug/ReleaseSafe modes.
pub fn get_slice(self: *const memory.Memory, relative_offset: usize, len: usize) errors.MemoryError![]const u8 {
    if (len == 0) return &[_]u8{};

    if (SAFE_MEMORY_BOUNDS) {
        const end = std.math.add(usize, relative_offset, len) catch {
            @branchHint(.cold);
            return errors.MemoryError.InvalidSize;
        };
        if (end > self.context_size()) {
            @branchHint(.cold);
            return errors.MemoryError.InvalidOffset;
        }
    }

    const abs_offset = self.my_checkpoint + relative_offset;
    const abs_end = abs_offset + len;
    return self.shared_buffer_ref.items[abs_offset..abs_end];
}

/// Read arbitrary slice without bounds checking.
/// SAFETY: Caller must ensure offset + len <= context_size() and no overflow
/// Use only for operations pre-validated by analysis.zig
pub fn get_slice_unsafe(self: *const memory.Memory, relative_offset: usize, len: usize) []const u8 {
    if (len == 0) return &[_]u8{};

    if (SAFE_MEMORY_BOUNDS) {
        std.debug.assert(relative_offset + len <= self.context_size());
    }

    const abs_offset = self.my_checkpoint + relative_offset;
    const abs_end = abs_offset + len;
    return self.shared_buffer_ref.items[abs_offset..abs_end];
}

/// Read a single byte at context-relative offset (for test compatibility)
pub fn get_byte(self: *const memory.Memory, relative_offset: usize) errors.MemoryError!u8 {
    if (SAFE_MEMORY_BOUNDS) {
        if (relative_offset >= self.context_size()) {
            @branchHint(.cold);
            return errors.MemoryError.InvalidOffset;
        }
    }
    const abs_offset = self.my_checkpoint + relative_offset;
    return self.shared_buffer_ref.items[abs_offset];
}
