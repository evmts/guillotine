const std = @import("std");

// Test LruCache implementation standalone
fn LruCache(comptime K: type, comptime V: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        const Node = struct {
            key: K,
            value: V,
            prev: ?*Node,
            next: ?*Node,
        };

        map: std.AutoHashMap(K, *Node),
        head: ?*Node,
        tail: ?*Node,
        allocator: std.mem.Allocator,
        size: usize,

        // Statistics
        hits: u64,
        misses: u64,

        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self{
                .map = std.AutoHashMap(K, *Node).init(allocator),
                .head = null,
                .tail = null,
                .allocator = allocator,
                .size = 0,
                .hits = 0,
                .misses = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            var current = self.head;
            while (current) |node| {
                const next = node.next;
                self.allocator.destroy(node);
                current = next;
            }
            self.map.deinit();
        }

        pub fn get(self: *Self, key: K) ?V {
            if (self.map.get(key)) |node| {
                self.hits += 1;
                self.moveToFront(node);
                return node.value;
            }
            self.misses += 1;
            return null;
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            // Update existing entry
            if (self.map.get(key)) |node| {
                node.value = value;
                self.moveToFront(node);
                return;
            }

            // Evict LRU if at capacity
            if (self.size >= capacity) {
                try self.evictLru();
            }

            // Allocate new node
            const node = try self.allocator.create(Node);
            node.* = .{
                .key = key,
                .value = value,
                .prev = null,
                .next = self.head,
            };

            // Update head's prev pointer if it exists
            if (self.head) |h| {
                h.prev = node;
            }

            // Update head
            self.head = node;

            // Update tail if this is the first node
            if (self.tail == null) {
                self.tail = node;
            }

            // Add to map
            try self.map.put(key, node);
            self.size += 1;
        }

        pub fn clear(self: *Self) void {
            var current = self.head;
            while (current) |node| {
                const next = node.next;
                self.allocator.destroy(node);
                current = next;
            }

            self.map.clearRetainingCapacity();
            self.head = null;
            self.tail = null;
            self.size = 0;
        }

        fn moveToFront(self: *Self, node: *Node) void {
            if (node == self.head) return; // Already at front

            // Remove from current position
            if (node.prev) |p| {
                p.next = node.next;
            }

            if (node.next) |n| {
                n.prev = node.prev;
            } else {
                // This was the tail
                self.tail = node.prev;
            }

            // Move to front
            node.prev = null;
            node.next = self.head;

            if (self.head) |h| {
                h.prev = node;
            }

            self.head = node;
        }

        fn evictLru(self: *Self) !void {
            if (self.tail) |node| {
                // Remove from map
                _ = self.map.remove(node.key);

                // Update tail
                if (node.prev) |p| {
                    p.next = null;
                    self.tail = p;
                } else {
                    // This was the only node
                    self.head = null;
                    self.tail = null;
                }

                // Free node
                self.allocator.destroy(node);
                self.size -= 1;
            }
        }
    };
}

test "LruCache - basic operations" {
    const testing = std.testing;
    const Cache = LruCache(u32, u32, 10);

    var cache = try Cache.init(testing.allocator);
    defer cache.deinit();

    try cache.put(1, 100);
    try testing.expectEqual(@as(u32, 100), cache.get(1).?);
    try testing.expectEqual(@as(usize, 1), cache.size);
}

test "LruCache - eviction at capacity" {
    const testing = std.testing;
    const Cache = LruCache(u32, u32, 2);

    var cache = try Cache.init(testing.allocator);
    defer cache.deinit();

    try cache.put(1, 100);
    try cache.put(2, 200);
    try testing.expectEqual(@as(usize, 2), cache.size);

    // Adding third item should evict first
    try cache.put(3, 300);

    try testing.expect(cache.get(1) == null); // Evicted
    try testing.expectEqual(@as(u32, 200), cache.get(2).?);
    try testing.expectEqual(@as(u32, 300), cache.get(3).?);
    try testing.expectEqual(@as(usize, 2), cache.size);
}

test "LruCache - LRU ordering" {
    const testing = std.testing;
    const Cache = LruCache(u32, u32, 3);

    var cache = try Cache.init(testing.allocator);
    defer cache.deinit();

    // Fill cache
    try cache.put(1, 100);
    try cache.put(2, 200);
    try cache.put(3, 300);

    // Access 1 (moves it to front)
    _ = cache.get(1);

    // Add 4 (should evict 2, which is now LRU)
    try cache.put(4, 400);

    try testing.expectEqual(@as(u32, 100), cache.get(1).?);
    try testing.expect(cache.get(2) == null); // Evicted
    try testing.expectEqual(@as(u32, 300), cache.get(3).?);
    try testing.expectEqual(@as(u32, 400), cache.get(4).?);
}

test "LruCache - hit/miss tracking" {
    const testing = std.testing;
    const Cache = LruCache(u32, u32, 10);

    var cache = try Cache.init(testing.allocator);
    defer cache.deinit();

    try cache.put(1, 100);

    _ = cache.get(1); // Hit
    _ = cache.get(1); // Hit
    _ = cache.get(2); // Miss
    _ = cache.get(3); // Miss

    try testing.expectEqual(@as(u64, 2), cache.hits);
    try testing.expectEqual(@as(u64, 2), cache.misses);
}

test "LruCache - clear" {
    const testing = std.testing;
    const Cache = LruCache(u32, u32, 10);

    var cache = try Cache.init(testing.allocator);
    defer cache.deinit();

    try cache.put(1, 100);
    try cache.put(2, 200);

    cache.clear();

    try testing.expectEqual(@as(usize, 0), cache.size);
    try testing.expect(cache.get(1) == null);
    try testing.expect(cache.get(2) == null);
}

test "JSON formatting - basic structure" {
    const testing = std.testing;

    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(testing.allocator);
    const writer = buffer.writer(testing.allocator);

    // Test building JSON manually
    try writer.writeAll("{\"storage\":[");

    // Add one storage entry
    try writer.writeAll("{\"address\":\"0xabcd\",\"slot\":\"0x2a\"}");

    try writer.writeAll("],\"balances\":[]}");

    const expected = "{\"storage\":[{\"address\":\"0xabcd\",\"slot\":\"0x2a\"}],\"balances\":[]}";
    try testing.expectEqualStrings(expected, buffer.items);
}
