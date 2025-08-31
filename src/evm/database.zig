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

    /// Get contract code by address (supports EIP-7702 delegation)
    pub fn get_code_by_address(self: *Database, address: [20]u8) Error![]const u8 {
        const log = std.log.scoped(.database);
        log.debug("get_code_by_address: Looking for address {x}", .{address});
        
        if (self.accounts.get(address)) |account| {
            // EIP-7702: Check if this EOA has delegated code
            if (account.get_effective_code_address()) |delegated_addr| {
                log.debug("get_code_by_address: EOA has delegation to {x}", .{delegated_addr.bytes});
                // Recursively get code from delegated address
                return self.get_code_by_address(delegated_addr.bytes);
            }
            
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

    // EIP-7702 Delegation operations

    /// Set delegation for an EOA to execute another address's code
    pub fn set_delegation(self: *Database, eoa_address: [20]u8, delegated_address: [20]u8) Error!void {
        const log = std.log.scoped(.database);
        
        // Get or create the EOA account
        var account = (try self.get_account(eoa_address)) orelse Account.zero();
        
        // Only EOAs can have delegations (no existing code)
        if (!std.mem.eql(u8, &account.code_hash, &[_]u8{0} ** 32)) {
            log.debug("set_delegation: Address {x} is a contract, cannot set delegation", .{eoa_address});
            return Error.InvalidAddress;
        }
        
        // Convert to Address type for the delegation
        const primitives = @import("primitives");
        const delegate_addr = primitives.Address.Address{ .bytes = delegated_address };
        
        account.set_delegation(delegate_addr);
        try self.set_account(eoa_address, account);
        
        log.debug("set_delegation: Set delegation for EOA {x} to {x}", .{ eoa_address, delegated_address });
    }

    /// Clear delegation for an EOA
    pub fn clear_delegation(self: *Database, eoa_address: [20]u8) Error!void {
        const log = std.log.scoped(.database);
        
        if (try self.get_account(eoa_address)) |*account| {
            account.clear_delegation();
            try self.set_account(eoa_address, account.*);
            log.debug("clear_delegation: Cleared delegation for EOA {x}", .{eoa_address});
        }
    }

    /// Check if an address has a delegation
    pub fn has_delegation(self: *Database, address: [20]u8) Error!bool {
        if (try self.get_account(address)) |account| {
            return account.has_delegation();
        }
        return false;
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

test "Database code storage operations" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const test_address = [_]u8{0x78} ++ [_]u8{0} ** 19;
    const test_code = [_]u8{ 0x60, 0x80, 0x60, 0x40, 0x52 }; // Simple bytecode

    // Test code storage
    const code_hash = try db.set_code(&test_code);
    const retrieved_code = try db.get_code(code_hash);
    try testing.expectEqualSlices(u8, &test_code, retrieved_code);

    // Test code by address - should fail for non-existent account
    try testing.expectError(Database.Error.AccountNotFound, db.get_code_by_address(test_address));

    // Create account with code hash
    const test_account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(test_address, test_account);

    // Now code by address should work
    const code_by_address = try db.get_code_by_address(test_address);
    try testing.expectEqualSlices(u8, &test_code, code_by_address);
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

test "Database delete account operations" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const test_address = [_]u8{0x99} ++ [_]u8{0} ** 19;
    const test_account = Account{
        .balance = 500,
        .nonce = 3,
        .code_hash = [_]u8{0x11} ** 32,
        .storage_root = [_]u8{0x22} ** 32,
    };

    // Create account
    try db.set_account(test_address, test_account);
    try testing.expect(db.account_exists(test_address));

    // Delete account
    try db.delete_account(test_address);
    try testing.expect(!db.account_exists(test_address));
    try testing.expectEqual(@as(?Account, null), try db.get_account(test_address));
    try testing.expectEqual(@as(u256, 0), try db.get_balance(test_address));
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

test "Database state root operations - detailed" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    // Test mock state root
    const state_root = try db.get_state_root();
    try testing.expectEqual([_]u8{0xAB} ** 32, state_root);

    // Test commit changes (returns same mock state root)
    const committed_root = try db.commit_changes();
    try testing.expectEqual(state_root, committed_root);
}

test "Database snapshot operations - detailed" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr1 = [_]u8{0xA1} ++ [_]u8{0} ** 19;
    const addr2 = [_]u8{0xA2} ++ [_]u8{0} ** 19;
    
    const account1 = Account{
        .balance = 100,
        .nonce = 1,
        .code_hash = [_]u8{0x11} ** 32,
        .storage_root = [_]u8{0x22} ** 32,
    };

    // Set initial state
    try db.set_account(addr1, account1);
    try db.set_storage(addr1, 0x123, 0xABC);

    // Create snapshot
    const snapshot_id = try db.create_snapshot();
    try testing.expectEqual(@as(u64, 1), snapshot_id);

    // Modify state after snapshot
    const account2 = Account{
        .balance = 200,
        .nonce = 2,
        .code_hash = [_]u8{0x33} ** 32,
        .storage_root = [_]u8{0x44} ** 32,
    };
    try db.set_account(addr2, account2);
    try db.set_storage(addr1, 0x123, 0xDEF);

    // Verify modified state
    try testing.expect(db.account_exists(addr2));
    try testing.expectEqual(@as(u256, 0xDEF), try db.get_storage(addr1, 0x123));

    // Revert to snapshot
    try db.revert_to_snapshot(snapshot_id);

    // Verify original state restored
    try testing.expect(!db.account_exists(addr2));
    try testing.expectEqual(@as(u256, 0xABC), try db.get_storage(addr1, 0x123));
    const restored_account = (try db.get_account(addr1)).?;
    try testing.expectEqual(account1.balance, restored_account.balance);
}

test "Database commit snapshot operations - detailed" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr1 = [_]u8{0xB1} ++ [_]u8{0} ** 19;
    const account1 = Account{
        .balance = 300,
        .nonce = 5,
        .code_hash = [_]u8{0x55} ** 32,
        .storage_root = [_]u8{0x66} ** 32,
    };

    try db.set_account(addr1, account1);
    
    // Create snapshot
    const snapshot_id = try db.create_snapshot();

    // Modify state
    try db.set_storage(addr1, 0x456, 0x789);

    // Commit snapshot (discard without reverting)
    try db.commit_snapshot(snapshot_id);

    // State should remain modified
    try testing.expectEqual(@as(u256, 0x789), try db.get_storage(addr1, 0x456));

    // Cannot revert to committed snapshot
    try testing.expectError(Database.Error.SnapshotNotFound, db.revert_to_snapshot(snapshot_id));
}

