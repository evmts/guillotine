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
//! - **Snapshots**: O(1) checkpoints backed by an undo log
//! - **Transactions**: Begin/commit/rollback with snapshot-based isolation
//! - **EIP-7702 Support**: EOA delegation for code execution
//! - **Ephemeral Views**: overlay for simulate() that never touches base state
//!
//! ## Snapshots and the undo log
//!
//! `create_snapshot` records the current length of the undo log and costs O(1).
//! While at least one snapshot is open, every write appends the value it replaces
//! to the undo log before it mutates a map. `revert_to_snapshot` pops entries back
//! to the recorded length and restores each previous value, so its cost is the
//! number of writes being undone, independent of the size of the state.
//!
//! The undo log covers every layer a write can land in: base state and the
//! ephemeral overlay (accounts, deletions, persistent storage, transient storage
//! and code).
//!
//! Rollback never allocates and cannot fail once a snapshot exists. All fallible
//! work (growing the undo log and the target map) happens when the write is
//! recorded. Restoring a value writes through an existing entry, removes an entry,
//! or re-inserts a key that the undone write removed. Re-insertion uses the slot
//! the removal freed: map capacity never shrinks while a snapshot is open and
//! entries are undone in LIFO order, so the map holds no more entries at that
//! point than it did immediately after the removal.
//!
//! ## Per-account storage
//!
//! Base and overlay storage are `SlotStore`s (`slot_store.zig`): a slot map plus
//! a per-address index of the keys it holds. `clear_account_storage`,
//! `delete_account` and `has_storage` (EIP-7610) use the index, so they cost
//! O(slots of the account) in every layer. Storage must be written through
//! `set_storage`, which keeps the index and the per-address count of non-zero
//! base slots (`storage_slot_counts`) exact.
//!
//! ## EIP-7702 delegation designators
//!
//! A delegated EOA is stored as an account with `delegated_address` set and no
//! code hash. `set_code` recognizes a designator (`0xef0100 || address`, 23
//! bytes) and `set_account` normalizes an account whose code hash names one to
//! that form, so a host that loads raw designator code gets the same account as
//! `set_delegation`.
//!
//! ## Memory Management
//!
//! All allocated memory is tracked and properly freed on deinit:
//! - Code buffers are owned by the database
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
const primitives = @import("voltaire");
pub const Account = @import("database_interface_account.zig").Account;

/// All-zero code hash for EOA detection
const ZERO_CODE_HASH = @as([32]u8, @splat(0));

/// Root of an empty trie: keccak256(RLP("")) = keccak256(0x80).
const EMPTY_STORAGE_ROOT = [_]u8{
    0x56, 0xe8, 0x1f, 0x17, 0x1b, 0xcc, 0x55, 0xa6,
    0xff, 0x83, 0x45, 0xe6, 0x92, 0xc0, 0xf8, 0x6e,
    0x5b, 0x48, 0xe0, 0x1b, 0x99, 0x6c, 0xad, 0xc0,
    0x01, 0x62, 0x2f, 0xb5, 0xe3, 0x63, 0xb4, 0x21,
};

const slot_store = @import("slot_store.zig");
const SlotKey = slot_store.SlotKey;
pub const SlotStore = slot_store.SlotStore;

/// EIP-7702 delegation designator: `0xef0100 || address`.
const DELEGATION_PREFIX = [_]u8{ 0xef, 0x01, 0x00 };
const DELEGATION_DESIGNATOR_LENGTH = DELEGATION_PREFIX.len + 20;

/// The delegate a designator names, or null when `code` is not a designator.
fn delegationTarget(code: []const u8) ?[20]u8 {
    if (code.len != DELEGATION_DESIGNATOR_LENGTH) return null;
    if (!std.mem.startsWith(u8, code, &DELEGATION_PREFIX)) return null;
    return code[DELEGATION_PREFIX.len..][0..20].*;
}

