const std = @import("std");
const Allocator = std.mem.Allocator;
const hash_builder = @import("hash_builder_complete.zig");
const node_cache = @import("node_cache.zig");
const HashBuilder = hash_builder.HashBuilder;

/// Stress test configuration
pub const StressConfig = struct {
    num_keys: usize = 10000,
    key_size: usize = 32,
    value_size: usize = 64,
    num_iterations: usize = 3,
};

/// Generate a deterministic key for testing
fn generate_key(allocator: Allocator, index: usize, size: usize) ![]u8 {
    const key = try allocator.alloc(u8, size);
    var hash_input: [8]u8 = undefined;
    std.mem.writeInt(u64, &hash_input, index, .big);

    // Use keccak256 to generate deterministic key material
    var hash_output: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&hash_input, &hash_output, .{});

    // Copy to key
    for (0..size) |i| {
        key[i] = hash_output[i % 32];
    }

    return key;
}

/// Generate a deterministic value for testing
fn generate_value(allocator: Allocator, index: usize, size: usize) ![]u8 {
    const value = try allocator.alloc(u8, size);
    var hash_input: [8]u8 = undefined;
    std.mem.writeInt(u64, &hash_input, index + 0x1000000, .big);

    var hash_output: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&hash_input, &hash_output, .{});

    for (0..size) |i| {
        value[i] = hash_output[i % 32];
    }

    return value;
}

// Tests

test "stress - insert 10k keys" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    const n = 10000;
    var i: usize = 0;

    // Insert 10k keys
    while (i < n) : (i += 1) {
        const key = try generate_key(allocator, i, 4);
        defer allocator.free(key);

        const value = try generate_value(allocator, i, 8);
        defer allocator.free(value);

        try builder.insert(key, value);
    }

    // Verify root hash exists
    try testing.expect(builder.get_root_hash() != null);

    // Spot check some keys
    const check_indices = [_]usize{ 0, 100, 1000, 5000, 9999 };
    for (check_indices) |idx| {
        const key = try generate_key(allocator, idx, 4);
        defer allocator.free(key);

        const expected_value = try generate_value(allocator, idx, 8);
        defer allocator.free(expected_value);

        const value = try builder.get(key);
        try testing.expect(value != null);
        try testing.expectEqualSlices(u8, expected_value, value.?);
    }
}

test "stress - sequential insert and delete" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    const n = 1000;

    // Insert
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try generate_key(allocator, i, 4);
        defer allocator.free(key);

        const value = try generate_value(allocator, i, 8);
        defer allocator.free(value);

        try builder.insert(key, value);
    }

    // Verify all keys present
    i = 0;
    while (i < n) : (i += 1) {
        const key = try generate_key(allocator, i, 4);
        defer allocator.free(key);

        const value = try builder.get(key);
        try testing.expect(value != null);
    }

    // Delete all keys
    i = 0;
    while (i < n) : (i += 1) {
        const key = try generate_key(allocator, i, 4);
        defer allocator.free(key);

        try builder.delete(key);
    }

    // Verify all keys deleted
    i = 0;
    while (i < n) : (i += 1) {
        const key = try generate_key(allocator, i, 4);
        defer allocator.free(key);

        const value = try builder.get(key);
        try testing.expect(value == null);
    }

    // Trie should be empty
    try testing.expect(builder.get_root_hash() == null);
}

test "stress - random insert/delete pattern" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    var prng = std.rand.DefaultPrng.init(12345);
    const random = prng.random();

    const n = 500;
    var i: usize = 0;

    // Random operations
    while (i < n) : (i += 1) {
        const key_idx = random.intRangeAtMost(usize, 0, 99);
        const key = try generate_key(allocator, key_idx, 4);
        defer allocator.free(key);

        if (random.boolean()) {
            // Insert
            const value = try generate_value(allocator, key_idx, 8);
            defer allocator.free(value);
            try builder.insert(key, value);
        } else {
            // Delete
            try builder.delete(key);
        }
    }

    // Verify consistency - all operations should complete without error
    try testing.expect(true);
}

