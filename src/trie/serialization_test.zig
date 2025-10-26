const std = @import("std");
const testing = std.testing;
const trie = @import("trie.zig");
const primitives = @import("primitives");

const BranchNode = trie.BranchNode;
const ExtensionNode = trie.ExtensionNode;
const LeafNode = trie.LeafNode;
const TrieNode = trie.TrieNode;
const HashValue = trie.HashValue;
const encode_path = @import("trie.zig").encode_path;
const decode_path = @import("trie.zig").decode_path;

test "BranchNode - empty branch encoding" {
    const allocator = testing.allocator;

    var branch = BranchNode.init();
    defer branch.deinit(allocator);

    const encoded = try branch.encode(allocator);
    defer allocator.free(encoded);

    // Decode to verify structure
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            // Branch node should have exactly 17 elements (16 children + 1 value)
            try testing.expectEqual(@as(usize, 17), items.len);

            // All children should be empty strings
            for (items[0..16]) |item| {
                switch (item) {
                    .String => |str| {
                        try testing.expectEqual(@as(usize, 0), str.len);
                    },
                    .List => return error.TestExpectedString,
                }
            }

            // Value slot should also be empty string
            switch (items[16]) {
                .String => |str| {
                    try testing.expectEqual(@as(usize, 0), str.len);
                },
                .List => return error.TestExpectedString,
            }
        },
        .String => return error.TestExpectedList,
    }
}

test "BranchNode - single child encoding" {
    const allocator = testing.allocator;

    var branch = BranchNode.init();
    defer branch.deinit(allocator);

    // Add a value at index 5
    const data = "test_value";
    const data_copy = try allocator.dupe(u8, data);
    branch.children[5] = HashValue{ .Raw = data_copy };
    branch.children_mask.set(5);

    const encoded = try branch.encode(allocator);
    defer allocator.free(encoded);

    // Decode to verify structure
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            try testing.expectEqual(@as(usize, 17), items.len);

            // Check child at index 5
            switch (items[5]) {
                .String => |str| {
                    try testing.expect(str.len > 0);
                },
                .List => return error.TestExpectedString,
            }
        },
        .String => return error.TestExpectedList,
    }
}

test "BranchNode - multiple children encoding" {
    const allocator = testing.allocator;

    var branch = BranchNode.init();
    defer branch.deinit(allocator);

    // Add values at multiple indices
    const data1 = "value1";
    const data1_copy = try allocator.dupe(u8, data1);
    branch.children[1] = HashValue{ .Raw = data1_copy };
    branch.children_mask.set(1);

    const data2 = "value2";
    const data2_copy = try allocator.dupe(u8, data2);
    branch.children[9] = HashValue{ .Raw = data2_copy };
    branch.children_mask.set(9);

    const data3 = "value3";
    const data3_copy = try allocator.dupe(u8, data3);
    branch.children[15] = HashValue{ .Raw = data3_copy };
    branch.children_mask.set(15);

    const encoded = try branch.encode(allocator);
    defer allocator.free(encoded);

    // Decode to verify structure
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            try testing.expectEqual(@as(usize, 17), items.len);
        },
        .String => return error.TestExpectedList,
    }
}

test "BranchNode - with terminal value" {
    const allocator = testing.allocator;

    var branch = BranchNode.init();
    defer branch.deinit(allocator);

    // Set terminal value
    const terminal_data = "terminal";
    const terminal_copy = try allocator.dupe(u8, terminal_data);
    branch.value = HashValue{ .Raw = terminal_copy };

    const encoded = try branch.encode(allocator);
    defer allocator.free(encoded);

    // Decode to verify structure
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            try testing.expectEqual(@as(usize, 17), items.len);

            // Last item should be the terminal value
            switch (items[16]) {
                .String => |str| {
                    try testing.expect(str.len > 0);
                },
                .List => return error.TestExpectedString,
            }
        },
        .String => return error.TestExpectedList,
    }
}

test "BranchNode - hash children encoding" {
    const allocator = testing.allocator;

    var branch = BranchNode.init();
    defer branch.deinit(allocator);

    // Add a hash value (32 bytes)
    var hash: [32]u8 = undefined;
    for (&hash, 0..) |*byte, i| {
        byte.* = @intCast(i);
    }

    branch.children[3] = HashValue{ .Hash = hash };
    branch.children_mask.set(3);

    const encoded = try branch.encode(allocator);
    defer allocator.free(encoded);

    // Decode to verify structure
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            try testing.expectEqual(@as(usize, 17), items.len);

            // Check that the hash child is present
            switch (items[3]) {
                .String => |str| {
                    // RLP encoded hash should be present
                    try testing.expect(str.len > 0);
                },
                .List => return error.TestExpectedString,
            }
        },
        .String => return error.TestExpectedList,
    }
}