/// High-performance in-memory database for EVM state
pub const Database = struct {
    accounts: std.HashMap([20]u8, Account, ArrayHashContext, std.hash_map.default_max_load_percentage),
    /// Persistent storage with its per-address index. Write it through `set_storage`.
    storage: SlotStore,
    transient_storage: std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage),
    code_storage: std.HashMap([32]u8, []const u8, ArrayHashContext, std.hash_map.default_max_load_percentage),
    /// Open snapshots, oldest first. Each one is a position in `undo_log`.
    snapshots: std.ArrayList(Snapshot),
    /// Previous values of every write made while a snapshot is open, oldest first.
    undo_log: std.ArrayList(UndoEntry),
    /// Number of non-zero slots each address holds in base `storage` (EIP-7610).
    /// An address keeps its entry once it has one, so undo never has to insert.
    storage_slot_counts: std.HashMap([20]u8, usize, ArrayHashContext, std.hash_map.default_max_load_percentage),
    /// Delegate of every designator `set_code` has seen, by code hash. The mapping
    /// is a property of the code's content, so entries are never undone or removed.
    delegation_targets: std.HashMap([32]u8, [20]u8, ArrayHashContext, std.hash_map.default_max_load_percentage),
    next_snapshot_id: u64,
    allocator: std.mem.Allocator,
    // Ephemeral overlay state (active only during simulate)
    overlay_active: bool = false,
    /// Overlay accounts. A null value is a tombstone: the account is deleted in the view.
    overlay_accounts: std.HashMap([20]u8, ?Account, ArrayHashContext, std.hash_map.default_max_load_percentage),
    /// First allocation failure of a write or snapshot since the field was last
    /// cleared. Callers that turn a failed write into something else (an EVM frame
    /// halts on a failed SSTORE) cannot lose it: whoever runs the transaction reads
    /// this field and aborts. The host clears it; `Evm.call` does at its start.
    failure: ?Error = null,
    /// Overlay storage. A zero value hides a non-zero base slot.
    overlay_storage: SlotStore,
    overlay_transient: std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage),
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

    const StorageKey = SlotKey;

    /// An open snapshot: its ID and the undo log length when it was created.
    const Snapshot = struct {
        id: u64,
        undo_len: usize,
    };

    /// The map a write landed in.
    const Layer = enum(u1) { base, overlay };

    /// What a layer held for an account before a write.
    const PreviousAccount = union(enum) {
        /// The layer had no entry for the address.
        absent,
        /// The layer held a deletion tombstone (overlay only).
        deleted,
        /// The layer held this account.
        present: Account,
    };

    /// One undone-able write. `noop` replaces entries whose layer was discarded.
    const UndoEntry = union(enum) {
        account: struct { layer: Layer, address: [20]u8, previous: PreviousAccount },
        storage: struct { layer: Layer, key: StorageKey, previous: ?u256 },
        transient: struct { layer: Layer, key: StorageKey, previous: ?u256 },
        /// Code inserted under `hash`. Code is content-addressed, so undo removes it.
        code: struct { layer: Layer, hash: [32]u8 },
        noop,
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
            .storage = SlotStore.init(allocator),
            .transient_storage = std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .code_storage = std.HashMap([32]u8, []const u8, ArrayHashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .snapshots = .empty,
            .undo_log = .empty,
            .storage_slot_counts = std.HashMap([20]u8, usize, ArrayHashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .delegation_targets = std.HashMap([32]u8, [20]u8, ArrayHashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .next_snapshot_id = 1,
            .allocator = allocator,
            .overlay_active = false,
            .overlay_accounts = std.HashMap([20]u8, ?Account, ArrayHashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .overlay_storage = SlotStore.init(allocator),
            .overlay_transient = std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .overlay_code = std.HashMap([32]u8, []const u8, ArrayHashContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    /// Free all allocated code slices in a code storage HashMap.
    ///
    /// Safety: Zig's HashMap iterator is stable during iteration because we're only
    /// freeing the memory that the value *points to* (the code slice), not modifying
    /// the HashMap entry itself. The HashMap structure remains unchanged.
    fn freeAllCodeInMap(self: *Database, code_map: *std.HashMap([32]u8, []const u8, ArrayHashContext, std.hash_map.default_max_load_percentage)) void {
        var it = code_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
    }

    /// Drop everything the overlay holds and forget undo entries that point into it.
    fn clearOverlay(self: *Database) void {
        self.discardUndoEntriesFor(.overlay);
        self.overlay_accounts.clearRetainingCapacity();
        self.overlay_storage.clearRetainingCapacity();
        self.overlay_transient.clearRetainingCapacity();
        self.freeAllCodeInMap(&self.overlay_code);
        self.overlay_code.clearRetainingCapacity();
    }

    pub fn begin_ephemeral_view(self: *Database) void {
        if (self.overlay_active) return;
        self.clearOverlay();
        self.overlay_active = true;
    }

    pub fn discard_ephemeral_view(self: *Database) void {
        if (!self.overlay_active) return;
        self.overlay_active = false;
        self.clearOverlay();
    }

    /// Clean up database resources
    pub fn deinit(self: *Database) void {
        self.accounts.deinit();
        self.storage.deinit();
        self.transient_storage.deinit();
        self.storage_slot_counts.deinit();
        self.delegation_targets.deinit();

        // Free all allocated code before deinitializing the hashmap
        self.freeAllCodeInMap(&self.code_storage);
        self.code_storage.deinit();

        self.snapshots.deinit(self.allocator);
        self.undo_log.deinit(self.allocator);
        // Deinit overlay
        self.freeAllCodeInMap(&self.overlay_code);
        self.overlay_code.deinit();
        self.overlay_accounts.deinit();
        self.overlay_storage.deinit();
        self.overlay_transient.deinit();
    }

    /// Remember that a write or snapshot ran out of memory. See `failure`. Used by
    /// the functions whose only possible error is an allocation failure.
    fn noteAllocationFailure(self: *Database) void {
        if (self.failure == null) self.failure = Error.OutOfMemory;
    }

    // Undo log

    /// True while a snapshot is open, which is when writes must be recorded.
    inline fn recording(self: *const Database) bool {
        return self.snapshots.items.len != 0;
    }

    /// Make room for one undo entry, so that recording after the map write cannot fail.
    inline fn reserveUndo(self: *Database) Error!void {
        if (self.recording()) try self.undo_log.ensureUnusedCapacity(self.allocator, 1);
    }

    /// Record `entry` in space reserved by `reserveUndo`.
    inline fn recordUndo(self: *Database, entry: UndoEntry) void {
        if (self.recording()) self.undo_log.appendAssumeCapacity(entry);
    }

    /// Replace the undo entries of a discarded layer with no-ops.
    fn discardUndoEntriesFor(self: *Database, layer: Layer) void {
        for (self.undo_log.items) |*entry| {
            const entry_layer = switch (entry.*) {
                .account => |e| e.layer,
                .storage => |e| e.layer,
                .transient => |e| e.layer,
                .code => |e| e.layer,
                .noop => continue,
            };
            if (entry_layer == layer) entry.* = .noop;
        }
    }

    /// Write `value` into a tombstone-capable account map and record what it replaces.
    fn writeLayeredAccount(self: *Database, map: anytype, layer: Layer, address: [20]u8, value: ?Account) Error!void {
        try self.reserveUndo();
        const slot = try map.getOrPut(address);
        const previous: PreviousAccount = if (!slot.found_existing)
            .absent
        else if (slot.value_ptr.*) |account|
            .{ .present = account }
        else
            .deleted;
        self.recordUndo(.{ .account = .{ .layer = layer, .address = address, .previous = previous } });
        slot.value_ptr.* = value;
    }

    /// Write a slot into a storage layer and record what it replaces. A base
    /// write keeps the per-address non-zero count exact.
    fn writeSlot(self: *Database, store: *SlotStore, layer: Layer, key: StorageKey, value: u256) Error!void {
        try self.reserveUndo();
        // The count entry is created before the slot, so a failure here changes nothing.
        const count: ?*usize = switch (layer) {
            .base => count: {
                const entry = try self.storage_slot_counts.getOrPut(key.address);
                if (!entry.found_existing) entry.value_ptr.* = 0;
                break :count entry.value_ptr;
            },
            .overlay => null,
        };
        const previous = try store.put(key, value);
        self.recordUndo(.{ .storage = .{ .layer = layer, .key = key, .previous = previous } });
        if (count) |non_zero| adjustSlotCount(non_zero, previous orelse 0, value);
    }

    /// Update a non-zero slot count for one slot changing from `before` to `after`.
    fn adjustSlotCount(count: *usize, before: u256, after: u256) void {
        if (before == 0 and after != 0) count.* += 1;
        if (before != 0 and after == 0) count.* -= 1;
    }

    /// Write a transient slot and record what it replaces.
    fn writeTransientSlot(self: *Database, map: anytype, layer: Layer, key: StorageKey, value: u256) Error!void {
        try self.reserveUndo();
        const slot = try map.getOrPut(key);
        const previous: ?u256 = if (slot.found_existing) slot.value_ptr.* else null;
        self.recordUndo(.{ .transient = .{ .layer = layer, .key = key, .previous = previous } });
        slot.value_ptr.* = value;
    }

    /// Put back what `map` held for `key` before a write: overwrite the entry the
    /// write left, remove it, or re-insert into the slot a removal freed.
    fn restoreEntry(map: anytype, key: anytype, previous: anytype) void {
        const value = previous orelse {
            _ = map.remove(key);
            return;
        };
        if (map.getPtr(key)) |ptr| {
            ptr.* = value;
            return;
        }
        map.putAssumeCapacity(key, value);
    }

    /// Put back what a tombstone-capable account map held before a write.
    fn restoreLayeredAccount(map: anytype, address: [20]u8, previous: PreviousAccount) void {
        switch (previous) {
            .absent => _ = map.remove(address),
            .deleted => restoreEntry(map, address, @as(??Account, @as(?Account, null))),
            .present => |account| restoreEntry(map, address, @as(??Account, @as(?Account, account))),
        }
    }

    /// Undo one recorded write. Never allocates and cannot fail.
    fn applyUndo(self: *Database, entry: UndoEntry) void {
        switch (entry) {
            .noop => {},
            .account => |e| switch (e.layer) {
                .base => switch (e.previous) {
                    .absent, .deleted => _ = self.accounts.remove(e.address),
                    .present => |account| restoreEntry(&self.accounts, e.address, @as(?Account, account)),
                },
                .overlay => restoreLayeredAccount(&self.overlay_accounts, e.address, e.previous),
            },
            .storage => |e| switch (e.layer) {
                .base => {
                    const current = self.storage.get(e.key) orelse 0;
                    self.storage.restore(e.key, e.previous);
                    // The address got its count entry when the undone write ran.
                    if (self.storage_slot_counts.getPtr(e.key.address)) |count| {
                        adjustSlotCount(count, current, e.previous orelse 0);
                    }
                },
                .overlay => self.overlay_storage.restore(e.key, e.previous),
            },
            .transient => |e| switch (e.layer) {
                .base => restoreEntry(&self.transient_storage, e.key, e.previous),
                .overlay => restoreEntry(&self.overlay_transient, e.key, e.previous),
            },
            .code => |e| switch (e.layer) {
                .base => if (self.code_storage.fetchRemove(e.hash)) |removed| self.allocator.free(removed.value),
                .overlay => if (self.overlay_code.fetchRemove(e.hash)) |removed| self.allocator.free(removed.value),
            },
        }
    }

    // Account operations

    /// Get account data for the given address
    pub fn get_account(self: *Database, address: [20]u8) Error!?Account {
        return self.find_account(address);
    }

    /// The account a read sees at `address`, or null. An in-memory lookup that
    /// cannot fail; `get_account` is the same read behind the database interface.
    pub fn find_account(self: *Database, address: [20]u8) ?Account {
        // Check overlay first (simulate mode)
        if (self.overlay_active) {
            if (self.overlay_accounts.get(address)) |maybe_acc| {
                return maybe_acc; // null means deleted in the view
            }
        }
        return self.accounts.get(address);
    }

    /// The stored form of `account`. An account whose code hash names an EIP-7702
    /// designator becomes a delegated EOA (`delegated_address` set, no code hash);
    /// an account with any other code carries no delegation.
    fn normalizeDelegation(self: *const Database, account: Account) Account {
        if (!Account.is_code_hash_present(account.code_hash)) return account;
        var normalized = account;
        if (self.delegation_targets.get(account.code_hash)) |target| {
            normalized.code_hash = ZERO_CODE_HASH;
            normalized.delegated_address = .{ .bytes = target };
            return normalized;
        }
        normalized.delegated_address = null;
        return normalized;
    }

    /// Set account data for the given address. The account is stored in its
    /// normalized EIP-7702 form (see `normalizeDelegation`).
    pub fn set_account(self: *Database, address: [20]u8, value: Account) Error!void {
        errdefer self.noteAllocationFailure();
        const account = self.normalizeDelegation(value);
        if (self.overlay_active) {
            return self.writeLayeredAccount(&self.overlay_accounts, .overlay, address, account);
        }
        try self.reserveUndo();
        const slot = try self.accounts.getOrPut(address);
        self.recordUndo(.{ .account = .{
            .layer = .base,
            .address = address,
            .previous = if (slot.found_existing) .{ .present = slot.value_ptr.* } else .absent,
        } });
        slot.value_ptr.* = account;
    }

    /// Delete the account and its storage (execution-specs `destroy_account`).
    /// Costs O(slots of the account). Every write is recorded in the undo log, so
    /// an open snapshot restores the account and its storage on revert. Without an
    /// open snapshot, an allocation failure can leave part of the storage cleared.
    pub fn delete_account(self: *Database, address: [20]u8) Error!void {
        errdefer self.noteAllocationFailure();
        try self.clear_account_storage(address);
        if (self.overlay_active) {
            // A tombstone hides the base account for the lifetime of the view.
            return self.writeLayeredAccount(&self.overlay_accounts, .overlay, address, null);
        }
        const existing = self.accounts.get(address) orelse return;
        try self.reserveUndo();
        self.recordUndo(.{ .account = .{ .layer = .base, .address = address, .previous = .{ .present = existing } } });
        _ = self.accounts.remove(address);
    }

    /// Check if account exists in the database
    pub fn account_exists(self: *Database, address: [20]u8) bool {
        if (self.overlay_active) {
            if (self.overlay_accounts.get(address)) |maybe_acc| {
                return maybe_acc != null;
            }
        }
        return self.accounts.contains(address);
    }

    /// Get account balance
    pub fn get_balance(self: *Database, address: [20]u8) Error!u256 {
        const account = (try self.get_account(address)) orelse return 0;
        return account.balance;
    }

    /// Set account balance
    pub fn set_balance(self: *Database, address: [20]u8, balance: u256) Error!void {
        var account = (try self.get_account(address)) orelse Account.zero();
        account.balance = balance;
        try self.set_account(address, account);
    }

    /// Get account nonce
    pub fn get_nonce(self: *Database, address: [20]u8) Error!u64 {
        const account = (try self.get_account(address)) orelse return 0;
        return account.nonce;
    }

    /// Set account nonce
    pub fn set_nonce(self: *Database, address: [20]u8, nonce: u64) Error!void {
        var account = (try self.get_account(address)) orelse Account.zero();
        account.nonce = nonce;
        try self.set_account(address, account);
    }

    /// Get account code hash
    pub fn get_code_hash(self: *Database, address: [20]u8) Error![32]u8 {
        const account = (try self.get_account(address)) orelse return ZERO_CODE_HASH;
        return account.code_hash;
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
        return self.read_storage(address, key);
    }

    /// The value a read sees in a storage slot; zero when the slot was never
    /// written. An in-memory lookup that cannot fail; `get_storage` is the same
    /// read behind the database interface.
    pub fn read_storage(self: *Database, address: [20]u8, key: u256) u256 {
        const storage_key = StorageKey{ .address = address, .key = key };
        if (self.overlay_active) {
            if (self.overlay_storage.get(storage_key)) |v| return v;
        }
        return self.storage.get(storage_key) orelse 0;
    }

    /// Set storage value for the given address and key
    pub fn set_storage(self: *Database, address: [20]u8, key: u256, value: u256) Error!void {
        errdefer self.noteAllocationFailure();
        const storage_key = StorageKey{ .address = address, .key = key };
        if (self.overlay_active) {
            return self.writeSlot(&self.overlay_storage, .overlay, storage_key, value);
        }
        try self.writeSlot(&self.storage, .base, storage_key, value);
    }

    /// Set every storage slot of `address` to zero in the state a read sees.
    /// Costs O(slots of the account). In an ephemeral view the zeros land in the
    /// overlay and hide the base slots; base storage is not written. Every write
    /// is recorded in the undo log.
    pub fn clear_account_storage(self: *Database, address: [20]u8) Error!void {
        errdefer self.noteAllocationFailure();
        if (!self.overlay_active) return self.zeroSlots(&self.storage, .base, address);
        try self.zeroSlots(&self.overlay_storage, .overlay, address);
        // Hide every non-zero base slot the overlay does not already cover. The
        // writes change only the overlay, so the base key slice stays valid.
        for (self.storage.keysOf(address)) |key| {
            const storage_key = StorageKey{ .address = address, .key = key };
            if ((self.storage.get(storage_key) orelse 0) == 0) continue;
            if (self.overlay_storage.get(storage_key) != null) continue;
            try self.writeSlot(&self.overlay_storage, .overlay, storage_key, 0);
        }
    }

    /// Write zero over every non-zero slot `store` holds for `address`.
    fn zeroSlots(self: *Database, store: *SlotStore, layer: Layer, address: [20]u8) Error!void {
        // Overwriting an existing key never changes the key set, but the slice is
        // fetched again each round so that this does not depend on it.
        var index: usize = 0;
        while (index < store.keysOf(address).len) : (index += 1) {
            const storage_key = StorageKey{ .address = address, .key = store.keysOf(address)[index] };
            if ((store.get(storage_key) orelse 0) == 0) continue;
            try self.writeSlot(store, layer, storage_key, 0);
        }
    }

    /// True when `address` holds storage: a non-empty storage root, or at least one
    /// non-zero slot in the state a read would see (EIP-7610 collision check).
    pub fn has_storage(self: *Database, address: [20]u8) Error!bool {
        if (try self.get_account(address)) |account| {
            if (!std.mem.eql(u8, &account.storage_root, &ZERO_CODE_HASH) and
                !std.mem.eql(u8, &account.storage_root, &EMPTY_STORAGE_ROOT))
            {
                return true;
            }
        }
        const base_count = self.storage_slot_counts.get(address) orelse 0;
        if (!self.overlay_active) return base_count != 0;

        // The overlay can add slots and can also zero base slots, so a base slot
        // counts only when the overlay does not cover it.
        for (self.overlay_storage.keysOf(address)) |key| {
            if ((self.overlay_storage.get(.{ .address = address, .key = key }) orelse 0) != 0) return true;
        }
        if (base_count == 0) return false;
        for (self.storage.keysOf(address)) |key| {
            const storage_key = StorageKey{ .address = address, .key = key };
            if ((self.storage.get(storage_key) orelse 0) == 0) continue;
            if (self.overlay_storage.get(storage_key) == null) return true;
        }
        return false;
    }

    // Transient storage operations

    /// Get transient storage value for the given address and key (EIP-1153)
    pub fn get_transient_storage(self: *Database, address: [20]u8, key: u256) Error!u256 {
        const storage_key = StorageKey{ .address = address, .key = key };
        if (self.overlay_active) {
            if (self.overlay_transient.get(storage_key)) |v| return v;
        }
        return self.transient_storage.get(storage_key) orelse 0;
    }

    /// Set transient storage value for the given address and key (EIP-1153)
    pub fn set_transient_storage(self: *Database, address: [20]u8, key: u256, value: u256) Error!void {
        errdefer self.noteAllocationFailure();
        const storage_key = StorageKey{ .address = address, .key = key };
        if (self.overlay_active) {
            return self.writeTransientSlot(&self.overlay_transient, .overlay, storage_key, value);
        }
        try self.writeTransientSlot(&self.transient_storage, .base, storage_key, value);
    }

    // Code operations

    /// Get contract code by hash
    pub fn get_code(self: *Database, code_hash: [32]u8) Error![]const u8 {
        if (self.overlay_active) {
            if (self.overlay_code.get(code_hash)) |buf| return buf;
        }
        const code = self.code_storage.get(code_hash) orelse {
            return Error.CodeNotFound;
        };
        return code;
    }

    /// Get contract code by address. An EIP-7702 delegation is followed exactly once:
    /// a delegate that is itself delegated contributes its own stored code (empty), so a
    /// delegation loop such as an EOA delegating to itself cannot recurse.
    pub fn get_code_by_address(self: *Database, address: [20]u8) Error![]const u8 {
        if (try self.get_account(address)) |account| {
            if (account.get_effective_code_address()) |delegated_addr| {
                return self.get_stored_code_by_address(delegated_addr.bytes);
            }
            return self.get_stored_code_by_address(address);
        }
        return Error.AccountNotFound;
    }

    /// Code stored under `address`'s code hash, ignoring EIP-7702 delegation. An
    /// account without code, or one that does not exist, has empty code.
    fn get_stored_code_by_address(self: *Database, address: [20]u8) Error![]const u8 {
        if (try self.get_account(address)) |account| {
            // Check if this is an EOA (all-zero code_hash or EMPTY_CODE_HASH)
            // EOAs don't have code stored, return empty code
            if (!Account.is_code_hash_present(account.code_hash)) {
                return &.{};
            }

            return self.get_code(account.code_hash);
        }
        return &.{};
    }

    /// Store contract code and return its hash. Designator code (EIP-7702) is also
    /// registered, so `set_account` stores an account that names it as a delegated EOA.
    pub fn set_code(self: *Database, code: []const u8) Error![32]u8 {
        errdefer self.noteAllocationFailure();
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(code, &hash, .{});

        if (delegationTarget(code)) |target| try self.delegation_targets.put(hash, target);

        // Code is content-addressed: a hash any visible layer holds needs no new copy.
        if (self.overlay_active) {
            if (self.overlay_code.contains(hash)) return hash;
        }
        if (self.code_storage.contains(hash)) return hash;

        try self.reserveUndo();

        // Make a copy of the code to own it
        const code_copy = self.allocator.alloc(u8, code.len) catch return Error.OutOfMemory;
        errdefer self.allocator.free(code_copy);
        @memcpy(code_copy, code);

        if (self.overlay_active) {
            try self.overlay_code.put(hash, code_copy);
            self.recordUndo(.{ .code = .{ .layer = .overlay, .hash = hash } });
        } else {
            try self.code_storage.put(hash, code_copy);
            self.recordUndo(.{ .code = .{ .layer = .base, .hash = hash } });
        }
        return hash;
    }

    // State root operations

    /// Get current state root hash by building a trie from all accounts
    pub fn get_state_root(self: *Database) Error![32]u8 {
        return @import("state_root.zig").stateRoot(self.allocator, self);
    }

    /// Commit pending changes and return new state root
    pub fn commit_changes(self: *Database) Error![32]u8 {
        return self.get_state_root();
    }

    /// Clear transient storage (called at transaction end per EIP-1153)
    /// Uses clearRetainingCapacity to avoid memory churn between transactions
    pub fn clear_transient_storage(self: *Database) void {
        const layer: Layer = if (self.overlay_active) .overlay else .base;
        // Undo entries for cleared slots must not bring the values back.
        for (self.undo_log.items) |*entry| {
            switch (entry.*) {
                .transient => |e| if (e.layer == layer) {
                    entry.* = .noop;
                },
                else => {},
            }
        }
        if (self.overlay_active) {
            self.overlay_transient.clearRetainingCapacity();
            return;
        }
        self.transient_storage.clearRetainingCapacity();
    }

    // Snapshot operations

    /// Create a state snapshot and return its ID. O(1): the snapshot is the current
    /// length of the undo log.
    pub fn create_snapshot(self: *Database) Error!u64 {
        errdefer self.noteAllocationFailure();
        const snapshot_id = self.next_snapshot_id;
        try self.snapshots.append(self.allocator, .{ .id = snapshot_id, .undo_len = self.undo_log.items.len });
        self.next_snapshot_id += 1;
        return snapshot_id;
    }

    /// Position of the open snapshot with `snapshot_id`. The newest snapshot is the
    /// usual target, so the search starts there.
    fn snapshotIndex(self: *const Database, snapshot_id: u64) ?usize {
        var index = self.snapshots.items.len;
        while (index > 0) {
            index -= 1;
            if (self.snapshots.items[index].id == snapshot_id) return index;
        }
        return null;
    }

    /// Number of open snapshots.
    pub fn snapshot_depth(self: *const Database) usize {
        return self.snapshots.items.len;
    }

    /// Revert and close every snapshot above `depth`, newest first. Does nothing when
    /// no more than `depth` snapshots are open. Never allocates and cannot fail.
    pub fn revert_to_depth(self: *Database, depth: usize) void {
        if (self.snapshots.items.len <= depth) return;
        const undo_len = self.snapshots.items[depth].undo_len;
        while (self.undo_log.items.len > undo_len) {
            const entry = self.undo_log.items[self.undo_log.items.len - 1];
            self.undo_log.items.len -= 1;
            self.applyUndo(entry);
        }
        self.snapshots.shrinkRetainingCapacity(depth);
    }

    /// Commit and close every snapshot above `depth`: their writes stay, recorded
    /// for the snapshots still open. Does nothing when no more than `depth`
    /// snapshots are open. Never allocates and cannot fail.
    pub fn commit_to_depth(self: *Database, depth: usize) void {
        if (self.snapshots.items.len <= depth) return;
        self.snapshots.shrinkRetainingCapacity(depth);
        if (depth == 0) self.undo_log.clearRetainingCapacity();
    }

    /// Revert state to the given snapshot and close it together with every snapshot
    /// created after it. The only error is an unknown snapshot ID; the rollback
    /// itself never allocates and cannot fail.
    pub fn revert_to_snapshot(self: *Database, snapshot_id: u64) Error!void {
        const index = self.snapshotIndex(snapshot_id) orelse return Error.SnapshotNotFound;
        self.revert_to_depth(index);
    }

    /// Commit a snapshot (discard it without reverting). Its writes stay recorded for
    /// the snapshots that are still open; the undo log empties with the last one.
    pub fn commit_snapshot(self: *Database, snapshot_id: u64) Error!void {
        const index = self.snapshotIndex(snapshot_id) orelse return Error.SnapshotNotFound;
        _ = self.snapshots.orderedRemove(index);
        if (self.snapshots.items.len == 0) self.undo_log.clearRetainingCapacity();
    }

    // EIP-7702 Delegation operations

    /// Set delegation for an EOA to execute another address's code
    pub fn set_delegation(self: *Database, eoa_address: [20]u8, delegated_address: [20]u8) Error!void {

        // Get or create the EOA account
        var account = (try self.get_account(eoa_address)) orelse Account.zero();

        // Only EOAs can have delegations (no existing code)
        if (Account.is_code_hash_present(account.code_hash)) {
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

    // Transaction operations

    /// Begin a transaction and return its ID. A transaction is a snapshot whose ID
    /// fits `u32`.
    pub fn begin_transaction(self: *Database) Error!u32 {
        const id = std.math.cast(u32, self.next_snapshot_id) orelse return Error.InvalidSnapshot;
        _ = try self.create_snapshot();
        return id;
    }

    /// Commit a transaction: keep its writes. An enclosing snapshot can still undo them.
    pub fn commit_transaction(self: *Database, id: u32) Error!void {
        try self.commit_snapshot(id);
    }

    /// Roll back a transaction: undo its writes. Never allocates.
    pub fn rollback_transaction(self: *Database, id: u32) Error!void {
        try self.revert_to_snapshot(id);
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

    const test_address = [_]u8{0x12} ++ @as([19]u8, @splat(0));

    // Test account operations
    try testing.expect(!db.account_exists(test_address));
    try testing.expectEqual(@as(?Account, null), try db.get_account(test_address));

    var test_account = Account{
        .balance = 1000,
        .nonce = 5,
        .code_hash = @as([32]u8, @splat(0xAB)),
        .storage_root = @as([32]u8, @splat(0xCD)),
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

    const test_address = [_]u8{0x34} ++ @as([19]u8, @splat(0));
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

    const test_address = [_]u8{0x56} ++ @as([19]u8, @splat(0));
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
    const test_address = [_]u8{0x78} ++ @as([19]u8, @splat(0));
    const account = Account{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
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

    const test_address = [_]u8{0x78} ++ @as([19]u8, @splat(0));
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
        .storage_root = @as([32]u8, @splat(0)),
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

    const invalid_hash = @as([32]u8, @splat(0xFF));
    try testing.expectError(Database.Error.CodeNotFound, db.get_code(invalid_hash));

    const test_address = [_]u8{0x99} ++ @as([19]u8, @splat(0));
    try testing.expectError(Database.Error.AccountNotFound, db.get_code_by_address(test_address));
}

test "Database delete account operations" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const test_address = [_]u8{0x99} ++ @as([19]u8, @splat(0));
    const test_account = Account{
        .balance = 500,
        .nonce = 3,
        .code_hash = @as([32]u8, @splat(0x11)),
        .storage_root = @as([32]u8, @splat(0x22)),
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

    const addr1 = [_]u8{0x01} ++ @as([19]u8, @splat(0));
    const addr2 = [_]u8{0x02} ++ @as([19]u8, @splat(0));

    // Initially no accounts exist
    try testing.expect(!db.account_exists(addr1));
    try testing.expect(!db.account_exists(addr2));
    try testing.expectEqual(@as(u256, 0), try db.get_balance(addr1));

    // Create account
    const account1 = Account{
        .balance = 1000,
        .nonce = 5,
        .code_hash = @as([32]u8, @splat(0xAA)),
        .storage_root = @as([32]u8, @splat(0xBB)),
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

    const addr1 = [_]u8{0x01} ++ @as([19]u8, @splat(0));
    const addr2 = [_]u8{0x02} ++ @as([19]u8, @splat(0));
    const storage_key: u256 = 42;

    // Initial state
    const account1 = Account{ .balance = 100, .nonce = 1, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) };
    try db.set_account(addr1, account1);
    try db.set_storage(addr1, storage_key, 999);

    // Create snapshot
    const snapshot_id = try db.create_snapshot();

    // Make changes
    const account2 = Account{ .balance = 200, .nonce = 2, .code_hash = @as([32]u8, @splat(1)), .storage_root = @as([32]u8, @splat(1)) };
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

    const addr = [_]u8{0x01} ++ @as([19]u8, @splat(0));

    // Initial state
    const initial_account = Account{ .balance = 100, .nonce = 0, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) };
    try db.set_account(addr, initial_account);

    // First snapshot
    const snapshot1 = try db.create_snapshot();
    const account1 = Account{ .balance = 200, .nonce = 1, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) };
    try db.set_account(addr, account1);

    // Second snapshot
    const snapshot2 = try db.create_snapshot();
    const account2 = Account{ .balance = 300, .nonce = 2, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) };
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

    const addr = [_]u8{0x01} ++ @as([19]u8, @splat(0));

    // Initial state
    const account = Account{ .balance = 100, .nonce = 0, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) };
    try db.set_account(addr, account);

    // Create snapshot and make changes
    const snapshot_id = try db.create_snapshot();
    const new_account = Account{ .balance = 200, .nonce = 1, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) };
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
    const addr = [_]u8{0x01} ++ @as([19]u8, @splat(0));
    const account = Account{
        .balance = 100,
        .nonce = 1,
        .code_hash = @as([32]u8, @splat(0xAA)),
        .storage_root = @as([32]u8, @splat(0xBB)),
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
    const addr1 = [_]u8{0x01} ++ @as([19]u8, @splat(0));
    const addr2 = [_]u8{0x02} ++ @as([19]u8, @splat(0));
    const addr3 = [_]u8{0x03} ++ @as([19]u8, @splat(0));

    const account1 = Account{ .balance = 100, .nonce = 1, .code_hash = @as([32]u8, @splat(0xAA)), .storage_root = @as([32]u8, @splat(0xBB)) };
    const account2 = Account{ .balance = 200, .nonce = 2, .code_hash = @as([32]u8, @splat(0xCC)), .storage_root = @as([32]u8, @splat(0xDD)) };
    const account3 = Account{ .balance = 300, .nonce = 3, .code_hash = @as([32]u8, @splat(0xEE)), .storage_root = @as([32]u8, @splat(0xFF)) };

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
    const addr1 = [_]u8{0x01} ++ @as([19]u8, @splat(0));
    const addr2 = [_]u8{0x02} ++ @as([19]u8, @splat(0));
    const account1 = Account{ .balance = 100, .nonce = 1, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) };
    const account2 = Account{ .balance = 200, .nonce = 2, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) };

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

    const addr = [_]u8{0x01} ++ @as([19]u8, @splat(0));
    const account1 = Account{ .balance = 100, .nonce = 1, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) };

    // Initial state
    try db.set_account(addr, account1);
    const root1 = try db.get_state_root();

    // Modify account
    const account2 = Account{ .balance = 200, .nonce = 2, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) };
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

    const addr = [_]u8{0x01} ++ @as([19]u8, @splat(0));
    var account = Account{ .balance = 100, .nonce = 1, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) };
    try db.set_account(addr, account);
    const empty_storage = try db.get_state_root();

    // The state root follows the account's slots.
    try db.set_storage(addr, 1, 1);
    const one_slot = try db.get_state_root();
    try testing.expect(!std.mem.eql(u8, &empty_storage, &one_slot));
    try db.set_storage(addr, 1, 2);
    const changed_slot = try db.get_state_root();
    try testing.expect(!std.mem.eql(u8, &one_slot, &changed_slot));

    // A zero slot is not in the storage trie.
    try db.set_storage(addr, 1, 0);
    try testing.expectEqualSlices(u8, &empty_storage, &(try db.get_state_root()));

    // The storage root is computed from the slots; the cached field is ignored.
    account.storage_root = @as([32]u8, @splat(0x22));
    try db.set_account(addr, account);
    try testing.expectEqualSlices(u8, &empty_storage, &(try db.get_state_root()));
}

test "Database state root - balance changes" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x01} ++ @as([19]u8, @splat(0));

    // Zero balance
    const account1 = Account{ .balance = 0, .nonce = 0, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) };
    try db.set_account(addr, account1);
    const root1 = try db.get_state_root();

    // Small balance
    const account2 = Account{ .balance = 1, .nonce = 0, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) };
    try db.set_account(addr, account2);
    const root2 = try db.get_state_root();

    // Large balance
    const account3 = Account{ .balance = std.math.maxInt(u256), .nonce = 0, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) };
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

    const addr = [_]u8{0x01} ++ @as([19]u8, @splat(0));

    // Nonce 0
    const account1 = Account{ .balance = 100, .nonce = 0, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) };
    try db.set_account(addr, account1);
    const root1 = try db.get_state_root();

    // Nonce 1
    const account2 = Account{ .balance = 100, .nonce = 1, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) };
    try db.set_account(addr, account2);
    const root2 = try db.get_state_root();

    // Nonce max
    const account3 = Account{ .balance = 100, .nonce = std.math.maxInt(u64), .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) };
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

    const addr = [_]u8{0x01} ++ @as([19]u8, @splat(0));

    // Empty code hash
    const account1 = Account{ .balance = 100, .nonce = 1, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) };
    try db.set_account(addr, account1);
    const root1 = try db.get_state_root();

    // Code hash 1
    const account2 = Account{ .balance = 100, .nonce = 1, .code_hash = @as([32]u8, @splat(0xAA)), .storage_root = @as([32]u8, @splat(0)) };
    try db.set_account(addr, account2);
    const root2 = try db.get_state_root();

    // Code hash 2
    const account3 = Account{ .balance = 100, .nonce = 1, .code_hash = @as([32]u8, @splat(0xBB)), .storage_root = @as([32]u8, @splat(0)) };
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

    const addr = [_]u8{0x01} ++ @as([19]u8, @splat(0));
    const account = Account{ .balance = 100, .nonce = 1, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) };

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
        var addr: [20]u8 = @as([20]u8, @splat(0));
        addr[19] = @intCast(i & 0xFF);
        const account = Account{
            .balance = @intCast(i * 1000),
            .nonce = @intCast(i),
            .code_hash = @as([32]u8, @splat(0)),
            .storage_root = @as([32]u8, @splat(0)),
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

    const addr = [_]u8{0x01} ++ @as([19]u8, @splat(0));
    const account = Account{ .balance = 100, .nonce = 1, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) };

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
    const addr1 = [_]u8{0x01} ++ @as([19]u8, @splat(0));
    const addr2 = [_]u8{0x02} ++ @as([19]u8, @splat(0));

    const account = Account{ .balance = 100, .nonce = 1, .code_hash = @as([32]u8, @splat(0)), .storage_root = @as([32]u8, @splat(0)) };

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

    const addr = [_]u8{0x01} ++ @as([19]u8, @splat(0));

    // Account with all zero values
    const account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
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

    const addr1 = [_]u8{0xA1} ++ @as([19]u8, @splat(0));
    const addr2 = [_]u8{0xA2} ++ @as([19]u8, @splat(0));

    const account1 = Account{
        .balance = 100,
        .nonce = 1,
        .code_hash = @as([32]u8, @splat(0x11)),
        .storage_root = @as([32]u8, @splat(0x22)),
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
        .code_hash = @as([32]u8, @splat(0x33)),
        .storage_root = @as([32]u8, @splat(0x44)),
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

    const addr1 = [_]u8{0xB1} ++ @as([19]u8, @splat(0));
    const account1 = Account{
        .balance = 300,
        .nonce = 5,
        .code_hash = @as([32]u8, @splat(0x55)),
        .storage_root = @as([32]u8, @splat(0x66)),
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

    const addr1 = [_]u8{0xC1} ++ @as([19]u8, @splat(0));

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

test "Database storage key collision handling" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr1 = [_]u8{0x01} ++ @as([19]u8, @splat(0));
    const addr2 = [_]u8{0x02} ++ @as([19]u8, @splat(0));
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

    const non_existent_hash = @as([32]u8, @splat(0xFF));

    // Code not found error
    try testing.expectError(Database.Error.CodeNotFound, db.get_code(non_existent_hash));

    // Account not found for code by address
    const non_existent_addr = [_]u8{0xEE} ++ @as([19]u8, @splat(0));
    try testing.expectError(Database.Error.AccountNotFound, db.get_code_by_address(non_existent_addr));

    // Snapshot not found
    try testing.expectError(Database.Error.SnapshotNotFound, db.revert_to_snapshot(999));
    try testing.expectError(Database.Error.SnapshotNotFound, db.commit_snapshot(999));
}

test "Database zero address handling" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const zero_address = @as([20]u8, @splat(0));
    const account = Account{
        .balance = 1000,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
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

    const addr = @as([20]u8, @splat(0xFF));
    const large_value: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    const large_key: u256 = 0x123456789ABCDEF123456789ABCDEF123456789ABCDEF123456789ABCDEF1234;

    // Test with maximum values
    const account = Account{
        .balance = large_value,
        .nonce = std.math.maxInt(u64),
        .code_hash = @as([32]u8, @splat(0xFF)),
        .storage_root = @as([32]u8, @splat(0xFF)),
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

    const max_address = @as([20]u8, @splat(0xFF));
    const max_u256 = std.math.maxInt(u256);
    const max_nonce = std.math.maxInt(u64);

    const max_account = Account{
        .balance = max_u256,
        .nonce = max_nonce,
        .code_hash = @as([32]u8, @splat(0xFF)),
        .storage_root = @as([32]u8, @splat(0xFF)),
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
        var addr: [20]u8 = @as([20]u8, @splat(0));
        addr[16] = @intCast(std.math.shr(usize, i, 24) & 0xFF);
        addr[17] = @intCast(std.math.shr(usize, i, 16) & 0xFF);
        addr[18] = @intCast(std.math.shr(usize, i, 8) & 0xFF);
        addr[19] = @intCast(i & 0xFF);

        const account = Account{
            .balance = @intCast(i),
            .nonce = @intCast(i % 1000),
            .code_hash = @as([32]u8, @splat(@intCast(i & 0xFF))),
            .storage_root = @as([32]u8, @splat(@intCast((i + 1) & 0xFF))),
        };

        try db.set_account(addr, account);
    }

    // Verify all accounts
    for (0..num_accounts) |i| {
        var addr: [20]u8 = @as([20]u8, @splat(0));
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

    const addr1 = [_]u8{0x11} ++ @as([19]u8, @splat(0));
    const addr2 = [_]u8{0x22} ++ @as([19]u8, @splat(0));
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
    const addr = [_]u8{0x33} ++ @as([19]u8, @splat(0));
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

    const addr = [_]u8{0x44} ++ @as([19]u8, @splat(0));
    const storage_key: u256 = 777;

    const account1 = Account{
        .balance = 100,
        .nonce = 1,
        .code_hash = @as([32]u8, @splat(0x11)),
        .storage_root = @as([32]u8, @splat(0x22)),
    };

    const account2 = Account{
        .balance = 200,
        .nonce = 2,
        .code_hash = @as([32]u8, @splat(0x33)),
        .storage_root = @as([32]u8, @splat(0x44)),
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

    const eoa_address = [_]u8{0x01} ++ @as([19]u8, @splat(0));
    const contract_address = [_]u8{0x02} ++ @as([19]u8, @splat(0));
    const contract_code = [_]u8{ 0x60, 0x80, 0x60, 0x40, 0x52 }; // Simple bytecode

    // Store contract code
    const code_hash = try db.set_code(&contract_code);
    const contract_account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
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

    // The EOA account still exists, so its code is empty rather than missing.
    try testing.expectEqual(@as(usize, 0), (try db.get_code_by_address(eoa_address)).len);
    // An address with no account at all is the AccountNotFound case.
    const missing_address = [_]u8{0x09} ++ @as([19]u8, @splat(0));
    try testing.expectError(Database.Error.AccountNotFound, db.get_code_by_address(missing_address));
}

test "EIP-7702: Cannot set delegation on contract" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const contract_address = [_]u8{0x03} ++ @as([19]u8, @splat(0));
    const delegate_address = [_]u8{0x04} ++ @as([19]u8, @splat(0));

    // Create a contract account (has code)
    const code_hash = try db.set_code(&[_]u8{0x60});
    const contract_account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
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

    const eoa1_address = [_]u8{0x05} ++ @as([19]u8, @splat(0));
    const eoa2_address = [_]u8{0x06} ++ @as([19]u8, @splat(0));
    const contract_address = [_]u8{0x07} ++ @as([19]u8, @splat(0));
    const contract_code = [_]u8{ 0x60, 0xFF }; // PUSH1 0xFF

    // Store contract code
    const code_hash = try db.set_code(&contract_code);
    const contract_account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
        .delegated_address = null,
    };
    try db.set_account(contract_address, contract_account);

    // EOA1 delegates to EOA2
    try db.set_delegation(eoa1_address, eoa2_address);

    // EOA2 delegates to contract
    try db.set_delegation(eoa2_address, contract_address);

    // EIP-7702 follows a delegation exactly once. EOA1 resolves to EOA2, whose own
    // stored code is empty; the chain to the contract is not followed.
    const eoa1_code = try db.get_code_by_address(eoa1_address);
    try testing.expectEqual(@as(usize, 0), eoa1_code.len);

    // One hop does reach the contract.
    const eoa2_code = try db.get_code_by_address(eoa2_address);
    try testing.expectEqualSlices(u8, &contract_code, eoa2_code);
}

test "Database validation test" {
    // Compile-time validation should pass for Database type
    validate_database_implementation(Database);
}

test "Database state persistence across operations" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr1 = [_]u8{0x55} ++ @as([19]u8, @splat(0));
    const addr2 = [_]u8{0x66} ++ @as([19]u8, @splat(0));

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

    const addr = [_]u8{0xAA} ++ @as([19]u8, @splat(0));

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

    const addr = [_]u8{0xBB} ++ @as([19]u8, @splat(0));

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

    const addr = [_]u8{0xCC} ++ @as([19]u8, @splat(0));

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
        .storage_root = @as([32]u8, @splat(0)),
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

    const addr = [_]u8{0xDD} ++ @as([19]u8, @splat(0));

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

    const addr = [_]u8{0xEE} ++ @as([19]u8, @splat(0));

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

    const addr = [_]u8{0xFF} ++ @as([19]u8, @splat(0));

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

    const addr = [_]u8{0x11} ++ @as([19]u8, @splat(0));

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

    const addr = [_]u8{0x22} ++ @as([19]u8, @splat(0));

    // Create account with nonce and code
    const code_hash = try db.set_code(&[_]u8{ 0x60, 0x01 });
    const account = Account{
        .balance = 1000,
        .nonce = 5,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0xAB)),
    };
    try db.set_account(addr, account);

    // Set balance
    try db.set_balance(addr, 2000);

    // Verify other fields are preserved
    const retrieved = (try db.get_account(addr)).?;
    try testing.expectEqual(@as(u256, 2000), retrieved.balance);
    try testing.expectEqual(@as(u64, 5), retrieved.nonce);
    try testing.expectEqualSlices(u8, &code_hash, &retrieved.code_hash);
    try testing.expectEqualSlices(u8, &(@as([32]u8, @splat(0xAB))), &retrieved.storage_root);
}

