const std = @import("std");
const micro = @import("micro");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const Database = @import("storage_db").Database;
const Journal = @import("storage_journal").Journal(.{
    .SnapshotIdType = u32,
    .WordType = u256,
    .NonceType = u64,
    .initial_capacity = 1024,
});
const AccessList = @import("storage_access_list").AccessList;
const LruCache = @import("storage_lru").LruCache;

const N: usize = 256;

fn makeAddr(idx: usize) [20]u8 {
    var bytes = [_]u8{0} ** 20;
    std.mem.writeInt(u64, bytes[12..20], @intCast(idx + 0x1000), .big);
    return bytes;
}

fn benchDbAccountSetGet(allocator: std.mem.Allocator) !u64 {
    var db = Database.init(allocator);
    defer db.deinit();
    var acc: u64 = 0;
    for (0..N) |i| {
        const addr = makeAddr(i);
        try db.set_account(addr, .{
            .balance = @as(u256, i) * 1_000_000,
            .nonce = @intCast(i),
            .code_hash = [_]u8{0} ** 32,
            .storage_root = [_]u8{0} ** 32,
        });
    }
    for (0..N) |i| {
        const acct = (try db.get_account(makeAddr(i))) orelse return error.MissingAccount;
        acc +%= acct.nonce;
    }
    return acc;
}

fn benchDbStorageSetGet(allocator: std.mem.Allocator) !u64 {
    var db = Database.init(allocator);
    defer db.deinit();
    const addr = makeAddr(1);
    var acc: u64 = 0;
    for (0..N) |i| {
        try db.set_storage(addr, @as(u256, i), @as(u256, i *% 7 +% 3));
    }
    for (0..N) |i| {
        const val = try db.get_storage(addr, @as(u256, i));
        acc +%= @truncate(val);
    }
    return acc;
}

fn benchDbTransientStorage(allocator: std.mem.Allocator) !u64 {
    var db = Database.init(allocator);
    defer db.deinit();
    const addr = makeAddr(2);
    var acc: u64 = 0;
    for (0..N) |i| {
        try db.set_transient_storage(addr, @as(u256, i), @as(u256, i +% 42));
        acc +%= @truncate(try db.get_transient_storage(addr, @as(u256, i)));
    }
    db.clear_transient_storage();
    return acc;
}

fn benchDbSnapshotRevert(allocator: std.mem.Allocator) !u64 {
    var db = Database.init(allocator);
    defer db.deinit();
    const addr = makeAddr(3);
    for (0..64) |i| try db.set_storage(addr, @as(u256, i), @as(u256, i));
    var acc: u64 = 0;
    for (0..16) |round| {
        const snap = try db.create_snapshot();
        for (0..16) |j| try db.set_storage(addr, @as(u256, j), @as(u256, round * 100 + j));
        try db.revert_to_snapshot(snap);
        acc +%= @truncate(try db.get_storage(addr, 0));
    }
    return acc;
}

fn benchDbEphemeralOverlay(allocator: std.mem.Allocator) !u64 {
    var db = Database.init(allocator);
    defer db.deinit();
    const addr = makeAddr(4);
    for (0..64) |i| try db.set_storage(addr, @as(u256, i), @as(u256, i + 1));
    var acc: u64 = 0;
    for (0..64) |round| {
        db.begin_ephemeral_view();
        try db.set_storage(addr, @as(u256, round), 999);
        acc +%= @truncate(try db.get_storage(addr, @as(u256, round)));
        db.discard_ephemeral_view();
    }
    return acc;
}

fn benchJournalRecordRevert(allocator: std.mem.Allocator) !u64 {
    var journal = try Journal.init(allocator);
    defer journal.deinit();
    var acc: u64 = 0;
    const addr = Address{ .bytes = makeAddr(5) };
    for (0..32) |round| {
        const snap = try journal.create_snapshot();
        for (0..32) |j| {
            try journal.record_storage_change(snap, addr, @as(u256, j), @as(u256, round + j));
        }
        acc +%= journal.entry_count();
        journal.revert_to_snapshot(snap);
    }
    return acc;
}

fn benchAccessListColdWarm(allocator: std.mem.Allocator) !u64 {
    var al = AccessList.init(allocator);
    defer al.deinit();
    const contract = Address{ .bytes = makeAddr(7) };
    var gas: u64 = 0;
    for (0..N) |i| {
        gas +%= try al.access_storage_slot(contract, @as(u256, i));
    }
    for (0..N) |i| {
        gas +%= try al.access_storage_slot(contract, @as(u256, i));
    }
    return gas;
}

fn benchLruCacheChurn(allocator: std.mem.Allocator) !u64 {
    const Cache = LruCache(u64, u64, .{ .capacity = 128 });
    var cache = try Cache.init(allocator);
    defer cache.deinit();
    var acc: u64 = 0;
    for (0..N) |i| {
        _ = try cache.put(@intCast(i), @intCast(i *% 3));
    }
    for (0..N) |i| {
        if (cache.get(@intCast(i))) |v| acc +%= v;
    }
    return acc + cache.hits + cache.misses;
}

pub fn main() void {
    micro.runSuite("storage", &.{
        .{ .name = "storage/db-account-set-get", .operations = N * 2, .run = benchDbAccountSetGet },
        .{ .name = "storage/db-storage-set-get", .operations = N * 2, .run = benchDbStorageSetGet },
        .{ .name = "storage/db-transient-storage", .operations = N * 2, .run = benchDbTransientStorage },
        .{ .name = "storage/db-snapshot-revert", .operations = 16, .run = benchDbSnapshotRevert },
        .{ .name = "storage/db-ephemeral-overlay", .operations = 64, .run = benchDbEphemeralOverlay },
        .{ .name = "storage/journal-record-revert", .operations = 32 * 32, .run = benchJournalRecordRevert },
        .{ .name = "storage/access-list-cold-warm", .operations = N * 2, .run = benchAccessListColdWarm },
        .{ .name = "storage/lru-cache-churn", .operations = N * 2, .run = benchLruCacheChurn },
    });
}
