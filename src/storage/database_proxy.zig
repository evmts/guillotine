//! Database proxy with comptime-selected access modes.
//!
//! `DatabaseProxy(mode, DatabaseType)` wraps a pointer to a database and
//! selects its behavior at compile time, so no mode branch survives to runtime:
//!
//! - `.pass_through`: every operation forwards to the inner database.
//! - `.static`: reads forward; writes return `PermissionDenied`. This encodes
//!   EIP-214 (STATICCALL) in the type system.
//! - `.lru`: persistent writes (accounts, storage, code) are buffered in the
//!   proxy and read back through it. `flush` applies them to the inner database
//!   atomically and hands the applied change set to the caller. The buffer is
//!   unbounded and never evicts. Transient storage (EIP-1153) is not persisted
//!   state, so it forwards to the inner database. State roots, snapshots,
//!   batches, and transactions would observe the inner database without the
//!   buffered writes, so they are compile errors in this mode: call `flush`
//!   first.
//!
//! The proxy stores `*DatabaseType`, never a copy. Copying a database that owns
//! hash maps and then writing through the copy diverges from, or frees memory
//! still referenced by, the original.

const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const Database = @import("database.zig").Database;
const Account = @import("database_interface_account.zig").Account;
const validate_database_implementation = @import("database.zig").validate_database_implementation;
const CallParams = @import("../frame/call_params.zig").CallParams;
const CallResult = @import("../frame/call_result.zig").CallResult;
const Hardfork = @import("../eips_and_hardforks/eips.zig").Hardfork;

const ZERO_CODE_HASH = [_]u8{0} ** 32;

pub const ProxyMode = enum {
    /// Forward every operation to the inner database.
    pass_through,
    /// Forward reads; reject writes with `PermissionDenied` (EIP-214).
    static,
    /// Buffer persistent writes in the proxy until `flush`.
    lru,
};

/// Storage slot identity used by the `.lru` write buffer.
pub const StorageKey = struct {
    address: [20]u8,
    slot: u256,
};