test "Database set_nonce preserves other account fields" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x33} ++ @as([19]u8, @splat(0));

    // Create account with balance and code
    const code_hash = try db.set_code(&[_]u8{ 0x60, 0x02 });
    const account = Account{
        .balance = 1000,
        .nonce = 5,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0xCD)),
    };
    try db.set_account(addr, account);

    // Set nonce
    try db.set_nonce(addr, 10);

    // Verify other fields are preserved
    const retrieved = (try db.get_account(addr)).?;
    try testing.expectEqual(@as(u256, 1000), retrieved.balance);
    try testing.expectEqual(@as(u64, 10), retrieved.nonce);
    try testing.expectEqualSlices(u8, &code_hash, &retrieved.code_hash);
    try testing.expectEqualSlices(u8, &(@as([32]u8, @splat(0xCD))), &retrieved.storage_root);
}

test "Database get_balance with overlay" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0x44} ++ @as([19]u8, @splat(0));

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

    const addr = [_]u8{0x55} ++ @as([19]u8, @splat(0));

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

    const addr = [_]u8{0x66} ++ @as([19]u8, @splat(0));

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

    const addr = [_]u8{0x77} ++ @as([19]u8, @splat(0));
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

    const addr = [_]u8{0x88} ++ @as([19]u8, @splat(0));

    // Create account with explicit zero code hash
    const account = Account{
        .balance = 100,
        .nonce = 1,
        .code_hash = ZERO_CODE_HASH,
        .storage_root = @as([32]u8, @splat(0)),
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


test "Database transaction - account write commits" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0xCC} ++ @as([19]u8, @splat(0));
    const initial_account = Account{
        .balance = 100,
        .nonce = 1,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    };

    // Set initial state
    try db.set_account(addr, initial_account);

    // Begin transaction
    const tx_id = try db.begin_transaction();

    // Modify account
    const modified_account = Account{
        .balance = 200,
        .nonce = 2,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    };
    try db.set_account(addr, modified_account);

    // Should see modified value
    const retrieved = (try db.get_account(addr)).?;
    try testing.expectEqual(@as(u256, 200), retrieved.balance);

    // Commit transaction
    try db.commit_transaction(tx_id);

    // Value should persist after commit
    const final = (try db.get_account(addr)).?;
    try testing.expectEqual(@as(u256, 200), final.balance);
}

