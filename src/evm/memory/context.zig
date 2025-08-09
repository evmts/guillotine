const std = @import("std");
const Log = @import("../log.zig");
const Memory = @import("./memory.zig").Memory;
const MemoryError = @import("errors.zig").MemoryError;
const constants = @import("constants.zig");
const tracy = @import("../tracy_support.zig");

/// Returns the size of the memory region visible to the current context.
pub inline fn context_size(self: *const Memory) usize {
    const total_len = self.shared_buffer_ref.items.len;
    return total_len -| self.my_checkpoint;
}

/// Inline wrapper for ensure_context_capacity that handles the common case where no expansion is needed.
/// This avoids function call overhead for the majority of memory operations.
pub inline fn ensure_context_capacity(self: *Memory, min_context_size: usize) MemoryError!u64 {
    // Fast path: Check if memory is already large enough (common case)
    const required_total_len = self.my_checkpoint + min_context_size;
    const current_len = self.shared_buffer_ref.items.len;
    
    if (required_total_len <= current_len) {
        @branchHint(.likely); // Most memory operations don't require expansion
        // Memory is already large enough - no expansion needed
        // This is the hot path that benefits from inlining
        return 0;
    }
    
    // Slow path: Delegate to the non-inline implementation for actual expansion
    return self.ensure_context_capacity_slow(min_context_size);
}

/// Non-inline implementation of memory expansion for when actual expansion is needed.
/// This keeps the complex expansion logic out of the inline hot path.
pub noinline fn ensure_context_capacity_slow(self: *Memory, min_context_size: usize) MemoryError!u64 {
    const zone = tracy.zone(@src(), "memory_ensure_capacity\x00");
    defer zone.end();
    
    const required_total_len = self.my_checkpoint + min_context_size;
    Log.debug("Memory.ensure_context_capacity: Ensuring capacity, min_context_size={}, required_total_len={}, memory_limit={}", .{ min_context_size, required_total_len, self.memory_limit });

    if (required_total_len > self.memory_limit) {
        Log.debug("Memory.ensure_context_capacity: Memory limit exceeded, required={}, limit={}", .{ required_total_len, self.memory_limit });
        return MemoryError.MemoryLimitExceeded;
    }

    const shared_buffer = self.shared_buffer_ref;
    const old_total_buffer_len = shared_buffer.items.len;
    const old_total_words = constants.calculate_num_words(old_total_buffer_len);
    
    // Note: We already checked in the inline wrapper that expansion is needed,
    // so we can skip the redundant check here

    // Resize the buffer
    const resize_zone = tracy.zone(@src(), "memory_resize\x00");
    const new_total_len = required_total_len;
    Log.debug("Memory.ensure_context_capacity: Expanding buffer from {} to {} bytes", .{ old_total_buffer_len, new_total_len });

    if (new_total_len > shared_buffer.capacity) {
        var new_capacity = shared_buffer.capacity;
        if (new_capacity == 0) new_capacity = 1; // Handle initial zero capacity
        while (new_capacity < new_total_len) {
            const doubled = @mulWithOverflow(new_capacity, 2);
            if (doubled[1] != 0) {
                // Overflow occurred
                return MemoryError.OutOfMemory;
            }
            new_capacity = doubled[0];
        }
        // Ensure new_capacity doesn't exceed memory_limit
        if (new_capacity > self.memory_limit and self.memory_limit <= std.math.maxInt(usize)) {
            new_capacity = @intCast(self.memory_limit);
        }
        if (new_total_len > new_capacity) return MemoryError.MemoryLimitExceeded;
        try shared_buffer.ensureTotalCapacity(new_capacity);
    }

    // Set new length and zero-initialize the newly added part
    shared_buffer.items.len = new_total_len;
    @memset(shared_buffer.items[old_total_buffer_len..new_total_len], 0);

    resize_zone.end();
    
    const new_total_words = constants.calculate_num_words(new_total_len);
    const words_added = new_total_words -| old_total_words;
    Log.debug("Memory.ensure_context_capacity: Expansion complete, old_words={}, new_words={}, words_added={}", .{ old_total_words, new_total_words, words_added });
    return words_added;
}

/// Resize the context to the specified size (for test compatibility)
pub noinline fn resize_context(self: *Memory, new_size: usize) MemoryError!void {
    _ = try self.ensure_context_capacity(new_size);
}

/// Get the memory size (alias for context_size for test compatibility)
pub inline fn size(self: *const Memory) usize {
    return self.context_size();
}

/// Get total size of memory (context size)
pub inline fn total_size(self: *const Memory) usize {
    return self.context_size();
}
