const std = @import("std");
const Allocator = std.mem.Allocator;

/// Cached hash for a trie node - avoids recomputation
pub const CachedHash = struct {
    hash: [32]u8,
    dirty: bool,

    pub fn init(hash: [32]u8) CachedHash {
        return CachedHash{
            .hash = hash,
            .dirty = false,
        };
    }

    pub fn mark_dirty(self: *CachedHash) void {
        self.dirty = true;
    }

    pub fn is_dirty(self: CachedHash) bool {
        return self.dirty;
    }

    pub fn get_hash(self: CachedHash) ?[32]u8 {
        if (self.dirty) return null;
        return self.hash;
    }

    pub fn update_hash(self: *CachedHash, new_hash: [32]u8) void {
        self.hash = new_hash;
        self.dirty = false;
    }
};

/// Node cache for efficient trie operations
pub const NodeCache = struct {
    allocator: Allocator,
    // Hash string -> cached hash
    hash_cache: std.StringHashMap(CachedHash),
    // Arena for temporary hex conversions to avoid repeated allocations
    hex_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator) NodeCache {
        return NodeCache{
            .allocator = allocator,
            .hash_cache = std.StringHashMap(CachedHash).init(allocator),
            .hex_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *NodeCache) void {
        var it = self.hash_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.hash_cache.deinit();
        self.hex_arena.deinit();
    }

    /// Get cached hash if available and not dirty
    pub fn get_cached_hash(self: *const NodeCache, hash_str: []const u8) ?[32]u8 {
        if (self.hash_cache.get(hash_str)) |cached| {
            return cached.get_hash();
        }
        return null;
    }

    /// Store a hash in the cache
    pub fn cache_hash(self: *NodeCache, hash_str: []const u8, hash: [32]u8) !void {
        // Check if already exists
        if (self.hash_cache.contains(hash_str)) {
            return;
        }

        // Duplicate the key
        const key_copy = try self.allocator.dupe(u8, hash_str);
        errdefer self.allocator.free(key_copy);

        // Store the cached hash
        try self.hash_cache.put(key_copy, CachedHash.init(hash));
    }

    /// Mark a hash as dirty (needs recomputation)
    pub fn mark_dirty(self: *NodeCache, hash_str: []const u8) void {
        if (self.hash_cache.getPtr(hash_str)) |cached| {
            cached.mark_dirty();
        }
    }

    /// Update a cached hash
    pub fn update_hash(self: *NodeCache, hash_str: []const u8, new_hash: [32]u8) !void {
        if (self.hash_cache.getPtr(hash_str)) |cached| {
            cached.update_hash(new_hash);
        } else {
            try self.cache_hash(hash_str, new_hash);
        }
    }

    /// Clear all cached hashes
    pub fn clear(self: *NodeCache) void {
        var it = self.hash_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.hash_cache.clearRetainingCapacity();
    }

    /// Reset the hex conversion arena (call periodically to free memory)
    pub fn reset_hex_arena(self: *NodeCache) void {
        _ = self.hex_arena.reset(.retain_capacity);
    }

    /// Get allocator for temporary hex conversions (uses arena)
    pub fn get_hex_allocator(self: *NodeCache) Allocator {
        return self.hex_arena.allocator();
    }
};

// Tests

test "CachedHash - basic operations" {
    const testing = std.testing;

    var hash: [32]u8 = undefined;
    for (0..32) |i| {
        hash[i] = @intCast(i);
    }

    var cached = CachedHash.init(hash);
    try testing.expect(!cached.is_dirty());

    const retrieved = cached.get_hash();
    try testing.expect(retrieved != null);
    try testing.expectEqualSlices(u8, &hash, &retrieved.?);

    cached.mark_dirty();
    try testing.expect(cached.is_dirty());
    try testing.expect(cached.get_hash() == null);

    var new_hash: [32]u8 = undefined;
    for (0..32) |i| {
        new_hash[i] = @intCast(i + 1);
    }

    cached.update_hash(new_hash);
    try testing.expect(!cached.is_dirty());
    const updated = cached.get_hash();
    try testing.expect(updated != null);
    try testing.expectEqualSlices(u8, &new_hash, &updated.?);
}

test "NodeCache - caching operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = NodeCache.init(allocator);
    defer cache.deinit();

    var hash: [32]u8 = undefined;
    for (0..32) |i| {
        hash[i] = @intCast(i);
    }

    const hash_str = "test_hash";

    // Cache the hash
    try cache.cache_hash(hash_str, hash);

    // Retrieve it
    const retrieved = cache.get_cached_hash(hash_str);
    try testing.expect(retrieved != null);
    try testing.expectEqualSlices(u8, &hash, &retrieved.?);

    // Mark dirty
    cache.mark_dirty(hash_str);
    const dirty_retrieve = cache.get_cached_hash(hash_str);
    try testing.expect(dirty_retrieve == null);

    // Update
    var new_hash: [32]u8 = undefined;
    for (0..32) |i| {
        new_hash[i] = @intCast(i + 1);
    }

    try cache.update_hash(hash_str, new_hash);
    const updated = cache.get_cached_hash(hash_str);
    try testing.expect(updated != null);
    try testing.expectEqualSlices(u8, &new_hash, &updated.?);

    // Clear
    cache.clear();
    const cleared = cache.get_cached_hash(hash_str);
    try testing.expect(cleared == null);
}

test "NodeCache - hex arena" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = NodeCache.init(allocator);
    defer cache.deinit();

    const hex_alloc = cache.get_hex_allocator();

    // Allocate some temporary hex strings
    const hex1 = try hex_alloc.alloc(u8, 64);
    const hex2 = try hex_alloc.alloc(u8, 64);

    // Use them
    @memset(hex1, 'a');
    @memset(hex2, 'b');

    try testing.expectEqual(@as(usize, 64), hex1.len);
    try testing.expectEqual(@as(usize, 64), hex2.len);

    // Reset arena (frees all allocations)
    cache.reset_hex_arena();

    // Can allocate again
    const hex3 = try hex_alloc.alloc(u8, 64);
    try testing.expectEqual(@as(usize, 64), hex3.len);
}