test "Database multiple snapshots - detailed" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr1 = [_]u8{0xC1} ++ [_]u8{0} ** 19;

    // Initial state
    try db.set_storage(addr1, 0x100, 0x200);

    // Snapshot 1
    const snap1 = try db.create_snapshot();
    try db.set_storage(addr1, 0x100, 0x300);

    // Snapshot 2
    const snap2 = try db.create_snapshot();
    try db.set_storage(addr1, 0x100, 0x400);

    // Verify final state
    try testing.expectEqual(@as(u256, 0x400), try db.get_storage(addr1, 0x100));

    // Revert to snapshot 2
    try db.revert_to_snapshot(snap2);
    try testing.expectEqual(@as(u256, 0x300), try db.get_storage(addr1, 0x100));

    // Revert to snapshot 1
    try db.revert_to_snapshot(snap1);
    try testing.expectEqual(@as(u256, 0x200), try db.get_storage(addr1, 0x100));

    // Cannot revert to non-existent snapshot
    try testing.expectError(Database.Error.SnapshotNotFound, db.revert_to_snapshot(snap2));
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

test "Database error cases" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const non_existent_hash = [_]u8{0xFF} ** 32;

    // Code not found error
    try testing.expectError(Database.Error.CodeNotFound, db.get_code(non_existent_hash));

    // Account not found for code by address
    const non_existent_addr = [_]u8{0xEE} ++ [_]u8{0} ** 19;
    try testing.expectError(Database.Error.AccountNotFound, db.get_code_by_address(non_existent_addr));

    // Snapshot not found
    try testing.expectError(Database.Error.SnapshotNotFound, db.revert_to_snapshot(999));
    try testing.expectError(Database.Error.SnapshotNotFound, db.commit_snapshot(999));
}

