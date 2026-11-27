//! Storage slots of one database layer, with a per-address index.
//!
//! `slots` maps `(address, key)` to a value for O(1) SLOAD and SSTORE. `index`
//! holds, per address, every key the layer has for it and the number of those
//! slots whose value is non-zero. The index makes the per-account operations
//! cost O(slots of that account) instead of O(all slots in the layer): clearing
//! an account's storage (SELFDESTRUCT, account deletion) and the EIP-7610 "has
//! storage" check, which reads the count.
//!
//! Both structures change together, and only through `put` and `restore`, so a
//! host that copies or swaps a whole store (`clone`, then assignment) keeps
//! them consistent.
//!
//! Overwriting a slot the store already holds is the hot SSTORE path. It probes
//! `slots` once, never allocates and cannot fail; the index is read only when
//! the write changes the slot between zero and non-zero.
//!
//! `restore` undoes a `put`. It never allocates and cannot fail, provided
//! writes are undone newest first: a key leaves the store only when the `put`
//! that introduced it is undone, and capacity never shrinks, so re-inserting a
//! key reuses space that already exists.
//!
//! Slot lookups take the slot's hash (`slot_hash.hash`) from the caller when it
//! already has it (`getHashed`, `putHashed`), so one SSTORE hashes its slot once
//! for the access list, the journal and the store.

const std = @import("std");
const slot_hash = @import("slot_hash.zig");

/// Key of one storage slot: the owning address and the slot number.
pub const SlotKey = struct {
    address: [20]u8,
    key: u256,

    pub fn eql(a: SlotKey, b: SlotKey) bool {
        return a.key == b.key and std.mem.eql(u8, &a.address, &b.address);
    }

    pub fn hash(self: SlotKey) u64 {
        return slot_hash.hash(self.address, self.key);
    }
};

/// Hash-map context for tables keyed by `SlotKey`. Uses the shared slot hash.
pub const SlotKeyContext = struct {
    pub fn hash(_: @This(), key: SlotKey) u64 {
        return key.hash();
    }
    pub fn eql(_: @This(), a: SlotKey, b: SlotKey) bool {
        return a.eql(b);
    }
};

/// Adapted context for a `SlotKey` lookup whose hash the caller already has.
pub const PrehashedSlot = slot_hash.Prehashed(SlotKey.eql);

