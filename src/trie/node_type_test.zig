const std = @import("std");
const trie = @import("trie.zig");
const hash_builder = @import("hash_builder_complete.zig");

const TrieNode = trie.TrieNode;
const BranchNode = trie.BranchNode;
const ExtensionNode = trie.ExtensionNode;
const LeafNode = trie.LeafNode;
const HashValue = trie.HashValue;
const HashBuilder = hash_builder.HashBuilder;

// Test 1: Empty node operations
test "Empty node - insert creates leaf" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert into empty trie should create a leaf node
    try builder.insert(&[_]u8{ 1, 2, 3 }, "value");

    // Verify the value exists
    const value = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(value != null);
    try testing.expectEqualStrings("value", value.?);
}

// Test 2: Empty node - get returns null
test "Empty node - get returns null" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Get from empty trie should return null
    const value = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(value == null);
}

// Test 3: Empty node - delete is no-op
test "Empty node - delete is no-op" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Delete from empty trie should not error
    try builder.delete(&[_]u8{ 1, 2, 3 });

    // Trie should still be empty
    try testing.expect(builder.root_hash == null);
}

// Test 4: Leaf node - exact match lookup
test "Leaf node - exact match lookup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    try builder.insert(&[_]u8{ 1, 2, 3, 4 }, "test_value");

    const value = try builder.get(&[_]u8{ 1, 2, 3, 4 });
    try testing.expect(value != null);
    try testing.expectEqualStrings("test_value", value.?);
}

// Test 5: Leaf node - partial match returns null
test "Leaf node - partial match returns null" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    try builder.insert(&[_]u8{ 1, 2, 3, 4 }, "test_value");

    // Lookup with shorter path should return null
    const value = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(value == null);
}

// Test 6: Leaf node - update value
test "Leaf node - update value" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");
    try builder.insert(&[_]u8{ 1, 2, 3 }, "value2");

    const value = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(value != null);
    try testing.expectEqualStrings("value2", value.?);
}

// Test 7: Leaf node - delete
test "Leaf node - delete" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    try builder.insert(&[_]u8{ 1, 2, 3 }, "value");
    try builder.delete(&[_]u8{ 1, 2, 3 });

    const value = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(value == null);
    try testing.expect(builder.root_hash == null);
}

// Test 8: Branch node - multiple children
test "Branch node - multiple children" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert keys that will create a branch node
    try builder.insert(&[_]u8{ 0x10 }, "value0");
    try builder.insert(&[_]u8{ 0x20 }, "value1");
    try builder.insert(&[_]u8{ 0x30 }, "value2");

    // All values should be retrievable
    const value0 = try builder.get(&[_]u8{ 0x10 });
    try testing.expectEqualStrings("value0", value0.?);

    const value1 = try builder.get(&[_]u8{ 0x20 });
    try testing.expectEqualStrings("value1", value1.?);

    const value2 = try builder.get(&[_]u8{ 0x30 });
    try testing.expectEqualStrings("value2", value2.?);
}

// Test 9: Branch node - with value at branch
test "Branch node - with value at branch" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Create a branch node
    try builder.insert(&[_]u8{ 1, 2, 3, 4 }, "child_value");
    try builder.insert(&[_]u8{ 1, 2, 3, 5 }, "other_child");

    // Insert value at the branch point
    try builder.insert(&[_]u8{ 1, 2, 3 }, "branch_value");

    // All values should be retrievable
    const branch_val = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expectEqualStrings("branch_value", branch_val.?);

    const child_val = try builder.get(&[_]u8{ 1, 2, 3, 4 });
    try testing.expectEqualStrings("child_value", child_val.?);
}

// Test 10: Branch node - delete one child
test "Branch node - delete one child" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    try builder.insert(&[_]u8{ 0x10 }, "value0");
    try builder.insert(&[_]u8{ 0x20 }, "value1");
    try builder.insert(&[_]u8{ 0x30 }, "value2");

    // Delete one child
    try builder.delete(&[_]u8{ 0x20 });

    // Other children should still exist
    const value0 = try builder.get(&[_]u8{ 0x10 });
    try testing.expectEqualStrings("value0", value0.?);

    const value2 = try builder.get(&[_]u8{ 0x30 });
    try testing.expectEqualStrings("value2", value2.?);

    // Deleted child should not exist
    const deleted = try builder.get(&[_]u8{ 0x20 });
    try testing.expect(deleted == null);
}

// Test 11: Extension node - common prefix
test "Extension node - common prefix" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert keys with long common prefix
    try builder.insert(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, "value1");
    try builder.insert(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 10 }, "value2");

    // Both values should be retrievable
    const value1 = try builder.get(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9 });
    try testing.expectEqualStrings("value1", value1.?);

    const value2 = try builder.get(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 10 });
    try testing.expectEqualStrings("value2", value2.?);
}

