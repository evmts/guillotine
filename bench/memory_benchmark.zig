const std = @import("std");
const root = @import("root.zig");
const Evm = root.Evm;
const Memory = Evm.Memory;
const Allocator = std.mem.Allocator;

// Benchmark different initial capacities
pub fn bench_init_small_capacity(allocator: Allocator) void {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var memory = Memory.init(allocator, 256, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
        defer memory.deinit();
    }
}

pub fn bench_init_medium_capacity(allocator: Allocator) void {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var memory = Memory.init(allocator, 4096, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
        defer memory.deinit();
    }
}

pub fn bench_init_large_capacity(allocator: Allocator) void {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var memory = Memory.init(allocator, 65536, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
        defer memory.deinit();
    }
}

// Memory expansion benchmarks
pub fn bench_memory_expansion_incremental(allocator: Allocator) void {
    var memory = Memory.init(allocator, 256, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    var size: usize = 256;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        size += 256;
        _ = memory.ensure_context_capacity(size) catch unreachable;
    }
}

pub fn bench_memory_expansion_doubling(allocator: Allocator) void {
    var memory = Memory.init(allocator, 256, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    var size: usize = 256;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        size *= 2;
        _ = memory.ensure_context_capacity(size) catch unreachable;
    }
}

pub fn bench_memory_expansion_large_jump(allocator: Allocator) void {
    var memory = Memory.init(allocator, 256, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    // Jump straight to large sizes
    const sizes = [_]usize{ 1024, 16384, 65536, 262144, 1048576 };
    for (sizes) |size| {
        _ = memory.ensure_context_capacity(size) catch unreachable;
    }
}

// Read operation benchmarks
pub fn bench_get_u256_sequential(allocator: Allocator) void {
    var memory = Memory.init(allocator, 8192, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    // Fill memory with data
    const data = [_]u8{0xFF} ** 8192;
    memory.set_data(0, &data) catch unreachable;

    var offset: usize = 0;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        _ = memory.get_u256(offset) catch unreachable;
        offset = (offset + 32) % 8000; // Stay within bounds
    }
}

pub fn bench_get_u256_random(allocator: Allocator) void {
    var memory = Memory.init(allocator, 8192, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    // Fill memory with data
    const data = [_]u8{0xFF} ** 8192;
    memory.set_data(0, &data) catch unreachable;

    // Random access pattern
    const offsets = [_]usize{ 0, 3200, 1600, 4800, 800, 7000, 2400, 5600, 1200, 6400 };
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        for (offsets) |offset| {
            _ = memory.get_u256(offset) catch unreachable;
        }
    }
}

pub fn bench_get_slice_small(allocator: Allocator) void {
    var memory = Memory.init(allocator, 4096, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    // Fill memory with data
    const data = [_]u8{0xAB} ** 4096;
    memory.set_data(0, &data) catch unreachable;

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        _ = memory.get_slice(i % 4000, 32) catch unreachable;
    }
}

pub fn bench_get_slice_medium(allocator: Allocator) void {
    var memory = Memory.init(allocator, 65536, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    // Fill memory with data
    const data = [_]u8{0xCD} ** 65536;
    memory.set_data(0, &data) catch unreachable;

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = memory.get_slice(i * 256, 1024) catch unreachable;
    }
}

pub fn bench_get_slice_large(allocator: Allocator) void {
    var memory = Memory.init(allocator, 1048576, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    // Fill memory with data
    memory.resize_context(1048576) catch unreachable;

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = memory.get_slice(i * 65536, 65536) catch unreachable;
    }
}

pub fn bench_get_byte_sequential(allocator: Allocator) void {
    var memory = Memory.init(allocator, 4096, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    // Fill memory with data
    const data = [_]u8{0xEF} ** 4096;
    memory.set_data(0, &data) catch unreachable;

    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        _ = memory.get_byte(i) catch unreachable;
    }
}

// Write operation benchmarks
pub fn bench_set_data_small(allocator: Allocator) void {
    var memory = Memory.init(allocator, 4096, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    const data = [_]u8{0x42} ** 32;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        memory.set_data(i * 32, &data) catch unreachable;
    }
}

pub fn bench_set_data_medium(allocator: Allocator) void {
    var memory = Memory.init(allocator, 65536, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    const data = [_]u8{0x42} ** 1024;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        memory.set_data(i * 1024, &data) catch unreachable;
    }
}

pub fn bench_set_data_large(allocator: Allocator) void {
    var memory = Memory.init(allocator, 1048576, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    const data = [_]u8{0x42} ** 65536;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        memory.set_data(i * 65536, &data) catch unreachable;
    }
}

pub fn bench_set_u256_sequential(allocator: Allocator) void {
    var memory = Memory.init(allocator, 8192, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        memory.set_u256(i * 32, @as(u256, i)) catch unreachable;
    }
}

pub fn bench_set_u256_random(allocator: Allocator) void {
    var memory = Memory.init(allocator, 8192, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    const offsets = [_]usize{ 0, 3200, 1600, 4800, 800, 7000, 2400, 5600, 1200, 6400 };
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        for (offsets) |offset| {
            memory.set_u256(offset, @as(u256, i)) catch unreachable;
        }
    }
}

// Bounded write operations
pub fn bench_set_data_bounded_full_copy(allocator: Allocator) void {
    var memory = Memory.init(allocator, 4096, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    const source_data = [_]u8{0x42} ** 256;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        memory.set_data_bounded(i * 32, &source_data, 0, 256) catch unreachable;
    }
}

pub fn bench_set_data_bounded_partial_copy(allocator: Allocator) void {
    var memory = Memory.init(allocator, 4096, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    const source_data = [_]u8{0x42} ** 256;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        // Copy only 100 bytes from source, rest will be zero-filled
        memory.set_data_bounded(i * 32, &source_data, 50, 200) catch unreachable;
    }
}

pub fn bench_set_data_bounded_zero_fill(allocator: Allocator) void {
    var memory = Memory.init(allocator, 4096, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    const source_data = [_]u8{0x42} ** 32;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        // Source offset beyond data length - will zero-fill
        memory.set_data_bounded(i * 32, &source_data, 100, 256) catch unreachable;
    }
}

// Shared buffer architecture benchmarks
pub fn bench_child_memory_creation(allocator: Allocator) void {
    var root_memory = Memory.init(allocator, 65536, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer root_memory.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const child = root_memory.init_child_memory(i * 256) catch unreachable;
        _ = child;
    }
}

pub fn bench_multiple_contexts_shared_buffer(allocator: Allocator) void {
    var root_memory = Memory.init(allocator, 65536, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer root_memory.deinit();

    // Create multiple child contexts
    var child1 = root_memory.init_child_memory(0) catch unreachable;
    var child2 = root_memory.init_child_memory(16384) catch unreachable;
    var child3 = root_memory.init_child_memory(32768) catch unreachable;

    const data = [_]u8{0x42} ** 1024;

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        child1.set_data(i * 32, data[0..32]) catch unreachable;
        child2.set_data(i * 32, data[0..32]) catch unreachable;
        child3.set_data(i * 32, data[0..32]) catch unreachable;
    }
}

// Memory patterns benchmarks
pub fn bench_codecopy_pattern(allocator: Allocator) void {
    var memory = Memory.init(allocator, 262144, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    // Simulate large contract code copy
    const code = [_]u8{0x60} ** 24576; // 24KB of code

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        memory.set_data(i * 1024, &code) catch unreachable;
    }
}

pub fn bench_mload_mstore_pattern(allocator: Allocator) void {
    var memory = Memory.init(allocator, 8192, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    // Simulate typical MLOAD/MSTORE patterns
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        // MSTORE
        memory.set_u256(i * 32 % 8000, @as(u256, i * 0x1234567890ABCDEF)) catch unreachable;
        // MLOAD
        _ = memory.get_u256(i * 32 % 8000) catch unreachable;
    }
}

pub fn bench_keccak256_large_data(allocator: Allocator) void {
    var memory = Memory.init(allocator, 131072, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    // Simulate memory access for large Keccak256 operations
    const large_data = [_]u8{0xAB} ** 32768; // 32KB
    memory.set_data(0, &large_data) catch unreachable;

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = memory.get_slice(0, 32768) catch unreachable;
    }
}

// Edge case benchmarks
pub fn bench_near_memory_limit(allocator: Allocator) void {
    const custom_limit = 1048576; // 1MB limit
    var memory = Memory.init(allocator, 256, custom_limit) catch unreachable;
    defer memory.deinit();

    // Expand to near limit
    _ = memory.ensure_context_capacity(custom_limit - 1024) catch unreachable;

    const data = [_]u8{0x42} ** 512;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        memory.set_data(i * 32, &data) catch unreachable;
    }
}

