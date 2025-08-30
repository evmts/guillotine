//! State change tracking for transaction reverts.
//!
//! The journal records all state modifications during EVM execution,
//! enabling efficient rollback to previous states on transaction failure.
//! Uses a snapshot-based approach for nested call handling.

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
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
        next_snapshot_id: SnapshotIdType,
        allocator: std.mem.Allocator,
        
        /// Initialize a new journal
        pub fn init(allocator: std.mem.Allocator) Self {
            var entries = std.ArrayList(Entry){};
            entries.ensureTotalCapacity(allocator, config.initial_capacity) catch {}; // Best effort
            
            return Self{
                .entries = entries,
                .next_snapshot_id = 0,
                .allocator = allocator,
            };
        }
        
        /// Deinitialize the journal
        pub fn deinit(self: *Self) void {
            self.entries.deinit(self.allocator);
        }
        
        /// Create a new snapshot and return its ID
        pub fn create_snapshot(self: *Self) SnapshotIdType {
            const id = self.next_snapshot_id;
            self.next_snapshot_id += 1;
            return id;
        }
        
        /// Revert all changes back to a specific snapshot
        pub fn revert_to_snapshot(self: *Self, snapshot_id: SnapshotIdType) void {
            var i = self.entries.items.len;
            while (i > 0) : (i -= 1) {
                if (self.entries.items[i - 1].snapshot_id < snapshot_id) {
                    break;
                }
            }
            self.entries.shrinkRetainingCapacity(i);
        }
        
        /// Record a storage change
        pub fn record_storage_change(self: *Self, snapshot_id: SnapshotIdType, address: Address, key: WordType, original_value: WordType) !void {
            try self.entries.append(self.allocator, Entry.storage_change(snapshot_id, address, key, original_value));
        }
        
        /// Record a balance change
        pub fn record_balance_change(self: *Self, snapshot_id: SnapshotIdType, address: Address, original_balance: WordType) !void {
            try self.entries.append(self.allocator, Entry.balance_change(snapshot_id, address, original_balance));
        }
        
        /// Record a nonce change
        pub fn record_nonce_change(self: *Self, snapshot_id: SnapshotIdType, address: Address, original_nonce: NonceType) !void {
            try self.entries.append(self.allocator, Entry.nonce_change(snapshot_id, address, original_nonce));
        }
        
        /// Record a code change
        pub fn record_code_change(self: *Self, snapshot_id: SnapshotIdType, address: Address, original_code_hash: [32]u8) !void {
            try self.entries.append(self.allocator, Entry.code_change(snapshot_id, address, original_code_hash));
        }
        
        /// Record account creation
        pub fn record_account_created(self: *Self, snapshot_id: SnapshotIdType, address: Address) !void {
            try self.entries.append(self.allocator, Entry.account_created(snapshot_id, address));
        }
        
        /// Record account destruction
        pub fn record_account_destroyed(self: *Self, snapshot_id: SnapshotIdType, address: Address, beneficiary: Address, balance: WordType) !void {
            try self.entries.append(self.allocator, Entry.account_destroyed(snapshot_id, address, beneficiary, balance));
        }
        
        /// Get the number of entries in the journal
        pub fn entry_count(self: *const Self) usize {
            return self.entries.items.len;
        }
        
        /// Clear all entries and reset snapshot counter
        pub fn clear(self: *Self) void {
            self.entries.clearRetainingCapacity();
            self.next_snapshot_id = 0;
        }
        
        /// Get original storage value from journal (searches backwards)
        pub fn get_original_storage(self: *const Self, address: Address, slot: WordType) ?WordType {
            var i = self.entries.items.len;
            while (i > 0) : (i -= 1) {
                const entry = self.entries.items[i - 1];
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
        
        /// Get original balance from journal
        pub fn get_original_balance(self: *const Self, address: Address) ?WordType {
            var i = self.entries.items.len;
            while (i > 0) : (i -= 1) {
                const entry = self.entries.items[i - 1];
                switch (entry.data) {
                    .balance_change => |bc| {
                        if (std.mem.eql(u8, &address, &bc.address)) {
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
            var result = std.ArrayList(Entry).init(allocator);
            for (self.entries.items) |entry| {
                if (entry.snapshot_id == snapshot_id) {
                    try result.append(entry);
                }
            }
            return result.toOwnedSlice();
        }
    };
}

/// Default journal type
pub const DefaultJournal = Journal(.{});

test "Journal - basic operations" {
    const testing = std.testing;
    
    var journal = DefaultJournal.init(testing.allocator);
    defer journal.deinit();
    
    try testing.expectEqual(@as(u32, 0), journal.next_snapshot_id);
    try testing.expectEqual(@as(usize, 0), journal.entry_count());
    
    // Create snapshots
    const snapshot1 = journal.create_snapshot();
    const snapshot2 = journal.create_snapshot();
    const snapshot3 = journal.create_snapshot();
    
    try testing.expectEqual(@as(u32, 0), snapshot1);
    try testing.expectEqual(@as(u32, 1), snapshot2);
    try testing.expectEqual(@as(u32, 2), snapshot3);
    try testing.expectEqual(@as(u32, 3), journal.next_snapshot_id);
}

test "Journal - storage change recording" {
    const testing = std.testing;
    const zero_addr = [_]u8{0} ** 20;
    
    var journal = DefaultJournal.init(testing.allocator);
    defer journal.deinit();
    
    const snapshot_id = journal.create_snapshot();
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
    const zero_addr = [_]u8{0} ** 20;
    
    var journal = DefaultJournal.init(testing.allocator);
    defer journal.deinit();
    
    const snapshot1 = journal.create_snapshot();
    const snapshot2 = journal.create_snapshot();
    const snapshot3 = journal.create_snapshot();
    
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
    const addr1 = [_]u8{1} ** 20;
    const addr2 = [_]u8{2} ** 20;
    const code_hash = [_]u8{0xAB} ** 32;
    
    var journal = DefaultJournal.init(testing.allocator);
    defer journal.deinit();
    
    const snapshot_id = journal.create_snapshot();
    
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
    const addr = [_]u8{0} ** 20;
    
    var journal = DefaultJournal.init(testing.allocator);
    defer journal.deinit();
    
    const snapshot1 = journal.create_snapshot();
    const snapshot2 = journal.create_snapshot();
    
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
    const addr = [_]u8{0} ** 20;
    
    var journal = DefaultJournal.init(testing.allocator);
    defer journal.deinit();
    
    // Add some entries
    const snapshot1 = journal.create_snapshot();
    try journal.record_storage_change(snapshot1, addr, 1, 100);
    try journal.record_balance_change(snapshot1, addr, 1000);
    
    try testing.expectEqual(@as(usize, 2), journal.entry_count());
    try testing.expectEqual(@as(u32, 1), journal.next_snapshot_id);
    
    // Clear the journal
    journal.clear();
    
    try testing.expectEqual(@as(usize, 0), journal.entry_count());
    try testing.expectEqual(@as(u32, 0), journal.next_snapshot_id);
    
    // Should be able to use it again
    const snapshot2 = journal.create_snapshot();
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
    
    var journal = MinimalJournal.init(testing.allocator);
    defer journal.deinit();
    
    const addr = [_]u8{0} ** 20;
    
    // Test with minimal types
    const snapshot: u8 = journal.create_snapshot();
    try journal.record_storage_change(snapshot, addr, std.math.maxInt(u64), 0);
    try journal.record_nonce_change(snapshot, addr, std.math.maxInt(u16));
    
    try testing.expectEqual(@as(usize, 2), journal.entry_count());
    
    // Test snapshot ID overflow protection
    journal.next_snapshot_id = 255;
    const last_snapshot = journal.create_snapshot();
    try testing.expectEqual(@as(u8, 255), last_snapshot);
    // Next create_snapshot would overflow - in real usage this should be checked
}

test "Journal - get_original_balance" {
    const testing = std.testing;
    const addr1 = [_]u8{1} ** 20;
    const addr2 = [_]u8{2} ** 20;
    
    var journal = DefaultJournal.init(testing.allocator);
    defer journal.deinit();
    
    const snapshot = journal.create_snapshot();
    
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
    const addr3 = [_]u8{3} ** 20;
    const balance3 = journal.get_original_balance(addr3);
    try testing.expect(balance3 == null);
}

test "Journal - memory efficiency" {
    const testing = std.testing;
    
    // Test that capacity pre-allocation works
    var journal = DefaultJournal.init(testing.allocator);
    defer journal.deinit();
    
    const initial_capacity = journal.entries.capacity;
    try testing.expect(initial_capacity >= 128); // Default initial_capacity
    
    // Add entries up to initial capacity
    const addr = [_]u8{0} ** 20;
    const snapshot = journal.create_snapshot();
    
    var i: usize = 0;
    while (i < initial_capacity) : (i += 1) {
        try journal.record_storage_change(snapshot, addr, i, i * 10);
    }
    
    // Should not have reallocated yet
    try testing.expectEqual(initial_capacity, journal.entries.capacity);
}

test "Journal - complex revert scenario" {
    const testing = std.testing;
    const addr = [_]u8{0} ** 20;
    
    var journal = DefaultJournal.init(testing.allocator);
    defer journal.deinit();
    
    // Create nested snapshots simulating nested calls
    const snapshot1 = journal.create_snapshot(); // Outer call
    try journal.record_storage_change(snapshot1, addr, 1, 100);
    
    const snapshot2 = journal.create_snapshot(); // Inner call 1
    try journal.record_storage_change(snapshot2, addr, 2, 200);
    try journal.record_balance_change(snapshot2, addr, 1000);
    
    const snapshot3 = journal.create_snapshot(); // Inner call 2
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
    const addr = [_]u8{0} ** 20;
    
    var journal = DefaultJournal.init(testing.allocator);
    defer journal.deinit();
    
    const snapshot = journal.create_snapshot();
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
    const addr1 = [_]u8{1} ** 20;
    const addr2 = [_]u8{2} ** 20;
    const addr3 = [_]u8{3} ** 20;
    
    var journal = DefaultJournal.init(testing.allocator);
    defer journal.deinit();
    
    const snapshot = journal.create_snapshot();
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

test "Journal - snapshot ID overflow behavior" {
    const testing = std.testing;
    const OverflowJournal = Journal(.{
        .SnapshotIdType = u8,
        .WordType = u256,
        .NonceType = u64,
        .initial_capacity = 16,
    });
    
    var journal = OverflowJournal.init(testing.allocator);
    defer journal.deinit();
    
    // Set near overflow
    journal.next_snapshot_id = 254;
    
    const snapshot1 = journal.create_snapshot(); // 254
    const snapshot2 = journal.create_snapshot(); // 255
    const snapshot3 = journal.create_snapshot(); // 0 (wraps around)
    
    try testing.expectEqual(@as(u8, 254), snapshot1);
    try testing.expectEqual(@as(u8, 255), snapshot2);
    try testing.expectEqual(@as(u8, 0), snapshot3); // Wrapped
}

test "Journal - empty journal operations" {
    const testing = std.testing;
    const addr = [_]u8{0} ** 20;
    
    var journal = DefaultJournal.init(testing.allocator);
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
    const addr = [_]u8{0xFF} ** 20; // Max address
    
    var journal = DefaultJournal.init(testing.allocator);
    defer journal.deinit();
    
    const snapshot = journal.create_snapshot();
    
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
    const addr1 = [_]u8{1} ** 20;
    _ = [_]u8{2} ** 20;
    const beneficiary = [_]u8{0xBE} ++ [_]u8{0} ** 19;
    
    var journal = DefaultJournal.init(testing.allocator);
    defer journal.deinit();
    
    const snapshot = journal.create_snapshot();
    
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
    const addr = [_]u8{0} ** 20;
    
    var journal = DefaultJournal.init(testing.allocator);
    defer journal.deinit();
    
    // Create snapshots in interleaved pattern
    const snap_a = journal.create_snapshot(); // 0
    const snap_b = journal.create_snapshot(); // 1
    const snap_c = journal.create_snapshot(); // 2
    
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
    
    var journal = DefaultJournal.init(testing.allocator);
    defer journal.deinit();
    
    const num_addresses = 100;
    const num_storage_slots = 50;
    
    // Create multiple snapshots
    const snapshot1 = journal.create_snapshot();
    const snapshot2 = journal.create_snapshot();
    
    // Record many changes
    for (0..num_addresses) |addr_idx| {
        var addr: [20]u8 = [_]u8{0} ** 20;
        addr[19] = @intCast(addr_idx);
        
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
    const addr_0: [20]u8 = [_]u8{0} ** 20;
    var addr_99: [20]u8 = [_]u8{0} ** 20;
    addr_99[19] = 99;
    
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
    const addr = [_]u8{0} ** 20;
    
    var journal = DefaultJournal.init(testing.allocator);
    defer journal.deinit();
    
    const snapshot = journal.create_snapshot();
    
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
    
    var journal = DefaultJournal.init(testing.allocator);
    defer journal.deinit();
    
    const snapshot = journal.create_snapshot();
    
    // Very similar addresses
    var addr1: [20]u8 = [_]u8{0} ** 20;
    var addr2: [20]u8 = [_]u8{0} ** 20;
    addr1[0] = 1;
    addr2[0] = 2;
    
    // Another pair differing in last byte
    var addr3: [20]u8 = [_]u8{0xFF} ** 20;
    var addr4: [20]u8 = [_]u8{0xFF} ** 20;
    addr3[19] = 0xFE;
    addr4[19] = 0xFF;
    
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
    
    var journal = CustomJournal.init(testing.allocator);
    defer journal.deinit();
    
    const addr = [_]u8{0} ** 20;
    
    // Test custom types
    const snapshot: u16 = journal.create_snapshot();
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
    
    var journal = DefaultJournal.init(testing.allocator);
    defer journal.deinit();
    
    // Create many snapshots and entries, then revert
    const num_cycles = 10;
    const entries_per_cycle = 50;
    
    var snapshots = std.ArrayList(u32).init(testing.allocator);
    defer snapshots.deinit();
    
    // Create and populate snapshots
    for (0..num_cycles) |cycle| {
        const snapshot = journal.create_snapshot();
        try snapshots.append(snapshot);
        
        var addr: [20]u8 = [_]u8{0} ** 20;
        addr[19] = @intCast(cycle);
        
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
    const addr = [_]u8{0} ** 20;
    
    var journal = DefaultJournal.init(testing.allocator);
    defer journal.deinit();
    
    // Create single snapshot but add entries over time
    const snapshot = journal.create_snapshot();
    
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