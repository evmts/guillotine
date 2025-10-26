//! Concrete Database Implementation for EVM State Management
//!
//! High-performance in-memory database with full Merkle Patricia Trie state root calculation.
//!
//! ## Features
//!
//! - **Account Management**: Balance, nonce, code hash, storage root
//! - **Contract Storage**: Persistent (SLOAD/SSTORE) and transient (TLOAD/TSTORE, EIP-1153)
//! - **Contract Code**: Keccak256-indexed bytecode storage
//! - **State Root**: Real Merkle Patricia Trie-based state root calculation
//! - **Snapshots**: Reversible state changes for transaction rollback
//! - **Transactions**: Begin/commit/rollback with snapshot-based isolation
//! - **Batch Operations**: Efficient bulk updates (placeholder implementation)
//! - **EIP-7702 Support**: EOA delegation for code execution
//! - **Ephemeral Views**: O(1) overlay for simulate() without state corruption
//!
//! ## Interface Completeness
//!
//! All required database interface methods are implemented:
//!
//! ### Account Operations
//! - `get_account`, `set_account`, `delete_account`: Full account CRUD
//! - `account_exists`: Check if account exists
//! - `get_balance`, `set_balance`: Balance management
//! - `get_nonce`, `set_nonce`: Nonce management
//! - `get_code_hash`: Retrieve account's code hash
//! - `is_empty`: Check if account is empty (EIP-161)
//!
//! ### Code Operations
//! - `get_code`: Retrieve code by hash
//! - `get_code_by_address`: Retrieve code by address (with EIP-7702 delegation support)
//! - `set_code`: Store code and return its hash
//!
//! ### Storage Operations
//! - `get_storage`, `set_storage`: Persistent storage (SLOAD/SSTORE)
//! - `get_transient_storage`, `set_transient_storage`: Transient storage (TLOAD/TSTORE)
//! - `clear_transient_storage`: Clear transient storage at transaction boundary
//!
//! ### State Management
//! - `get_state_root`: Calculate current Merkle Patricia Trie state root
//! - `commit_changes`: Commit pending changes and return state root
//!
//! ### Snapshot Operations
//! - `create_snapshot`: Create reversible checkpoint
//! - `revert_to_snapshot`: Rollback to checkpoint
//! - `commit_snapshot`: Discard checkpoint without reverting
//!
//! ### Transaction Operations
//! - `begin_transaction`: Start transaction (creates snapshot)
//! - `commit_transaction`: Commit transaction (discards snapshot)
//! - `rollback_transaction`: Rollback transaction (reverts to snapshot)
//!
//! ### Batch Operations
//! - `begin_batch`, `commit_batch`, `rollback_batch`: Placeholder for bulk operations
//!
//! ### EIP-7702 Delegation
//! - `set_delegation`: Set EOA to delegate code execution
//! - `clear_delegation`: Remove EOA delegation
//! - `has_delegation`: Check if address has delegation
//!
//! ### Ephemeral Views (Simulate Support)
//! - `begin_ephemeral_view`: Activate overlay for reads without state modification
//! - `discard_ephemeral_view`: Discard overlay and return to base state
//!
//! ## Memory Management
//!
//! All allocated memory is tracked and properly freed on deinit:
//! - Code buffers are owned by the database
//! - Snapshot state is deep-copied
//! - Overlay state is cleared on discard
//!
//! ## Error Handling
//!
//! All operations return proper errors without swallowing them:
//! - `AccountNotFound`: Account does not exist
//! - `CodeNotFound`: Code hash not found
//! - `SnapshotNotFound`: Invalid snapshot ID
//! - `WriteProtection`: Write attempted in static context
//! - `OutOfMemory`: Allocation failed
//!
//! This implementation uses hash maps for O(1) lookups and provides
//! all functionality needed for EVM execution without vtable overhead.

const std = @import("std");
const log = @import("../log.zig");
const primitives = @import("primitives");
pub const Account = @import("database_interface_account.zig").Account;
// Ephemeral overlay support for simulate() O(1) revert

/// All-zero code hash for EOA detection
const ZERO_CODE_HASH = [_]u8{0} ** 32;

