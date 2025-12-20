/// Storage Injector with LRU Cache for Async State Interface
/// Phase 2: Storage Injector with LRU Cache
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

/// Simple LRU cache for storage slots
/// Using a basic implementation since we can't import from Guillotine
pub fn LruCache(comptime K: type, comptime V: type, comptime capacity: usize) type {
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

// Import StorageKey from evm.zig to avoid duplication
const evm_module = @import("evm.zig");
const StorageKey = evm_module.StorageKey;

/// Storage Injector - manages LRU cache and dirty tracking for async storage
pub const StorageInjector = struct {
    allocator: std.mem.Allocator,

    // LRU cache (check before sending message)
    storage_cache: LruCache(StorageKey, u256, 1024),
    balance_cache: LruCache(Address, u256, 256),
    code_cache: LruCache(Address, []const u8, 128),
    nonce_cache: LruCache(Address, u64, 256),

    // Dirty tracking (for change dump)
    dirty_storage: std.AutoHashMap(StorageKey, void),
    dirty_balances: std.AutoHashMap(Address, void),
    dirty_nonces: std.AutoHashMap(Address, void),
    dirty_codes: std.AutoHashMap(Address, void),

    pub fn init(allocator: std.mem.Allocator) !StorageInjector {
        return StorageInjector{
            .allocator = allocator,
            .storage_cache = try LruCache(StorageKey, u256, 1024).init(allocator),
            .balance_cache = try LruCache(Address, u256, 256).init(allocator),
            .code_cache = try LruCache(Address, []const u8, 128).init(allocator),
            .nonce_cache = try LruCache(Address, u64, 256).init(allocator),
            .dirty_storage = std.AutoHashMap(StorageKey, void).init(allocator),
            .dirty_balances = std.AutoHashMap(Address, void).init(allocator),
            .dirty_nonces = std.AutoHashMap(Address, void).init(allocator),
            .dirty_codes = std.AutoHashMap(Address, void).init(allocator),
        };
    }

    pub fn deinit(self: *StorageInjector) void {
        // Clean up code cache memory - need to free each slice
        var code_iter = self.code_cache.map.valueIterator();
        while (code_iter.next()) |node_ptr| {
            const node = node_ptr.*;
            self.allocator.free(node.value);
        }

        self.storage_cache.deinit();
        self.balance_cache.deinit();
        self.code_cache.deinit();
        self.nonce_cache.deinit();
        self.dirty_storage.deinit();
        self.dirty_balances.deinit();
        self.dirty_nonces.deinit();
        self.dirty_codes.deinit();
    }

    /// Mark storage slot as dirty (called by Evm.set_storage)
    pub fn markStorageDirty(self: *StorageInjector, address: Address, slot: u256) !void {
        const key = StorageKey{ .address = address.bytes, .slot = slot };
        try self.dirty_storage.put(key, {});
    }

    /// Mark balance as dirty
    pub fn markBalanceDirty(self: *StorageInjector, address: Address) !void {
        try self.dirty_balances.put(address, {});
    }

    /// Mark nonce as dirty
    pub fn markNonceDirty(self: *StorageInjector, address: Address) !void {
        try self.dirty_nonces.put(address, {});
    }

    /// Mark code as dirty
    pub fn markCodeDirty(self: *StorageInjector, address: Address) !void {
        try self.dirty_codes.put(address, {});
    }

    /// Clear cache and dirty sets (called at start of new transaction)
    pub fn clearCache(self: *StorageInjector) void {
        self.storage_cache.clear();
        self.balance_cache.clear();
        self.code_cache.clear();
        self.nonce_cache.clear();
        self.dirty_storage.clearRetainingCapacity();
        self.dirty_balances.clearRetainingCapacity();
        self.dirty_nonces.clearRetainingCapacity();
        self.dirty_codes.clearRetainingCapacity();
    }

    // Cache read methods
    pub fn getStorageFromCache(self: *StorageInjector, address: Address, slot: u256) ?u256 {
        const key = StorageKey{ .address = address.bytes, .slot = slot };
        return self.storage_cache.get(key);
    }

    pub fn getBalanceFromCache(self: *StorageInjector, address: Address) ?u256 {
        return self.balance_cache.get(address);
    }

    pub fn getCodeFromCache(self: *StorageInjector, address: Address) ?[]const u8 {
        return self.code_cache.get(address);
    }

    pub fn getNonceFromCache(self: *StorageInjector, address: Address) ?u64 {
        return self.nonce_cache.get(address);
    }

    // Cache write methods
    pub fn cacheStorage(self: *StorageInjector, address: Address, slot: u256, value: u256) !void {
        const key = StorageKey{ .address = address.bytes, .slot = slot };
        try self.storage_cache.put(key, value);
    }

    pub fn cacheBalance(self: *StorageInjector, address: Address, balance: u256) !void {
        try self.balance_cache.put(address, balance);
    }

    pub fn cacheCode(self: *StorageInjector, address: Address, code: []const u8) !void {
        // Duplicate the code slice since cache will own it
        const code_copy = try self.allocator.dupe(u8, code);
        try self.code_cache.put(address, code_copy);
    }

    pub fn cacheNonce(self: *StorageInjector, address: Address, nonce: u64) !void {
        try self.nonce_cache.put(address, nonce);
    }

    /// Dump all state changes as JSON for commit
    /// Returns JSON string allocated with arena allocator
    pub fn dumpChanges(self: *StorageInjector, evm: anytype) ![]const u8 {
        // Determine EVM type (mock vs real) once at the beginning
        const EvmTypeInfo = @typeInfo(@TypeOf(evm));
        const EvmType = if (EvmTypeInfo == .pointer) @TypeOf(evm.*) else @TypeOf(evm);

        var buffer: std.ArrayList(u8) = .{};
        defer buffer.deinit(self.allocator);
        const writer = buffer.writer(self.allocator);

        // Start JSON object
        try writer.writeAll("{\"storage\":[");

        // Dump storage changes
        var storage_iter = self.dirty_storage.keyIterator();
        var first_storage = true;
        while (storage_iter.next()) |key| {
            if (!first_storage) try writer.writeAll(",");
            first_storage = false;

            // Get original and current values
            // Support both mock EVM (with HashMap) and real EVM (with Storage struct)
            const is_mock = @hasField(EvmType, "original_storage");

            const original = if (is_mock)
                evm.original_storage.get(key.*) orelse 0
            else
                evm.storage.getOriginal(primitives.Address{ .bytes = key.address }, key.slot);

            const current = if (is_mock)
                evm.storage.get(key.*) orelse 0
            else
                evm.storage.get(primitives.Address{ .bytes = key.address }, key.slot) catch 0;

            // Format: {"address":"0x...","slot":"0x...","originalValue":"0x...","newValue":"0x..."}
            try writer.writeAll("{\"address\":\"0x");
            // Format address as hex
            for (key.address) |byte| {
                try std.fmt.format(writer, "{x:0>2}", .{byte});
            }
            try writer.writeAll("\",\"slot\":\"0x");
            try std.fmt.format(writer, "{x}", .{key.slot});
            try writer.writeAll("\",\"originalValue\":\"0x");
            try std.fmt.format(writer, "{x}", .{original});
            try writer.writeAll("\",\"newValue\":\"0x");
            try std.fmt.format(writer, "{x}", .{current});
            try writer.writeAll("\"}");
        }

        try writer.writeAll("],\"balances\":[");

        // Dump balance changes
        var balance_iter = self.dirty_balances.keyIterator();
        var first_balance = true;
        while (balance_iter.next()) |address| {
            if (!first_balance) try writer.writeAll(",");
            first_balance = false;

            const balance = if (evm.balances.get(address.*)) |b| b else 0;

            // Format: {"address":"0x...","balance":"0x..."}
            try writer.writeAll("{\"address\":\"0x");
            for (address.bytes) |byte| {
                try std.fmt.format(writer, "{x:0>2}", .{byte});
            }
            try writer.writeAll("\",\"balance\":\"0x");
            try std.fmt.format(writer, "{x}", .{balance});
            try writer.writeAll("\"}");
        }

        try writer.writeAll("],\"nonces\":[");

        // Dump nonce changes
        var nonce_iter = self.dirty_nonces.keyIterator();
        var first_nonce = true;
        while (nonce_iter.next()) |address| {
            if (!first_nonce) try writer.writeAll(",");
            first_nonce = false;

            const nonce = if (@hasField(EvmType, "nonces"))
                evm.nonces.get(address.*) orelse 0
            else
                evm.getNonce(address.*);

            // Format: {"address":"0x...","nonce":"0x..."}
            try writer.writeAll("{\"address\":\"0x");
            for (address.bytes) |byte| {
                try std.fmt.format(writer, "{x:0>2}", .{byte});
            }
            try writer.writeAll("\",\"nonce\":\"0x");
            try std.fmt.format(writer, "{x}", .{nonce});
            try writer.writeAll("\"}");
        }

        try writer.writeAll("],\"codes\":[");

        // Dump code changes
        var code_iter = self.dirty_codes.keyIterator();
        var first_code = true;
        while (code_iter.next()) |address| {
            if (!first_code) try writer.writeAll(",");
            first_code = false;

            const code = if (evm.code.get(address.*)) |c| c else &[_]u8{};

            // Format: {"address":"0x...","code":"0x..."}
            try writer.writeAll("{\"address\":\"0x");
            for (address.bytes) |byte| {
                try std.fmt.format(writer, "{x:0>2}", .{byte});
            }
            try writer.writeAll("\",\"code\":\"0x");
            for (code) |byte| {
                try std.fmt.format(writer, "{x:0>2}", .{byte});
            }
            try writer.writeAll("\"}");
        }

        try writer.writeAll("],\"selfDestructs\":[");

        // Dump self-destructs if tracked
        if (@hasField(EvmType, "selfdestructed_accounts")) {
            var selfdestruct_iter = evm.selfdestructed_accounts.keyIterator();
            var first_sd = true;
            while (selfdestruct_iter.next()) |address| {
                if (!first_sd) try writer.writeAll(",");
                first_sd = false;

                try writer.writeAll("\"0x");
                for (address.bytes) |byte| {
                    try std.fmt.format(writer, "{x:0>2}", .{byte});
                }
                try writer.writeAll("\"");
            }
        }

        try writer.writeAll("]}");

        return buffer.toOwnedSlice(self.allocator);
    }
};

// ============================================================================
// Tests for Phase 2: Storage Injector with LRU Cache
// ============================================================================

test "StorageInjector - init and deinit" {
    const testing = std.testing;

    var injector = try StorageInjector.init(testing.allocator);
    defer injector.deinit();

    // Verify empty state
    try testing.expectEqual(@as(usize, 0), injector.storage_cache.size);
    try testing.expectEqual(@as(usize, 0), injector.dirty_storage.count());
}

test "StorageInjector - markStorageDirty adds to dirty set" {
    const testing = std.testing;

    var injector = try StorageInjector.init(testing.allocator);
    defer injector.deinit();

    const addr = primitives.Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
    const key = StorageKey{ .address = addr.bytes, .slot = 42 };

    try injector.markStorageDirty(addr, 42);

    try testing.expect(injector.dirty_storage.contains(key));
}

test "StorageInjector - multiple marks for same slot (idempotent)" {
    const testing = std.testing;

    var injector = try StorageInjector.init(testing.allocator);
    defer injector.deinit();

    const addr = primitives.Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;

    try injector.markStorageDirty(addr, 42);
    try injector.markStorageDirty(addr, 42);
    try injector.markStorageDirty(addr, 42);

    // Should only have one entry
    try testing.expectEqual(@as(usize, 1), injector.dirty_storage.count());
}

test "StorageInjector - clearCache clears all state" {
    const testing = std.testing;

    var injector = try StorageInjector.init(testing.allocator);
    defer injector.deinit();

    const addr = primitives.Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
    const key = StorageKey{ .address = addr.bytes, .slot = 42 };

    // Add some data
    try injector.storage_cache.put(key, 100);
    try injector.markStorageDirty(addr, 42);

    // Clear
    injector.clearCache();

    // Verify everything is cleared
    try testing.expectEqual(@as(usize, 0), injector.storage_cache.size);
    try testing.expectEqual(@as(usize, 0), injector.dirty_storage.count());
}

test "LruCache - init and deinit" {
    const testing = std.testing;
    const Cache = LruCache(u32, u32, 10);

    var cache = try Cache.init(testing.allocator);
    defer cache.deinit();

    try testing.expectEqual(@as(usize, 0), cache.size);
}

test "LruCache - put and get" {
    const testing = std.testing;
    const Cache = LruCache(u32, u32, 10);

    var cache = try Cache.init(testing.allocator);
    defer cache.deinit();

    try cache.put(1, 100);
    try testing.expectEqual(@as(u32, 100), cache.get(1).?);
    try testing.expectEqual(@as(usize, 1), cache.size);
}

test "LruCache - cache miss" {
    const testing = std.testing;
    const Cache = LruCache(u32, u32, 10);

    var cache = try Cache.init(testing.allocator);
    defer cache.deinit();

    try testing.expect(cache.get(99) == null);
}

test "LruCache - update existing" {
    const testing = std.testing;
    const Cache = LruCache(u32, u32, 10);

    var cache = try Cache.init(testing.allocator);
    defer cache.deinit();

    try cache.put(1, 100);
    try cache.put(1, 200);

    try testing.expectEqual(@as(u32, 200), cache.get(1).?);
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

// ============================================================================
// Tests for Phase 6: dumpChanges() and JSON Serialization
// ============================================================================

test "StorageInjector - dumpChanges with empty dirty sets" {
    const testing = std.testing;

    var injector = try StorageInjector.init(testing.allocator);
    defer injector.deinit();

    // Create minimal mock EVM for testing
    const MockEvm = struct {
        original_storage: std.AutoHashMap(StorageKey, u256),
        storage: std.AutoHashMap(StorageKey, u256),
        balances: std.AutoHashMap(Address, u256),
        nonces: std.AutoHashMap(Address, u64),
        code: std.AutoHashMap(Address, []const u8),
    };

    var mock_evm = MockEvm{
        .original_storage = std.AutoHashMap(StorageKey, u256).init(testing.allocator),
        .storage = std.AutoHashMap(StorageKey, u256).init(testing.allocator),
        .balances = std.AutoHashMap(Address, u256).init(testing.allocator),
        .nonces = std.AutoHashMap(Address, u64).init(testing.allocator),
        .code = std.AutoHashMap(Address, []const u8).init(testing.allocator),
    };
    defer mock_evm.original_storage.deinit();
    defer mock_evm.storage.deinit();
    defer mock_evm.balances.deinit();
    defer mock_evm.nonces.deinit();
    defer mock_evm.code.deinit();

    const json = try injector.dumpChanges(mock_evm);
    defer testing.allocator.free(json);

    // Should return empty arrays
    try testing.expectEqualStrings("{\"storage\":[],\"balances\":[],\"nonces\":[],\"codes\":[],\"selfDestructs\":[]}", json);
}

test "StorageInjector - dumpChanges with storage change" {
    const testing = std.testing;

    var injector = try StorageInjector.init(testing.allocator);
    defer injector.deinit();

    const addr = primitives.Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
    const slot: u256 = 42;
    const key = StorageKey{ .address = addr.bytes, .slot = slot };

    // Mock EVM
    const MockEvm = struct {
        original_storage: std.AutoHashMap(StorageKey, u256),
        storage: std.AutoHashMap(StorageKey, u256),
        balances: std.AutoHashMap(Address, u256),
        nonces: std.AutoHashMap(Address, u64),
        code: std.AutoHashMap(Address, []const u8),
    };

    var mock_evm = MockEvm{
        .original_storage = std.AutoHashMap(StorageKey, u256).init(testing.allocator),
        .storage = std.AutoHashMap(StorageKey, u256).init(testing.allocator),
        .balances = std.AutoHashMap(Address, u256).init(testing.allocator),
        .nonces = std.AutoHashMap(Address, u64).init(testing.allocator),
        .code = std.AutoHashMap(Address, []const u8).init(testing.allocator),
    };
    defer mock_evm.original_storage.deinit();
    defer mock_evm.storage.deinit();
    defer mock_evm.balances.deinit();
    defer mock_evm.nonces.deinit();
    defer mock_evm.code.deinit();

    // Set up state
    try mock_evm.original_storage.put(key, 0);
    try mock_evm.storage.put(key, 100);
    try injector.markStorageDirty(addr, slot);

    const json = try injector.dumpChanges(mock_evm);
    defer testing.allocator.free(json);

    // Verify JSON contains the change
    try testing.expect(std.mem.indexOf(u8, json, "\"address\":\"0x1234567890123456789012345678901234567890\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"storage\":[") != null);
}