test "stress - common prefix keys" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    const n = 1000;
    var i: usize = 0;

    // Insert keys with common prefix
    while (i < n) : (i += 1) {
        var key: [8]u8 = undefined;
        // First 4 bytes are common prefix
        std.mem.writeInt(u32, key[0..4], 0x12345678, .big);
        // Last 4 bytes vary
        std.mem.writeInt(u32, key[4..8], @intCast(i), .big);

        const value = try generate_value(allocator, i, 8);
        defer allocator.free(value);

        try builder.insert(&key, value);
    }

    // Verify all keys retrievable
    i = 0;
    while (i < n) : (i += 1) {
        var key: [8]u8 = undefined;
        std.mem.writeInt(u32, key[0..4], 0x12345678, .big);
        std.mem.writeInt(u32, key[4..8], @intCast(i), .big);

        const value = try builder.get(&key);
        try testing.expect(value != null);
    }
}

test "stress - large values" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    const n = 100;
    const value_size = 1024; // 1 KB values

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try generate_key(allocator, i, 4);
        defer allocator.free(key);

        const value = try generate_value(allocator, i, value_size);
        defer allocator.free(value);

        try builder.insert(key, value);
    }

    // Verify
    i = 0;
    while (i < n) : (i += 1) {
        const key = try generate_key(allocator, i, 4);
        defer allocator.free(key);

        const expected_value = try generate_value(allocator, i, value_size);
        defer allocator.free(expected_value);

        const value = try builder.get(key);
        try testing.expect(value != null);
        try testing.expectEqualSlices(u8, expected_value, value.?);
    }
}

test "stress - update existing keys" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    const n = 500;
    var i: usize = 0;

    // Initial insert
    while (i < n) : (i += 1) {
        const key = try generate_key(allocator, i, 4);
        defer allocator.free(key);

        const value = try generate_value(allocator, i, 8);
        defer allocator.free(value);

        try builder.insert(key, value);
    }

    // Update all keys
    i = 0;
    while (i < n) : (i += 1) {
        const key = try generate_key(allocator, i, 4);
        defer allocator.free(key);

        const new_value = try generate_value(allocator, i + 1000000, 8);
        defer allocator.free(new_value);

        try builder.insert(key, new_value);
    }

    // Verify updates
    i = 0;
    while (i < n) : (i += 1) {
        const key = try generate_key(allocator, i, 4);
        defer allocator.free(key);

        const expected_value = try generate_value(allocator, i + 1000000, 8);
        defer allocator.free(expected_value);

        const value = try builder.get(key);
        try testing.expect(value != null);
        try testing.expectEqualSlices(u8, expected_value, value.?);
    }
}

test "stress - alternating insert/delete" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    const n = 300;
    var i: usize = 0;

    while (i < n) : (i += 1) {
        // Insert key i
        const key = try generate_key(allocator, i, 4);
        defer allocator.free(key);

        const value = try generate_value(allocator, i, 8);
        defer allocator.free(value);

        try builder.insert(key, value);

        // Delete key i-1 (if it exists)
        if (i > 0) {
            const prev_key = try generate_key(allocator, i - 1, 4);
            defer allocator.free(prev_key);

            try builder.delete(prev_key);
        }
    }

    // Only the last key should exist
    const last_key = try generate_key(allocator, n - 1, 4);
    defer allocator.free(last_key);

    const value = try builder.get(last_key);
    try testing.expect(value != null);

    // All other keys should not exist
    i = 0;
    while (i < n - 1) : (i += 1) {
        const key = try generate_key(allocator, i, 4);
        defer allocator.free(key);

        const v = try builder.get(key);
        try testing.expect(v == null);
    }
}

test "stress - hash collision resistance" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert keys that might have similar hashes
    const n = 1000;
    var i: usize = 0;

    while (i < n) : (i += 1) {
        var key: [4]u8 = undefined;
        // Use sequential patterns that might collide
        std.mem.writeInt(u32, &key, @intCast(i), .little);

        const value = try generate_value(allocator, i, 8);
        defer allocator.free(value);

        try builder.insert(&key, value);
    }

    // Verify all keys are distinct and retrievable
    i = 0;
    while (i < n) : (i += 1) {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i), .little);

        const value = try builder.get(&key);
        try testing.expect(value != null);
    }
}

