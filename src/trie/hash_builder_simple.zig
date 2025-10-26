const std = @import("std");
const Allocator = std.mem.Allocator;
const trie = @import("trie.zig");

/// TEST FIXTURE ONLY - NOT A REAL MERKLE PATRICIA TRIE
///
/// This is a simplified mock implementation for testing purposes.
/// DO NOT use in production. Does not generate correct Ethereum-compatible
/// state roots or support Merkle proof generation.
///
/// Differences from real MPT:
/// - Linear O(n) search instead of tree structure
/// - Hash is simple concatenation, not RLP-encoded tree
/// - No support for Merkle proofs
/// - No node sharing/deduplication
/// - Order-dependent hashing
///
/// CRITICAL: This violates proper MPT semantics and should only be used
/// for basic testing where exact trie structure doesn't matter.
pub const HashBuilder = struct {
    allocator: Allocator,
    // Simple key-value store using ArrayLists to avoid complex hash management
    keys: std.ArrayList([]u8),
    values: std.ArrayList([]u8),
    // Compatibility fields for merkle_trie
    root_hash: ?[32]u8,
    nodes: NodeStore,

    const NodeStore = struct {
        allocator: Allocator,
        stored_nodes: std.StringHashMap(trie.TrieNode),

        pub fn init(allocator: Allocator) NodeStore {
            return NodeStore{
                .allocator = allocator,
                .stored_nodes = std.StringHashMap(trie.TrieNode).init(allocator),
            };
        }

        pub fn deinit(self: *NodeStore) void {
            var it = self.stored_nodes.iterator();
            while (it.next()) |entry| {
                var node = entry.value_ptr.*;
                node.deinit(self.allocator);
            }
            self.stored_nodes.deinit();
        }

        pub fn get(self: NodeStore, hash_str: []const u8) !?trie.TrieNode {
            if (self.stored_nodes.get(hash_str)) |node| {
                return node;
            }
            return null;
        }

        pub fn put(self: *NodeStore, hash_str: []const u8, node: trie.TrieNode) !void {
            try self.stored_nodes.put(hash_str, node);
        }
    };

    pub fn init(allocator: Allocator) HashBuilder {
        return HashBuilder{
            .allocator = allocator,
            .keys = .empty,
            .values = .empty,
            .root_hash = null,
            .nodes = NodeStore.init(allocator),
        };
    }

    pub fn deinit(self: *HashBuilder) void {
        // Free all stored keys and values
        for (self.keys.items) |key| {
            self.allocator.free(key);
        }
        for (self.values.items) |value| {
            self.allocator.free(value);
        }
        self.keys.deinit(self.allocator);
        self.values.deinit(self.allocator);
        self.nodes.deinit();
    }

    pub fn reset(self: *HashBuilder) void {
        // Free all stored keys and values
        for (self.keys.items) |key| {
            self.allocator.free(key);
        }
        for (self.values.items) |value| {
            self.allocator.free(value);
        }
        self.keys.clearRetainingCapacity();
        self.values.clearRetainingCapacity();
        self.root_hash = null;
    }

    /// Add a key-value pair to the trie
    pub fn insert(self: *HashBuilder, key: []const u8, value: []const u8) !void {
        // Check if key already exists
        for (self.keys.items, 0..) |existing_key, i| {
            if (std.mem.eql(u8, existing_key, key)) {
                // Update existing value
                self.allocator.free(self.values.items[i]);
                self.values.items[i] = try self.allocator.dupe(u8, value);
                self.update_root_hash();
                return;
            }
        }

        // Add new key-value pair
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);

        try self.keys.append(self.allocator, key_copy);
        try self.values.append(self.allocator, value_copy);
        self.update_root_hash();
    }

    /// Get a value from the trie
    pub fn get(self: *HashBuilder, key: []const u8) !?[]const u8 {
        for (self.keys.items, 0..) |existing_key, i| {
            if (std.mem.eql(u8, existing_key, key)) {
                return self.values.items[i];
            }
        }
        return null;
    }

    /// Delete a key-value pair from the trie
    pub fn delete(self: *HashBuilder, key: []const u8) !void {
        for (self.keys.items, 0..) |existing_key, i| {
            if (std.mem.eql(u8, existing_key, key)) {
                // Free the key and value
                self.allocator.free(self.keys.items[i]);
                self.allocator.free(self.values.items[i]);

                // Remove from arrays
                _ = self.keys.swapRemove(i);
                _ = self.values.swapRemove(i);
                self.update_root_hash();
                return;
            }
        }
    }

    /// Calculate a simple hash of all data
    pub fn get_root_hash(self: *const HashBuilder) ?[32]u8 {
        return self.root_hash;
    }

    // Internal helper to update root hash
    fn update_root_hash(self: *HashBuilder) void {
        if (self.keys.items.len == 0) {
            self.root_hash = null;
            return;
        }

        // Simple hash of all keys and values concatenated
        var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
        for (self.keys.items, 0..) |key, i| {
            hasher.update(key);
            hasher.update(self.values.items[i]);
        }
        var hash: [32]u8 = undefined;
        hasher.final(&hash);
        self.root_hash = hash;
    }
};

