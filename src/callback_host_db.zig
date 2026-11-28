//! C-callback-backed `DatabaseType` for embedding Guillotine against external
//! state stores (RPC forks, LevelDB/MDBX/Pebble, custom Go/Rust/Python/Node hosts).
//!
//! Lazily fetches accounts, contract bytecode, and storage slots from caller-provided
//! C callbacks and caches them in an in-memory `Database` overlay so snapshots,
//! nested call reverts, `simulate()`, and `dumpState()` work without extra host
//! round-trips or leaking reverted writes.

const std = @import("std");
const Database = @import("storage/database.zig").Database;
const Account = @import("storage/database_interface_account.zig").Account;

/// Account metadata returned by `GuillotineHostVTable.get_account`.
pub const GuillotineHostAccount = extern struct {
    /// Account balance as 32-byte big-endian u256.
    balance: [32]u8,
    /// Account nonce.
    nonce: u64,
    /// True if the account exists in host state; false for absent/empty accounts.
    exists: bool,
};

/// C callback table for external read-through state loading.
///
/// Any callback may be NULL to treat that domain as empty (defaulting to the
/// local overlay populated via `guillotine_set_*`). Returning `false` from
/// `get_account` or `get_storage` signals a host I/O error and aborts execution
/// with a host failure rather than silently treating the state as zero.
pub const GuillotineHostVTable = extern struct {
    /// Populate `*out` for `address`. Return `true` on success (even when
    /// `out->exists == false`), or `false` on host I/O failure.
    get_account: ?*const fn (
        ctx: ?*anyopaque,
        address: *const [20]u8,
        out: *GuillotineHostAccount,
    ) callconv(.c) bool = null,
    /// Populate `*value_out` (big-endian u256) for `(address, key)`. Return `true`
    /// on success (zero-fill when absent), or `false` on host I/O failure.
    get_storage: ?*const fn (
        ctx: ?*anyopaque,
        address: *const [20]u8,
        key: *const [32]u8,
        value_out: *[32]u8,
    ) callconv(.c) bool = null,
    /// Query or copy contract bytecode for `address`. When `buf == NULL` or
    /// `buf_len == 0`, return the full bytecode length in bytes. Otherwise copy up
    /// to `buf_len` bytes into `buf` and return the number of bytes copied.
    get_code: ?*const fn (
        ctx: ?*anyopaque,
        address: *const [20]u8,
        buf: ?[*]u8,
        buf_len: usize,
    ) callconv(.c) usize = null,
};

