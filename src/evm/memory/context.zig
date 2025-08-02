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

/// Fast inline wrapper for memory capacity checks.
/// Hot path: if buffer is already large enough, returns immediately with zero overhead.
/// Cold path: calls the noinline expansion function for complex resizing logic.
pub inline fn ensure_context_capacity(self: *Memory, min_context_size: usize) MemoryError!u64 {
    const required_total_len = self.my_checkpoint + min_context_size;
    
    // Hot path: buffer is already large enough
    if (required_total_len <= self.shared_buffer_ref.items.len) {
        return 0;
    }
    
    // Cold path: need expansion, call the slow path
    return self.ensure_context_capacity_slow(min_context_size);
}

/// Ensures the current context's memory region is at least `min_context_size` bytes.
/// Returns the number of *new 32-byte words added to the shared_buffer* if it expanded.
/// This is crucial for EVM gas calculation.
/// This is the slow path that handles the actual memory expansion logic.
/// Should only be called when expansion is actually needed.
pub noinline fn ensure_context_capacity_slow(self: *Memory, min_context_size: usize) MemoryError!u64 {
    const zone = tracy.zone(@src(), "memory_ensure_capacity\x00");
    defer zone.end();
    
    const required_total_len = self.my_checkpoint + min_context_size;
    Log.debug("Memory.ensure_context_capacity_slow: Ensuring capacity, min_context_size={}, required_total_len={}, memory_limit={}", .{ min_context_size, required_total_len, self.memory_limit });

    if (required_total_len > self.memory_limit) {
        Log.debug("Memory.ensure_context_capacity_slow: Memory limit exceeded, required={}, limit={}", .{ required_total_len, self.memory_limit });
        return MemoryError.MemoryLimitExceeded;
    }

    const shared_buffer = self.shared_buffer_ref;
    const old_total_buffer_len = shared_buffer.items.len;
    const old_total_words = constants.calculate_num_words(old_total_buffer_len);

    // Note: We should only reach here when expansion is actually needed
    // The inline wrapper already checked if (required_total_len <= old_total_buffer_len)

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

test "ensure_context_capacity hot path no expansion" {
    const allocator = std.testing.allocator;
    var memory = try Memory.init(allocator, 1024, 8192);
    defer memory.deinit();
    
    // Expand to some size first
    _ = try memory.ensure_context_capacity(512);
    
    // Now test hot path - requesting same or smaller size should return 0
    const words_added1 = try memory.ensure_context_capacity(512);
    try std.testing.expectEqual(@as(u64, 0), words_added1);
    
    const words_added2 = try memory.ensure_context_capacity(256);
    try std.testing.expectEqual(@as(u64, 0), words_added2);
    
    const words_added3 = try memory.ensure_context_capacity(0);
    try std.testing.expectEqual(@as(u64, 0), words_added3);
}

test "ensure_context_capacity cold path expansion" {
    const allocator = std.testing.allocator;
    var memory = try Memory.init(allocator, 64, 8192);
    defer memory.deinit();
    
    // Test cold path - actual expansion needed
    const initial_size = memory.context_size();
    try std.testing.expectEqual(@as(usize, 0), initial_size);
    
    // Expand to 96 bytes (3 words)
    const words_added1 = try memory.ensure_context_capacity(96);
    try std.testing.expectEqual(@as(u64, 3), words_added1);
    try std.testing.expectEqual(@as(usize, 96), memory.context_size());
    
    // Expand to 160 bytes (5 words) - should add 2 more words
    const words_added2 = try memory.ensure_context_capacity(160);
    try std.testing.expectEqual(@as(u64, 2), words_added2);
    try std.testing.expectEqual(@as(usize, 160), memory.context_size());
}

test "ensure_context_capacity mixed hot and cold path" {
    const allocator = std.testing.allocator;
    var memory = try Memory.init(allocator, 32, 4096);
    defer memory.deinit();
    
    // Cold path: initial expansion
    const words_added1 = try memory.ensure_context_capacity(64);
    try std.testing.expectEqual(@as(u64, 2), words_added1);
    
    // Hot path: no expansion needed
    const words_added2 = try memory.ensure_context_capacity(64);
    try std.testing.expectEqual(@as(u64, 0), words_added2);
    
    const words_added3 = try memory.ensure_context_capacity(32);
    try std.testing.expectEqual(@as(u64, 0), words_added3);
    
    // Cold path: further expansion
    const words_added4 = try memory.ensure_context_capacity(128);
    try std.testing.expectEqual(@as(u64, 2), words_added4);
    
    // Hot path: no expansion needed
    const words_added5 = try memory.ensure_context_capacity(128);
    try std.testing.expectEqual(@as(u64, 0), words_added5);
}

test "ensure_context_capacity memory limit enforcement" {
    const allocator = std.testing.allocator;
    const memory_limit = 256;
    var memory = try Memory.init(allocator, 32, memory_limit);
    defer memory.deinit();
    
    // Should succeed within limit
    _ = try memory.ensure_context_capacity(200);
    
    // Should fail when exceeding limit
    const result = memory.ensure_context_capacity(300);
    try std.testing.expectError(MemoryError.MemoryLimitExceeded, result);
}

test "ensure_context_capacity child memory context" {
    const allocator = std.testing.allocator;
    var parent = try Memory.init(allocator, 128, 2048);
    defer parent.deinit();
    
    // Expand parent first
    _ = try parent.ensure_context_capacity(128);
    
    // Create child with checkpoint at 64
    var child = try parent.init_child_memory(64);
    
    // Child's context size should be buffer_size - checkpoint
    try std.testing.expectEqual(@as(usize, 64), child.context_size());
    
    // Hot path: child requesting size within existing buffer
    const words_added1 = try child.ensure_context_capacity(32);
    try std.testing.expectEqual(@as(u64, 0), words_added1);
    
    // Cold path: child needs expansion
    const words_added2 = try child.ensure_context_capacity(96);
    try std.testing.expectEqual(@as(u64, 1), words_added2);
    
    // Verify parent buffer grew
    try std.testing.expectEqual(@as(usize, 160), parent.context_size());
}
