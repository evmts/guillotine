//! In-memory implementation of the database interface.
//!
//! A small state store for tests and development. Snapshots are full copies of
//! the account, storage and transient-storage maps, so reverting one moves the
//! copy back in and cannot fail part-way. Code is content-addressed and stored
//! once per hash. Not suitable for production: every snapshot costs O(state).

const std = @import("std");
const Database = @import("database.zig").Database;
const Account = @import("database.zig").Account;
const primitives = @import("voltaire");

/// In-memory database with snapshot and batch operation support.
pub const MemoryDatabase = struct {
    allocator: std.mem.Allocator,
    accounts: AccountMap,
    storage: StorageMap,
    transient_storage: StorageMap,
    codes: std.hash_map.HashMap([32]u8, []u8, CodeHashContext, 80),
    /// Code hashes in insertion order. A snapshot remembers the length, so a
    /// revert frees exactly the code stored after it.
    code_order: std.ArrayList([32]u8),
    snapshots: std.ArrayList(Snapshot),
    next_snapshot_id: u64,
    batch_in_progress: bool,
    batch_changes: ?BatchChanges,

    const Self = @This();

    const AccountMap = std.hash_map.HashMap([20]u8, Account, AccountContext, 80);
    const StorageMap = std.hash_map.HashMap(StorageKey, u256, StorageKeyContext, 80);
    const AddressSet = std.hash_map.HashMap([20]u8, void, AccountContext, 80);

    const StorageKey = struct {
        address: [20]u8,
        key: u256,
    };

    const Snapshot = struct {
        id: u64,
        accounts: AccountMap,
        storage: StorageMap,
        transient_storage: StorageMap,
        code_count: usize,

        fn deinit(self: *Snapshot) void {
            self.accounts.deinit();
            self.storage.deinit();
            self.transient_storage.deinit();
        }
    };

    const BatchChanges = struct {
        accounts: std.hash_map.HashMap([20]u8, ?Account, AccountContext, 80),
        storage: StorageMap,
        /// Accounts deleted in this batch. Their committed storage reads as zero
        /// until the batch ends, and is dropped when the batch commits.
        deleted: AddressSet,

        fn deinit(self: *BatchChanges) void {
            self.accounts.deinit();
            self.storage.deinit();
            self.deleted.deinit();
        }
    };

    const AccountContext = struct {
        pub fn hash(self: @This(), key: [20]u8) u64 {
            _ = self;
            return std.hash.Wyhash.hash(0, &key);
        }
        pub fn eql(self: @This(), a: [20]u8, b: [20]u8) bool {
            _ = self;
            return std.mem.eql(u8, &a, &b);
        }
    };

    const StorageKeyContext = struct {
        pub fn hash(self: @This(), key: StorageKey) u64 {
            _ = self;
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(&key.address);
            hasher.update(std.mem.asBytes(&key.key));
            return hasher.final();
        }
        pub fn eql(self: @This(), a: StorageKey, b: StorageKey) bool {
            _ = self;
            return std.mem.eql(u8, &a.address, &b.address) and a.key == b.key;
        }
    };

    const CodeHashContext = struct {
        pub fn hash(self: @This(), key: [32]u8) u64 {
            _ = self;
            return std.hash.Wyhash.hash(0, &key);
        }
        pub fn eql(self: @This(), a: [32]u8, b: [32]u8) bool {
            _ = self;
            return std.mem.eql(u8, &a, &b);
        }
    };

    /// Initialize a new in-memory database.
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .accounts = AccountMap.init(allocator),
            .storage = StorageMap.init(allocator),
            .transient_storage = StorageMap.init(allocator),
            .codes = std.hash_map.HashMap([32]u8, []u8, CodeHashContext, 80).init(allocator),
            .code_order = .empty,
            .snapshots = .empty,
            .next_snapshot_id = 0,
            .batch_in_progress = false,
            .batch_changes = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.accounts.deinit();
        self.storage.deinit();
        self.transient_storage.deinit();

        var code_iter = self.codes.valueIterator();
        while (code_iter.next()) |code| self.allocator.free(code.*);
        self.codes.deinit();
        self.code_order.deinit(self.allocator);

        for (self.snapshots.items) |*snapshot| snapshot.deinit();
        self.snapshots.deinit(self.allocator);

        if (self.batch_changes) |*batch| batch.deinit();
    }

    /// Convert to the generic database interface.
    /// Since we now use concrete Database type, return self as the concrete implementation
    pub fn to_database_interface(self: *Self) *Self {
        return self;
    }

    // Account operations

    pub fn get_account(self: *Self, address: [20]u8) Database.Error!?Account {
        if (self.batch_changes) |*batch| {
            if (batch.accounts.get(address)) |maybe_account| return maybe_account;
        }
        return self.accounts.get(address);
    }

    pub fn set_account(self: *Self, address: [20]u8, account: Account) Database.Error!void {
        if (self.batch_changes) |*batch| return batch.accounts.put(address, account);
        try self.accounts.put(address, account);
    }

    /// Delete an account together with its persistent storage, so a later
    /// account at the same address never reads the old slots.
    pub fn delete_account(self: *Self, address: [20]u8) Database.Error!void {
        if (self.batch_changes) |*batch| {
            // Reserve first: once both maps have room nothing below can fail.
            try batch.accounts.ensureUnusedCapacity(1);
            try batch.deleted.ensureUnusedCapacity(1);
            batch.accounts.putAssumeCapacity(address, null);
            batch.deleted.putAssumeCapacity(address, {});
            removeAddressSlots(&batch.storage, address);
            return;
        }
        _ = self.accounts.remove(address);
        removeAddressSlots(&self.storage, address);
    }

    /// Remove every slot of `address`. Removing through the iterator's key pointer
    /// leaves the table in place, so the iteration stays valid.
    fn removeAddressSlots(map: *StorageMap, address: [20]u8) void {
        var it = map.keyIterator();
        while (it.next()) |slot| {
            if (std.mem.eql(u8, &slot.address, &address)) map.removeByPtr(slot);
        }
    }

    pub fn account_exists(self: *Self, address: [20]u8) bool {
        if (self.batch_changes) |*batch| {
            if (batch.accounts.get(address)) |maybe_account| return maybe_account != null;
        }
        return self.accounts.contains(address);
    }

    pub fn get_balance(self: *Self, address: [20]u8) Database.Error!u256 {
        const account = try self.get_account(address);
        return if (account) |acc| acc.balance else 0;
    }

    // Storage operations

    pub fn get_storage(self: *Self, address: [20]u8, key: u256) Database.Error!u256 {
        const storage_key = StorageKey{ .address = address, .key = key };
        if (self.batch_changes) |*batch| {
            if (batch.storage.get(storage_key)) |value| return value;
            if (batch.deleted.contains(address)) return 0;
        }
        return self.storage.get(storage_key) orelse 0;
    }

    pub fn set_storage(self: *Self, address: [20]u8, key: u256, value: u256) Database.Error!void {
        const storage_key = StorageKey{ .address = address, .key = key };
        if (self.batch_changes) |*batch| return batch.storage.put(storage_key, value);
        if (value == 0) {
            _ = self.storage.remove(storage_key);
            return;
        }
        try self.storage.put(storage_key, value);
    }

    pub fn get_transient_storage(self: *Self, address: [20]u8, key: u256) Database.Error!u256 {
        const storage_key = StorageKey{ .address = address, .key = key };
        return self.transient_storage.get(storage_key) orelse 0;
    }

    pub fn set_transient_storage(self: *Self, address: [20]u8, key: u256, value: u256) Database.Error!void {
        const storage_key = StorageKey{ .address = address, .key = key };
        if (value == 0) {
            _ = self.transient_storage.remove(storage_key);
            return;
        }
        try self.transient_storage.put(storage_key, value);
    }

    // Code operations

    pub fn get_code(self: *Self, code_hash: [32]u8) Database.Error![]const u8 {
        return self.codes.get(code_hash) orelse return Database.Error.CodeNotFound;
    }

    pub fn get_code_by_address(self: *Self, address: [20]u8) Database.Error![]const u8 {
        const account = (try self.get_account(address)) orelse return &.{};
        if (!Account.is_code_hash_present(account.code_hash)) return &.{};
        return self.get_code(account.code_hash);
    }

    /// Store `code` under its keccak256 hash and return the hash. Code is stored
    /// once per hash: storing the same bytes again allocates nothing.
    pub fn set_code(self: *Self, code: []const u8) Database.Error![32]u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(code, &hash, .{});
        if (self.codes.contains(hash)) return hash;

        try self.code_order.ensureUnusedCapacity(self.allocator, 1);
        const code_copy = try self.allocator.dupe(u8, code);
        errdefer self.allocator.free(code_copy);
        try self.codes.put(hash, code_copy);
        self.code_order.appendAssumeCapacity(hash);
        return hash;
    }

    // State root operations

    /// This backend keeps no trie: its state root is always the zero hash.
    pub fn get_state_root(self: *Self) Database.Error![32]u8 {
        _ = self;
        return @as([32]u8, @splat(0));
    }

    /// End a transaction: clear transient storage (EIP-1153) and return the state root.
    pub fn commit_changes(self: *Self) Database.Error![32]u8 {
        self.clear_transient_storage();
        return self.get_state_root();
    }

    /// Clear transient storage (called at transaction end per EIP-1153)
    /// Uses clearRetainingCapacity to avoid memory churn between transactions
    pub fn clear_transient_storage(self: *Self) void {
        self.transient_storage.clearRetainingCapacity();
    }

    // Snapshot operations

    /// Copy accounts, storage and transient storage. On error nothing changes.
    pub fn create_snapshot(self: *Self) Database.Error!u64 {
        try self.snapshots.ensureUnusedCapacity(self.allocator, 1);
        var accounts = try self.accounts.clone();
        errdefer accounts.deinit();
        var storage = try self.storage.clone();
        errdefer storage.deinit();
        var transient_storage = try self.transient_storage.clone();
        errdefer transient_storage.deinit();

        const snapshot_id = self.next_snapshot_id;
        self.next_snapshot_id += 1;
        self.snapshots.appendAssumeCapacity(.{
            .id = snapshot_id,
            .accounts = accounts,
            .storage = storage,
            .transient_storage = transient_storage,
            .code_count = self.code_order.items.len,
        });
        return snapshot_id;
    }

    fn snapshotIndex(self: *const Self, snapshot_id: u64) ?usize {
        for (self.snapshots.items, 0..) |snapshot, i| {
            if (snapshot.id == snapshot_id) return i;
        }
        return null;
    }

    /// Restore accounts, storage, transient storage and code to the snapshot and
    /// drop it and every later snapshot. The snapshot's own maps become the live
    /// state, so this allocates nothing: it either fails with `SnapshotNotFound`
    /// before touching anything or completes.
    pub fn revert_to_snapshot(self: *Self, snapshot_id: u64) Database.Error!void {
        const index = self.snapshotIndex(snapshot_id) orelse return Database.Error.SnapshotNotFound;
        const snapshot = self.snapshots.items[index];

        while (self.code_order.items.len > snapshot.code_count) {
            const hash = self.code_order.pop() orelse break;
            if (self.codes.fetchRemove(hash)) |removed| self.allocator.free(removed.value);
        }

        self.accounts.deinit();
        self.storage.deinit();
        self.transient_storage.deinit();
        self.accounts = snapshot.accounts;
        self.storage = snapshot.storage;
        self.transient_storage = snapshot.transient_storage;

        for (self.snapshots.items[index + 1 ..]) |*later| later.deinit();
        self.snapshots.shrinkRetainingCapacity(index);
    }

    /// Keep the current state and drop the snapshot.
    pub fn commit_snapshot(self: *Self, snapshot_id: u64) Database.Error!void {
        const index = self.snapshotIndex(snapshot_id) orelse return Database.Error.SnapshotNotFound;
        var removed = self.snapshots.orderedRemove(index);
        removed.deinit();
    }

    // Batch operations

    pub fn begin_batch(self: *Self) Database.Error!void {
        if (self.batch_in_progress) return Database.Error.NoBatchInProgress;

        self.batch_in_progress = true;
        self.batch_changes = BatchChanges{
            .accounts = std.hash_map.HashMap([20]u8, ?Account, AccountContext, 80).init(self.allocator),
            .storage = StorageMap.init(self.allocator),
            .deleted = AddressSet.init(self.allocator),
        };
    }

    /// Apply the batch. Room for every write is reserved first, so an allocation
    /// failure leaves both the committed state and the pending batch as they were.
    pub fn commit_batch(self: *Self) Database.Error!void {
        const batch = if (self.batch_changes) |*b| b else return Database.Error.NoBatchInProgress;
        try self.accounts.ensureUnusedCapacity(batch.accounts.count());
        try self.storage.ensureUnusedCapacity(batch.storage.count());

        var deleted_iter = batch.deleted.keyIterator();
        while (deleted_iter.next()) |address| removeAddressSlots(&self.storage, address.*);

        var accounts_iter = batch.accounts.iterator();
        while (accounts_iter.next()) |entry| {
            if (entry.value_ptr.*) |account| {
                self.accounts.putAssumeCapacity(entry.key_ptr.*, account);
            } else {
                _ = self.accounts.remove(entry.key_ptr.*);
            }
        }

        var storage_iter = batch.storage.iterator();
        while (storage_iter.next()) |entry| {
            if (entry.value_ptr.* == 0) {
                _ = self.storage.remove(entry.key_ptr.*);
            } else {
                self.storage.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        batch.deinit();
        self.batch_in_progress = false;
        self.batch_changes = null;
    }

    /// Get all account addresses (for state dumping). Caller owns the slice.
    pub fn getAllAccounts(self: *Self, allocator: std.mem.Allocator) ![]const primitives.Address {
        var addresses = try std.ArrayList(primitives.Address).initCapacity(allocator, self.accounts.count());
        errdefer addresses.deinit(allocator);

        var iter = self.accounts.keyIterator();
        while (iter.next()) |address| addresses.appendAssumeCapacity(.{ .bytes = address.* });
        return addresses.toOwnedSlice(allocator);
    }

    pub fn rollback_batch(self: *Self) Database.Error!void {
        const batch = if (self.batch_changes) |*b| b else return Database.Error.NoBatchInProgress;
        batch.deinit();
        self.batch_in_progress = false;
        self.batch_changes = null;
    }
};

test "MemoryDatabase basic operations" {
    const allocator = std.testing.allocator;

    var db = MemoryDatabase.init(allocator);
    defer db.deinit();

    // Test account operations
    const address = @as([20]u8, @splat(1));
    const account = Account{
        .balance = 1000,
        .nonce = 5,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    };

    try db.set_account(address, account);

    const retrieved = try db.get_account(address);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(account.balance, retrieved.?.balance);
    try std.testing.expectEqual(account.nonce, retrieved.?.nonce);

    // Test storage operations
    const key: u256 = 42;
    const value: u256 = 123456;

    try db.set_storage(address, key, value);
    const stored_value = try db.get_storage(address, key);
    try std.testing.expectEqual(value, stored_value);
}

test "MemoryDatabase snapshot operations" {
    const allocator = std.testing.allocator;

    var db = MemoryDatabase.init(allocator);
    defer db.deinit();

    // Set initial state
    const address = @as([20]u8, @splat(1));
    const account1 = Account{
        .balance = 1000,
        .nonce = 1,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    };

    try db.set_account(address, account1);

    // Create snapshot
    const snapshot_id = try db.create_snapshot();

    // Modify state
    const account2 = Account{
        .balance = 2000,
        .nonce = 2,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    };

    try db.set_account(address, account2);

    // Verify modified state
    const modified = try db.get_account(address);
    try std.testing.expectEqual(@as(u256, 2000), modified.?.balance);

    // Revert to snapshot
    try db.revert_to_snapshot(snapshot_id);

    // Verify reverted state
    const reverted = try db.get_account(address);
    try std.testing.expectEqual(@as(u256, 1000), reverted.?.balance);
}

test "W3-16: MemoryDatabase.set_code stores each code once and never leaks on overwrite" {
    var db = MemoryDatabase.init(std.testing.allocator);
    defer db.deinit();

    const code = [_]u8{ 0x60, 0x42, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    const first = try db.set_code(&code);
    const stored = try db.get_code(first);
    for (0..8) |_| {
        const again = try db.set_code(&code);
        try std.testing.expectEqualSlices(u8, &first, &again);
        // The stored copy is reused, not replaced.
        try std.testing.expectEqual(stored.ptr, (try db.get_code(again)).ptr);
    }
    try std.testing.expectEqual(@as(usize, 1), db.codes.count());
    try std.testing.expectEqualSlices(u8, &code, try db.get_code(first));

    var expected: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&code, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &first);
}

test "W3-16: MemoryDatabase.set_code leaks nothing when any allocation fails" {
    const code = [_]u8{ 0x5f, 0x5f, 0xf3 };
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var db = MemoryDatabase.init(failing.allocator());
        defer db.deinit();
        const hash = db.set_code(&code) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), db.codes.count());
            try std.testing.expectEqual(@as(usize, 0), db.code_order.items.len);
            continue;
        };
        try std.testing.expectEqualSlices(u8, &code, try db.get_code(hash));
        break;
    }
    try std.testing.expect(fail_index >= 3);
}