pub fn DatabaseProxy(comptime mode: ProxyMode, comptime DatabaseType: type) type {
    return struct {
        const Self = @This();
        pub const Error = DatabaseType.Error;
        pub const proxy_mode = mode;

        /// Writes buffered by an `.lru` proxy. `null` account values are deletions.
        /// Code values are owned by the allocator stored here.
        pub const Changes = struct {
            storage_writes: std.AutoHashMapUnmanaged(StorageKey, u256) = .{},
            account_updates: std.AutoHashMapUnmanaged([20]u8, ?Account) = .{},
            code_updates: std.AutoHashMapUnmanaged([32]u8, []const u8) = .{},

            pub fn deinit(self: *Changes, allocator: std.mem.Allocator) void {
                var code_iter = self.code_updates.valueIterator();
                while (code_iter.next()) |code| allocator.free(code.*);
                self.code_updates.deinit(allocator);
                self.account_updates.deinit(allocator);
                self.storage_writes.deinit(allocator);
            }
        };

        const Cache = if (mode == .lru) struct {
            changes: Changes = .{},
            allocator: std.mem.Allocator,
        } else void;

        /// Inner database; owned by the caller and never copied.
        inner: *DatabaseType,
        cache: Cache,

        /// `.pass_through` and `.static`: `init(inner)`.
        /// `.lru`: `init(inner, allocator)`; the allocator owns buffered writes.
        pub const init = if (mode == .lru) init_cached else init_direct;

        fn init_direct(inner: *DatabaseType) Self {
            return .{ .inner = inner, .cache = {} };
        }

        fn init_cached(inner: *DatabaseType, allocator: std.mem.Allocator) Self {
            return .{ .inner = inner, .cache = .{ .allocator = allocator } };
        }

        /// Frees buffered writes. Does not deinit the inner database.
        pub fn deinit(self: *Self) void {
            if (mode == .lru) self.cache.changes.deinit(self.cache.allocator);
        }

        fn require_flushed(comptime operation: []const u8) void {
            if (mode == .lru) @compileError(operation ++ " sees the inner database without buffered writes; call flush first");
        }

        // Account operations

        pub fn get_account(self: *Self, address: [20]u8) Error!?Account {
            if (mode == .lru) {
                if (self.cache.changes.account_updates.get(address)) |account| return account;
            }
            return self.inner.get_account(address);
        }

        pub fn set_account(self: *Self, address: [20]u8, account: Account) Error!void {
            switch (mode) {
                .pass_through => return self.inner.set_account(address, account),
                .static => return Error.PermissionDenied,
                .lru => try self.cache.changes.account_updates.put(self.cache.allocator, address, account),
            }
        }

        pub fn delete_account(self: *Self, address: [20]u8) Error!void {
            switch (mode) {
                .pass_through => return self.inner.delete_account(address),
                .static => return Error.PermissionDenied,
                .lru => try self.cache.changes.account_updates.put(self.cache.allocator, address, null),
            }
        }

        pub fn account_exists(self: *Self, address: [20]u8) bool {
            if (mode == .lru) {
                if (self.cache.changes.account_updates.get(address)) |account| return account != null;
            }
            return self.inner.account_exists(address);
        }

        pub fn get_balance(self: *Self, address: [20]u8) Error!u256 {
            if (mode != .lru) return self.inner.get_balance(address);
            const account = (try self.get_account(address)) orelse return 0;
            return account.balance;
        }

        pub fn set_balance(self: *Self, address: [20]u8, balance: u256) Error!void {
            switch (mode) {
                .pass_through => return self.inner.set_balance(address, balance),
                .static => return Error.PermissionDenied,
                .lru => {
                    var account = (try self.get_account(address)) orelse Account.zero();
                    account.balance = balance;
                    try self.set_account(address, account);
                },
            }
        }

        pub fn get_nonce(self: *Self, address: [20]u8) Error!u64 {
            if (mode != .lru) return self.inner.get_nonce(address);
            const account = (try self.get_account(address)) orelse return 0;
            return account.nonce;
        }

        pub fn set_nonce(self: *Self, address: [20]u8, nonce: u64) Error!void {
            switch (mode) {
                .pass_through => return self.inner.set_nonce(address, nonce),
                .static => return Error.PermissionDenied,
                .lru => {
                    var account = (try self.get_account(address)) orelse Account.zero();
                    account.nonce = nonce;
                    try self.set_account(address, account);
                },
            }
        }

        pub fn get_code_hash(self: *Self, address: [20]u8) Error![32]u8 {
            if (mode != .lru) return self.inner.get_code_hash(address);
            const account = (try self.get_account(address)) orelse return ZERO_CODE_HASH;
            return account.code_hash;
        }

        pub fn is_empty(self: *Self, address: [20]u8) Error!bool {
            if (mode != .lru) return self.inner.is_empty(address);
            const account = (try self.get_account(address)) orelse return true;
            return account.is_empty();
        }

        // Storage operations

        pub fn get_storage(self: *Self, address: [20]u8, key: u256) Error!u256 {
            if (mode == .lru) {
                const cache_key = StorageKey{ .address = address, .slot = key };
                if (self.cache.changes.storage_writes.get(cache_key)) |value| return value;
            }
            return self.inner.get_storage(address, key);
        }

        pub fn set_storage(self: *Self, address: [20]u8, key: u256, value: u256) Error!void {
            switch (mode) {
                .pass_through => return self.inner.set_storage(address, key, value),
                .static => return Error.PermissionDenied,
                .lru => {
                    const cache_key = StorageKey{ .address = address, .slot = key };
                    try self.cache.changes.storage_writes.put(self.cache.allocator, cache_key, value);
                },
            }
        }

        pub fn get_transient_storage(self: *Self, address: [20]u8, key: u256) Error!u256 {
            return self.inner.get_transient_storage(address, key);
        }

        pub fn set_transient_storage(self: *Self, address: [20]u8, key: u256, value: u256) Error!void {
            switch (mode) {
                .pass_through, .lru => return self.inner.set_transient_storage(address, key, value),
                .static => return Error.PermissionDenied,
            }
        }

        // Code operations

        pub fn get_code(self: *Self, code_hash: [32]u8) Error![]const u8 {
            if (mode == .lru) {
                if (self.cache.changes.code_updates.get(code_hash)) |code| return code;
            }
            return self.inner.get_code(code_hash);
        }

        /// Mirrors `Database.get_code_by_address`, including EIP-7702 delegation.
        pub fn get_code_by_address(self: *Self, address: [20]u8) Error![]const u8 {
            if (mode != .lru) return self.inner.get_code_by_address(address);
            const account = (try self.get_account(address)) orelse return Error.AccountNotFound;
            if (account.get_effective_code_address()) |delegated| {
                return self.get_code_by_address(delegated.bytes);
            }
            if (std.mem.eql(u8, &account.code_hash, &ZERO_CODE_HASH) or
                std.mem.eql(u8, &account.code_hash, &primitives.EMPTY_CODE_HASH))
            {
                return &.{};
            }
            return self.get_code(account.code_hash);
        }

        pub fn set_code(self: *Self, code: []const u8) Error![32]u8 {
            switch (mode) {
                .pass_through => return self.inner.set_code(code),
                .static => return Error.PermissionDenied,
                .lru => {
                    var hash: [32]u8 = undefined;
                    std.crypto.hash.sha3.Keccak256.hash(code, &hash, .{});
                    if (self.cache.changes.code_updates.contains(hash)) return hash;
                    if (self.inner.get_code(hash)) |_| {
                        return hash;
                    } else |err| switch (err) {
                        Error.CodeNotFound => {},
                        else => return err,
                    }
                    const allocator = self.cache.allocator;
                    const copy = try allocator.dupe(u8, code);
                    errdefer allocator.free(copy);
                    try self.cache.changes.code_updates.put(allocator, hash, copy);
                    return hash;
                },
            }
        }

        // State operations

        pub fn get_state_root(self: *Self) Error![32]u8 {
            require_flushed("get_state_root");
            return self.inner.get_state_root();
        }

        pub fn commit_changes(self: *Self) Error![32]u8 {
            require_flushed("commit_changes");
            if (mode == .static) return Error.PermissionDenied;
            return self.inner.commit_changes();
        }

        // Snapshot operations

        pub fn create_snapshot(self: *Self) Error!u64 {
            require_flushed("create_snapshot");
            return self.inner.create_snapshot();
        }

        pub fn revert_to_snapshot(self: *Self, snapshot_id: u64) Error!void {
            require_flushed("revert_to_snapshot");
            return self.inner.revert_to_snapshot(snapshot_id);
        }

        pub fn commit_snapshot(self: *Self, snapshot_id: u64) Error!void {
            require_flushed("commit_snapshot");
            if (mode == .static) return Error.PermissionDenied;
            return self.inner.commit_snapshot(snapshot_id);
        }

        // Batch operations

        pub fn begin_batch(self: *Self) Error!void {
            require_flushed("begin_batch");
            return self.inner.begin_batch();
        }

        pub fn commit_batch(self: *Self) Error!void {
            require_flushed("commit_batch");
            if (mode == .static) return Error.PermissionDenied;
            return self.inner.commit_batch();
        }

        pub fn rollback_batch(self: *Self) Error!void {
            require_flushed("rollback_batch");
            return self.inner.rollback_batch();
        }

        // Transaction operations

        pub fn begin_transaction(self: *Self) Error!u32 {
            require_flushed("begin_transaction");
            return self.inner.begin_transaction();
        }

        pub fn commit_transaction(self: *Self, id: u32) Error!void {
            require_flushed("commit_transaction");
            return self.inner.commit_transaction(id);
        }

        pub fn rollback_transaction(self: *Self, id: u32) Error!void {
            require_flushed("rollback_transaction");
            return self.inner.rollback_transaction(id);
        }

        // Write buffer (`.lru` only)

        /// Apply buffered writes to the inner database and return them.
        /// Writes apply in order code, accounts, storage inside an inner snapshot:
        /// if any write fails, the inner database reverts and the buffer is kept.
        /// The caller owns the returned changes: `changes.deinit(allocator)`.
        pub fn flush(self: *Self) Error!Changes {
            if (mode != .lru) @compileError("flush is only available in .lru mode");
            const snapshot_id = try self.inner.create_snapshot();
            self.apply(&self.cache.changes) catch |err| {
                try self.inner.revert_to_snapshot(snapshot_id);
                return err;
            };
            try self.inner.commit_snapshot(snapshot_id);
            const changes = self.cache.changes;
            self.cache.changes = .{};
            return changes;
        }

        /// Discard buffered writes without applying them.
        pub fn discard(self: *Self) void {
            if (mode != .lru) @compileError("discard is only available in .lru mode");
            self.cache.changes.deinit(self.cache.allocator);
            self.cache.changes = .{};
        }

        fn apply(self: *Self, changes: *const Changes) Error!void {
            var code_iter = changes.code_updates.valueIterator();
            while (code_iter.next()) |code| _ = try self.inner.set_code(code.*);

            var account_iter = changes.account_updates.iterator();
            while (account_iter.next()) |entry| {
                if (entry.value_ptr.*) |account| {
                    try self.inner.set_account(entry.key_ptr.*, account);
                } else {
                    try self.inner.delete_account(entry.key_ptr.*);
                }
            }

            var storage_iter = changes.storage_writes.iterator();
            while (storage_iter.next()) |entry| {
                try self.inner.set_storage(entry.key_ptr.address, entry.key_ptr.slot, entry.value_ptr.*);
            }
        }
    };
}