// Test 12: Extension node - lookup through extension
test "Extension node - lookup through extension" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Create extension node scenario
    try builder.insert(&[_]u8{ 0xAA, 0xBB, 0xCC, 0x01 }, "value1");
    try builder.insert(&[_]u8{ 0xAA, 0xBB, 0xCC, 0x02 }, "value2");

    // Lookups should traverse extension correctly
    const value1 = try builder.get(&[_]u8{ 0xAA, 0xBB, 0xCC, 0x01 });
    try testing.expectEqualStrings("value1", value1.?);
}

// Test 13: Extension node - partial prefix returns null
test "Extension node - partial prefix returns null" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    try builder.insert(&[_]u8{ 1, 2, 3, 4, 5 }, "value");

    // Lookup with partial prefix should return null
    const value = try builder.get(&[_]u8{ 1, 2 });
    try testing.expect(value == null);
}

// Test 14: Leaf to Branch conversion
test "Node conversion - leaf to branch" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Start with a leaf
    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");

    // Insert diverging key - should convert to branch
    try builder.insert(&[_]u8{ 1, 2, 4 }, "value2");

    // Both values should exist
    const value1 = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expectEqualStrings("value1", value1.?);

    const value2 = try builder.get(&[_]u8{ 1, 2, 4 });
    try testing.expectEqualStrings("value2", value2.?);
}

// Test 15: Leaf to Extension+Branch conversion
test "Node conversion - leaf to extension plus branch" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Start with a leaf with long path
    try builder.insert(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }, "value1");

    // Insert key with partial match - should create extension + branch
    try builder.insert(&[_]u8{ 1, 2, 3, 4, 9, 10, 11, 12 }, "value2");

    // Both values should exist
    const value1 = try builder.get(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try testing.expectEqualStrings("value1", value1.?);

    const value2 = try builder.get(&[_]u8{ 1, 2, 3, 4, 9, 10, 11, 12 });
    try testing.expectEqualStrings("value2", value2.?);
}

// Test 16: Branch to Extension conversion on delete
test "Node conversion - branch to extension on delete" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Create a branch with multiple children
    try builder.insert(&[_]u8{ 1, 2, 3, 4 }, "value1");
    try builder.insert(&[_]u8{ 1, 2, 3, 5 }, "value2");
    try builder.insert(&[_]u8{ 1, 2, 3, 6 }, "value3");

    // Delete two children leaving only one
    try builder.delete(&[_]u8{ 1, 2, 3, 5 });
    try builder.delete(&[_]u8{ 1, 2, 3, 6 });

    // Remaining value should still be accessible
    const value1 = try builder.get(&[_]u8{ 1, 2, 3, 4 });
    try testing.expectEqualStrings("value1", value1.?);

    // Deleted values should not exist
    const deleted1 = try builder.get(&[_]u8{ 1, 2, 3, 5 });
    try testing.expect(deleted1 == null);
}

// Test 17: Branch to Leaf conversion on delete
test "Node conversion - branch to leaf on delete" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Create a branch
    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");
    try builder.insert(&[_]u8{ 1, 2, 4 }, "value2");

    // Delete one value
    try builder.delete(&[_]u8{ 1, 2, 4 });

    // Remaining value should still be accessible
    const value1 = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expectEqualStrings("value1", value1.?);
}

// Test 18: Extension split on insert
test "Extension node - split on diverging insert" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Create extension node
    try builder.insert(&[_]u8{ 1, 2, 3, 4, 5, 6, 7 }, "value1");
    try builder.insert(&[_]u8{ 1, 2, 3, 4, 5, 6, 8 }, "value2");

    // Insert key that diverges in the middle of extension
    try builder.insert(&[_]u8{ 1, 2, 3, 9, 10, 11, 12 }, "value3");

    // All values should be retrievable
    const value1 = try builder.get(&[_]u8{ 1, 2, 3, 4, 5, 6, 7 });
    try testing.expectEqualStrings("value1", value1.?);

    const value2 = try builder.get(&[_]u8{ 1, 2, 3, 4, 5, 6, 8 });
    try testing.expectEqualStrings("value2", value2.?);

    const value3 = try builder.get(&[_]u8{ 1, 2, 3, 9, 10, 11, 12 });
    try testing.expectEqualStrings("value3", value3.?);
}

// Test 19: Complex mixed operations
test "Complex operations - mixed insert/update/delete" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Build complex tree
    try builder.insert(&[_]u8{ 0x00, 0x00 }, "a");
    try builder.insert(&[_]u8{ 0x00, 0x01 }, "b");
    try builder.insert(&[_]u8{ 0x01, 0x00 }, "c");
    try builder.insert(&[_]u8{ 0x01, 0x01 }, "d");
    try builder.insert(&[_]u8{ 0xFF, 0xFF }, "e");

    // Update some values
    try builder.insert(&[_]u8{ 0x00, 0x00 }, "a_updated");

    // Delete some values
    try builder.delete(&[_]u8{ 0x01, 0x00 });

    // Verify final state
    const val_a = try builder.get(&[_]u8{ 0x00, 0x00 });
    try testing.expectEqualStrings("a_updated", val_a.?);

    const val_b = try builder.get(&[_]u8{ 0x00, 0x01 });
    try testing.expectEqualStrings("b", val_b.?);

    const val_c = try builder.get(&[_]u8{ 0x01, 0x00 });
    try testing.expect(val_c == null);

    const val_d = try builder.get(&[_]u8{ 0x01, 0x01 });
    try testing.expectEqualStrings("d", val_d.?);

    const val_e = try builder.get(&[_]u8{ 0xFF, 0xFF });
    try testing.expectEqualStrings("e", val_e.?);
}

