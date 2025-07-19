const std = @import("std");
const Memory = @import("evm").Memory;

// Benchmark state to avoid repeated allocations
var bench_memory: ?Memory = null;
var bench_allocator: ?std.mem.Allocator = null;
var test_data_32: [32]u8 = undefined;
var test_data_1kb: [1024]u8 = undefined;
var test_data_64kb: [65536]u8 = undefined;
var u256_test_values: [100]u256 = undefined;

pub fn setup_benchmarks(allocator: std.mem.Allocator) !void {
    bench_allocator = allocator;
    
    // Initialize test data
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();
    
    random.bytes(&test_data_32);
    random.bytes(&test_data_1kb);
    random.bytes(&test_data_64kb);
    
    for (&u256_test_values) |*val| {
        val.* = random.int(u256);
    }
}

pub fn cleanup_benchmarks() void {
    if (bench_memory) |*mem| {
        mem.deinit();
        bench_memory = null;
    }
}

// Memory Allocation Benchmarks
pub fn bench_memory_init_small(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 1024, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
}

pub fn bench_memory_init_large(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 1024 * 1024, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
}

pub fn bench_memory_expansion_small(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 0, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    _ = memory.ensure_context_capacity(1024) catch unreachable;
}

pub fn bench_memory_expansion_large(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 0, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    _ = memory.ensure_context_capacity(1024 * 1024) catch unreachable;
}

pub fn bench_memory_expansion_incremental(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 0, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = memory.ensure_context_capacity(i * 1024) catch unreachable;
    }
}

// Read Operations Benchmarks
pub fn bench_read_u256_sequential(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 32 * 100, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    // Initialize with test data
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        memory.set_u256(i * 32, u256_test_values[i]) catch unreachable;
    }
    
    // Benchmark sequential reads
    i = 0;
    while (i < 100) : (i += 1) {
        _ = memory.get_u256(i * 32) catch unreachable;
    }
}

pub fn bench_read_u256_random(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 32 * 100, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    // Initialize with test data
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        memory.set_u256(i * 32, u256_test_values[i]) catch unreachable;
    }
    
    // Benchmark random reads with pre-computed offsets
    const offsets = [_]usize{ 64, 2816, 1568, 32, 2432, 896, 1920, 544, 2080, 1216 };
    for (offsets) |offset| {
        _ = memory.get_u256(offset) catch unreachable;
    }
}

pub fn bench_read_slice_small(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 10240, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    memory.set_data(0, &test_data_1kb) catch unreachable;
    
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = memory.get_slice(i * 10, 32) catch unreachable;
    }
}

pub fn bench_read_slice_large(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 100 * 1024, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    memory.set_data(0, &test_data_64kb) catch unreachable;
    
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = memory.get_slice(i * 1024, 1024) catch unreachable;
    }
}

pub fn bench_read_byte_sequential(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 1024, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    memory.set_data(0, &test_data_1kb) catch unreachable;
    
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        _ = memory.get_byte(i) catch unreachable;
    }
}

// Write Operations Benchmarks
pub fn bench_write_u256_sequential(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 0, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        memory.set_u256(i * 32, u256_test_values[i]) catch unreachable;
    }
}

pub fn bench_write_u256_random(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 32 * 100, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    const offsets = [_]usize{ 64, 2816, 1568, 32, 2432, 896, 1920, 544, 2080, 1216 };
    for (offsets, 0..) |offset, i| {
        memory.set_u256(offset, u256_test_values[i]) catch unreachable;
    }
}

pub fn bench_write_data_small(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 0, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        memory.set_data(i * 32, &test_data_32) catch unreachable;
    }
}

pub fn bench_write_data_large(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 0, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        memory.set_data(i * 65536, &test_data_64kb) catch unreachable;
    }
}

pub fn bench_write_data_bounded(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 0, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        memory.set_data_bounded(i * 32, &test_data_1kb, i % 16, 32) catch unreachable;
    }
}

// Shared Buffer Architecture Benchmarks
pub fn bench_child_context_creation(allocator: std.mem.Allocator) void {
    var root = Memory.init(allocator, 10240, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer root.deinit();
    
    var children: [10]Memory = undefined;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        children[i] = root.init_child_memory(i * 1024) catch unreachable;
    }
}

