const std = @import("std");
const Frame = @import("frame_fat.zig");
const constants = @import("../memory/constants.zig");

/// Memory error types
pub const MemoryError = error{
    OutOfGas,
    AllocationError,
    Overflow,
    OutOfMemory,
};

// ============================================================================
// MEMORY SIZE AND CAPACITY OPERATIONS
// ============================================================================

/// Get the current context size (memory size relative to checkpoint).
///
/// @param self The frame containing the memory
/// @return Size of memory for this context in bytes
pub fn memory_context_size(self: *const Frame) usize {
    const total = self.memory_shared_buffer_ref.items.len;
    return if (total > self.memory_checkpoint) total - self.memory_checkpoint else 0;
}

/// Get the total size of the shared buffer.
///
/// @param self The frame containing the memory
/// @return Total size of shared buffer in bytes
pub fn memory_total_size(self: *const Frame) usize {
    return self.memory_shared_buffer_ref.items.len;
}

/// Alias for memory_context_size for compatibility.
pub const memory_size = memory_context_size;

/// Ensure memory has capacity for the given size.
///
/// Expands memory if needed and charges gas for expansion.
///
/// @param self The frame containing the memory
/// @param size Required memory size in bytes
/// @throws OutOfGas if insufficient gas for expansion
/// @throws OutOfMemory if size exceeds memory limit
/// @throws AllocationError if memory allocation fails
pub fn memory_ensure_capacity(self: *Frame, size: u64) MemoryError!void {
    const current_size = @as(u64, @intCast(self.memory_context_size()));
    
    if (size <= current_size) {
        return;
    }
    
    if (size > self.memory_limit) {
        return MemoryError.OutOfMemory;
    }
    
    // Gas calculation handled by caller
    
    const total_size = self.memory_checkpoint + size;
    self.memory_shared_buffer_ref.resize(@intCast(total_size)) catch |err| {
        return switch (err) {
            error.OutOfMemory => MemoryError.AllocationError,
        };
    };
}

/// Resize context memory to exact size.
///
/// @param self The frame containing the memory
/// @param new_size New size in bytes
/// @throws AllocationError if resize fails
pub fn memory_resize_context(self: *Frame, new_size: usize) MemoryError!void {
    const total_size = self.memory_checkpoint + new_size;
    self.memory_shared_buffer_ref.resize(total_size) catch |err| {
        return switch (err) {
            error.OutOfMemory => MemoryError.AllocationError,
        };
    };
}

// ============================================================================
// MEMORY READ OPERATIONS
// ============================================================================

/// Read a u256 value from memory.
///
/// Reads 32 bytes from the specified offset and interprets as big-endian u256.
/// If reading beyond memory bounds, pads with zeros.
///
/// @param self The frame containing the memory
/// @param offset Byte offset to read from
/// @return The u256 value (zero-padded if necessary)
pub fn memory_get_u256(self: *const Frame, offset: u64) u256 {
    const offset_usize = @as(usize, @intCast(offset));
    const context_offset = self.memory_checkpoint + offset_usize;
    const buffer = self.memory_shared_buffer_ref.items;
    
    if (context_offset >= buffer.len) {
        return 0;
    }
    
    const available = buffer.len - context_offset;
    if (available >= 32) {
        var bytes: [32]u8 = undefined;
        @memcpy(&bytes, buffer[context_offset..context_offset + 32]);
        return std.mem.readInt(u256, &bytes, .big);
    }
    
    // Partial read with zero padding
    var bytes = [_]u8{0} ** 32;
    @memcpy(bytes[0..available], buffer[context_offset..]);
    return std.mem.readInt(u256, &bytes, .big);
}

/// Get a single byte from memory.
///
/// @param self The frame containing the memory
/// @param offset Byte offset
/// @return The byte value or 0 if out of bounds
pub fn memory_get_byte(self: *const Frame, offset: u64) u8 {
    const offset_usize = @as(usize, @intCast(offset));
    const context_offset = self.memory_checkpoint + offset_usize;
    const buffer = self.memory_shared_buffer_ref.items;
    
    if (context_offset >= buffer.len) {
        return 0;
    }
    
    return buffer[context_offset];
}

