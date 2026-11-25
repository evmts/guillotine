//! State change tracking for transaction reverts.
//!
//! The journal records all state modifications during EVM execution,
//! enabling efficient rollback to previous states on transaction failure.
//! Uses a snapshot-based approach for nested call handling.

const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const JournalConfig = @import("journal_config.zig").JournalConfig;
const journal_entry = @import("journal_entry.zig");

/// Creates a configured journal type for state tracking.
pub fn Journal(comptime config: JournalConfig) type {
    config.validate();
    
    const Entry = journal_entry.JournalEntry(config);
    
    return struct {
        const Self = @This();
        
        pub const SnapshotIdType = config.SnapshotIdType;
        pub const WordType = config.WordType;
        pub const NonceType = config.NonceType;
        pub const EntryType = Entry;
        
        entries: std.ArrayList(Entry),
        /// `prefix_max.items[i]` is the highest snapshot ID among `entries.items[0..i + 1]`.
        /// It tells a revert in O(1) whether removing the tail of `entries` is enough.
        prefix_max: std.ArrayList(SnapshotIdType),
        /// First recorded value of each storage slot since the last `clear`, with the
        /// index of the entry that recorded it. Answers `get_original_storage` in O(1).
        original_storage: std.AutoHashMapUnmanaged(SlotKey, OriginalValue),
        next_snapshot_id: SnapshotIdType,
        allocator: std.mem.Allocator,

        const SlotKey = struct {
            address: [20]u8,
            slot: WordType,
        };

        const OriginalValue = struct {
            value: WordType,
            entry_index: usize,
        };

        /// Initialize a new journal with pre-allocated capacity
        pub fn init(allocator: std.mem.Allocator) !Self {
            var self = initEmpty(allocator);
            errdefer self.deinit();
            // Pre-allocate capacity for performance
            try self.entries.ensureTotalCapacity(allocator, config.initial_capacity);
            try self.prefix_max.ensureTotalCapacity(allocator, config.initial_capacity);
            return self;
        }

        /// Initialize a new journal without pre-allocation (will grow on demand)
        pub fn initEmpty(allocator: std.mem.Allocator) Self {
            return Self{
                .entries = std.ArrayList(Entry).empty,
                .prefix_max = std.ArrayList(SnapshotIdType).empty,
                .original_storage = .empty,
                .next_snapshot_id = 0,
                .allocator = allocator,
            };
        }

        /// Deinitialize the journal
        pub fn deinit(self: *Self) void {
            self.entries.deinit(self.allocator);
            self.prefix_max.deinit(self.allocator);
            self.original_storage.deinit(self.allocator);
        }

        /// Error returned when snapshot IDs are exhausted
        pub const Error = error{SnapshotIdExhausted};

        /// Create a new snapshot and return its ID
        pub fn create_snapshot(self: *Self) Error!SnapshotIdType {
            if (self.next_snapshot_id == std.math.maxInt(SnapshotIdType)) {
                return error.SnapshotIdExhausted;
            }
            const id = self.next_snapshot_id;
            self.next_snapshot_id += 1;
            return id;
        }

        /// True when `prefix_max` describes `entries`. Code that appends to `entries`
        /// directly leaves it behind; reverts then take the full scan.
        fn prefixMaxIsCurrent(self: *const Self) bool {
            return self.prefix_max.items.len == self.entries.items.len;
        }

        /// Revert all changes back to a specific snapshot
        /// Removes all entries with snapshot_id >= the given snapshot_id
        ///
        /// Nested calls append entries in snapshot order, so the entries to remove are
        /// the tail of the list and the cost is the number of entries removed. Entries
        /// recorded out of that order are found by a full scan.
        pub fn revert_to_snapshot(self: *Self, snapshot_id: SnapshotIdType) void {
            var new_len = self.entries.items.len;
            while (new_len > 0 and self.entries.items[new_len - 1].snapshot_id >= snapshot_id) new_len -= 1;

            const tail_is_everything = self.prefixMaxIsCurrent() and
                (new_len == 0 or self.prefix_max.items[new_len - 1] < snapshot_id);
            if (tail_is_everything) {
                self.forgetOriginalStorageFrom(new_len);
                self.entries.shrinkRetainingCapacity(new_len);
                self.prefix_max.shrinkRetainingCapacity(new_len);
                return;
            }

            // An entry to remove sits below one that stays: filter the whole list.
            const was_current = self.prefixMaxIsCurrent();
            var write_idx: usize = 0;
            for (self.entries.items) |entry| {
                if (entry.snapshot_id < snapshot_id) {
                    self.entries.items[write_idx] = entry;
                    write_idx += 1;
                }
            }
            self.entries.shrinkRetainingCapacity(write_idx);
            self.rebuildIndexes(was_current);
        }

        /// Drop the original-storage records made by entries at `new_len` and above.
        fn forgetOriginalStorageFrom(self: *Self, new_len: usize) void {
            for (self.entries.items[new_len..]) |entry| {
                switch (entry.data) {
                    .storage_change => |sc| {
                        const key = SlotKey{ .address = sc.address.bytes, .slot = sc.key };
                        const original = self.original_storage.get(key) orelse continue;
                        if (original.entry_index >= new_len) _ = self.original_storage.remove(key);
                    },
                    else => {},
                }
            }
        }

        /// Recompute `prefix_max` and `original_storage` after a filter moved entries.
        /// When the indexes described every entry before the filter, both already own
        /// enough capacity (fewer entries, a subset of the slots), so this cannot fail.
        /// Otherwise the indexes are emptied and lookups scan `entries`.
        fn rebuildIndexes(self: *Self, was_current: bool) void {
            self.prefix_max.clearRetainingCapacity();
            self.original_storage.clearRetainingCapacity();
            if (!was_current) return;
            var highest: SnapshotIdType = 0;
            for (self.entries.items, 0..) |entry, index| {
                highest = @max(highest, entry.snapshot_id);
                self.prefix_max.appendAssumeCapacity(highest);
                switch (entry.data) {
                    .storage_change => |sc| {
                        const slot = self.original_storage.getOrPutAssumeCapacity(.{ .address = sc.address.bytes, .slot = sc.key });
                        if (!slot.found_existing) slot.value_ptr.* = .{ .value = sc.original_value, .entry_index = index };
                    },
                    else => {},
                }
            }
        }

        /// Append one entry and keep `prefix_max` in step with `entries`.
        fn append(self: *Self, entry: Entry) !void {
            try self.entries.ensureUnusedCapacity(self.allocator, 1);
            try self.prefix_max.ensureUnusedCapacity(self.allocator, 1);
            self.appendAssumeCapacity(entry);
        }

        fn appendAssumeCapacity(self: *Self, entry: Entry) void {
            if (self.prefixMaxIsCurrent()) {
                const previous: SnapshotIdType = if (self.prefix_max.items.len == 0) 0 else self.prefix_max.items[self.prefix_max.items.len - 1];
                self.prefix_max.appendAssumeCapacity(@max(previous, entry.snapshot_id));
            }
            self.entries.appendAssumeCapacity(entry);
        }

        /// Record a storage change
        pub fn record_storage_change(self: *Self, snapshot_id: SnapshotIdType, address: Address, key: WordType, original_value: WordType) !void {
            try self.entries.ensureUnusedCapacity(self.allocator, 1);
            try self.prefix_max.ensureUnusedCapacity(self.allocator, 1);
            const slot = try self.original_storage.getOrPut(self.allocator, .{ .address = address.bytes, .slot = key });
            if (!slot.found_existing) slot.value_ptr.* = .{ .value = original_value, .entry_index = self.entries.items.len };
            self.appendAssumeCapacity(Entry.storage_change(snapshot_id, address, key, original_value));
        }

        /// Record a balance change
        pub fn record_balance_change(self: *Self, snapshot_id: SnapshotIdType, address: Address, original_balance: WordType) !void {
            try self.append(Entry.balance_change(snapshot_id, address, original_balance));
        }

        /// Record a nonce change
        pub fn record_nonce_change(self: *Self, snapshot_id: SnapshotIdType, address: Address, original_nonce: NonceType) !void {
            try self.append(Entry.nonce_change(snapshot_id, address, original_nonce));
        }

        /// Record a code change
        pub fn record_code_change(self: *Self, snapshot_id: SnapshotIdType, address: Address, original_code_hash: [32]u8) !void {
            try self.append(Entry.code_change(snapshot_id, address, original_code_hash));
        }

        /// Record account creation
        pub fn record_account_created(self: *Self, snapshot_id: SnapshotIdType, address: Address) !void {
            try self.append(Entry.account_created(snapshot_id, address));
        }

        /// Record account destruction
        pub fn record_account_destroyed(self: *Self, snapshot_id: SnapshotIdType, address: Address, beneficiary: Address, balance: WordType) !void {
            try self.append(Entry.account_destroyed(snapshot_id, address, beneficiary, balance));
        }

        /// Get the number of entries in the journal
        pub fn entry_count(self: *const Self) usize {
            return self.entries.items.len;
        }

        /// Clear all entries and reset snapshot counter. Called at the start of each
        /// transaction, which also resets the original-storage index.
        pub fn clear(self: *Self) void {
            self.entries.clearRetainingCapacity();
            self.prefix_max.clearRetainingCapacity();
            self.original_storage.clearRetainingCapacity();
            self.next_snapshot_id = 0;
        }

        /// Get original storage value from journal: the value the slot held before the
        /// oldest recorded change that is still in the journal. O(1).
        pub fn get_original_storage(self: *const Self, address: Address, slot: WordType) ?WordType {
            if (self.prefixMaxIsCurrent()) {
                const original = self.original_storage.get(.{ .address = address.bytes, .slot = slot }) orelse return null;
                return original.value;
            }
            // Entries appended directly to `entries` are not indexed: scan them.
            for (self.entries.items) |entry| {
                switch (entry.data) {
                    .storage_change => |sc| {
                        if (std.mem.eql(u8, &address.bytes, &sc.address.bytes) and sc.key == slot) {
                            return sc.original_value;
                        }
                    },
                    else => continue,
                }
            }
            return null;
        }

        /// Get original balance from journal (searches from oldest to newest)
        pub fn get_original_balance(self: *const Self, address: Address) ?WordType {
            for (self.entries.items) |entry| {
                switch (entry.data) {
                    .balance_change => |bc| {
                        if (std.mem.eql(u8, &address.bytes, &bc.address.bytes)) {
                            return bc.original_balance;
                        }
                    },
                    else => continue,
                }
            }
            return null;
        }
        
        /// Get entries for a specific snapshot
        pub fn get_snapshot_entries(self: *const Self, snapshot_id: SnapshotIdType, allocator: std.mem.Allocator) ![]Entry {
            var result = std.ArrayList(Entry).empty;
            for (self.entries.items) |entry| {
                if (entry.snapshot_id == snapshot_id) {
                    try result.append(allocator, entry);
                }
            }
            return try result.toOwnedSlice(allocator);
        }
    };
}

