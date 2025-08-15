//! Capture utilities for bounded EVM state snapshots
//!
//! This module provides efficient functions for capturing bounded snapshots of
//! EVM execution state (stack, memory, storage changes, logs) with configurable
//! limits to prevent excessive memory usage during tracing.
//!
//! ## Design Principles
//!
//! - **Bounded Capture**: All functions respect configured memory limits
//! - **Minimal Copies**: Only copy what's needed, use windowing for large data
//! - **Safe Access**: Proper bounds checking and error handling
//! - **Delta Tracking**: Capture only changes since last step
//! - **Memory Ownership**: Clear ownership transfer semantics
//!
//! ## Usage Pattern
//!
//! These functions are called from the interpreter post-step hooks to capture
//! bounded snapshots of execution state for structured tracing.

const std = @import("std");
const primitives = @import("primitives");
const tracer = @import("trace_types.zig");
const Memory = @import("../memory/memory.zig").Memory;
const CallJournal = @import("../call_frame_stack.zig").CallJournal;
const JournalEntry = @import("../call_frame_stack.zig").JournalEntry;
const EvmLog = @import("../state/evm_log.zig");
const Allocator = std.mem.Allocator;

/// Copy stack data with bounds checking
/// Returns null if stack is empty, otherwise returns bounded copy
/// Caller owns returned memory and must free it
pub fn copy_stack_bounded(
    allocator: Allocator,
    stack_data: []const u256,
    max_items: usize,
) !?[]u256 {
    if (stack_data.len == 0) return null;

    const copy_count = @min(stack_data.len, max_items);
    if (copy_count == 0) return null;

    // MEMORY ALLOCATION: Stack snapshot
    // Size: copy_count * 32 bytes (u256 is 32 bytes)
    // Lifetime: Until StructLog is freed by tracer
    const stack_copy = try allocator.alloc(u256, copy_count);
    errdefer allocator.free(stack_copy);

    // Copy stack data (most recent items first in EVM stack)
    @memcpy(stack_copy, stack_data[0..copy_count]);

    return stack_copy;
}

/// Copy memory with optional windowing around accessed region
/// Returns null if memory is empty or exceeds bounds
/// Caller owns returned memory and must free it
pub fn copy_memory_bounded(
    allocator: Allocator,
    memory: *const Memory,
    max_bytes: usize,
    accessed_region: ?struct { start: usize, len: usize },
) !?[]u8 {
    const memory_size = memory.context_size();
    if (memory_size == 0) return null;

    const copy_size = @min(memory_size, max_bytes);
    if (copy_size == 0) return null;

    // MEMORY ALLOCATION: Memory snapshot
    // Size: copy_size bytes
    // Lifetime: Until StructLog is freed by tracer
    const memory_copy = try allocator.alloc(u8, copy_size);
    errdefer allocator.free(memory_copy);

    if (accessed_region) |region| {
        // Create window around accessed region for better debugging
        const window_start = if (region.start >= max_bytes / 2)
            region.start - max_bytes / 2
        else
            0;
        const window_end = @min(memory_size, window_start + max_bytes);
        const actual_copy_size = window_end - window_start;

        const memory_ptr = memory.get_memory_ptr();
        const checkpoint = memory.get_checkpoint();
        const source_slice = memory_ptr[checkpoint + window_start .. checkpoint + window_start + actual_copy_size];

        @memcpy(memory_copy[0..actual_copy_size], source_slice);

        // Zero-fill remainder if we couldn't copy the full requested size
        if (actual_copy_size < copy_size) {
            @memset(memory_copy[actual_copy_size..copy_size], 0);
        }
    } else {
        // Copy from beginning of memory
        const memory_ptr = memory.get_memory_ptr();
        const checkpoint = memory.get_checkpoint();
        const source_slice = memory_ptr[checkpoint .. checkpoint + copy_size];

        @memcpy(memory_copy, source_slice);
    }

    return memory_copy;
}