/// Get a slice of memory.
///
/// Returns a slice of the requested size starting at offset.
/// The returned slice may be shorter if it would exceed memory bounds.
///
/// @param self The frame containing the memory
/// @param offset Starting byte offset
/// @param size Number of bytes to get
/// @return Slice of memory (may be empty or shorter than requested)
pub fn memory_get_slice(self: *const Frame, offset: u64, size: u64) []const u8 {
    const offset_usize = @as(usize, @intCast(offset));
    const size_usize = @as(usize, @intCast(size));
    const context_offset = self.memory_checkpoint + offset_usize;
    const buffer = self.memory_shared_buffer_ref.items;
    
    if (context_offset >= buffer.len) {
        return &[_]u8{};
    }
    
    const available = buffer.len - context_offset;
    const actual_size = @min(size_usize, available);
    
    return buffer[context_offset..context_offset + actual_size];
}

/// Read memory into a destination buffer.
///
/// @param self The frame containing the memory
/// @param offset Source offset in memory
/// @param dest Destination buffer
/// @throws OutOfMemory if offset + dest.len would overflow
pub fn memory_read(self: *const Frame, offset: u64, dest: []u8) MemoryError!void {
    if (dest.len == 0) return;
    
    const offset_usize = @as(usize, @intCast(offset));
    const context_offset = self.memory_checkpoint + offset_usize;
    const buffer = self.memory_shared_buffer_ref.items;
    
    if (context_offset >= buffer.len) {
        @memset(dest, 0);
        return;
    }
    
    const available = buffer.len - context_offset;
    if (available >= dest.len) {
        @memcpy(dest, buffer[context_offset..context_offset + dest.len]);
    } else {
        @memcpy(dest[0..available], buffer[context_offset..]);
        @memset(dest[available..], 0);
    }
}

// ============================================================================
// MEMORY WRITE OPERATIONS
// ============================================================================

/// Write data to memory at the specified offset.
///
/// Expands memory if necessary. Overwrites existing data.
///
/// @param self The frame containing the memory
/// @param offset Byte offset to write at
/// @param data Data to write
/// @throws AllocationError if memory expansion fails
pub fn memory_write(self: *Frame, offset: u64, data: []const u8) MemoryError!void {
    if (data.len == 0) return;
    
    const offset_usize = @as(usize, @intCast(offset));
    const end_offset = offset + data.len;
    
    try self.memory_ensure_capacity(end_offset);
    
    const context_offset = self.memory_checkpoint + offset_usize;
    const buffer = self.memory_shared_buffer_ref.items;
    
    @memcpy(buffer[context_offset..context_offset + data.len], data);
}

/// Set data in memory with bounds checking.
///
/// Similar to memory_write but with explicit size parameter.
///
/// @param self The frame containing the memory
/// @param offset Byte offset to write at
/// @param size Number of bytes to write
/// @param data Source data (must be at least size bytes)
/// @throws AllocationError if memory expansion fails
pub fn memory_set_data(self: *Frame, offset: u64, size: u64, data: []const u8) MemoryError!void {
    if (size == 0) return;
    
    const size_usize = @as(usize, @intCast(size));
    const actual_size = @min(size_usize, data.len);
    
    try self.memory_write(offset, data[0..actual_size]);
    
    // Zero-pad if size > data.len
    if (size_usize > data.len) {
        const pad_offset = offset + data.len;
        const pad_size = size_usize - data.len;
        try self.memory_zero(pad_offset, pad_size);
    }
}

/// Write a u256 value to memory.
///
/// Stores the value as 32 big-endian bytes.
///
/// @param self The frame containing the memory
/// @param offset Byte offset to write at
/// @param value The u256 value to write
/// @throws AllocationError if memory expansion fails
pub fn memory_set_u256(self: *Frame, offset: u64, value: u256) MemoryError!void {
    var bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &bytes, value, .big);
    try self.memory_write(offset, &bytes);
}

/// Zero out a region of memory.
///
/// @param self The frame containing the memory
/// @param offset Starting byte offset
/// @param size Number of bytes to zero
/// @throws AllocationError if memory expansion fails
fn memory_zero(self: *Frame, offset: u64, size: usize) MemoryError!void {
    if (size == 0) return;
    
    const end_offset = offset + size;
    try self.memory_ensure_capacity(end_offset);
    
    const offset_usize = @as(usize, @intCast(offset));
    const context_offset = self.memory_checkpoint + offset_usize;
    const buffer = self.memory_shared_buffer_ref.items;
    
    @memset(buffer[context_offset..context_offset + size], 0);
}

