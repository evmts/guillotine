//! Generic LRU (Least Recently Used) cache implementation
//! 
//! Provides O(1) get/put operations with automatic eviction of least recently used items.
//! Zero allocation after initialization - uses pre-allocated node pool.

const std = @import("std");
const testing = std.testing;

pub fn LruCache(comptime K: type, comptime V: type, comptime config: LruConfig) type {
    return struct {
        const Self = @This();
        
        const HashContextType = if (config.HashContext == void) 
            std.hash_map.AutoContext(K) 
        else 
            config.HashContext;
        
        // Define evicted item type here so it's consistent
        pub const EvictedItem = struct { key: K, value: V };
        
        // Core data structures
        map: std.HashMap(K, usize, HashContextType, 80),  // Key -> Node index
        nodes: []Node,  // Pre-allocated array of nodes
        head: usize,    // Index of most recently used node
        tail: usize,    // Index of least recently used node
        free_head: usize,    // Head of free list
        size: usize,
        allocator: std.mem.Allocator,
        
        // Statistics
        hits: u64,
        misses: u64,
        evictions: u64,
        
        const Node = struct {
            key: K,
            value: V,
            prev: usize,
            next: usize,
            in_use: bool,
        };
        
        const INVALID_INDEX = std.math.maxInt(usize);
        
        pub fn init(allocator: std.mem.Allocator) !Self {
            const nodes = try allocator.alloc(Node, config.capacity);
            
            // Initialize all nodes as free
            for (nodes, 0..) |*node, i| {
                node.* = .{
                    .key = undefined,
                    .value = undefined,
                    .prev = if (i == 0) INVALID_INDEX else i - 1,
                    .next = if (i == config.capacity - 1) INVALID_INDEX else i + 1,
                    .in_use = false,
                };
            }
            
            var map = std.HashMap(K, usize, HashContextType, 80).init(allocator);
            try map.ensureTotalCapacity(@intCast(config.capacity));
            
            return Self{
                .map = map,
                .nodes = nodes,
                .head = INVALID_INDEX,
                .tail = INVALID_INDEX,
                .free_head = 0,
                .size = 0,
                .allocator = allocator,
                .hits = 0,
                .misses = 0,
                .evictions = 0,
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.nodes);
            self.map.deinit();
        }
        
        /// Get value for key, moving it to the front (most recently used)
        pub fn get(self: *Self, key: K) ?V {
            if (self.map.get(key)) |idx| {
                self.hits += 1;
                self.moveToFront(idx);
                return self.nodes[idx].value;
            }
            self.misses += 1;
            return null;
        }
        
        /// Put key-value pair, returning evicted item if capacity exceeded
        pub fn put(self: *Self, key: K, value: V) !?EvictedItem {
            // Update existing entry
            if (self.map.get(key)) |idx| {
                self.nodes[idx].value = value;
                self.moveToFront(idx);
                return null;
            }
            
            // Need to add new entry
            var evicted: ?EvictedItem = null;
            
            // Evict LRU if at capacity
            if (self.size >= config.capacity) {
                evicted = self.evictLru();
            }
            
            // Allocate new node
            const idx = self.allocateNode();
            self.nodes[idx] = .{
                .key = key,
                .value = value,
                .prev = INVALID_INDEX,
                .next = self.head,
                .in_use = true,
            };
            
            // Update head's prev pointer if it exists
            if (self.head != INVALID_INDEX) {
                self.nodes[self.head].prev = idx;
            }
            
            // Update head
            self.head = idx;
            
            // Update tail if this is the first node
            if (self.tail == INVALID_INDEX) {
                self.tail = idx;
            }
            
            // Add to map
            try self.map.put(key, idx);
            self.size += 1;
            
            return evicted;
        }
        
        /// Check if key exists without updating position
        pub fn contains(self: *const Self, key: K) bool {
            return self.map.contains(key);
        }
        
        /// Remove a specific key
        pub fn remove(self: *Self, key: K) ?V {
            if (self.map.get(key)) |idx| {
                const node = &self.nodes[idx];
                const value = node.value;
                
                // Remove from map
                _ = self.map.remove(key);
                
                // Update linked list
                if (node.prev != INVALID_INDEX) {
                    self.nodes[node.prev].next = node.next;
                } else {
                    self.head = node.next;
                }
                
                if (node.next != INVALID_INDEX) {
                    self.nodes[node.next].prev = node.prev;
                } else {
                    self.tail = node.prev;
                }
                
                // Return node to free list
                self.freeNode(idx);
                self.size -= 1;
                
                return value;
            }
            return null;
        }
        
        /// Clear all entries
        pub fn clear(self: *Self) void {
            self.map.clearRetainingCapacity();
            
            // Reset all nodes to free state
            for (self.nodes, 0..) |*node, i| {
                node.* = .{
                    .key = undefined,
                    .value = undefined,
                    .prev = if (i == 0) INVALID_INDEX else i - 1,
                    .next = if (i == config.capacity - 1) INVALID_INDEX else i + 1,
                    .in_use = false,
                };
            }
            
            self.head = INVALID_INDEX;
            self.tail = INVALID_INDEX;
            self.free_head = 0;
            self.size = 0;
        }
        
        /// Get current number of entries
        pub fn getSize(self: *const Self) usize {
            return self.size;
        }
        
        /// Get cache statistics
        pub fn getStats(self: *const Self) CacheStats {
            return .{
                .hits = self.hits,
                .misses = self.misses,
                .evictions = self.evictions,
                .size = self.size,
                .capacity = config.capacity,
            };
        }
        
        // Internal functions
        
        fn moveToFront(self: *Self, idx: usize) void {
            if (idx == self.head) return;  // Already at front
            
            const node = &self.nodes[idx];
            
            // Remove from current position
            if (node.prev != INVALID_INDEX) {
                self.nodes[node.prev].next = node.next;
            }
            
            if (node.next != INVALID_INDEX) {
                self.nodes[node.next].prev = node.prev;
            } else {
                // This was the tail
                self.tail = node.prev;
            }
            
            // Move to front
            node.prev = INVALID_INDEX;
            node.next = self.head;
            
            if (self.head != INVALID_INDEX) {
                self.nodes[self.head].prev = idx;
            }
            
            self.head = idx;
        }
        
        fn evictLru(self: *Self) EvictedItem {
            if (self.tail == INVALID_INDEX) {
                @panic("LRU cache eviction called with empty cache");
            }

            const idx = self.tail;
            const node = self.nodes[idx];
            
            // Remove from map
            _ = self.map.remove(node.key);
            
            // Update tail
            if (node.prev != INVALID_INDEX) {
                self.nodes[node.prev].next = INVALID_INDEX;
                self.tail = node.prev;
            } else {
                // This was the only node
                self.head = INVALID_INDEX;
                self.tail = INVALID_INDEX;
            }
            
            // Return node to free list
            self.freeNode(idx);
            self.size -= 1;
            self.evictions += 1;
            
            return .{ .key = node.key, .value = node.value };
        }
        
        fn allocateNode(self: *Self) usize {
            if (self.free_head == INVALID_INDEX) {
                @panic("LRU cache allocation called with no free nodes");
            }

            const idx = self.free_head;
            const node = &self.nodes[idx];
            
            // Update free list head
            self.free_head = node.next;
            if (self.free_head != INVALID_INDEX) {
                self.nodes[self.free_head].prev = INVALID_INDEX;
            }
            
            node.in_use = true;
            return idx;
        }
        
        fn freeNode(self: *Self, idx: usize) void {
            const node = &self.nodes[idx];
            node.in_use = false;
            node.key = undefined;
            node.value = undefined;
            
            // Add to front of free list
            node.prev = INVALID_INDEX;
            node.next = self.free_head;
            
            if (self.free_head != INVALID_INDEX) {
                self.nodes[self.free_head].prev = idx;
            }
            
            self.free_head = idx;
        }
    };
}

