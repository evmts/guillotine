const std = @import("std");
const testing = std.testing;
const trie = @import("trie.zig");
const hash_builder = @import("hash_builder_complete.zig");
const merkle_trie = @import("merkle_trie.zig");

const HashBuilder = hash_builder.HashBuilder;
const MerkleTrie = merkle_trie.MerkleTrie;
const TrieNode = trie.TrieNode;
const HashValue = trie.HashValue;
const BranchNode = trie.BranchNode;
const LeafNode = trie.LeafNode;
const ExtensionNode = trie.ExtensionNode;

// MEMORY LEAK DETECTION TESTS
// Using std.testing.allocator which detects leaks

test "Memory: single insert and delete - no leaks" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");
    try builder.delete(&[_]u8{ 1, 2, 3 });
}

test "Memory: multiple inserts and deletes - no leaks" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert multiple keys
    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");
    try builder.insert(&[_]u8{ 1, 2, 4 }, "value2");
    try builder.insert(&[_]u8{ 1, 3, 5 }, "value3");
    try builder.insert(&[_]u8{ 2, 3, 4 }, "value4");

    // Delete all
    try builder.delete(&[_]u8{ 1, 2, 3 });
    try builder.delete(&[_]u8{ 1, 2, 4 });
    try builder.delete(&[_]u8{ 1, 3, 5 });
    try builder.delete(&[_]u8{ 2, 3, 4 });
}

test "Memory: insert with common prefixes - no leaks" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    try builder.insert(&[_]u8{ 1, 2, 3, 4 }, "value1");
    try builder.insert(&[_]u8{ 1, 2, 3, 5 }, "value2");
    try builder.insert(&[_]u8{ 1, 2, 4, 5 }, "value3");

    try builder.delete(&[_]u8{ 1, 2, 3, 4 });
    try builder.delete(&[_]u8{ 1, 2, 3, 5 });
    try builder.delete(&[_]u8{ 1, 2, 4, 5 });
}

test "Memory: update existing key - no leaks" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");
    try builder.insert(&[_]u8{ 1, 2, 3 }, "updated_value");
    try builder.delete(&[_]u8{ 1, 2, 3 });
}

test "Memory: reset builder - no leaks" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");
    try builder.insert(&[_]u8{ 4, 5, 6 }, "value2");

    builder.reset();

    try builder.insert(&[_]u8{ 7, 8, 9 }, "value3");
    builder.reset();
}

test "Memory: get operations - no leaks" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");

    // Multiple get operations
    _ = try builder.get(&[_]u8{ 1, 2, 3 });
    _ = try builder.get(&[_]u8{ 1, 2, 4 });
    _ = try builder.get(&[_]u8{ 5, 6, 7 });

    try builder.delete(&[_]u8{ 1, 2, 3 });
}

test "Memory: BranchNode dupe and deinit" {
    const allocator = testing.allocator;

    var branch = BranchNode.init();
    defer branch.deinit(allocator);

    const data1 = "value1";
    const data1_copy = try allocator.dupe(u8, data1);
    branch.children[1] = HashValue{ .Raw = data1_copy };
    branch.children_mask.set(1);

    // Duplicate the branch
    var branch_copy = try branch.dupe(allocator);
    defer branch_copy.deinit(allocator);

    try testing.expect(branch_copy.children_mask.is_set(1));
}

test "Memory: LeafNode creation and destruction" {
    const allocator = testing.allocator;

    const path = [_]u8{ 1, 2, 3, 4 };
    const value = "test_value";
    const value_copy = try allocator.dupe(u8, value);
    const path_copy = try allocator.dupe(u8, &path);

    var leaf = try LeafNode.init(allocator, path_copy, HashValue{ .Raw = value_copy });
    defer leaf.deinit(allocator);

    try testing.expectEqualSlices(u8, &path, leaf.nibbles);
}

test "Memory: ExtensionNode creation and destruction" {
    const allocator = testing.allocator;

    const path = [_]u8{ 1, 2, 3, 4 };
    const value = "next_node";
    const value_copy = try allocator.dupe(u8, value);
    const path_copy = try allocator.dupe(u8, &path);

    var extension = try ExtensionNode.init(allocator, path_copy, HashValue{ .Raw = value_copy });
    defer extension.deinit(allocator);

    try testing.expectEqualSlices(u8, &path, extension.nibbles);
}

test "Memory: HashValue dupe and deinit" {
    const allocator = testing.allocator;

    const data = "test_data";
    const data_copy = try allocator.dupe(u8, data);
    var value = HashValue{ .Raw = data_copy };
    defer value.deinit(allocator);

    var value_dup = try value.dupe(allocator);
    defer value_dup.deinit(allocator);
}

