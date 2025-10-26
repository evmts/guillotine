const std = @import("std");
const hash_builder = @import("hash_builder_complete.zig");

const HashBuilder = hash_builder.HashBuilder;
const testing = std.testing;

test "TrieIterator - empty trie" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    var iter = try builder.iterator(allocator);
    defer iter.deinit();

    const result = try iter.next();
    try testing.expect(result == null);
}

test "TrieIterator - single key" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");

    var iter = try builder.iterator(allocator);
    defer iter.deinit();

    const result1 = try iter.next();
    try testing.expect(result1 != null);
    defer allocator.free(result1.?.key);
    defer allocator.free(result1.?.value);

    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, result1.?.key);
    try testing.expectEqualStrings("value1", result1.?.value);

    const result2 = try iter.next();
    try testing.expect(result2 == null);
}

test "TrieIterator - multiple keys sorted order" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert in non-sorted order
    try builder.insert(&[_]u8{ 2, 0, 0 }, "value3");
    try builder.insert(&[_]u8{ 1, 0, 0 }, "value1");
    try builder.insert(&[_]u8{ 1, 5, 0 }, "value2");
    try builder.insert(&[_]u8{ 3, 0, 0 }, "value4");

    var iter = try builder.iterator(allocator);
    defer iter.deinit();

    // Should come out in sorted order
    const result1 = try iter.next();
    try testing.expect(result1 != null);
    defer allocator.free(result1.?.key);
    defer allocator.free(result1.?.value);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 0, 0 }, result1.?.key);
    try testing.expectEqualStrings("value1", result1.?.value);

    const result2 = try iter.next();
    try testing.expect(result2 != null);
    defer allocator.free(result2.?.key);
    defer allocator.free(result2.?.value);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 5, 0 }, result2.?.key);
    try testing.expectEqualStrings("value2", result2.?.value);

    const result3 = try iter.next();
    try testing.expect(result3 != null);
    defer allocator.free(result3.?.key);
    defer allocator.free(result3.?.value);
    try testing.expectEqualSlices(u8, &[_]u8{ 2, 0, 0 }, result3.?.key);
    try testing.expectEqualStrings("value3", result3.?.value);

    const result4 = try iter.next();
    try testing.expect(result4 != null);
    defer allocator.free(result4.?.key);
    defer allocator.free(result4.?.value);
    try testing.expectEqualSlices(u8, &[_]u8{ 3, 0, 0 }, result4.?.key);
    try testing.expectEqualStrings("value4", result4.?.value);

    const result5 = try iter.next();
    try testing.expect(result5 == null);
}

test "TrieIterator - all keys visited exactly once" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert 10 keys
    try builder.insert(&[_]u8{ 0, 1 }, "v0");
    try builder.insert(&[_]u8{ 0, 2 }, "v1");
    try builder.insert(&[_]u8{ 0, 3 }, "v2");
    try builder.insert(&[_]u8{ 1, 1 }, "v3");
    try builder.insert(&[_]u8{ 1, 2 }, "v4");
    try builder.insert(&[_]u8{ 2, 1 }, "v5");
    try builder.insert(&[_]u8{ 2, 2 }, "v6");
    try builder.insert(&[_]u8{ 3, 1 }, "v7");
    try builder.insert(&[_]u8{ 4, 1 }, "v8");
    try builder.insert(&[_]u8{ 5, 1 }, "v9");

    var iter = try builder.iterator(allocator);
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |result| {
        defer allocator.free(result.key);
        defer allocator.free(result.value);
        count += 1;
    }

    try testing.expectEqual(@as(usize, 10), count);
}

test "TrieIterator - common prefix keys" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Keys with common prefixes
    try builder.insert(&[_]u8{ 0xAB, 0xCD }, "val1");
    try builder.insert(&[_]u8{ 0xAB, 0xCE }, "val2");
    try builder.insert(&[_]u8{ 0xAB, 0xCF }, "val3");

    var iter = try builder.iterator(allocator);
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |result| {
        defer allocator.free(result.key);
        defer allocator.free(result.value);
        count += 1;

        // All keys should start with 0xAB
        try testing.expectEqual(@as(u8, 0xAB), result.key[0]);
    }

    try testing.expectEqual(@as(usize, 3), count);
}