/// Default journal type
pub const DefaultJournal = Journal(.{});

test "Journal - basic operations" {
    const testing = std.testing;

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    try testing.expectEqual(@as(u64, 0), journal.next_snapshot_id);
    try testing.expectEqual(@as(usize, 0), journal.entry_count());

    // Create snapshots
    const snapshot1 = try journal.create_snapshot();
    const snapshot2 = try journal.create_snapshot();
    const snapshot3 = try journal.create_snapshot();

    try testing.expectEqual(@as(u32, 0), snapshot1);
    try testing.expectEqual(@as(u32, 1), snapshot2);
    try testing.expectEqual(@as(u32, 2), snapshot3);
    try testing.expectEqual(@as(u32, 3), journal.next_snapshot_id);
}

test "Journal - storage change recording" {
    const testing = std.testing;
    const zero_addr: Address = .{ .bytes = @as([20]u8, @splat(0)) };

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    const snapshot_id = try journal.create_snapshot();
    const key = 42;
    const original_value = 100;
    
    // Record storage change
    try journal.record_storage_change(snapshot_id, zero_addr, key, original_value);
    
    // Verify entry was recorded
    try testing.expectEqual(@as(usize, 1), journal.entry_count());
    const entry = journal.entries.items[0];
    try testing.expectEqual(snapshot_id, entry.snapshot_id);
    
    switch (entry.data) {
        .storage_change => |sc| {
            try testing.expectEqual(zero_addr, sc.address);
            try testing.expectEqual(key, sc.key);
            try testing.expectEqual(original_value, sc.original_value);
        },
        else => try testing.expect(false),
    }
    
    // Test get_original_storage
    const retrieved = journal.get_original_storage(zero_addr, key);
    try testing.expect(retrieved != null);
    try testing.expectEqual(original_value, retrieved.?);
    
    // Test non-existent storage
    const not_found = journal.get_original_storage(zero_addr, 999);
    try testing.expect(not_found == null);
}

