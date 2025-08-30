//! Concrete Database Implementation for EVM State Management
//!
//! WARNING: DOES NOT CALCULATE AN ACTUAL STATE ROOT.
//! Just an in memory implementation
//!
//! High-performance in-memory database for EVM state storage including:
//! - Account data (balance, nonce, code hash, storage root)
//! - Contract storage (persistent and transient)
//! - Contract code storage
//! - Snapshot and batching support
//!
//! This implementation uses hash maps for efficient lookups and provides
//! all functionality needed for EVM execution without vtable overhead.

const std = @import("std");
pub const Account = @import("database_interface_account.zig").Account;

/// High-performance in-memory database for EVM state
pub const Database = struct {
    accounts: std.HashMap([20]u8, Account, ArrayHashContext, std.hash_map.default_max_load_percentage),
    storage: std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage),
    transient_storage: std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage),
    code_storage: std.HashMap([32]u8, []const u8, ArrayHashContext, std.hash_map.default_max_load_percentage),
    snapshots: std.ArrayList(Snapshot),
    next_snapshot_id: u64,
    allocator: std.mem.Allocator,

    /// Database operation errors
    pub const Error = error{
        /// Account not found in the database
        AccountNotFound,
        /// Storage slot not found for the given address
        StorageNotFound,
        /// Contract code not found for the given hash
        CodeNotFound,
        /// Invalid address format
        InvalidAddress,
        /// Database corruption detected
        DatabaseCorrupted,
        /// Network error when accessing remote database
        NetworkError,
        /// Permission denied accessing database
        PermissionDenied,
        /// Out of memory during database operation
        OutOfMemory,
        /// Invalid snapshot identifier
        InvalidSnapshot,
        /// Batch operation not in progress
        NoBatchInProgress,
        /// Snapshot not found
        SnapshotNotFound,
        /// Write protection for static calls
        WriteProtection,
    };

    const StorageKey = struct {
        address: [20]u8,
        key: u256,
    };

    const Snapshot = struct {
        id: u64,
        accounts: std.HashMap([20]u8, Account, ArrayHashContext, std.hash_map.default_max_load_percentage),
        storage: std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage),
    };

    const ArrayHashContext = struct {
        pub fn hash(self: @This(), s: anytype) u64 {
            _ = self;
            return std.hash_map.hashString(@as([]const u8, &s));
        }
        pub fn eql(self: @This(), a: anytype, b: anytype) bool {
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

    /// Initialize a new database
    pub fn init(allocator: std.mem.Allocator) Database {
        return Database{
            .accounts = std.HashMap([20]u8, Account, ArrayHashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .storage = std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .transient_storage = std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .code_storage = std.HashMap([32]u8, []const u8, ArrayHashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .snapshots = .{ .items = &[_]Snapshot{}, .capacity = 0 },
            .next_snapshot_id = 1,
            .allocator = allocator,
        };
    }

    /// Clean up database resources
    pub fn deinit(self: *Database) void {
        self.accounts.deinit();
        self.storage.deinit();
        self.transient_storage.deinit();
        self.code_storage.deinit();

        for (self.snapshots.items) |*snapshot| {
            snapshot.accounts.deinit();
            snapshot.storage.deinit();
        }
        self.snapshots.deinit(self.allocator);
    }

    // Account operations

    /// Get account data for the given address
    pub fn get_account(self: *Database, address: [20]u8) Error!?Account {
        return self.accounts.get(address);
    }

    /// Set account data for the given address
    pub fn set_account(self: *Database, address: [20]u8, account: Account) Error!void {
        const log = std.log.scoped(.database);
        log.debug("set_account: Setting account for address {x} with code_hash {x}", .{ address, account.code_hash });
        try self.accounts.put(address, account);
    }

    /// Delete account and all associated data
    pub fn delete_account(self: *Database, address: [20]u8) Error!void {
        _ = self.accounts.remove(address);
    }

    /// Check if account exists in the database
    pub fn account_exists(self: *Database, address: [20]u8) bool {
        return self.accounts.contains(address);
    }

    /// Get account balance
    pub fn get_balance(self: *Database, address: [20]u8) Error!u256 {
        if (self.accounts.get(address)) |account| {
            return account.balance;
        }
        return 0; // Non-existent accounts have zero balance
    }

    // Storage operations

    /// Get storage value for the given address and key
    pub fn get_storage(self: *Database, address: [20]u8, key: u256) Error!u256 {
        const storage_key = StorageKey{ .address = address, .key = key };
        return self.storage.get(storage_key) orelse 0;
    }

    /// Set storage value for the given address and key
    pub fn set_storage(self: *Database, address: [20]u8, key: u256, value: u256) Error!void {
        const storage_key = StorageKey{ .address = address, .key = key };
        try self.storage.put(storage_key, value);
    }

    // Transient storage operations

    /// Get transient storage value for the given address and key (EIP-1153)
    pub fn get_transient_storage(self: *Database, address: [20]u8, key: u256) Error!u256 {
        const storage_key = StorageKey{ .address = address, .key = key };
        return self.transient_storage.get(storage_key) orelse 0;
    }

    /// Set transient storage value for the given address and key (EIP-1153)
    pub fn set_transient_storage(self: *Database, address: [20]u8, key: u256, value: u256) Error!void {
        const storage_key = StorageKey{ .address = address, .key = key };
        try self.transient_storage.put(storage_key, value);
    }

    // Code operations

    /// Get contract code by hash
    pub fn get_code(self: *Database, code_hash: [32]u8) Error![]const u8 {
        return self.code_storage.get(code_hash) orelse return Error.CodeNotFound;
    }

    /// Get contract code by address
    pub fn get_code_by_address(self: *Database, address: [20]u8) Error![]const u8 {
        const log = std.log.scoped(.database);
        log.debug("get_code_by_address: Looking for address {x}", .{address});
        
        if (self.accounts.get(address)) |account| {
            log.debug("get_code_by_address: Found account with code_hash {x}", .{account.code_hash});
            return self.get_code(account.code_hash);
        }
        
        log.debug("get_code_by_address: Account not found for address {x}", .{address});
        return Error.AccountNotFound;
    }

    /// Store contract code and return its hash
    pub fn set_code(self: *Database, code: []const u8) Error![32]u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(code, &hash, .{});
        try self.code_storage.put(hash, code);
        return hash;
    }

    // State root operations

    /// Get current state root hash
    pub fn get_state_root(self: *Database) Error![32]u8 {
        _ = self;
        return [_]u8{0xAB} ** 32; // Mock state root
    }

    /// Commit pending changes and return new state root
    pub fn commit_changes(self: *Database) Error![32]u8 {
        return self.get_state_root();
    }

    // Snapshot operations

    /// Create a state snapshot and return its ID
    pub fn create_snapshot(self: *Database) Error!u64 {
        const snapshot_id = self.next_snapshot_id;
        self.next_snapshot_id += 1;

        var snapshot_accounts = std.HashMap([20]u8, Account, ArrayHashContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        var accounts_iter = self.accounts.iterator();
        while (accounts_iter.next()) |entry| {
            try snapshot_accounts.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var snapshot_storage = std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        var storage_iter = self.storage.iterator();
        while (storage_iter.next()) |entry| {
            try snapshot_storage.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        try self.snapshots.append(self.allocator, Snapshot{
            .id = snapshot_id,
            .accounts = snapshot_accounts,
            .storage = snapshot_storage,
        });

        return snapshot_id;
    }

    /// Revert state to the given snapshot
    pub fn revert_to_snapshot(self: *Database, snapshot_id: u64) Error!void {
        var snapshot_index: ?usize = null;
        for (self.snapshots.items, 0..) |snapshot, i| {
            if (snapshot.id == snapshot_id) {
                snapshot_index = i;
                break;
            }
        }

        const index = snapshot_index orelse return Error.SnapshotNotFound;
        const snapshot = &self.snapshots.items[index];

        self.accounts.deinit();
        self.storage.deinit();

        self.accounts = std.HashMap([20]u8, Account, ArrayHashContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        self.storage = std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage).init(self.allocator);

        var accounts_iter = snapshot.accounts.iterator();
        while (accounts_iter.next()) |entry| {
            try self.accounts.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var storage_iter = snapshot.storage.iterator();
        while (storage_iter.next()) |entry| {
            try self.storage.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        // Remove this snapshot and all later ones
        for (self.snapshots.items[index..]) |*snap| {
            snap.accounts.deinit();
            snap.storage.deinit();
        }
        self.snapshots.shrinkRetainingCapacity(index);
    }

    /// Commit a snapshot (discard it without reverting)
    pub fn commit_snapshot(self: *Database, snapshot_id: u64) Error!void {
        var snapshot_index: ?usize = null;
        for (self.snapshots.items, 0..) |snapshot, i| {
            if (snapshot.id == snapshot_id) {
                snapshot_index = i;
                break;
            }
        }

        const index = snapshot_index orelse return Error.SnapshotNotFound;

        // Clean up this snapshot and all later ones
        for (self.snapshots.items[index..]) |*snapshot| {
            snapshot.accounts.deinit();
            snapshot.storage.deinit();
        }
        self.snapshots.shrinkRetainingCapacity(index);
    }

    // Batch operations (simple implementation)

    /// Begin a batch operation for efficient bulk updates
    pub fn begin_batch(self: *Database) Error!void {
        _ = self;
        // In a real implementation, this would prepare batch state
    }

    /// Commit all changes in the current batch
    pub fn commit_batch(self: *Database) Error!void {
        _ = self;
        // In a real implementation, this would commit all batched operations
    }

    /// Rollback all changes in the current batch
    pub fn rollback_batch(self: *Database) Error!void {
        _ = self;
        // In a real implementation, this would rollback all batched operations
    }
};

// Compile-time validation helper
/// Validates that a type can be used as a database implementation
pub fn validate_database_implementation(comptime T: type) void {
    // Check for required methods at compile time
    if (!@hasDecl(T, "get_account")) @compileError("Database implementation missing get_account method");
    if (!@hasDecl(T, "set_account")) @compileError("Database implementation missing set_account method");
    if (!@hasDecl(T, "delete_account")) @compileError("Database implementation missing delete_account method");
    if (!@hasDecl(T, "account_exists")) @compileError("Database implementation missing account_exists method");
    if (!@hasDecl(T, "get_balance")) @compileError("Database implementation missing get_balance method");
    if (!@hasDecl(T, "get_storage")) @compileError("Database implementation missing get_storage method");
    if (!@hasDecl(T, "set_storage")) @compileError("Database implementation missing set_storage method");
    if (!@hasDecl(T, "get_transient_storage")) @compileError("Database implementation missing get_transient_storage method");
    if (!@hasDecl(T, "set_transient_storage")) @compileError("Database implementation missing set_transient_storage method");
    if (!@hasDecl(T, "get_code")) @compileError("Database implementation missing get_code method");
    if (!@hasDecl(T, "get_code_by_address")) @compileError("Database implementation missing get_code_by_address method");
    if (!@hasDecl(T, "set_code")) @compileError("Database implementation missing set_code method");
    if (!@hasDecl(T, "get_state_root")) @compileError("Database implementation missing get_state_root method");
    if (!@hasDecl(T, "commit_changes")) @compileError("Database implementation missing commit_changes method");
    if (!@hasDecl(T, "create_snapshot")) @compileError("Database implementation missing create_snapshot method");
    if (!@hasDecl(T, "revert_to_snapshot")) @compileError("Database implementation missing revert_to_snapshot method");
    if (!@hasDecl(T, "commit_snapshot")) @compileError("Database implementation missing commit_snapshot method");
    if (!@hasDecl(T, "begin_batch")) @compileError("Database implementation missing begin_batch method");
    if (!@hasDecl(T, "commit_batch")) @compileError("Database implementation missing commit_batch method");
    if (!@hasDecl(T, "rollback_batch")) @compileError("Database implementation missing rollback_batch method");
    if (!@hasDecl(T, "deinit")) @compileError("Database implementation missing deinit method");
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "Database operations work correctly" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const test_address = [_]u8{0x12} ++ [_]u8{0} ** 19;

    // Test account operations
    try testing.expect(!db.account_exists(test_address));
    try testing.expectEqual(@as(?Account, null), try db.get_account(test_address));

    var test_account = Account{
        .balance = 1000,
        .nonce = 5,
        .code_hash = [_]u8{0xAB} ** 32,
        .storage_root = [_]u8{0xCD} ** 32,
    };

    try db.set_account(test_address, test_account);
    try testing.expect(db.account_exists(test_address));

    const retrieved_account = (try db.get_account(test_address)).?;
    try testing.expectEqual(test_account.balance, retrieved_account.balance);
    try testing.expectEqual(test_account.nonce, retrieved_account.nonce);
    try testing.expectEqualSlices(u8, &test_account.code_hash, &retrieved_account.code_hash);
    try testing.expectEqualSlices(u8, &test_account.storage_root, &retrieved_account.storage_root);

    try testing.expectEqual(@as(u256, 1000), try db.get_balance(test_address));
}

test "Database storage operations" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const test_address = [_]u8{0x34} ++ [_]u8{0} ** 19;
    const storage_key: u256 = 0x123456789ABCDEF;
    const storage_value: u256 = 0xFEDCBA987654321;

    // Initially storage should be zero
    try testing.expectEqual(@as(u256, 0), try db.get_storage(test_address, storage_key));

    // Set storage value
    try db.set_storage(test_address, storage_key, storage_value);
    try testing.expectEqual(storage_value, try db.get_storage(test_address, storage_key));
}

test "Database transient storage operations" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const test_address = [_]u8{0x56} ++ [_]u8{0} ** 19;
    const storage_key: u256 = 0x987654321;
    const storage_value: u256 = 0x123456789;

    // Initially transient storage should be zero
    try testing.expectEqual(@as(u256, 0), try db.get_transient_storage(test_address, storage_key));

    // Set transient storage value
    try db.set_transient_storage(test_address, storage_key, storage_value);
    try testing.expectEqual(storage_value, try db.get_transient_storage(test_address, storage_key));
}

test "Database code operations" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const test_code = "608060405234801561001057600080fd5b50";
    const test_bytes = std.fmt.hexToBytes(allocator, test_code) catch unreachable;
    defer allocator.free(test_bytes);

    // Store code and get hash
    const code_hash = try db.set_code(test_bytes);
    
    // Verify code can be retrieved by hash
    const retrieved_code = try db.get_code(code_hash);
    try testing.expectEqualSlices(u8, test_bytes, retrieved_code);

    // Test with account having this code
    const test_address = [_]u8{0x78} ++ [_]u8{0} ** 19;
    const account = Account{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };

    try db.set_account(test_address, account);
    
    // Get code by address should work
    const code_by_addr = try db.get_code_by_address(test_address);
    try testing.expectEqualSlices(u8, test_bytes, code_by_addr);
}

test "Database code operations - missing code" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const invalid_hash = [_]u8{0xFF} ** 32;
    try testing.expectError(Database.Error.CodeNotFound, db.get_code(invalid_hash));

    const test_address = [_]u8{0x99} ++ [_]u8{0} ** 19;
    try testing.expectError(Database.Error.AccountNotFound, db.get_code_by_address(test_address));
}

test "Database account operations" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr1 = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const addr2 = [_]u8{0x02} ++ [_]u8{0} ** 19;

    // Initially no accounts exist
    try testing.expect(!db.account_exists(addr1));
    try testing.expect(!db.account_exists(addr2));
    try testing.expectEqual(@as(u256, 0), try db.get_balance(addr1));

    // Create account
    const account1 = Account{
        .balance = 1000,
        .nonce = 5,
        .code_hash = [_]u8{0xAA} ** 32,
        .storage_root = [_]u8{0xBB} ** 32,
    };
    
    try db.set_account(addr1, account1);
    try testing.expect(db.account_exists(addr1));
    try testing.expectEqual(@as(u256, 1000), try db.get_balance(addr1));

    // Delete account
    try db.delete_account(addr1);
    try testing.expect(!db.account_exists(addr1));
    try testing.expectEqual(@as(u256, 0), try db.get_balance(addr1));
}

test "Database snapshot operations" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr1 = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const addr2 = [_]u8{0x02} ++ [_]u8{0} ** 19;
    const storage_key: u256 = 42;

    // Initial state
    const account1 = Account{ .balance = 100, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    try db.set_account(addr1, account1);
    try db.set_storage(addr1, storage_key, 999);

    // Create snapshot
    const snapshot_id = try db.create_snapshot();

    // Make changes
    const account2 = Account{ .balance = 200, .nonce = 2, .code_hash = [_]u8{1} ** 32, .storage_root = [_]u8{1} ** 32 };
    try db.set_account(addr1, account2);
    try db.set_account(addr2, account2);
    try db.set_storage(addr1, storage_key, 777);

    // Verify changes are present
    const retrieved = (try db.get_account(addr1)).?;
    try testing.expectEqual(@as(u256, 200), retrieved.balance);
    try testing.expectEqual(@as(u64, 2), retrieved.nonce);
    try testing.expect(db.account_exists(addr2));
    try testing.expectEqual(@as(u256, 777), try db.get_storage(addr1, storage_key));

    // Revert to snapshot
    try db.revert_to_snapshot(snapshot_id);

    // Verify state is reverted
    const reverted = (try db.get_account(addr1)).?;
    try testing.expectEqual(@as(u256, 100), reverted.balance);
    try testing.expectEqual(@as(u64, 1), reverted.nonce);
    try testing.expect(!db.account_exists(addr2));
    try testing.expectEqual(@as(u256, 999), try db.get_storage(addr1, storage_key));
}

test "Database snapshot operations - invalid snapshot" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    // Try to revert to non-existent snapshot
    try testing.expectError(Database.Error.SnapshotNotFound, db.revert_to_snapshot(999));
    try testing.expectError(Database.Error.SnapshotNotFound, db.commit_snapshot(999));
}

test "Database multiple snapshots" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x01} ++ [_]u8{0} ** 19;
    
    // Initial state
    const initial_account = Account{ .balance = 100, .nonce = 0, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    try db.set_account(addr, initial_account);

    // First snapshot
    const snapshot1 = try db.create_snapshot();
    const account1 = Account{ .balance = 200, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    try db.set_account(addr, account1);

    // Second snapshot
    const snapshot2 = try db.create_snapshot();
    const account2 = Account{ .balance = 300, .nonce = 2, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    try db.set_account(addr, account2);

    // Verify final state
    try testing.expectEqual(@as(u256, 300), try db.get_balance(addr));

    // Revert to snapshot2
    try db.revert_to_snapshot(snapshot2);
    try testing.expectEqual(@as(u256, 200), try db.get_balance(addr));

    // Revert to snapshot1
    try db.revert_to_snapshot(snapshot1);
    try testing.expectEqual(@as(u256, 100), try db.get_balance(addr));
}

test "Database commit snapshot" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x01} ++ [_]u8{0} ** 19;
    
    // Initial state
    const account = Account{ .balance = 100, .nonce = 0, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    try db.set_account(addr, account);

    // Create snapshot and make changes
    const snapshot_id = try db.create_snapshot();
    const new_account = Account{ .balance = 200, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    try db.set_account(addr, new_account);

    // Commit snapshot (discard it)
    try db.commit_snapshot(snapshot_id);

    // Changes should remain
    try testing.expectEqual(@as(u256, 200), try db.get_balance(addr));
    
    // Cannot revert to committed snapshot
    try testing.expectError(Database.Error.SnapshotNotFound, db.revert_to_snapshot(snapshot_id));
}

test "Database state root operations" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    // Get state root (mock implementation returns fixed value)
    const root1 = try db.get_state_root();
    try testing.expectEqualSlices(u8, &([_]u8{0xAB} ** 32), &root1);

    // Commit changes (should return same mock value)
    const root2 = try db.commit_changes();
    try testing.expectEqualSlices(u8, &([_]u8{0xAB} ** 32), &root2);
}

test "Database batch operations" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    // Batch operations are currently no-ops but should not error
    try db.begin_batch();
    try db.commit_batch();
    try db.rollback_batch();
}