test "TrieIterator - deep tree structure" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Create deep paths
    try builder.insert(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }, "deep1");
    try builder.insert(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 9 }, "deep2");
    try builder.insert(&[_]u8{ 1, 2 }, "shallow");

    var iter = try builder.iterator(allocator);
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |result| {
        defer allocator.free(result.key);
        defer allocator.free(result.value);
        count += 1;
    }

    try testing.expectEqual(@as(usize, 3), count);
}

test "TrieIterator - single branch traversal" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Create single branch (linear chain)
    try builder.insert(&[_]u8{0}, "v0");
    try builder.insert(&[_]u8{1}, "v1");
    try builder.insert(&[_]u8{2}, "v2");

    var iter = try builder.iterator(allocator);
    defer iter.deinit();

    var count: usize = 0;
    var last_key: u8 = 0;
    while (try iter.next()) |result| {
        defer allocator.free(result.key);
        defer allocator.free(result.value);

        // Keys should be in order
        try testing.expectEqual(@as(usize, 1), result.key.len);
        try testing.expect(result.key[0] >= last_key);
        last_key = result.key[0];
        count += 1;
    }

    try testing.expectEqual(@as(usize, 3), count);
}

test "TrieIterator - lexicographic ordering" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert keys that should be sorted lexicographically
    try builder.insert(&[_]u8{0xFF}, "last");
    try builder.insert(&[_]u8{0x00}, "first");
    try builder.insert(&[_]u8{0x80}, "middle");

    var iter = try builder.iterator(allocator);
    defer iter.deinit();

    const result1 = try iter.next();
    try testing.expect(result1 != null);
    defer allocator.free(result1.?.key);
    defer allocator.free(result1.?.value);
    try testing.expectEqual(@as(u8, 0x00), result1.?.key[0]);

    const result2 = try iter.next();
    try testing.expect(result2 != null);
    defer allocator.free(result2.?.key);
    defer allocator.free(result2.?.value);
    try testing.expectEqual(@as(u8, 0x80), result2.?.key[0]);

    const result3 = try iter.next();
    try testing.expect(result3 != null);
    defer allocator.free(result3.?.key);
    defer allocator.free(result3.?.value);
    try testing.expectEqual(@as(u8, 0xFF), result3.?.key[0]);
}

test "TrieIterator - branch with value" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert keys where a branch node itself has a value
    try builder.insert(&[_]u8{0xAB}, "branch_value");
    try builder.insert(&[_]u8{ 0xAB, 0x01 }, "child1");
    try builder.insert(&[_]u8{ 0xAB, 0x02 }, "child2");

    var iter = try builder.iterator(allocator);
    defer iter.deinit();

    var count: usize = 0;
    var found_branch_value = false;

    while (try iter.next()) |result| {
        defer allocator.free(result.key);
        defer allocator.free(result.value);

        if (result.key.len == 1 and result.key[0] == 0xAB) {
            found_branch_value = true;
            try testing.expectEqualStrings("branch_value", result.value);
        }
        count += 1;
    }

    try testing.expectEqual(@as(usize, 3), count);
    try testing.expect(found_branch_value);
}

test "TrieIterator - wide branch" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Create a branch with many children
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        try builder.insert(&[_]u8{i}, "value");
    }

    var iter = try builder.iterator(allocator);
    defer iter.deinit();

    var count: usize = 0;
    var last_key: u8 = 0;
    while (try iter.next()) |result| {
        defer allocator.free(result.key);
        defer allocator.free(result.value);

        try testing.expect(result.key[0] >= last_key);
        last_key = result.key[0];
        count += 1;
    }

    try testing.expectEqual(@as(usize, 16), count);
}