test "Database zero address handling" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const zero_address = [_]u8{0} ** 20;
    const account = Account{
        .balance = 1000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };

    // Should handle zero address like any other address
    try db.set_account(zero_address, account);
    try testing.expect(db.account_exists(zero_address));
    try testing.expectEqual(@as(u256, 1000), try db.get_balance(zero_address));

    // Storage operations with zero address
    try db.set_storage(zero_address, 0, 42);
    try testing.expectEqual(@as(u256, 42), try db.get_storage(zero_address, 0));
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

test "Database max values" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const max_address = [_]u8{0xFF} ** 20;
    const max_u256 = std.math.maxInt(u256);
    const max_nonce = std.math.maxInt(u64);
    
    const max_account = Account{
        .balance = max_u256,
        .nonce = max_nonce,
        .code_hash = [_]u8{0xFF} ** 32,
        .storage_root = [_]u8{0xFF} ** 32,
    };

    // Test maximum values
    try db.set_account(max_address, max_account);
    try testing.expectEqual(max_u256, try db.get_balance(max_address));

    // Storage with max values
    try db.set_storage(max_address, max_u256, max_u256);
    try testing.expectEqual(max_u256, try db.get_storage(max_address, max_u256));

    // Transient storage with max values
    try db.set_transient_storage(max_address, max_u256, max_u256);
    try testing.expectEqual(max_u256, try db.get_transient_storage(max_address, max_u256));
}

test "Database hash map stress test" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    // Test many accounts
    const num_accounts = 1000;
    for (0..num_accounts) |i| {
        var addr: [20]u8 = [_]u8{0} ** 20;
        addr[16] = @intCast((i >> 24) & 0xFF);
        addr[17] = @intCast((i >> 16) & 0xFF);
        addr[18] = @intCast((i >> 8) & 0xFF);
        addr[19] = @intCast(i & 0xFF);

        const account = Account{
            .balance = @intCast(i),
            .nonce = @intCast(i % 1000),
            .code_hash = [_]u8{@intCast(i & 0xFF)} ** 32,
            .storage_root = [_]u8{@intCast((i + 1) & 0xFF)} ** 32,
        };

        try db.set_account(addr, account);
    }

    // Verify all accounts
    for (0..num_accounts) |i| {
        var addr: [20]u8 = [_]u8{0} ** 20;
        addr[16] = @intCast((i >> 24) & 0xFF);
        addr[17] = @intCast((i >> 16) & 0xFF);
        addr[18] = @intCast((i >> 8) & 0xFF);
        addr[19] = @intCast(i & 0xFF);

        try testing.expect(db.account_exists(addr));
        try testing.expectEqual(@as(u256, @intCast(i)), try db.get_balance(addr));
    }
}

test "Database storage isolation between addresses" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr1 = [_]u8{0x11} ++ [_]u8{0} ** 19;
    const addr2 = [_]u8{0x22} ++ [_]u8{0} ** 19;
    const storage_key: u256 = 42;

    // Set same storage key for different addresses
    try db.set_storage(addr1, storage_key, 100);
    try db.set_storage(addr2, storage_key, 200);

    // Verify isolation
    try testing.expectEqual(@as(u256, 100), try db.get_storage(addr1, storage_key));
    try testing.expectEqual(@as(u256, 200), try db.get_storage(addr2, storage_key));

    // Test transient storage isolation
    try db.set_transient_storage(addr1, storage_key, 300);
    try db.set_transient_storage(addr2, storage_key, 400);

    try testing.expectEqual(@as(u256, 300), try db.get_transient_storage(addr1, storage_key));
    try testing.expectEqual(@as(u256, 400), try db.get_transient_storage(addr2, storage_key));
}

