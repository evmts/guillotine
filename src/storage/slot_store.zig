//! Storage slots of one database layer, with a per-address index.
//!
//! `slots` maps `(address, key)` to a value for O(1) SLOAD and SSTORE. `index`
//! lists, per address, every key the layer holds. The index makes the
//! per-account operations cost O(slots of that account) instead of O(all slots
//! in the layer): clearing an account's storage (SELFDESTRUCT, account
//! deletion) and the layered EIP-7610 "has storage" check.
//!
//! Both structures change together, and only through `put` and `restore`, so a
//! host that copies or swaps a whole store (`clone`, then assignment) keeps
//! them consistent.
//!
//! `restore` undoes a `put`. It never allocates and cannot fail, provided
//! writes are undone newest first: a key leaves the store only when the `put`
//! that introduced it is undone, and capacity never shrinks, so re-inserting a
//! key reuses space that already exists.

const std = @import("std");

/// Key of one storage slot: the owning address and the slot number.
pub const SlotKey = struct {
    address: [20]u8,
    key: u256,
};

pub const SlotStore = struct {
    slots: Map,
    index: Index,
    allocator: std.mem.Allocator,

    pub const Map = std.HashMap(SlotKey, u256, SlotKeyContext, std.hash_map.default_max_load_percentage);
    /// Every key the store holds for one address, zero-valued ones included.
    const KeySet = std.array_hash_map.Auto(u256, void);
    const Index = std.HashMap([20]u8, KeySet, AddressContext, std.hash_map.default_max_load_percentage);

    const AddressContext = struct {
        pub fn hash(_: @This(), address: [20]u8) u64 {
            return std.hash_map.hashString(&address);
        }
        pub fn eql(_: @This(), a: [20]u8, b: [20]u8) bool {
            return std.mem.eql(u8, &a, &b);
        }
    };

    const SlotKeyContext = struct {
        pub fn hash(_: @This(), key: SlotKey) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(&key.address);
            hasher.update(std.mem.asBytes(&key.key));
            return hasher.final();
        }
        pub fn eql(_: @This(), a: SlotKey, b: SlotKey) bool {
            return std.mem.eql(u8, &a.address, &b.address) and a.key == b.key;
        }
    };

    pub fn init(allocator: std.mem.Allocator) SlotStore {
        return .{ .slots = Map.init(allocator), .index = Index.init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *SlotStore) void {
        self.freeKeySets();
        self.index.deinit();
        self.slots.deinit();
    }

    fn freeKeySets(self: *SlotStore) void {
        var accounts = self.index.valueIterator();
        while (accounts.next()) |keys| keys.deinit(self.allocator);
    }

    /// Deep copy. The copy shares nothing with `self`.
    pub fn clone(self: *const SlotStore) std.mem.Allocator.Error!SlotStore {
        var copy = SlotStore.init(self.allocator);
        errdefer copy.deinit();
        copy.slots = try self.slots.clone();
        try copy.index.ensureTotalCapacity(self.index.count());
        var accounts = self.index.iterator();
        while (accounts.next()) |entry| {
            const keys = try entry.value_ptr.clone(self.allocator);
            copy.index.putAssumeCapacity(entry.key_ptr.*, keys);
        }
        return copy;
    }

    /// Drop every slot. Slot capacity is kept; the index is freed.
    pub fn clearRetainingCapacity(self: *SlotStore) void {
        self.slots.clearRetainingCapacity();
        self.freeKeySets();
        self.index.clearRetainingCapacity();
    }

    /// The value held for `key`, or null when the store has no entry for it.
    pub fn get(self: *const SlotStore, key: SlotKey) ?u256 {
        return self.slots.get(key);
    }

    /// True when the store has an entry for `key`, zero-valued or not.
    pub fn contains(self: *const SlotStore, key: SlotKey) bool {
        return self.slots.contains(key);
    }

    /// Number of slots held, zero-valued ones included.
    pub fn count(self: *const SlotStore) usize {
        return self.slots.count();
    }

    /// Iterates every slot held, in no particular order.
    pub fn iterator(self: *const SlotStore) Map.Iterator {
        return self.slots.iterator();
    }

    /// Every key held for `address`, zero-valued ones included. The slice is
    /// valid until the next `put` or `restore` for that address.
    pub fn keysOf(self: *const SlotStore, address: [20]u8) []const u256 {
        const keys = self.index.getPtr(address) orelse return &.{};
        return keys.keys();
    }

    /// Store `value` under `key` and return what the store held before (null:
    /// no entry). On error the store is unchanged.
    pub fn put(self: *SlotStore, key: SlotKey, value: u256) std.mem.Allocator.Error!?u256 {
        // Everything fallible runs before the first change. A failure after the
        // index entry is created leaves only an empty key set behind.
        const keys = try self.index.getOrPut(key.address);
        if (!keys.found_existing) keys.value_ptr.* = .empty;
        try keys.value_ptr.ensureUnusedCapacity(self.allocator, 1);
        const slot = try self.slots.getOrPut(key);

        const previous: ?u256 = if (slot.found_existing) slot.value_ptr.* else null;
        if (previous == null) keys.value_ptr.putAssumeCapacity(key.key, {});
        slot.value_ptr.* = value;
        return previous;
    }

    /// Undo a `put` of `key` that returned `previous`. See the module comment
    /// for why this cannot fail.
    pub fn restore(self: *SlotStore, key: SlotKey, previous: ?u256) void {
        // The `put` being undone created the index entry and nothing removes it.
        const keys = self.index.getPtr(key.address) orelse return;
        const value = previous orelse {
            if (self.slots.remove(key)) _ = keys.swapRemove(key.key);
            return;
        };
        if (self.slots.getPtr(key)) |current| {
            current.* = value;
            return;
        }
        self.slots.putAssumeCapacity(key, value);
        keys.putAssumeCapacity(key.key, {});
    }
};