/// Read-through caching database backed by a `GuillotineHostVTable`.
pub const CallbackHostDb = struct {
    pub const Error = Database.Error;

    const SlotKey = struct { address: [20]u8, key: u256 };

    inner: Database,
    vtable: GuillotineHostVTable,
    user_ctx: ?*anyopaque,
    loaded_accounts: std.AutoHashMap([20]u8, void),
    loaded_storage: std.AutoHashMap(SlotKey, void),
    failure: ?Error = null,
    views: std.ArrayList(View) = .empty,

    const View = struct {
        accounts: std.AutoHashMap([20]u8, void),
        storage: std.AutoHashMap(SlotKey, void),
    };

    pub fn begin_ephemeral_view(self: *CallbackHostDb) Error!void {
        try self.views.ensureUnusedCapacity(self.inner.allocator, 1);
        var accounts = try self.loaded_accounts.clone();
        errdefer accounts.deinit();
        var storage = try self.loaded_storage.clone();
        errdefer storage.deinit();
        try self.inner.begin_ephemeral_view();
        self.views.appendAssumeCapacity(.{ .accounts = accounts, .storage = storage });
    }

    pub fn discard_ephemeral_view(self: *CallbackHostDb) void {
        const saved = self.views.pop() orelse return;
        self.inner.discard_ephemeral_view();
        self.loaded_accounts.deinit();
        self.loaded_storage.deinit();
        self.loaded_accounts = saved.accounts;
        self.loaded_storage = saved.storage;
    }

    pub fn init(allocator: std.mem.Allocator, vtable: GuillotineHostVTable, user_ctx: ?*anyopaque) CallbackHostDb {
        return .{
            .inner = Database.init(allocator),
            .vtable = vtable,
            .user_ctx = user_ctx,
            .loaded_accounts = std.AutoHashMap([20]u8, void).init(allocator),
            .loaded_storage = std.AutoHashMap(SlotKey, void).init(allocator),
        };
    }

    pub fn deinit(self: *CallbackHostDb) void {
        while (self.views.items.len != 0) self.discard_ephemeral_view();
        self.views.deinit(self.inner.allocator);
        self.loaded_accounts.deinit();
        self.loaded_storage.deinit();
        self.inner.deinit();
    }

    fn noteFailure(self: *CallbackHostDb, err: Error) Error {
        if (self.failure == null) self.failure = err;
        return err;
    }

    fn ensureAccountLoaded(self: *CallbackHostDb, address: [20]u8) Error!void {
        if (self.loaded_accounts.contains(address)) return;
        const get_acc = self.vtable.get_account orelse {
            try self.loaded_accounts.put(address, {});
            return;
        };
        var raw = GuillotineHostAccount{ .balance = @splat(0), .nonce = 0, .exists = false };
        if (!get_acc(self.user_ctx, &address, &raw)) {
            return self.noteFailure(error.DatabaseCorrupted);
        }
        try self.loaded_accounts.put(address, {});
        if (!raw.exists) return;

        var code_hash: [32]u8 = @splat(0);
        if (self.vtable.get_code) |get_code_fn| {
            const code_len = get_code_fn(self.user_ctx, &address, null, 0);
            if (code_len > 0) {
                const buf = self.inner.allocator.alloc(u8, code_len) catch return self.noteFailure(error.OutOfMemory);
                defer self.inner.allocator.free(buf);
                const copied = get_code_fn(self.user_ctx, &address, buf.ptr, code_len);
                const actual_len = @min(copied, code_len);
                code_hash = try self.inner.set_code(buf[0..actual_len]);
            }
        }
        try self.inner.set_account(address, .{
            .balance = std.mem.readInt(u256, &raw.balance, .big),
            .nonce = raw.nonce,
            .code_hash = code_hash,
            .storage_root = @splat(0),
        });
    }

    fn ensureStorageLoaded(self: *CallbackHostDb, address: [20]u8, key: u256) Error!void {
        const sk = SlotKey{ .address = address, .key = key };
        if (self.loaded_storage.contains(sk)) return;
        const get_slot = self.vtable.get_storage orelse {
            try self.loaded_storage.put(sk, {});
            return;
        };
        var key_be: [32]u8 = undefined;
        std.mem.writeInt(u256, &key_be, key, .big);
        var val_be: [32]u8 = @splat(0);
        if (!get_slot(self.user_ctx, &address, &key_be, &val_be)) {
            return self.noteFailure(error.DatabaseCorrupted);
        }
        try self.loaded_storage.put(sk, {});
        const val = std.mem.readInt(u256, &val_be, .big);
        if (val != 0) try self.inner.set_storage(address, key, val);
    }

    pub fn get_account(self: *CallbackHostDb, address: [20]u8) Error!?Account {
        try self.ensureAccountLoaded(address);
        return self.inner.get_account(address);
    }

    pub fn set_account(self: *CallbackHostDb, address: [20]u8, account: Account) Error!void {
        try self.loaded_accounts.put(address, {});
        return self.inner.set_account(address, account);
    }

    pub fn delete_account(self: *CallbackHostDb, address: [20]u8) Error!void {
        try self.loaded_accounts.put(address, {});
        return self.inner.delete_account(address);
    }

    pub fn account_exists(self: *CallbackHostDb, address: [20]u8) bool {
        self.ensureAccountLoaded(address) catch return false;
        return self.inner.account_exists(address);
    }

    pub fn get_balance(self: *CallbackHostDb, address: [20]u8) Error!u256 {
        try self.ensureAccountLoaded(address);
        return self.inner.get_balance(address);
    }

    pub fn set_balance(self: *CallbackHostDb, address: [20]u8, balance: u256) Error!void {
        try self.ensureAccountLoaded(address);
        return self.inner.set_balance(address, balance);
    }

    pub fn get_storage(self: *CallbackHostDb, address: [20]u8, key: u256) Error!u256 {
        try self.ensureStorageLoaded(address, key);
        return self.inner.get_storage(address, key);
    }

    pub fn read_storage(self: *CallbackHostDb, address: [20]u8, key: u256) u256 {
        return self.get_storage(address, key) catch 0;
    }

    pub fn set_storage(self: *CallbackHostDb, address: [20]u8, key: u256, value: u256) Error!void {
        try self.loaded_storage.put(.{ .address = address, .key = key }, {});
        return self.inner.set_storage(address, key, value);
    }

    pub fn has_storage(self: *CallbackHostDb, address: [20]u8) Error!bool {
        return self.inner.has_storage(address);
    }

    pub fn clear_account_storage(self: *CallbackHostDb, address: [20]u8) Error!void {
        return self.inner.clear_account_storage(address);
    }

    pub fn get_transient_storage(self: *CallbackHostDb, address: [20]u8, key: u256) Error!u256 {
        return self.inner.get_transient_storage(address, key);
    }

    pub fn set_transient_storage(self: *CallbackHostDb, address: [20]u8, key: u256, value: u256) Error!void {
        return self.inner.set_transient_storage(address, key, value);
    }

    pub fn clear_transient_storage(self: *CallbackHostDb) void {
        self.inner.clear_transient_storage();
    }

    pub fn get_code(self: *CallbackHostDb, code_hash: [32]u8) Error![]const u8 {
        return self.inner.get_code(code_hash);
    }

    pub fn set_code(self: *CallbackHostDb, code: []const u8) Error![32]u8 {
        return self.inner.set_code(code);
    }

    pub fn create_snapshot(self: *CallbackHostDb) Error!u64 {
        return self.inner.create_snapshot();
    }

    pub fn revert_to_snapshot(self: *CallbackHostDb, id: u64) Error!void {
        return self.inner.revert_to_snapshot(id);
    }

    pub fn commit_snapshot(self: *CallbackHostDb, id: u64) Error!void {
        return self.inner.commit_snapshot(id);
    }

    pub fn snapshot_depth(self: *const CallbackHostDb) usize {
        return self.inner.snapshot_depth();
    }

    pub fn commit_to_depth(self: *CallbackHostDb, depth: usize) void {
        self.inner.commit_to_depth(depth);
    }

    pub fn revert_to_depth(self: *CallbackHostDb, depth: usize) void {
        self.inner.revert_to_depth(depth);
    }
};