pub fn bench_zero_length_operations(allocator: Allocator) void {
    var memory = Memory.init(allocator, 4096, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        _ = memory.get_slice(0, 0) catch unreachable;
        memory.set_data(0, &[_]u8{}) catch unreachable;
    }
}

// Memory alignment benchmarks
pub fn bench_aligned_access(allocator: Allocator) void {
    var memory = Memory.init(allocator, 8192, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    // All accesses are 32-byte aligned
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        memory.set_u256(i * 32, @as(u256, i)) catch unreachable;
        _ = memory.get_u256(i * 32) catch unreachable;
    }
}

pub fn bench_unaligned_access(allocator: Allocator) void {
    var memory = Memory.init(allocator, 8192, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    // Accesses are not aligned to 32-byte boundaries
    const offsets = [_]usize{ 1, 7, 13, 19, 23, 29, 31, 37, 41, 47 };
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        for (offsets) |offset| {
            memory.set_u256(offset + i * 50, @as(u256, i)) catch unreachable;
            _ = memory.get_u256(offset + i * 50) catch unreachable;
        }
    }
}

// Bulk operation benchmarks
pub fn bench_returndatacopy_pattern(allocator: Allocator) void {
    var memory = Memory.init(allocator, 65536, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    // Simulate RETURNDATACOPY with various sizes
    const return_data = [_]u8{0xDE} ** 4096;

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        memory.set_data(i * 2048, &return_data) catch unreachable;
    }
}

pub fn bench_mcopy_pattern(allocator: Allocator) void {
    var memory = Memory.init(allocator, 32768, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    // Fill source region
    const source_data = [_]u8{0xAA} ** 4096;
    memory.set_data(0, &source_data) catch unreachable;

    // Simulate MCOPY operations
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const src_data = memory.get_slice(0, 4096) catch unreachable;
        memory.set_data(8192 + i * 256, src_data) catch unreachable;
    }
}

// Memory expansion cost curve benchmark
pub fn bench_expansion_cost_curve(allocator: Allocator) void {
    var memory = Memory.init(allocator, 256, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();

    // Measure expansion at different sizes to understand cost curve
    const sizes = [_]usize{ 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576 };

    for (sizes) |size| {
        _ = memory.ensure_context_capacity(size) catch break;
    }
}