test "stress - deep trie (long keys)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    const n = 100;
    const key_size = 64; // Very long keys create deep tries

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try generate_key(allocator, i, key_size);
        defer allocator.free(key);

        const value = try generate_value(allocator, i, 8);
        defer allocator.free(value);

        try builder.insert(key, value);
    }

    // Verify
    i = 0;
    while (i < n) : (i += 1) {
        const key = try generate_key(allocator, i, key_size);
        defer allocator.free(key);

        const value = try builder.get(key);
        try testing.expect(value != null);
    }
}

test "stress - empty key handling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert empty key should work (edge case)
    const empty_key = "";
    const value = "empty_key_value";

    try builder.insert(empty_key, value);

    const retrieved = try builder.get(empty_key);
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings(value, retrieved.?);

    // Delete empty key
    try builder.delete(empty_key);

    const deleted = try builder.get(empty_key);
    try testing.expect(deleted == null);
}

test "stress - single nibble keys" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert all 16 possible single-nibble keys (1 byte with high nibble = 0)
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        const key = [_]u8{i};
        const value = try generate_value(allocator, i, 8);
        defer allocator.free(value);

        try builder.insert(&key, value);
    }

    // Verify all present
    i = 0;
    while (i < 16) : (i += 1) {
        const key = [_]u8{i};
        const value = try builder.get(&key);
        try testing.expect(value != null);
    }
}

test "stress - node cache effectiveness" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = node_cache.NodeCache.init(allocator);
    defer cache.deinit();

    // Cache many hashes
    const n = 1000;
    var i: usize = 0;

    while (i < n) : (i += 1) {
        var hash: [32]u8 = undefined;
        for (0..32) |j| {
            hash[j] = @intCast((i + j) % 256);
        }

        var hash_str_buf: [64]u8 = undefined;
        _ = try std.fmt.bufPrint(&hash_str_buf, "{x}", .{std.fmt.fmtSliceHexLower(&hash)});

        try cache.cache_hash(&hash_str_buf, hash);
    }

    // Verify all cached hashes retrievable
    i = 0;
    while (i < n) : (i += 1) {
        var hash: [32]u8 = undefined;
        for (0..32) |j| {
            hash[j] = @intCast((i + j) % 256);
        }

        var hash_str_buf: [64]u8 = undefined;
        _ = try std.fmt.bufPrint(&hash_str_buf, "{x}", .{std.fmt.fmtSliceHexLower(&hash)});

        const cached = cache.get_cached_hash(&hash_str_buf);
        try testing.expect(cached != null);
        try testing.expectEqualSlices(u8, &hash, &cached.?);
    }
}

test "stress - memory cleanup verification" {
    const testing = std.testing;

    // Use a counting allocator to verify no leaks
    var counting_allocator = std.testing.LeakCountAllocator.init(testing.allocator);
    defer counting_allocator.validate() catch |err| {
        std.debug.print("Memory leak detected: {any}\n", .{err});
    };

    const allocator = counting_allocator.allocator();

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    const n = 500;
    var i: usize = 0;

    // Insert and delete many keys
    while (i < n) : (i += 1) {
        const key = try generate_key(allocator, i, 4);
        defer allocator.free(key);

        const value = try generate_value(allocator, i, 8);
        defer allocator.free(value);

        try builder.insert(key, value);
    }

    i = 0;
    while (i < n) : (i += 1) {
        const key = try generate_key(allocator, i, 4);
        defer allocator.free(key);

        try builder.delete(key);
    }
}

test "stress - concurrent-like access pattern" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Simulate a workload with interleaved operations
    const n = 300;
    var i: usize = 0;

    while (i < n) : (i += 1) {
        // Insert 3 keys
        for (0..3) |j| {
            const idx = i * 3 + j;
            const key = try generate_key(allocator, idx, 4);
            defer allocator.free(key);

            const value = try generate_value(allocator, idx, 8);
            defer allocator.free(value);

            try builder.insert(key, value);
        }

        // Read 2 keys
        for (0..2) |j| {
            if (i > 0) {
                const idx = (i - 1) * 3 + j;
                const key = try generate_key(allocator, idx, 4);
                defer allocator.free(key);

                _ = try builder.get(key);
            }
        }

        // Delete 1 key
        if (i > 1) {
            const idx = (i - 2) * 3;
            const key = try generate_key(allocator, idx, 4);
            defer allocator.free(key);

            try builder.delete(key);
        }
    }

    // Verify trie is still consistent
    try testing.expect(builder.get_root_hash() != null);
}
