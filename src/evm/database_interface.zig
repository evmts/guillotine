//! Database Interface for Pluggable State Management
//! This module provides a vtable-based interface abstraction for EVM state storage,
//! allowing different backend implementations (memory, file, network, etc.) to be
//! swapped without changing the core EVM logic.
//!
//! ## Design Philosophy
//!
//! The interface uses Zig's vtable pattern to provide type-safe, runtime polymorphism
//! without the overhead of traditional virtual function calls. Each implementation
//! provides its own vtable with function pointers to its specific operations.
//!
//! ## Usage
//!
//! ```zig
//! // Create a memory database
//! var memory_db = MemoryDatabase.init(allocator);
//! defer memory_db.deinit();
//!
//! // Convert to interface
//! const db_interface = memory_db.to_database_interface();
//!
//! // Use through interface
//! const account = try db_interface.get_account(address);
//! try db_interface.set_account(address, updated_account);
//! ```
//!
//! ## Performance Considerations
//!
//! The vtable dispatch adds minimal overhead compared to direct function calls.
//! Hot paths should consider batching operations where possible to reduce the
//! number of interface calls.

const std = @import("std");
pub const Account = @import("database_interface_account.zig").Account;

/// Database interface using vtable pattern for pluggable implementations
pub const DatabaseInterface = struct {
    /// Pointer to the actual implementation
    ptr: *anyopaque,
    /// Function pointer table for the implementation
    vtable: *const VTable,

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
    };

    /// Virtual function table defining all database operations
    pub const VTable = struct {
        get_account: *const fn (ptr: *anyopaque, address: [20]u8) Error!?Account,
        set_account: *const fn (ptr: *anyopaque, address: [20]u8, account: Account) Error!void,
        delete_account: *const fn (ptr: *anyopaque, address: [20]u8) Error!void,
        account_exists: *const fn (ptr: *anyopaque, address: [20]u8) bool,
        get_balance: *const fn (ptr: *anyopaque, address: [20]u8) Error!u256,
        get_storage: *const fn (ptr: *anyopaque, address: [20]u8, key: u256) Error!u256,
        set_storage: *const fn (ptr: *anyopaque, address: [20]u8, key: u256, value: u256) Error!void,
        get_transient_storage: *const fn (ptr: *anyopaque, address: [20]u8, key: u256) Error!u256,
        set_transient_storage: *const fn (ptr: *anyopaque, address: [20]u8, key: u256, value: u256) Error!void,
        get_code: *const fn (ptr: *anyopaque, code_hash: [32]u8) Error![]const u8,
        get_code_by_address: *const fn (ptr: *anyopaque, address: [20]u8) Error![]const u8,
        set_code: *const fn (ptr: *anyopaque, code: []const u8) Error![32]u8,
        get_state_root: *const fn (ptr: *anyopaque) Error![32]u8,
        commit_changes: *const fn (ptr: *anyopaque) Error![32]u8,
        create_snapshot: *const fn (ptr: *anyopaque) Error!u64,
        revert_to_snapshot: *const fn (ptr: *anyopaque, snapshot_id: u64) Error!void,
        commit_snapshot: *const fn (ptr: *anyopaque, snapshot_id: u64) Error!void,
        begin_batch: *const fn (ptr: *anyopaque) Error!void,
        commit_batch: *const fn (ptr: *anyopaque) Error!void,
        rollback_batch: *const fn (ptr: *anyopaque) Error!void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    /// Convert this database interface to a static version that blocks writes
    /// This implements EIP-214 (STATICCALL) constraints
    /// IMPORTANT: The returned interface is only valid as long as this database is valid
    pub fn as_static(self: DatabaseInterface) DatabaseInterface {
        const StaticDatabase = @import("static_wrappers.zig").StaticDatabase;
        // We'll create a static wrapper that re-uses the existing database interface
        // This is a bit of a hack but works because the StaticDatabase just forwards or blocks calls
        return StaticDatabase.init(self).to_database_interface();
    }

    /// Initialize a database interface from any implementation
    ///
    /// This function uses Zig's compile-time type introspection to generate
    /// the appropriate vtable for the given implementation type.
    ///
    /// ## Parameters
    /// - `implementation`: Pointer to the database implementation
    ///
    /// ## Returns
    /// DatabaseInterface wrapping the implementation
    ///
    /// ## Type Requirements
    /// The implementation must provide all required methods with correct signatures
    pub fn init(implementation: anytype) DatabaseInterface {
        const Impl = @TypeOf(implementation);
        const impl_info = @typeInfo(Impl);
        if (impl_info != .pointer) {
            @compileError("Database interface requires a pointer to implementation");
        }
        const gen = struct {
            fn vtable_get_account(ptr: *anyopaque, address: [20]u8) Error!?Account {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_account(address);
            }
            fn vtable_set_account(ptr: *anyopaque, address: [20]u8, account: Account) Error!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.set_account(address, account);
            }
            fn vtable_delete_account(ptr: *anyopaque, address: [20]u8) Error!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.delete_account(address);
            }
            fn vtable_account_exists(ptr: *anyopaque, address: [20]u8) bool {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.account_exists(address);
            }
            fn vtable_get_balance(ptr: *anyopaque, address: [20]u8) Error!u256 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_balance(address);
            }
            fn vtable_get_storage(ptr: *anyopaque, address: [20]u8, key: u256) Error!u256 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_storage(address, key);
            }
            fn vtable_set_storage(ptr: *anyopaque, address: [20]u8, key: u256, value: u256) Error!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.set_storage(address, key, value);
            }
            fn vtable_get_transient_storage(ptr: *anyopaque, address: [20]u8, key: u256) Error!u256 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_transient_storage(address, key);
            }
            fn vtable_set_transient_storage(ptr: *anyopaque, address: [20]u8, key: u256, value: u256) Error!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.set_transient_storage(address, key, value);
            }
            fn vtable_get_code(ptr: *anyopaque, code_hash: [32]u8) Error![]const u8 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_code(code_hash);
            }
            fn vtable_get_code_by_address(ptr: *anyopaque, address: [20]u8) Error![]const u8 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_code_by_address(address);
            }
            fn vtable_set_code(ptr: *anyopaque, code: []const u8) Error![32]u8 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.set_code(code);
            }
            fn vtable_get_state_root(ptr: *anyopaque) Error![32]u8 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_state_root();
            }
            fn vtable_commit_changes(ptr: *anyopaque) Error![32]u8 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.commit_changes();
            }
            fn vtable_create_snapshot(ptr: *anyopaque) Error!u64 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.create_snapshot();
            }
            fn vtable_revert_to_snapshot(ptr: *anyopaque, snapshot_id: u64) Error!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.revert_to_snapshot(snapshot_id);
            }
            fn vtable_commit_snapshot(ptr: *anyopaque, snapshot_id: u64) Error!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.commit_snapshot(snapshot_id);
            }
            fn vtable_begin_batch(ptr: *anyopaque) Error!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.begin_batch();
            }
            fn vtable_commit_batch(ptr: *anyopaque) Error!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.commit_batch();
            }
            fn vtable_rollback_batch(ptr: *anyopaque) Error!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.rollback_batch();
            }
            fn vtable_deinit(ptr: *anyopaque) void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.deinit();
            }
            const vtable = VTable{
                .get_account = vtable_get_account,
                .set_account = vtable_set_account,
                .delete_account = vtable_delete_account,
                .account_exists = vtable_account_exists,
                .get_balance = vtable_get_balance,
                .get_storage = vtable_get_storage,
                .set_storage = vtable_set_storage,
                .get_transient_storage = vtable_get_transient_storage,
                .set_transient_storage = vtable_set_transient_storage,
                .get_code = vtable_get_code,
                .get_code_by_address = vtable_get_code_by_address,
                .set_code = vtable_set_code,
                .get_state_root = vtable_get_state_root,
                .commit_changes = vtable_commit_changes,
                .create_snapshot = vtable_create_snapshot,
                .revert_to_snapshot = vtable_revert_to_snapshot,
                .commit_snapshot = vtable_commit_snapshot,
                .begin_batch = vtable_begin_batch,
                .commit_batch = vtable_commit_batch,
                .rollback_batch = vtable_rollback_batch,
                .deinit = vtable_deinit,
            };
        };
        return DatabaseInterface{
            .ptr = implementation,
            .vtable = &gen.vtable,
        };
    }

    pub fn get_account(self: DatabaseInterface, address: [20]u8) Error!?Account {
        return self.vtable.get_account(self.ptr, address);
    }

    /// Set account data for the given address
    pub fn set_account(self: DatabaseInterface, address: [20]u8, account: Account) Error!void {
        return self.vtable.set_account(self.ptr, address, account);
    }

    /// Delete account and all associated data
    pub fn delete_account(self: DatabaseInterface, address: [20]u8) Error!void {
        return self.vtable.delete_account(self.ptr, address);
    }

    /// Check if account exists in the database
    pub fn account_exists(self: DatabaseInterface, address: [20]u8) bool {
        return self.vtable.account_exists(self.ptr, address);
    }

    /// Get account balance
    pub fn get_balance(self: DatabaseInterface, address: [20]u8) Error!u256 {
        return self.vtable.get_balance(self.ptr, address);
    }

    /// Get storage value for the given address and key
    pub fn get_storage(self: DatabaseInterface, address: [20]u8, key: u256) Error!u256 {
        return self.vtable.get_storage(self.ptr, address, key);
    }

    /// Set storage value for the given address and key
    pub fn set_storage(self: DatabaseInterface, address: [20]u8, key: u256, value: u256) Error!void {
        return self.vtable.set_storage(self.ptr, address, key, value);
    }

    /// Get transient storage value for the given address and key (EIP-1153)
    pub fn get_transient_storage(self: DatabaseInterface, address: [20]u8, key: u256) Error!u256 {
        return self.vtable.get_transient_storage(self.ptr, address, key);
    }

    /// Set transient storage value for the given address and key (EIP-1153)
    pub fn set_transient_storage(self: DatabaseInterface, address: [20]u8, key: u256, value: u256) Error!void {
        return self.vtable.set_transient_storage(self.ptr, address, key, value);
    }

    // Code operations

    /// Get contract code by hash
    pub fn get_code(self: DatabaseInterface, code_hash: [32]u8) Error![]const u8 {
        return self.vtable.get_code(self.ptr, code_hash);
    }

    /// Get contract code by address
    pub fn get_code_by_address(self: DatabaseInterface, address: [20]u8) Error![]const u8 {
        return self.vtable.get_code_by_address(self.ptr, address);
    }

    /// Store contract code and return its hash
    pub fn set_code(self: DatabaseInterface, code: []const u8) Error![32]u8 {
        return self.vtable.set_code(self.ptr, code);
    }

    // State root operations

    /// Get current state root hash
    pub fn get_state_root(self: DatabaseInterface) Error![32]u8 {
        return self.vtable.get_state_root(self.ptr);
    }

    /// Commit pending changes and return new state root
    pub fn commit_changes(self: DatabaseInterface) Error![32]u8 {
        return self.vtable.commit_changes(self.ptr);
    }

    // Snapshot operations

    /// Create a state snapshot and return its ID
    pub fn create_snapshot(self: DatabaseInterface) Error!u64 {
        return self.vtable.create_snapshot(self.ptr);
    }

    /// Revert state to the given snapshot
    pub fn revert_to_snapshot(self: DatabaseInterface, snapshot_id: u64) Error!void {
        return self.vtable.revert_to_snapshot(self.ptr, snapshot_id);
    }

    /// Commit a snapshot (discard it without reverting)
    pub fn commit_snapshot(self: DatabaseInterface, snapshot_id: u64) Error!void {
        return self.vtable.commit_snapshot(self.ptr, snapshot_id);
    }

    // Batch operations

    /// Begin a batch operation for efficient bulk updates
    pub fn begin_batch(self: DatabaseInterface) Error!void {
        return self.vtable.begin_batch(self.ptr);
    }

    /// Commit all changes in the current batch
    pub fn commit_batch(self: DatabaseInterface) Error!void {
        return self.vtable.commit_batch(self.ptr);
    }

    /// Rollback all changes in the current batch
    pub fn rollback_batch(self: DatabaseInterface) Error!void {
        return self.vtable.rollback_batch(self.ptr);
    }

    // Lifecycle

    /// Clean up database resources
    pub fn deinit(self: DatabaseInterface) void {
        return self.vtable.deinit(self.ptr);
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

// Mock database implementation for testing
const MockDatabase = struct {
    accounts: std.HashMap([20]u8, Account, ArrayHashContext, std.hash_map.default_max_load_percentage),
    storage: std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage),
    transient_storage: std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage),
    code_storage: std.HashMap([32]u8, []const u8, ArrayHashContext, std.hash_map.default_max_load_percentage),
    snapshots: std.ArrayList(MockSnapshot),
    next_snapshot_id: u64,
    allocator: std.mem.Allocator,
    
    const StorageKey = struct {
        address: [20]u8,
        key: u256,
    };
    
    const MockSnapshot = struct {
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
    
    pub fn init(allocator: std.mem.Allocator) MockDatabase {
        return MockDatabase{
            .accounts = std.HashMap([20]u8, Account, ArrayHashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .storage = std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .transient_storage = std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .code_storage = std.HashMap([32]u8, []const u8, ArrayHashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .snapshots = std.ArrayList(MockSnapshot).init(allocator),
            .next_snapshot_id = 1,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *MockDatabase) void {
        self.accounts.deinit();
        self.storage.deinit();
        self.transient_storage.deinit();
        self.code_storage.deinit();
        
        for (self.snapshots.items) |*snapshot| {
            snapshot.accounts.deinit();
            snapshot.storage.deinit();
        }
        self.snapshots.deinit();
    }
    
    // Account operations
    pub fn get_account(self: *MockDatabase, address: [20]u8) DatabaseInterface.Error!?Account {
        return self.accounts.get(address);
    }
    
    pub fn set_account(self: *MockDatabase, address: [20]u8, account: Account) DatabaseInterface.Error!void {
        try self.accounts.put(address, account);
    }
    
    pub fn delete_account(self: *MockDatabase, address: [20]u8) DatabaseInterface.Error!void {
        _ = self.accounts.remove(address);
    }
    
    pub fn account_exists(self: *MockDatabase, address: [20]u8) bool {
        return self.accounts.contains(address);
    }
    
    pub fn get_balance(self: *MockDatabase, address: [20]u8) DatabaseInterface.Error!u256 {
        if (self.accounts.get(address)) |account| {
            return account.balance;
        }
        return 0; // Non-existent accounts have zero balance
    }
    
    // Storage operations
    pub fn get_storage(self: *MockDatabase, address: [20]u8, key: u256) DatabaseInterface.Error!u256 {
        const storage_key = StorageKey{ .address = address, .key = key };
        return self.storage.get(storage_key) orelse 0;
    }
    
    pub fn set_storage(self: *MockDatabase, address: [20]u8, key: u256, value: u256) DatabaseInterface.Error!void {
        const storage_key = StorageKey{ .address = address, .key = key };
        try self.storage.put(storage_key, value);
    }
    
    // Transient storage operations
    pub fn get_transient_storage(self: *MockDatabase, address: [20]u8, key: u256) DatabaseInterface.Error!u256 {
        const storage_key = StorageKey{ .address = address, .key = key };
        return self.transient_storage.get(storage_key) orelse 0;
    }
    
    pub fn set_transient_storage(self: *MockDatabase, address: [20]u8, key: u256, value: u256) DatabaseInterface.Error!void {
        const storage_key = StorageKey{ .address = address, .key = key };
        try self.transient_storage.put(storage_key, value);
    }
    
    // Code operations
    pub fn get_code(self: *MockDatabase, code_hash: [32]u8) DatabaseInterface.Error![]const u8 {
        return self.code_storage.get(code_hash) orelse return DatabaseInterface.Error.CodeNotFound;
    }
    
    pub fn get_code_by_address(self: *MockDatabase, address: [20]u8) DatabaseInterface.Error![]const u8 {
        if (self.accounts.get(address)) |account| {
            return self.get_code(account.code_hash);
        }
        return DatabaseInterface.Error.AccountNotFound;
    }
    
    pub fn set_code(self: *MockDatabase, code: []const u8) DatabaseInterface.Error![32]u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(code, &hash, .{});
        try self.code_storage.put(hash, code);
        return hash;
    }
    
    // State root operations
    pub fn get_state_root(self: *MockDatabase) DatabaseInterface.Error![32]u8 {
        _ = self;
        return [_]u8{0xAB} ** 32; // Mock state root
    }
    
    pub fn commit_changes(self: *MockDatabase) DatabaseInterface.Error![32]u8 {
        return self.get_state_root();
    }
    
    // Snapshot operations
    pub fn create_snapshot(self: *MockDatabase) DatabaseInterface.Error!u64 {
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
        
        try self.snapshots.append(MockSnapshot{
            .id = snapshot_id,
            .accounts = snapshot_accounts,
            .storage = snapshot_storage,
        });
        
        return snapshot_id;
    }
    
    pub fn revert_to_snapshot(self: *MockDatabase, snapshot_id: u64) DatabaseInterface.Error!void {
        var snapshot_index: ?usize = null;
        for (self.snapshots.items, 0..) |snapshot, i| {
            if (snapshot.id == snapshot_id) {
                snapshot_index = i;
                break;
            }
        }
        
        const index = snapshot_index orelse return DatabaseInterface.Error.SnapshotNotFound;
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
    
    pub fn commit_snapshot(self: *MockDatabase, snapshot_id: u64) DatabaseInterface.Error!void {
        var snapshot_index: ?usize = null;
        for (self.snapshots.items, 0..) |snapshot, i| {
            if (snapshot.id == snapshot_id) {
                snapshot_index = i;
                break;
            }
        }
        
        const index = snapshot_index orelse return DatabaseInterface.Error.SnapshotNotFound;
        
        // Clean up this snapshot and all later ones
        for (self.snapshots.items[index..]) |*snapshot| {
            snapshot.accounts.deinit();
            snapshot.storage.deinit();
        }
        self.snapshots.shrinkRetainingCapacity(index);
    }
    
    // Batch operations (simple implementation)
    pub fn begin_batch(self: *MockDatabase) DatabaseInterface.Error!void {
        _ = self;
        // In a real implementation, this would prepare batch state
    }
    
    pub fn commit_batch(self: *MockDatabase) DatabaseInterface.Error!void {
        _ = self;
        // In a real implementation, this would commit all batched operations
    }
    
    pub fn rollback_batch(self: *MockDatabase) DatabaseInterface.Error!void {
        _ = self;
        // In a real implementation, this would rollback all batched operations
    }
};

test "DatabaseInterface vtable dispatch works correctly" {
    const allocator = testing.allocator;
    var mock_db = MockDatabase.init(allocator);
    defer mock_db.deinit();
    
    const db_interface = DatabaseInterface.init(&mock_db);
    
    const test_address = [_]u8{0x12} ++ [_]u8{0} ** 19;
    
    // Test account operations
    try testing.expect(!db_interface.account_exists(test_address));
    try testing.expectEqual(@as(?Account, null), try db_interface.get_account(test_address));
    
    var test_account = Account{
        .balance = 1000,
        .nonce = 5,
        .code_hash = [_]u8{0xAB} ** 32,
        .storage_root = [_]u8{0xCD} ** 32,
    };
    
    try db_interface.set_account(test_address, test_account);
    try testing.expect(db_interface.account_exists(test_address));
    
    const retrieved_account = (try db_interface.get_account(test_address)).?;
    try testing.expectEqual(test_account.balance, retrieved_account.balance);
    try testing.expectEqual(test_account.nonce, retrieved_account.nonce);
    try testing.expectEqualSlices(u8, &test_account.code_hash, &retrieved_account.code_hash);
    try testing.expectEqualSlices(u8, &test_account.storage_root, &retrieved_account.storage_root);
    
    try testing.expectEqual(@as(u256, 1000), try db_interface.get_balance(test_address));
}

test "DatabaseInterface storage operations" {
    const allocator = testing.allocator;
    var mock_db = MockDatabase.init(allocator);
    defer mock_db.deinit();
    
    const db_interface = DatabaseInterface.init(&mock_db);
    
    const test_address = [_]u8{0x34} ++ [_]u8{0} ** 19;
    const storage_key: u256 = 0x123456789ABCDEF;
    const storage_value: u256 = 0xFEDCBA987654321;
    
    // Initially storage should be zero
    try testing.expectEqual(@as(u256, 0), try db_interface.get_storage(test_address, storage_key));
    
    // Set storage value
    try db_interface.set_storage(test_address, storage_key, storage_value);
    try testing.expectEqual(storage_value, try db_interface.get_storage(test_address, storage_key));
}

test "DatabaseInterface transient storage operations" {
    const allocator = testing.allocator;
    var mock_db = MockDatabase.init(allocator);
    defer mock_db.deinit();
    
    const db_interface = DatabaseInterface.init(&mock_db);
    
    const test_address = [_]u8{0x56} ++ [_]u8{0} ** 19;
    const storage_key: u256 = 0x987654321;
    const storage_value: u256 = 0x123456789;
    
    // Initially transient storage should be zero
    try testing.expectEqual(@as(u256, 0), try db_interface.get_transient_storage(test_address, storage_key));
    
    // Set transient storage value
    try db_interface.set_transient_storage(test_address, storage_key, storage_value);
    try testing.expectEqual(storage_value, try db_interface.get_transient_storage(test_address, storage_key));
}

test "DatabaseInterface code operations" {
    const allocator = testing.allocator;
    var mock_db = MockDatabase.init(allocator);
    defer mock_db.deinit();
    
    const db_interface = DatabaseInterface.init(&mock_db);
    
    const test_code = "PUSH1 0x60 PUSH1 0x40 MSTORE";
    
    // Set code and get its hash
    const code_hash = try db_interface.set_code(test_code);
    
    // Retrieve code by hash
    const retrieved_code = try db_interface.get_code(code_hash);
    try testing.expectEqualSlices(u8, test_code, retrieved_code);
    
    // Test retrieving code for non-existent hash
    const fake_hash = [_]u8{0xFF} ** 32;
    try testing.expectError(DatabaseInterface.Error.CodeNotFound, db_interface.get_code(fake_hash));
}

test "DatabaseInterface code by address operations" {
    const allocator = testing.allocator;
    var mock_db = MockDatabase.init(allocator);
    defer mock_db.deinit();
    
    const db_interface = DatabaseInterface.init(&mock_db);
    
    const test_address = [_]u8{0x78} ++ [_]u8{0} ** 19;
    const test_code = "PUSH2 0x1234 RETURN";
    
    // Set code and get its hash
    const code_hash = try db_interface.set_code(test_code);
    
    // Create account with code hash
    const test_account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try db_interface.set_account(test_address, test_account);
    
    // Retrieve code by address
    const retrieved_code = try db_interface.get_code_by_address(test_address);
    try testing.expectEqualSlices(u8, test_code, retrieved_code);
    
    // Test retrieving code for non-existent address
    const fake_address = [_]u8{0xFF} ** 20;
    try testing.expectError(DatabaseInterface.Error.AccountNotFound, db_interface.get_code_by_address(fake_address));
}

test "DatabaseInterface snapshot operations" {
    const allocator = testing.allocator;
    var mock_db = MockDatabase.init(allocator);
    defer mock_db.deinit();
    
    const db_interface = DatabaseInterface.init(&mock_db);
    
    const test_address = [_]u8{0x9A} ++ [_]u8{0} ** 19;
    
    // Set initial account state
    const initial_account = Account{
        .balance = 500,
        .nonce = 1,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try db_interface.set_account(test_address, initial_account);
    try db_interface.set_storage(test_address, 1, 100);
    
    // Create snapshot
    const snapshot_id = try db_interface.create_snapshot();
    
    // Modify state
    const modified_account = Account{
        .balance = 1000,
        .nonce = 2,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try db_interface.set_account(test_address, modified_account);
    try db_interface.set_storage(test_address, 1, 200);
    
    // Verify modified state
    const current_account = (try db_interface.get_account(test_address)).?;
    try testing.expectEqual(@as(u256, 1000), current_account.balance);
    try testing.expectEqual(@as(u64, 2), current_account.nonce);
    try testing.expectEqual(@as(u256, 200), try db_interface.get_storage(test_address, 1));
    
    // Revert to snapshot
    try db_interface.revert_to_snapshot(snapshot_id);
    
    // Verify reverted state
    const reverted_account = (try db_interface.get_account(test_address)).?;
    try testing.expectEqual(@as(u256, 500), reverted_account.balance);
    try testing.expectEqual(@as(u64, 1), reverted_account.nonce);
    try testing.expectEqual(@as(u256, 100), try db_interface.get_storage(test_address, 1));
}

test "DatabaseInterface snapshot error handling" {
    const allocator = testing.allocator;
    var mock_db = MockDatabase.init(allocator);
    defer mock_db.deinit();
    
    const db_interface = DatabaseInterface.init(&mock_db);
    
    // Test reverting to non-existent snapshot
    try testing.expectError(DatabaseInterface.Error.SnapshotNotFound, db_interface.revert_to_snapshot(999));
    
    // Test committing non-existent snapshot
    try testing.expectError(DatabaseInterface.Error.SnapshotNotFound, db_interface.commit_snapshot(999));
}

test "DatabaseInterface state root operations" {
    const allocator = testing.allocator;
    var mock_db = MockDatabase.init(allocator);
    defer mock_db.deinit();
    
    const db_interface = DatabaseInterface.init(&mock_db);
    
    const state_root = try db_interface.get_state_root();
    try testing.expectEqualSlices(u8, &[_]u8{0xAB} ** 32, &state_root);
    
    const committed_root = try db_interface.commit_changes();
    try testing.expectEqualSlices(u8, &state_root, &committed_root);
}

test "DatabaseInterface batch operations" {
    const allocator = testing.allocator;
    var mock_db = MockDatabase.init(allocator);
    defer mock_db.deinit();
    
    const db_interface = DatabaseInterface.init(&mock_db);
    
    // Test batch operations (mock implementation doesn't do much)
    try db_interface.begin_batch();
    try db_interface.commit_batch();
    
    try db_interface.begin_batch();
    try db_interface.rollback_batch();
}

test "DatabaseInterface account deletion" {
    const allocator = testing.allocator;
    var mock_db = MockDatabase.init(allocator);
    defer mock_db.deinit();
    
    const db_interface = DatabaseInterface.init(&mock_db);
    
    const test_address = [_]u8{0xBC} ++ [_]u8{0} ** 19;
    const test_account = Account{
        .balance = 250,
        .nonce = 3,
        .code_hash = [_]u8{0x11} ** 32,
        .storage_root = [_]u8{0x22} ** 32,
    };
    
    // Set account
    try db_interface.set_account(test_address, test_account);
    try testing.expect(db_interface.account_exists(test_address));
    
    // Delete account
    try db_interface.delete_account(test_address);
    try testing.expect(!db_interface.account_exists(test_address));
    try testing.expectEqual(@as(?Account, null), try db_interface.get_account(test_address));
    try testing.expectEqual(@as(u256, 0), try db_interface.get_balance(test_address));
}
