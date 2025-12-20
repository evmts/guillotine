const std = @import("std");
const testing = std.testing;
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const Journal = @import("journal.zig").Journal;
const JournalConfig = @import("journal_config.zig").JournalConfig;

test "Journal snapshot - sequential ID generation" {
    var journal = Journal(.{}).init(testing.allocator);
    defer journal.deinit();
    
    try testing.expectEqual(@as(u32, 0), journal.next_snapshot_id);
    
    const snapshot1 = journal.create_snapshot();
    const snapshot2 = journal.create_snapshot();
    const snapshot3 = journal.create_snapshot();
    
    try testing.expectEqual(@as(u32, 0), snapshot1);
    try testing.expectEqual(@as(u32, 1), snapshot2);
    try testing.expectEqual(@as(u32, 2), snapshot3);
    try testing.expectEqual(@as(u32, 3), journal.next_snapshot_id);
}

test "Journal snapshot - creation with different ID types" {
    // Test with u8 snapshot IDs
    var journal_u8 = Journal(.{ .SnapshotIdType = u8 }).init(testing.allocator);
    defer journal_u8.deinit();
    
    var count: u8 = 0;
    while (count < 255) {
        const snapshot = journal_u8.create_snapshot();
        try testing.expectEqual(count, snapshot);
        count += 1;
    }
    try testing.expectEqual(@as(u8, 255), journal_u8.next_snapshot_id);
    
    // Test with u64 snapshot IDs
    var journal_u64 = Journal(.{ .SnapshotIdType = u64 }).init(testing.allocator);
    defer journal_u64.deinit();
    
    journal_u64.next_snapshot_id = std.math.maxInt(u64) - 1;
    const large_snapshot = journal_u64.create_snapshot();
    try testing.expectEqual(std.math.maxInt(u64) - 1, large_snapshot);
    try testing.expectEqual(std.math.maxInt(u64), journal_u64.next_snapshot_id);
}

test "Journal snapshot - basic revert to snapshot" {
    const addr1 = [_]u8{1} ** 20;
    const addr2 = [_]u8{2} ** 20;
    
    var journal = Journal(.{}).init(testing.allocator);
    defer journal.deinit();
    
    // Create snapshots
    const snapshot0 = journal.create_snapshot();
    const snapshot1 = journal.create_snapshot();
    const snapshot2 = journal.create_snapshot();
    
    // Add entries across different snapshots
    try journal.record_storage_change(snapshot0, addr1, 1, 100);
    try journal.record_balance_change(snapshot0, addr1, 1000);
    
    try journal.record_storage_change(snapshot1, addr1, 2, 200);
    try journal.record_nonce_change(snapshot1, addr2, 5);
    
    try journal.record_storage_change(snapshot2, addr1, 3, 300);
    try journal.record_code_change(snapshot2, addr2, [_]u8{0xAB} ** 32);
    
    try testing.expectEqual(@as(usize, 6), journal.entry_count());
    
    // Revert to snapshot1 - should remove entries with snapshot_id >= 1
    journal.revert_to_snapshot(snapshot1);
    
    try testing.expectEqual(@as(usize, 2), journal.entry_count());
    
    // Verify only snapshot0 entries remain
    for (journal.entries.items) |entry| {
        try testing.expect(entry.snapshot_id < snapshot1);
    }
    
    // Verify data integrity of remaining entries
    const storage_value = journal.get_original_storage(addr1, 1);
    try testing.expect(storage_value != null);
    try testing.expectEqual(@as(u256, 100), storage_value.?);
    
    const balance_value = journal.get_original_balance(addr1);
    try testing.expect(balance_value != null);
    try testing.expectEqual(@as(u256, 1000), balance_value.?);
    
    // Verify reverted entries are gone
    const reverted_storage = journal.get_original_storage(addr1, 2);
    try testing.expect(reverted_storage == null);
    
    const reverted_storage2 = journal.get_original_storage(addr1, 3);
    try testing.expect(reverted_storage2 == null);
}