pub const LruConfig = struct {
    capacity: usize,
    HashContext: type = void,  // Will be replaced with AutoContext(K) if void
};

pub const CacheStats = struct {
    hits: u64,
    misses: u64,
    evictions: u64,
    size: usize,
    capacity: usize,
    
    pub fn hitRate(self: CacheStats) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }
};

// =============================================================================
// Tests
// =============================================================================

test "LruCache - basic operations" {
    const Cache = LruCache(u32, u32, .{ .capacity = 3 });
    var cache = try Cache.init(testing.allocator);
    defer cache.deinit();
    
    // Test empty cache
    try testing.expect(cache.get(1) == null);
    try testing.expect(!cache.contains(1));
    try testing.expectEqual(@as(usize, 0), cache.getSize());
    
    // Test put and get
    try testing.expect(try cache.put(1, 100) == null);
    try testing.expectEqual(@as(u32, 100), cache.get(1).?);
    try testing.expect(cache.contains(1));
    try testing.expectEqual(@as(usize, 1), cache.getSize());
    
    // Test update existing
    try testing.expect(try cache.put(1, 101) == null);
    try testing.expectEqual(@as(u32, 101), cache.get(1).?);
    try testing.expectEqual(@as(usize, 1), cache.getSize());
}

test "LruCache - eviction" {
    const Cache = LruCache(u32, u32, .{ .capacity = 3 });
    var cache = try Cache.init(testing.allocator);
    defer cache.deinit();
    
    // Fill cache to capacity
    try testing.expect(try cache.put(1, 100) == null);
    try testing.expect(try cache.put(2, 200) == null);
    try testing.expect(try cache.put(3, 300) == null);
    
    try testing.expectEqual(@as(usize, 3), cache.getSize());
    
    // Add fourth item, should evict least recently used (1)
    const evicted = try cache.put(4, 400);
    try testing.expect(evicted != null);
    try testing.expectEqual(@as(u32, 1), evicted.?.key);
    try testing.expectEqual(@as(u32, 100), evicted.?.value);
    
    // Verify 1 was evicted
    try testing.expect(cache.get(1) == null);
    try testing.expect(cache.get(2) != null);
    try testing.expect(cache.get(3) != null);
    try testing.expect(cache.get(4) != null);
    try testing.expectEqual(@as(usize, 3), cache.getSize());
}