pub const SlotStore = struct {
    slots: Map,
    index: Index,
    allocator: std.mem.Allocator,
    /// True once a key has entered the store since it was created or last
    /// cleared. A store that is not dirty holds nothing and has no tombstones,
    /// so clearing it would only rewrite untouched hash-map metadata.
    dirty: bool = false,

    pub const Map = std.HashMap(SlotKey, u256, SlotKeyContext, std.hash_map.default_max_load_percentage);

    /// What the store holds for one address.
    const AccountSlots = struct {
        /// Every key held, zero-valued ones included, in the order they entered.
        keys: std.ArrayList(u256) = .empty,
        /// Number of held slots whose value is not zero.
        non_zero: usize = 0,
    };
    const Index = std.HashMap([20]u8, AccountSlots, AddressContext, std.hash_map.default_max_load_percentage);

    const AddressContext = struct {
        pub fn hash(_: @This(), address: [20]u8) u64 {
            return std.hash_map.hashString(&address);
        }
        pub fn eql(_: @This(), a: [20]u8, b: [20]u8) bool {
            return std.mem.eql(u8, &a, &b);
        }
    };

    pub fn init(allocator: std.mem.Allocator) SlotStore {
        return .{ .slots = Map.init(allocator), .index = Index.init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *SlotStore) void {
        self.freeKeyLists();
        self.index.deinit();
        self.slots.deinit();
    }

    fn freeKeyLists(self: *SlotStore) void {
        var accounts = self.index.valueIterator();
        while (accounts.next()) |account| account.keys.deinit(self.allocator);
    }

    /// Deep copy. The copy shares nothing with `self`.
    pub fn clone(self: *const SlotStore) std.mem.Allocator.Error!SlotStore {
        var copy = SlotStore.init(self.allocator);
        errdefer copy.deinit();
        copy.slots = try self.slots.clone();
        copy.dirty = self.dirty;
        try copy.index.ensureTotalCapacity(self.index.count());
        var accounts = self.index.iterator();
        while (accounts.next()) |entry| {
            const keys = try entry.value_ptr.keys.clone(self.allocator);
            copy.index.putAssumeCapacity(entry.key_ptr.*, .{ .keys = keys, .non_zero = entry.value_ptr.non_zero });
        }
        return copy;
    }

    /// Drop every slot. Slot capacity is kept; the index is freed. A store that
    /// no key has entered since the last clear is left untouched, in O(1).
    pub fn clearRetainingCapacity(self: *SlotStore) void {
        if (!self.dirty and self.slots.count() == 0 and self.index.count() == 0) return;
        self.slots.clearRetainingCapacity();
        self.freeKeyLists();
        self.index.clearRetainingCapacity();
        self.dirty = false;
    }

    /// The value held for `key`, or null when the store has no entry for it.
    pub fn get(self: *const SlotStore, key: SlotKey) ?u256 {
        return self.getHashed(key, key.hash());
    }

    /// `get` for a caller that already has `key.hash()`.
    pub fn getHashed(self: *const SlotStore, key: SlotKey, hash: u64) ?u256 {
        return self.slots.getAdapted(key, PrehashedSlot{ .value = hash });
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
    /// valid until a `put` adds a key for that address or a `restore` removes one;
    /// overwriting a key the store already holds leaves it valid.
    pub fn keysOf(self: *const SlotStore, address: [20]u8) []const u256 {
        const account = self.index.getPtr(address) orelse return &.{};
        return account.keys.items;
    }

    /// Number of slots held for `address` whose value is not zero.
    pub fn nonZeroCount(self: *const SlotStore, address: [20]u8) usize {
        const account = self.index.getPtr(address) orelse return 0;
        return account.non_zero;
    }

    /// Store `value` under `key` and return what the store held before (null:
    /// no entry). On error the store is unchanged.
    pub fn put(self: *SlotStore, key: SlotKey, value: u256) std.mem.Allocator.Error!?u256 {
        return self.putHashed(key, key.hash(), value);
    }

    /// `put` for a caller that already has `key.hash()`.
    pub fn putHashed(self: *SlotStore, key: SlotKey, hash: u64, value: u256) std.mem.Allocator.Error!?u256 {
        const prehashed = PrehashedSlot{ .value = hash };
        if (self.slots.getPtrAdapted(key, prehashed)) |held| {
            const previous = held.*;
            held.* = value;
            self.adjustNonZero(key.address, previous, value);
            return previous;
        }

        // A new key. Everything fallible runs before the first change. A failure
        // after the index entry is created leaves only an empty key list behind.
        self.dirty = true;
        const account = try self.index.getOrPut(key.address);
        if (!account.found_existing) account.value_ptr.* = .{};
        try account.value_ptr.keys.ensureUnusedCapacity(self.allocator, 1);
        const slot = try self.slots.getOrPutAdapted(key, prehashed);
        slot.key_ptr.* = key;
        slot.value_ptr.* = value;
        account.value_ptr.keys.appendAssumeCapacity(key.key);
        if (value != 0) account.value_ptr.non_zero += 1;
        return null;
    }

    /// Keep the per-address non-zero count exact for a held slot that changed
    /// from `before` to `after`. Reads the index only when zero-ness changed.
    fn adjustNonZero(self: *SlotStore, address: [20]u8, before: u256, after: u256) void {
        if ((before == 0) == (after == 0)) return;
        // Every held slot has an index entry: `putHashed` creates it first.
        const account = self.index.getPtr(address) orelse return;
        if (after != 0) {
            account.non_zero += 1;
        } else {
            account.non_zero -= 1;
        }
    }

    /// Undo a `put` of `key` that returned `previous`. See the module comment
    /// for why this cannot fail.
    pub fn restore(self: *SlotStore, key: SlotKey, previous: ?u256) void {
        // The `put` being undone created the index entry and nothing removes it.
        const account = self.index.getPtr(key.address) orelse return;
        const value = previous orelse {
            const removed = self.slots.fetchRemove(key) orelse return;
            if (removed.value != 0) account.non_zero -= 1;
            removeKey(&account.keys, key.key);
            return;
        };
        if (self.slots.getPtr(key)) |current| {
            const before = current.*;
            current.* = value;
            if (before == 0 and value != 0) account.non_zero += 1;
            if (before != 0 and value == 0) account.non_zero -= 1;
            return;
        }
        self.slots.putAssumeCapacity(key, value);
        account.keys.appendAssumeCapacity(key.key);
        if (value != 0) account.non_zero += 1;
    }

    /// Remove `key` from a key list. Writes are undone newest first, so the key
    /// is the last one; the scan covers any other order.
    fn removeKey(keys: *std.ArrayList(u256), key: u256) void {
        var index = keys.items.len;
        while (index > 0) {
            index -= 1;
            if (keys.items[index] != key) continue;
            _ = keys.swapRemove(index);
            return;
        }
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

test "SlotStore counts non-zero slots per address through put and restore" {
    var store = SlotStore.init(testing.allocator);
    defer store.deinit();
    const a = @as([20]u8, @splat(0xA1));
    const b = @as([20]u8, @splat(0xB2));
    const key = SlotKey{ .address = a, .key = 7 };

    try testing.expectEqual(@as(usize, 0), store.nonZeroCount(a));
    const first = try store.put(key, 5);
    try testing.expectEqual(@as(usize, 1), store.nonZeroCount(a));
    const second = try store.put(key, 6);
    try testing.expectEqual(@as(usize, 1), store.nonZeroCount(a));
    const third = try store.put(key, 0);
    try testing.expectEqual(@as(usize, 0), store.nonZeroCount(a));
    const zero_key = try store.put(.{ .address = a, .key = 8 }, 0);
    try testing.expectEqual(@as(usize, 0), store.nonZeroCount(a));
    _ = try store.put(.{ .address = b, .key = 7 }, 1);
    try testing.expectEqual(@as(usize, 1), store.nonZeroCount(b));

    store.restore(.{ .address = a, .key = 8 }, zero_key);
    try testing.expectEqual(@as(usize, 0), store.nonZeroCount(a));
    store.restore(key, third);
    try testing.expectEqual(@as(usize, 1), store.nonZeroCount(a));
    store.restore(key, second);
    try testing.expectEqual(@as(usize, 1), store.nonZeroCount(a));
    store.restore(key, first);
    try testing.expectEqual(@as(usize, 0), store.nonZeroCount(a));
    try testing.expectEqual(@as(usize, 0), store.keysOf(a).len);
    try testing.expectEqual(@as(usize, 1), store.nonZeroCount(b));
}

test "SlotStore overwrite of a held key never allocates" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var store = SlotStore.init(failing.allocator());
    defer store.deinit();
    const key = SlotKey{ .address = @as([20]u8, @splat(0xA1)), .key = 3 };
    _ = try store.put(key, 1);

    // Every allocation from here on fails; overwrites must still succeed.
    failing.fail_index = failing.alloc_index;
    const allocations = failing.allocations;
    var value: u256 = 0;
    while (value < 64) : (value += 1) {
        try testing.expectEqual(@as(?u256, if (value == 0) 1 else value - 1), try store.put(key, value));
    }
    try testing.expectEqual(allocations, failing.allocations);
    try testing.expectEqual(@as(usize, 1), store.nonZeroCount(key.address));
    try testing.expectEqualSlices(u256, &.{3}, store.keysOf(key.address));
}

test "SlotStore hashed and unhashed lookups agree" {
    var store = SlotStore.init(testing.allocator);
    defer store.deinit();
    var seed: u256 = 1;
    var n: usize = 0;
    while (n < 500) : (n += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        var address: [20]u8 = @splat(0);
        address[0] = @truncate(n % 7);
        const key = SlotKey{ .address = address, .key = seed << @intCast(n % 190) };
        _ = try store.putHashed(key, key.hash(), n + 1);
        try testing.expectEqual(@as(?u256, n + 1), store.get(key));
        try testing.expectEqual(@as(?u256, n + 1), store.getHashed(key, key.hash()));
    }
    try testing.expectEqual(@as(usize, 500), store.count());
}

test "SlotStore restore out of order still removes the right key" {
    var store = SlotStore.init(testing.allocator);
    defer store.deinit();
    const a = @as([20]u8, @splat(0xA1));
    const first = try store.put(.{ .address = a, .key = 1 }, 10);
    _ = try store.put(.{ .address = a, .key = 2 }, 20);
    store.restore(.{ .address = a, .key = 1 }, first);
    try testing.expectEqualSlices(u256, &.{2}, store.keysOf(a));
    try testing.expectEqual(@as(usize, 1), store.nonZeroCount(a));
    try testing.expectEqual(@as(?u256, 20), store.get(.{ .address = a, .key = 2 }));
}