test "Database transaction - rollback discards many changes" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0xDD} ++ @as([19]u8, @splat(0));
    const initial_account = Account{
        .balance = 1000,
        .nonce = 5,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    };

    try db.set_account(addr, initial_account);

    // Begin transaction
    const tx_id = try db.begin_transaction();

    // Make many changes
    for (0..100) |i| {
        const account = Account{
            .balance = @intCast(i * 100),
            .nonce = @intCast(i),
            .code_hash = @as([32]u8, @splat(0)),
            .storage_root = @as([32]u8, @splat(0)),
        };
        try db.set_account(addr, account);
        try db.set_storage(addr, @intCast(i), @intCast(i * 10));
    }

    // Rollback
    try db.rollback_transaction(tx_id);

    // Original values should be restored
    const restored = (try db.get_account(addr)).?;
    try testing.expectEqual(@as(u256, 1000), restored.balance);
    try testing.expectEqual(@as(u64, 5), restored.nonce);
}

test "Database transaction - storage write commits" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0xEE} ++ @as([19]u8, @splat(0));
    const key: u256 = 0x12345;
    const initial_value: u256 = 100;
    const modified_value: u256 = 200;

    // Set initial storage
    try db.set_storage(addr, key, initial_value);

    // Begin transaction
    const tx_id = try db.begin_transaction();

    // Modify storage
    try db.set_storage(addr, key, modified_value);

    // Should see modified value
    try testing.expectEqual(modified_value, try db.get_storage(addr, key));

    // Commit
    try db.commit_transaction(tx_id);

    // Value should persist
    try testing.expectEqual(modified_value, try db.get_storage(addr, key));
}

