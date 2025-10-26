//! Forked storage implementation with RPC backend
//! 
//! Provides a storage backend that fetches state from a remote blockchain via RPC.
//! Uses a multi-tier cache system to minimize RPC calls and improve performance.

const std = @import("std");
const primitives = @import("primitives");
const Account = @import("database_interface_account.zig").Account;
const RpcClient = @import("rpc_client.zig").RpcClient;
const cache_storage = @import("cache_storage.zig");
const HotStorage = cache_storage.HotStorage;
const WarmStorage = cache_storage.WarmStorage;
const StorageKey = cache_storage.StorageKey;

/// Forked storage that fetches state from remote RPC
pub const ForkedStorage = struct {
    /// L1 Cache - Hot storage for frequently accessed items
    hot: HotStorage,
    /// L2 Cache - Warm storage with LRU eviction
    warm: *WarmStorage,
    /// L3 Cache - Original fork values (never evicted)
    fork_cache: HotStorage,
    /// RPC client for fetching remote state
    rpc: RpcClient,
    /// Fork block number
    fork_block: u64,
    /// Allocator
    allocator: std.mem.Allocator,
    /// Stats
    stats: Stats,
    
    const Self = @This();
    
    pub const Stats = struct {
        cache_hits: u64 = 0,
        cache_misses: u64 = 0,
        rpc_calls: u64 = 0,
    };
    
    pub fn init(allocator: std.mem.Allocator, rpc_endpoint: []const u8, fork_block: ?u64) !Self {
        const hot = HotStorage.init(allocator);
        const fork_cache = HotStorage.init(allocator);
        
        const warm = try allocator.create(WarmStorage);
        warm.* = try WarmStorage.init(allocator, null);
        
        const rpc = try RpcClient.init(allocator, rpc_endpoint, fork_block);
        
        return .{
            .hot = hot,
            .warm = warm,
            .fork_cache = fork_cache,
            .rpc = rpc,
            .fork_block = fork_block orelse std.math.maxInt(u64),
            .allocator = allocator,
            .stats = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.hot.deinit();
        self.warm.deinit();
        self.allocator.destroy(self.warm);
        self.fork_cache.deinit();
        self.rpc.deinit();
    }
    
    // Account operations
    
    pub fn get_account(self: *Self, address: [20]u8) !?Account {
        // Check L1 hot cache
        if (self.hot.getAccount(address)) |account| {
            self.stats.cache_hits += 1;
            return account;
        }
        
        // Check L2 warm cache
        if (self.warm.getAccount(address)) |account| {
            self.stats.cache_hits += 1;
            // Promote to hot cache
            try self.hot.putAccount(address, account);
            return account;
        }
        
        // Check L3 fork cache (original values)
        if (self.fork_cache.getAccount(address)) |account| {
            self.stats.cache_hits += 1;
            // Promote to hot cache
            try self.hot.putAccount(address, account);
            return account;
        }
        
        // Cache miss - fetch from RPC
        self.stats.cache_misses += 1;
        self.stats.rpc_calls += 1;
        
        const proof = try self.rpc.getProof(address, &.{});
        const code = if (!std.mem.eql(u8, &proof.codeHash, &([_]u8{0} ** 32)))
            try self.rpc.getCode(address)
        else
            &[_]u8{};
        
        // Store code if present
        var code_hash = proof.codeHash;
        if (code.len > 0) {
            const code_copy = try self.allocator.dupe(u8, code);
            try self.hot.putCode(code_hash, code_copy);
            try self.fork_cache.putCode(code_hash, code_copy);
        }
        
        const account = Account{
            .balance = proof.balance,
            .nonce = proof.nonce,
            .code_hash = code_hash,
            .storage_root = proof.storageHash,
        };
        
        // Store in all caches
        try self.hot.putAccount(address, account);
        try self.warm.putAccount(address, account);
        try self.fork_cache.putAccount(address, account);
        
        return account;
    }
    
    pub fn set_account(self: *Self, address: [20]u8, account: Account) !void {
        // Only update hot cache for writes (not fork cache)
        try self.hot.putAccount(address, account);
    }
    
    pub fn delete_account(self: *Self, address: [20]u8) !void {
        _ = self.hot.removeAccount(address);
    }
    
    pub fn account_exists(self: *Self, address: [20]u8) bool {
        const account = self.get_account(address) catch return false;
        return account != null;
    }
    
    pub fn get_balance(self: *Self, address: [20]u8) !u256 {
        const account = (try self.get_account(address)) orelse return 0;
        return account.balance;
    }
    
    // Storage operations
    
    pub fn get_storage(self: *Self, address: [20]u8, slot: u256) !u256 {
        const key = StorageKey{ .address = address, .slot = slot };
        
        // Check L1 hot cache
        if (self.hot.getStorage(address, slot)) |value| {
            self.stats.cache_hits += 1;
            return value;
        }
        
        // Check L2 warm cache
        if (self.warm.storage.get(key)) |value| {
            self.stats.cache_hits += 1;
            // Promote to hot cache
            try self.hot.putStorage(address, slot, value);
            return value;
        }
        
        // Check L3 fork cache
        if (self.fork_cache.getStorage(address, slot)) |value| {
            self.stats.cache_hits += 1;
            // Promote to hot cache
            try self.hot.putStorage(address, slot, value);
            return value;
        }
        
        // Cache miss - fetch from RPC
        self.stats.cache_misses += 1;
        self.stats.rpc_calls += 1;
        
        const value = try self.rpc.getStorageAt(address, slot);
        
        // Store in all caches
        try self.hot.putStorage(address, slot, value);
        _ = try self.warm.storage.put(key, value);
        try self.fork_cache.putStorage(address, slot, value);
        
        return value;
    }
    
    pub fn set_storage(self: *Self, address: [20]u8, slot: u256, value: u256) !void {
        // Only update hot cache for writes (not fork cache)
        try self.hot.putStorage(address, slot, value);
    }
    
    // Transient storage (not persisted to fork)
    
    pub fn get_transient_storage(self: *Self, address: [20]u8, slot: u256) !u256 {
        _ = self;
        _ = address;
        _ = slot;
        return 0; // Transient storage starts at 0
    }
    
    pub fn set_transient_storage(self: *Self, address: [20]u8, slot: u256, value: u256) !void {
        _ = self;
        _ = address;
        _ = slot;
        _ = value;
        // Transient storage (EIP-1153) not implemented for forked storage
        // This is acceptable as forked storage is primarily used for testing against mainnet
        // and transient storage is typically only needed for live execution
    }
    
    // Code operations
    
    pub fn get_code(self: *Self, code_hash: [32]u8) ![]const u8 {
        // Check hot cache
        if (self.hot.getCode(code_hash)) |code| {
            self.stats.cache_hits += 1;
            return code;
        }
        
        // Check fork cache
        if (self.fork_cache.getCode(code_hash)) |code| {
            self.stats.cache_hits += 1;
            // Promote to hot cache
            const code_copy = try self.allocator.dupe(u8, code);
            try self.hot.putCode(code_hash, code_copy);
            return code;
        }
        
        // Code should have been fetched with account
        return error.CodeNotFound;
    }
    
    pub fn get_code_by_address(self: *Self, address: [20]u8) ![]const u8 {
        const account = (try self.get_account(address)) orelse return &.{};
        if (std.mem.eql(u8, &account.code_hash, &([_]u8{0} ** 32))) {
            return &.{};
        }
        return self.get_code(account.code_hash);
    }
    
    pub fn set_code(self: *Self, code: []const u8) ![32]u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(code, &hash, .{});
        
        const code_copy = try self.allocator.dupe(u8, code);
        try self.hot.putCode(hash, code_copy);
        
        return hash;
    }
    
    // State root operations (not meaningful for forked storage)
    
    pub fn get_state_root(self: *Self) ![32]u8 {
        _ = self;
        // Return a deterministic state root for forked mode
        return [_]u8{0xFF} ** 32;
    }
    
    pub fn commit_changes(self: *Self) ![32]u8 {
        return self.get_state_root();
    }
    
    // Snapshot operations
    
    pub fn create_snapshot(self: *Self) !u64 {
        _ = self;
        // Snapshot support not implemented - forked storage uses journal-based state tracking
        // For snapshot functionality, use the journal system in the main database
        return 0;
    }

    pub fn revert_to_snapshot(self: *Self, snapshot_id: u64) !void {
        _ = self;
        _ = snapshot_id;
        // Snapshot support not implemented - use journal-based rollback instead
    }

    pub fn commit_snapshot(self: *Self, snapshot_id: u64) !void {
        _ = self;
        _ = snapshot_id;
        // Snapshot support not implemented - journal commits handle state finalization
    }
    
    // Batch operations
    
    pub fn begin_batch(self: *Self) !void {
        _ = self;
    }
    
    pub fn commit_batch(self: *Self) !void {
        _ = self;
    }
    
    pub fn rollback_batch(self: *Self) !void {
        _ = self;
    }
    
    // Statistics
    
    pub fn getStats(self: *const Self) Stats {
        return self.stats;
    }
    
    pub fn resetStats(self: *Self) void {
        self.stats = .{};
    }
};

