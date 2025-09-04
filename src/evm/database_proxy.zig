//! DatabaseProxy - Generic database proxy supporting multiple operation modes
//!
//! Provides flexible database access patterns through compile-time mode selection:
//! - pass_through: Direct forwarding to underlying database (zero overhead)
//! - static: Read-only access enforcing EIP-214 STATICCALL constraints
//! - lru: Local caching with batch write support for performance optimization
//!
//! This design uses comptime mode selection to eliminate runtime branching
//! and provide zero-cost abstractions for different use cases.

const std = @import("std");
const Database = @import("database.zig").Database;
const Account = @import("database.zig").Account;

/// Proxy operation modes
pub const ProxyMode = enum {
    /// Default mode - all operations forwarded directly to underlying database
    pass_through,
    /// Read-only mode - writes return PermissionDenied (EIP-214 STATICCALL)
    static,
    /// Cache mode - reads check cache first, writes go to cache, flush applies to database
    lru,
};

/// Storage key for cache operations - matches database.zig StorageKey structure
const StorageKey = struct {
    address: [20]u8,
    slot: u256,
};

/// Generic database proxy with compile-time mode selection
pub fn DatabaseProxy(comptime mode: ProxyMode, comptime DatabaseType: type) type {
    return struct {
        const Self = @This();
        
        /// Underlying database for all operations
        inner: DatabaseType,
        
        /// LRU cache - only present when mode == .lru
        cache: if (mode == .lru) struct {
            storage_writes: std.AutoHashMap(StorageKey, u256),
            account_updates: std.AutoHashMap([20]u8, Account),
            allocator: std.mem.Allocator,
        } else void,
        
        /// Initialize proxy with underlying database
        pub fn init(inner: DatabaseType, allocator: ?std.mem.Allocator) !Self {
            return switch (mode) {
                .pass_through, .static => Self{ 
                    .inner = inner, 
                    .cache = {} 
                },
                .lru => blk: {
                    if (allocator == null) @compileError("LRU mode requires allocator");
                    break :blk Self{
                        .inner = inner,
                        .cache = .{
                            .storage_writes = std.AutoHashMap(StorageKey, u256).init(allocator.?),
                            .account_updates = std.AutoHashMap([20]u8, Account).init(allocator.?),
                            .allocator = allocator.?,
                        },
                    };
                },
            };
        }
        
        /// Cleanup proxy resources
        pub fn deinit(self: *Self) void {
            switch (mode) {
                .pass_through, .static => {},
                .lru => {
                    self.cache.storage_writes.deinit();
                    self.cache.account_updates.deinit();
                },
            }
        }
        
        // Read operations - all modes support reading
        
        pub fn get_account(self: *Self, address: [20]u8) Database.Error!?Account {
            switch (mode) {
                .pass_through, .static => return self.inner.get_account(address),
                .lru => {
                    // Check cache first
                    if (self.cache.account_updates.get(address)) |cached_account| {
                        return cached_account;
                    }
                    // Fall back to underlying database
                    return self.inner.get_account(address);
                },
            }
        }
        
        pub fn get_storage(self: *Self, address: [20]u8, key: u256) Database.Error!u256 {
            switch (mode) {
                .pass_through, .static => return self.inner.get_storage(address, key),
                .lru => {
                    // Check cache first
                    const cache_key = StorageKey{ .address = address, .slot = key };
                    if (self.cache.storage_writes.get(cache_key)) |cached_value| {
                        return cached_value;
                    }
                    // Fall back to underlying database
                    return self.inner.get_storage(address, key);
                },
            }
        }
        
        pub fn get_balance(self: *Self, address: [20]u8) Database.Error!u256 {
            switch (mode) {
                .pass_through, .static => return self.inner.get_balance(address),
                .lru => {
                    // Check cache first
                    if (self.cache.account_updates.get(address)) |cached_account| {
                        return cached_account.balance;
                    }
                    // Fall back to underlying database
                    return self.inner.get_balance(address);
                },
            }
        }
        
        pub fn account_exists(self: *Self, address: [20]u8) bool {
            switch (mode) {
                .pass_through, .static => return self.inner.account_exists(address),
                .lru => {
                    // Check if account is in cache
                    if (self.cache.account_updates.contains(address)) {
                        return true;
                    }
                    // Fall back to underlying database
                    return self.inner.account_exists(address);
                },
            }
        }
        
        // Write operations - behavior varies by mode
        
        pub fn set_account(self: *Self, address: [20]u8, account: Account) Database.Error!void {
            switch (mode) {
                .pass_through => return self.inner.set_account(address, account),
                .static => return Database.Error.PermissionDenied,
                .lru => {
                    // Store in cache only
                    try self.cache.account_updates.put(address, account);
                },
            }
        }
        
        pub fn set_storage(self: *Self, address: [20]u8, key: u256, value: u256) Database.Error!void {
            switch (mode) {
                .pass_through => return self.inner.set_storage(address, key, value),
                .static => return Database.Error.PermissionDenied,
                .lru => {
                    // Store in cache only
                    const cache_key = StorageKey{ .address = address, .slot = key };
                    try self.cache.storage_writes.put(cache_key, value);
                },
            }
        }
        
        pub fn set_balance(self: *Self, address: [20]u8, balance: u256) Database.Error!void {
            switch (mode) {
                .pass_through => return self.inner.set_balance(address, balance),
                .static => return Database.Error.PermissionDenied,
                .lru => {
                    // Get existing account or create new one
                    const existing = self.get_account(address) catch null;
                    const account = if (existing) |acc| 
                        Account{ .balance = balance, .nonce = acc.nonce, .code_hash = acc.code_hash, .storage_root = acc.storage_root }
                    else 
                        Account{ .balance = balance, .nonce = 0, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
                    try self.cache.account_updates.put(address, account);
                },
            }
        }
        
        // LRU-specific operation: flush cache to underlying database
        pub fn flush(self: *Self) !void {
            if (mode != .lru) @compileError("flush() only available in LRU mode");
            
            // Apply cached account updates to database
            var account_iter = self.cache.account_updates.iterator();
            while (account_iter.next()) |entry| {
                try self.inner.set_account(entry.key_ptr.*, entry.value_ptr.*);
            }
            
            // Apply cached storage writes to database
            var storage_iter = self.cache.storage_writes.iterator();
            while (storage_iter.next()) |entry| {
                try self.inner.set_storage(entry.key_ptr.address, entry.key_ptr.slot, entry.value_ptr.*);
            }
            
            // Clear cache after successful flush
            self.cache.account_updates.clearRetainingCapacity();
            self.cache.storage_writes.clearRetainingCapacity();
        }
        
        // Complete Database interface implementation
        
        pub fn get_code(self: *Self, code_hash: [32]u8) Database.Error![]const u8 {
            return self.inner.get_code(code_hash);
        }
        
        pub fn get_code_by_address(self: *Self, address: [20]u8) Database.Error![]const u8 {
            return self.inner.get_code_by_address(address);
        }
        
        pub fn get_nonce(self: *Self, address: [20]u8) Database.Error!u64 {
            switch (mode) {
                .pass_through, .static => return self.inner.get_nonce(address),
                .lru => {
                    if (self.cache.account_updates.get(address)) |cached_account| {
                        return cached_account.nonce;
                    }
                    return self.inner.get_nonce(address);
                },
            }
        }
        
        pub fn is_empty(self: *Self, address: [20]u8) Database.Error!bool {
            switch (mode) {
                .pass_through, .static => return self.inner.is_empty(address),
                .lru => {
                    if (self.cache.account_updates.get(address)) |cached_account| {
                        return cached_account.balance == 0 and cached_account.nonce == 0;
                    }
                    return self.inner.is_empty(address);
                },
            }
        }
        
        pub fn get_code_hash(self: *Self, address: [20]u8) Database.Error![32]u8 {
            switch (mode) {
                .pass_through, .static => return self.inner.get_code_hash(address),
                .lru => {
                    if (self.cache.account_updates.get(address)) |cached_account| {
                        return cached_account.code_hash;
                    }
                    return self.inner.get_code_hash(address);
                },
            }
        }
        
        pub fn set_code(self: *Self, code: []const u8) Database.Error![32]u8 {
            switch (mode) {
                .pass_through => return self.inner.set_code(code),
                .static => return Database.Error.PermissionDenied,
                .lru => return self.inner.set_code(code), // Code storage not cached for simplicity
            }
        }
        
        pub fn set_nonce(self: *Self, address: [20]u8, nonce: u64) Database.Error!void {
            switch (mode) {
                .pass_through => return self.inner.set_nonce(address, nonce),
                .static => return Database.Error.PermissionDenied,
                .lru => {
                    // Get existing account or create new one
                    const existing = self.get_account(address) catch null;
                    const account = if (existing) |acc| 
                        Account{ .balance = acc.balance, .nonce = nonce, .code_hash = acc.code_hash, .storage_root = acc.storage_root }
                    else 
                        Account{ .balance = 0, .nonce = nonce, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
                    try self.cache.account_updates.put(address, account);
                },
            }
        }
        
        pub fn delete_account(self: *Self, address: [20]u8) Database.Error!void {
            switch (mode) {
                .pass_through => return self.inner.delete_account(address),
                .static => return Database.Error.PermissionDenied,
                .lru => {
                    // Remove from cache and delete from database
                    _ = self.cache.account_updates.remove(address);
                    return self.inner.delete_account(address);
                },
            }
        }
        
        // Transient storage operations
        pub fn get_transient_storage(self: *Self, address: [20]u8, key: u256) Database.Error!u256 {
            return self.inner.get_transient_storage(address, key);
        }
        
        pub fn set_transient_storage(self: *Self, address: [20]u8, key: u256, value: u256) Database.Error!void {
            switch (mode) {
                .pass_through => return self.inner.set_transient_storage(address, key, value),
                .static => return Database.Error.PermissionDenied,
                .lru => return self.inner.set_transient_storage(address, key, value), // Not cached
            }
        }
        
        // State root operations
        pub fn get_state_root(self: *Self) Database.Error![32]u8 {
            return self.inner.get_state_root();
        }
        
        pub fn commit_changes(self: *Self) Database.Error![32]u8 {
            switch (mode) {
                .pass_through => return self.inner.commit_changes(),
                .static => return Database.Error.PermissionDenied,
                .lru => {
                    try self.flush();
                    return self.inner.commit_changes();
                },
            }
        }
        
        // Snapshot operations
        pub fn create_snapshot(self: *Self) Database.Error!u64 {
            return self.inner.create_snapshot();
        }
        
        pub fn revert_to_snapshot(self: *Self, snapshot_id: u64) Database.Error!void {
            switch (mode) {
                .pass_through, .static => return self.inner.revert_to_snapshot(snapshot_id),
                .lru => {
                    // Clear cache and revert database
                    self.cache.account_updates.clearRetainingCapacity();
                    self.cache.storage_writes.clearRetainingCapacity();
                    return self.inner.revert_to_snapshot(snapshot_id);
                },
            }
        }
        
        pub fn commit_snapshot(self: *Self, snapshot_id: u64) Database.Error!void {
            switch (mode) {
                .pass_through => return self.inner.commit_snapshot(snapshot_id),
                .static => return Database.Error.PermissionDenied,
                .lru => return self.inner.commit_snapshot(snapshot_id),
            }
        }
        
        // Batch operations
        pub fn begin_batch(self: *Self) Database.Error!void {
            return self.inner.begin_batch();
        }
        
        pub fn commit_batch(self: *Self) Database.Error!void {
            switch (mode) {
                .pass_through => return self.inner.commit_batch(),
                .static => return Database.Error.PermissionDenied,
                .lru => {
                    try self.flush();
                    return self.inner.commit_batch();
                },
            }
        }
        
        pub fn rollback_batch(self: *Self) Database.Error!void {
            switch (mode) {
                .pass_through, .static => return self.inner.rollback_batch(),
                .lru => {
                    // Clear cache and rollback database
                    self.cache.account_updates.clearRetainingCapacity();
                    self.cache.storage_writes.clearRetainingCapacity();
                    return self.inner.rollback_batch();
                },
            }
        }
        
        // Transaction operations (for completeness)
        pub fn begin_transaction(self: *Self) Database.Error!u32 {
            return self.inner.begin_transaction();
        }
        
        pub fn commit_transaction(self: *Self, id: u32) Database.Error!void {
            switch (mode) {
                .pass_through => return self.inner.commit_transaction(id),
                .static => return Database.Error.PermissionDenied,
                .lru => return self.inner.commit_transaction(id),
            }
        }
        
        pub fn rollback_transaction(self: *Self, id: u32) Database.Error!void {
            return self.inner.rollback_transaction(id);
        }
    };
}

// Tests for TDD implementation

test "DatabaseProxy compiles with all three modes" {
    const PassThroughProxy = DatabaseProxy(.pass_through, Database);
    const StaticProxy = DatabaseProxy(.static, Database);
    const LruProxy = DatabaseProxy(.lru, Database);
    
    // Should compile without errors
    _ = PassThroughProxy;
    _ = StaticProxy;
    _ = LruProxy;
}

test "DatabaseProxy pass_through mode forwards all operations" {
    const allocator = std.testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();
    
    var proxy = try DatabaseProxy(.pass_through, Database).init(db, null);
    defer proxy.deinit();
    
    const test_addr = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const test_account = Account{ .balance = 100, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    
    // Write operations should succeed
    try proxy.set_account(test_addr, test_account);
    try proxy.set_storage(test_addr, 42, 100);
    
    // Read operations should return correct values
    try std.testing.expectEqual(@as(u256, 100), try proxy.get_balance(test_addr));
    try std.testing.expectEqual(@as(u256, 100), try proxy.get_storage(test_addr, 42));
}

test "DatabaseProxy static mode blocks all write operations" {
    const allocator = std.testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();
    
    var proxy = try DatabaseProxy(.static, Database).init(db, null);
    defer proxy.deinit();
    
    const test_addr = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const test_account = Account{ .balance = 100, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    
    // All write operations should return PermissionDenied
    try std.testing.expectError(Database.Error.PermissionDenied, proxy.set_account(test_addr, test_account));
    try std.testing.expectError(Database.Error.PermissionDenied, proxy.set_storage(test_addr, 42, 100));
    try std.testing.expectError(Database.Error.PermissionDenied, proxy.set_balance(test_addr, 500));
    try std.testing.expectError(Database.Error.PermissionDenied, proxy.delete_account(test_addr));
}

test "DatabaseProxy LRU mode caches writes without persistence" {
    const allocator = std.testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();
    
    var proxy = try DatabaseProxy(.lru, Database).init(db, allocator);
    defer proxy.deinit();
    
    const test_addr = [_]u8{0x01} ++ [_]u8{0} ** 19;
    
    // Write to cache
    try proxy.set_storage(test_addr, 99, 200);
    try proxy.set_balance(test_addr, 300);
    
    // Should read from cache
    try std.testing.expectEqual(@as(u256, 200), try proxy.get_storage(test_addr, 99));
    try std.testing.expectEqual(@as(u256, 300), try proxy.get_balance(test_addr));
    
    // Should NOT be in underlying database yet
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(test_addr, 99));
    try std.testing.expectEqual(@as(u256, 0), try db.get_balance(test_addr));
}

test "DatabaseProxy LRU mode flush applies cache to database" {
    const allocator = std.testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();
    
    var proxy = try DatabaseProxy(.lru, Database).init(db, allocator);
    defer proxy.deinit();
    
    const test_addr = [_]u8{0x01} ++ [_]u8{0} ** 19;
    
    // Write to cache
    try proxy.set_storage(test_addr, 55, 888);
    try proxy.set_balance(test_addr, 777);
    
    // Flush cache
    try proxy.flush();
    
    // Database should now have cached values
    try std.testing.expectEqual(@as(u256, 888), try db.get_storage(test_addr, 55));
    try std.testing.expectEqual(@as(u256, 777), try db.get_balance(test_addr));
    
    // Cache should be empty after flush
    try std.testing.expectEqual(@as(usize, 0), proxy.cache.storage_writes.count());
    try std.testing.expectEqual(@as(usize, 0), proxy.cache.account_updates.count());
}

test "DatabaseProxy static mode allows read operations" {
    const allocator = std.testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();
    
    // Pre-populate database
    const test_addr = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const test_account = Account{ .balance = 500, .nonce = 2, .code_hash = [_]u8{0x11} ** 32, .storage_root = [_]u8{0} ** 32 };
    try db.set_account(test_addr, test_account);
    try db.set_storage(test_addr, 123, 456);
    
    var proxy = try DatabaseProxy(.static, Database).init(db, null);
    defer proxy.deinit();
    
    // Read operations should work
    try std.testing.expectEqual(@as(u256, 500), try proxy.get_balance(test_addr));
    try std.testing.expectEqual(@as(u256, 456), try proxy.get_storage(test_addr, 123));
    try std.testing.expect(proxy.account_exists(test_addr));
    try std.testing.expectEqual(@as(u64, 2), try proxy.get_nonce(test_addr));
    
    // Snapshot reads should work
    _ = try proxy.create_snapshot();
    try proxy.revert_to_snapshot(0);
}

test "DatabaseProxy LRU mode prioritizes cache over database reads" {
    const allocator = std.testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();
    
    // Pre-populate database
    const test_addr = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const original_account = Account{ .balance = 100, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    try db.set_account(test_addr, original_account);
    try db.set_storage(test_addr, 42, 50);
    
    var proxy = try DatabaseProxy(.lru, Database).init(db, allocator);
    defer proxy.deinit();
    
    // Modify in cache
    try proxy.set_balance(test_addr, 999);
    try proxy.set_nonce(test_addr, 10);
    try proxy.set_storage(test_addr, 42, 777);
    
    // Should read cached values, not database values
    try std.testing.expectEqual(@as(u256, 999), try proxy.get_balance(test_addr));
    try std.testing.expectEqual(@as(u64, 10), try proxy.get_nonce(test_addr));
    try std.testing.expectEqual(@as(u256, 777), try proxy.get_storage(test_addr, 42));
    
    // Database should still have original values
    try std.testing.expectEqual(@as(u256, 100), try db.get_balance(test_addr));
    try std.testing.expectEqual(@as(u64, 1), try db.get_nonce(test_addr));
    try std.testing.expectEqual(@as(u256, 50), try db.get_storage(test_addr, 42));
}

test "DatabaseProxy LRU mode initializes cache correctly" {
    const allocator = std.testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();
    
    var proxy = try DatabaseProxy(.lru, Database).init(db, allocator);
    defer proxy.deinit();
    
    // Cache should be initialized and empty
    try std.testing.expectEqual(@as(usize, 0), proxy.cache.storage_writes.count());
    try std.testing.expectEqual(@as(usize, 0), proxy.cache.account_updates.count());
}

test "DatabaseProxy LRU mode handles allocation failures gracefully" {
    // Test with failing allocator to ensure proper error propagation
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, 0);
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    
    // Should fail gracefully during init
    try std.testing.expectError(error.OutOfMemory, 
        DatabaseProxy(.lru, Database).init(db, failing_allocator.allocator()));
}

test "DatabaseProxy commit and rollback operations" {
    const allocator = std.testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();
    
    // Test static mode blocks commits
    var static_proxy = try DatabaseProxy(.static, Database).init(db, null);
    defer static_proxy.deinit();
    
    try std.testing.expectError(Database.Error.PermissionDenied, static_proxy.commit_changes());
    try std.testing.expectError(Database.Error.PermissionDenied, static_proxy.commit_batch());
    
    // Test LRU mode flushes on commit
    var lru_proxy = try DatabaseProxy(.lru, Database).init(db, allocator);
    defer lru_proxy.deinit();
    
    const test_addr = [_]u8{0x01} ++ [_]u8{0} ** 19;
    try lru_proxy.set_balance(test_addr, 500);
    
    // Should be cached, not in database yet
    try std.testing.expectEqual(@as(u256, 500), try lru_proxy.get_balance(test_addr));
    try std.testing.expectEqual(@as(u256, 0), try db.get_balance(test_addr));
    
    // Commit should flush cache
    _ = try lru_proxy.commit_changes();
    try std.testing.expectEqual(@as(u256, 500), try db.get_balance(test_addr));
    try std.testing.expectEqual(@as(usize, 0), lru_proxy.cache.account_updates.count());
}

/// Type alias for StaticDatabase compatibility
pub const StaticDatabaseCompat = DatabaseProxy(.static, Database);

/// Create a static database proxy for backward compatibility
pub fn createStaticDatabase(inner: Database) StaticDatabaseCompat {
    return StaticDatabaseCompat.init(inner, null) catch unreachable; // static mode doesn't use allocator
}

test "DatabaseProxy interfaces are valid database implementations" {
    // Compile-time validation using database.zig validation function
    const validate_database_implementation = Database.validate_database_implementation;
    
    // All three modes should pass database validation
    validate_database_implementation(DatabaseProxy(.pass_through, Database));
    validate_database_implementation(DatabaseProxy(.static, Database)); 
    validate_database_implementation(DatabaseProxy(.lru, Database));
}