test "LruCache - LRU ordering" {
    const Cache = LruCache(u32, u32, .{ .capacity = 3 });
    var cache = try Cache.init(testing.allocator);
    defer cache.deinit();
    
    // Add items in order: 1, 2, 3
    _ = try cache.put(1, 100);
    _ = try cache.put(2, 200);
    _ = try cache.put(3, 300);
    
    // Access 1, making order: 2, 3, 1 (least to most recent)
    _ = cache.get(1);
    
    // Add 4, should evict 2 (least recently used)
    const evicted1 = try cache.put(4, 400);
    try testing.expectEqual(@as(u32, 2), evicted1.?.key);
    
    // Access 3, making order: 1, 4, 3
    _ = cache.get(3);
    
    // Add 5, should evict 1
    const evicted2 = try cache.put(5, 500);
    try testing.expectEqual(@as(u32, 1), evicted2.?.key);
    
    // Verify final state
    try testing.expect(cache.get(1) == null);  // Evicted
    try testing.expect(cache.get(2) == null);  // Evicted
    try testing.expectEqual(@as(u32, 300), cache.get(3).?);
    try testing.expectEqual(@as(u32, 400), cache.get(4).?);
    try testing.expectEqual(@as(u32, 500), cache.get(5).?);
}

test "LruCache - remove operation" {
    const Cache = LruCache(u32, u32, .{ .capacity = 3 });
    var cache = try Cache.init(testing.allocator);
    defer cache.deinit();
    
    _ = try cache.put(1, 100);
    _ = try cache.put(2, 200);
    _ = try cache.put(3, 300);
    
    // Remove middle item
    try testing.expectEqual(@as(u32, 200), cache.remove(2).?);
    try testing.expectEqual(@as(usize, 2), cache.getSize());
    try testing.expect(!cache.contains(2));
    
    // Can add new item without eviction now
    try testing.expect(try cache.put(4, 400) == null);
    try testing.expectEqual(@as(usize, 3), cache.getSize());
    
    // Remove non-existent
    try testing.expect(cache.remove(99) == null);
}

test "LruCache - clear operation" {
    const Cache = LruCache(u32, u32, .{ .capacity = 3 });
    var cache = try Cache.init(testing.allocator);
    defer cache.deinit();
    
    _ = try cache.put(1, 100);
    _ = try cache.put(2, 200);
    _ = try cache.put(3, 300);
    
    cache.clear();
    
    try testing.expectEqual(@as(usize, 0), cache.getSize());
    try testing.expect(cache.get(1) == null);
    try testing.expect(cache.get(2) == null);
    try testing.expect(cache.get(3) == null);
    
    // Can use cache again after clear
    _ = try cache.put(4, 400);
    try testing.expectEqual(@as(u32, 400), cache.get(4).?);
}