const testing = std.testing;

test "SlotStore put indexes keys per address" {
    var store = SlotStore.init(testing.allocator);
    defer store.deinit();
    const a = @as([20]u8, @splat(0xA1));
    const b = @as([20]u8, @splat(0xB2));

    try testing.expectEqual(@as(?u256, null), try store.put(.{ .address = a, .key = 1 }, 10));
    try testing.expectEqual(@as(?u256, null), try store.put(.{ .address = a, .key = 2 }, 0));
    try testing.expectEqual(@as(?u256, null), try store.put(.{ .address = b, .key = 1 }, 30));
    try testing.expectEqual(@as(?u256, 10), try store.put(.{ .address = a, .key = 1 }, 11));

    try testing.expectEqual(@as(usize, 3), store.count());
    try testing.expectEqualSlices(u256, &.{ 1, 2 }, store.keysOf(a));
    try testing.expectEqualSlices(u256, &.{1}, store.keysOf(b));
    try testing.expectEqual(@as(usize, 0), store.keysOf(@as([20]u8, @splat(0))).len);
    try testing.expectEqual(@as(?u256, 11), store.get(.{ .address = a, .key = 1 }));

    // A key written to zero stays indexed.
    try testing.expectEqual(@as(?u256, 11), try store.put(.{ .address = a, .key = 1 }, 0));
    try testing.expectEqualSlices(u256, &.{ 1, 2 }, store.keysOf(a));
    try testing.expect(store.contains(.{ .address = a, .key = 1 }));
}

test "SlotStore restore undoes puts newest first" {
    var store = SlotStore.init(testing.allocator);
    defer store.deinit();
    const a = @as([20]u8, @splat(0xA1));
    const key = SlotKey{ .address = a, .key = 7 };

    const first = try store.put(key, 5);
    const second = try store.put(key, 0);
    const other = try store.put(.{ .address = a, .key = 8 }, 9);

    store.restore(.{ .address = a, .key = 8 }, other);
    try testing.expectEqualSlices(u256, &.{7}, store.keysOf(a));
    try testing.expectEqual(@as(?u256, 0), store.get(key));

    store.restore(key, second);
    try testing.expectEqual(@as(?u256, 5), store.get(key));

    store.restore(key, first);
    try testing.expectEqual(@as(?u256, null), store.get(key));
    try testing.expectEqual(@as(usize, 0), store.keysOf(a).len);
    try testing.expectEqual(@as(usize, 0), store.count());
}

test "SlotStore clone is independent and carries the index" {
    var store = SlotStore.init(testing.allocator);
    defer store.deinit();
    const a = @as([20]u8, @splat(0xA1));
    _ = try store.put(.{ .address = a, .key = 1 }, 10);

    var copy = try store.clone();
    defer copy.deinit();
    _ = try store.put(.{ .address = a, .key = 2 }, 20);
    _ = try store.put(.{ .address = a, .key = 1 }, 0);

    try testing.expectEqualSlices(u256, &.{1}, copy.keysOf(a));
    try testing.expectEqual(@as(?u256, 10), copy.get(.{ .address = a, .key = 1 }));
    try testing.expectEqualSlices(u256, &.{ 1, 2 }, store.keysOf(a));
    try testing.expectEqual(@as(?u256, 0), store.get(.{ .address = a, .key = 1 }));
}

test "SlotStore clearRetainingCapacity empties slots and index" {
    var store = SlotStore.init(testing.allocator);
    defer store.deinit();
    const a = @as([20]u8, @splat(0xA1));
    _ = try store.put(.{ .address = a, .key = 1 }, 10);

    store.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 0), store.count());
    try testing.expectEqual(@as(usize, 0), store.keysOf(a).len);

    _ = try store.put(.{ .address = a, .key = 3 }, 4);
    try testing.expectEqualSlices(u256, &.{3}, store.keysOf(a));
}

test "SlotStore put leaves the store unchanged when allocation fails" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var store = SlotStore.init(failing.allocator());
    defer store.deinit();
    const a = @as([20]u8, @splat(0xA1));
    _ = try store.put(.{ .address = a, .key = 1 }, 10);

    var fail_index: usize = 0;
    while (fail_index < 8) : (fail_index += 1) {
        failing.fail_index = failing.alloc_index + fail_index;
        const key = SlotKey{ .address = @as([20]u8, @splat(@intCast(0x10 + fail_index))), .key = 99 };
        if (store.put(key, 1)) |_| break else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(?u256, null), store.get(key));
            try testing.expectEqual(@as(usize, 0), store.keysOf(key.address).len);
        }
    }
    try testing.expectEqual(@as(?u256, 10), store.get(.{ .address = a, .key = 1 }));
}