test "Journal - revert to snapshot" {
    const testing = std.testing;
    const zero_addr: Address = .{ .bytes = @as([20]u8, @splat(0)) };

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    const snapshot1 = try journal.create_snapshot();
    const snapshot2 = try journal.create_snapshot();
    const snapshot3 = try journal.create_snapshot();
    
    // Add entries with different snapshot IDs
    try journal.record_storage_change(snapshot1, zero_addr, 1, 10);
    try journal.record_storage_change(snapshot1, zero_addr, 2, 20);
    try journal.record_storage_change(snapshot2, zero_addr, 3, 30);
    try journal.record_storage_change(snapshot3, zero_addr, 4, 40);
    
    try testing.expectEqual(@as(usize, 4), journal.entry_count());
    
    // Revert to snapshot2 - should remove entries with snapshot_id >= 2
    journal.revert_to_snapshot(snapshot2);
    
    try testing.expectEqual(@as(usize, 2), journal.entry_count());
    // Verify remaining entries are from snapshot1
    for (journal.entries.items) |entry| {
        try testing.expect(entry.snapshot_id < snapshot2);
    }
}

test "Journal - all entry types" {
    const testing = std.testing;
    const addr1: Address = .{ .bytes = @as([20]u8, @splat(1)) };
    const addr2: Address = .{ .bytes = @as([20]u8, @splat(2)) };
    const code_hash = @as([32]u8, @splat(0xAB));

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    const snapshot_id = try journal.create_snapshot();
    
    // Record different types of changes
    try journal.record_storage_change(snapshot_id, addr1, 1, 100);
    try journal.record_balance_change(snapshot_id, addr1, 1000);
    try journal.record_nonce_change(snapshot_id, addr1, 5);
    try journal.record_code_change(snapshot_id, addr1, code_hash);
    try journal.record_account_created(snapshot_id, addr2);
    try journal.record_account_destroyed(snapshot_id, addr1, addr2, 500);
    
    try testing.expectEqual(@as(usize, 6), journal.entry_count());
    
    // Verify each entry type
    var storage_found = false;
    var balance_found = false;
    var nonce_found = false;
    var code_found = false;
    var created_found = false;
    var destroyed_found = false;
    
    for (journal.entries.items) |entry| {
        switch (entry.data) {
            .storage_change => storage_found = true,
            .balance_change => balance_found = true,
            .nonce_change => nonce_found = true,
            .code_change => code_found = true,
            .account_created => created_found = true,
            .account_destroyed => destroyed_found = true,
        }
    }
    
    try testing.expect(storage_found);
    try testing.expect(balance_found);
    try testing.expect(nonce_found);
    try testing.expect(code_found);
    try testing.expect(created_found);
    try testing.expect(destroyed_found);
}

