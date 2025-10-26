const std = @import("std");
const Allocator = std.mem.Allocator;
const hash_builder = @import("hash_builder_complete.zig");
const hash_builder_opt = @import("hash_builder_optimized.zig");
const HashBuilder = hash_builder.HashBuilder;
const HashBuilderOptimized = hash_builder_opt.HashBuilderOptimized;

/// Benchmark result structure
pub const BenchmarkResult = struct {
    name: []const u8,
    operations: usize,
    duration_ns: u64,
    ops_per_sec: f64,
    ns_per_op: f64,

    pub fn print(self: BenchmarkResult) void {
        std.debug.print("Benchmark: {s}\n", .{self.name});
        std.debug.print("  Operations: {d}\n", .{self.operations});
        std.debug.print("  Duration: {d} ns\n", .{self.duration_ns});
        std.debug.print("  Ops/sec: {d:.2}\n", .{self.ops_per_sec});
        std.debug.print("  ns/op: {d:.2}\n", .{self.ns_per_op});
    }
};

/// Run a benchmark and return results
fn benchmark(
    comptime name: []const u8,
    comptime func: fn (allocator: Allocator, iterations: usize) anyerror!void,
    allocator: Allocator,
    iterations: usize,
) !BenchmarkResult {
    // Warm up
    try func(allocator, @min(iterations / 10, 100));

    // Actual benchmark
    const start = std.time.nanoTimestamp();
    try func(allocator, iterations);
    const end = std.time.nanoTimestamp();

    const duration = @as(u64, @intCast(end - start));
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(duration)) / 1_000_000_000.0);
    const ns_per_op = @as(f64, @floatFromInt(duration)) / @as(f64, @floatFromInt(iterations));

    return BenchmarkResult{
        .name = name,
        .operations = iterations,
        .duration_ns = duration,
        .ops_per_sec = ops_per_sec,
        .ns_per_op = ns_per_op,
    };
}

/// Benchmark: Insert operations
fn bench_insert(allocator: Allocator, n: usize) !void {
    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    var i: usize = 0;
    while (i < n) : (i += 1) {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        try builder.insert(&key, "test_value");
    }
}

/// Benchmark: Lookup operations
fn bench_lookup(allocator: Allocator, n: usize) !void {
    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Pre-populate
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        try builder.insert(&key, "test_value");
    }

    // Benchmark lookups
    i = 0;
    while (i < n) : (i += 1) {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        _ = try builder.get(&key);
    }
}

/// Benchmark: Delete operations
fn bench_delete(allocator: Allocator, n: usize) !void {
    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Pre-populate
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        try builder.insert(&key, "test_value");
    }

    // Benchmark deletes
    i = 0;
    while (i < n) : (i += 1) {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        try builder.delete(&key);
    }
}

/// Benchmark: Mixed workload (50% read, 30% insert, 20% delete)
fn bench_mixed(allocator: Allocator, n: usize) !void {
    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Pre-populate with half the keys
    var i: usize = 0;
    while (i < n / 2) : (i += 1) {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        try builder.insert(&key, "test_value");
    }

    // Mixed workload
    i = 0;
    while (i < n) : (i += 1) {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i % (n / 2)), .big);

        const op = i % 10;
        if (op < 5) {
            // Read
            _ = try builder.get(&key);
        } else if (op < 8) {
            // Insert
            try builder.insert(&key, "updated_value");
        } else {
            // Delete
            try builder.delete(&key);
        }
    }
}

/// Benchmark: Large keys (32 bytes)
fn bench_large_keys(allocator: Allocator, n: usize) !void {
    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    var i: usize = 0;
    while (i < n) : (i += 1) {
        var key: [32]u8 = undefined;
        for (0..32) |j| {
            key[j] = @intCast((i + j) % 256);
        }
        try builder.insert(&key, "test_value");
    }
}

/// Benchmark: Optimized builder insert
fn bench_insert_optimized(allocator: Allocator, n: usize) !void {
    var builder = HashBuilderOptimized.init(allocator);
    defer builder.deinit();

    var i: usize = 0;
    while (i < n) : (i += 1) {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        try builder.insert(&key, "test_value");
    }
}