test "LeafNode - simple encoding" {
    const allocator = testing.allocator;

    const path = [_]u8{ 1, 2, 3, 4 };
    const value = "leaf_value";
    const value_copy = try allocator.dupe(u8, value);
    const path_copy = try allocator.dupe(u8, &path);

    var leaf = try LeafNode.init(allocator, path_copy, HashValue{ .Raw = value_copy });
    defer leaf.deinit(allocator);

    const encoded = try leaf.encode(allocator);
    defer allocator.free(encoded);

    // Decode to verify structure
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            // Leaf node should have exactly 2 elements (path and value)
            try testing.expectEqual(@as(usize, 2), items.len);

            // Both should be strings
            switch (items[0]) {
                .String => |str| {
                    try testing.expect(str.len > 0);
                },
                .List => return error.TestExpectedString,
            }

            switch (items[1]) {
                .String => |str| {
                    try testing.expect(str.len > 0);
                },
                .List => return error.TestExpectedString,
            }
        },
        .String => return error.TestExpectedList,
    }
}

test "LeafNode - empty path encoding" {
    const allocator = testing.allocator;

    const value = "value";
    const value_copy = try allocator.dupe(u8, value);
    const path_copy = try allocator.alloc(u8, 0);

    var leaf = try LeafNode.init(allocator, path_copy, HashValue{ .Raw = value_copy });
    defer leaf.deinit(allocator);

    const encoded = try leaf.encode(allocator);
    defer allocator.free(encoded);

    // Decode to verify structure
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            try testing.expectEqual(@as(usize, 2), items.len);
        },
        .String => return error.TestExpectedList,
    }
}

test "LeafNode - long value encoding" {
    const allocator = testing.allocator;

    const path = [_]u8{ 1, 2 };
    // Create a value longer than 55 bytes to test long string encoding
    var long_value = try allocator.alloc(u8, 100);
    defer allocator.free(long_value);
    for (long_value, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    const value_copy = try allocator.dupe(u8, long_value);
    const path_copy = try allocator.dupe(u8, &path);

    var leaf = try LeafNode.init(allocator, path_copy, HashValue{ .Raw = value_copy });
    defer leaf.deinit(allocator);

    const encoded = try leaf.encode(allocator);
    defer allocator.free(encoded);

    // Decode to verify structure
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            try testing.expectEqual(@as(usize, 2), items.len);

            // Check that long value is properly encoded
            switch (items[1]) {
                .String => |str| {
                    try testing.expect(str.len > 55);
                },
                .List => return error.TestExpectedString,
            }
        },
        .String => return error.TestExpectedList,
    }
}

test "ExtensionNode - simple encoding" {
    const allocator = testing.allocator;

    const path = [_]u8{ 1, 2, 3, 4 };
    const next_value = "next_node_hash";
    const value_copy = try allocator.dupe(u8, next_value);
    const path_copy = try allocator.dupe(u8, &path);

    var extension = try ExtensionNode.init(allocator, path_copy, HashValue{ .Raw = value_copy });
    defer extension.deinit(allocator);

    const encoded = try extension.encode(allocator);
    defer allocator.free(encoded);

    // Decode to verify structure
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            // Extension node should have exactly 2 elements (path and next)
            try testing.expectEqual(@as(usize, 2), items.len);

            // Both should be strings
            switch (items[0]) {
                .String => |str| {
                    try testing.expect(str.len > 0);
                },
                .List => return error.TestExpectedString,
            }

            switch (items[1]) {
                .String => |str| {
                    try testing.expect(str.len > 0);
                },
                .List => return error.TestExpectedString,
            }
        },
        .String => return error.TestExpectedList,
    }
}

test "ExtensionNode - hash pointer encoding" {
    const allocator = testing.allocator;

    const path = [_]u8{ 5, 6 };
    var hash: [32]u8 = undefined;
    for (&hash, 0..) |*byte, i| {
        byte.* = @intCast(i * 7 % 256);
    }

    const path_copy = try allocator.dupe(u8, &path);

    var extension = try ExtensionNode.init(allocator, path_copy, HashValue{ .Hash = hash });
    defer extension.deinit(allocator);

    const encoded = try extension.encode(allocator);
    defer allocator.free(encoded);

    // Decode to verify structure
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            try testing.expectEqual(@as(usize, 2), items.len);
        },
        .String => return error.TestExpectedList,
    }
}