// ============================================================================
// MEMORY GAS CALCULATION
// ============================================================================

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

/// Get memory expansion gas cost with caching optimization.
///
/// Returns the gas cost for expanding memory from current size to new_size.
/// Uses lookup table for small sizes and cached values for larger sizes.
///
/// @param self The frame containing the memory
/// @param new_size Target memory size in bytes
/// @return Gas cost for expansion (0 if no expansion needed)
pub fn memory_get_expansion_cost(self: *Frame, new_size: u64) u64 {
    const current_size = @as(u64, @intCast(self.memory_context_size()));
    
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
    if (new_size == self.memory_cached_expansion.last_size) {
        const current_cost = if (current_size == 0) 0 else calculate_memory_total_cost(current_size);
        return self.memory_cached_expansion.last_cost -| current_cost;
    }
    
    // Calculate new cost and update cache
    const new_cost = calculate_memory_total_cost(new_size);
    const current_cost = if (current_size == 0) 0 else calculate_memory_total_cost(current_size);
    const expansion_cost = new_cost - current_cost;
    
    // Update cache
    self.memory_cached_expansion.last_size = new_size;
    self.memory_cached_expansion.last_cost = new_cost;
    
    return expansion_cost;
}

/// Calculate total memory cost for a given size (internal helper).
inline fn calculate_memory_total_cost(size_bytes: u64) u64 {
    const words = (size_bytes + 31) / 32;
    return 3 * words + (words * words) / 512;
}

// ============================================================================
// MEMORY SLICE OPERATIONS
// ============================================================================

/// Get a mutable slice of the entire memory context.
///
/// @param self The frame containing the memory
/// @return Mutable slice of memory from checkpoint to end
pub fn memory_slice(self: *Frame) []u8 {
    const buffer = self.memory_shared_buffer_ref.items;
    if (self.memory_checkpoint >= buffer.len) {
        return &[_]u8{};
    }
    return buffer[self.memory_checkpoint..];
}

/// Get an immutable slice of the entire memory context.
///
/// @param self The frame containing the memory
/// @return Immutable slice of memory from checkpoint to end
pub fn memory_slice_const(self: *const Frame) []const u8 {
    const buffer = self.memory_shared_buffer_ref.items;
    if (self.memory_checkpoint >= buffer.len) {
        return &[_]u8{};
    }
    return buffer[self.memory_checkpoint..];
}

/// Write data with source offset and length (handles partial copies and zero-fills).
///
/// This function is used by EXTCODECOPY and similar operations that need to copy
/// data from an external source with specific offset and length constraints.
///
/// @param self The frame containing the memory
/// @param relative_memory_offset Destination offset in memory
/// @param data Source data to copy from
/// @param data_offset Offset within source data to start copying
/// @param len Number of bytes to copy
/// @throws InvalidSize if memory calculations overflow
/// @throws AllocationError if memory expansion fails
pub fn memory_set_data_bounded(
    self: *Frame,
    relative_memory_offset: usize,
    data: []const u8,
    data_offset: usize,
    len: usize,
) MemoryError!void {
    if (len == 0) return;

    const end = std.math.add(usize, relative_memory_offset, len) catch return MemoryError.Overflow;
    try self.memory_ensure_capacity(@intCast(end));

    const abs_offset = self.memory_checkpoint + relative_memory_offset;
    const abs_end = self.memory_checkpoint + end;

    // Calculate how much data can be copied from source
    const copy_start = @min(data_offset, data.len);
    const copy_len = @min(if (data_offset < data.len) data.len - data_offset else 0, len);

    if (copy_len > 0) {
        // Copy available data
        @memcpy(
            self.memory_shared_buffer_ref.items[abs_offset..abs_offset + copy_len],
            data[copy_start..copy_start + copy_len],
        );
    }

    // Zero-fill the remaining bytes if necessary
    if (copy_len < len) {
        const zero_start = abs_offset + copy_len;
        const zero_end = abs_end;
        @memset(self.memory_shared_buffer_ref.items[zero_start..zero_end], 0);
    }
}