test "W3-16: MemoryDatabase.delete_account removes the account's storage and no other" {
    var db = MemoryDatabase.init(std.testing.allocator);
    defer db.deinit();

    const doomed = @as([20]u8, @splat(0xaa));
    const kept = @as([20]u8, @splat(0xbb));
    try db.set_account(doomed, Account.zero());
    try db.set_account(kept, Account.zero());
    for (0..64) |slot| {
        try db.set_storage(doomed, slot, slot + 1);
        try db.set_storage(kept, slot, slot + 100);
    }

    try db.delete_account(doomed);
    try std.testing.expect(!db.account_exists(doomed));
    try std.testing.expectEqual(@as(usize, 64), db.storage.count());
    for (0..64) |slot| {
        try std.testing.expectEqual(@as(u256, 0), try db.get_storage(doomed, slot));
        try std.testing.expectEqual(@as(u256, slot + 100), try db.get_storage(kept, slot));
    }

    // An account created later at the same address starts with empty storage.
    try db.set_account(doomed, Account.zero());
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(doomed, 7));
}

test "W3-16: MemoryDatabase.delete_account inside a batch hides storage and purges it on commit" {
    var db = MemoryDatabase.init(std.testing.allocator);
    defer db.deinit();

    const address = @as([20]u8, @splat(0x11));
    try db.set_account(address, Account.zero());
    try db.set_storage(address, 1, 111);
    try db.set_storage(address, 2, 222);

    // Rolled back: the deletion never happened.
    try db.begin_batch();
    try db.delete_account(address);
    try std.testing.expect(!db.account_exists(address));
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(address, 1));
    try db.rollback_batch();
    try std.testing.expect(db.account_exists(address));
    try std.testing.expectEqual(@as(u256, 111), try db.get_storage(address, 1));

    // Committed: old slots are gone, a slot written after the deletion survives.
    try db.begin_batch();
    try db.set_storage(address, 2, 999);
    try db.delete_account(address);
    try db.set_account(address, Account.zero());
    try db.set_storage(address, 3, 333);
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(address, 2));
    try db.commit_batch();
    try std.testing.expect(db.account_exists(address));
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(address, 1));
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(address, 2));
    try std.testing.expectEqual(@as(u256, 333), try db.get_storage(address, 3));
    try std.testing.expectEqual(@as(usize, 1), db.storage.count());
}