test "Journal - get_snapshot_entries" {
    const testing = std.testing;
    const addr: Address = .{ .bytes = @as([20]u8, @splat(0)) };

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    const snapshot1 = try journal.create_snapshot();
    const snapshot2 = try journal.create_snapshot();
    
    // Add entries for different snapshots
    try journal.record_storage_change(snapshot1, addr, 1, 10);
    try journal.record_storage_change(snapshot2, addr, 2, 20);
    try journal.record_storage_change(snapshot1, addr, 3, 30);
    try journal.record_storage_change(snapshot2, addr, 4, 40);
    
    // Get entries for snapshot1
    const snapshot1_entries = try journal.get_snapshot_entries(snapshot1, testing.allocator);
    defer testing.allocator.free(snapshot1_entries);
    
    try testing.expectEqual(@as(usize, 2), snapshot1_entries.len);
    for (snapshot1_entries) |entry| {
        try testing.expectEqual(snapshot1, entry.snapshot_id);
    }
    
    // Get entries for snapshot2
    const snapshot2_entries = try journal.get_snapshot_entries(snapshot2, testing.allocator);
    defer testing.allocator.free(snapshot2_entries);
    
    try testing.expectEqual(@as(usize, 2), snapshot2_entries.len);
    for (snapshot2_entries) |entry| {
        try testing.expectEqual(snapshot2, entry.snapshot_id);
    }
}

test "Journal - clear operation" {
    const testing = std.testing;
    const addr: Address = .{ .bytes = @as([20]u8, @splat(0)) };

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    // Add some entries
    const snapshot1 = try journal.create_snapshot();
    try journal.record_storage_change(snapshot1, addr, 1, 100);
    try journal.record_balance_change(snapshot1, addr, 1000);

    try testing.expectEqual(@as(usize, 2), journal.entry_count());
    try testing.expectEqual(@as(u32, 1), journal.next_snapshot_id);

    // Clear the journal
    journal.clear();

    try testing.expectEqual(@as(usize, 0), journal.entry_count());
    try testing.expectEqual(@as(u64, 0), journal.next_snapshot_id);

    // Should be able to use it again
    const snapshot2 = try journal.create_snapshot();
    try testing.expectEqual(@as(u32, 0), snapshot2);
}

test "Journal - minimal configuration" {
    const testing = std.testing;
    const MinimalJournal = Journal(.{
        .SnapshotIdType = u8,
        .WordType = u64,
        .NonceType = u16,
        .initial_capacity = 8,
    });

    var journal = try MinimalJournal.init(testing.allocator);
    defer journal.deinit();

    const addr: Address = .{ .bytes = @as([20]u8, @splat(0)) };

    // Test with minimal types
    const snapshot: u8 = try journal.create_snapshot();
    try journal.record_storage_change(snapshot, addr, std.math.maxInt(u64), 0);
    try journal.record_nonce_change(snapshot, addr, std.math.maxInt(u16));

    try testing.expectEqual(@as(usize, 2), journal.entry_count());

    // Test snapshot ID exhaustion - at 254, can still create snapshot
    journal.next_snapshot_id = 254;
    const snap_254 = try journal.create_snapshot();
    try testing.expectEqual(@as(u8, 254), snap_254);

    // At 255 (max), should error
    try testing.expectError(error.SnapshotIdExhausted, journal.create_snapshot());
}

test "Journal - get_original_balance" {
    const testing = std.testing;
    const addr1: Address = .{ .bytes = @as([20]u8, @splat(1)) };
    const addr2: Address = .{ .bytes = @as([20]u8, @splat(2)) };

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    const snapshot = try journal.create_snapshot();
    
    // Record balance changes
    try journal.record_balance_change(snapshot, addr1, 1000);
    try journal.record_balance_change(snapshot, addr2, 2000);
    
    // Test retrieval
    const balance1 = journal.get_original_balance(addr1);
    try testing.expect(balance1 != null);
    try testing.expectEqual(@as(u256, 1000), balance1.?);
    
    const balance2 = journal.get_original_balance(addr2);
    try testing.expect(balance2 != null);
    try testing.expectEqual(@as(u256, 2000), balance2.?);
    
    // Test non-existent address
    const addr3: Address = .{ .bytes = @as([20]u8, @splat(3)) };
    const balance3 = journal.get_original_balance(addr3);
    try testing.expect(balance3 == null);
}

test "Journal - memory efficiency" {
    const testing = std.testing;

    // Test that capacity pre-allocation works
    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    const initial_capacity = journal.entries.capacity;
    try testing.expect(initial_capacity >= 128); // Default initial_capacity

    // Add entries up to initial capacity
    const addr: Address = .{ .bytes = @as([20]u8, @splat(0)) };
    const snapshot = try journal.create_snapshot();
    
    var i: usize = 0;
    while (i < initial_capacity) : (i += 1) {
        try journal.record_storage_change(snapshot, addr, i, i * 10);
    }
    
    // Should not have reallocated yet
    try testing.expectEqual(initial_capacity, journal.entries.capacity);
}