test "TrieNode - Empty encoding" {
    const allocator = testing.allocator;

    const node = TrieNode{ .Empty = {} };
    const encoded = try node.encode(allocator);
    defer allocator.free(encoded);

    // Empty node should encode as empty string (0x80 in RLP)
    try testing.expect(encoded.len > 0);

    // Decode to verify
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .String => |str| {
            try testing.expectEqual(@as(usize, 0), str.len);
        },
        .List => return error.TestExpectedString,
    }
}

test "TrieNode - hash calculation for branch" {
    const allocator = testing.allocator;

    var branch = BranchNode.init();
    defer branch.deinit(allocator);

    const data = "test";
    const data_copy = try allocator.dupe(u8, data);
    branch.children[0] = HashValue{ .Raw = data_copy };
    branch.children_mask.set(0);

    var node = TrieNode{ .Branch = branch };

    const hash = try node.hash(allocator);

    // Hash should be non-zero
    var is_zero = true;
    for (hash) |byte| {
        if (byte != 0) {
            is_zero = false;
            break;
        }
    }
    try testing.expect(!is_zero);

    // Hash should be deterministic - calculate again and compare
    var branch2 = BranchNode.init();
    const data2_copy = try allocator.dupe(u8, data);
    branch2.children[0] = HashValue{ .Raw = data2_copy };
    branch2.children_mask.set(0);

    var node2 = TrieNode{ .Branch = branch2 };
    defer node2.deinit(allocator);

    const hash2 = try node2.hash(allocator);

    try testing.expectEqualSlices(u8, &hash, &hash2);
}

test "TrieNode - hash calculation for leaf" {
    const allocator = testing.allocator;

    const path = [_]u8{ 1, 2, 3 };
    const value = "value";
    const value_copy = try allocator.dupe(u8, value);
    const path_copy = try allocator.dupe(u8, &path);

    const leaf = try LeafNode.init(allocator, path_copy, HashValue{ .Raw = value_copy });
    var node = TrieNode{ .Leaf = leaf };
    defer node.deinit(allocator);

    const hash = try node.hash(allocator);

    // Hash should be non-zero and 32 bytes
    var is_zero = true;
    for (hash) |byte| {
        if (byte != 0) {
            is_zero = false;
            break;
        }
    }
    try testing.expect(!is_zero);
}

test "encode_path - even nibbles extension" {
    const allocator = testing.allocator;

    const nibbles = [_]u8{ 0, 1, 2, 3 };
    const encoded = try encode_path(allocator, &nibbles, false);
    defer allocator.free(encoded);

    // Even number of nibbles, extension node: [0x00, 0x01, 0x23]
    try testing.expectEqual(@as(usize, 3), encoded.len);
    try testing.expectEqual(@as(u8, 0x00), encoded[0]); // Even extension prefix
    try testing.expectEqual(@as(u8, 0x01), encoded[1]);
    try testing.expectEqual(@as(u8, 0x23), encoded[2]);
}

test "encode_path - odd nibbles extension" {
    const allocator = testing.allocator;

    const nibbles = [_]u8{ 1, 2, 3, 4, 5 };
    const encoded = try encode_path(allocator, &nibbles, false);
    defer allocator.free(encoded);

    // Odd number of nibbles, extension node: [0x11, 0x23, 0x45]
    try testing.expectEqual(@as(usize, 3), encoded.len);
    try testing.expectEqual(@as(u8, 0x11), encoded[0]); // Odd extension prefix with first nibble
}

test "encode_path - even nibbles leaf" {
    const allocator = testing.allocator;

    const nibbles = [_]u8{ 0, 1, 2, 3 };
    const encoded = try encode_path(allocator, &nibbles, true);
    defer allocator.free(encoded);

    // Even number of nibbles, leaf node: [0x20, 0x01, 0x23]
    try testing.expectEqual(@as(usize, 3), encoded.len);
    try testing.expectEqual(@as(u8, 0x20), encoded[0]); // Even leaf prefix
}

test "encode_path - odd nibbles leaf" {
    const allocator = testing.allocator;

    const nibbles = [_]u8{ 1, 2, 3, 4, 5 };
    const encoded = try encode_path(allocator, &nibbles, true);
    defer allocator.free(encoded);

    // Odd number of nibbles, leaf node: [0x31, 0x23, 0x45]
    try testing.expectEqual(@as(usize, 3), encoded.len);
    try testing.expectEqual(@as(u8, 0x31), encoded[0]); // Odd leaf prefix with first nibble
}

test "encode_path - empty path extension" {
    const allocator = testing.allocator;

    const nibbles = [_]u8{};
    const encoded = try encode_path(allocator, &nibbles, false);
    defer allocator.free(encoded);

    // Empty path, extension: [0x00]
    try testing.expectEqual(@as(usize, 1), encoded.len);
    try testing.expectEqual(@as(u8, 0x00), encoded[0]);
}