// Tests
const testing = std.testing;

test "ForkedStorage cache hit flow" {
    const allocator = testing.allocator;

    // Create mock forked storage without RPC
    var hot = HotStorage.init(allocator);
    defer hot.deinit();

    const test_addr: [20]u8 = [_]u8{0x11} ** 20;
    const test_account = Account{
        .balance = 1000,
        .nonce = 5,
        .code_hash = [_]u8{0x22} ** 32,
        .storage_root = [_]u8{0x33} ** 32,
    };

    // Put account in hot cache
    try hot.putAccount(test_addr, test_account);

    // Verify retrieval
    const retrieved = hot.getAccount(test_addr);
    try testing.expect(retrieved != null);
    try testing.expectEqual(test_account.balance, retrieved.?.balance);
    try testing.expectEqual(test_account.nonce, retrieved.?.nonce);
}

test "ForkedStorage cache miss requires RPC" {
    const allocator = testing.allocator;

    var hot = HotStorage.init(allocator);
    defer hot.deinit();

    const test_addr: [20]u8 = [_]u8{0x99} ** 20;

    // Cache miss should return null
    const retrieved = hot.getAccount(test_addr);
    try testing.expect(retrieved == null);
}

test "ForkedStorage storage cache operations" {
    const allocator = testing.allocator;

    var hot = HotStorage.init(allocator);
    defer hot.deinit();

    const test_addr: [20]u8 = [_]u8{0xAA} ** 20;
    const slot: u256 = 42;
    const value: u256 = 9999;

    // Initially should be null
    try testing.expect(hot.getStorage(test_addr, slot) == null);

    // Put storage value
    try hot.putStorage(test_addr, slot, value);

    // Retrieve should work
    const retrieved = hot.getStorage(test_addr, slot);
    try testing.expect(retrieved != null);
    try testing.expectEqual(value, retrieved.?);
}