test "Journal - complex revert scenario" {
    const testing = std.testing;
    const addr: Address = .{ .bytes = @as([20]u8, @splat(0)) };

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    // Create nested snapshots simulating nested calls
    const snapshot1 = try journal.create_snapshot(); // Outer call
    try journal.record_storage_change(snapshot1, addr, 1, 100);

    const snapshot2 = try journal.create_snapshot(); // Inner call 1
    try journal.record_storage_change(snapshot2, addr, 2, 200);
    try journal.record_balance_change(snapshot2, addr, 1000);

    const snapshot3 = try journal.create_snapshot(); // Inner call 2
    try journal.record_storage_change(snapshot3, addr, 3, 300);
    try journal.record_nonce_change(snapshot3, addr, 5);
    
    try testing.expectEqual(@as(usize, 5), journal.entry_count());
    
    // Revert inner call 2
    journal.revert_to_snapshot(snapshot3);
    try testing.expectEqual(@as(usize, 3), journal.entry_count());
    
    // Check that snapshot1 and snapshot2 entries remain
    const storage1 = journal.get_original_storage(addr, 1);
    try testing.expect(storage1 != null);
    try testing.expectEqual(@as(u256, 100), storage1.?);
    
    const storage2 = journal.get_original_storage(addr, 2);
    try testing.expect(storage2 != null);
    try testing.expectEqual(@as(u256, 200), storage2.?);
    
    // Snapshot3 entries should be gone
    const storage3 = journal.get_original_storage(addr, 3);
    try testing.expect(storage3 == null);
}

test "Journal - duplicate storage changes" {
    const testing = std.testing;
    const addr: Address = .{ .bytes = @as([20]u8, @splat(0)) };

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    const snapshot = try journal.create_snapshot();
    const slot = 42;
    
    // Record multiple changes to same storage slot
    try journal.record_storage_change(snapshot, addr, slot, 100);
    try journal.record_storage_change(snapshot, addr, slot, 200);
    try journal.record_storage_change(snapshot, addr, slot, 300);
    
    try testing.expectEqual(@as(usize, 3), journal.entry_count());
    
    // get_original_storage should return the FIRST (oldest) value
    const original = journal.get_original_storage(addr, slot);
    try testing.expect(original != null);
    try testing.expectEqual(@as(u256, 100), original.?);
}

test "Journal - multiple addresses same slot" {
    const testing = std.testing;
    const addr1: Address = .{ .bytes = @as([20]u8, @splat(1)) };
    const addr2: Address = .{ .bytes = @as([20]u8, @splat(2)) };
    const addr3: Address = .{ .bytes = @as([20]u8, @splat(3)) };

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    const snapshot = try journal.create_snapshot();
    const slot = 1;
    
    // Same slot, different addresses
    try journal.record_storage_change(snapshot, addr1, slot, 111);
    try journal.record_storage_change(snapshot, addr2, slot, 222);
    try journal.record_storage_change(snapshot, addr3, slot, 333);
    
    // Should return different values for each address
    const val1 = journal.get_original_storage(addr1, slot);
    const val2 = journal.get_original_storage(addr2, slot);
    const val3 = journal.get_original_storage(addr3, slot);
    
    try testing.expectEqual(@as(u256, 111), val1.?);
    try testing.expectEqual(@as(u256, 222), val2.?);
    try testing.expectEqual(@as(u256, 333), val3.?);
}

test "Journal - snapshot ID exhaustion returns error" {
    const testing = std.testing;
    const OverflowJournal = Journal(.{
        .SnapshotIdType = u8,
        .WordType = u256,
        .NonceType = u64,
        .initial_capacity = 16,
    });

    var journal = try OverflowJournal.init(testing.allocator);
    defer journal.deinit();

    // Set near max
    journal.next_snapshot_id = 254;

    const snapshot1 = try journal.create_snapshot(); // 254
    try testing.expectEqual(@as(u8, 254), snapshot1);

    // At max, should return error instead of saturating
    try testing.expectError(error.SnapshotIdExhausted, journal.create_snapshot());
}

test "Journal - snapshot ID uniqueness guaranteed" {
    const testing = std.testing;

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    // Set next_snapshot_id near max
    journal.next_snapshot_id = std.math.maxInt(u64) - 2;

    const snap1 = try journal.create_snapshot();
    const snap2 = try journal.create_snapshot();

    // Verify IDs are unique
    try testing.expect(snap1 != snap2);
    try testing.expectEqual(std.math.maxInt(u64) - 2, snap1);
    try testing.expectEqual(std.math.maxInt(u64) - 1, snap2);

    // At max, should return error
    try testing.expectError(error.SnapshotIdExhausted, journal.create_snapshot());
}

test "Journal - empty journal operations" {
    const testing = std.testing;
    const addr: Address = .{ .bytes = @as([20]u8, @splat(0)) };
    
    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();
    
    // Operations on empty journal
    try testing.expectEqual(@as(usize, 0), journal.entry_count());
    
    // Should return null for non-existent data
    try testing.expect(journal.get_original_storage(addr, 1) == null);
    try testing.expect(journal.get_original_balance(addr) == null);
    
    // Revert to non-existent snapshot should be no-op
    journal.revert_to_snapshot(999);
    try testing.expectEqual(@as(usize, 0), journal.entry_count());
    
    // Get entries for non-existent snapshot
    const entries = try journal.get_snapshot_entries(999, testing.allocator);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
    
    // Clear empty journal
    journal.clear();
    try testing.expectEqual(@as(usize, 0), journal.entry_count());
}