/// High-performance in-memory database for EVM state
pub const Database = struct {
    accounts: std.HashMap([20]u8, Account, ArrayHashContext, std.hash_map.default_max_load_percentage),
    storage: std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage),
    transient_storage: std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage),
    code_storage: std.HashMap([32]u8, []const u8, ArrayHashContext, std.hash_map.default_max_load_percentage),
    snapshots: std.ArrayList(Snapshot),
    next_snapshot_id: u64,
    allocator: std.mem.Allocator,
    // Ephemeral overlay state (active only during simulate)
    overlay_active: bool = false,
    overlay_accounts: std.HashMap([20]u8, Account, ArrayHashContext, std.hash_map.default_max_load_percentage),
    overlay_storage: std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage),
    overlay_code: std.HashMap([32]u8, []const u8, ArrayHashContext, std.hash_map.default_max_load_percentage),

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
        // Pre-allocate capacity for transient storage to avoid growth-related memory leaks
        var transient_map = std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage).init(allocator);
        // Reserve initial capacity to prevent HashMap growth during typical TSTORE operations
        // If this fails, HashMap will grow dynamically as needed
        _ = transient_map.ensureTotalCapacity(16) catch 0;
        return Database{
            .accounts = std.HashMap([20]u8, Account, ArrayHashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .storage = std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .transient_storage = transient_map,
            .code_storage = std.HashMap([32]u8, []const u8, ArrayHashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .snapshots = .{ .items = &[_]Snapshot{}, .capacity = 0 },
            .next_snapshot_id = 1,
            .allocator = allocator,
            .overlay_active = false,
            .overlay_accounts = std.HashMap([20]u8, Account, ArrayHashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .overlay_storage = std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .overlay_code = std.HashMap([32]u8, []const u8, ArrayHashContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn begin_ephemeral_view(self: *Database) void {
        if (self.overlay_active) return;
        self.overlay_active = true;
        // Clear any stale overlays
        self.overlay_accounts.clearRetainingCapacity();
        self.overlay_storage.clearRetainingCapacity();
        // Free overlay code buffers if any
        var it = self.overlay_code.iterator();
        while (it.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.overlay_code.clearRetainingCapacity();
    }

    pub fn discard_ephemeral_view(self: *Database) void {
        if (!self.overlay_active) return;
        self.overlay_active = false;
        self.overlay_accounts.clearRetainingCapacity();
        self.overlay_storage.clearRetainingCapacity();
        var it = self.overlay_code.iterator();
        while (it.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.overlay_code.clearRetainingCapacity();
    }

    /// Clean up database resources
    pub fn deinit(self: *Database) void {
        self.accounts.deinit();
        self.storage.deinit();
        self.transient_storage.deinit();

        // Free all allocated code before deinitializing the hashmap
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
        // Deinit overlay
        var it = self.overlay_code.iterator();
        while (it.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.overlay_code.deinit();
        self.overlay_accounts.deinit();
        self.overlay_storage.deinit();
    }

    // Account operations

    /// Get account data for the given address
    pub fn get_account(self: *Database, address: [20]u8) Error!?Account {
        if (self.overlay_active) {
            if (self.overlay_accounts.get(address)) |acc| return acc;
        }
        return self.accounts.get(address);
    }

    /// Set account data for the given address
    pub fn set_account(self: *Database, address: [20]u8, account: Account) Error!void {
        if (self.overlay_active) {
            try self.overlay_accounts.put(address, account);
            return;
        }
        try self.accounts.put(address, account);
    }

    /// Delete account and all associated data
    pub fn delete_account(self: *Database, address: [20]u8) Error!void {
        if (self.overlay_active) {
            _ = self.overlay_accounts.remove(address);
            return;
        }
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

    /// Set account balance
    pub fn set_balance(self: *Database, address: [20]u8, balance: u256) Error!void {
        var account = (try self.get_account(address)) orelse Account.zero();
        account.balance = balance;
        try self.set_account(address, account);
    }

    /// Get account nonce
    pub fn get_nonce(self: *Database, address: [20]u8) Error!u64 {
        if (self.accounts.get(address)) |account| {
            return account.nonce;
        }
        return 0; // Non-existent accounts have zero nonce
    }

    /// Set account nonce
    pub fn set_nonce(self: *Database, address: [20]u8, nonce: u64) Error!void {
        var account = (try self.get_account(address)) orelse Account.zero();
        account.nonce = nonce;
        try self.set_account(address, account);
    }

    /// Get account code hash
    pub fn get_code_hash(self: *Database, address: [20]u8) Error![32]u8 {
        if (self.accounts.get(address)) |account| {
            return account.code_hash;
        }
        return ZERO_CODE_HASH; // Non-existent accounts have zero code hash
    }

    /// Check if account is empty (zero balance, nonce, and no code)
    pub fn is_empty(self: *Database, address: [20]u8) Error!bool {
        if (try self.get_account(address)) |account| {
            return account.is_empty();
        }
        return true; // Non-existent accounts are considered empty
    }

    // Storage operations

    /// Get storage value for the given address and key
    pub fn get_storage(self: *Database, address: [20]u8, key: u256) Error!u256 {
        const storage_key = StorageKey{ .address = address, .key = key };
        if (self.overlay_active) {
            if (self.overlay_storage.get(storage_key)) |v| return v;
        }
        return self.storage.get(storage_key) orelse 0;
    }

    /// Set storage value for the given address and key
    pub fn set_storage(self: *Database, address: [20]u8, key: u256, value: u256) Error!void {
        const storage_key = StorageKey{ .address = address, .key = key };
        if (self.overlay_active) {
            try self.overlay_storage.put(storage_key, value);
            return;
        }
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
        if (self.overlay_active) {
            if (self.overlay_code.get(code_hash)) |buf| return buf;
        }
        const code = self.code_storage.get(code_hash) orelse {
            // log.debug("get_code: Code not found for hash {x}", .{code_hash});
            return Error.CodeNotFound;
        };
        // log.debug("get_code: Found code with len={} for hash {x}", .{code.len, code_hash});
        return code;
    }

    /// Get contract code by address (supports EIP-7702 delegation)
    pub fn get_code_by_address(self: *Database, address: [20]u8) Error![]const u8 {
        // log.debug("get_code_by_address: Looking for address {x}", .{address});

        if (self.accounts.get(address)) |account| {
            // EIP-7702: Check if this EOA has delegated code
            if (account.get_effective_code_address()) |delegated_addr| {
                // log.debug("get_code_by_address: EOA has delegation to {x}", .{delegated_addr.bytes});
                // Recursively get code from delegated address
                return self.get_code_by_address(delegated_addr.bytes);
            }

            // Check if this is an EOA (all-zero code_hash or EMPTY_CODE_HASH)
            // EOAs don't have code stored, return empty code
            if (std.mem.eql(u8, &account.code_hash, &ZERO_CODE_HASH) or
                std.mem.eql(u8, &account.code_hash, &primitives.EMPTY_CODE_HASH))
            {
                return &.{};
            }

            // log.debug("get_code_by_address: Found account with code_hash {x}", .{account.code_hash});
            return self.get_code(account.code_hash);
        }

        // log.debug("get_code_by_address: Account not found for address {x}", .{address});
        return Error.AccountNotFound;
    }

    /// Store contract code and return its hash
    pub fn set_code(self: *Database, code: []const u8) Error![32]u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(code, &hash, .{});
        // log.debug("set_code: Storing code with len={} and hash {x}", .{code.len, hash});

        // Check if code with this hash already exists to avoid memory leak
        if (self.overlay_active) {
            if (self.overlay_code.get(hash)) |_| {
                // Code already exists, no need to store again
                return hash;
            }
        } else {
            if (self.code_storage.get(hash)) |_| {
                // Code already exists, no need to store again
                return hash;
            }
        }

        // Make a copy of the code to own it
        const code_copy = self.allocator.alloc(u8, code.len) catch return Error.OutOfMemory;
        @memcpy(code_copy, code);

        if (self.overlay_active) {
            try self.overlay_code.put(hash, code_copy);
        } else {
            try self.code_storage.put(hash, code_copy);
        }
        return hash;
    }

    // State root operations

    /// RLP encode an account for trie insertion
    /// Account RLP encoding: [nonce, balance, storage_root, code_hash]
    fn encode_account(allocator: std.mem.Allocator, account: Account) Error![]u8 {
        // Pre-calculate sizes for efficiency
        var size: usize = 0;

        // Calculate size for nonce (u64)
        const nonce_bytes = std.mem.asBytes(&account.nonce);
        var nonce_len: usize = 8;
        // Trim leading zeros for canonical encoding
        while (nonce_len > 0 and nonce_bytes[8 - nonce_len] == 0) : (nonce_len -= 1) {}
        size += if (nonce_len <= 1) 1 else 1 + nonce_len;

        // Calculate size for balance (u256)
        var balance_bytes: [32]u8 = undefined;
        std.mem.writeInt(u256, &balance_bytes, account.balance, .big);
        var balance_len: usize = 32;
        // Trim leading zeros
        while (balance_len > 0 and balance_bytes[32 - balance_len] == 0) : (balance_len -= 1) {}
        size += if (balance_len <= 1) 1 else 1 + balance_len;

        // storage_root and code_hash are always 32 bytes
        size += 1 + 32; // storage_root with length prefix
        size += 1 + 32; // code_hash with length prefix

        // Add list header
        const total_size = size;
        const header_size = if (total_size < 56) @as(usize, 1) else 1 + std.math.log2_int(u64, @as(u64, @intCast(total_size))) / 8 + 1;

        const result = try allocator.alloc(u8, header_size + total_size);
        errdefer allocator.free(result);

        var offset: usize = 0;

        // Write list header
        if (total_size < 56) {
            result[offset] = 0xC0 + @as(u8, @intCast(total_size));
            offset += 1;
        } else {
            const len_bytes = std.math.log2_int(u64, @as(u64, @intCast(total_size))) / 8 + 1;
            result[offset] = 0xF7 + @as(u8, @intCast(len_bytes));
            offset += 1;
            var i: usize = len_bytes;
            while (i > 0) : (i -= 1) {
                result[offset] = @intCast((total_size >> ((i - 1) * 8)) & 0xFF);
                offset += 1;
            }
        }

        // Encode nonce
        if (nonce_len == 0) {
            result[offset] = 0x80;
            offset += 1;
        } else if (nonce_len == 1 and nonce_bytes[7] < 0x80) {
            result[offset] = nonce_bytes[7];
            offset += 1;
        } else {
            result[offset] = 0x80 + @as(u8, @intCast(nonce_len));
            offset += 1;
            @memcpy(result[offset..][0..nonce_len], nonce_bytes[8 - nonce_len..]);
            offset += nonce_len;
        }

        // Encode balance
        if (balance_len == 0) {
            result[offset] = 0x80;
            offset += 1;
        } else if (balance_len == 1 and balance_bytes[31] < 0x80) {
            result[offset] = balance_bytes[31];
            offset += 1;
        } else {
            result[offset] = 0x80 + @as(u8, @intCast(balance_len));
            offset += 1;
            @memcpy(result[offset..][0..balance_len], balance_bytes[32 - balance_len..]);
            offset += balance_len;
        }

        // Encode storage_root (always 32 bytes)
        result[offset] = 0xA0; // 0x80 + 32
        offset += 1;
        @memcpy(result[offset..][0..32], &account.storage_root);
        offset += 32;

        // Encode code_hash (always 32 bytes)
        result[offset] = 0xA0; // 0x80 + 32
        offset += 1;
        @memcpy(result[offset..][0..32], &account.code_hash);
        offset += 32;

        return result[0..header_size + total_size];
    }

    /// Get current state root hash by building a trie from all accounts
    pub fn get_state_root(self: *Database) Error![32]u8 {
        // Empty trie hash: keccak256(RLP encode of empty string)
        // RLP of empty string is 0x80, so keccak256(0x80) = 0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421
        const EMPTY_TRIE_ROOT = [_]u8{
            0x56, 0xe8, 0x1f, 0x17, 0x1b, 0xcc, 0x55, 0xa6,
            0xff, 0x83, 0x45, 0xe6, 0x92, 0xc0, 0xf8, 0x6e,
            0x5b, 0x48, 0xe0, 0x1b, 0x99, 0x6c, 0xad, 0xc0,
            0x01, 0x62, 0x2f, 0xb5, 0xe3, 0x63, 0xb4, 0x21,
        };

        // Empty state has a known root
        if (self.accounts.count() == 0) {
            return EMPTY_TRIE_ROOT;
        }

        // Build account trie
        const trie = @import("../trie/hash_builder.zig");
        var builder = trie.HashBuilder.init(self.allocator);
        defer builder.deinit();

        // Insert all accounts into the trie
        var iter = self.accounts.iterator();
        while (iter.next()) |entry| {
            const address = entry.key_ptr.*;
            const account = entry.value_ptr.*;

            // Keccak256 hash the address for the trie key
            var key_hash: [32]u8 = undefined;
            std.crypto.hash.sha3.Keccak256.hash(&address, &key_hash, .{});

            // RLP encode the account
            const encoded_account = try encode_account(self.allocator, account);
            defer self.allocator.free(encoded_account);

            // Insert into trie
            builder.insert(&key_hash, encoded_account) catch |err| {
                log.debug("Failed to insert account into trie: {any}", .{err});
                return Error.DatabaseCorrupted;
            };
        }

        // Get the root hash
        if (builder.get_root_hash()) |root| {
            return root;
        } else {
            // Empty trie after insertions - shouldn't happen but handle gracefully
            return EMPTY_TRIE_ROOT;
        }
    }

    /// Commit pending changes and return new state root
    pub fn commit_changes(self: *Database) Error![32]u8 {
        return self.get_state_root();
    }

    /// Clear transient storage (called at transaction end per EIP-1153)
    /// Uses clearRetainingCapacity to avoid memory churn between transactions
    pub fn clear_transient_storage(self: *Database) void {
        self.transient_storage.clearRetainingCapacity();
    }

    // Snapshot operations

    /// Create a state snapshot and return its ID (legacy tests support)
    pub fn create_snapshot(self: *Database) Error!u64 {
        const snapshot_id = self.next_snapshot_id;
        self.next_snapshot_id += 1;
        var snapshot_accounts = std.HashMap([20]u8, Account, ArrayHashContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        var accounts_iter = self.accounts.iterator();
        while (accounts_iter.next()) |entry| try snapshot_accounts.put(entry.key_ptr.*, entry.value_ptr.*);
        var snapshot_storage = std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        var storage_iter = self.storage.iterator();
        while (storage_iter.next()) |entry| try snapshot_storage.put(entry.key_ptr.*, entry.value_ptr.*);
        try self.snapshots.append(self.allocator, Snapshot{ .id = snapshot_id, .accounts = snapshot_accounts, .storage = snapshot_storage });
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
        while (accounts_iter.next()) |entry| try self.accounts.put(entry.key_ptr.*, entry.value_ptr.*);
        var storage_iter = snapshot.storage.iterator();
        while (storage_iter.next()) |entry| try self.storage.put(entry.key_ptr.*, entry.value_ptr.*);
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

        // Free just this snapshot's memory
        self.snapshots.items[index].accounts.deinit();
        self.snapshots.items[index].storage.deinit();

        // Remove this snapshot from the list, keeping all others
        _ = self.snapshots.orderedRemove(index);
    }

    // EIP-7702 Delegation operations

    /// Set delegation for an EOA to execute another address's code
    pub fn set_delegation(self: *Database, eoa_address: [20]u8, delegated_address: [20]u8) Error!void {

        // Get or create the EOA account
        var account = (try self.get_account(eoa_address)) orelse Account.zero();

        // Only EOAs can have delegations (no existing code)
        if (!std.mem.eql(u8, &account.code_hash, &ZERO_CODE_HASH)) {
            log.debug("set_delegation: Address {x} is a contract, cannot set delegation", .{eoa_address});
            return Error.InvalidAddress;
        }

        // Convert to Address type for the delegation
        const delegate_addr = primitives.Address.Address{ .bytes = delegated_address };

        account.set_delegation(delegate_addr);
        try self.set_account(eoa_address, account);

        log.debug("set_delegation: Set delegation for EOA {x} to {x}", .{ eoa_address, delegated_address });
    }

    /// Clear delegation for an EOA
    pub fn clear_delegation(self: *Database, eoa_address: [20]u8) Error!void {
        if (try self.get_account(eoa_address)) |account| {
            var mutable_account = account;
            mutable_account.clear_delegation();
            try self.set_account(eoa_address, mutable_account);
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

    // Transaction operations (simple implementation using snapshots)

    /// Begin a transaction and return a transaction ID
    /// Transactions use the snapshot mechanism for state isolation
    pub fn begin_transaction(self: *Database) Error!u32 {
        const snapshot_id = try self.create_snapshot();
        return @intCast(snapshot_id);
    }

    /// Commit a transaction by discarding its snapshot
    pub fn commit_transaction(self: *Database, id: u32) Error!void {
        try self.commit_snapshot(@intCast(id));
    }

    /// Rollback a transaction by reverting to its snapshot
    pub fn rollback_transaction(self: *Database, id: u32) Error!void {
        try self.revert_to_snapshot(@intCast(id));
    }
};

// Compile-time validation helper
/// Validates that a type can be used as a database implementation
///
/// This function checks that all required interface methods are present at compile time.
/// Use this to ensure your custom database implementation is complete.
pub fn validate_database_implementation(comptime T: type) void {
    // Account operations
    if (!@hasDecl(T, "get_account")) @compileError("Database implementation missing get_account method");
    if (!@hasDecl(T, "set_account")) @compileError("Database implementation missing set_account method");
    if (!@hasDecl(T, "delete_account")) @compileError("Database implementation missing delete_account method");
    if (!@hasDecl(T, "account_exists")) @compileError("Database implementation missing account_exists method");

    // Balance and nonce operations
    if (!@hasDecl(T, "get_balance")) @compileError("Database implementation missing get_balance method");
    if (!@hasDecl(T, "set_balance")) @compileError("Database implementation missing set_balance method");
    if (!@hasDecl(T, "get_nonce")) @compileError("Database implementation missing get_nonce method");
    if (!@hasDecl(T, "set_nonce")) @compileError("Database implementation missing set_nonce method");

    // Code operations
    if (!@hasDecl(T, "get_code")) @compileError("Database implementation missing get_code method");
    if (!@hasDecl(T, "get_code_by_address")) @compileError("Database implementation missing get_code_by_address method");
    if (!@hasDecl(T, "set_code")) @compileError("Database implementation missing set_code method");
    if (!@hasDecl(T, "get_code_hash")) @compileError("Database implementation missing get_code_hash method");

    // Storage operations
    if (!@hasDecl(T, "get_storage")) @compileError("Database implementation missing get_storage method");
    if (!@hasDecl(T, "set_storage")) @compileError("Database implementation missing set_storage method");
    if (!@hasDecl(T, "get_transient_storage")) @compileError("Database implementation missing get_transient_storage method");
    if (!@hasDecl(T, "set_transient_storage")) @compileError("Database implementation missing set_transient_storage method");

    // State operations
    if (!@hasDecl(T, "get_state_root")) @compileError("Database implementation missing get_state_root method");
    if (!@hasDecl(T, "commit_changes")) @compileError("Database implementation missing commit_changes method");
    if (!@hasDecl(T, "is_empty")) @compileError("Database implementation missing is_empty method");

    // Snapshot operations
    if (!@hasDecl(T, "create_snapshot")) @compileError("Database implementation missing create_snapshot method");
    if (!@hasDecl(T, "revert_to_snapshot")) @compileError("Database implementation missing revert_to_snapshot method");
    if (!@hasDecl(T, "commit_snapshot")) @compileError("Database implementation missing commit_snapshot method");

    // Batch operations
    if (!@hasDecl(T, "begin_batch")) @compileError("Database implementation missing begin_batch method");
    if (!@hasDecl(T, "commit_batch")) @compileError("Database implementation missing commit_batch method");
    if (!@hasDecl(T, "rollback_batch")) @compileError("Database implementation missing rollback_batch method");

    // Transaction operations
    if (!@hasDecl(T, "begin_transaction")) @compileError("Database implementation missing begin_transaction method");
    if (!@hasDecl(T, "commit_transaction")) @compileError("Database implementation missing commit_transaction method");
    if (!@hasDecl(T, "rollback_transaction")) @compileError("Database implementation missing rollback_transaction method");

    // Cleanup
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
    const test_bytes = try allocator.alloc(u8, test_code.len / 2);
    defer allocator.free(test_bytes);
    _ = try std.fmt.hexToBytes(test_bytes, test_code);

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

test "Database state root operations - empty state" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    // Empty state should return known empty trie hash
    const EMPTY_TRIE_ROOT = [_]u8{
        0x56, 0xe8, 0x1f, 0x17, 0x1b, 0xcc, 0x55, 0xa6,
        0xff, 0x83, 0x45, 0xe6, 0x92, 0xc0, 0xf8, 0x6e,
        0x5b, 0x48, 0xe0, 0x1b, 0x99, 0x6c, 0xad, 0xc0,
        0x01, 0x62, 0x2f, 0xb5, 0xe3, 0x63, 0xb4, 0x21,
    };

    const root1 = try db.get_state_root();
    try testing.expectEqualSlices(u8, &EMPTY_TRIE_ROOT, &root1);

    // Commit changes (should return same empty trie hash)
    const root2 = try db.commit_changes();
    try testing.expectEqualSlices(u8, &EMPTY_TRIE_ROOT, &root2);
}

test "Database state root operations - single account" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    // Add one account
    const addr = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const account = Account{
        .balance = 100,
        .nonce = 1,
        .code_hash = [_]u8{0xAA} ** 32,
        .storage_root = [_]u8{0xBB} ** 32,
    };
    try db.set_account(addr, account);

    // State root should be deterministic and non-empty
    const root = try db.get_state_root();
    const EMPTY_TRIE_ROOT = [_]u8{
        0x56, 0xe8, 0x1f, 0x17, 0x1b, 0xcc, 0x55, 0xa6,
        0xff, 0x83, 0x45, 0xe6, 0x92, 0xc0, 0xf8, 0x6e,
        0x5b, 0x48, 0xe0, 0x1b, 0x99, 0x6c, 0xad, 0xc0,
        0x01, 0x62, 0x2f, 0xb5, 0xe3, 0x63, 0xb4, 0x21,
    };
    try testing.expect(!std.mem.eql(u8, &root, &EMPTY_TRIE_ROOT));
}

test "Database state root operations - multiple accounts" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    // Add multiple accounts
    const addr1 = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const addr2 = [_]u8{0x02} ++ [_]u8{0} ** 19;
    const addr3 = [_]u8{0x03} ++ [_]u8{0} ** 19;

    const account1 = Account{ .balance = 100, .nonce = 1, .code_hash = [_]u8{0xAA} ** 32, .storage_root = [_]u8{0xBB} ** 32 };
    const account2 = Account{ .balance = 200, .nonce = 2, .code_hash = [_]u8{0xCC} ** 32, .storage_root = [_]u8{0xDD} ** 32 };
    const account3 = Account{ .balance = 300, .nonce = 3, .code_hash = [_]u8{0xEE} ** 32, .storage_root = [_]u8{0xFF} ** 32 };

    try db.set_account(addr1, account1);
    try db.set_account(addr2, account2);
    try db.set_account(addr3, account3);

    // State root should be deterministic
    const root1 = try db.get_state_root();
    const root2 = try db.get_state_root();
    try testing.expectEqualSlices(u8, &root1, &root2);
}

test "Database state root operations - deterministic" {
    const allocator = testing.allocator;
    var db1 = Database.init(allocator);
    defer db1.deinit();
    var db2 = Database.init(allocator);
    defer db2.deinit();

    // Add same accounts in different order
    const addr1 = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const addr2 = [_]u8{0x02} ++ [_]u8{0} ** 19;
    const account1 = Account{ .balance = 100, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    const account2 = Account{ .balance = 200, .nonce = 2, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };

    // DB1: Insert addr1, then addr2
    try db1.set_account(addr1, account1);
    try db1.set_account(addr2, account2);

    // DB2: Insert addr2, then addr1
    try db2.set_account(addr2, account2);
    try db2.set_account(addr1, account1);

    // State roots should be identical (deterministic)
    const root1 = try db1.get_state_root();
    const root2 = try db2.get_state_root();
    try testing.expectEqualSlices(u8, &root1, &root2);
}

test "Database state root operations - state changes" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const account1 = Account{ .balance = 100, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };

    // Initial state
    try db.set_account(addr, account1);
    const root1 = try db.get_state_root();

    // Modify account
    const account2 = Account{ .balance = 200, .nonce = 2, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    try db.set_account(addr, account2);
    const root2 = try db.get_state_root();

    // State root should change
    try testing.expect(!std.mem.eql(u8, &root1, &root2));

    // Revert to original account
    try db.set_account(addr, account1);
    const root3 = try db.get_state_root();

    // State root should match original
    try testing.expectEqualSlices(u8, &root1, &root3);
}

test "Database state root - account with storage" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const storage_root1 = [_]u8{0x11} ** 32;
    const storage_root2 = [_]u8{0x22} ** 32;

    const account1 = Account{ .balance = 100, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = storage_root1 };
    try db.set_account(addr, account1);
    const root1 = try db.get_state_root();

    // Change storage root
    const account2 = Account{ .balance = 100, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = storage_root2 };
    try db.set_account(addr, account2);
    const root2 = try db.get_state_root();

    // State root should change when storage root changes
    try testing.expect(!std.mem.eql(u8, &root1, &root2));
}

test "Database state root - balance changes" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x01} ++ [_]u8{0} ** 19;

    // Zero balance
    const account1 = Account{ .balance = 0, .nonce = 0, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    try db.set_account(addr, account1);
    const root1 = try db.get_state_root();

    // Small balance
    const account2 = Account{ .balance = 1, .nonce = 0, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    try db.set_account(addr, account2);
    const root2 = try db.get_state_root();

    // Large balance
    const account3 = Account{ .balance = std.math.maxInt(u256), .nonce = 0, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    try db.set_account(addr, account3);
    const root3 = try db.get_state_root();

    // All roots should be different
    try testing.expect(!std.mem.eql(u8, &root1, &root2));
    try testing.expect(!std.mem.eql(u8, &root1, &root3));
    try testing.expect(!std.mem.eql(u8, &root2, &root3));
}

test "Database state root - nonce changes" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x01} ++ [_]u8{0} ** 19;

    // Nonce 0
    const account1 = Account{ .balance = 100, .nonce = 0, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    try db.set_account(addr, account1);
    const root1 = try db.get_state_root();

    // Nonce 1
    const account2 = Account{ .balance = 100, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    try db.set_account(addr, account2);
    const root2 = try db.get_state_root();

    // Nonce max
    const account3 = Account{ .balance = 100, .nonce = std.math.maxInt(u64), .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    try db.set_account(addr, account3);
    const root3 = try db.get_state_root();

    // All roots should be different
    try testing.expect(!std.mem.eql(u8, &root1, &root2));
    try testing.expect(!std.mem.eql(u8, &root1, &root3));
    try testing.expect(!std.mem.eql(u8, &root2, &root3));
}

test "Database state root - code hash changes" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x01} ++ [_]u8{0} ** 19;

    // Empty code hash
    const account1 = Account{ .balance = 100, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    try db.set_account(addr, account1);
    const root1 = try db.get_state_root();

    // Code hash 1
    const account2 = Account{ .balance = 100, .nonce = 1, .code_hash = [_]u8{0xAA} ** 32, .storage_root = [_]u8{0} ** 32 };
    try db.set_account(addr, account2);
    const root2 = try db.get_state_root();

    // Code hash 2
    const account3 = Account{ .balance = 100, .nonce = 1, .code_hash = [_]u8{0xBB} ** 32, .storage_root = [_]u8{0} ** 32 };
    try db.set_account(addr, account3);
    const root3 = try db.get_state_root();

    // All roots should be different
    try testing.expect(!std.mem.eql(u8, &root1, &root2));
    try testing.expect(!std.mem.eql(u8, &root1, &root3));
    try testing.expect(!std.mem.eql(u8, &root2, &root3));
}

test "Database state root - account deletion" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const account = Account{ .balance = 100, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };

    // Initial empty state
    const EMPTY_TRIE_ROOT = [_]u8{
        0x56, 0xe8, 0x1f, 0x17, 0x1b, 0xcc, 0x55, 0xa6,
        0xff, 0x83, 0x45, 0xe6, 0x92, 0xc0, 0xf8, 0x6e,
        0x5b, 0x48, 0xe0, 0x1b, 0x99, 0x6c, 0xad, 0xc0,
        0x01, 0x62, 0x2f, 0xb5, 0xe3, 0x63, 0xb4, 0x21,
    };
    const empty_root = try db.get_state_root();
    try testing.expectEqualSlices(u8, &EMPTY_TRIE_ROOT, &empty_root);

    // Add account
    try db.set_account(addr, account);
    const root_with_account = try db.get_state_root();
    try testing.expect(!std.mem.eql(u8, &empty_root, &root_with_account));

    // Delete account
    try db.delete_account(addr);
    const root_after_delete = try db.get_state_root();

    // Should return to empty state root
    try testing.expectEqualSlices(u8, &EMPTY_TRIE_ROOT, &root_after_delete);
}

test "Database state root - large number of accounts" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    // Add 100 accounts
    for (0..100) |i| {
        var addr: [20]u8 = [_]u8{0} ** 20;
        addr[19] = @intCast(i & 0xFF);
        const account = Account{
            .balance = @intCast(i * 1000),
            .nonce = @intCast(i),
            .code_hash = [_]u8{0} ** 32,
            .storage_root = [_]u8{0} ** 32,
        };
        try db.set_account(addr, account);
    }

    // Calculate state root
    const root = try db.get_state_root();

    // Should be deterministic
    const root2 = try db.get_state_root();
    try testing.expectEqualSlices(u8, &root, &root2);

    // Should not be empty
    const EMPTY_TRIE_ROOT = [_]u8{
        0x56, 0xe8, 0x1f, 0x17, 0x1b, 0xcc, 0x55, 0xa6,
        0xff, 0x83, 0x45, 0xe6, 0x92, 0xc0, 0xf8, 0x6e,
        0x5b, 0x48, 0xe0, 0x1b, 0x99, 0x6c, 0xad, 0xc0,
        0x01, 0x62, 0x2f, 0xb5, 0xe3, 0x63, 0xb4, 0x21,
    };
    try testing.expect(!std.mem.eql(u8, &root, &EMPTY_TRIE_ROOT));
}

test "Database state root - commit_changes" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const account = Account{ .balance = 100, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };

    try db.set_account(addr, account);

    // commit_changes should return same root as get_state_root
    const root1 = try db.get_state_root();
    const root2 = try db.commit_changes();
    try testing.expectEqualSlices(u8, &root1, &root2);
}

test "Database state root - address collision" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    // Two accounts with similar addresses
    const addr1 = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const addr2 = [_]u8{0x02} ++ [_]u8{0} ** 19;

    const account = Account{ .balance = 100, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };

    // Add both accounts
    try db.set_account(addr1, account);
    try db.set_account(addr2, account);

    const root = try db.get_state_root();

    // Remove one account
    try db.delete_account(addr2);
    const root_after = try db.get_state_root();

    // Roots should be different
    try testing.expect(!std.mem.eql(u8, &root, &root_after));
}

test "Database state root - zero values" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x01} ++ [_]u8{0} ** 19;

    // Account with all zero values
    const account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };

    try db.set_account(addr, account);
    const root = try db.get_state_root();

    // Should still compute a valid root (not empty trie root)
    const EMPTY_TRIE_ROOT = [_]u8{
        0x56, 0xe8, 0x1f, 0x17, 0x1b, 0xcc, 0x55, 0xa6,
        0xff, 0x83, 0x45, 0xe6, 0x92, 0xc0, 0xf8, 0x6e,
        0x5b, 0x48, 0xe0, 0x1b, 0x99, 0x6c, 0xad, 0xc0,
        0x01, 0x62, 0x2f, 0xb5, 0xe3, 0x63, 0xb4, 0x21,
    };
    try testing.expect(!std.mem.eql(u8, &root, &EMPTY_TRIE_ROOT));
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
    const large_key: u256 = 0x123456789ABCDEF123456789ABCDEF123456789ABCDEF123456789ABCDEF1234;

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
        addr[16] = @intCast(std.math.shr(usize, i, 24) & 0xFF);
        addr[17] = @intCast(std.math.shr(usize, i, 16) & 0xFF);
        addr[18] = @intCast(std.math.shr(usize, i, 8) & 0xFF);
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
        addr[16] = @intCast(std.math.shr(usize, i, 24) & 0xFF);
        addr[17] = @intCast(std.math.shr(usize, i, 16) & 0xFF);
        addr[18] = @intCast(std.math.shr(usize, i, 8) & 0xFF);
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

// =============================================================================
// Tests for New Interface Methods
// =============================================================================

test "Database get_balance and set_balance" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0xAA} ++ [_]u8{0} ** 19;

    // Initially zero balance
    try testing.expectEqual(@as(u256, 0), try db.get_balance(addr));

    // Set balance on non-existent account (should create account)
    try db.set_balance(addr, 1000);
    try testing.expectEqual(@as(u256, 1000), try db.get_balance(addr));

    // Update balance
    try db.set_balance(addr, 2000);
    try testing.expectEqual(@as(u256, 2000), try db.get_balance(addr));

    // Set balance to zero
    try db.set_balance(addr, 0);
    try testing.expectEqual(@as(u256, 0), try db.get_balance(addr));
}

test "Database get_nonce and set_nonce" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0xBB} ++ [_]u8{0} ** 19;

    // Initially zero nonce
    try testing.expectEqual(@as(u64, 0), try db.get_nonce(addr));

    // Set nonce on non-existent account (should create account)
    try db.set_nonce(addr, 5);
    try testing.expectEqual(@as(u64, 5), try db.get_nonce(addr));

    // Update nonce
    try db.set_nonce(addr, 10);
    try testing.expectEqual(@as(u64, 10), try db.get_nonce(addr));

    // Set nonce to max value
    try db.set_nonce(addr, std.math.maxInt(u64));
    try testing.expectEqual(std.math.maxInt(u64), try db.get_nonce(addr));
}

