//! EVMC v12 host adapter implementing Guillotine's `EvmConfig.DatabaseType`.

const std = @import("std");
const evm = @import("evm");
const types = @import("evmc_types.zig");

const EvmcAddress = types.EvmcAddress;
const EvmcBytes32 = types.EvmcBytes32;
const EvmcHostContext = types.EvmcHostContext;
const EvmcHostInterface = types.EvmcHostInterface;

pub fn bytes32ToU256(b: EvmcBytes32) u256 {
    return std.mem.readInt(u256, &b.bytes, .big);
}

pub fn u256ToBytes32(v: u256) EvmcBytes32 {
    var out: EvmcBytes32 = undefined;
    std.mem.writeInt(u256, &out.bytes, v, .big);
    return out;
}

/// Bridges an `evmc_host_interface` into Guillotine's `EvmConfig.DatabaseType`.
/// Reads lazily from the EVMC host, keeps local snapshot/undo semantics for nested
/// frames, and flushes net storage/transient mutations back to the host on success.
pub const EvmcHostDb = struct {
    pub const Error = evm.Database.Error;

    inner: evm.Database,
    host: ?*const EvmcHostInterface,
    ctx: ?*EvmcHostContext,
    loaded_accounts: std.AutoHashMap([20]u8, void),
    loaded_storage: std.AutoHashMap(SlotKey, void),
    dirty_storage: std.AutoHashMap(SlotKey, u256),
    dirty_transient: std.AutoHashMap(SlotKey, u256),
    failure: ?Error = null,

    const SlotKey = struct { address: [20]u8, key: u256 };

    pub fn init(allocator: std.mem.Allocator, host: ?*const EvmcHostInterface, ctx: ?*EvmcHostContext) EvmcHostDb {
        return .{
            .inner = evm.Database.init(allocator),
            .host = host,
            .ctx = ctx,
            .loaded_accounts = std.AutoHashMap([20]u8, void).init(allocator),
            .loaded_storage = std.AutoHashMap(SlotKey, void).init(allocator),
            .dirty_storage = std.AutoHashMap(SlotKey, u256).init(allocator),
            .dirty_transient = std.AutoHashMap(SlotKey, u256).init(allocator),
        };
    }

    pub fn deinit(self: *EvmcHostDb) void {
        self.loaded_accounts.deinit();
        self.loaded_storage.deinit();
        self.dirty_storage.deinit();
        self.dirty_transient.deinit();
        self.inner.deinit();
    }

    fn ensureAccountLoaded(self: *EvmcHostDb, address: [20]u8) Error!void {
        if (self.loaded_accounts.contains(address)) return;
        try self.loaded_accounts.put(address, {});
        const host = self.host orelse return;
        const c_addr = EvmcAddress{ .bytes = address };
        if (!host.account_exists(self.ctx, &c_addr)) return;
        const bal = bytes32ToU256(host.get_balance(self.ctx, &c_addr));
        const code_len = host.get_code_size(self.ctx, &c_addr);
        var code_hash: [32]u8 = @splat(0);
        if (code_len > 0) {
            const buf = self.inner.allocator.alloc(u8, code_len) catch return error.OutOfMemory;
            defer self.inner.allocator.free(buf);
            const copied = host.copy_code(self.ctx, &c_addr, 0, buf.ptr, code_len);
            code_hash = try self.inner.set_code(buf[0..copied]);
        }
        try self.inner.set_account(address, .{
            .balance = bal,
            .nonce = 0,
            .code_hash = code_hash,
            .storage_root = @splat(0),
        });
    }

    pub fn get_account(self: *EvmcHostDb, address: [20]u8) Error!?evm.Account {
        try self.ensureAccountLoaded(address);
        return self.inner.get_account(address);
    }

    pub fn set_account(self: *EvmcHostDb, address: [20]u8, account: evm.Account) Error!void {
        try self.loaded_accounts.put(address, {});
        return self.inner.set_account(address, account);
    }

    pub fn delete_account(self: *EvmcHostDb, address: [20]u8) Error!void {
        try self.loaded_accounts.put(address, {});
        return self.inner.delete_account(address);
    }

    pub fn account_exists(self: *EvmcHostDb, address: [20]u8) bool {
        self.ensureAccountLoaded(address) catch return false;
        return self.inner.account_exists(address);
    }

    pub fn get_balance(self: *EvmcHostDb, address: [20]u8) Error!u256 {
        try self.ensureAccountLoaded(address);
        return self.inner.get_balance(address);
    }

    pub fn set_balance(self: *EvmcHostDb, address: [20]u8, balance: u256) Error!void {
        try self.ensureAccountLoaded(address);
        return self.inner.set_balance(address, balance);
    }

    pub fn read_storage(self: *EvmcHostDb, address: [20]u8, key: u256) u256 {
        return self.get_storage(address, key) catch 0;
    }

    pub fn get_storage(self: *EvmcHostDb, address: [20]u8, key: u256) Error!u256 {
        const sk = SlotKey{ .address = address, .key = key };
        if (!self.loaded_storage.contains(sk)) {
            try self.loaded_storage.put(sk, {});
            if (self.host) |host| {
                const c_addr = EvmcAddress{ .bytes = address };
                const c_key = u256ToBytes32(key);
                const val = bytes32ToU256(host.get_storage(self.ctx, &c_addr, &c_key));
                if (val != 0) try self.inner.set_storage(address, key, val);
            }
        }
        return self.inner.get_storage(address, key);
    }

    pub fn set_storage(self: *EvmcHostDb, address: [20]u8, key: u256, value: u256) Error!void {
        const sk = SlotKey{ .address = address, .key = key };
        try self.loaded_storage.put(sk, {});
        try self.dirty_storage.put(sk, value);
        return self.inner.set_storage(address, key, value);
    }

    pub fn has_storage(self: *EvmcHostDb, address: [20]u8) Error!bool {
        return self.inner.has_storage(address);
    }

    pub fn clear_account_storage(self: *EvmcHostDb, address: [20]u8) Error!void {
        return self.inner.clear_account_storage(address);
    }

    pub fn get_transient_storage(self: *EvmcHostDb, address: [20]u8, key: u256) Error!u256 {
        const sk = SlotKey{ .address = address, .key = key };
        if (self.dirty_transient.contains(sk)) return self.inner.get_transient_storage(address, key);
        if (self.host) |host| {
            const c_addr = EvmcAddress{ .bytes = address };
            const c_key = u256ToBytes32(key);
            return bytes32ToU256(host.get_transient_storage(self.ctx, &c_addr, &c_key));
        }
        return self.inner.get_transient_storage(address, key);
    }

    pub fn set_transient_storage(self: *EvmcHostDb, address: [20]u8, key: u256, value: u256) Error!void {
        const sk = SlotKey{ .address = address, .key = key };
        try self.dirty_transient.put(sk, value);
        return self.inner.set_transient_storage(address, key, value);
    }

    pub fn clear_transient_storage(self: *EvmcHostDb) void {
        self.dirty_transient.clearRetainingCapacity();
        self.inner.clear_transient_storage();
    }

    pub fn get_code(self: *EvmcHostDb, code_hash: [32]u8) Error![]const u8 {
        return self.inner.get_code(code_hash);
    }
    pub fn set_code(self: *EvmcHostDb, code: []const u8) Error![32]u8 {
        return self.inner.set_code(code);
    }
    pub fn create_snapshot(self: *EvmcHostDb) Error!u64 {
        return self.inner.create_snapshot();
    }
    pub fn revert_to_snapshot(self: *EvmcHostDb, id: u64) Error!void {
        return self.inner.revert_to_snapshot(id);
    }
    pub fn commit_snapshot(self: *EvmcHostDb, id: u64) Error!void {
        return self.inner.commit_snapshot(id);
    }
    pub fn snapshot_depth(self: *const EvmcHostDb) usize {
        return self.inner.snapshot_depth();
    }
    pub fn commit_to_depth(self: *EvmcHostDb, depth: usize) void {
        self.inner.commit_to_depth(depth);
    }
    pub fn revert_to_depth(self: *EvmcHostDb, depth: usize) void {
        self.inner.revert_to_depth(depth);
    }

    /// Flush net committed storage and transient writes back to the EVMC host.
    pub fn flushToHost(self: *EvmcHostDb) void {
        const host = self.host orelse return;
        var st_it = self.dirty_storage.iterator();
        while (st_it.next()) |entry| {
            const c_addr = EvmcAddress{ .bytes = entry.key_ptr.address };
            const c_key = u256ToBytes32(entry.key_ptr.key);
            const cur = self.inner.get_storage(entry.key_ptr.address, entry.key_ptr.key) catch continue;
            const c_val = u256ToBytes32(cur);
            _ = host.set_storage(self.ctx, &c_addr, &c_key, &c_val);
        }
        var tr_it = self.dirty_transient.iterator();
        while (tr_it.next()) |entry| {
            const c_addr = EvmcAddress{ .bytes = entry.key_ptr.address };
            const c_key = u256ToBytes32(entry.key_ptr.key);
            const cur = self.inner.get_transient_storage(entry.key_ptr.address, entry.key_ptr.key) catch continue;
            const c_val = u256ToBytes32(cur);
            host.set_transient_storage(self.ctx, &c_addr, &c_key, &c_val);
        }
    }
};

test "EvmcHostDb stores and retrieves local storage without a host" {
    var db = EvmcHostDb.init(std.testing.allocator, null, null);
    defer db.deinit();
    const addr: [20]u8 = @splat(0x22);
    try db.set_storage(addr, 3, 99);
    try std.testing.expectEqual(@as(u256, 99), try db.get_storage(addr, 3));
}