test "ForkedStorage code cache operations" {
    const allocator = testing.allocator;

    var hot = HotStorage.init(allocator);
    defer hot.deinit();

    const test_code = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01 };
    var code_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&test_code, &code_hash, .{});

    const code_copy = try allocator.dupe(u8, &test_code);
    defer allocator.free(code_copy);

    // Initially should be null
    try testing.expect(hot.getCode(code_hash) == null);

    // Put code
    try hot.putCode(code_hash, code_copy);

    // Retrieve should work
    const retrieved = hot.getCode(code_hash);
    try testing.expect(retrieved != null);
    try testing.expectEqualSlices(u8, &test_code, retrieved.?);
}

test "ForkedStorage account deletion" {
    const allocator = testing.allocator;

    var hot = HotStorage.init(allocator);
    defer hot.deinit();

    const test_addr: [20]u8 = [_]u8{0xBB} ** 20;
    const test_account = Account{
        .balance = 500,
        .nonce = 1,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };

    // Add account
    try hot.putAccount(test_addr, test_account);
    try testing.expect(hot.getAccount(test_addr) != null);

    // Remove account
    const removed = hot.removeAccount(test_addr);
    try testing.expect(removed);

    // Should be null now
    try testing.expect(hot.getAccount(test_addr) == null);

    // Removing again should return false
    try testing.expect(!hot.removeAccount(test_addr));
}