test "Database get_code_hash" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0xCC} ++ [_]u8{0} ** 19;

    // Non-existent account returns zero code hash
    const zero_hash = try db.get_code_hash(addr);
    try testing.expectEqualSlices(u8, &ZERO_CODE_HASH, &zero_hash);

    // Create account with code
    const test_code = [_]u8{ 0x60, 0x01, 0x60, 0x02 };
    const code_hash = try db.set_code(&test_code);
    const account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(addr, account);

    // Get code hash should return the account's code hash
    const retrieved_hash = try db.get_code_hash(addr);
    try testing.expectEqualSlices(u8, &code_hash, &retrieved_hash);
}

test "Database is_empty" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0xDD} ++ [_]u8{0} ** 19;

    // Non-existent account is considered empty
    try testing.expect(try db.is_empty(addr));

    // Account with zero balance but non-zero nonce is not empty
    try db.set_nonce(addr, 1);
    try testing.expect(!(try db.is_empty(addr)));

    // Reset to zero nonce
    var account = (try db.get_account(addr)).?;
    account.nonce = 0;
    try db.set_account(addr, account);
    try testing.expect(try db.is_empty(addr));

    // Account with balance is not empty
    try db.set_balance(addr, 100);
    try testing.expect(!(try db.is_empty(addr)));

    // Reset to zero balance
    try db.set_balance(addr, 0);
    try testing.expect(try db.is_empty(addr));

    // Account with code is not empty
    const code_hash = try db.set_code(&[_]u8{0x60});
    account = (try db.get_account(addr)).?;
    account.code_hash = code_hash;
    try db.set_account(addr, account);
    try testing.expect(!(try db.is_empty(addr)));
}

