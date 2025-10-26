const std = @import("std");
const Allocator = std.mem.Allocator;
const hash_builder = @import("hash_builder_complete.zig");
const hash_builder_opt = @import("hash_builder_optimized.zig");
const node_cache = @import("node_cache.zig");

/// Validation test to ensure optimized implementation matches standard
pub fn validate_correctness(allocator: Allocator, n: usize) !void {
    var standard = hash_builder.HashBuilder.init(allocator);
    defer standard.deinit();

    var optimized = hash_builder_opt.HashBuilderOptimized.init(allocator);
    defer optimized.deinit();

    // Insert same keys into both
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        const value = "test_value";

        try standard.insert(&key, value);
        try optimized.insert(&key, value);
    }

    // Verify root hashes match
    const standard_root = standard.get_root_hash();
    const optimized_root = optimized.get_root_hash();

    if (standard_root == null and optimized_root == null) {
        return; // Both empty
    }

    if (standard_root == null or optimized_root == null) {
        return error.RootHashMismatch; // One is empty, other is not
    }

    if (!std.mem.eql(u8, &standard_root.?, &optimized_root.?)) {
        return error.RootHashMismatch;
    }

    // Verify all values match
    i = 0;
    while (i < n) : (i += 1) {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i), .big);

        const standard_value = try standard.get(&key);
        const optimized_value = try optimized.get(&key);

        if (standard_value == null and optimized_value == null) continue;
        if (standard_value == null or optimized_value == null) return error.ValueMismatch;

        if (!std.mem.eql(u8, standard_value.?, optimized_value.?)) {
            return error.ValueMismatch;
        }
    }
}

/// Performance comparison test
pub fn compare_performance(allocator: Allocator, n: usize) !struct { standard_ns: u64, optimized_ns: u64, speedup: f64 } {
    // Benchmark standard
    var standard = hash_builder.HashBuilder.init(allocator);
    defer standard.deinit();

    const standard_start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        try standard.insert(&key, "test_value");
    }
    const standard_end = std.time.nanoTimestamp();
    const standard_ns: u64 = @intCast(standard_end - standard_start);

    // Benchmark optimized
    var optimized = hash_builder_opt.HashBuilderOptimized.init(allocator);
    defer optimized.deinit();

    const optimized_start = std.time.nanoTimestamp();
    i = 0;
    while (i < n) : (i += 1) {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        try optimized.insert(&key, "test_value");
    }
    const optimized_end = std.time.nanoTimestamp();
    const optimized_ns: u64 = @intCast(optimized_end - optimized_start);

    const speedup = @as(f64, @floatFromInt(standard_ns)) / @as(f64, @floatFromInt(optimized_ns));

    return .{
        .standard_ns = standard_ns,
        .optimized_ns = optimized_ns,
        .speedup = speedup,
    };
}

// Tests

test "validation - correctness with 100 keys" {
    const testing = std.testing;
    const allocator = testing.allocator;

    try validate_correctness(allocator, 100);
}

test "validation - correctness with 1000 keys" {
    const testing = std.testing;
    const allocator = testing.allocator;

    try validate_correctness(allocator, 1000);
}

test "validation - correctness after updates" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var standard = hash_builder.HashBuilder.init(allocator);
    defer standard.deinit();

    var optimized = hash_builder_opt.HashBuilderOptimized.init(allocator);
    defer optimized.deinit();

    // Insert
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        try standard.insert(&key, "value1");
        try optimized.insert(&key, "value1");
    }

    // Update
    i = 0;
    while (i < 100) : (i += 1) {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        try standard.insert(&key, "value2");
        try optimized.insert(&key, "value2");
    }

    // Verify root hashes match
    const standard_root = standard.get_root_hash();
    const optimized_root = optimized.get_root_hash();

    try testing.expect(standard_root != null);
    try testing.expect(optimized_root != null);
    try testing.expectEqualSlices(u8, &standard_root.?, &optimized_root.?);
}