/// Static host implementation that blocks state modifications.
/// Implements EIP-214 constraint: STATICCALL cannot emit logs or modify state.
pub fn StaticHost(comptime HostType: type) type {
    return struct {
        const Self = @This();

        /// Underlying host for read operations
        inner: HostType,

        /// Initialize static host wrapper
        pub fn init(inner: HostType) Self {
            return Self{ .inner = inner };
        }

        // Read operations - forwarded to underlying host
        pub fn get_balance(self: *Self, address: Address) u256 {
            return self.inner.get_balance(address);
        }

        pub fn account_exists(self: *Self, address: Address) bool {
            return self.inner.account_exists(address);
        }

        pub fn get_code(self: *Self, address: Address) []const u8 {
            return self.inner.get_code(address);
        }

        pub fn get_block_info(self: *Self) @TypeOf(self.inner.get_block_info()) {
            return self.inner.get_block_info();
        }

        pub fn get_storage(self: *Self, address: Address, slot: u256) u256 {
            return self.inner.get_storage(address, slot);
        }

        pub fn get_is_static(self: *Self) bool {
            _ = self;
            return true; // Static hosts are always in static context
        }

        pub fn get_depth(self: *Self) u11 {
            return self.inner.get_depth();
        }

        pub fn get_gas_price(self: *Self) u256 {
            return self.inner.get_gas_price();
        }

        pub fn get_return_data(self: *Self) []const u8 {
            return self.inner.get_return_data();
        }

        pub fn get_chain_id(self: *Self) u64 {
            return self.inner.get_chain_id();
        }

        pub fn get_block_hash(self: *Self, block_number: u64) ?[32]u8 {
            return self.inner.get_block_hash(block_number);
        }

        pub fn get_blob_hash(self: *Self, index: u256) ?[32]u8 {
            return self.inner.get_blob_hash(index);
        }

        pub fn get_blob_base_fee(self: *Self) u256 {
            return self.inner.get_blob_base_fee();
        }

        pub fn get_tx_origin(self: *Self) Address {
            return self.inner.get_tx_origin();
        }

        pub fn get_caller(self: *Self) Address {
            return self.inner.get_caller();
        }

        pub fn get_call_value(self: *Self) u256 {
            return self.inner.get_call_value();
        }

        pub fn get_input(self: *Self) []const u8 {
            return self.inner.get_input();
        }

        pub fn is_hardfork_at_least(self: *Self, target: Hardfork) bool {
            return self.inner.is_hardfork_at_least(target);
        }

        pub fn get_hardfork(self: *Self) Hardfork {
            return self.inner.get_hardfork();
        }

        pub fn create_snapshot(self: *Self) u32 {
            return self.inner.create_snapshot();
        }

        pub fn revert_to_snapshot(self: *Self, snapshot_id: u32) void {
            return self.inner.revert_to_snapshot(snapshot_id);
        }

        pub fn record_storage_change(self: *Self, address: Address, slot: u256, original_value: u256) anyerror!void {
            return self.inner.record_storage_change(address, slot, original_value);
        }

        pub fn get_original_storage(self: *Self, address: Address, slot: u256) ?u256 {
            return self.inner.get_original_storage(address, slot);
        }

        pub fn access_address(self: *Self, address: Address) anyerror!u64 {
            return self.inner.access_address(address);
        }

        pub fn access_storage_slot(self: *Self, contract_address: Address, slot: u256) anyerror!u64 {
            return self.inner.access_storage_slot(contract_address, slot);
        }

        pub fn register_created_contract(self: *Self, address: Address) anyerror!void {
            return self.inner.register_created_contract(address);
        }

        pub fn was_created_in_tx(self: *Self, address: Address) bool {
            return self.inner.was_created_in_tx(address);
        }

        pub fn get_transient_storage(self: *Self, address: Address, slot: u256) anyerror!u256 {
            return self.inner.get_transient_storage(address, slot);
        }

        // Write operations - all throw WriteProtection errors per EIP-214

        /// EIP-214: STATICCALL cannot emit logs
        pub fn emit_log(self: *Self, contract_address: Address, topics: []const u256, data: []const u8) void {
            _ = self;
            _ = contract_address;
            _ = topics;
            _ = data;
            // Note: This should ideally return an error, but Host interface defines emit_log as void
            // The LOG handlers check get_is_static() before calling emit_log, so this is a backup
            @panic("WriteProtection: STATICCALL cannot emit logs (EIP-214)");
        }

        /// EIP-214: STATICCALL cannot modify storage
        pub fn set_storage(self: *Self, address: Address, slot: u256, value: u256) anyerror!void {
            _ = self;
            _ = address;
            _ = slot;
            _ = value;
            return error.WriteProtection;
        }

        /// EIP-214: STATICCALL cannot modify storage
        pub fn set_transient_storage(self: *Self, address: Address, slot: u256, value: u256) anyerror!void {
            _ = self;
            _ = address;
            _ = slot;
            _ = value;
            return error.WriteProtection;
        }

        /// EIP-214: STATICCALL cannot mark contracts for destruction
        pub fn mark_for_destruction(self: *Self, contract_address: Address, recipient: Address) anyerror!void {
            _ = self;
            _ = contract_address;
            _ = recipient;
            return error.WriteProtection;
        }

        /// EIP-214: STATICCALL cannot make state-modifying calls (only STATICCALL allowed)
        pub fn inner_call(self: *Self, params: CallParams) anyerror!CallResult {
            // Only allow STATICCALL - other call types would allow state modification
            switch (params) {
                .staticcall => return self.inner.inner_call(params),
                else => return error.WriteProtection,
            }
        }
    };
}