test "Database storage key collision resistance" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    // Test keys that might cause hash collisions
    const addr = [_]u8{0x33} ++ [_]u8{0} ** 19;
    const keys = [_]u256{ 0, 1, 0x100, 0x10000, 0x100000000, std.math.maxInt(u256) };
    
    // Set different values for each key
    for (keys, 0..) |key, i| {
        try db.set_storage(addr, key, @intCast(i + 1000));
    }

    // Verify each key has correct value
    for (keys, 0..) |key, i| {
        try testing.expectEqual(@as(u256, @intCast(i + 1000)), try db.get_storage(addr, key));
    }
}

test "Database overwrite operations" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x44} ++ [_]u8{0} ** 19;
    const storage_key: u256 = 777;

    const account1 = Account{
        .balance = 100,
        .nonce = 1,
        .code_hash = [_]u8{0x11} ** 32,
        .storage_root = [_]u8{0x22} ** 32,
    };

    const account2 = Account{
        .balance = 200,
        .nonce = 2,
        .code_hash = [_]u8{0x33} ** 32,
        .storage_root = [_]u8{0x44} ** 32,
    };

    // Set initial account and storage
    try db.set_account(addr, account1);
    try db.set_storage(addr, storage_key, 111);
    try db.set_transient_storage(addr, storage_key, 222);

    // Verify initial values
    try testing.expectEqual(@as(u256, 100), try db.get_balance(addr));
    try testing.expectEqual(@as(u256, 111), try db.get_storage(addr, storage_key));
    try testing.expectEqual(@as(u256, 222), try db.get_transient_storage(addr, storage_key));

    // Overwrite values
    try db.set_account(addr, account2);
    try db.set_storage(addr, storage_key, 333);
    try db.set_transient_storage(addr, storage_key, 444);

    // Verify overwritten values
    try testing.expectEqual(@as(u256, 200), try db.get_balance(addr));
    try testing.expectEqual(@as(u256, 333), try db.get_storage(addr, storage_key));
    try testing.expectEqual(@as(u256, 444), try db.get_transient_storage(addr, storage_key));
}

test "Database empty code hash handling" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const empty_code = [_]u8{};
    const code_hash = try db.set_code(&empty_code);
    
    // Empty code should still have a hash
    try testing.expect(code_hash.len == 32);
    
    const retrieved_code = try db.get_code(code_hash);
    try testing.expectEqualSlices(u8, &empty_code, retrieved_code);
}

test "Database large code storage" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    // Create large bytecode (24KB - EIP-170 limit)
    const large_code_size = 24576;
    const large_code = try allocator.alloc(u8, large_code_size);
    defer allocator.free(large_code);
    
    // Fill with pattern
    for (large_code, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    const code_hash = try db.set_code(large_code);
    const retrieved_code = try db.get_code(code_hash);
    try testing.expectEqualSlices(u8, large_code, retrieved_code);
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

test "Database validation function" {
    // Test compile-time validation
    validate_database_implementation(Database);
    
    // This would fail to compile if Database was missing required methods
    // validate_database_implementation(struct {}); // Uncomment to test failure
}

test "EIP-7702: Database delegation operations" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const eoa_address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const contract_address = [_]u8{0x02} ++ [_]u8{0} ** 19;
    const contract_code = [_]u8{ 0x60, 0x80, 0x60, 0x40, 0x52 }; // Simple bytecode

    // Store contract code
    const code_hash = try db.set_code(&contract_code);
    const contract_account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .delegated_address = null,
    };
    try db.set_account(contract_address, contract_account);

    // Set delegation from EOA to contract
    try db.set_delegation(eoa_address, contract_address);

    // Check delegation was set
    try testing.expect(try db.has_delegation(eoa_address));

    // Get code for EOA should return contract's code via delegation
    const eoa_code = try db.get_code_by_address(eoa_address);
    try testing.expectEqualSlices(u8, &contract_code, eoa_code);

    // Clear delegation
    try db.clear_delegation(eoa_address);
    try testing.expect(!(try db.has_delegation(eoa_address)));

    // Now get_code_by_address should fail for EOA
    try testing.expectError(Database.Error.AccountNotFound, db.get_code_by_address(eoa_address));
}