test "CallbackHostDb lazily loads accounts, code, and storage once and caches" {
    const Mock = struct {
        account_calls: usize = 0,
        storage_calls: usize = 0,
        code_calls: usize = 0,
        fail_next: bool = false,

        fn getAccount(raw: ?*anyopaque, addr: *const [20]u8, out: *GuillotineHostAccount) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.account_calls += 1;
            if (self.fail_next) return false;
            if (addr[19] == 0xAA) {
                std.mem.writeInt(u256, &out.balance, 9_000, .big);
                out.nonce = 7;
                out.exists = true;
            } else {
                out.exists = false;
            }
            return true;
        }

        fn getStorage(raw: ?*anyopaque, _: *const [20]u8, key: *const [32]u8, out: *[32]u8) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.storage_calls += 1;
            if (self.fail_next) return false;
            const k = std.mem.readInt(u256, key, .big);
            std.mem.writeInt(u256, out, k + 100, .big);
            return true;
        }

        fn getCode(raw: ?*anyopaque, addr: *const [20]u8, buf: ?[*]u8, buf_len: usize) callconv(.c) usize {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.code_calls += 1;
            if (addr[19] != 0xAA) return 0;
            const bytecode = [_]u8{ 0x60, 0x01, 0x00 };
            if (buf == null or buf_len == 0) return bytecode.len;
            const n = @min(buf_len, bytecode.len);
            @memcpy(buf.?[0..n], bytecode[0..n]);
            return n;
        }
    };

    var mock = Mock{};
    var db = CallbackHostDb.init(std.testing.allocator, .{
        .get_account = Mock.getAccount,
        .get_storage = Mock.getStorage,
        .get_code = Mock.getCode,
    }, &mock);
    defer db.deinit();

    var addr: [20]u8 = @splat(0);
    addr[19] = 0xAA;

    const acc1 = (try db.get_account(addr)).?;
    try std.testing.expectEqual(@as(u256, 9_000), acc1.balance);
    try std.testing.expectEqual(@as(u64, 7), acc1.nonce);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x60, 0x01, 0x00 }, try db.get_code(acc1.code_hash));

    // Second read hits cache; host is not called again.
    _ = try db.get_account(addr);
    try std.testing.expectEqual(@as(usize, 1), mock.account_calls);

    // Storage lazy read + cache
    try std.testing.expectEqual(@as(u256, 105), try db.get_storage(addr, 5));
    try std.testing.expectEqual(@as(u256, 105), try db.get_storage(addr, 5));
    try std.testing.expectEqual(@as(usize, 1), mock.storage_calls);

    // Host failure records db.failure and propagates error.
    mock.fail_next = true;
    try std.testing.expectError(error.DatabaseCorrupted, db.get_storage(addr, 6));
    try std.testing.expectEqual(@as(?CallbackHostDb.Error, error.DatabaseCorrupted), db.failure);
}