test "DatabaseProxy satisfies the database interface in every mode" {
    comptime validate_database_implementation(DatabaseProxy(.pass_through, Database));
    comptime validate_database_implementation(DatabaseProxy(.static, Database));
    comptime validate_database_implementation(DatabaseProxy(.lru, Database));
}

test "DatabaseProxy pass_through writes reach the caller's database" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    const address = [_]u8{0x11} ** 20;

    var proxy = DatabaseProxy(.pass_through, Database).init(&db);
    defer proxy.deinit();

    try proxy.set_balance(address, 100);
    try proxy.set_nonce(address, 7);
    try proxy.set_storage(address, 1, 42);
    try proxy.set_transient_storage(address, 2, 9);
    const hash = try proxy.set_code(&[_]u8{ 0x60, 0x00 });

    try std.testing.expectEqual(@as(u256, 100), try db.get_balance(address));
    try std.testing.expectEqual(@as(u64, 7), try db.get_nonce(address));
    try std.testing.expectEqual(@as(u256, 42), try db.get_storage(address, 1));
    try std.testing.expectEqual(@as(u256, 9), try db.get_transient_storage(address, 2));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x60, 0x00 }, try db.get_code(hash));

    const snapshot = try proxy.create_snapshot();
    try proxy.set_storage(address, 1, 43);
    try proxy.revert_to_snapshot(snapshot);
    try std.testing.expectEqual(@as(u256, 42), try db.get_storage(address, 1));

    try proxy.delete_account(address);
    try std.testing.expect(!db.account_exists(address));
}