test "TrieIterator - after delete operations" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert and delete some keys
    try builder.insert(&[_]u8{ 1, 0 }, "v1");
    try builder.insert(&[_]u8{ 2, 0 }, "v2");
    try builder.insert(&[_]u8{ 3, 0 }, "v3");
    try builder.insert(&[_]u8{ 4, 0 }, "v4");

    try builder.delete(&[_]u8{ 2, 0 });
    try builder.delete(&[_]u8{ 4, 0 });

    var iter = try builder.iterator(allocator);
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |result| {
        defer allocator.free(result.key);
        defer allocator.free(result.value);

        // Should not see deleted keys
        try testing.expect(!(result.key.len == 2 and result.key[0] == 2 and result.key[1] == 0));
        try testing.expect(!(result.key.len == 2 and result.key[0] == 4 and result.key[1] == 0));
        count += 1;
    }

    try testing.expectEqual(@as(usize, 2), count);
}

test "TrieIterator - mixed key lengths" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Different length keys
    try builder.insert(&[_]u8{1}, "short1");
    try builder.insert(&[_]u8{ 1, 2 }, "medium1");
    try builder.insert(&[_]u8{ 1, 2, 3 }, "long1");
    try builder.insert(&[_]u8{ 1, 2, 3, 4 }, "longer1");
    try builder.insert(&[_]u8{2}, "short2");

    var iter = try builder.iterator(allocator);
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |result| {
        defer allocator.free(result.key);
        defer allocator.free(result.value);
        count += 1;
    }

    try testing.expectEqual(@as(usize, 5), count);
}

test "TrieIterator - repeated iteration" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    try builder.insert(&[_]u8{ 1, 2 }, "v1");
    try builder.insert(&[_]u8{ 3, 4 }, "v2");

    // First iteration
    {
        var iter = try builder.iterator(allocator);
        defer iter.deinit();

        var count: usize = 0;
        while (try iter.next()) |result| {
            defer allocator.free(result.key);
            defer allocator.free(result.value);
            count += 1;
        }
        try testing.expectEqual(@as(usize, 2), count);
    }

    // Second iteration should work the same
    {
        var iter = try builder.iterator(allocator);
        defer iter.deinit();

        var count: usize = 0;
        while (try iter.next()) |result| {
            defer allocator.free(result.key);
            defer allocator.free(result.value);
            count += 1;
        }
        try testing.expectEqual(@as(usize, 2), count);
    }
}

test "TrieIterator - extension node handling" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Create scenario likely to produce extension nodes
    try builder.insert(&[_]u8{ 0xAB, 0xCD, 0xEF, 0x01 }, "ext1");
    try builder.insert(&[_]u8{ 0xAB, 0xCD, 0xEF, 0x02 }, "ext2");

    var iter = try builder.iterator(allocator);
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |result| {
        defer allocator.free(result.key);
        defer allocator.free(result.value);

        // Verify common prefix
        try testing.expectEqual(@as(u8, 0xAB), result.key[0]);
        try testing.expectEqual(@as(u8, 0xCD), result.key[1]);
        try testing.expectEqual(@as(u8, 0xEF), result.key[2]);
        count += 1;
    }

    try testing.expectEqual(@as(usize, 2), count);
}

test "TrieIterator - value correctness" {
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Insert with distinct values
    try builder.insert(&[_]u8{ 1, 0 }, "first_value");
    try builder.insert(&[_]u8{ 2, 0 }, "second_value");
    try builder.insert(&[_]u8{ 3, 0 }, "third_value");

    var iter = try builder.iterator(allocator);
    defer iter.deinit();

    // Verify each key maps to correct value
    while (try iter.next()) |result| {
        defer allocator.free(result.key);
        defer allocator.free(result.value);

        if (result.key[0] == 1) {
            try testing.expectEqualStrings("first_value", result.value);
        } else if (result.key[0] == 2) {
            try testing.expectEqualStrings("second_value", result.value);
        } else if (result.key[0] == 3) {
            try testing.expectEqualStrings("third_value", result.value);
        }
    }
}