test "W3-16: MemoryDatabase.revert_to_snapshot restores accounts, storage, transient storage and code" {
    var db = MemoryDatabase.init(std.testing.allocator);
    defer db.deinit();

    const address = @as([20]u8, @splat(0x01));
    const other = @as([20]u8, @splat(0x02));
    const old_code = [_]u8{ 0x60, 0x01 };
    const new_code = [_]u8{ 0x60, 0x02, 0x00 };
    var account = Account.zero();
    account.balance = 1000;
    account.code_hash = try db.set_code(&old_code);
    try db.set_account(address, account);
    try db.set_storage(address, 1, 11);
    try db.set_transient_storage(address, 1, 21);

    const snapshot = try db.create_snapshot();
    account.balance = 5;
    try db.set_account(address, account);
    try db.set_account(other, Account.zero());
    try db.set_storage(address, 1, 12);
    try db.set_storage(address, 2, 13);
    try db.set_transient_storage(address, 1, 0);
    try db.set_transient_storage(other, 9, 99);
    const new_hash = try db.set_code(&new_code);
    const inner = try db.create_snapshot();

    // An unknown id fails before anything is touched.
    try std.testing.expectError(Database.Error.SnapshotNotFound, db.revert_to_snapshot(inner + 100));
    try std.testing.expectEqual(@as(u256, 12), try db.get_storage(address, 1));
    try std.testing.expectEqual(@as(usize, 2), db.snapshots.items.len);

    try db.revert_to_snapshot(snapshot);
    try std.testing.expectEqual(@as(u256, 1000), (try db.get_account(address)).?.balance);
    try std.testing.expect(!db.account_exists(other));
    try std.testing.expectEqual(@as(u256, 11), try db.get_storage(address, 1));
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(address, 2));
    try std.testing.expectEqual(@as(u256, 21), try db.get_transient_storage(address, 1));
    try std.testing.expectEqual(@as(u256, 0), try db.get_transient_storage(other, 9));
    try std.testing.expectEqualSlices(u8, &old_code, try db.get_code_by_address(address));
    try std.testing.expectError(Database.Error.CodeNotFound, db.get_code(new_hash));
    // The snapshot and the one nested inside it are both gone.
    try std.testing.expectEqual(@as(usize, 0), db.snapshots.items.len);
    try std.testing.expectError(Database.Error.SnapshotNotFound, db.revert_to_snapshot(inner));
}