test "DatabaseProxy static rejects every write and reads live inner state" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    const address = [_]u8{0x22} ** 20;

    var proxy = DatabaseProxy(.static, Database).init(&db);
    defer proxy.deinit();

    // Writes made to the inner database after wrapping are visible: the proxy holds a pointer.
    try db.set_balance(address, 5);
    try db.set_storage(address, 3, 4);
    try std.testing.expectEqual(@as(u256, 5), try proxy.get_balance(address));
    try std.testing.expectEqual(@as(u256, 4), try proxy.get_storage(address, 3));
    try std.testing.expect(proxy.account_exists(address));

    const denied = Database.Error.PermissionDenied;
    try std.testing.expectError(denied, proxy.set_account(address, Account.zero()));
    try std.testing.expectError(denied, proxy.delete_account(address));
    try std.testing.expectError(denied, proxy.set_balance(address, 100));
    try std.testing.expectError(denied, proxy.set_nonce(address, 1));
    try std.testing.expectError(denied, proxy.set_storage(address, 3, 42));
    try std.testing.expectError(denied, proxy.set_transient_storage(address, 3, 42));
    try std.testing.expectError(denied, proxy.set_code(&[_]u8{0x00}));
    try std.testing.expectError(denied, proxy.commit_changes());
    try std.testing.expectError(denied, proxy.commit_batch());
    const snapshot = try proxy.create_snapshot();
    try std.testing.expectError(denied, proxy.commit_snapshot(snapshot));
    try proxy.revert_to_snapshot(snapshot);

    try std.testing.expectEqual(@as(u256, 5), try db.get_balance(address));
    try std.testing.expectEqual(@as(u256, 4), try db.get_storage(address, 3));
}