test "Memory: TrieNode encode and hash" {
    const allocator = testing.allocator;

    const path = [_]u8{ 1, 2, 3, 4 };
    const value = "test_value";
    const value_copy = try allocator.dupe(u8, value);
    const path_copy = try allocator.dupe(u8, &path);

    const leaf = try LeafNode.init(allocator, path_copy, HashValue{ .Raw = value_copy });
    var node = TrieNode{ .Leaf = leaf };
    defer node.deinit(allocator);

    const encoded = try node.encode(allocator);
    defer allocator.free(encoded);

    _ = try node.hash(allocator);
}

test "Memory: MerkleTrie basic operations - no leaks" {
    const allocator = testing.allocator;

    var trie_instance = MerkleTrie.init(allocator);
    defer trie_instance.deinit();

    try trie_instance.put(&[_]u8{ 1, 2, 3 }, "value1");

    const value = try trie_instance.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(value != null);

    try trie_instance.delete(&[_]u8{ 1, 2, 3 });
}

test "Memory: MerkleTrie multiple operations - no leaks" {
    const allocator = testing.allocator;

    var trie_instance = MerkleTrie.init(allocator);
    defer trie_instance.deinit();

    try trie_instance.put(&[_]u8{ 1, 2, 3 }, "value1");
    try trie_instance.put(&[_]u8{ 1, 2, 4 }, "value2");
    try trie_instance.put(&[_]u8{ 1, 3, 5 }, "value3");
    try trie_instance.put(&[_]u8{ 2, 3, 4 }, "value4");

    _ = try trie_instance.get(&[_]u8{ 1, 2, 3 });
    _ = try trie_instance.get(&[_]u8{ 1, 2, 4 });

    try trie_instance.delete(&[_]u8{ 1, 2, 3 });
    try trie_instance.delete(&[_]u8{ 1, 3, 5 });

    trie_instance.clear();
}

test "Memory: MerkleTrie clear - no leaks" {
    const allocator = testing.allocator;

    var trie_instance = MerkleTrie.init(allocator);
    defer trie_instance.deinit();

    try trie_instance.put(&[_]u8{ 1, 2, 3 }, "value1");
    try trie_instance.put(&[_]u8{ 4, 5, 6 }, "value2");

    trie_instance.clear();
}

test "Memory: large trie cleanup - no leaks" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert many keys
    var i: u8 = 0;
    while (i < 50) : (i += 1) {
        const key = [_]u8{ i, i +% 1, i +% 2 };
        try builder.insert(&key, "value");
    }

    // Delete half of them
    i = 0;
    while (i < 25) : (i += 1) {
        const key = [_]u8{ i, i +% 1, i +% 2 };
        try builder.delete(&key);
    }

    // Reset to clean up the rest
    builder.reset();
}

test "Memory: delete non-existent key - no leaks" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");

    // Try to delete a non-existent key
    try builder.delete(&[_]u8{ 4, 5, 6 });

    try builder.delete(&[_]u8{ 1, 2, 3 });
}

test "Memory: key_to_nibbles and nibbles_to_key - no leaks" {
    const allocator = testing.allocator;

    const key = [_]u8{ 0x12, 0x34, 0xAB, 0xCD };
    const nibbles = try trie.key_to_nibbles(allocator, &key);
    defer allocator.free(nibbles);

    const round_trip = try trie.nibbles_to_key(allocator, nibbles);
    defer allocator.free(round_trip);

    try testing.expectEqualSlices(u8, &key, round_trip);
}

test "Memory: encode_path and decode_path - no leaks" {
    const allocator = testing.allocator;

    const nibbles = [_]u8{ 1, 2, 3, 4 };
    const encoded = try trie.encode_path(allocator, &nibbles, false);
    defer allocator.free(encoded);

    const decoded = try trie.decode_path(allocator, encoded);
    defer allocator.free(decoded.nibbles);

    try testing.expectEqualSlices(u8, &nibbles, decoded.nibbles);
}

// ERROR PATH TESTS

test "Memory: error on invalid key decode - no leaks" {
    const allocator = testing.allocator;

    // Empty path is invalid
    const result = trie.decode_path(allocator, &[_]u8{});
    try testing.expectError(trie.TrieError.InvalidPath, result);
}

test "Memory: error on invalid nibble count - no leaks" {
    const allocator = testing.allocator;

    // Odd number of nibbles can't convert to key
    const nibbles = [_]u8{ 1, 2, 3 };
    const result = trie.nibbles_to_key(allocator, &nibbles);
    try testing.expectError(trie.TrieError.InvalidKey, result);
}