// Test 20: Empty key handling
test "Edge case - empty key" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert with empty key
    try builder.insert(&[_]u8{}, "root_value");

    // Should be retrievable
    const value = try builder.get(&[_]u8{});
    try testing.expect(value != null);
    try testing.expectEqualStrings("root_value", value.?);
}

// Test 21: Single nibble paths
test "Edge case - single nibble paths" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert values with single byte keys (2 nibbles)
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        const key = [_]u8{i};
        try builder.insert(&key, "value");
    }

    // All should be retrievable
    i = 0;
    while (i < 16) : (i += 1) {
        const key = [_]u8{i};
        const value = try builder.get(&key);
        try testing.expect(value != null);
    }
}

// Test 22: Large values
test "Edge case - large values" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Create a large value (> 32 bytes)
    var large_value: [100]u8 = undefined;
    for (&large_value, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    try builder.insert(&[_]u8{ 1, 2, 3 }, &large_value);

    const retrieved = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(retrieved != null);
    try testing.expectEqualSlices(u8, &large_value, retrieved.?);
}

// Test 23: Deep tree structure
test "Edge case - deep tree structure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Create a very deep path (32 bytes = 64 nibbles)
    var deep_key: [32]u8 = undefined;
    for (&deep_key, 0..) |*byte, i| {
        byte.* = @intCast(i);
    }

    try builder.insert(&deep_key, "deep_value");

    const value = try builder.get(&deep_key);
    try testing.expect(value != null);
    try testing.expectEqualStrings("deep_value", value.?);
}

// Test 24: All node types in one tree
test "Integration - all node types present" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Create a tree that will have all node types:
    // - Empty (initially)
    // - Leaf (first insert)
    // - Branch (diverging inserts)
    // - Extension (long common prefix)

    // Start empty - check
    try testing.expect(builder.root_hash == null);

    // Insert first value - creates leaf
    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");
    try testing.expect(builder.root_hash != null);

    // Insert diverging value - creates branch
    try builder.insert(&[_]u8{ 1, 2, 4 }, "value2");

    // Insert values with long common prefix - creates extension
    try builder.insert(&[_]u8{ 5, 5, 5, 5, 5, 5, 5, 1 }, "ext_value1");
    try builder.insert(&[_]u8{ 5, 5, 5, 5, 5, 5, 5, 2 }, "ext_value2");

    // Verify all values
    try testing.expectEqualStrings("value1", (try builder.get(&[_]u8{ 1, 2, 3 })).?);
    try testing.expectEqualStrings("value2", (try builder.get(&[_]u8{ 1, 2, 4 })).?);
    try testing.expectEqualStrings("ext_value1", (try builder.get(&[_]u8{ 5, 5, 5, 5, 5, 5, 5, 1 })).?);
    try testing.expectEqualStrings("ext_value2", (try builder.get(&[_]u8{ 5, 5, 5, 5, 5, 5, 5, 2 })).?);
}

// Test 25: Node encoding/decoding consistency
test "Node encoding - all types encode correctly" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test Branch node encoding
    {
        var branch = BranchNode.init();
        defer branch.deinit(allocator);

        branch.children[0] = HashValue{ .Raw = try allocator.dupe(u8, "child0") };
        branch.children_mask.set(0);
        branch.children[15] = HashValue{ .Raw = try allocator.dupe(u8, "child15") };
        branch.children_mask.set(15);
        branch.value = HashValue{ .Raw = try allocator.dupe(u8, "branch_value") };

        const encoded = try branch.encode(allocator);
        defer allocator.free(encoded);

        // Encoded data should be non-empty
        try testing.expect(encoded.len > 0);
    }

    // Test Extension node encoding
    {
        const path = try allocator.dupe(u8, &[_]u8{ 1, 2, 3, 4 });
        const next_val = HashValue{ .Raw = try allocator.dupe(u8, "next") };
        var extension = try ExtensionNode.init(allocator, path, next_val);
        defer extension.deinit(allocator);

        const encoded = try extension.encode(allocator);
        defer allocator.free(encoded);

        try testing.expect(encoded.len > 0);
    }

    // Test Leaf node encoding
    {
        const path = try allocator.dupe(u8, &[_]u8{ 5, 6, 7 });
        const value = HashValue{ .Raw = try allocator.dupe(u8, "leaf_value") };
        var leaf = try LeafNode.init(allocator, path, value);
        defer leaf.deinit(allocator);

        const encoded = try leaf.encode(allocator);
        defer allocator.free(encoded);

        try testing.expect(encoded.len > 0);
    }
}