test "Database transaction management - begin and commit" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0xEE} ++ [_]u8{0} ** 19;

    // Set initial state
    try db.set_balance(addr, 100);

    // Begin transaction
    const tx_id = try db.begin_transaction();

    // Make changes within transaction
    try db.set_balance(addr, 200);
    try testing.expectEqual(@as(u256, 200), try db.get_balance(addr));

    // Commit transaction
    try db.commit_transaction(tx_id);

    // Changes should persist
    try testing.expectEqual(@as(u256, 200), try db.get_balance(addr));
}

test "Database transaction management - begin and rollback" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0xFF} ++ [_]u8{0} ** 19;

    // Set initial state
    try db.set_balance(addr, 100);

    // Begin transaction
    const tx_id = try db.begin_transaction();

    // Make changes within transaction
    try db.set_balance(addr, 200);
    try testing.expectEqual(@as(u256, 200), try db.get_balance(addr));

    // Rollback transaction
    try db.rollback_transaction(tx_id);

    // Changes should be reverted
    try testing.expectEqual(@as(u256, 100), try db.get_balance(addr));
}

test "Database transaction management - nested transactions" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x11} ++ [_]u8{0} ** 19;

    // Initial state
    try db.set_balance(addr, 100);

    // First transaction
    const tx1 = try db.begin_transaction();
    try db.set_balance(addr, 200);

    // Second transaction (nested)
    const tx2 = try db.begin_transaction();
    try db.set_balance(addr, 300);

    // Rollback inner transaction
    try db.rollback_transaction(tx2);
    try testing.expectEqual(@as(u256, 200), try db.get_balance(addr));

    // Commit outer transaction
    try db.commit_transaction(tx1);
    try testing.expectEqual(@as(u256, 200), try db.get_balance(addr));
}

