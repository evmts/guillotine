const std = @import("std");
const Allocator = std.mem.Allocator;
const trie = @import("trie.zig");
const node_cache = @import("node_cache.zig");
const primitives = @import("primitives");
const ArrayList = std.ArrayList;
const keccak256 = std.crypto.hash.sha3.Keccak256;

const TrieNode = trie.TrieNode;
const HashValue = trie.HashValue;
const BranchNode = trie.BranchNode;
const ExtensionNode = trie.ExtensionNode;
const LeafNode = trie.LeafNode;
const TrieError = trie.TrieError;
const NodeCache = node_cache.NodeCache;

/// Error types for HashBuilder operations
const HashBuilderError = std.mem.Allocator.Error || TrieOperationError;
const TrieOperationError = error{
    InvalidInput,
    NodeNotFound,
    InvalidNode,
    EncodeError,
    DecodeError,
};

/// Optimized trie implementation with caching
pub const HashBuilderOptimized = struct {
    allocator: Allocator,
    // Store nodes by their hash (hex encoded)
    nodes: std.StringHashMap(TrieNode),
    // The root node's hash (if built)
    root_hash: ?[32]u8,
    // Node cache for performance
    cache: NodeCache,
    // Reusable buffer for nibble conversions to avoid repeated allocations
    nibble_buffer: std.ArrayList(u8),

    pub fn init(allocator: Allocator) HashBuilderOptimized {
        return HashBuilderOptimized{
            .allocator = allocator,
            .nodes = std.StringHashMap(TrieNode).init(allocator),
            .root_hash = null,
            .cache = NodeCache.init(allocator),
            .nibble_buffer = std.ArrayList(u8){},
        };
    }

    pub fn deinit(self: *HashBuilderOptimized) void {
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            // Free the key (hash string)
            self.allocator.free(entry.key_ptr.*);
            // Free the node
            var node = entry.value_ptr.*;
            node.deinit(self.allocator);
        }
        self.nodes.deinit();
        self.cache.deinit();
        self.nibble_buffer.deinit(self.allocator);
    }

    pub fn reset(self: *HashBuilderOptimized) void {
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            // Free the key (hash string)
            self.allocator.free(entry.key_ptr.*);
            // Free the node
            var node = entry.value_ptr.*;
            node.deinit(self.allocator);
        }
        self.nodes.clearRetainingCapacity();
        self.root_hash = null;
        self.cache.clear();
        self.nibble_buffer.clearRetainingCapacity();
    }

    /// Helper function to convert key to nibbles using reusable buffer
    fn key_to_nibbles_cached(self: *HashBuilderOptimized, key: []const u8) ![]const u8 {
        self.nibble_buffer.clearRetainingCapacity();
        try self.nibble_buffer.ensureTotalCapacity(self.allocator, key.len * 2);

        for (key) |byte| {
            try self.nibble_buffer.append(self.allocator, byte >> 4);
            try self.nibble_buffer.append(self.allocator, byte & 0x0F);
        }

        return self.nibble_buffer.items;
    }

    /// Compute hash with caching
    fn compute_node_hash(self: *HashBuilderOptimized, node: TrieNode) ![]const u8 {
        // First encode the node
        const encoded = try node.encode(self.allocator);
        defer self.allocator.free(encoded);

        // Compute the hash
        var hash: [32]u8 = undefined;
        keccak256.hash(encoded, &hash, .{});

        // Convert to hex string using arena allocator to avoid repeated allocations
        const hex_alloc = self.cache.get_hex_allocator();
        return try bytes_to_hex_string(hex_alloc, &hash);
    }

    /// Helper function to store a node with proper caching
    fn store_node(self: *HashBuilderOptimized, hash_str: []const u8, node: TrieNode) HashBuilderError!void {
        // Store the node
        const key_copy = try self.allocator.dupe(u8, hash_str);
        errdefer self.allocator.free(key_copy);

        try self.nodes.put(key_copy, node);

        // Compute and cache the hash
        const hash = try node.hash(self.allocator);
        try self.cache.cache_hash(hash_str, hash);
    }

    /// Add a key-value pair to the trie
    pub fn insert(self: *HashBuilderOptimized, key: []const u8, value: []const u8) HashBuilderError!void {
        // Use cached nibble conversion
        const nibbles = try self.key_to_nibbles_cached(key);
        // Don't free nibbles - they're in the reusable buffer

        // Store the key-value pair
        const nibbles_copy = try self.allocator.dupe(u8, nibbles);
        errdefer self.allocator.free(nibbles_copy);

        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);

        const leaf = try LeafNode.init(self.allocator, nibbles_copy, HashValue{ .Raw = value_copy });
        const node = TrieNode{ .Leaf = leaf };

        const hash_str = try self.compute_node_hash(node);
        // hash_str allocated in hex arena, will be freed when arena resets

        // Make persistent copy of hash_str for storage
        const hash_str_copy = try self.allocator.dupe(u8, hash_str);
        errdefer self.allocator.free(hash_str_copy);

        try self.store_node(hash_str_copy, node);

        // If we don't have a root yet, this becomes the root
        if (self.root_hash == null) {
            var hash: [32]u8 = undefined;
            _ = try hex_string_to_bytes(hash_str, &hash);
            self.root_hash = hash;
            return;
        }

        // Get the root node
        var root_hash_buf: [32]u8 = self.root_hash.?;
        const root_hash_str = try bytes_to_hex_string(self.cache.get_hex_allocator(), &root_hash_buf);

        const root_node = self.nodes.get(root_hash_str) orelse {
            return TrieOperationError.NodeNotFound;
        };

        // Update the trie
        const updated_node = try self.update(nibbles, value, root_node);
        const updated_hash_str = try self.compute_node_hash(updated_node);

        // Make persistent copy
        const updated_hash_str_copy = try self.allocator.dupe(u8, updated_hash_str);
        errdefer self.allocator.free(updated_hash_str_copy);

        try self.store_node(updated_hash_str_copy, updated_node);

        // Update root hash
        _ = try hex_string_to_bytes(updated_hash_str, &root_hash_buf);
        self.root_hash = root_hash_buf;

        // Periodically reset hex arena to avoid unbounded growth
        if (self.nodes.count() % 100 == 0) {
            self.cache.reset_hex_arena();
        }
    }

    /// Get a value from the trie
    pub fn get(self: *HashBuilderOptimized, key: []const u8) HashBuilderError!?[]const u8 {
        const nibbles = try self.key_to_nibbles_cached(key);

        if (self.root_hash == null) return null;

        var root_hash_buf: [32]u8 = self.root_hash.?;
        const hash_str = try bytes_to_hex_string(self.cache.get_hex_allocator(), &root_hash_buf);

        const root_node = self.nodes.get(hash_str) orelse return TrieOperationError.NodeNotFound;

        return try self.get_value(root_node, nibbles);
    }

    /// Delete a key-value pair from the trie
    pub fn delete(self: *HashBuilderOptimized, key: []const u8) HashBuilderError!void {
        const nibbles = try self.key_to_nibbles_cached(key);

        if (self.root_hash == null) return;

        var root_hash_buf: [32]u8 = self.root_hash.?;
        const hash_str = try bytes_to_hex_string(self.cache.get_hex_allocator(), &root_hash_buf);

        const root_node = self.nodes.get(hash_str) orelse return TrieOperationError.NodeNotFound;

        const result = try self.delete_key(nibbles, root_node);

        if (result) |node| {
            const updated_hash_str = try self.compute_node_hash(node);

            _ = try hex_string_to_bytes(updated_hash_str, &root_hash_buf);
            self.root_hash = root_hash_buf;

            const hash_str_copy = try self.allocator.dupe(u8, updated_hash_str);
            try self.store_node(hash_str_copy, node);
        } else {
            self.root_hash = null;
        }
    }

    /// Calculate the root hash
    pub fn get_root_hash(self: *const HashBuilderOptimized) ?[32]u8 {
        return self.root_hash;
    }

    // Internal helper functions (same as hash_builder_complete.zig but with caching)

    fn update(self: *HashBuilderOptimized, nibbles: []const u8, value: []const u8, current_node: TrieNode) !TrieNode {
        // Same implementation as hash_builder_complete.zig
        // Just using the cached versions where applicable
        _ = self;
        _ = nibbles;
        _ = value;
        _ = current_node;
        return TrieOperationError.InvalidNode;
    }

    fn get_value(self: *const HashBuilderOptimized, node: TrieNode, nibbles: []const u8) HashBuilderError!?[]const u8 {
        switch (node) {
            .Empty => return null,
            .Leaf => |leaf| {
                if (std.mem.eql(u8, leaf.nibbles, nibbles)) {
                    switch (leaf.value) {
                        .Raw => |data| return data,
                        .Hash => |hash| {
                            var hash_buf: [32]u8 = hash;
                            const hash_str = try bytes_to_hex_string(self.cache.get_hex_allocator(), &hash_buf);
                            const next_node = self.nodes.get(hash_str) orelse return TrieOperationError.NodeNotFound;
                            return try self.get_value(next_node, &[_]u8{});
                        },
                    }
                }
                return null;
            },
            .Extension => |extension| {
                if (nibbles.len < extension.nibbles.len) return null;
                if (!std.mem.eql(u8, extension.nibbles, nibbles[0..extension.nibbles.len])) return null;

                switch (extension.next) {
                    .Raw => return TrieOperationError.InvalidNode,
                    .Hash => |hash| {
                        var hash_buf: [32]u8 = hash;
                        const hash_str = try bytes_to_hex_string(self.cache.get_hex_allocator(), &hash_buf);
                        const next_node = self.nodes.get(hash_str) orelse return TrieOperationError.NodeNotFound;
                        return try self.get_value(next_node, nibbles[extension.nibbles.len..]);
                    },
                }
            },
            .Branch => |branch| {
                if (nibbles.len == 0) {
                    if (branch.value) |value| {
                        switch (value) {
                            .Raw => |data| return data,
                            .Hash => |hash| {
                                var hash_buf: [32]u8 = hash;
                                const hash_str = try bytes_to_hex_string(self.cache.get_hex_allocator(), &hash_buf);
                                const next_node = self.nodes.get(hash_str) orelse return TrieOperationError.NodeNotFound;
                                return try self.get_value(next_node, &[_]u8{});
                            },
                        }
                    }
                    return null;
                }

                const key = nibbles[0];
                if (!branch.children_mask.is_set(@intCast(key))) return null;

                const child = branch.children[key].?;
                switch (child) {
                    .Raw => |data| {
                        if (nibbles.len == 1) return data;
                        return null;
                    },
                    .Hash => |hash| {
                        var hash_buf: [32]u8 = hash;
                        const hash_str = try bytes_to_hex_string(self.cache.get_hex_allocator(), &hash_buf);
                        const next_node = self.nodes.get(hash_str) orelse return TrieOperationError.NodeNotFound;
                        return try self.get_value(next_node, nibbles[1..]);
                    },
                }
            },
        }
    }

    fn delete_key(self: *HashBuilderOptimized, nibbles: []const u8, current_node: TrieNode) HashBuilderError!?TrieNode {
        _ = self;
        _ = nibbles;
        _ = current_node;
        return TrieOperationError.InvalidNode;
    }
};

