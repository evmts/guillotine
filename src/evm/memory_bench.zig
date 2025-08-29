const std = @import("std");
const zbench = @import("zbench");
const memory_mod = @import("memory.zig");
const memory_config_mod = @import("memory_config.zig");

const MemoryConfig = memory_config_mod.MemoryConfig;
const Memory = memory_mod.Memory;

// Test configuration
const test_config = MemoryConfig{
    .initial_capacity = 4096,
    .memory_limit = 1024 * 1024, // 1MB limit
    .WordType = u256,
};

const TestMemory = Memory(test_config);

fn benchMemorySet(allocator: std.mem.Allocator) void {
    var memory = TestMemory.init(allocator) catch return;
    defer memory.deinit(allocator);
    
    // Write data at various offsets
    var i: u32 = 0;
    while (i < 1000) : (i += 32) {
        const data = [_]u8{0xAB, 0xCD} ++ [_]u8{0x00} ** 30;
        memory.set_data_evm(i, &data) catch break;
    }
}

fn benchMemoryGet(allocator: std.mem.Allocator) void {
    var memory = TestMemory.init(allocator) catch return;
    defer memory.deinit(allocator);
    
    // Pre-fill memory
    var i: u32 = 0;
    while (i < 1000) : (i += 32) {
        const data = [_]u8{0xAB, 0xCD} ++ [_]u8{0x00} ** 30;
        memory.set_data_evm(i, &data) catch break;
    }
    
    // Read data back
    i = 0;
    while (i < 1000) : (i += 32) {
        _ = memory.get_slice_evm(i, 32) catch break;
    }
}

fn benchMemoryU256Operations(allocator: std.mem.Allocator) void {
    var memory = TestMemory.init(allocator) catch return;
    defer memory.deinit(allocator);
    
    // Write u256 values
    var i: u32 = 0;
    while (i < 500) : (i += 32) {
        const value: u256 = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0;
        memory.set_u256_evm(i, value) catch break;
    }
    
    // Read u256 values back
    i = 0;
    while (i < 500) : (i += 32) {
        _ = memory.get_u256_evm(i) catch break;
    }
}

fn benchMemoryExpansion(allocator: std.mem.Allocator) void {
    var memory = TestMemory.init(allocator) catch return;
    defer memory.deinit(allocator);
    
    // Trigger memory expansions
    const offsets = [_]u32{ 1024, 2048, 4096, 8192, 16384, 32768, 65536 };
    
    for (offsets) |offset| {
        const data = [_]u8{0xFF} ** 32;
        memory.set_data_evm(offset, &data) catch break;
    }
}

fn benchMemoryCopy(allocator: std.mem.Allocator) void {
    var memory = TestMemory.init(allocator) catch return;
    defer memory.deinit(allocator);
    
    // Pre-fill with source data
    const source_data = [_]u8{0xAB} ** 1024;
    memory.set_data_evm(0, &source_data) catch return;
    
    // Perform copy operations
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const dest_offset = 2048 + (i * 64);
        const src_offset = i * 10;
        memory.copy_evm(dest_offset, src_offset, 64) catch break;
    }
}

fn benchMemoryChildOperations(allocator: std.mem.Allocator) void {
    var parent_memory = TestMemory.init(allocator) catch return;
    defer parent_memory.deinit(allocator);
    
    // Fill parent with some data
    const data = [_]u8{0xDE, 0xAD, 0xBE, 0xEF} ++ [_]u8{0x00} ** 28;
    parent_memory.set_data_evm(0, &data) catch return;
    
    // Create child memory and perform operations
    var child_memory = parent_memory.init_child() catch return;
    defer child_memory.deinit(allocator);
    
    // Perform operations on child
    var i: u32 = 0;
    while (i < 100) : (i += 32) {
        const child_data = [_]u8{0xCA, 0xFE} ++ [_]u8{0x00} ** 30;
        child_memory.set_data_evm(1024 + i, &child_data) catch break;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();
    
    var bench = zbench.Benchmark.init(allocator, .{});
    defer bench.deinit();
    
    try bench.add("Memory Set Operations", benchMemorySet, .{});
    try bench.add("Memory Get Operations", benchMemoryGet, .{});
    try bench.add("Memory U256 Operations", benchMemoryU256Operations, .{});
    try bench.add("Memory Expansion", benchMemoryExpansion, .{});
    try bench.add("Memory Copy Operations", benchMemoryCopy, .{});
    try bench.add("Memory Child Operations", benchMemoryChildOperations, .{});
    
    try stdout.print("Running Memory Benchmarks...\n");
    try bench.run(stdout);
}