test "DatabaseProxy lru buffers writes until flush" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    const kept = [_]u8{0x33} ** 20;
    const deleted = [_]u8{0x44} ** 20;
    const code = [_]u8{ 0x60, 0x01, 0x00 };

    try db.set_balance(kept, 10);
    try db.set_storage(kept, 1, 11);
    try db.set_balance(deleted, 20);

    var proxy = DatabaseProxy(.lru, Database).init(&db, std.testing.allocator);
    defer proxy.deinit();

    // Unbuffered reads fall through to the inner database.
    try std.testing.expectEqual(@as(u256, 10), try proxy.get_balance(kept));
    try std.testing.expectEqual(@as(u256, 11), try proxy.get_storage(kept, 1));

    try proxy.set_balance(kept, 99);
    try proxy.set_nonce(kept, 3);
    try proxy.set_storage(kept, 1, 12);
    try proxy.set_storage(kept, 2, 13);
    try proxy.delete_account(deleted);
    const hash = try proxy.set_code(&code);
    var account = (try proxy.get_account(kept)).?;
    account.code_hash = hash;
    try proxy.set_account(kept, account);

    // The proxy reads its own writes.
    try std.testing.expectEqual(@as(u256, 99), try proxy.get_balance(kept));
    try std.testing.expectEqual(@as(u64, 3), try proxy.get_nonce(kept));
    try std.testing.expectEqual(@as(u256, 12), try proxy.get_storage(kept, 1));
    try std.testing.expectEqual(@as(u256, 13), try proxy.get_storage(kept, 2));
    try std.testing.expect(!proxy.account_exists(deleted));
    try std.testing.expectEqual(@as(?Account, null), try proxy.get_account(deleted));
    try std.testing.expect(try proxy.is_empty(deleted));
    try std.testing.expectEqual(hash, try proxy.get_code_hash(kept));
    try std.testing.expectEqualSlices(u8, &code, try proxy.get_code(hash));
    try std.testing.expectEqualSlices(u8, &code, try proxy.get_code_by_address(kept));

    // The inner database is untouched before flush.
    try std.testing.expectEqual(@as(u256, 10), try db.get_balance(kept));
    try std.testing.expectEqual(@as(u64, 0), try db.get_nonce(kept));
    try std.testing.expectEqual(@as(u256, 11), try db.get_storage(kept, 1));
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(kept, 2));
    try std.testing.expect(db.account_exists(deleted));
    try std.testing.expectError(Database.Error.CodeNotFound, db.get_code(hash));

    var changes = try proxy.flush();
    defer changes.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 2), changes.storage_writes.count());
    try std.testing.expectEqual(@as(?u256, 12), changes.storage_writes.get(.{ .address = kept, .slot = 1 }));
    try std.testing.expectEqual(@as(?u256, 13), changes.storage_writes.get(.{ .address = kept, .slot = 2 }));
    try std.testing.expectEqual(@as(u32, 2), changes.account_updates.count());
    try std.testing.expectEqual(@as(?Account, null), changes.account_updates.get(deleted).?);
    try std.testing.expectEqual(@as(u32, 1), changes.code_updates.count());

    try std.testing.expectEqual(@as(u256, 99), try db.get_balance(kept));
    try std.testing.expectEqual(@as(u64, 3), try db.get_nonce(kept));
    try std.testing.expectEqual(@as(u256, 12), try db.get_storage(kept, 1));
    try std.testing.expectEqual(@as(u256, 13), try db.get_storage(kept, 2));
    try std.testing.expect(!db.account_exists(deleted));
    try std.testing.expectEqualSlices(u8, &code, try db.get_code_by_address(kept));

    // The buffer is empty after flush; reads see the inner database again.
    try db.set_storage(kept, 1, 50);
    try std.testing.expectEqual(@as(u256, 50), try proxy.get_storage(kept, 1));
    var empty = try proxy.flush();
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), empty.storage_writes.count());
    try std.testing.expectEqual(@as(u32, 0), empty.account_updates.count());
    try std.testing.expectEqual(@as(u32, 0), empty.code_updates.count());
}