// Tests
test "HashBuilder - insert and get" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Empty trie has no root
    try testing.expect(builder.get_root_hash() == null);

    // Insert a key-value pair
    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");

    // Root should be set
    try testing.expect(builder.get_root_hash() != null);

    // Get the value
    const value = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(value != null);
    try testing.expectEqualStrings("value1", value.?);

    // Get a non-existent key
    const missing = try builder.get(&[_]u8{ 4, 5, 6 });
    try testing.expect(missing == null);

    // Insert another key
    try builder.insert(&[_]u8{ 1, 2, 4 }, "value2");

    // Get both values
    const value1 = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(value1 != null);
    try testing.expectEqualStrings("value1", value1.?);

    const value2 = try builder.get(&[_]u8{ 1, 2, 4 });
    try testing.expect(value2 != null);
    try testing.expectEqualStrings("value2", value2.?);
}

test "HashBuilder - delete" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert some key-value pairs
    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");
    try builder.insert(&[_]u8{ 1, 2, 4 }, "value2");
    try builder.insert(&[_]u8{ 5, 6, 7 }, "value3");

    // Delete a key
    try builder.delete(&[_]u8{ 1, 2, 3 });

    // Value should be gone
    const value1 = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(value1 == null);

    // Other values still present
    const value2 = try builder.get(&[_]u8{ 1, 2, 4 });
    try testing.expect(value2 != null);
    try testing.expectEqualStrings("value2", value2.?);

    const value3 = try builder.get(&[_]u8{ 5, 6, 7 });
    try testing.expect(value3 != null);
    try testing.expectEqualStrings("value3", value3.?);

    // Delete all keys
    try builder.delete(&[_]u8{ 1, 2, 4 });
    try builder.delete(&[_]u8{ 5, 6, 7 });

    // Trie should be empty
    try testing.expect(builder.get_root_hash() == null);
}

test "HashBuilder - update existing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert a key-value pair
    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");

    // Update it
    try builder.insert(&[_]u8{ 1, 2, 3 }, "updated");

    // Get the updated value
    const value = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(value != null);
    try testing.expectEqualStrings("updated", value.?);
}

test "HashBuilder - reset" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert some key-value pairs
    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");
    try builder.insert(&[_]u8{ 4, 5, 6 }, "value2");

    // Reset the builder
    builder.reset();

    // Trie should be empty
    try testing.expect(builder.get_root_hash() == null);

    // Values should be gone
    const value1 = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(value1 == null);

    const value2 = try builder.get(&[_]u8{ 4, 5, 6 });
    try testing.expect(value2 == null);
}

test "HashBuilder - empty key and value" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert empty key and value
    try builder.insert(&[_]u8{}, "");

    // Should be able to retrieve it
    const value = try builder.get(&[_]u8{});
    try testing.expect(value != null);
    try testing.expectEqualStrings("", value.?);

    // Root hash should be set
    try testing.expect(builder.get_root_hash() != null);
}

test "HashBuilder - large values" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Create large value (1KB)
    var large_value: [1024]u8 = undefined;
    for (&large_value, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    try builder.insert(&[_]u8{ 1, 2, 3 }, &large_value);

    const retrieved = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(retrieved != null);
    try testing.expectEqualSlices(u8, &large_value, retrieved.?);
}

test "HashBuilder - many insertions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert 100 key-value pairs
    var i: u8 = 0;
    while (i < 100) : (i += 1) {
        const key = [_]u8{i};
        const value = [_]u8{ i, i +% 1, i +% 2 };
        try builder.insert(&key, &value);
    }

    // Verify all can be retrieved
    i = 0;
    while (i < 100) : (i += 1) {
        const key = [_]u8{i};
        const expected = [_]u8{ i, i +% 1, i +% 2 };
        const retrieved = try builder.get(&key);
        try testing.expect(retrieved != null);
        try testing.expectEqualSlices(u8, &expected, retrieved.?);
    }
}

