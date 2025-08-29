//! In-memory implementation of the database interface.
//!
//! Provides a complete state storage solution for testing and development.
//! Supports snapshots for transaction rollback and batch operations for
//! atomic updates. Not suitable for production due to memory constraints.

const std = @import("std");
const Database = @import("database.zig").Database;
const Account = @import("database.zig").Account;
const crypto = @import("crypto");
const primitives = @import("primitives");

/// In-memory database with snapshot and batch operation support.
pub const MemoryDatabase = struct {
    allocator: std.mem.Allocator,
    accounts: std.hash_map.HashMap([20]u8, Account, AccountContext, 80),
    storage: std.hash_map.HashMap(StorageKey, u256, StorageKeyContext, 80),
    transient_storage: std.hash_map.HashMap(StorageKey, u256, StorageKeyContext, 80),
    codes: std.hash_map.HashMap([32]u8, []u8, CodeHashContext, 80),
    snapshots: std.ArrayList(Snapshot),
    next_snapshot_id: u64,
    batch_in_progress: bool,
    batch_changes: ?BatchChanges,

    const Self = @This();

    const StorageKey = struct {
        address: [20]u8,
        key: u256,
    };

    const Snapshot = struct {
        id: u64,
        accounts: std.hash_map.HashMap([20]u8, Account, AccountContext, 80),
        storage: std.hash_map.HashMap(StorageKey, u256, StorageKeyContext, 80),
    };

    const BatchChanges = struct {
        accounts: std.hash_map.HashMap([20]u8, ?Account, AccountContext, 80),
        storage: std.hash_map.HashMap(StorageKey, u256, StorageKeyContext, 80),
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
            .accounts = std.hash_map.HashMap([20]u8, Account, AccountContext, 80).init(allocator),
            .storage = std.hash_map.HashMap(StorageKey, u256, StorageKeyContext, 80).init(allocator),
            .transient_storage = std.hash_map.HashMap(StorageKey, u256, StorageKeyContext, 80).init(allocator),
            .codes = std.hash_map.HashMap([32]u8, []u8, CodeHashContext, 80).init(allocator),
            .snapshots = std.ArrayList(Snapshot){},
            .next_snapshot_id = 0,
            .batch_in_progress = false,
            .batch_changes = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.accounts.deinit();
        self.storage.deinit();
        self.transient_storage.deinit();
        
        // Free all stored code
        var code_iter = self.codes.iterator();
        while (code_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.codes.deinit();
        
        // Free all snapshots
        for (self.snapshots.items) |*snapshot| {
            snapshot.accounts.deinit();
            snapshot.storage.deinit();
        }
        self.snapshots.deinit();
        
        // Free batch changes if any
        if (self.batch_changes) |*batch| {
            batch.accounts.deinit();
            batch.storage.deinit();
        }
    }

    /// Convert to the generic database interface.
    /// Since we now use concrete Database type, return self as the concrete implementation
    pub fn to_database_interface(self: *Self) *Self {
        return self;
    }

    // Account operations

    pub fn get_account(self: *Self, address: [20]u8) Database.Error!?Account {
        if (self.batch_in_progress) {
            if (self.batch_changes) |*batch| {
                if (batch.accounts.get(address)) |maybe_account| {
                    return maybe_account;
                }
            }
        }
        return self.accounts.get(address);
    }

    pub fn set_account(self: *Self, address: [20]u8, account: Account) Database.Error!void {
        if (self.batch_in_progress) {
            if (self.batch_changes) |*batch| {
                try batch.accounts.put(address, account);
                return;
            }
        }
        try self.accounts.put(address, account);
    }

    pub fn delete_account(self: *Self, address: [20]u8) Database.Error!void {
        if (self.batch_in_progress) {
            if (self.batch_changes) |*batch| {
                try batch.accounts.put(address, null);
                return;
            }
        }
        _ = self.accounts.remove(address);
    }

    pub fn account_exists(self: *Self, address: [20]u8) bool {
        if (self.batch_in_progress) {
            if (self.batch_changes) |*batch| {
                if (batch.accounts.get(address)) |maybe_account| {
                    return maybe_account != null;
                }
            }
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
        if (self.batch_in_progress) {
            if (self.batch_changes) |*batch| {
                if (batch.storage.get(storage_key)) |value| {
                    return value;
                }
            }
        }
        return self.storage.get(storage_key) orelse 0;
    }

    pub fn set_storage(self: *Self, address: [20]u8, key: u256, value: u256) Database.Error!void {
        const storage_key = StorageKey{ .address = address, .key = key };
        if (self.batch_in_progress) {
            if (self.batch_changes) |*batch| {
                try batch.storage.put(storage_key, value);
                return;
            }
        }
        if (value == 0) {
            _ = self.storage.remove(storage_key);
        } else {
            try self.storage.put(storage_key, value);
        }
    }

    pub fn get_transient_storage(self: *Self, address: [20]u8, key: u256) Database.Error!u256 {
        const storage_key = StorageKey{ .address = address, .key = key };
        return self.transient_storage.get(storage_key) orelse 0;
    }

    pub fn set_transient_storage(self: *Self, address: [20]u8, key: u256, value: u256) Database.Error!void {
        const storage_key = StorageKey{ .address = address, .key = key };
        if (value == 0) {
            _ = self.transient_storage.remove(storage_key);
        } else {
            try self.transient_storage.put(storage_key, value);
        }
    }

    // Code operations

    pub fn get_code(self: *Self, code_hash: [32]u8) Database.Error![]const u8 {
        return self.codes.get(code_hash) orelse return Database.Error.CodeNotFound;
    }

    pub fn get_code_by_address(self: *Self, address: [20]u8) Database.Error![]const u8 {
        const account = try self.get_account(address);
        if (account) |acc| {
            if (std.mem.eql(u8, &acc.code_hash, &[_]u8{0} ** 32)) {
                return &[_]u8{};
            }
            return self.get_code(acc.code_hash);
        }
        return &[_]u8{};
    }

    pub fn set_code(self: *Self, code: []const u8) Database.Error![32]u8 {
        // Calculate keccak256 hash of the code
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(code, &hash, .{});
        
        // Store the code
        const code_copy = try self.allocator.dupe(u8, code);
        errdefer self.allocator.free(code_copy);
        
        try self.codes.put(hash, code_copy);
        
        return hash;
    }

    // State root operations (simplified for in-memory)

    pub fn get_state_root(self: *Self) Database.Error![32]u8 {
        _ = self;
        // For in-memory database, return a dummy root
        return [_]u8{0} ** 32;
    }

    pub fn commit_changes(self: *Self) Database.Error![32]u8 {
        // Clear transient storage
        self.transient_storage.clearAndFree();
        
        // Return dummy root
        return [_]u8{0} ** 32;
    }

    // Snapshot operations

    pub fn create_snapshot(self: *Self) Database.Error!u64 {
        const snapshot_id = self.next_snapshot_id;
        self.next_snapshot_id += 1;
        
        // Clone current state
        var snapshot_accounts = std.hash_map.HashMap([20]u8, Account, AccountContext, 80).init(self.allocator);
        errdefer snapshot_accounts.deinit();
        
        var accounts_iter = self.accounts.iterator();
        while (accounts_iter.next()) |entry| {
            try snapshot_accounts.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        
        var snapshot_storage = std.hash_map.HashMap(StorageKey, u256, StorageKeyContext, 80).init(self.allocator);
        errdefer snapshot_storage.deinit();
        
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

    pub fn revert_to_snapshot(self: *Self, snapshot_id: u64) Database.Error!void {
        // Find the snapshot
        var snapshot_index: ?usize = null;
        for (self.snapshots.items, 0..) |snapshot, i| {
            if (snapshot.id == snapshot_id) {
                snapshot_index = i;
                break;
            }
        }
        
        const index = snapshot_index orelse return Database.Error.SnapshotNotFound;
        
        // Revert to the snapshot state
        const snapshot = self.snapshots.items[index];
        
        // Clear current state
        self.accounts.clearAndFree();
        self.storage.clearAndFree();
        
        // Copy snapshot state
        var accounts_iter = snapshot.accounts.iterator();
        while (accounts_iter.next()) |entry| {
            try self.accounts.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        
        var storage_iter = snapshot.storage.iterator();
        while (storage_iter.next()) |entry| {
            try self.storage.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        
        // Remove this and all later snapshots
        while (self.snapshots.items.len > index) {
            if (self.snapshots.items.len > 0) {
                var removed = self.snapshots.items[self.snapshots.items.len - 1];
                _ = self.snapshots.pop();
                removed.accounts.deinit();
                removed.storage.deinit();
            }
        }
    }

    pub fn commit_snapshot(self: *Self, snapshot_id: u64) Database.Error!void {
        // Find and remove the snapshot
        var snapshot_index: ?usize = null;
        for (self.snapshots.items, 0..) |snapshot, i| {
            if (snapshot.id == snapshot_id) {
                snapshot_index = i;
                break;
            }
        }
        
        const index = snapshot_index orelse return Database.Error.SnapshotNotFound;
        
        var removed = self.snapshots.orderedRemove(index);
        removed.accounts.deinit();
        removed.storage.deinit();
    }

    // Batch operations

    pub fn begin_batch(self: *Self) Database.Error!void {
        if (self.batch_in_progress) return Database.Error.NoBatchInProgress;
        
        self.batch_in_progress = true;
        self.batch_changes = BatchChanges{
            .accounts = std.hash_map.HashMap([20]u8, ?Account, AccountContext, 80).init(self.allocator),
            .storage = std.hash_map.HashMap(StorageKey, u256, StorageKeyContext, 80).init(self.allocator),
        };
    }

    pub fn commit_batch(self: *Self) Database.Error!void {
        if (!self.batch_in_progress) return Database.Error.NoBatchInProgress;
        
        if (self.batch_changes) |*batch| {
            // Apply account changes
            var accounts_iter = batch.accounts.iterator();
            while (accounts_iter.next()) |entry| {
                if (entry.value_ptr.*) |account| {
                    try self.accounts.put(entry.key_ptr.*, account);
                } else {
                    _ = self.accounts.remove(entry.key_ptr.*);
                }
            }
            
            // Apply storage changes
            var storage_iter = batch.storage.iterator();
            while (storage_iter.next()) |entry| {
                if (entry.value_ptr.* == 0) {
                    _ = self.storage.remove(entry.key_ptr.*);
                } else {
                    try self.storage.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            }
            
            batch.accounts.deinit();
            batch.storage.deinit();
        }
        
        self.batch_in_progress = false;
        self.batch_changes = null;
    }

    pub fn rollback_batch(self: *Self) Database.Error!void {
        if (!self.batch_in_progress) return Database.Error.NoBatchInProgress;
        
        if (self.batch_changes) |*batch| {
            batch.accounts.deinit();
            batch.storage.deinit();
        }
        
        self.batch_in_progress = false;
        self.batch_changes = null;
    }
};

test "MemoryDatabase basic operations" {
    const allocator = std.testing.allocator;
    
    var db = MemoryDatabase.init(allocator);
    defer db.deinit();
    
    // Database is now used directly
    
    // Test account operations
    const address = [_]u8{1} ** 20;
    const account = Account{
        .balance = 1000,
        .nonce = 5,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
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
    
    // Database is now used directly
    
    // Set initial state
    const address = [_]u8{1} ** 20;
    const account1 = Account{
        .balance = 1000,
        .nonce = 1,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    
    try db.set_account(address, account1);
    
    // Create snapshot
    const snapshot_id = try db.create_snapshot();
    
    // Modify state
    const account2 = Account{
        .balance = 2000,
        .nonce = 2,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
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

// Tests for CREATE/CREATE2 code storage and retrieval
// These tests verify that contract code is properly stored in the database
// and can be retrieved after deployment

fn to_address(n: u32) [20]u8 {
    var addr = [_]u8{0} ** 20;
    std.mem.writeInt(u32, addr[16..20], n, .big);
    return addr;
}

fn to_u256(addr: [20]u8) u256 {
    return primitives.Address.to_u256(addr);
}

// Helper to create test EVM
const TestEvm = struct {
    evm: *@import("evm.zig").DefaultEvm,
    memory_db: *MemoryDatabase,
};

fn createTestEvm(allocator: std.mem.Allocator) !TestEvm {
    const memory_db = try allocator.create(MemoryDatabase);
    memory_db.* = MemoryDatabase.init(allocator);
    
    // Using database directly now
    const evm_ptr = try allocator.create(@import("evm.zig").DefaultEvm);
    const block_info = @import("block_info.zig").DefaultBlockInfo.init();
    const tx_context = @import("transaction_context.zig").TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = [_]u8{0} ** 20,
        .chain_id = 1,
    };
    evm_ptr.* = try @import("evm.zig").DefaultEvm.init(allocator, memory_db, block_info, tx_context, 0, [_]u8{0} ** 20, .CANCUN);
    
    return TestEvm{ .evm = evm_ptr, .memory_db = memory_db };
}

// Simple contract that returns its own code
const RETURN_OWN_CODE_CONTRACT = [_]u8{
    // Get code size
    0x38,       // CODESIZE
    0x60, 0x00, // PUSH1 0 (offset)
    0x52,       // MSTORE
    
    // Copy code to memory
    0x38,       // CODESIZE
    0x60, 0x00, // PUSH1 0 (dest offset)
    0x60, 0x00, // PUSH1 0 (src offset)
    0x39,       // CODECOPY
    
    // Return the code
    0x38,       // CODESIZE
    0x60, 0x00, // PUSH1 0 (memory offset)
    0xF3,       // RETURN
};

// Simple contract constructor that deploys a minimal contract
// Constructor: stores a simple "hello" contract
const CONSTRUCTOR_CONTRACT = [_]u8{
    // Load the runtime code and return it
    0x60, 0x0A, // PUSH1 10 (size of runtime code)
    0x60, 0x0C, // PUSH1 12 (offset to runtime code)
    0x60, 0x00, // PUSH1 0 (memory dest)
    0x39,       // CODECOPY
    0x60, 0x0A, // PUSH1 10 (size)
    0x60, 0x00, // PUSH1 0 (offset)
    0xF3,       // RETURN
    
    // Runtime code starts here (offset 12):
    0x60, 0x42, // PUSH1 0x42 ("hello" value)
    0x60, 0x00, // PUSH1 0
    0x52,       // MSTORE
    0x60, 0x20, // PUSH1 32
    0x60, 0x00, // PUSH1 0
    0xF3,       // RETURN
};

test "CREATE stores code and retrieves via get_code_by_address" {
    return error.SkipZigTest; // TODO: Update to use new architecture

    //     return error.SkipZigTest; // TODO: Update to use new architecture
    //     const skip = std.time.nanoTimestamp() >= 0; // runtime-true to skip without unreachable
    //     if (skip) return error.SkipZigTest;
    //     const allocator = std.testing.allocator;
    
    //     // Create EVM
    //     const result = try createTestEvm(allocator);
    //     var evm = result.evm;
    //     var memory_db = result.memory_db;
    //     defer {
    //         evm.deinit();
    //         allocator.destroy(evm);
    //         db.deinit();
    //         allocator.destroy(memory_db);
    //     }
    
    //     const creator_address = to_address(0x1000);
    //     const host = evm.to_host();
    //     const FrameInterpreterType = @import("frame_interpreter.zig").FrameInterpreter(.{ .has_database = true });
    
    //     // Set up creator account with balance
    //     var creator_account = Account.zero();
    //     creator_account.balance = 100000;
    //     try evm.database.set_account(creator_address, creator_account);
    
    //     // Prepare CREATE bytecode:
    //     // 1. Put constructor code in memory
    //     // 2. Call CREATE
    //     var create_bytecode = std.ArrayList(u8).init(allocator);
    //     defer create_bytecode.deinit();
    
    //     // Store constructor code in memory at offset 0
    //     for (CONSTRUCTOR_CONTRACT, 0..) |byte, i| {
    //         try create_bytecode.append(0x60); // PUSH1
    //         try create_bytecode.append(byte);
    //         try create_bytecode.append(0x60); // PUSH1
    //         try create_bytecode.append(@intCast(i));
    //         try create_bytecode.append(0x52); // MSTORE8
    //     }
    
    //     // CREATE: value=0, offset=0, size=len(CONSTRUCTOR_CONTRACT)
    //     try create_bytecode.append(0x60); // PUSH1
    //     try create_bytecode.append(@intCast(CONSTRUCTOR_CONTRACT.len)); // size
    //     try create_bytecode.append(0x60); // PUSH1 
    //     try create_bytecode.append(0x00); // offset
    //     try create_bytecode.append(0x60); // PUSH1
    //     try create_bytecode.append(0x00); // value
    //     try create_bytecode.append(0xF0); // CREATE
    
    //     // STOP
    //     try create_bytecode.append(0x00);
    
    //     // Execute CREATE
    //     var interpreter = try FrameInterpreterType.init(allocator, create_bytecode.items, 1000000, evm.database, host);
    //     defer interpreter.deinit(allocator);
    
    //     interpreter.frame.contract_address = creator_address;
    
    //     // Execute until STOP (interpret handles STOP internally)
    //     try interpreter.interpret();
    
    //     // Get the created address from stack
    //     try std.testing.expectEqual(@as(usize, 1), interpreter.frame.stack.size());
    //     const created_address_u256 = try interpreter.frame.stack.pop();
    //     const created_address = @import("primitives").Address.from_u256(created_address_u256);
    
    //     // Verify the created contract exists
    //     const created_account = try evm.database.get_account(created_address);
    //     try std.testing.expect(created_account != null);
    
    //     // Get the deployed code
    //     const deployed_code = try evm.database.get_code_by_address(created_address);
    
    //     // The deployed code should be the runtime code (last 10 bytes of CONSTRUCTOR_CONTRACT)
    //     const expected_runtime_code = CONSTRUCTOR_CONTRACT[12..];
    //     try std.testing.expectEqualSlices(u8, expected_runtime_code, deployed_code);
    
    //     // Verify we can also get code by address
    //     const code_by_address = try evm.database.get_code_by_address(created_address);
    //     try std.testing.expectEqualSlices(u8, expected_runtime_code, code_by_address);
}

test "CREATE2 stores code with deterministic address" {
    return error.SkipZigTest; // TODO: Update to use new architecture

    //     return error.SkipZigTest; // TODO: Update to use new architecture
    //     const skip = std.time.nanoTimestamp() >= 0; // runtime-true to skip without unreachable
    //     if (skip) return error.SkipZigTest;
    //     const allocator = std.testing.allocator;
    
    //     // Create EVM
    //     const result = try createTestEvm(allocator);
    //     var evm = result.evm;
    //     var memory_db = result.memory_db;
    //     defer {
    //         evm.deinit();
    //         allocator.destroy(evm);
    //         db.deinit();
    //         allocator.destroy(memory_db);
    //     }
    
    //     const creator_address = to_address(0x2000);
    //     const salt: u256 = 0x123456789abcdef;
    
    //     // Set up creator account
    //     var creator_account = Account.zero();
    //     creator_account.balance = 100000;
    //     try evm.database.set_account(creator_address, creator_account);
    
    //     // Calculate expected CREATE2 address
    //     const expected_address = try calculateCreate2Address(creator_address, salt, &CONSTRUCTOR_CONTRACT);
    
    //     const host = evm.to_host();
    //     const FrameInterpreterType = @import("frame_interpreter.zig").FrameInterpreter(.{ .has_database = true });
    
    //     // Prepare CREATE2 bytecode
    //     var create2_bytecode = std.ArrayList(u8).init(allocator);
    //     defer create2_bytecode.deinit();
    
    //     // Store constructor code in memory
    //     for (CONSTRUCTOR_CONTRACT, 0..) |byte, i| {
    //         try create2_bytecode.append(0x60); // PUSH1
    //         try create2_bytecode.append(byte);
    //         try create2_bytecode.append(0x60); // PUSH1
    //         try create2_bytecode.append(@intCast(i));
    //         try create2_bytecode.append(0x52); // MSTORE8
    //     }
    
    //     // CREATE2: salt, size, offset, value
    //     // Push salt (32 bytes)
    //     try create2_bytecode.appendSlice(&[_]u8{ 0x7F }); // PUSH32
    //     var salt_bytes: [32]u8 = @bitCast(salt);
    //     // Convert to big-endian
    //     std.mem.reverse(u8, &salt_bytes);
    //     try create2_bytecode.appendSlice(&salt_bytes);
    
    //     try create2_bytecode.append(0x60); // PUSH1
    //     try create2_bytecode.append(@intCast(CONSTRUCTOR_CONTRACT.len)); // size
    //     try create2_bytecode.append(0x60); // PUSH1
    //     try create2_bytecode.append(0x00); // offset
    //     try create2_bytecode.append(0x60); // PUSH1
    //     try create2_bytecode.append(0x00); // value
    //     try create2_bytecode.append(0xF5); // CREATE2
    
    //     // STOP
    //     try create2_bytecode.append(0x00);
    
    //     // Execute CREATE2
    //     var interpreter = try FrameInterpreterType.init(allocator, create2_bytecode.items, 1000000, evm.database, host);
    //     defer interpreter.deinit(allocator);
    
    //     interpreter.frame.contract_address = creator_address;
    
    //     // Execute until STOP
    //     try interpreter.interpret();
    
    //     // Get the created address from stack
    //     try std.testing.expectEqual(@as(usize, 1), interpreter.frame.stack.size());
    //     const created_address_u256 = try interpreter.frame.stack.pop();
    //     const created_address = @import("primitives").Address.from_u256(created_address_u256);
    
    //     // Verify it matches the expected CREATE2 address
    //     try std.testing.expectEqual(expected_address, created_address);
    
    //     // Verify the contract exists and has correct code
    //     const created_account = try evm.database.get_account(created_address);
    //     try std.testing.expect(created_account != null);
    
    //     const deployed_code = try evm.database.get_code_by_address(created_address);
    //     const expected_runtime_code = CONSTRUCTOR_CONTRACT[12..];
    //     try std.testing.expectEqualSlices(u8, expected_runtime_code, deployed_code);
}

test "get_code_by_address returns empty for non-existent contracts" {
    const allocator = std.testing.allocator;
    
    const result = try createTestEvm(allocator);
    var evm = result.evm;
    var memory_db = result.memory_db;
    defer {
        evm.deinit();
        allocator.destroy(evm);
        memory_db.deinit();
        allocator.destroy(memory_db);
    }
    
    const non_existent_address = to_address(0x9999);
    
    // Should return empty slice for non-existent contract
    const code = try evm.database.get_code_by_address(non_existent_address);
    try std.testing.expectEqual(@as(usize, 0), code.len);
}

test "get_code_by_address returns empty for EOA (externally owned account)" {
    const allocator = std.testing.allocator;
    
    const result = try createTestEvm(allocator);
    var evm = result.evm;
    var memory_db = result.memory_db;
    defer {
        evm.deinit();
        allocator.destroy(evm);
        memory_db.deinit();
        allocator.destroy(memory_db);
    }
    
    const eoa_address = to_address(0x4000);
    
    // Create an EOA (account with balance but no code)
    var eoa_account = Account.zero();
    eoa_account.balance = 1000;
    try evm.database.set_account(eoa_address, eoa_account);
    
    // Should return empty code for EOA
    const code = try evm.database.get_code_by_address(eoa_address);
    try std.testing.expectEqual(@as(usize, 0), code.len);
}

test "Code storage persistence across multiple operations" {
    const allocator = std.testing.allocator;
    
    const result = try createTestEvm(allocator);
    var evm = result.evm;
    var memory_db = result.memory_db;
    defer {
        evm.deinit();
        allocator.destroy(evm);
        memory_db.deinit();
        allocator.destroy(memory_db);
    }
    
    const test_code = [_]u8{ 0x60, 0x42, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xF3 };
    const contract_address = to_address(0x5000);
    
    // Manually set contract code
    const code_hash = try evm.database.set_code(&test_code);
    var account = Account.zero();
    account.code_hash = code_hash;
    try evm.database.set_account(contract_address, account);
    
    // Retrieve code multiple times to ensure persistence
    for (0..5) |_| {
        const retrieved_code = try evm.database.get_code_by_address(contract_address);
        try std.testing.expectEqualSlices(u8, &test_code, retrieved_code);
        
        const retrieved_code_by_hash = try evm.database.get_code(code_hash);
        try std.testing.expectEqualSlices(u8, &test_code, retrieved_code_by_hash);
    }
    
    // Modify account but keep same code hash
    account.balance = 9999;
    try evm.database.set_account(contract_address, account);
    
    // Code should still be the same
    const code_after_balance_change = try evm.database.get_code_by_address(contract_address);
    try std.testing.expectEqualSlices(u8, &test_code, code_after_balance_change);
}

// Helper function to calculate CREATE2 address
// address = keccak256(0xff ++ creator ++ salt ++ keccak256(init_code))[12:]
fn calculateCreate2Address(creator: [20]u8, salt: u256, init_code: []const u8) ![20]u8 {
    // Calculate init_code hash
    var init_code_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(init_code, &init_code_hash, .{});
    
    // Prepare data for CREATE2 address calculation
    var data: [85]u8 = undefined;
    data[0] = 0xFF;
    @memcpy(data[1..21], &creator);
    
    // Convert salt to big-endian bytes
    var salt_bytes: [32]u8 = @bitCast(salt);
    std.mem.reverse(u8, &salt_bytes);
    @memcpy(data[21..53], &salt_bytes);
    @memcpy(data[53..85], &init_code_hash);
    
    // Hash the data
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&data, &hash, .{});
    
    // Take last 20 bytes as address
    var address: [20]u8 = undefined;
    @memcpy(&address, hash[12..32]);
    return address;
}