test "Database transaction - code write commits" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const test_code = [_]u8{ 0x60, 0x80, 0x60, 0x40, 0x52 }; // Simple bytecode

    // Begin transaction
    const tx_id = try db.begin_transaction();

    // Store code
    const code_hash = try db.set_code(&test_code);

    // Should retrieve it inside the transaction
    const retrieved = try db.get_code(code_hash);
    try testing.expectEqualSlices(u8, &test_code, retrieved);

    // Commit
    try db.commit_transaction(tx_id);

    // Code should persist
    const final = try db.get_code(code_hash);
    try testing.expectEqualSlices(u8, &test_code, final);
}

test "Database transaction - account deletion commits" {
    const allocator = testing.allocator;
    var db = Database.init(allocator);
    defer db.deinit();

    const addr = [_]u8{0xBB} ++ @as([19]u8, @splat(0));

    // Create initial account
    const account = Account{
        .balance = 100,
        .nonce = 1,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    };
    try db.set_account(addr, account);

    // Begin transaction
    const tx_id = try db.begin_transaction();

    // Delete account
    try db.delete_account(addr);

    // Should not exist inside the transaction
    try testing.expect(!db.account_exists(addr));

    // Commit
    try db.commit_transaction(tx_id);

    // Account should stay deleted
    try testing.expect(!db.account_exists(addr));
}