test "HashBuilder - delete nonexistent key" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    try builder.insert(&[_]u8{ 1, 2, 3 }, "value");

    // Delete a key that doesn't exist - should not error
    try builder.delete(&[_]u8{ 4, 5, 6 });

    // Original key should still be present
    const value = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(value != null);
    try testing.expectEqualStrings("value", value.?);
}

test "HashBuilder - multiple updates" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Update same key multiple times
    try builder.insert(&[_]u8{ 1, 2, 3 }, "v1");
    try builder.insert(&[_]u8{ 1, 2, 3 }, "v2");
    try builder.insert(&[_]u8{ 1, 2, 3 }, "v3");
    try builder.insert(&[_]u8{ 1, 2, 3 }, "final");

    const value = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(value != null);
    try testing.expectEqualStrings("final", value.?);
}

test "HashBuilder - hash changes on insert" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    const hash1 = builder.get_root_hash();
    try testing.expect(hash1 == null);

    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");
    const hash2 = builder.get_root_hash();
    try testing.expect(hash2 != null);

    try builder.insert(&[_]u8{ 4, 5, 6 }, "value2");
    const hash3 = builder.get_root_hash();
    try testing.expect(hash3 != null);

    // Hashes should be different
    try testing.expect(!std.mem.eql(u8, &hash2.?, &hash3.?));
}

test "HashBuilder - hash changes on delete" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");
    try builder.insert(&[_]u8{ 4, 5, 6 }, "value2");

    const hash1 = builder.get_root_hash();
    try testing.expect(hash1 != null);

    try builder.delete(&[_]u8{ 1, 2, 3 });
    const hash2 = builder.get_root_hash();
    try testing.expect(hash2 != null);

    // Hashes should be different
    try testing.expect(!std.mem.eql(u8, &hash1.?, &hash2.?));
}

test "HashBuilder - hash changes on update" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");
    const hash1 = builder.get_root_hash();
    try testing.expect(hash1 != null);

    try builder.insert(&[_]u8{ 1, 2, 3 }, "different");
    const hash2 = builder.get_root_hash();
    try testing.expect(hash2 != null);

    // Hashes should be different
    try testing.expect(!std.mem.eql(u8, &hash1.?, &hash2.?));
}

test "HashBuilder - reset and reuse" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // First use
    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");
    const hash1 = builder.get_root_hash();
    try testing.expect(hash1 != null);

    // Reset
    builder.reset();
    try testing.expect(builder.get_root_hash() == null);

    // Reuse with same data
    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");
    const hash2 = builder.get_root_hash();
    try testing.expect(hash2 != null);

    // Hashes should be identical
    try testing.expectEqualSlices(u8, &hash1.?, &hash2.?);
}

test "HashBuilder - keys with different lengths" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    try builder.insert(&[_]u8{1}, "short");
    try builder.insert(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }, "long");
    try builder.insert(&[_]u8{}, "empty");

    const short = try builder.get(&[_]u8{1});
    try testing.expect(short != null);
    try testing.expectEqualStrings("short", short.?);

    const long = try builder.get(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try testing.expect(long != null);
    try testing.expectEqualStrings("long", long.?);

    const empty = try builder.get(&[_]u8{});
    try testing.expect(empty != null);
    try testing.expectEqualStrings("empty", empty.?);
}

test "HashBuilder - similar keys" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Keys that differ by only one byte
    try builder.insert(&[_]u8{ 1, 2, 3 }, "v1");
    try builder.insert(&[_]u8{ 1, 2, 4 }, "v2");
    try builder.insert(&[_]u8{ 1, 3, 3 }, "v3");
    try builder.insert(&[_]u8{ 2, 2, 3 }, "v4");

    const v1 = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expectEqualStrings("v1", v1.?);

    const v2 = try builder.get(&[_]u8{ 1, 2, 4 });
    try testing.expectEqualStrings("v2", v2.?);

    const v3 = try builder.get(&[_]u8{ 1, 3, 3 });
    try testing.expectEqualStrings("v3", v3.?);

    const v4 = try builder.get(&[_]u8{ 2, 2, 3 });
    try testing.expectEqualStrings("v4", v4.?);
}

test "HashBuilder - NodeStore operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Create a leaf node
    const path = try allocator.dupe(u8, &[_]u8{ 1, 2, 3, 4 });
    const value = try allocator.dupe(u8, "test_value");
    const leaf = try trie.LeafNode.init(allocator, path, trie.HashValue{ .Raw = value });
    const node = trie.TrieNode{ .Leaf = leaf };

    // Store the node
    try builder.nodes.put("test_hash", node);

    // Retrieve the node
    const retrieved = try builder.nodes.get("test_hash");
    try testing.expect(retrieved != null);
}