test "DatabaseProxy lru set_code does not buffer code the inner database already has" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    const code = [_]u8{ 0x60, 0x02 };
    const stored = try db.set_code(&code);

    var proxy = DatabaseProxy(.lru, Database).init(&db, std.testing.allocator);
    defer proxy.deinit();

    try std.testing.expectEqual(stored, try proxy.set_code(&code));
    try std.testing.expectEqual(stored, try proxy.set_code(&code));
    try std.testing.expectEqual(@as(u32, 0), proxy.cache.changes.code_updates.count());
}

test "DatabaseProxy lru discard drops buffered writes" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    const address = [_]u8{0x55} ** 20;

    var proxy = DatabaseProxy(.lru, Database).init(&db, std.testing.allocator);
    defer proxy.deinit();

    try proxy.set_storage(address, 1, 2);
    _ = try proxy.set_code(&[_]u8{0x01});
    proxy.discard();

    try std.testing.expectEqual(@as(u256, 0), try proxy.get_storage(address, 1));
    var changes = try proxy.flush();
    defer changes.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), changes.storage_writes.count());
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(address, 1));
}

test "DatabaseProxy lru flush reverts the inner database when a write fails" {
    const FailingStorage = struct {
        const Self = @This();
        pub const Error = Database.Error;
        db: *Database,

        pub fn get_account(self: *Self, address: [20]u8) Error!?Account {
            return self.db.get_account(address);
        }
        pub fn set_account(self: *Self, address: [20]u8, account: Account) Error!void {
            return self.db.set_account(address, account);
        }
        pub fn delete_account(self: *Self, address: [20]u8) Error!void {
            return self.db.delete_account(address);
        }
        pub fn get_code(self: *Self, hash: [32]u8) Error![]const u8 {
            return self.db.get_code(hash);
        }
        pub fn set_code(self: *Self, code: []const u8) Error![32]u8 {
            return self.db.set_code(code);
        }
        pub fn get_storage(self: *Self, address: [20]u8, key: u256) Error!u256 {
            return self.db.get_storage(address, key);
        }
        pub fn set_storage(self: *Self, address: [20]u8, key: u256, value: u256) Error!void {
            _ = self;
            _ = address;
            _ = key;
            _ = value;
            return Error.NetworkError;
        }
        pub fn create_snapshot(self: *Self) Error!u64 {
            return self.db.create_snapshot();
        }
        pub fn revert_to_snapshot(self: *Self, id: u64) Error!void {
            return self.db.revert_to_snapshot(id);
        }
        pub fn commit_snapshot(self: *Self, id: u64) Error!void {
            return self.db.commit_snapshot(id);
        }
    };

    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    var inner = FailingStorage{ .db = &db };
    const address = [_]u8{0x66} ** 20;
    try db.set_balance(address, 1);

    var proxy = DatabaseProxy(.lru, FailingStorage).init(&inner, std.testing.allocator);
    defer proxy.deinit();

    try proxy.set_balance(address, 2);
    try proxy.set_storage(address, 1, 3);
    try std.testing.expectError(Database.Error.NetworkError, proxy.flush());

    // The account write applied before the storage failure is reverted.
    try std.testing.expectEqual(@as(u256, 1), try db.get_balance(address));
    // The buffer survives so the caller can retry or discard.
    try std.testing.expectEqual(@as(u256, 2), try proxy.get_balance(address));
    try std.testing.expectEqual(@as(u256, 3), try proxy.get_storage(address, 1));
}
