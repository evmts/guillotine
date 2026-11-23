const std = @import("std");
const micro = @import("micro");
const trie = @import("trie");

fn benchMerkleTrieInsert100(allocator: std.mem.Allocator) !u64 {
    var mt = trie.MerkleTrie.init(allocator);
    defer mt.deinit();
    var key: [4]u8 = undefined;
    var val: [32]u8 = undefined;
    for (0..100) |i| {
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        @memset(&val, @truncate(i));
        try mt.put(&key, &val);
    }
    const root = mt.root_hash() orelse return error.MissingRoot;
    return std.mem.readInt(u64, root[0..8], .big);
}

fn benchMerkleTrieLookup100(allocator: std.mem.Allocator) !u64 {
    var mt = trie.MerkleTrie.init(allocator);
    defer mt.deinit();
    var key: [4]u8 = undefined;
    var val: [32]u8 = undefined;
    for (0..100) |i| {
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        @memset(&val, @truncate(i));
        try mt.put(&key, &val);
    }
    var acc: u64 = 0;
    for (0..100) |i| {
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        const got = (try mt.get(&key)) orelse return error.MissingKey;
        acc +%= got[0] + got.len;
    }
    return acc;
}

fn benchMerkleTrieUpdateDelete100(allocator: std.mem.Allocator) !u64 {
    var mt = trie.MerkleTrie.init(allocator);
    defer mt.deinit();
    var key: [4]u8 = undefined;
    var val: [32]u8 = undefined;
    for (0..100) |i| {
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        @memset(&val, @truncate(i));
        try mt.put(&key, &val);
    }
    for (0..50) |i| {
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        @memset(&val, @truncate(i +% 99));
        try mt.put(&key, &val);
    }
    for (50..75) |i| {
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        try mt.delete(&key);
    }
    const root = mt.root_hash() orelse return error.MissingRoot;
    return std.mem.readInt(u64, root[0..8], .big);
}

fn benchNodeCacheOps(allocator: std.mem.Allocator) !u64 {
    var cache = trie.NodeCache.init(allocator);
    defer cache.deinit();
    var key_buf: [16]u8 = undefined;
    var hash = [_]u8{0} ** 32;
    for (0..256) |i| {
        const k = try std.fmt.bufPrint(&key_buf, "node-{x:0>8}", .{i});
        hash[0] = @truncate(i);
        try cache.cache_hash(k, hash);
    }
    var acc: u64 = 0;
    for (0..256) |i| {
        const k = try std.fmt.bufPrint(&key_buf, "node-{x:0>8}", .{i});
        if (cache.get_cached_hash(k)) |h| acc +%= h[0];
    }
    return acc;
}

fn benchKeyToNibbles(allocator: std.mem.Allocator) !u64 {
    var key: [32]u8 = undefined;
    for (&key, 0..) |*b, i| b.* = @truncate(i *% 19);
    var acc: u64 = 0;
    for (0..512) |i| {
        key[0] = @truncate(i);
        const nibbles = try trie.key_to_nibbles(allocator, &key);
        defer allocator.free(nibbles);
        acc +%= nibbles[0] + nibbles[nibbles.len - 1];
    }
    return acc;
}

pub fn main() void {
    micro.runSuite("trie", &.{
        .{ .name = "trie/merkle-insert-100", .operations = 100, .run = benchMerkleTrieInsert100 },
        .{ .name = "trie/merkle-lookup-100", .operations = 100, .run = benchMerkleTrieLookup100 },
        .{ .name = "trie/merkle-update-delete-100", .operations = 175, .run = benchMerkleTrieUpdateDelete100 },
        .{ .name = "trie/node-cache-256", .operations = 512, .run = benchNodeCacheOps },
        .{ .name = "trie/key-to-nibbles-512", .operations = 512, .bytes = 512 * 32, .run = benchKeyToNibbles },
    });
}