test "W3-16: MemoryDatabase.revert_to_snapshot allocates nothing, so it cannot fail half-way" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var db = MemoryDatabase.init(failing.allocator());
    defer db.deinit();

    const address = @as([20]u8, @splat(0x07));
    try db.set_account(address, Account.zero());
    for (0..32) |slot| try db.set_storage(address, slot, slot + 1);
    const snapshot = try db.create_snapshot();
    for (0..32) |slot| try db.set_storage(address, slot, 0);
    for (100..400) |slot| try db.set_storage(address, slot, 7);
    _ = try db.set_code(&[_]u8{ 0xfe, 0xfe });

    // From here on every allocation fails.
    failing.fail_index = failing.alloc_index;
    try db.revert_to_snapshot(snapshot);
    try std.testing.expectEqual(@as(usize, 32), db.storage.count());
    for (0..32) |slot| try std.testing.expectEqual(@as(u256, slot + 1), try db.get_storage(address, slot));
    try std.testing.expectEqual(@as(usize, 0), db.codes.count());
}

test "W3-16: MemoryDatabase.create_snapshot leaves the database unchanged when it runs out of memory" {
    var fail_index: usize = 0;
    var failures: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var db = MemoryDatabase.init(failing.allocator());
        defer db.deinit();
        const address = @as([20]u8, @splat(0x09));
        try db.set_account(address, Account.zero());
        try db.set_storage(address, 1, 2);
        try db.set_transient_storage(address, 3, 4);

        failing.fail_index = failing.alloc_index + fail_index;
        const snapshot = db.create_snapshot() catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), db.snapshots.items.len);
            try std.testing.expectEqual(@as(u64, 0), db.next_snapshot_id);
            try std.testing.expectEqual(@as(u256, 2), try db.get_storage(address, 1));
            failures += 1;
            continue;
        };
        try db.commit_snapshot(snapshot);
        break;
    }
    try std.testing.expect(failures >= 4);
}

test "W3-16: MemoryDatabase.getAllAccounts returns every address once" {
    var db = MemoryDatabase.init(std.testing.allocator);
    defer db.deinit();

    for (1..6) |i| try db.set_account(@as([20]u8, @splat(@intCast(i))), Account.zero());
    const addresses = try db.getAllAccounts(std.testing.allocator);
    defer std.testing.allocator.free(addresses);
    try std.testing.expectEqual(@as(usize, 5), addresses.len);
    var seen: u8 = 0;
    for (addresses) |address| seen |= @as(u8, 1) << @intCast(address.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0b0011_1110), seen);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, db.getAllAccounts(failing.allocator()));
}

test "W3-16: MemoryDatabase.get_code_by_address treats the empty code hash as no code" {
    var db = MemoryDatabase.init(std.testing.allocator);
    defer db.deinit();

    const address = @as([20]u8, @splat(0x33));
    var account = Account.zero();
    account.code_hash = primitives.EMPTY_CODE_HASH;
    try db.set_account(address, account);
    try std.testing.expectEqual(@as(usize, 0), (try db.get_code_by_address(address)).len);
    try std.testing.expectEqual(@as(usize, 0), (try db.get_code_by_address(@as([20]u8, @splat(0x34)))).len);
}