test "Journal - boundary value testing" {
    const testing = std.testing;
    const addr: Address = .{ .bytes = @as([20]u8, @splat(0xFF)) }; // Max address

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    const snapshot = try journal.create_snapshot();
    
    // Test boundary values
    const max_u256 = std.math.maxInt(u256);
    const max_u64 = std.math.maxInt(u64);
    
    try journal.record_storage_change(snapshot, addr, max_u256, 0);
    try journal.record_storage_change(snapshot, addr, 0, max_u256);
    try journal.record_balance_change(snapshot, addr, max_u256);
    try journal.record_nonce_change(snapshot, addr, max_u64);
    
    try testing.expectEqual(@as(usize, 4), journal.entry_count());
    
    // Verify boundary values
    const storage_max_key = journal.get_original_storage(addr, max_u256);
    try testing.expectEqual(@as(u256, 0), storage_max_key.?);
    
    const storage_max_val = journal.get_original_storage(addr, 0);
    try testing.expectEqual(max_u256, storage_max_val.?);
    
    const balance = journal.get_original_balance(addr);
    try testing.expectEqual(max_u256, balance.?);
}

test "Journal - account lifecycle tracking" {
    const testing = std.testing;
    const addr1: Address = .{ .bytes = @as([20]u8, @splat(1)) };
    const _unused_addr: Address = .{ .bytes = @as([20]u8, @splat(2)) };
    _ = _unused_addr;
    const beneficiary: Address = .{ .bytes = [_]u8{0xBE} ++ @as([19]u8, @splat(0)) };

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    const snapshot = try journal.create_snapshot();
    
    // Complete account lifecycle
    try journal.record_account_created(snapshot, addr1);
    try journal.record_balance_change(snapshot, addr1, 0); // Initial balance
    try journal.record_nonce_change(snapshot, addr1, 0); // Initial nonce
    
    // Modify account
    try journal.record_balance_change(snapshot, addr1, 1000);
    try journal.record_nonce_change(snapshot, addr1, 5);
    try journal.record_storage_change(snapshot, addr1, 1, 100);
    
    // Destroy account
    try journal.record_account_destroyed(snapshot, addr1, beneficiary, 1500);
    
    try testing.expectEqual(@as(usize, 7), journal.entry_count());
    
    // Verify we can find the original values (first occurrence)
    const original_balance = journal.get_original_balance(addr1);
    try testing.expectEqual(@as(u256, 0), original_balance.?); // First balance change
    
    const original_storage = journal.get_original_storage(addr1, 1);
    try testing.expectEqual(@as(u256, 100), original_storage.?);
}

test "Journal - interleaved snapshots" {
    const testing = std.testing;
    const addr: Address = .{ .bytes = @as([20]u8, @splat(0)) };

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    // Create snapshots in interleaved pattern
    const snap_a = try journal.create_snapshot(); // 0
    const snap_b = try journal.create_snapshot(); // 1
    const snap_c = try journal.create_snapshot(); // 2
    
    // Add entries in mixed order
    try journal.record_storage_change(snap_c, addr, 3, 300);
    try journal.record_storage_change(snap_a, addr, 1, 100);
    try journal.record_storage_change(snap_b, addr, 2, 200);
    try journal.record_storage_change(snap_c, addr, 4, 400);
    try journal.record_storage_change(snap_a, addr, 5, 500);
    
    try testing.expectEqual(@as(usize, 5), journal.entry_count());
    
    // Revert to snap_b (should remove entries with snapshot_id >= 1)
    journal.revert_to_snapshot(snap_b);
    
    // Should only have snap_a entries
    try testing.expectEqual(@as(usize, 2), journal.entry_count());
    
    for (journal.entries.items) |entry| {
        try testing.expect(entry.snapshot_id < snap_b);
    }
}

test "Journal - large scale operations" {
    const testing = std.testing;

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    const num_addresses = 100;
    const num_storage_slots = 50;

    // Create multiple snapshots
    const snapshot1 = try journal.create_snapshot();
    const snapshot2 = try journal.create_snapshot();
    
    // Record many changes
    for (0..num_addresses) |addr_idx| {
        var addr: Address = .{ .bytes = @as([20]u8, @splat(0)) };
        addr.bytes[19] = @intCast(addr_idx);
        
        const snapshot = if (addr_idx % 2 == 0) snapshot1 else snapshot2;
        
        try journal.record_balance_change(snapshot, addr, addr_idx * 1000);
        try journal.record_nonce_change(snapshot, addr, @intCast(addr_idx));
        
        for (0..num_storage_slots) |slot| {
            try journal.record_storage_change(snapshot, addr, slot, addr_idx * 100 + slot);
        }
    }
    
    const expected_entries = num_addresses * (2 + num_storage_slots); // balance + nonce + storage
    try testing.expectEqual(expected_entries, journal.entry_count());
    
    // Test retrieval of some values
    const addr_0: Address = .{ .bytes = @as([20]u8, @splat(0)) };
    var addr_99: Address = .{ .bytes = @as([20]u8, @splat(0)) };
    addr_99.bytes[19] = 99;
    
    const balance_0 = journal.get_original_balance(addr_0);
    try testing.expectEqual(@as(u256, 0), balance_0.?);
    
    const storage_99_10 = journal.get_original_storage(addr_99, 10);
    try testing.expectEqual(@as(u256, 99 * 100 + 10), storage_99_10.?);
    
    // Revert to snapshot2 (remove snapshot1 entries)
    journal.revert_to_snapshot(snapshot2);
    
    // Should have roughly half the entries
    const remaining = journal.entry_count();
    try testing.expect(remaining < expected_entries);
    try testing.expect(remaining > 0);
}