test "Database snapshot is O(1): it records a position, not a copy of the state" {
    var db = Database.init(testing.allocator);
    defer db.deinit();

    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        var address = @as([20]u8, @splat(0));
        std.mem.writeInt(u64, address[0..8], i, .big);
        try db.set_account(address, Account.zero());
        try db.set_storage(address, i, i + 1);
    }

    const snapshot = try db.create_snapshot();
    try testing.expectEqual(@as(usize, 1), db.snapshot_depth());
    try testing.expectEqual(@as(usize, 0), db.undo_log.items.len);

    const address = @as([20]u8, @splat(0xAA));
    try db.set_storage(address, 1, 2);
    try testing.expectEqual(@as(usize, 1), db.undo_log.items.len);

    try db.revert_to_snapshot(snapshot);
    try testing.expectEqual(@as(u256, 0), try db.get_storage(address, 1));
    try testing.expectEqual(@as(usize, 1000), db.storage.count());
    try testing.expectEqual(@as(usize, 0), db.undo_log.items.len);
}

test "Database revert restores accounts, deletions, storage, transient storage and code" {
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const kept = @as([20]u8, @splat(0x01));
    const deleted = @as([20]u8, @splat(0x02));
    const created = @as([20]u8, @splat(0x03));
    var kept_account = Account.zero();
    kept_account.balance = 100;
    try db.set_account(kept, kept_account);
    var deleted_account = Account.zero();
    deleted_account.nonce = 7;
    try db.set_account(deleted, deleted_account);
    try db.set_storage(kept, 1, 11);
    try db.set_transient_storage(kept, 1, 21);

    const snapshot = try db.create_snapshot();

    kept_account.balance = 5;
    try db.set_account(kept, kept_account);
    try db.delete_account(deleted);
    try db.set_account(created, Account.zero());
    try db.set_storage(kept, 1, 0);
    try db.set_storage(kept, 2, 12);
    try db.set_transient_storage(kept, 1, 22);
    try db.set_transient_storage(kept, 2, 23);
    const code_hash = try db.set_code(&[_]u8{ 0x60, 0x00 });
    try testing.expect(!(try db.has_storage(deleted)));

    try db.revert_to_snapshot(snapshot);

    try testing.expectEqual(@as(u256, 100), (try db.get_account(kept)).?.balance);
    try testing.expectEqual(@as(u64, 7), (try db.get_account(deleted)).?.nonce);
    try testing.expect(!db.account_exists(created));
    try testing.expectEqual(@as(u256, 11), try db.get_storage(kept, 1));
    try testing.expectEqual(@as(u256, 0), try db.get_storage(kept, 2));
    try testing.expect(!db.storage.contains(.{ .address = kept, .key = 2 }));
    try testing.expectEqual(@as(u256, 21), try db.get_transient_storage(kept, 1));
    try testing.expectEqual(@as(u256, 0), try db.get_transient_storage(kept, 2));
    try testing.expectError(Database.Error.CodeNotFound, db.get_code(code_hash));
    try testing.expectEqual(@as(usize, 0), db.snapshot_depth());
}