test "LruCache - statistics" {
    const Cache = LruCache(u32, u32, .{ .capacity = 2 });
    var cache = try Cache.init(testing.allocator);
    defer cache.deinit();
    
    _ = try cache.put(1, 100);
    _ = try cache.put(2, 200);
    
    // Generate hits and misses
    _ = cache.get(1);  // Hit
    _ = cache.get(1);  // Hit
    _ = cache.get(3);  // Miss
    _ = cache.get(4);  // Miss
    _ = cache.get(2);  // Hit
    
    // Cause eviction
    _ = try cache.put(3, 300);  // Evicts 1
    
    const stats = cache.getStats();
    try testing.expectEqual(@as(u64, 3), stats.hits);
    try testing.expectEqual(@as(u64, 2), stats.misses);
    try testing.expectEqual(@as(u64, 1), stats.evictions);
    try testing.expectEqual(@as(usize, 2), stats.size);
    try testing.expectEqual(@as(usize, 2), stats.capacity);
    
    // Hit rate should be 3/5 = 0.6
    try testing.expectApproxEqRel(@as(f64, 0.6), stats.hitRate(), 0.01);
}

test "LruCache - capacity 1 edge case" {
    const Cache = LruCache(u32, u32, .{ .capacity = 1 });
    var cache = try Cache.init(testing.allocator);
    defer cache.deinit();
    
    _ = try cache.put(1, 100);
    try testing.expectEqual(@as(u32, 100), cache.get(1).?);
    
    // Adding second item should evict first
    const evicted = try cache.put(2, 200);
    try testing.expectEqual(@as(u32, 1), evicted.?.key);
    try testing.expectEqual(@as(u32, 100), evicted.?.value);
    
    try testing.expect(cache.get(1) == null);
    try testing.expectEqual(@as(u32, 200), cache.get(2).?);
}

test "LruCache - stress test" {
    const Cache = LruCache(u32, u32, .{ .capacity = 100 });
    var cache = try Cache.init(testing.allocator);
    defer cache.deinit();
    
    // Add many items
    for (0..1000) |i| {
        const key = @as(u32, @intCast(i));
        const value = @as(u32, @intCast(i * 100));
        _ = try cache.put(key, value);
    }
    
    // Cache should contain last 100 items
    try testing.expectEqual(@as(usize, 100), cache.getSize());
    
    // Verify last 100 items are present
    for (900..1000) |i| {
        const key = @as(u32, @intCast(i));
        const expected_value = @as(u32, @intCast(i * 100));
        try testing.expectEqual(expected_value, cache.get(key).?);
    }
    
    // Verify earlier items were evicted
    for (0..900) |i| {
        const key = @as(u32, @intCast(i));
        try testing.expect(cache.get(key) == null);
    }
}

test "LruCache - with custom types" {
    const Key = struct {
        id: u32,
        
        pub fn hash(self: @This()) u64 {
            return std.hash.Wyhash.hash(0, std.mem.asBytes(&self.id));
        }
        
        pub fn eql(a: @This(), b: @This()) bool {
            return a.id == b.id;
        }
    };
    
    const Value = struct {
        data: [20]u8,
    };
    
    const HashContext = struct {
        pub fn hash(self: @This(), k: Key) u64 {
            _ = self;
            return k.hash();
        }
        pub fn eql(self: @This(), a: Key, b: Key) bool {
            _ = self;
            return a.eql(b);
        }
    };
    
    const Cache = LruCache(Key, Value, .{ 
        .capacity = 3,
        .HashContext = HashContext,
    });
    
    var cache = try Cache.init(testing.allocator);
    defer cache.deinit();
    
    const key1 = Key{ .id = 1 };
    const value1 = Value{ .data = [_]u8{1} ** 20 };
    
    _ = try cache.put(key1, value1);
    const retrieved = cache.get(key1).?;
    try testing.expectEqualSlices(u8, &value1.data, &retrieved.data);
}