test "EIP-7702: Cannot set delegation on contract" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const contract_address = [_]u8{0x03} ++ [_]u8{0} ** 19;
    const delegate_address = [_]u8{0x04} ++ [_]u8{0} ** 19;
    
    // Create a contract account (has code)
    const code_hash = try db.set_code(&[_]u8{0x60});
    const contract_account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .delegated_address = null,
    };
    try db.set_account(contract_address, contract_account);

    // Try to set delegation on contract - should fail
    try testing.expectError(Database.Error.InvalidAddress, db.set_delegation(contract_address, delegate_address));
}

test "EIP-7702: Delegation chain resolution" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const eoa1_address = [_]u8{0x05} ++ [_]u8{0} ** 19;
    const eoa2_address = [_]u8{0x06} ++ [_]u8{0} ** 19;
    const contract_address = [_]u8{0x07} ++ [_]u8{0} ** 19;
    const contract_code = [_]u8{ 0x60, 0xFF }; // PUSH1 0xFF

    // Store contract code
    const code_hash = try db.set_code(&contract_code);
    const contract_account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .delegated_address = null,
    };
    try db.set_account(contract_address, contract_account);

    // EOA1 delegates to EOA2
    try db.set_delegation(eoa1_address, eoa2_address);
    
    // EOA2 delegates to contract
    try db.set_delegation(eoa2_address, contract_address);

    // Getting code for EOA1 should resolve through the delegation chain
    const eoa1_code = try db.get_code_by_address(eoa1_address);
    try testing.expectEqualSlices(u8, &contract_code, eoa1_code);
}

test "Database validation test" {
    // Compile-time validation should pass for Database type
    validate_database_implementation(Database);
}

test "Database state persistence across operations" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr1 = [_]u8{0x55} ++ [_]u8{0} ** 19;
    const addr2 = [_]u8{0x66} ++ [_]u8{0} ** 19;

    // Complex sequence of operations
    try db.set_storage(addr1, 1, 100);
    try db.set_transient_storage(addr1, 1, 200);
    
    _ = try db.create_snapshot(); // snapshot1 - used for state setup
    
    try db.set_storage(addr2, 1, 300);
    try db.set_transient_storage(addr2, 1, 400);
    
    const snapshot2 = try db.create_snapshot();
    
    try db.set_storage(addr1, 2, 500);
    
    // Verify intermediate state
    try testing.expectEqual(@as(u256, 100), try db.get_storage(addr1, 1));
    try testing.expectEqual(@as(u256, 200), try db.get_transient_storage(addr1, 1));
    try testing.expectEqual(@as(u256, 300), try db.get_storage(addr2, 1));
    try testing.expectEqual(@as(u256, 400), try db.get_transient_storage(addr2, 1));
    try testing.expectEqual(@as(u256, 500), try db.get_storage(addr1, 2));
    
    // Revert to snapshot2
    try db.revert_to_snapshot(snapshot2);
    try testing.expectEqual(@as(u256, 100), try db.get_storage(addr1, 1));
    try testing.expectEqual(@as(u256, 300), try db.get_storage(addr2, 1));
    try testing.expectEqual(@as(u256, 0), try db.get_storage(addr1, 2)); // Should be zero after revert
    
    // Note: transient storage behavior during snapshots might need clarification
    // as EIP-1153 specifies transient storage is cleared between transactions
}