test "Database revert never allocates" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var db = Database.init(failing.allocator());
    defer db.deinit();

    var i: u8 = 0;
    while (i < 64) : (i += 1) {
        const address = @as([20]u8, @splat(i));
        var account = Account.zero();
        account.nonce = i;
        try db.set_account(address, account);
        try db.set_storage(address, i, @as(u256, i) + 1);
    }

    const snapshot = try db.create_snapshot();
    i = 0;
    while (i < 64) : (i += 1) {
        const address = @as([20]u8, @splat(i));
        try db.delete_account(address);
        try db.set_storage(address, i, 0);
        try db.set_transient_storage(address, i, 9);
    }

    // Every allocation from here on fails; the rollback must still complete.
    failing.fail_index = failing.alloc_index;
    try db.revert_to_snapshot(snapshot);

    i = 0;
    while (i < 64) : (i += 1) {
        const address = @as([20]u8, @splat(i));
        try testing.expectEqual(@as(u64, i), (try db.get_account(address)).?.nonce);
        try testing.expectEqual(@as(u256, i) + 1, try db.get_storage(address, i));
        try testing.expectEqual(@as(u256, 0), try db.get_transient_storage(address, i));
        try testing.expect(try db.has_storage(address));
    }
}

test "Database failed write under a snapshot leaves state and undo log unchanged" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var db = Database.init(failing.allocator());
    defer db.deinit();

    const address = @as([20]u8, @splat(0x10));
    try db.set_storage(address, 1, 1);
    const snapshot = try db.create_snapshot();

    failing.fail_index = failing.alloc_index;
    try testing.expectEqual(@as(?Database.Error, null), db.failure);
    try testing.expectError(Database.Error.OutOfMemory, db.set_storage(address, 1, 2));
    try testing.expectEqual(@as(u256, 1), try db.get_storage(address, 1));
    try testing.expectEqual(@as(usize, 0), db.undo_log.items.len);
    // The failure stays readable after the caller has handled the error.
    try testing.expectEqual(@as(?Database.Error, Database.Error.OutOfMemory), db.failure);

    failing.fail_index = std.math.maxInt(usize);
    try db.revert_to_snapshot(snapshot);
    try testing.expectEqual(@as(u256, 1), try db.get_storage(address, 1));
}

test "Database nested snapshots: inner commit stays undoable by the outer revert" {
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const address = @as([20]u8, @splat(0x20));
    try db.set_storage(address, 1, 1);

    const outer = try db.create_snapshot();
    try db.set_storage(address, 1, 2);
    const inner = try db.create_snapshot();
    try db.set_storage(address, 1, 3);
    try db.commit_snapshot(inner);
    try testing.expectEqual(@as(u256, 3), try db.get_storage(address, 1));

    const failed = try db.create_snapshot();
    try db.set_storage(address, 1, 4);
    try db.revert_to_snapshot(failed);
    try testing.expectEqual(@as(u256, 3), try db.get_storage(address, 1));

    try db.revert_to_snapshot(outer);
    try testing.expectEqual(@as(u256, 1), try db.get_storage(address, 1));
    try testing.expectEqual(@as(usize, 0), db.undo_log.items.len);
}

test "Database revert_to_depth closes leaked snapshots" {
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const address = @as([20]u8, @splat(0x21));
    const depth = db.snapshot_depth();
    _ = try db.create_snapshot();
    try db.set_storage(address, 1, 1);
    _ = try db.create_snapshot();
    try db.set_storage(address, 1, 2);

    db.revert_to_depth(depth);
    try testing.expectEqual(depth, db.snapshot_depth());
    try testing.expectEqual(@as(u256, 0), try db.get_storage(address, 1));
    // Reverting to a depth that is already reached changes nothing.
    db.revert_to_depth(depth);
    try testing.expectEqual(depth, db.snapshot_depth());
}

test "Database overlay: revert rolls back overlay writes, tombstones and transient storage" {
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const address = @as([20]u8, @splat(0x30));
    var account = Account.zero();
    account.balance = 50;
    try db.set_account(address, account);
    try db.set_storage(address, 1, 10);
    try db.set_transient_storage(address, 1, 70);

    db.begin_ephemeral_view();
    try db.set_storage(address, 1, 11);
    try db.set_transient_storage(address, 1, 71);

    const snapshot = try db.create_snapshot();
    try db.set_storage(address, 1, 12);
    try db.set_storage(address, 2, 13);
    try db.set_transient_storage(address, 1, 72);
    try db.delete_account(address);
    try testing.expect(!db.account_exists(address));
    try testing.expectEqual(@as(?Account, null), try db.get_account(address));
    try db.revert_to_snapshot(snapshot);

    // The view is back to its state before the snapshot, not to base state.
    try testing.expectEqual(@as(u256, 11), try db.get_storage(address, 1));
    try testing.expectEqual(@as(u256, 0), try db.get_storage(address, 2));
    try testing.expectEqual(@as(u256, 71), try db.get_transient_storage(address, 1));
    try testing.expectEqual(@as(u256, 50), (try db.get_account(address)).?.balance);

    db.discard_ephemeral_view();
    // Base state never changed.
    try testing.expectEqual(@as(u256, 10), try db.get_storage(address, 1));
    try testing.expectEqual(@as(u256, 70), try db.get_transient_storage(address, 1));
    try testing.expectEqual(@as(u256, 50), (try db.get_account(address)).?.balance);
}

test "Database overlay: discarding the view under an open snapshot drops its undo entries" {
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const address = @as([20]u8, @splat(0x31));
    try db.set_storage(address, 1, 10);

    const snapshot = try db.create_snapshot();
    db.begin_ephemeral_view();
    try db.set_storage(address, 1, 11);
    db.discard_ephemeral_view();
    try db.set_storage(address, 1, 12);

    try db.revert_to_snapshot(snapshot);
    try testing.expectEqual(@as(u256, 10), try db.get_storage(address, 1));
    try testing.expectEqual(@as(usize, 0), db.overlay_storage.count());
}

test "Database has_storage: storage root, non-zero slots, and layers" {
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const empty = @as([20]u8, @splat(0x40));
    const rooted = @as([20]u8, @splat(0x41));
    const slotted = @as([20]u8, @splat(0x42));

    try db.set_account(empty, Account.zero());
    try testing.expect(!(try db.has_storage(empty)));

    var empty_root = Account.zero();
    empty_root.storage_root = EMPTY_STORAGE_ROOT;
    try db.set_account(empty, empty_root);
    try testing.expect(!(try db.has_storage(empty)));

    var rooted_account = Account.zero();
    rooted_account.storage_root = @as([32]u8, @splat(0x77));
    try db.set_account(rooted, rooted_account);
    try testing.expect(try db.has_storage(rooted));

    // Storage without an account entry still counts.
    try db.set_storage(slotted, 5, 0);
    try testing.expect(!(try db.has_storage(slotted)));
    try db.set_storage(slotted, 5, 1);
    try db.set_storage(slotted, 6, 1);
    try testing.expect(try db.has_storage(slotted));
    try db.set_storage(slotted, 5, 0);
    try testing.expect(try db.has_storage(slotted));
    try db.set_storage(slotted, 6, 0);
    try testing.expect(!(try db.has_storage(slotted)));

    // A view that zeroes the only slot hides the storage; one that adds a slot shows it.
    try db.set_storage(slotted, 6, 9);
    db.begin_ephemeral_view();
    try db.set_storage(slotted, 6, 0);
    try testing.expect(!(try db.has_storage(slotted)));
    try db.set_storage(empty, 1, 1);
    try testing.expect(try db.has_storage(empty));
    db.discard_ephemeral_view();
    try testing.expect(try db.has_storage(slotted));
    try testing.expect(!(try db.has_storage(empty)));
}

test "Database transaction: enclosing snapshot undoes a committed transaction" {
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const address = @as([20]u8, @splat(0x50));
    try db.set_storage(address, 1, 1);

    const outer = try db.create_snapshot();
    const tx = try db.begin_transaction();
    try db.set_storage(address, 1, 2);
    var account = Account.zero();
    account.nonce = 3;
    try db.set_account(address, account);
    try db.commit_transaction(tx);
    try testing.expectEqual(@as(u256, 2), try db.get_storage(address, 1));
    try testing.expect(db.account_exists(address));

    try db.revert_to_snapshot(outer);
    try testing.expectEqual(@as(u256, 1), try db.get_storage(address, 1));
    try testing.expect(!db.account_exists(address));
}