test "Journal snapshot - revert to non-existent snapshot" {
    const addr = [_]u8{0} ** 20;
    
    var journal = Journal(.{}).init(testing.allocator);
    defer journal.deinit();
    
    const snapshot1 = journal.create_snapshot();
    const snapshot2 = journal.create_snapshot();
    
    try journal.record_storage_change(snapshot1, addr, 1, 100);
    try journal.record_storage_change(snapshot2, addr, 2, 200);
    
    // Revert to snapshot ID that doesn't exist (higher than any created)
    journal.revert_to_snapshot(999);
    
    // Should remove all entries since 999 > any actual snapshot_id
    try testing.expectEqual(@as(usize, 0), journal.entry_count());
}

test "Journal snapshot - revert to snapshot 0" {
    const addr = [_]u8{0} ** 20;
    
    var journal = Journal(.{}).init(testing.allocator);
    defer journal.deinit();
    
    const snapshot0 = journal.create_snapshot();
    const snapshot1 = journal.create_snapshot();
    
    try journal.record_storage_change(snapshot0, addr, 1, 100);
    try journal.record_storage_change(snapshot1, addr, 2, 200);
    
    try testing.expectEqual(@as(usize, 2), journal.entry_count());
    
    // Revert to snapshot 0 - should remove entries with snapshot_id >= 0 (all entries)
    journal.revert_to_snapshot(0);
    
    try testing.expectEqual(@as(usize, 0), journal.entry_count());
}

test "Journal snapshot - nested call simulation" {
    const caller_addr = [_]u8{1} ** 20;
    const contract1_addr = [_]u8{2} ** 20;
    const contract2_addr = [_]u8{3} ** 20;
    
    var journal = Journal(.{}).init(testing.allocator);
    defer journal.deinit();
    
    // Outer call
    const outer_snapshot = journal.create_snapshot();
    try journal.record_balance_change(outer_snapshot, caller_addr, 10000);
    try journal.record_storage_change(outer_snapshot, contract1_addr, 1, 42);
    
    // Inner call 1
    const inner1_snapshot = journal.create_snapshot();
    try journal.record_storage_change(inner1_snapshot, contract1_addr, 2, 100);
    try journal.record_nonce_change(inner1_snapshot, contract1_addr, 1);
    
    // Inner call 2 (nested deeper)
    const inner2_snapshot = journal.create_snapshot();
    try journal.record_storage_change(inner2_snapshot, contract2_addr, 1, 200);
    try journal.record_balance_change(inner2_snapshot, contract2_addr, 5000);
    try journal.record_code_change(inner2_snapshot, contract2_addr, [_]u8{0xFF} ** 32);
    
    try testing.expectEqual(@as(usize, 7), journal.entry_count());
    
    // Inner call 2 fails - revert to inner2_snapshot
    journal.revert_to_snapshot(inner2_snapshot);
    try testing.expectEqual(@as(usize, 4), journal.entry_count());
    
    // Verify inner call 1 and outer call state remains
    const outer_balance = journal.get_original_balance(caller_addr);
    try testing.expect(outer_balance != null);
    try testing.expectEqual(@as(u256, 10000), outer_balance.?);
    
    const contract1_storage = journal.get_original_storage(contract1_addr, 2);
    try testing.expect(contract1_storage != null);
    try testing.expectEqual(@as(u256, 100), contract1_storage.?);
    
    // Verify inner call 2 state was reverted
    const contract2_storage = journal.get_original_storage(contract2_addr, 1);
    try testing.expect(contract2_storage == null);
    
    // Inner call 1 also fails - revert to inner1_snapshot
    journal.revert_to_snapshot(inner1_snapshot);
    try testing.expectEqual(@as(usize, 2), journal.entry_count());
    
    // Only outer call state should remain
    const remaining_balance = journal.get_original_balance(caller_addr);
    try testing.expect(remaining_balance != null);
    try testing.expectEqual(@as(u256, 10000), remaining_balance.?);
    
    const remaining_storage = journal.get_original_storage(contract1_addr, 1);
    try testing.expect(remaining_storage != null);
    try testing.expectEqual(@as(u256, 42), remaining_storage.?);
    
    // Inner call state should be gone
    const reverted_storage = journal.get_original_storage(contract1_addr, 2);
    try testing.expect(reverted_storage == null);
}