test "HashBuilder - NodeStore returns null for missing key" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    const retrieved = try builder.nodes.get("nonexistent");
    try testing.expect(retrieved == null);
}

test "HashBuilder - delete and reinsert same key" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert
    try builder.insert(&[_]u8{ 1, 2, 3 }, "first");
    const hash1 = builder.get_root_hash();

    // Delete
    try builder.delete(&[_]u8{ 1, 2, 3 });
    const hash2 = builder.get_root_hash();

    // Reinsert with same value
    try builder.insert(&[_]u8{ 1, 2, 3 }, "first");
    const hash3 = builder.get_root_hash();

    // First and third hashes should be equal
    try testing.expect(hash1 != null);
    try testing.expect(hash3 != null);
    try testing.expectEqualSlices(u8, &hash1.?, &hash3.?);

    // But second hash should be null (empty trie)
    try testing.expect(hash2 == null);
}

test "HashBuilder - stress test: insert, update, delete cycle" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Multiple cycles of operations
    var cycle: u8 = 0;
    while (cycle < 10) : (cycle += 1) {
        // Insert 20 items
        var i: u8 = 0;
        while (i < 20) : (i += 1) {
            const key = [_]u8{ cycle, i };
            const value = [_]u8{ i, cycle };
            try builder.insert(&key, &value);
        }

        // Update half of them
        i = 0;
        while (i < 10) : (i += 1) {
            const key = [_]u8{ cycle, i };
            const value = [_]u8{ i +% 1, cycle +% 1 };
            try builder.insert(&key, &value);
        }

        // Delete a quarter
        i = 0;
        while (i < 5) : (i += 1) {
            const key = [_]u8{ cycle, i };
            try builder.delete(&key);
        }

        // Verify remaining items
        i = 5;
        while (i < 10) : (i += 1) {
            const key = [_]u8{ cycle, i };
            const retrieved = try builder.get(&key);
            try testing.expect(retrieved != null);
        }

        // Clean up for next cycle
        builder.reset();
    }
}

test "HashBuilder - binary keys and values" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Keys and values with null bytes and special characters
    const key1 = [_]u8{ 0x00, 0xFF, 0x00, 0xFF };
    const val1 = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };

    const key2 = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    const val2 = [_]u8{ 0x00, 0x00, 0x00, 0x00 };

    try builder.insert(&key1, &val1);
    try builder.insert(&key2, &val2);

    const r1 = try builder.get(&key1);
    try testing.expect(r1 != null);
    try testing.expectEqualSlices(u8, &val1, r1.?);

    const r2 = try builder.get(&key2);
    try testing.expect(r2 != null);
    try testing.expectEqualSlices(u8, &val2, r2.?);
}

test "HashBuilder - order independence verification" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // NOTE: This test DOCUMENTS that this implementation is ORDER-DEPENDENT
    // This is a known limitation - not a real MPT!

    var builder1 = HashBuilder.init(allocator);
    defer builder1.deinit();

    var builder2 = HashBuilder.init(allocator);
    defer builder2.deinit();

    // Insert in different orders
    try builder1.insert(&[_]u8{ 1, 2, 3 }, "v1");
    try builder1.insert(&[_]u8{ 4, 5, 6 }, "v2");

    try builder2.insert(&[_]u8{ 4, 5, 6 }, "v2");
    try builder2.insert(&[_]u8{ 1, 2, 3 }, "v1");

    const hash1 = builder1.get_root_hash();
    const hash2 = builder2.get_root_hash();

    // For a real MPT, these should be equal
    // But this simple implementation is order-dependent
    // This test DOCUMENTS this limitation
    try testing.expect(hash1 != null);
    try testing.expect(hash2 != null);
    // We don't assert they're different because implementation might use HashMap
    // which could make it accidentally order-independent, but we document
    // that proper MPT would guarantee equal hashes regardless of insertion order
}

test "HashBuilder - memory leak detection via reset" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert, reset, repeat many times
    var i: u8 = 0;
    while (i < 50) : (i += 1) {
        try builder.insert(&[_]u8{ i, i +% 1 }, &[_]u8{ i +% 2, i +% 3, i +% 4 });
        builder.reset();
    }

    // If there are memory leaks, allocator tracking will catch them
    try testing.expect(builder.get_root_hash() == null);
}