test "Database set_balance preserves other account fields" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x22} ++ [_]u8{0} ** 19;

    // Create account with nonce and code
    const code_hash = try db.set_code(&[_]u8{ 0x60, 0x01 });
    const account = Account{
        .balance = 1000,
        .nonce = 5,
        .code_hash = code_hash,
        .storage_root = [_]u8{0xAB} ** 32,
    };
    try db.set_account(addr, account);

    // Set balance
    try db.set_balance(addr, 2000);

    // Verify other fields are preserved
    const retrieved = (try db.get_account(addr)).?;
    try testing.expectEqual(@as(u256, 2000), retrieved.balance);
    try testing.expectEqual(@as(u64, 5), retrieved.nonce);
    try testing.expectEqualSlices(u8, &code_hash, &retrieved.code_hash);
    try testing.expectEqualSlices(u8, &([_]u8{0xAB} ** 32), &retrieved.storage_root);
}

test "Database set_nonce preserves other account fields" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x33} ++ [_]u8{0} ** 19;

    // Create account with balance and code
    const code_hash = try db.set_code(&[_]u8{ 0x60, 0x02 });
    const account = Account{
        .balance = 1000,
        .nonce = 5,
        .code_hash = code_hash,
        .storage_root = [_]u8{0xCD} ** 32,
    };
    try db.set_account(addr, account);

    // Set nonce
    try db.set_nonce(addr, 10);

    // Verify other fields are preserved
    const retrieved = (try db.get_account(addr)).?;
    try testing.expectEqual(@as(u256, 1000), retrieved.balance);
    try testing.expectEqual(@as(u64, 10), retrieved.nonce);
    try testing.expectEqualSlices(u8, &code_hash, &retrieved.code_hash);
    try testing.expectEqualSlices(u8, &([_]u8{0xCD} ** 32), &retrieved.storage_root);
}