test "Journal snapshot - complex multi-level revert scenario" {
    const addr = [_]u8{0} ** 20;
    
    var journal = Journal(.{}).init(testing.allocator);
    defer journal.deinit();
    
    // Create snapshots representing call depth
    const depth0 = journal.create_snapshot(); // Transaction level
    const depth1 = journal.create_snapshot(); // Contract call
    const depth2 = journal.create_snapshot(); // Nested call
    const depth3 = journal.create_snapshot(); // Deep nested call
    const depth4 = journal.create_snapshot(); // Deepest call
    
    // Add entries at each depth
    try journal.record_storage_change(depth0, addr, 0, 0);     // Transaction setup
    
    try journal.record_storage_change(depth1, addr, 1, 10);    // Contract execution
    try journal.record_balance_change(depth1, addr, 1000);
    
    try journal.record_storage_change(depth2, addr, 2, 20);    // Nested call
    try journal.record_nonce_change(depth2, addr, 1);
    
    try journal.record_storage_change(depth3, addr, 3, 30);    // Deep call
    try journal.record_account_created(depth3, addr);
    
    try journal.record_storage_change(depth4, addr, 4, 40);    // Deepest call
    try journal.record_account_destroyed(depth4, addr, addr, 500);
    
    try testing.expectEqual(@as(usize, 8), journal.entry_count());
    
    // Deepest call fails (depth4)
    journal.revert_to_snapshot(depth4);
    try testing.expectEqual(@as(usize, 6), journal.entry_count());
    
    // Deep call succeeds, nested call fails (depth2)
    journal.revert_to_snapshot(depth2);
    try testing.expectEqual(@as(usize, 3), journal.entry_count());
    
    // Contract call succeeds, all remaining should be from depth0 and depth1
    for (journal.entries.items) |entry| {
        try testing.expect(entry.snapshot_id < depth2);
    }
    
    // Verify correct state remains
    const depth0_value = journal.get_original_storage(addr, 0);
    try testing.expect(depth0_value != null);
    try testing.expectEqual(@as(u256, 0), depth0_value.?);
    
    const depth1_value = journal.get_original_storage(addr, 1);
    try testing.expect(depth1_value != null);
    try testing.expectEqual(@as(u256, 10), depth1_value.?);
    
    const depth1_balance = journal.get_original_balance(addr);
    try testing.expect(depth1_balance != null);
    try testing.expectEqual(@as(u256, 1000), depth1_balance.?);
    
    // Verify reverted state is gone
    try testing.expect(journal.get_original_storage(addr, 2) == null);
    try testing.expect(journal.get_original_storage(addr, 3) == null);
    try testing.expect(journal.get_original_storage(addr, 4) == null);
}

test "Journal snapshot - revert with no entries" {
    var journal = Journal(.{}).init(testing.allocator);
    defer journal.deinit();
    
    const snapshot = journal.create_snapshot();
    
    // Revert empty journal should be safe
    journal.revert_to_snapshot(snapshot);
    try testing.expectEqual(@as(usize, 0), journal.entry_count());
    
    // Multiple reverts should be safe
    journal.revert_to_snapshot(snapshot);
    journal.revert_to_snapshot(0);
    journal.revert_to_snapshot(999);
    
    try testing.expectEqual(@as(usize, 0), journal.entry_count());
}

test "Journal snapshot - revert to current state" {
    const addr = [_]u8{0} ** 20;
    
    var journal = Journal(.{}).init(testing.allocator);
    defer journal.deinit();
    
    const snapshot1 = journal.create_snapshot();
    const snapshot2 = journal.create_snapshot();
    
    try journal.record_storage_change(snapshot1, addr, 1, 100);
    try journal.record_storage_change(snapshot2, addr, 2, 200);
    
    const original_count = journal.entry_count();
    
    // Revert to the highest snapshot ID + 1 should remove nothing
    journal.revert_to_snapshot(snapshot2 + 1);
    try testing.expectEqual(original_count, journal.entry_count());
    
    // All entries should still be present
    const storage1 = journal.get_original_storage(addr, 1);
    try testing.expect(storage1 != null);
    try testing.expectEqual(@as(u256, 100), storage1.?);
    
    const storage2 = journal.get_original_storage(addr, 2);
    try testing.expect(storage2 != null);
    try testing.expectEqual(@as(u256, 200), storage2.?);
}