test "validation - correctness after deletes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var standard = hash_builder.HashBuilder.init(allocator);
    defer standard.deinit();

    var optimized = hash_builder_opt.HashBuilderOptimized.init(allocator);
    defer optimized.deinit();

    // Insert
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        try standard.insert(&key, "value1");
        try optimized.insert(&key, "value1");
    }

    // Delete half
    i = 0;
    while (i < 50) : (i += 1) {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        try standard.delete(&key);
        try optimized.delete(&key);
    }

    // Verify root hashes match
    const standard_root = standard.get_root_hash();
    const optimized_root = optimized.get_root_hash();

    try testing.expect(standard_root != null);
    try testing.expect(optimized_root != null);
    try testing.expectEqualSlices(u8, &standard_root.?, &optimized_root.?);
}

test "performance - insert speedup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const result = try compare_performance(allocator, 500);

    std.debug.print("\nPerformance comparison (500 inserts):\n", .{});
    std.debug.print("  Standard: {d} ns\n", .{result.standard_ns});
    std.debug.print("  Optimized: {d} ns\n", .{result.optimized_ns});
    std.debug.print("  Speedup: {d:.2}x\n", .{result.speedup});

    // Optimized should not be significantly slower (allow for timing variance)
    // We expect speedup >= 1.0, but allow some variance
    try testing.expect(result.speedup > 0.5);
}

test "cache - hash cache effectiveness" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = node_cache.NodeCache.init(allocator);
    defer cache.deinit();

    // Generate some hashes
    var hashes: [100][32]u8 = undefined;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        for (0..32) |j| {
            hashes[i][j] = @intCast((i + j) % 256);
        }
    }

    // Cache all hashes
    i = 0;
    while (i < 100) : (i += 1) {
        var hash_str_buf: [64]u8 = undefined;
        _ = try std.fmt.bufPrint(&hash_str_buf, "{x}", .{std.fmt.fmtSliceHexLower(&hashes[i])});
        try cache.cache_hash(&hash_str_buf, hashes[i]);
    }

    // Verify cache hit rate (should be 100%)
    var hits: usize = 0;
    i = 0;
    while (i < 100) : (i += 1) {
        var hash_str_buf: [64]u8 = undefined;
        _ = try std.fmt.bufPrint(&hash_str_buf, "{x}", .{std.fmt.fmtSliceHexLower(&hashes[i])});
        if (cache.get_cached_hash(&hash_str_buf)) |_| {
            hits += 1;
        }
    }

    try testing.expectEqual(@as(usize, 100), hits);
    std.debug.print("\nCache hit rate: {d}/100 (100%)\n", .{hits});
}

test "cache - dirty flag propagation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = node_cache.NodeCache.init(allocator);
    defer cache.deinit();

    var hash: [32]u8 = undefined;
    for (0..32) |i| {
        hash[i] = @intCast(i);
    }

    var hash_str_buf: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hash_str_buf, "{x}", .{std.fmt.fmtSliceHexLower(&hash)});

    // Cache the hash
    try cache.cache_hash(&hash_str_buf, hash);

    // Verify cached
    var cached = cache.get_cached_hash(&hash_str_buf);
    try testing.expect(cached != null);

    // Mark dirty
    cache.mark_dirty(&hash_str_buf);

    // Verify not cached (dirty)
    cached = cache.get_cached_hash(&hash_str_buf);
    try testing.expect(cached == null);

    // Update
    var new_hash: [32]u8 = undefined;
    for (0..32) |i| {
        new_hash[i] = @intCast(i + 1);
    }
    try cache.update_hash(&hash_str_buf, new_hash);

    // Verify cached again (clean)
    cached = cache.get_cached_hash(&hash_str_buf);
    try testing.expect(cached != null);
    try testing.expectEqualSlices(u8, &new_hash, &cached.?);
}