test "Database get_balance with overlay" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x44} ++ [_]u8{0} ** 19;

    // Set base balance
    try db.set_balance(addr, 100);

    // Begin ephemeral view
    db.begin_ephemeral_view();

    // Set balance in overlay
    try db.set_balance(addr, 200);
    try testing.expectEqual(@as(u256, 200), try db.get_balance(addr));

    // Discard ephemeral view
    db.discard_ephemeral_view();

    // Should revert to base balance
    try testing.expectEqual(@as(u256, 100), try db.get_balance(addr));
}

test "Database get_nonce with overlay" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x55} ++ [_]u8{0} ** 19;

    // Set base nonce
    try db.set_nonce(addr, 5);

    // Begin ephemeral view
    db.begin_ephemeral_view();

    // Set nonce in overlay
    try db.set_nonce(addr, 10);
    try testing.expectEqual(@as(u64, 10), try db.get_nonce(addr));

    // Discard ephemeral view
    db.discard_ephemeral_view();

    // Should revert to base nonce
    try testing.expectEqual(@as(u64, 5), try db.get_nonce(addr));
}

test "Database is_empty after deletion" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x66} ++ [_]u8{0} ** 19;

    // Create non-empty account
    try db.set_balance(addr, 1000);
    try testing.expect(!(try db.is_empty(addr)));

    // Delete account
    try db.delete_account(addr);

    // Should now be empty (non-existent)
    try testing.expect(try db.is_empty(addr));
}