test "Journal snapshot - revert preserves capacity" {
    const addr = [_]u8{0} ** 20;
    
    var journal = Journal(.{}).init(testing.allocator);
    defer journal.deinit();
    
    const snapshot1 = journal.create_snapshot();
    const snapshot2 = journal.create_snapshot();
    
    // Add many entries to force capacity growth
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const snapshot_id = if (i < 500) snapshot1 else snapshot2;
        try journal.record_storage_change(snapshot_id, addr, i, i * 10);
    }
    
    const capacity_before = journal.entries.capacity;
    try testing.expect(capacity_before >= 1000);
    
    // Revert to snapshot2 should remove 500 entries but preserve capacity
    journal.revert_to_snapshot(snapshot2);
    try testing.expectEqual(@as(usize, 500), journal.entry_count());
    
    const capacity_after = journal.entries.capacity;
    try testing.expectEqual(capacity_before, capacity_after);
    
    // Verify data integrity
    const first_entry = journal.get_original_storage(addr, 0);
    try testing.expect(first_entry != null);
    try testing.expectEqual(@as(u256, 0), first_entry.?);
    
    const last_valid_entry = journal.get_original_storage(addr, 499);
    try testing.expect(last_valid_entry != null);
    try testing.expectEqual(@as(u256, 4990), last_valid_entry.?);
    
    // Reverted entries should be gone
    const reverted_entry = journal.get_original_storage(addr, 500);
    try testing.expect(reverted_entry == null);
}

test "Journal snapshot - stress test with many snapshots" {
    const addr = [_]u8{0} ** 20;
    
    var journal = Journal(.{}).init(testing.allocator);
    defer journal.deinit();
    
    const num_snapshots = 100;
    var snapshots = std.array_list.AlignedManaged(u32, null).init(testing.allocator);
    defer snapshots.deinit();
    
    // Create many snapshots and add entries
    var i: u32 = 0;
    while (i < num_snapshots) : (i += 1) {
        const snapshot = journal.create_snapshot();
        try snapshots.append(snapshot);
        
        // Add multiple entries per snapshot
        try journal.record_storage_change(snapshot, addr, i * 2, i * 100);
        try journal.record_storage_change(snapshot, addr, i * 2 + 1, i * 100 + 50);
    }
    
    try testing.expectEqual(num_snapshots * 2, journal.entry_count());
    
    // Revert to middle snapshot
    const middle_snapshot = snapshots.items[num_snapshots / 2];
    journal.revert_to_snapshot(middle_snapshot);
    
    const expected_remaining = (num_snapshots / 2) * 2;
    try testing.expectEqual(expected_remaining, journal.entry_count());
    
    // Verify only lower-indexed entries remain
    for (journal.entries.items) |entry| {
        try testing.expect(entry.snapshot_id < middle_snapshot);
    }
    
    // Revert to beginning
    journal.revert_to_snapshot(0);
    try testing.expectEqual(@as(usize, 0), journal.entry_count());
}

test "Journal snapshot - memory usage with frequent reverts" {
    const addr = [_]u8{0} ** 20;
    
    var journal = Journal(.{}).init(testing.allocator);
    defer journal.deinit();
    
    // Simulate frequent snapshot creation and reversion
    var cycle: usize = 0;
    while (cycle < 10) : (cycle += 1) {
        const snapshot1 = journal.create_snapshot();
        const snapshot2 = journal.create_snapshot();
        const snapshot3 = journal.create_snapshot();
        
        // Add entries
        try journal.record_storage_change(snapshot1, addr, cycle * 3, 100);
        try journal.record_storage_change(snapshot2, addr, cycle * 3 + 1, 200);
        try journal.record_storage_change(snapshot3, addr, cycle * 3 + 2, 300);
        
        // Revert most recent
        journal.revert_to_snapshot(snapshot3);
        
        // Revert another level
        journal.revert_to_snapshot(snapshot2);
        
        // Keep only the first entry from this cycle
    }
    
    // Should have one entry per cycle
    try testing.expectEqual(@as(usize, 10), journal.entry_count());
    
    // Verify data integrity
    var check_cycle: usize = 0;
    while (check_cycle < 10) : (check_cycle += 1) {
        const stored_value = journal.get_original_storage(addr, check_cycle * 3);
        try testing.expect(stored_value != null);
        try testing.expectEqual(@as(u256, 100), stored_value.?);
    }
}