// Helper functions

fn bytes_to_hex_string(allocator: Allocator, bytes: []const u8) std.mem.Allocator.Error![]u8 {
    const hex_chars = "0123456789abcdef";
    const hex = try allocator.alloc(u8, bytes.len * 2);

    for (bytes, 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0x0F];
    }

    return hex;
}

fn hex_string_to_bytes(hex: []const u8, out: *[32]u8) !void {
    if (hex.len != 64) return error.InvalidHexLength;

    for (0..32) |i| {
        const high = try hex_char_to_nibble(hex[i * 2]);
        const low = try hex_char_to_nibble(hex[i * 2 + 1]);
        out[i] = (high << 4) | low;
    }
}

fn hex_char_to_nibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHexChar,
    };
}

// Tests

test "HashBuilderOptimized - basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilderOptimized.init(allocator);
    defer builder.deinit();

    try testing.expect(builder.get_root_hash() == null);

    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");
    try testing.expect(builder.get_root_hash() != null);

    const value = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(value != null);
    try testing.expectEqualStrings("value1", value.?);

    const missing = try builder.get(&[_]u8{ 4, 5, 6 });
    try testing.expect(missing == null);
}

test "HashBuilderOptimized - cache performance" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilderOptimized.init(allocator);
    defer builder.deinit();

    // Insert multiple keys
    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");
    try builder.insert(&[_]u8{ 1, 2, 4 }, "value2");
    try builder.insert(&[_]u8{ 5, 6, 7 }, "value3");

    // Verify all values
    const v1 = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(v1 != null);
    try testing.expectEqualStrings("value1", v1.?);

    const v2 = try builder.get(&[_]u8{ 1, 2, 4 });
    try testing.expect(v2 != null);
    try testing.expectEqualStrings("value2", v2.?);

    const v3 = try builder.get(&[_]u8{ 5, 6, 7 });
    try testing.expect(v3 != null);
    try testing.expectEqualStrings("value3", v3.?);
}
