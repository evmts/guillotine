//! Union-based storage system with zero overhead for memory case
//!
//! This module provides a unified storage interface using union types
//! instead of virtual functions, ensuring zero overhead for the hot path
//! (in-memory access) while supporting different storage backends.

const std = @import("std");
const primitives = @import("voltaire");
const Account = @import("database_interface_account.zig").Account;
const Journal = @import("journal.zig").DefaultJournal;
const cache_storage = @import("cache_storage.zig");
const HotStorage = cache_storage.HotStorage;
const StorageKey = cache_storage.StorageKey;

/// Memory-only storage (current Database implementation renamed)
pub const MemoryStorage = @import("database.zig").Database;

/// Forked storage with RPC backend
pub const ForkedStorage = @import("forked_storage.zig").ForkedStorage;

/// Test storage with deterministic data
pub const TestStorage = struct {
    accounts: std.HashMap([20]u8, Account, AddressHashContext, 80),
    storage: std.HashMap(StorageKey, u256, StorageHashContext, 80), 
    code_storage: std.HashMap([32]u8, []const u8, CodeHashContext, 80),
    snapshots: std.ArrayList(Snapshot),
    next_snapshot_id: u64,
    allocator: std.mem.Allocator,
    
    const AddressHashContext = cache_storage.AddressHashContext;
    const StorageHashContext = cache_storage.StorageHashContext;
    const CodeHashContext = cache_storage.CodeHashContext;
    
    const Snapshot = struct {
        id: u64,
        accounts: std.HashMap([20]u8, Account, AddressHashContext, 80),
        storage: std.HashMap(StorageKey, u256, StorageHashContext, 80),
    };
    
    pub fn init(allocator: std.mem.Allocator) TestStorage {
        return .{
            .accounts = std.HashMap([20]u8, Account, AddressHashContext, 80).init(allocator),
            .storage = std.HashMap(StorageKey, u256, StorageHashContext, 80).init(allocator),
            .code_storage = std.HashMap([32]u8, []const u8, CodeHashContext, 80).init(allocator),
            .snapshots = .empty,
            .next_snapshot_id = 1,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *TestStorage) void {
        self.accounts.deinit();
        self.storage.deinit();
        
        var code_iter = self.code_storage.iterator();
        while (code_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.code_storage.deinit();
        
        for (self.snapshots.items) |*snapshot| {
            snapshot.accounts.deinit();
            snapshot.storage.deinit();
        }
        self.snapshots.deinit(self.allocator);
    }
    
    // Implement same API as MemoryStorage for accidental polymorphism
    pub fn get_account(self: *TestStorage, address: [20]u8) !?Account {
        return self.accounts.get(address);
    }
    
    pub fn set_account(self: *TestStorage, address: [20]u8, account: Account) !void {
        try self.accounts.put(address, account);
    }
    
    pub fn delete_account(self: *TestStorage, address: [20]u8) !void {
        _ = self.accounts.remove(address);
    }
    
    pub fn account_exists(self: *TestStorage, address: [20]u8) bool {
        return self.accounts.contains(address);
    }
    
    pub fn get_balance(self: *TestStorage, address: [20]u8) !u256 {
        if (self.accounts.get(address)) |account| {
            return account.balance;
        }
        return 0;
    }
    
    pub fn get_storage(self: *TestStorage, address: [20]u8, key: u256) !u256 {
        const storage_key = StorageKey{ .address = address, .slot = key };
        return self.storage.get(storage_key) orelse 0;
    }
    
    pub fn set_storage(self: *TestStorage, address: [20]u8, key: u256, value: u256) !void {
        const storage_key = StorageKey{ .address = address, .slot = key };
        try self.storage.put(storage_key, value);
    }
    
    pub fn get_transient_storage(self: *TestStorage, address: [20]u8, key: u256) !u256 {
        _ = self;
        _ = address;
        _ = key;
        return 0;  // Test storage doesn't implement transient storage
    }
    
    pub fn set_transient_storage(self: *TestStorage, address: [20]u8, key: u256, value: u256) !void {
        _ = self;
        _ = address;
        _ = key;
        _ = value;
        // Test storage doesn't implement transient storage
    }
    
    pub fn get_code(self: *TestStorage, code_hash: [32]u8) ![]const u8 {
        return self.code_storage.get(code_hash) orelse return error.CodeNotFound;
    }
    
    pub fn get_code_by_address(self: *TestStorage, address: [20]u8) ![]const u8 {
        if (self.accounts.get(address)) |account| {
            if (std.mem.eql(u8, &account.code_hash, &([_]u8{0} ** 32))) {
                return &.{};
            }
            return self.get_code(account.code_hash);
        }
        return error.AccountNotFound;
    }
    
    pub fn set_code(self: *TestStorage, code: []const u8) ![32]u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(code, &hash, .{});
        
        const code_copy = try self.allocator.dupe(u8, code);
        try self.code_storage.put(hash, code_copy);
        return hash;
    }
    
    pub fn get_state_root(self: *TestStorage) ![32]u8 {
        _ = self;
        return [_]u8{0xDE, 0xAD} ** 16;  // Test deterministic root
    }
    
    pub fn commit_changes(self: *TestStorage) ![32]u8 {
        return self.get_state_root();
    }
    
    pub fn create_snapshot(self: *TestStorage) !u64 {
        const snapshot_id = self.next_snapshot_id;
        self.next_snapshot_id += 1;
        
        var snapshot_accounts = std.HashMap([20]u8, Account, AddressHashContext, 80).init(self.allocator);
        var accounts_iter = self.accounts.iterator();
        while (accounts_iter.next()) |entry| {
            try snapshot_accounts.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        
        var snapshot_storage = std.HashMap(StorageKey, u256, StorageHashContext, 80).init(self.allocator);
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
    
    pub fn revert_to_snapshot(self: *TestStorage, snapshot_id: u64) !void {
        var snapshot_index: ?usize = null;
        for (self.snapshots.items, 0..) |snapshot, i| {
            if (snapshot.id == snapshot_id) {
                snapshot_index = i;
                break;
            }
        }
        
        const index = snapshot_index orelse return error.SnapshotNotFound;
        const snapshot = &self.snapshots.items[index];
        
        self.accounts.deinit();
        self.storage.deinit();
        
        self.accounts = std.HashMap([20]u8, Account, AddressHashContext, 80).init(self.allocator);
        self.storage = std.HashMap(StorageKey, u256, StorageHashContext, 80).init(self.allocator);
        
        var accounts_iter = snapshot.accounts.iterator();
        while (accounts_iter.next()) |entry| {
            try self.accounts.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        
        var storage_iter = snapshot.storage.iterator();
        while (storage_iter.next()) |entry| {
            try self.storage.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        
        for (self.snapshots.items[index..]) |*snap| {
            snap.accounts.deinit();
            snap.storage.deinit();
        }
        self.snapshots.shrinkRetainingCapacity(index);
    }
    
    pub fn commit_snapshot(self: *TestStorage, snapshot_id: u64) !void {
        var snapshot_index: ?usize = null;
        for (self.snapshots.items, 0..) |snapshot, i| {
            if (snapshot.id == snapshot_id) {
                snapshot_index = i;
                break;
            }
        }
        
        const index = snapshot_index orelse return error.SnapshotNotFound;
        
        for (self.snapshots.items[index..]) |*snapshot| {
            snapshot.accounts.deinit();
            snapshot.storage.deinit();
        }
        self.snapshots.shrinkRetainingCapacity(index);
    }
    
    pub fn begin_batch(self: *TestStorage) !void {
        _ = self;
    }
    
    pub fn commit_batch(self: *TestStorage) !void {
        _ = self;
    }
    
    pub fn rollback_batch(self: *TestStorage) !void {
        _ = self;
    }
    
    // Test-specific methods
    pub fn seedWithTestData(self: *TestStorage) !void {
        // Add some predefined test accounts
        const test_accounts = [_]struct { addr: [20]u8, balance: u256, nonce: u64 }{
            .{ .addr = [_]u8{0x01} ** 20, .balance = 1_000_000, .nonce = 0 },
            .{ .addr = [_]u8{0x02} ** 20, .balance = 2_000_000, .nonce = 5 },
            .{ .addr = [_]u8{0x03} ** 20, .balance = 3_000_000, .nonce = 10 },
        };
        
        for (test_accounts) |test_account| {
            try self.set_account(test_account.addr, Account{
                .balance = test_account.balance,
                .nonce = test_account.nonce,
                .code_hash = [_]u8{0} ** 32,
                .storage_root = [_]u8{0} ** 32,
            });
        }
        
        // Add some test storage values
        try self.set_storage(test_accounts[0].addr, 0, 100);
        try self.set_storage(test_accounts[0].addr, 1, 200);
        try self.set_storage(test_accounts[1].addr, 0, 300);
    }
};

/// Placeholder for disk storage (future implementation)
pub const DiskStorage = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) DiskStorage {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *DiskStorage) void {
        _ = self;
    }
    
    // Implement all required methods (stubbed for now)
    pub fn get_account(self: *DiskStorage, address: [20]u8) !?Account {
        _ = self;
        _ = address;
        return null;
    }
    
    pub fn set_account(self: *DiskStorage, address: [20]u8, account: Account) !void {
        _ = self;
        _ = address;
        _ = account;
    }
    
    // ... other methods follow same pattern ...
};

/// Union-based storage - zero overhead for memory case
pub const Storage = union(enum) {
    memory: MemoryStorage,
    test: TestStorage,
    forked: ForkedStorage,
    // disk: DiskStorage,      // Future
    
    const Self = @This();
    
    // All wrapper functions are inline for zero overhead
    
    pub inline fn get_account(self: *Self, address: [20]u8) !?Account {
        return switch (self.*) {
            .memory => |*s| s.get_account(address),
            .test => |*s| s.get_account(address),
            .forked => |*s| s.get_account(address),
        };
    }
    
    pub inline fn set_account(self: *Self, address: [20]u8, account: Account) !void {
        return switch (self.*) {
            .memory => |*s| s.set_account(address, account),
            .test => |*s| s.set_account(address, account),
            .forked => |*s| s.set_account(address, account),
        };
    }
    
    pub inline fn delete_account(self: *Self, address: [20]u8) !void {
        return switch (self.*) {
            .memory => |*s| s.delete_account(address),
            .test => |*s| s.delete_account(address),
            .forked => |*s| s.delete_account(address),
        };
    }
    
    pub inline fn account_exists(self: *Self, address: [20]u8) bool {
        return switch (self.*) {
            .memory => |*s| s.account_exists(address),
            .test => |*s| s.account_exists(address),
            .forked => |*s| s.account_exists(address),
        };
    }
    
    pub inline fn get_balance(self: *Self, address: [20]u8) !u256 {
        return switch (self.*) {
            .memory => |*s| s.get_balance(address),
            .test => |*s| s.get_balance(address),
            .forked => |*s| s.get_balance(address),
        };
    }
    
    pub inline fn get_storage(self: *Self, address: [20]u8, key: u256) !u256 {
        return switch (self.*) {
            .memory => |*s| s.get_storage(address, key),
            .test => |*s| s.get_storage(address, key),
            .forked => |*s| s.get_storage(address, key),
        };
    }
    
    pub inline fn set_storage(self: *Self, address: [20]u8, key: u256, value: u256) !void {
        return switch (self.*) {
            .memory => |*s| s.set_storage(address, key, value),
            .test => |*s| s.set_storage(address, key, value),
            .forked => |*s| s.set_storage(address, key, value),
        };
    }
    
    pub inline fn get_transient_storage(self: *Self, address: [20]u8, key: u256) !u256 {
        return switch (self.*) {
            .memory => |*s| s.get_transient_storage(address, key),
            .test => |*s| s.get_transient_storage(address, key),
            .forked => |*s| s.get_transient_storage(address, key),
        };
    }
    
    pub inline fn set_transient_storage(self: *Self, address: [20]u8, key: u256, value: u256) !void {
        return switch (self.*) {
            .memory => |*s| s.set_transient_storage(address, key, value),
            .test => |*s| s.set_transient_storage(address, key, value),
            .forked => |*s| s.set_transient_storage(address, key, value),
        };
    }
    
    pub inline fn get_code(self: *Self, code_hash: [32]u8) ![]const u8 {
        return switch (self.*) {
            .memory => |*s| s.get_code(code_hash),
            .test => |*s| s.get_code(code_hash),
            .forked => |*s| s.get_code(code_hash),
        };
    }
    
    pub inline fn get_code_by_address(self: *Self, address: [20]u8) ![]const u8 {
        return switch (self.*) {
            .memory => |*s| s.get_code_by_address(address),
            .test => |*s| s.get_code_by_address(address),
            .forked => |*s| s.get_code_by_address(address),
        };
    }
    
    pub inline fn set_code(self: *Self, code: []const u8) ![32]u8 {
        return switch (self.*) {
            .memory => |*s| s.set_code(code),
            .test => |*s| s.set_code(code),
            .forked => |*s| s.set_code(code),
        };
    }
    
    pub inline fn get_state_root(self: *Self) ![32]u8 {
        return switch (self.*) {
            .memory => |*s| s.get_state_root(),
            .test => |*s| s.get_state_root(),
            .forked => |*s| s.get_state_root(),
        };
    }
    
    pub inline fn commit_changes(self: *Self) ![32]u8 {
        return switch (self.*) {
            .memory => |*s| s.commit_changes(),
            .test => |*s| s.commit_changes(),
            .forked => |*s| s.commit_changes(),
        };
    }
    
    pub inline fn create_snapshot(self: *Self) !u64 {
        return switch (self.*) {
            .memory => |*s| s.create_snapshot(),
            .test => |*s| s.create_snapshot(),
            .forked => |*s| s.create_snapshot(),
        };
    }
    
    pub inline fn revert_to_snapshot(self: *Self, snapshot_id: u64) !void {
        return switch (self.*) {
            .memory => |*s| s.revert_to_snapshot(snapshot_id),
            .test => |*s| s.revert_to_snapshot(snapshot_id),
            .forked => |*s| s.revert_to_snapshot(snapshot_id),
        };
    }
    
    pub inline fn commit_snapshot(self: *Self, snapshot_id: u64) !void {
        return switch (self.*) {
            .memory => |*s| s.commit_snapshot(snapshot_id),
            .test => |*s| s.commit_snapshot(snapshot_id),
            .forked => |*s| s.commit_snapshot(snapshot_id),
        };
    }
    
    pub inline fn begin_batch(self: *Self) !void {
        return switch (self.*) {
            .memory => |*s| s.begin_batch(),
            .test => |*s| s.begin_batch(),
            .forked => |*s| s.begin_batch(),
        };
    }
    
    pub inline fn commit_batch(self: *Self) !void {
        return switch (self.*) {
            .memory => |*s| s.commit_batch(),
            .test => |*s| s.commit_batch(),
            .forked => |*s| s.commit_batch(),
        };
    }
    
    pub inline fn rollback_batch(self: *Self) !void {
        return switch (self.*) {
            .memory => |*s| s.rollback_batch(),
            .test => |*s| s.rollback_batch(),
            .forked => |*s| s.rollback_batch(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        switch (self.*) {
            .memory => |*s| s.deinit(),
            .test => |*s| s.deinit(),
            .forked => |*s| s.deinit(),
        }
    }
};

// Convenience functions for creating storage instances
pub fn createMemoryStorage(allocator: std.mem.Allocator) Storage {
    return .{ .memory = MemoryStorage.init(allocator) };
}

pub fn createTestStorage(allocator: std.mem.Allocator) !Storage {
    var test = TestStorage.init(allocator);
    try test.seedWithTestData();
    return .{ .test = test };
}

pub fn createForkedStorage(allocator: std.mem.Allocator, rpc_endpoint: []const u8, fork_block: ?u64) !Storage {
    return .{ .forked = try ForkedStorage.init(allocator, rpc_endpoint, fork_block) };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "Storage union - memory variant" {
    const allocator = testing.allocator;
    var storage = createMemoryStorage(allocator);
    defer storage.deinit();
    
    const addr = [_]u8{0x12} ** 20;
    const account = Account{
        .balance = 1000,
        .nonce = 5,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    
    // Test account operations through union
    try testing.expect(!storage.account_exists(addr));
    try storage.set_account(addr, account);
    try testing.expect(storage.account_exists(addr));
    
    const retrieved = (try storage.get_account(addr)).?;
    try testing.expectEqual(account.balance, retrieved.balance);
    try testing.expectEqual(@as(u256, 1000), try storage.get_balance(addr));
    
    // Test storage operations
    try storage.set_storage(addr, 42, 999);
    try testing.expectEqual(@as(u256, 999), try storage.get_storage(addr, 42));
    
    // Test snapshots
    const snapshot_id = try storage.create_snapshot();
    try storage.set_account(addr, Account.zero());
    try testing.expectEqual(@as(u256, 0), try storage.get_balance(addr));
    
    try storage.revert_to_snapshot(snapshot_id);
    try testing.expectEqual(@as(u256, 1000), try storage.get_balance(addr));
}

test "Storage union - test variant" {
    const allocator = testing.allocator;
    var storage = try createTestStorage(allocator);
    defer storage.deinit();
    
    // Test storage should have seeded data
    const test_addr = [_]u8{0x01} ** 20;
    try testing.expect(storage.account_exists(test_addr));
    try testing.expectEqual(@as(u256, 1_000_000), try storage.get_balance(test_addr));
    
    // Test storage values
    try testing.expectEqual(@as(u256, 100), try storage.get_storage(test_addr, 0));
    try testing.expectEqual(@as(u256, 200), try storage.get_storage(test_addr, 1));
    
    // Test deterministic state root
    const root = try storage.get_state_root();
    try testing.expectEqual([_]u8{0xDE, 0xAD} ** 16, root);
}

test "TestStorage - operations" {
    const allocator = testing.allocator;
    var test_storage = TestStorage.init(allocator);
    defer test_storage.deinit();
    
    try test_storage.seedWithTestData();
    
    // Verify seeded accounts
    const addr1 = [_]u8{0x01} ** 20;
    const addr2 = [_]u8{0x02} ** 20;
    const addr3 = [_]u8{0x03} ** 20;
    
    try testing.expectEqual(@as(u256, 1_000_000), try test_storage.get_balance(addr1));
    try testing.expectEqual(@as(u256, 2_000_000), try test_storage.get_balance(addr2));
    try testing.expectEqual(@as(u256, 3_000_000), try test_storage.get_balance(addr3));
    
    // Verify seeded storage
    try testing.expectEqual(@as(u256, 100), try test_storage.get_storage(addr1, 0));
    try testing.expectEqual(@as(u256, 300), try test_storage.get_storage(addr2, 0));
    
    // Test code operations
    const test_code = [_]u8{ 0x60, 0x80, 0x60, 0x40, 0x52 };
    const code_hash = try test_storage.set_code(&test_code);
    
    const retrieved_code = try test_storage.get_code(code_hash);
    try testing.expectEqualSlices(u8, &test_code, retrieved_code);
}

test "Storage polymorphism - same API" {
    const allocator = testing.allocator;
    
    // Both variants support the same operations
    var storages = [_]Storage{
        createMemoryStorage(allocator),
        try createTestStorage(allocator),
    };
    
    for (&storages) |*storage| {
        defer storage.deinit();
        
        const addr = [_]u8{0xFF} ** 20;
        const account = Account{
            .balance = 5000,
            .nonce = 10,
            .code_hash = [_]u8{0} ** 32,
            .storage_root = [_]u8{0} ** 32,
        };
        
        // All variants support the same operations
        try storage.set_account(addr, account);
        const retrieved = (try storage.get_account(addr)).?;
        try testing.expectEqual(account.balance, retrieved.balance);
        
        try storage.set_storage(addr, 1, 42);
        try testing.expectEqual(@as(u256, 42), try storage.get_storage(addr, 1));
        
        const snapshot_id = try storage.create_snapshot();
        try storage.delete_account(addr);
        try testing.expect(!storage.account_exists(addr));
        
        try storage.revert_to_snapshot(snapshot_id);
        try testing.expect(storage.account_exists(addr));
    }
}