test "Database storage key collision handling" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr1 = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const addr2 = [_]u8{0x02} ++ [_]u8{0} ** 19;
    const key: u256 = 42;

    // Set storage for different addresses with same key
    try db.set_storage(addr1, key, 100);
    try db.set_storage(addr2, key, 200);

    // Should be independent
    try testing.expectEqual(@as(u256, 100), try db.get_storage(addr1, key));
    try testing.expectEqual(@as(u256, 200), try db.get_storage(addr2, key));

    // Same for transient storage
    try db.set_transient_storage(addr1, key, 300);
    try db.set_transient_storage(addr2, key, 400);

    try testing.expectEqual(@as(u256, 300), try db.get_transient_storage(addr1, key));
    try testing.expectEqual(@as(u256, 400), try db.get_transient_storage(addr2, key));
}

test "Database large values" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0xFF} ** 20;
    const large_value: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    const large_key: u256 = 0x123456789ABCDEF123456789ABCDEF123456789ABCDEF123456789ABCDEF12345;
    
    // Test with maximum values
    const account = Account{
        .balance = large_value,
        .nonce = std.math.maxInt(u64),
        .code_hash = [_]u8{0xFF} ** 32,
        .storage_root = [_]u8{0xFF} ** 32,
    };

    try db.set_account(addr, account);
    try db.set_storage(addr, large_key, large_value);
    try db.set_transient_storage(addr, large_key, large_value);

    // Verify large values are stored correctly
    const retrieved = (try db.get_account(addr)).?;
    try testing.expectEqual(large_value, retrieved.balance);
    try testing.expectEqual(std.math.maxInt(u64), retrieved.nonce);
    try testing.expectEqual(large_value, try db.get_storage(addr, large_key));
    try testing.expectEqual(large_value, try db.get_transient_storage(addr, large_key));
}

test "Database empty code handling" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    // Store empty code
    const empty_code: []const u8 = &.{};
    const code_hash = try db.set_code(empty_code);
    
    // Should be able to retrieve empty code
    const retrieved = try db.get_code(code_hash);
    try testing.expectEqual(@as(usize, 0), retrieved.len);
}

test "Database validation test" {
    // Compile-time validation should pass for Database type
    validate_database_implementation(Database);
}