test "Database transaction with storage operations" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x77} ++ [_]u8{0} ** 19;
    const key: u256 = 42;

    // Set initial storage
    try db.set_storage(addr, key, 100);

    // Begin transaction
    const tx_id = try db.begin_transaction();

    // Modify storage
    try db.set_storage(addr, key, 200);
    try testing.expectEqual(@as(u256, 200), try db.get_storage(addr, key));

    // Rollback transaction
    try db.rollback_transaction(tx_id);

    // Storage should be reverted
    try testing.expectEqual(@as(u256, 100), try db.get_storage(addr, key));
}

test "Database get_code_hash with zero code" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x88} ++ [_]u8{0} ** 19;

    // Create account with explicit zero code hash
    const account = Account{
        .balance = 100,
        .nonce = 1,
        .code_hash = ZERO_CODE_HASH,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(addr, account);

    // Get code hash should return zero hash
    const hash = try db.get_code_hash(addr);
    try testing.expectEqualSlices(u8, &ZERO_CODE_HASH, &hash);
}

test "Database transaction error handling - invalid snapshot" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    // Try to commit non-existent transaction
    try testing.expectError(Database.Error.SnapshotNotFound, db.commit_transaction(999));

    // Try to rollback non-existent transaction
    try testing.expectError(Database.Error.SnapshotNotFound, db.rollback_transaction(999));
}
