const std = @import("std");
const DatabaseInterface = @import("database_interface.zig").DatabaseInterface;
const DatabaseError = @import("database_interface.zig").DatabaseError;
const Account = @import("database_interface.zig").Account;
const CallJournal = @import("../call_frame_stack.zig").CallJournal;

/// Journaling database wrapper that records all state changes for revert capability
/// This wraps any DatabaseInterface and adds journaling functionality on top
pub const JournalingDatabase = struct {
    /// Underlying database implementation
    inner: DatabaseInterface,
    /// Journal for tracking state changes
    journal: *CallJournal,
    /// Current snapshot ID for this database session
    current_snapshot_id: u32,
    /// Allocator for internal operations
    allocator: std.mem.Allocator,
    
    pub fn init(inner: DatabaseInterface, journal: *CallJournal, snapshot_id: u32, allocator: std.mem.Allocator) JournalingDatabase {
        return JournalingDatabase{
            .inner = inner,
            .journal = journal,
            .current_snapshot_id = snapshot_id,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *JournalingDatabase) void {
        // We don't own the inner database or journal, so just cleanup our own resources
        _ = self;
    }
    
    // Account operations with journaling
    
    pub fn get_account(self: *JournalingDatabase, address: [20]u8) DatabaseError!?Account {
        return self.inner.get_account(address);
    }
    
    pub fn set_account(self: *JournalingDatabase, address: [20]u8, account: Account) DatabaseError!void {
        // Check if we need to journal the original account state
        const original_account = self.inner.get_account(address) catch null;
        
        // Record the change in journal for revert capability
        if (original_account) |orig| {
            // Journal the original balance if it's different
            if (orig.balance != account.balance) {
                self.journal.record_balance_change(
                    self.current_snapshot_id,
                    address,
                    orig.balance
                ) catch {};
            }
            
            // Journal the original nonce if it's different
            if (orig.nonce != account.nonce) {
                self.journal.record_nonce_change(
                    self.current_snapshot_id,
                    address,
                    orig.nonce
                ) catch {};
            }
        } else {
            // Account didn't exist, journal a "zero" account for revert
            self.journal.record_balance_change(
                self.current_snapshot_id,
                address,
                0
            ) catch {};
            
            self.journal.record_nonce_change(
                self.current_snapshot_id,
                address,
                0
            ) catch {};
        }
        
        return self.inner.set_account(address, account);
    }
    
    pub fn delete_account(self: *JournalingDatabase, address: [20]u8) DatabaseError!void {
        // Journal the original account state before deletion
        if (self.inner.get_account(address)) |original_account| {
            self.journal.record_balance_change(
                self.current_snapshot_id,
                address,
                original_account.balance
            ) catch {};
            
            self.journal.record_nonce_change(
                self.current_snapshot_id,
                address,
                original_account.nonce
            ) catch {};
        } else |_| {
            // Account doesn't exist, nothing to journal
        }
        
        return self.inner.delete_account(address);
    }
    
    pub fn account_exists(self: *JournalingDatabase, address: [20]u8) bool {
        return self.inner.account_exists(address);
    }
    
    // Storage operations with journaling
    
    pub fn get_storage(self: *JournalingDatabase, address: [20]u8, key: u256) DatabaseError!u256 {
        return self.inner.get_storage(address, key);
    }
    
    pub fn set_storage(self: *JournalingDatabase, address: [20]u8, key: u256, value: u256) DatabaseError!void {
        // Journal the original storage value
        const original_value = self.inner.get_storage(address, key) catch 0;
        
        // Only journal if the value is actually changing
        if (original_value != value) {
            self.journal.record_storage_change(
                self.current_snapshot_id,
                address,
                key,
                original_value
            ) catch {};
        }
        
        return self.inner.set_storage(address, key, value);
    }
    
    // Code operations (pass through - code changes are rare and complex to journal)
    
    pub fn get_code(self: *JournalingDatabase, code_hash: [32]u8) DatabaseError![]const u8 {
        return self.inner.get_code(code_hash);
    }
    
    pub fn set_code(self: *JournalingDatabase, code: []const u8) DatabaseError![32]u8 {
        // TODO: In a full implementation, we might want to journal code changes too
        return self.inner.set_code(code);
    }
    
    // State root operations (pass through)
    
    pub fn get_state_root(self: *JournalingDatabase) DatabaseError![32]u8 {
        return self.inner.get_state_root();
    }
    
    pub fn commit_changes(self: *JournalingDatabase) DatabaseError![32]u8 {
        return self.inner.commit_changes();
    }
    
    // Snapshot operations (delegate to inner database)
    
    pub fn create_snapshot(self: *JournalingDatabase) DatabaseError!u64 {
        return self.inner.create_snapshot();
    }
    
    pub fn revert_to_snapshot(self: *JournalingDatabase, snapshot_id: u64) DatabaseError!void {
        return self.inner.revert_to_snapshot(snapshot_id);
    }
    
    pub fn commit_snapshot(self: *JournalingDatabase, snapshot_id: u64) DatabaseError!void {
        return self.inner.commit_snapshot(snapshot_id);
    }
    
    // Batch operations (pass through)
    
    pub fn begin_batch(self: *JournalingDatabase) DatabaseError!void {
        return self.inner.begin_batch();
    }
    
    pub fn commit_batch(self: *JournalingDatabase) DatabaseError!void {
        return self.inner.commit_batch();
    }
    
    pub fn rollback_batch(self: *JournalingDatabase) DatabaseError!void {
        return self.inner.rollback_batch();
    }
    
    /// Convert this journaling database to a DatabaseInterface
    pub fn to_database_interface(self: *JournalingDatabase) DatabaseInterface {
        return DatabaseInterface.init(self);
    }
    
    /// Apply journal reverts to restore state
    /// This is called by the CallFrameStack when reverting to a snapshot
    pub fn apply_journal_reverts(self: *JournalingDatabase, journal_entries: []const @import("../call_frame_stack.zig").JournalEntry) DatabaseError!void {
        // Apply journal entries in reverse order to restore original state
        var i: usize = journal_entries.len;
        while (i > 0) {
            i -= 1;
            const entry = journal_entries[i];
            
            switch (entry) {
                .storage_change => |sc| {
                    try self.inner.set_storage(sc.address, sc.key, sc.original_value);
                },
                .balance_change => |bc| {
                    // Get current account and restore balance
                    if (self.inner.get_account(bc.address)) |mut_account| {
                        var account = mut_account;
                        account.balance = bc.original_balance;
                        try self.inner.set_account(bc.address, account);
                    } else |_| {
                        // Account doesn't exist, create it with original balance
                        var account = Account.zero();
                        account.balance = bc.original_balance;
                        try self.inner.set_account(bc.address, account);
                    }
                },
                .nonce_change => |nc| {
                    // Get current account and restore nonce
                    if (self.inner.get_account(nc.address)) |mut_account| {
                        var account = mut_account;
                        account.nonce = nc.original_nonce;
                        try self.inner.set_account(nc.address, account);
                    } else |_| {
                        // Account doesn't exist, create it with original nonce
                        var account = Account.zero();
                        account.nonce = nc.original_nonce;
                        try self.inner.set_account(nc.address, account);
                    }
                },
                .log_entry => {
                    // Log entries are handled separately by the execution environment
                    // Nothing to do here for database state
                },
                .selfdestruct => {
                    // Self-destruct operations are handled by the SelfDestruct tracking system
                    // Nothing to do here for database state
                },
            }
        }
    }
};

test "JournalingDatabase storage operations" {
    const std = @import("std");
    const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
    
    const allocator = std.testing.allocator;
    
    // Create underlying database
    var memory_db = try MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    // Create journal
    var journal = CallJournal.init(allocator);
    defer journal.deinit();
    
    const snapshot_id = journal.create_snapshot();
    
    // Create journaling wrapper
    var journaling_db = JournalingDatabase.init(db_interface, &journal, snapshot_id, allocator);
    defer journaling_db.deinit();
    
    const test_address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    
    // Set initial storage value (should be journaled)
    try journaling_db.set_storage(test_address, 1, 42);
    
    // Verify the value was set
    const stored_value = try journaling_db.get_storage(test_address, 1);
    try std.testing.expectEqual(@as(u256, 42), stored_value);
    
    // Verify journal entry was created
    try std.testing.expectEqual(@as(usize, 1), journal.entries.items.len);
    
    // Verify journal entry is correct
    const entry = journal.entries.items[0];
    switch (entry) {
        .storage_change => |sc| {
            try std.testing.expectEqual(snapshot_id, sc.snapshot_id);
            try std.testing.expectEqualSlices(u8, &test_address, &sc.address);
            try std.testing.expectEqual(@as(u256, 1), sc.key);
            try std.testing.expectEqual(@as(u256, 0), sc.original_value); // Original was 0
        },
        else => try std.testing.expect(false), // Should be storage_change
    }
}

test "JournalingDatabase account operations" {
    const std = @import("std");
    const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
    
    const allocator = std.testing.allocator;
    
    // Create underlying database
    var memory_db = try MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    // Create journal
    var journal = CallJournal.init(allocator);
    defer journal.deinit();
    
    const snapshot_id = journal.create_snapshot();
    
    // Create journaling wrapper
    var journaling_db = JournalingDatabase.init(db_interface, &journal, snapshot_id, allocator);
    defer journaling_db.deinit();
    
    const test_address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    
    // Create account
    var account = Account.zero();
    account.balance = 1000;
    account.nonce = 5;
    
    try journaling_db.set_account(test_address, account);
    
    // Verify account was set
    const retrieved = try journaling_db.get_account(test_address);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u256, 1000), retrieved.?.balance);
    try std.testing.expectEqual(@as(u64, 5), retrieved.?.nonce);
    
    // Should have 2 journal entries (balance and nonce)
    try std.testing.expectEqual(@as(usize, 2), journal.entries.items.len);
}