pub fn bench_child_context_access(allocator: std.mem.Allocator) void {
    var root = Memory.init(allocator, 10240, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer root.deinit();
    
    // Write data to root
    root.set_u256(0, 0xDEADBEEF) catch unreachable;
    root.set_u256(1024, 0xCAFEBABE) catch unreachable;
    
    var child1 = root.init_child_memory(512) catch unreachable;
    var child2 = root.init_child_memory(1024) catch unreachable;
    
    // Access through children
    _ = child1.get_u256(0) catch unreachable;
    _ = child2.get_u256(0) catch unreachable;
    child1.set_u256(100, 0x12345678) catch unreachable;
    child2.set_u256(200, 0x87654321) catch unreachable;
}

// EVM Pattern Benchmarks
pub fn bench_evm_codecopy(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 0, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    // Simulate CODECOPY - copy 512 bytes of code
    memory.set_data(0, test_data_1kb[0..512]) catch unreachable;
}

pub fn bench_evm_calldatacopy(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 0, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    // Simulate CALLDATACOPY with offset
    memory.set_data_bounded(64, &test_data_1kb, 32, 256) catch unreachable;
}

pub fn bench_evm_returndatacopy(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 0, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    // Simulate RETURNDATACOPY
    memory.set_data(128, test_data_32[0..]) catch unreachable;
}

pub fn bench_evm_mload_mstore(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 1024, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    // Initialize source data
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        memory.set_u256(i * 32, u256_test_values[i]) catch unreachable;
    }
    
    // MLOAD/MSTORE pattern
    i = 0;
    while (i < 10) : (i += 1) {
        const value = memory.get_u256(i * 32) catch unreachable;
        memory.set_u256((i + 10) * 32, value) catch unreachable;
    }
}

pub fn bench_evm_keccak_pattern(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 0, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    // Write data for hashing
    memory.set_data(0, &test_data_1kb) catch unreachable;
    // Read it back (simulating passing to Keccak256)
    _ = memory.get_slice(0, 1024) catch unreachable;
}

pub fn bench_evm_memory_expansion(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 0, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    // Simulate gradual memory expansion during contract execution
    var offset: usize = 0;
    while (offset < 10000) : (offset += 1000) {
        memory.set_u256(offset, 0xABCDEF) catch unreachable;
    }
}

// Edge Case Benchmarks
pub fn bench_zero_length_ops(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 1024, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    memory.set_data(0, &[_]u8{}) catch unreachable;
    _ = memory.get_slice(0, 0) catch unreachable;
}

pub fn bench_near_memory_limit(allocator: std.mem.Allocator) void {
    const limit = 1024 * 1024; // 1MB for testing
    var memory = Memory.init(allocator, 0, limit) catch unreachable;
    defer memory.deinit();
    
    _ = memory.ensure_context_capacity(limit - 100) catch unreachable;
    memory.set_data(limit - 100, "test") catch unreachable;
}

pub fn bench_alignment_patterns(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 1024, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    // Test various misaligned accesses
    const alignments = [_]usize{ 1, 7, 15, 31, 63, 127 };
    for (alignments) |alignment| {
        memory.set_u256(alignment, 0x12345678) catch unreachable;
        _ = memory.get_u256(alignment) catch unreachable;
    }
}

// Memory copy vs memset benchmarks
pub fn bench_memcpy_small(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 0, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    // Small memcpy operations
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        memory.set_data(i * 8, test_data_32[0..8]) catch unreachable;
    }
}

pub fn bench_memcpy_large(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 0, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    // Large memcpy operation
    memory.set_data(0, &test_data_64kb) catch unreachable;
}

pub fn bench_memset_pattern(allocator: std.mem.Allocator) void {
    var memory = Memory.init(allocator, 0, Memory.DEFAULT_MEMORY_LIMIT) catch unreachable;
    defer memory.deinit();
    
    // Bounded writes that trigger zero-filling
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        // This will zero-fill because offset is beyond data bounds
        memory.set_data_bounded(i * 32, &test_data_32, 1000, 32) catch unreachable;
    }
}