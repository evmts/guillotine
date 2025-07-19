const std = @import("std");
const Log = @import("../log.zig");
const memory = @import("./memory.zig");
const errors = @import("errors.zig");
const context = @import("context.zig");

/// Read 32 bytes as u256 at context-relative offset.
pub inline fn get_u256(self: *const memory.Memory, relative_offset: usize) errors.MemoryError!u256 {
    if (relative_offset + 32 > self.context_size()) {
        return errors.MemoryError.InvalidOffset;
    }
    const abs_offset = self.my_checkpoint + relative_offset;
    const bytes = self.shared_buffer_ref.items[abs_offset .. abs_offset + 32];
    return std.mem.readInt(u256, bytes[0..32], .big);
}

/// Read arbitrary slice of memory at context-relative offset.
pub inline fn get_slice(self: *const memory.Memory, relative_offset: usize, len: usize) errors.MemoryError![]const u8 {
    // Debug logging removed for fuzz testing compatibility
    if (len == 0) return &[_]u8{};
    const end = std.math.add(usize, relative_offset, len) catch {
        // Debug logging removed for fuzz testing compatibility
        return errors.MemoryError.InvalidSize;
    };
    if (end > self.context_size()) {
        // Debug logging removed for fuzz testing compatibility
        return errors.MemoryError.InvalidOffset;
    }
    const abs_offset = self.my_checkpoint + relative_offset;
    const abs_end = abs_offset + len;
    // Debug logging removed for fuzz testing compatibility
    return self.shared_buffer_ref.items[abs_offset..abs_end];
}

/// Read a single byte at context-relative offset (for test compatibility)
pub inline fn get_byte(self: *const memory.Memory, relative_offset: usize) errors.MemoryError!u8 {
    if (relative_offset >= self.context_size()) return errors.MemoryError.InvalidOffset;
    const abs_offset = self.my_checkpoint + relative_offset;
    return self.shared_buffer_ref.items[abs_offset];
}