test "Journal - zero value storage" {
    const testing = std.testing;
    const addr: Address = .{ .bytes = @as([20]u8, @splat(0)) };

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    const snapshot = try journal.create_snapshot();
    
    // Record storage changes with zero values
    try journal.record_storage_change(snapshot, addr, 1, 0);
    try journal.record_storage_change(snapshot, addr, 0, 42); // Zero key
    try journal.record_balance_change(snapshot, addr, 0); // Zero balance
    
    // Should still be able to retrieve zero values
    const storage_1 = journal.get_original_storage(addr, 1);
    try testing.expectEqual(@as(u256, 0), storage_1.?);
    
    const storage_0 = journal.get_original_storage(addr, 0);
    try testing.expectEqual(@as(u256, 42), storage_0.?);
    
    const balance = journal.get_original_balance(addr);
    try testing.expectEqual(@as(u256, 0), balance.?);
}

test "Journal - address comparison edge cases" {
    const testing = std.testing;

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    const snapshot = try journal.create_snapshot();
    
    // Very similar addresses
    var addr1: Address = .{ .bytes = @as([20]u8, @splat(0)) };
    var addr2: Address = .{ .bytes = @as([20]u8, @splat(0)) };
    addr1.bytes[0] = 1;
    addr2.bytes[0] = 2;
    
    // Another pair differing in last byte
    var addr3: Address = .{ .bytes = @as([20]u8, @splat(0xFF)) };
    var addr4: Address = .{ .bytes = @as([20]u8, @splat(0xFF)) };
    addr3.bytes[19] = 0xFE;
    addr4.bytes[19] = 0xFF;
    
    try journal.record_storage_change(snapshot, addr1, 1, 11);
    try journal.record_storage_change(snapshot, addr2, 1, 22);
    try journal.record_balance_change(snapshot, addr3, 33);
    try journal.record_balance_change(snapshot, addr4, 44);
    
    // Should correctly distinguish between addresses
    try testing.expectEqual(@as(u256, 11), journal.get_original_storage(addr1, 1).?);
    try testing.expectEqual(@as(u256, 22), journal.get_original_storage(addr2, 1).?);
    try testing.expect(journal.get_original_storage(addr3, 1) == null);
    try testing.expect(journal.get_original_storage(addr4, 1) == null);
    
    try testing.expectEqual(@as(u256, 33), journal.get_original_balance(addr3).?);
    try testing.expectEqual(@as(u256, 44), journal.get_original_balance(addr4).?);
    try testing.expect(journal.get_original_balance(addr1) == null);
    try testing.expect(journal.get_original_balance(addr2) == null);
}

test "Journal - custom configuration comprehensive" {
    const testing = std.testing;

    const CustomJournal = Journal(.{
        .SnapshotIdType = u16,
        .WordType = u128,
        .NonceType = u32,
        .initial_capacity = 64,
    });

    var journal = try CustomJournal.init(testing.allocator);
    defer journal.deinit();

    const addr: Address = .{ .bytes = @as([20]u8, @splat(0)) };

    // Test custom types
    const snapshot: u16 = try journal.create_snapshot();
    try journal.record_storage_change(snapshot, addr, std.math.maxInt(u128), 0);
    try journal.record_nonce_change(snapshot, addr, std.math.maxInt(u32));
    try journal.record_balance_change(snapshot, addr, std.math.maxInt(u128));
    
    // Verify types work correctly
    const storage = journal.get_original_storage(addr, std.math.maxInt(u128));
    try testing.expectEqual(@as(u128, 0), storage.?);
    
    const balance = journal.get_original_balance(addr);
    try testing.expectEqual(std.math.maxInt(u128), balance.?);
    
    // Test custom snapshot ID type
    try testing.expectEqual(@as(u16, 1), journal.next_snapshot_id);
}

test "Journal - memory management stress" {
    const testing = std.testing;

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    // Create many snapshots and entries, then revert
    const num_cycles = 10;
    const entries_per_cycle = 50;

    var snapshots = std.array_list.AlignedManaged(DefaultJournal.SnapshotIdType, null).init(testing.allocator);
    defer snapshots.deinit();

    // Create and populate snapshots
    for (0..num_cycles) |cycle| {
        const snapshot = try journal.create_snapshot();
        try snapshots.append(snapshot);
        
        var addr: Address = .{ .bytes = @as([20]u8, @splat(0)) };
        addr.bytes[19] = @intCast(cycle);
        
        for (0..entries_per_cycle) |entry_idx| {
            try journal.record_storage_change(snapshot, addr, entry_idx, cycle * 1000 + entry_idx);
        }
    }
    
    const peak_entries = journal.entry_count();
    try testing.expectEqual(num_cycles * entries_per_cycle, peak_entries);
    
    // Revert half the snapshots
    const mid_snapshot = snapshots.items[num_cycles / 2];
    journal.revert_to_snapshot(mid_snapshot);
    
    const remaining_entries = journal.entry_count();
    try testing.expect(remaining_entries < peak_entries);
    try testing.expect(remaining_entries > 0);
    
    // Memory should be efficiently managed
    const capacity_after_revert = journal.entries.capacity;
    try testing.expect(capacity_after_revert >= remaining_entries);
}