test "encode_path - empty path leaf" {
    const allocator = testing.allocator;

    const nibbles = [_]u8{};
    const encoded = try encode_path(allocator, &nibbles, true);
    defer allocator.free(encoded);

    // Empty path, leaf: [0x20]
    try testing.expectEqual(@as(usize, 1), encoded.len);
    try testing.expectEqual(@as(u8, 0x20), encoded[0]);
}

test "decode_path - round trip even extension" {
    const allocator = testing.allocator;

    const original_nibbles = [_]u8{ 0, 1, 2, 3 };
    const encoded = try encode_path(allocator, &original_nibbles, false);
    defer allocator.free(encoded);

    const decoded = try decode_path(allocator, encoded);
    defer allocator.free(decoded.nibbles);

    try testing.expectEqual(false, decoded.is_leaf);
    try testing.expectEqualSlices(u8, &original_nibbles, decoded.nibbles);
}

test "decode_path - round trip odd leaf" {
    const allocator = testing.allocator;

    const original_nibbles = [_]u8{ 1, 2, 3, 4, 5 };
    const encoded = try encode_path(allocator, &original_nibbles, true);
    defer allocator.free(encoded);

    const decoded = try decode_path(allocator, encoded);
    defer allocator.free(decoded.nibbles);

    try testing.expectEqual(true, decoded.is_leaf);
    try testing.expectEqualSlices(u8, &original_nibbles, decoded.nibbles);
}

test "HashValue - hash calculation for raw data" {
    const allocator = testing.allocator;

    const data = "test_data";
    const data_copy = try allocator.dupe(u8, data);
    const value = HashValue{ .Raw = data_copy };
    defer value.deinit(allocator);

    const hash = try value.hash(allocator);

    // Hash should be 32 bytes and non-zero
    var is_zero = true;
    for (hash) |byte| {
        if (byte != 0) {
            is_zero = false;
            break;
        }
    }
    try testing.expect(!is_zero);
}

test "HashValue - hash calculation for hash value" {
    const allocator = testing.allocator;

    var hash_input: [32]u8 = undefined;
    for (&hash_input, 0..) |*byte, i| {
        byte.* = @intCast(i);
    }

    const value = HashValue{ .Hash = hash_input };

    const hash = try value.hash(allocator);

    // Should return the same hash
    try testing.expectEqualSlices(u8, &hash_input, &hash);
}

test "Node serialization - inline vs hash storage" {
    const allocator = testing.allocator;

    // Test small value (should be inlined as Raw)
    {
        const small_data = "small";
        const small_copy = try allocator.dupe(u8, small_data);
        const path_copy = try allocator.dupe(u8, &[_]u8{ 1, 2 });

        var leaf = try LeafNode.init(allocator, path_copy, HashValue{ .Raw = small_copy });
        defer leaf.deinit(allocator);

        const encoded = try leaf.encode(allocator);
        defer allocator.free(encoded);

        // Small values should be stored inline (< 32 bytes)
        // The encoded form should be relatively small
        try testing.expect(encoded.len < 100);
    }

    // Test large value (would normally be hashed, but we're testing Raw encoding)
    {
        var large_data = try allocator.alloc(u8, 50);
        defer allocator.free(large_data);
        for (large_data, 0..) |*byte, i| {
            byte.* = @intCast(i % 256);
        }

        const large_copy = try allocator.dupe(u8, large_data);
        const path_copy2 = try allocator.dupe(u8, &[_]u8{ 3, 4 });

        var leaf2 = try LeafNode.init(allocator, path_copy2, HashValue{ .Raw = large_copy });
        defer leaf2.deinit(allocator);

        const encoded2 = try leaf2.encode(allocator);
        defer allocator.free(encoded2);

        // Large values encoded as Raw should be present in full
        try testing.expect(encoded2.len > 50);
    }

    // Test hash storage (32 bytes)
    {
        var hash: [32]u8 = undefined;
        for (&hash, 0..) |*byte, i| {
            byte.* = @intCast((i * 13) % 256);
        }

        const path_copy3 = try allocator.dupe(u8, &[_]u8{ 5, 6 });

        var leaf3 = try LeafNode.init(allocator, path_copy3, HashValue{ .Hash = hash });
        defer leaf3.deinit(allocator);

        const encoded3 = try leaf3.encode(allocator);
        defer allocator.free(encoded3);

        // Hash values should result in compact encoding
        try testing.expect(encoded3.len > 0);
    }
}