test "Journal snapshot - snapshot ID uniqueness across clear operations" {
    var journal = Journal(.{}).init(testing.allocator);
    defer journal.deinit();
    
    const addr = [_]u8{0} ** 20;
    
    // Create snapshots and entries
    const snapshot1 = journal.create_snapshot();
    const snapshot2 = journal.create_snapshot();
    try journal.record_storage_change(snapshot1, addr, 1, 100);
    try journal.record_storage_change(snapshot2, addr, 2, 200);
    
    try testing.expectEqual(@as(u32, 2), journal.next_snapshot_id);
    try testing.expectEqual(@as(usize, 2), journal.entry_count());
    
    // Clear journal
    journal.clear();
    
    try testing.expectEqual(@as(u32, 0), journal.next_snapshot_id);
    try testing.expectEqual(@as(usize, 0), journal.entry_count());
    
    // New snapshots should start from 0 again
    const new_snapshot1 = journal.create_snapshot();
    const new_snapshot2 = journal.create_snapshot();
    
    try testing.expectEqual(@as(u32, 0), new_snapshot1);
    try testing.expectEqual(@as(u32, 1), new_snapshot2);
    
    // Add new entries with reused IDs
    try journal.record_storage_change(new_snapshot1, addr, 1, 300);
    try journal.record_storage_change(new_snapshot2, addr, 2, 400);
    
    // Verify new data
    const new_storage1 = journal.get_original_storage(addr, 1);
    try testing.expect(new_storage1 != null);
    try testing.expectEqual(@as(u256, 300), new_storage1.?);
    
    const new_storage2 = journal.get_original_storage(addr, 2);
    try testing.expect(new_storage2 != null);
    try testing.expectEqual(@as(u256, 400), new_storage2.?);
}

test "Journal snapshot - all entry types with selective reversion" {
    const addr1 = Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
    const addr2 = Address.fromHex("0x9876543210987654321098765432109876543210") catch unreachable;
    const code_hash = [_]u8{0xAB} ** 32;
    
    var journal = Journal(.{}).init(testing.allocator);
    defer journal.deinit();
    
    const snapshot1 = journal.create_snapshot();
    const snapshot2 = journal.create_snapshot();
    const snapshot3 = journal.create_snapshot();
    
    // Add one type per snapshot
    try journal.record_storage_change(snapshot1, addr1, 1, 100);
    try journal.record_balance_change(snapshot1, addr1, 1000);
    
    try journal.record_nonce_change(snapshot2, addr1, 5);
    try journal.record_code_change(snapshot2, addr1, code_hash);
    
    try journal.record_account_created(snapshot3, addr2);
    try journal.record_account_destroyed(snapshot3, addr1, addr2, 500);
    
    try testing.expectEqual(@as(usize, 6), journal.entry_count());
    
    // Revert snapshot3 - removes account lifecycle entries
    journal.revert_to_snapshot(snapshot3);
    try testing.expectEqual(@as(usize, 4), journal.entry_count());
    
    // Verify snapshot1 and snapshot2 entries remain
    const storage_value = journal.get_original_storage(addr1, 1);
    try testing.expect(storage_value != null);
    try testing.expectEqual(@as(u256, 100), storage_value.?);
    
    const balance_value = journal.get_original_balance(addr1);
    try testing.expect(balance_value != null);
    try testing.expectEqual(@as(u256, 1000), balance_value.?);
    
    // Verify snapshot2 entries are intact
    var nonce_found = false;
    var code_found = false;
    for (journal.entries.items) |entry| {
        switch (entry.data) {
            .nonce_change => nonce_found = true,
            .code_change => code_found = true,
            .account_created, .account_destroyed => try testing.expect(false), // Should be reverted
            else => {},
        }
    }
    try testing.expect(nonce_found);
    try testing.expect(code_found);
    
    // Revert to snapshot1 - only storage and balance should remain
    journal.revert_to_snapshot(snapshot1);
    try testing.expectEqual(@as(usize, 2), journal.entry_count());
    
    // Verify final state
    var storage_found = false;
    var balance_found = false;
    for (journal.entries.items) |entry| {
        switch (entry.data) {
            .storage_change => storage_found = true,
            .balance_change => balance_found = true,
            else => try testing.expect(false), // Should be reverted
        }
    }
    try testing.expect(storage_found);
    try testing.expect(balance_found);
}