test "Journal - entry ordering preservation" {
    const testing = std.testing;
    const addr: Address = .{ .bytes = @as([20]u8, @splat(0)) };

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    // Create single snapshot but add entries over time
    const snapshot = try journal.create_snapshot();
    
    const operations = [_]struct { key: u256, value: u256 }{
        .{ .key = 1, .value = 100 },
        .{ .key = 2, .value = 200 },
        .{ .key = 3, .value = 300 },
        .{ .key = 1, .value = 150 }, // Update to slot 1
        .{ .key = 4, .value = 400 },
    };
    
    for (operations) |op| {
        try journal.record_storage_change(snapshot, addr, op.key, op.value);
    }
    
    // First occurrence should be returned for get_original_storage
    try testing.expectEqual(@as(u256, 100), journal.get_original_storage(addr, 1).?); // First value
    try testing.expectEqual(@as(u256, 200), journal.get_original_storage(addr, 2).?);
    try testing.expectEqual(@as(u256, 300), journal.get_original_storage(addr, 3).?);
    try testing.expectEqual(@as(u256, 400), journal.get_original_storage(addr, 4).?);
    
    // Verify entries maintain insertion order
    try testing.expectEqual(@as(usize, 5), journal.entry_count());
    
    const expected_values = [_]u256{ 100, 200, 300, 150, 400 };
    for (journal.entries.items, 0..) |entry, i| {
        switch (entry.data) {
            .storage_change => |sc| {
                try testing.expectEqual(expected_values[i], sc.original_value);
            },
            else => unreachable,
        }
    }
}

test "Journal - get_original_storage is indexed and follows reverts" {
    const testing = std.testing;
    const addr: Address = .{ .bytes = @as([20]u8, @splat(7)) };

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    const outer = try journal.create_snapshot();
    try journal.record_storage_change(outer, addr, 1, 100);
    const inner = try journal.create_snapshot();
    // A second write to the same slot keeps the first original value.
    try journal.record_storage_change(inner, addr, 1, 200);
    try journal.record_storage_change(inner, addr, 2, 300);
    try testing.expectEqual(@as(?u256, 100), journal.get_original_storage(addr, 1));
    try testing.expectEqual(@as(?u256, 300), journal.get_original_storage(addr, 2));

    journal.revert_to_snapshot(inner);
    try testing.expectEqual(@as(usize, 1), journal.entry_count());
    try testing.expectEqual(@as(?u256, 100), journal.get_original_storage(addr, 1));
    try testing.expectEqual(@as(?u256, null), journal.get_original_storage(addr, 2));

    journal.revert_to_snapshot(outer);
    try testing.expectEqual(@as(?u256, null), journal.get_original_storage(addr, 1));

    // `clear` starts a new transaction: nothing recorded earlier is visible.
    try journal.record_storage_change(outer, addr, 1, 5);
    journal.clear();
    try testing.expectEqual(@as(?u256, null), journal.get_original_storage(addr, 1));
    try testing.expectEqual(@as(usize, 0), journal.original_storage.count());
}

test "Journal - revert removes hidden entries recorded out of snapshot order" {
    const testing = std.testing;
    const addr: Address = .{ .bytes = @as([20]u8, @splat(8)) };

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    const s1 = try journal.create_snapshot();
    const s2 = try journal.create_snapshot();
    try journal.record_storage_change(s2, addr, 1, 10);
    try journal.record_storage_change(s1, addr, 2, 20);
    try journal.record_storage_change(s2, addr, 3, 30);
    try journal.record_storage_change(s1, addr, 4, 40);

    journal.revert_to_snapshot(s2);
    try testing.expectEqual(@as(usize, 2), journal.entry_count());
    try testing.expectEqual(@as(?u256, null), journal.get_original_storage(addr, 1));
    try testing.expectEqual(@as(?u256, 20), journal.get_original_storage(addr, 2));
    try testing.expectEqual(@as(?u256, null), journal.get_original_storage(addr, 3));
    try testing.expectEqual(@as(?u256, 40), journal.get_original_storage(addr, 4));
}

test "Journal - nested call order reverts by truncating the tail" {
    const testing = std.testing;
    const addr: Address = .{ .bytes = @as([20]u8, @splat(9)) };

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    // A(0) calls B(1), which succeeds; A writes; A calls C(2), which calls D(3);
    // D succeeds, C writes, then C reverts.
    const a = try journal.create_snapshot();
    const b = try journal.create_snapshot();
    try journal.record_storage_change(b, addr, 1, 1);
    try journal.record_storage_change(a, addr, 2, 2);
    const c = try journal.create_snapshot();
    const d = try journal.create_snapshot();
    try journal.record_storage_change(d, addr, 3, 3);
    try journal.record_storage_change(c, addr, 4, 4);

    journal.revert_to_snapshot(c);
    try testing.expectEqual(@as(usize, 2), journal.entry_count());
    try testing.expectEqual(@as(usize, 2), journal.prefix_max.items.len);
    try testing.expectEqual(@as(?u256, 1), journal.get_original_storage(addr, 1));
    try testing.expectEqual(@as(?u256, 2), journal.get_original_storage(addr, 2));
    try testing.expectEqual(@as(?u256, null), journal.get_original_storage(addr, 3));
    try testing.expectEqual(@as(?u256, null), journal.get_original_storage(addr, 4));
}

test "Journal - snapshot IDs are u64 and do not exhaust at 65,535" {
    const testing = std.testing;

    var journal = try DefaultJournal.init(testing.allocator);
    defer journal.deinit();

    try testing.expectEqual(u64, DefaultJournal.SnapshotIdType);
    var i: u32 = 0;
    while (i < 70_000) : (i += 1) _ = try journal.create_snapshot();
    try testing.expectEqual(@as(u64, 70_000), journal.next_snapshot_id);
}