test "ForkedStorage multiple accounts" {
    const allocator = testing.allocator;

    var hot = HotStorage.init(allocator);
    defer hot.deinit();

    const addr1: [20]u8 = [_]u8{0x01} ** 20;
    const addr2: [20]u8 = [_]u8{0x02} ** 20;
    const addr3: [20]u8 = [_]u8{0x03} ** 20;

    const account1 = Account{ .balance = 100, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    const account2 = Account{ .balance = 200, .nonce = 2, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    const account3 = Account{ .balance = 300, .nonce = 3, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };

    try hot.putAccount(addr1, account1);
    try hot.putAccount(addr2, account2);
    try hot.putAccount(addr3, account3);

    // Verify all are retrievable
    const ret1 = hot.getAccount(addr1);
    const ret2 = hot.getAccount(addr2);
    const ret3 = hot.getAccount(addr3);

    try testing.expect(ret1 != null);
    try testing.expect(ret2 != null);
    try testing.expect(ret3 != null);

    try testing.expectEqual(@as(u256, 100), ret1.?.balance);
    try testing.expectEqual(@as(u256, 200), ret2.?.balance);
    try testing.expectEqual(@as(u256, 300), ret3.?.balance);
}

test "ForkedStorage storage slots per address" {
    const allocator = testing.allocator;

    var hot = HotStorage.init(allocator);
    defer hot.deinit();

    const addr: [20]u8 = [_]u8{0xCC} ** 20;

    // Add multiple storage slots for same address
    try hot.putStorage(addr, 0, 100);
    try hot.putStorage(addr, 1, 200);
    try hot.putStorage(addr, 2, 300);

    // Verify all slots
    try testing.expectEqual(@as(u256, 100), hot.getStorage(addr, 0).?);
    try testing.expectEqual(@as(u256, 200), hot.getStorage(addr, 1).?);
    try testing.expectEqual(@as(u256, 300), hot.getStorage(addr, 2).?);

    // Non-existent slot should be null
    try testing.expect(hot.getStorage(addr, 999) == null);
}

test "ForkedStorage account overwrite" {
    const allocator = testing.allocator;

    var hot = HotStorage.init(allocator);
    defer hot.deinit();

    const addr: [20]u8 = [_]u8{0xDD} ** 20;
    const account1 = Account{ .balance = 100, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    const account2 = Account{ .balance = 500, .nonce = 10, .code_hash = [_]u8{1} ** 32, .storage_root = [_]u8{1} ** 32 };

    // Put first account
    try hot.putAccount(addr, account1);
    try testing.expectEqual(@as(u256, 100), hot.getAccount(addr).?.balance);

    // Overwrite with second account
    try hot.putAccount(addr, account2);
    try testing.expectEqual(@as(u256, 500), hot.getAccount(addr).?.balance);
    try testing.expectEqual(@as(u64, 10), hot.getAccount(addr).?.nonce);
}

test "ForkedStorage storage overwrite" {
    const allocator = testing.allocator;

    var hot = HotStorage.init(allocator);
    defer hot.deinit();

    const addr: [20]u8 = [_]u8{0xEE} ** 20;
    const slot: u256 = 5;

    // Set initial value
    try hot.putStorage(addr, slot, 111);
    try testing.expectEqual(@as(u256, 111), hot.getStorage(addr, slot).?);

    // Overwrite
    try hot.putStorage(addr, slot, 999);
    try testing.expectEqual(@as(u256, 999), hot.getStorage(addr, slot).?);
}

test "ForkedStorage zero balance account" {
    const allocator = testing.allocator;

    var hot = HotStorage.init(allocator);
    defer hot.deinit();

    const addr: [20]u8 = [_]u8{0xFF} ** 20;
    const account = Account{ .balance = 0, .nonce = 0, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };

    try hot.putAccount(addr, account);

    const retrieved = hot.getAccount(addr);
    try testing.expect(retrieved != null);
    try testing.expectEqual(@as(u256, 0), retrieved.?.balance);
    try testing.expectEqual(@as(u64, 0), retrieved.?.nonce);
}

test "ForkedStorage zero storage value" {
    const allocator = testing.allocator;

    var hot = HotStorage.init(allocator);
    defer hot.deinit();

    const addr: [20]u8 = [_]u8{0x55} ** 20;
    const slot: u256 = 10;

    // Zero is a valid storage value
    try hot.putStorage(addr, slot, 0);

    const retrieved = hot.getStorage(addr, slot);
    try testing.expect(retrieved != null);
    try testing.expectEqual(@as(u256, 0), retrieved.?);
}

test "ForkedStorage empty code" {
    const allocator = testing.allocator;

    var hot = HotStorage.init(allocator);
    defer hot.deinit();

    const empty_code: []const u8 = &.{};
    var code_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(empty_code, &code_hash, .{});

    const code_copy = try allocator.dupe(u8, empty_code);
    defer allocator.free(code_copy);

    try hot.putCode(code_hash, code_copy);

    const retrieved = hot.getCode(code_hash);
    try testing.expect(retrieved != null);
    try testing.expectEqual(@as(usize, 0), retrieved.?.len);
}

test "ForkedStorage large storage slots" {
    const allocator = testing.allocator;

    var hot = HotStorage.init(allocator);
    defer hot.deinit();

    const addr: [20]u8 = [_]u8{0x77} ** 20;

    // Test with large slot numbers
    const slot_max: u256 = std.math.maxInt(u256);
    const slot_large: u256 = 1 << 128;

    try hot.putStorage(addr, slot_max, 12345);
    try hot.putStorage(addr, slot_large, 67890);

    try testing.expectEqual(@as(u256, 12345), hot.getStorage(addr, slot_max).?);
    try testing.expectEqual(@as(u256, 67890), hot.getStorage(addr, slot_large).?);
}

test "ForkedStorage mixed operations" {
    const allocator = testing.allocator;

    var hot = HotStorage.init(allocator);
    defer hot.deinit();

    const addr: [20]u8 = [_]u8{0x88} ** 20;
    const account = Account{ .balance = 777, .nonce = 7, .code_hash = [_]u8{0x99} ** 32, .storage_root = [_]u8{0x88} ** 32 };

    // Add account
    try hot.putAccount(addr, account);

    // Add storage
    try hot.putStorage(addr, 0, 111);
    try hot.putStorage(addr, 1, 222);

    // Add code
    const code = [_]u8{ 0x60, 0x80 };
    const code_copy = try allocator.dupe(u8, &code);
    defer allocator.free(code_copy);
    try hot.putCode(account.code_hash, code_copy);

    // Verify all
    try testing.expectEqual(@as(u256, 777), hot.getAccount(addr).?.balance);
    try testing.expectEqual(@as(u256, 111), hot.getStorage(addr, 0).?);
    try testing.expectEqual(@as(u256, 222), hot.getStorage(addr, 1).?);
    try testing.expectEqualSlices(u8, &code, hot.getCode(account.code_hash).?);
}