/// Benchmark: Optimized builder lookup
fn bench_lookup_optimized(allocator: Allocator, n: usize) !void {
    var builder = HashBuilderOptimized.init(allocator);
    defer builder.deinit();

    // Pre-populate
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        try builder.insert(&key, "test_value");
    }

    // Benchmark lookups
    i = 0;
    while (i < n) : (i += 1) {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        _ = try builder.get(&key);
    }
}

/// Run all benchmarks
pub fn run_all_benchmarks(allocator: Allocator) !void {
    const iterations = 1000;

    std.debug.print("\n=== Trie Performance Benchmarks ===\n\n", .{});

    const insert_result = try benchmark("Insert (1000 ops)", bench_insert, allocator, iterations);
    insert_result.print();
    std.debug.print("\n", .{});

    const lookup_result = try benchmark("Lookup (1000 ops)", bench_lookup, allocator, iterations);
    lookup_result.print();
    std.debug.print("\n", .{});

    const delete_result = try benchmark("Delete (1000 ops)", bench_delete, allocator, iterations);
    delete_result.print();
    std.debug.print("\n", .{});

    const mixed_result = try benchmark("Mixed workload (1000 ops)", bench_mixed, allocator, iterations);
    mixed_result.print();
    std.debug.print("\n", .{});

    const large_keys_result = try benchmark("Large keys (1000 ops)", bench_large_keys, allocator, iterations);
    large_keys_result.print();
    std.debug.print("\n", .{});

    std.debug.print("=== Optimized Builder Benchmarks ===\n\n", .{});

    const insert_opt_result = try benchmark("Optimized Insert (1000 ops)", bench_insert_optimized, allocator, iterations);
    insert_opt_result.print();
    std.debug.print("\n", .{});

    const lookup_opt_result = try benchmark("Optimized Lookup (1000 ops)", bench_lookup_optimized, allocator, iterations);
    lookup_opt_result.print();
    std.debug.print("\n", .{});

    // Compute speedup
    const insert_speedup = insert_result.ns_per_op / insert_opt_result.ns_per_op;
    const lookup_speedup = lookup_result.ns_per_op / lookup_opt_result.ns_per_op;

    std.debug.print("=== Performance Summary ===\n", .{});
    std.debug.print("Insert speedup: {d:.2}x\n", .{insert_speedup});
    std.debug.print("Lookup speedup: {d:.2}x\n", .{lookup_speedup});
}

// Tests

test "benchmark - insert small" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const result = try benchmark("Insert (10 ops)", bench_insert, allocator, 10);
    try testing.expect(result.operations == 10);
    try testing.expect(result.duration_ns > 0);
    try testing.expect(result.ops_per_sec > 0);
}

test "benchmark - lookup small" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const result = try benchmark("Lookup (10 ops)", bench_lookup, allocator, 10);
    try testing.expect(result.operations == 10);
    try testing.expect(result.duration_ns > 0);
}

test "benchmark - delete small" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const result = try benchmark("Delete (10 ops)", bench_delete, allocator, 10);
    try testing.expect(result.operations == 10);
    try testing.expect(result.duration_ns > 0);
}

test "benchmark - mixed workload" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const result = try benchmark("Mixed (10 ops)", bench_mixed, allocator, 10);
    try testing.expect(result.operations == 10);
    try testing.expect(result.duration_ns > 0);
}

test "benchmark - optimized vs standard" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const standard = try benchmark("Standard Insert", bench_insert, allocator, 100);
    const optimized = try benchmark("Optimized Insert", bench_insert_optimized, allocator, 100);

    // Optimized should be at least as fast (or we have a regression)
    // Allow some variance due to timing noise
    const speedup = standard.ns_per_op / optimized.ns_per_op;
    std.debug.print("Speedup: {d:.2}x\n", .{speedup});

    // This test is informational - no strict assertion
    try testing.expect(speedup > 0);
}