/// Collect storage changes since given journal index
/// Returns empty slice if no storage changes found
/// Caller owns returned memory and must free it
pub fn collect_storage_changes_since(
    allocator: Allocator,
    journal: *const CallJournal,
    from_index: usize,
) ![]tracer.StorageChange {
    const entries = journal.entries.items;
    if (from_index >= entries.len) {
        return try allocator.alloc(tracer.StorageChange, 0);
    }

    // Count storage changes since from_index
    var change_count: usize = 0;
    for (entries[from_index..]) |entry| {
        if (entry == .storage_change) change_count += 1;
    }

    if (change_count == 0) {
        return try allocator.alloc(tracer.StorageChange, 0);
    }

    // MEMORY ALLOCATION: Storage changes array
    // Size: change_count * ~80 bytes per entry (Address + 2*u256)
    // Lifetime: Until StructLog is freed by tracer
    const changes = try allocator.alloc(tracer.StorageChange, change_count);
    errdefer allocator.free(changes);

    var i: usize = 0;
    for (entries[from_index..]) |entry| {
        switch (entry) {
            .storage_change => |sc| {
                changes[i] = tracer.StorageChange{
                    .address = sc.address,
                    .key = sc.key,
                    .value = sc.original_value, // Note: This needs to be updated to current value
                    .original_value = sc.original_value,
                };
                i += 1;
            },
            else => continue,
        }
    }

    return changes;
}

/// Get original storage value for a given address and key
/// Returns null if no original value is recorded
pub fn get_original_storage_value(
    journal: *const CallJournal,
    address: primitives.Address.Address,
    key: u256,
) ?u256 {
    if (journal.original_storage.get(address)) |address_storage| {
        return address_storage.get(key);
    }
    return null;
}

/// Copy recent log entries with bounded data
/// Returns empty slice if no new logs since from_index
/// Caller owns returned memory and must free nested allocations
pub fn copy_logs_bounded(
    allocator: Allocator,
    logs: []const EvmLog,
    from_index: usize,
    log_data_max_bytes: usize,
) ![]tracer.LogEntry {
    if (from_index >= logs.len) {
        return try allocator.alloc(tracer.LogEntry, 0);
    }

    const new_logs = logs[from_index..];
    if (new_logs.len == 0) {
        return try allocator.alloc(tracer.LogEntry, 0);
    }

    // MEMORY ALLOCATION: Log entries array
    // Size: new_logs.len * ~200 bytes per entry (varies by topics and data size)
    // Lifetime: Until StructLog is freed by tracer
    const log_entries = try allocator.alloc(tracer.LogEntry, new_logs.len);
    errdefer {
        // Clean up any partial allocations on failure
        for (log_entries[0..new_logs.len]) |*entry| {
            if (entry.topics.len > 0) allocator.free(entry.topics);
            if (entry.data.len > 0) allocator.free(entry.data);
        }
        allocator.free(log_entries);
    }

    for (new_logs, 0..) |log, i| {
        const data_size = @min(log.data.len, log_data_max_bytes);

        // Copy topic data (always include all topics - they're bounded by EVM spec)
        const topics_copy = try allocator.dupe(u256, log.topics);
        errdefer allocator.free(topics_copy);

        // Copy bounded log data
        const data_copy = try allocator.alloc(u8, data_size);
        errdefer allocator.free(data_copy);
        @memcpy(data_copy, log.data[0..data_size]);

        log_entries[i] = tracer.LogEntry{
            .address = log.address,
            .topics = topics_copy,
            .data = data_copy,
            .data_truncated = log.data.len > log_data_max_bytes,
        };
    }

    return log_entries;
}

/// Helper to create empty arrays for when there are no changes/logs
pub fn create_empty_storage_changes(allocator: Allocator) ![]tracer.StorageChange {
    return try allocator.alloc(tracer.StorageChange, 0);
}

/// Helper to create empty arrays for when there are no logs
pub fn create_empty_log_entries(allocator: Allocator) ![]tracer.LogEntry {
    return try allocator.alloc(tracer.LogEntry, 0);
}