test {
    _ = @import("slot_store.zig");
    _ = @import("database_proxy.zig");
}

test "Database clear_account_storage zeroes only that account and is undone by revert" {
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const doomed = @as([20]u8, @splat(0x60));
    const neighbour = @as([20]u8, @splat(0x61));
    try db.set_storage(doomed, 1, 11);
    try db.set_storage(doomed, 2, 22);
    try db.set_storage(doomed, 3, 0);
    try db.set_storage(neighbour, 1, 99);

    const snapshot = try db.create_snapshot();
    try db.clear_account_storage(doomed);
    try testing.expectEqual(@as(u256, 0), try db.get_storage(doomed, 1));
    try testing.expectEqual(@as(u256, 0), try db.get_storage(doomed, 2));
    try testing.expect(!(try db.has_storage(doomed)));
    try testing.expectEqual(@as(u256, 99), try db.get_storage(neighbour, 1));
    // One undo entry per non-zero slot of the account: the cost does not depend
    // on the rest of the database.
    try testing.expectEqual(@as(usize, 2), db.undo_log.items.len);

    try db.revert_to_snapshot(snapshot);
    try testing.expectEqual(@as(u256, 11), try db.get_storage(doomed, 1));
    try testing.expectEqual(@as(u256, 22), try db.get_storage(doomed, 2));
    try testing.expect(try db.has_storage(doomed));
}

test "Database delete_account removes the account's storage and revert restores both" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var db = Database.init(failing.allocator());
    defer db.deinit();

    const address = @as([20]u8, @splat(0x62));
    var account = Account.zero();
    account.nonce = 7;
    try db.set_account(address, account);
    try db.set_storage(address, 1, 11);
    try db.set_storage(address, 2, 22);

    const snapshot = try db.create_snapshot();
    try db.delete_account(address);
    try testing.expect(!db.account_exists(address));
    try testing.expect(!(try db.has_storage(address)));
    try testing.expectEqual(@as(u256, 0), try db.get_storage(address, 1));

    // An account recreated at the address starts with empty storage.
    try db.set_account(address, Account.zero());
    try testing.expectEqual(@as(u256, 0), try db.get_storage(address, 2));

    // The rollback restores account and storage without allocating.
    failing.fail_index = failing.alloc_index;
    try db.revert_to_snapshot(snapshot);
    try testing.expectEqual(@as(u64, 7), (try db.get_account(address)).?.nonce);
    try testing.expectEqual(@as(u256, 11), try db.get_storage(address, 1));
    try testing.expectEqual(@as(u256, 22), try db.get_storage(address, 2));
}

test "Database delete_account without a snapshot leaves no slot behind" {
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const address = @as([20]u8, @splat(0x63));
    try db.set_balance(address, 1);
    var key: u256 = 0;
    while (key < 100) : (key += 1) try db.set_storage(address, key, key + 1);

    try db.delete_account(address);
    try testing.expectEqual(@as(?usize, 0), db.storage_slot_counts.get(address));
    var slots = db.storage.iterator();
    while (slots.next()) |slot| try testing.expectEqual(@as(u256, 0), slot.value_ptr.*);
}

test "Database overlay: delete_account hides base storage and never writes it" {
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const address = @as([20]u8, @splat(0x64));
    try db.set_balance(address, 5);
    try db.set_storage(address, 1, 11);
    try db.set_storage(address, 2, 22);

    db.begin_ephemeral_view();
    try db.set_storage(address, 2, 23);
    try db.set_storage(address, 3, 33);

    const snapshot = try db.create_snapshot();
    try db.delete_account(address);
    try testing.expect(!db.account_exists(address));
    try testing.expect(!(try db.has_storage(address)));
    try testing.expectEqual(@as(u256, 0), try db.get_storage(address, 1));
    try testing.expectEqual(@as(u256, 0), try db.get_storage(address, 2));
    try testing.expectEqual(@as(u256, 0), try db.get_storage(address, 3));

    // Reverting inside the view brings back the view's own state.
    try db.revert_to_snapshot(snapshot);
    try testing.expectEqual(@as(u256, 11), try db.get_storage(address, 1));
    try testing.expectEqual(@as(u256, 23), try db.get_storage(address, 2));
    try testing.expectEqual(@as(u256, 33), try db.get_storage(address, 3));
    try testing.expect(try db.has_storage(address));

    try db.delete_account(address);
    db.discard_ephemeral_view();
    // Base state never changed.
    try testing.expectEqual(@as(u256, 5), try db.get_balance(address));
    try testing.expectEqual(@as(u256, 11), try db.get_storage(address, 1));
    try testing.expectEqual(@as(u256, 22), try db.get_storage(address, 2));
    try testing.expectEqual(@as(u256, 0), try db.get_storage(address, 3));
}

test "EIP-7702: set_account stores raw designator code as a delegation" {
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const eoa = @as([20]u8, @splat(0x70));
    const delegate = @as([20]u8, @splat(0x71));
    const designator = DELEGATION_PREFIX ++ delegate;

    var account = Account.zero();
    account.nonce = 1;
    account.code_hash = try db.set_code(&designator);
    try db.set_account(eoa, account);

    const stored = (try db.get_account(eoa)).?;
    try testing.expectEqualSlices(u8, &delegate, &stored.delegated_address.?.bytes);
    try testing.expectEqualSlices(u8, &ZERO_CODE_HASH, &stored.code_hash);
    try testing.expectEqual(@as(u64, 1), stored.nonce);
    try testing.expect(try db.has_delegation(eoa));
    try testing.expectEqualSlices(u8, &delegate, &stored.get_effective_code_address().?.bytes);

    // The same account as `set_delegation` produces.
    const other = @as([20]u8, @splat(0x72));
    try db.set_delegation(other, delegate);
    try testing.expectEqual((try db.get_account(other)).?.delegated_address, stored.delegated_address);
}

test "EIP-7702: set_account clears a delegation when non-designator code is set" {
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const address = @as([20]u8, @splat(0x73));
    const delegate = @as([20]u8, @splat(0x74));
    try db.set_delegation(address, delegate);

    var account = (try db.get_account(address)).?;
    account.code_hash = try db.set_code(&[_]u8{ 0x60, 0x00 });
    try db.set_account(address, account);

    const stored = (try db.get_account(address)).?;
    try testing.expectEqual(@as(?primitives.Address.Address, null), stored.delegated_address);
    try testing.expect(Account.is_code_hash_present(stored.code_hash));
}

test "EIP-7702: only exact designators are normalized" {
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const delegate = @as([20]u8, @splat(0x75));
    const short = (DELEGATION_PREFIX ++ delegate)[0..22];
    const long = DELEGATION_PREFIX ++ delegate ++ [_]u8{0x00};
    const wrong_prefix = [_]u8{ 0xef, 0x01, 0x01 } ++ delegate;

    for ([_][]const u8{ short, &long, &wrong_prefix }, 0..) |code, index| {
        const address = @as([20]u8, @splat(@intCast(0x80 + index)));
        var account = Account.zero();
        account.code_hash = try db.set_code(code);
        try db.set_account(address, account);
        const stored = (try db.get_account(address)).?;
        try testing.expectEqual(@as(?primitives.Address.Address, null), stored.delegated_address);
        try testing.expectEqualSlices(u8, code, try db.get_code(stored.code_hash));
    }
}

test "EIP-7702: designator normalization applies inside an ephemeral view" {
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const eoa = @as([20]u8, @splat(0x76));
    const delegate = @as([20]u8, @splat(0x77));
    const designator = DELEGATION_PREFIX ++ delegate;

    db.begin_ephemeral_view();
    var account = Account.zero();
    account.code_hash = try db.set_code(&designator);
    try db.set_account(eoa, account);
    try testing.expectEqualSlices(u8, &delegate, &(try db.get_account(eoa)).?.delegated_address.?.bytes);
    db.discard_ephemeral_view();
    try testing.expectEqual(@as(?Account, null), try db.get_account(eoa));
}

test "Database commit_to_depth keeps writes and leaves them undoable by outer snapshots" {
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const address = @as([20]u8, @splat(0x78));
    try db.set_storage(address, 1, 1);

    const outer = try db.create_snapshot();
    const depth = db.snapshot_depth();
    _ = try db.create_snapshot();
    try db.set_storage(address, 1, 2);
    _ = try db.create_snapshot();
    try db.set_storage(address, 1, 3);

    db.commit_to_depth(depth);
    try testing.expectEqual(depth, db.snapshot_depth());
    try testing.expectEqual(@as(u256, 3), try db.get_storage(address, 1));
    // Committing to a depth that is already reached changes nothing.
    db.commit_to_depth(depth);
    try testing.expectEqual(depth, db.snapshot_depth());

    try db.revert_to_snapshot(outer);
    try testing.expectEqual(@as(u256, 1), try db.get_storage(address, 1));

    // With no snapshot left the undo log is empty.
    _ = try db.create_snapshot();
    try db.set_storage(address, 1, 4);
    db.commit_to_depth(0);
    try testing.expectEqual(@as(usize, 0), db.undo_log.items.len);
    try testing.expectEqual(@as(u256, 4), try db.get_storage(address, 1));
}
