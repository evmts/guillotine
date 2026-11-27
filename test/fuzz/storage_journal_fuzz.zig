//! Stateful Storage, Database, Journal, Snapshot, AccessList, SelfDestruct,
//! Ephemeral View, and Transaction Cache Fuzz Tests
//!
//! Verifies every state-management subsystem against an independent, brute-force
//! deep-copy reference model under arbitrary operation & nested snapshot/revert sequences.

const std = @import("std");
const evm = @import("evm");
const fuzz_alloc = @import("fuzz_alloc.zig");
const primitives = @import("voltaire");

const Database = evm.Database;
const Account = evm.Account;
const AccessList = evm.AccessList;
const Address = primitives.Address.Address;

const NUM_ACCOUNTS = 6;
const NUM_SLOTS = 6;

fn makeAddr(idx: u8) [20]u8 {
    var bytes = @as([20]u8, @splat(0));
    bytes[19] = (idx % NUM_ACCOUNTS) + 1;
    return bytes;
}

const RefAccount = struct {
    exists: bool = false,
    balance: u256 = 0,
    nonce: u64 = 0,
    code_hash: [32]u8 = @as([32]u8, @splat(0)),
};

const RefState = struct {
    accounts: [NUM_ACCOUNTS]RefAccount = @as([NUM_ACCOUNTS]RefAccount, @splat(.{})),
    storage: [NUM_ACCOUNTS][NUM_SLOTS]u256 = @as([NUM_ACCOUNTS][NUM_SLOTS]u256, @splat(@as([NUM_SLOTS]u256, @splat(0)))),
    transient: [NUM_ACCOUNTS][NUM_SLOTS]u256 = @as([NUM_ACCOUNTS][NUM_SLOTS]u256, @splat(@as([NUM_SLOTS]u256, @splat(0)))),
};

fn verifyDbMatchesRef(db: *Database, ref: *const RefState) !void {
    for (0..NUM_ACCOUNTS) |a_idx| {
        const addr = makeAddr(@intCast(a_idx));
        const r = ref.accounts[a_idx];
        const actual_acc = try db.get_account(addr);
        if (!r.exists) {
            try std.testing.expect(actual_acc == null);
            try std.testing.expectEqual(@as(u256, 0), try db.get_balance(addr));
            try std.testing.expectEqual(@as(u64, 0), try db.get_nonce(addr));
        } else {
            try std.testing.expect(actual_acc != null);
            try std.testing.expectEqual(r.balance, actual_acc.?.balance);
            try std.testing.expectEqual(r.nonce, actual_acc.?.nonce);
            try std.testing.expectEqualSlices(u8, &r.code_hash, &actual_acc.?.code_hash);
        }
        for (0..NUM_SLOTS) |s_idx| {
            const actual_val = try db.get_storage(addr, @intCast(s_idx));
            try std.testing.expectEqual(ref.storage[a_idx][s_idx], actual_val);
        }
    }
}

pub fn fuzzDatabaseSnapshotsAndViews(_: void, input: []const u8) !void {
    const allocator = fuzz_alloc.get();
    var db = Database.init(allocator);
    defer db.deinit();

    var ref = RefState{};

    // Snapshot stack storing (snapshot_id, RefState copy)
    const SnapEntry = struct { id: u64, state: RefState };
    var snaps = std.ArrayList(SnapEntry).empty;
    defer snaps.deinit(allocator);

    var i: usize = 0;
    while (i + 3 <= input.len) : (i += 3) {
        const op = input[i];
        const a_idx: usize = input[i + 1] % NUM_ACCOUNTS;
        const addr = makeAddr(@intCast(a_idx));
        const val_byte = input[i + 2];
        const slot_idx: usize = val_byte % NUM_SLOTS;

        switch (op % 11) {
            0 => { // set_account
                const acc = Account{
                    .balance = @as(u256, val_byte) * 1000,
                    .nonce = val_byte,
                    .code_hash = @as([32]u8, @splat(0)),
                    .storage_root = @as([32]u8, @splat(0)),
                };
                try db.set_account(addr, acc);
                ref.accounts[a_idx] = .{
                    .exists = true,
                    .balance = acc.balance,
                    .nonce = acc.nonce,
                    .code_hash = acc.code_hash,
                };
            },
            1 => { // set_balance
                const bal: u256 = (@as(u256, val_byte) << 64) | @as(u256, op);
                try db.set_balance(addr, bal);
                ref.accounts[a_idx].exists = true;
                ref.accounts[a_idx].balance = bal;
            },
            2 => { // set_nonce
                const nonce: u64 = @as(u64, val_byte) + 1;
                try db.set_nonce(addr, nonce);
                ref.accounts[a_idx].exists = true;
                ref.accounts[a_idx].nonce = nonce;
            },
            3 => { // set_code + attach to account
                const code = [_]u8{ 0x60, val_byte, 0x00 };
                const code_hash = try db.set_code(&code);
                const fetched = try db.get_code(code_hash);
                try std.testing.expectEqualSlices(u8, &code, fetched);
                var acc = (try db.get_account(addr)) orelse Account.zero();
                acc.code_hash = code_hash;
                try db.set_account(addr, acc);
                ref.accounts[a_idx] = .{
                    .exists = true,
                    .balance = acc.balance,
                    .nonce = acc.nonce,
                    .code_hash = code_hash,
                };
            },
            4 => { // set_storage
                const val: u256 = if (val_byte < 32) 0 else (@as(u256, val_byte) << 128) | @as(u256, a_idx);
                try db.set_storage(addr, @intCast(slot_idx), val);
                ref.storage[a_idx][slot_idx] = val;
            },
            5 => { // delete_account (removes the account and its storage)
                try db.delete_account(addr);
                ref.accounts[a_idx] = .{};
                ref.storage[a_idx] = @splat(0);
            },
            6 => { // create_snapshot (up to depth 6)
                if (snaps.items.len < 6) {
                    const snap_id = try db.create_snapshot();
                    try snaps.append(allocator, .{ .id = snap_id, .state = ref });
                }
            },
            7 => { // revert_to_snapshot
                if (snaps.items.len > 0) {
                    const target_pos = val_byte % snaps.items.len;
                    const snap = snaps.items[target_pos];
                    try db.revert_to_snapshot(snap.id);
                    ref = snap.state;
                    snaps.items.len = target_pos;
                }
            },
            8 => { // commit_snapshot (topmost)
                if (snaps.items.len > 0) {
                    const snap = snaps.pop().?;
                    try db.commit_snapshot(snap.id);
                }
            },
            9 => { // Ephemeral view (simulate() isolation invariant!)
                db.begin_ephemeral_view();
                try db.set_balance(addr, 0xdeadbeefcafebabe);
                try db.set_storage(addr, @intCast(slot_idx), 0x123456789abcdef0);
                try std.testing.expectEqual(@as(u256, 0xdeadbeefcafebabe), try db.get_balance(addr));
                try std.testing.expectEqual(@as(u256, 0x123456789abcdef0), try db.get_storage(addr, @intCast(slot_idx)));
                db.discard_ephemeral_view();
                // Base state must be 100% untouched after discard!
            },
            else => { // Transient storage roundtrip & clear
                const tval: u256 = (@as(u256, val_byte) << 8) | op;
                try db.set_transient_storage(addr, @intCast(slot_idx), tval);
                try std.testing.expectEqual(tval, try db.get_transient_storage(addr, @intCast(slot_idx)));
                if (val_byte < 16) {
                    db.clear_transient_storage();
                    try std.testing.expectEqual(@as(u256, 0), try db.get_transient_storage(addr, @intCast(slot_idx)));
                }
            },
        }

        try verifyDbMatchesRef(&db, &ref);
    }
}

pub fn fuzzJournalOriginalStorageIndex(_: void, input: []const u8) !void {
    const allocator = fuzz_alloc.get();
    const JournalType = evm.Evm(.{}).Journal;
    var journal = try JournalType.init(allocator);
    defer journal.deinit();

    // Independent flat log of (snap_id, addr_idx, slot_idx, original_value)
    const LogEntry = struct { snap_id: JournalType.SnapshotIdType, addr_idx: u8, slot_idx: u8, orig: u256 };
    var ref_log = std.ArrayList(LogEntry).empty;
    defer ref_log.deinit(allocator);

    var snaps = std.ArrayList(JournalType.SnapshotIdType).empty;
    defer snaps.deinit(allocator);

    var current_snap: JournalType.SnapshotIdType = 0;

    var i: usize = 0;
    while (i + 3 <= input.len) : (i += 3) {
        const op = input[i];
        const a_idx: u8 = input[i + 1] % NUM_ACCOUNTS;
        const s_idx: u8 = input[i + 2] % NUM_SLOTS;
        const addr = Address{ .bytes = makeAddr(a_idx) };

        switch (op % 5) {
            0, 1 => { // record_storage_change
                const orig: u256 = (@as(u256, op) << 16) | (@as(u256, input[i + 2]) << 8) | a_idx;
                try journal.record_storage_change(current_snap, addr, s_idx, orig);
                try ref_log.append(allocator, .{ .snap_id = current_snap, .addr_idx = a_idx, .slot_idx = s_idx, .orig = orig });
            },
            2 => { // create_snapshot
                if (snaps.items.len < 16) {
                    const id = try journal.create_snapshot();
                    try snaps.append(allocator, id);
                    current_snap = id;
                }
            },
            3 => { // revert_to_snapshot
                if (snaps.items.len > 0) {
                    const idx = input[i + 2] % snaps.items.len;
                    const target_id = snaps.items[idx];
                    journal.revert_to_snapshot(target_id);
                    // Remove all entries with snap_id >= target_id
                    var write_pos: usize = 0;
                    for (ref_log.items) |entry| {
                        if (entry.snap_id < target_id) {
                            ref_log.items[write_pos] = entry;
                            write_pos += 1;
                        }
                    }
                    ref_log.items.len = write_pos;
                    snaps.items.len = idx;
                    current_snap = if (snaps.items.len > 0) snaps.items[snaps.items.len - 1] else 0;
                }
            },
            else => { // record balance/nonce change to mix entry types in journal
                try journal.record_balance_change(current_snap, addr, input[i + 2]);
            },
        }

        // Verify O(1) journal.get_original_storage matches brute-force scan of oldest entry in ref_log!
        for (0..NUM_ACCOUNTS) |ai| {
            for (0..NUM_SLOTS) |si| {
                var expected: ?u256 = null;
                for (ref_log.items) |entry| {
                    if (entry.addr_idx == ai and entry.slot_idx == si) {
                        expected = entry.orig;
                        break;
                    }
                }
                const actual = journal.get_original_storage(Address{ .bytes = makeAddr(@intCast(ai)) }, si);
                try std.testing.expectEqual(expected, actual);
            }
        }
    }
}

pub fn fuzzAccessListWarmCold(_: void, input: []const u8) !void {
    const allocator = fuzz_alloc.get();
    var al = AccessList.init(allocator);
    defer al.deinit();

    var ref_addrs = @as([NUM_ACCOUNTS]bool, @splat(false));
    var ref_slots = @as([NUM_ACCOUNTS][NUM_SLOTS]bool, @splat(@as([NUM_SLOTS]bool, @splat(false))));

    var i: usize = 0;
    while (i + 2 <= input.len) : (i += 2) {
        const op = input[i];
        const a_idx = input[i + 1] % NUM_ACCOUNTS;
        const s_idx = (input[i + 1] >> 3) % NUM_SLOTS;
        const addr = Address{ .bytes = makeAddr(a_idx) };

        switch (op % 4) {
            0 => { // access_address
                const cost = try al.access_address(addr);
                const expected_cost = if (ref_addrs[a_idx]) AccessList.WARM_ACCOUNT_ACCESS_COST else AccessList.COLD_ACCOUNT_ACCESS_COST;
                try std.testing.expectEqual(expected_cost, cost);
                ref_addrs[a_idx] = true;
                try std.testing.expect(al.is_address_warm(addr));
            },
            1 => { // access_storage_slot
                const cost = try al.access_storage_slot(addr, s_idx);
                const expected_cost = if (ref_slots[a_idx][s_idx]) AccessList.WARM_SLOAD_COST else AccessList.COLD_SLOAD_COST;
                try std.testing.expectEqual(expected_cost, cost);
                ref_slots[a_idx][s_idx] = true;
                try std.testing.expect(al.is_storage_slot_warm(addr, s_idx));
            },
            2 => { // clone must preserve exact warm/cold state
                var cloned = try al.clone();
                defer cloned.deinit();
                for (0..NUM_ACCOUNTS) |ai| {
                    const a = Address{ .bytes = makeAddr(@intCast(ai)) };
                    try std.testing.expectEqual(ref_addrs[ai], cloned.is_address_warm(a));
                    for (0..NUM_SLOTS) |si| {
                        try std.testing.expectEqual(ref_slots[ai][si], cloned.is_storage_slot_warm(a, si));
                    }
                }
            },
            else => { // clear
                if (input[i + 1] < 16) {
                    al.clear();
                    ref_addrs = @as([NUM_ACCOUNTS]bool, @splat(false));
                    ref_slots = @as([NUM_ACCOUNTS][NUM_SLOTS]bool, @splat(@as([NUM_SLOTS]bool, @splat(false))));
                }
            },
        }
    }
}

/// Storage as the slot-store model sees it: base slots, the overlay's slots (null:
/// the overlay has no entry and the base shows through) and which view the
/// overlay belongs to.
const SlotModel = struct {
    base: [NUM_ACCOUNTS][NUM_SLOTS]u256 = @as([NUM_ACCOUNTS][NUM_SLOTS]u256, @splat(@as([NUM_SLOTS]u256, @splat(0)))),
    overlay: [NUM_ACCOUNTS][NUM_SLOTS]?u256 = @as([NUM_ACCOUNTS][NUM_SLOTS]?u256, @splat(@as([NUM_SLOTS]?u256, @splat(null)))),
    /// Number of times a view was entered or left so far. A snapshot's overlay
    /// part can be restored only while no view has been entered or left since.
    epoch: u32 = 0,

    fn visible(self: *const SlotModel, active: bool, account: usize, slot: usize) u256 {
        if (active) {
            if (self.overlay[account][slot]) |value| return value;
        }
        return self.base[account][slot];
    }
};

/// `SlotStore` (per-address key list and non-zero count), `zeroSlots`, overlay
/// shadowing and the overlay's dirty flags, against a model, under nested
/// snapshots that stay open across ephemeral views.
pub fn fuzzSlotStoreAndOverlayDirtiness(_: void, input: []const u8) !void {
    const allocator = fuzz_alloc.get();
    var db = Database.init(allocator);
    defer db.deinit();

    var model = SlotModel{};
    var active = false;
    var snapshots: [6]SlotModel = undefined;
    var snapshot_ids: [6]u64 = undefined;
    var depth: usize = 0;

    var i: usize = 0;
    while (i + 2 < input.len) : (i += 3) {
        const account: usize = input[i + 1] % NUM_ACCOUNTS;
        const slot: usize = input[i + 2] % NUM_SLOTS;
        const address = makeAddr(@intCast(account));
        switch (input[i] % 9) {
            0, 1, 2 => { // SSTORE; a third of the writes store zero
                const value: u256 = if (input[i + 2] % 3 == 0) 0 else @as(u256, input[i + 2]) + 1;
                try db.set_storage(address, slot, value);
                if (active) {
                    model.overlay[account][slot] = value;
                } else {
                    model.base[account][slot] = value;
                }
            },
            3 => { // clear the account's storage (SELFDESTRUCT, account deletion)
                try db.clear_account_storage(address);
                for (0..NUM_SLOTS) |s| {
                    if (!active) {
                        model.base[account][s] = 0;
                    } else if (model.visible(true, account, s) != 0) {
                        model.overlay[account][s] = 0;
                    }
                }
            },
            4 => { // enter a view: the overlay starts empty
                if (!active) {
                    db.begin_ephemeral_view();
                    active = true;
                    model.epoch += 1;
                    model.overlay = @as([NUM_ACCOUNTS][NUM_SLOTS]?u256, @splat(@as([NUM_SLOTS]?u256, @splat(null))));
                    try std.testing.expect(db.overlayIsClean());
                }
            },
            5 => { // leave the view: everything it wrote is gone
                if (active) {
                    db.discard_ephemeral_view();
                    active = false;
                    model.epoch += 1;
                    model.overlay = @as([NUM_ACCOUNTS][NUM_SLOTS]?u256, @splat(@as([NUM_SLOTS]?u256, @splat(null))));
                    try std.testing.expect(db.overlayIsClean());
                }
            },
            6 => { // open a snapshot
                if (depth < snapshots.len) {
                    snapshot_ids[depth] = try db.create_snapshot();
                    snapshots[depth] = model;
                    depth += 1;
                }
            },
            7 => { // revert to the newest snapshot
                if (depth > 0) {
                    depth -= 1;
                    try db.revert_to_snapshot(snapshot_ids[depth]);
                    const saved = snapshots[depth];
                    model.base = saved.base;
                    // Overlay writes of a view that has since been left were dropped
                    // with it; a view entered after the snapshot is undone back to
                    // empty. Either way the overlay holds nothing.
                    model.overlay = if (saved.epoch == model.epoch)
                        saved.overlay
                    else
                        @as([NUM_ACCOUNTS][NUM_SLOTS]?u256, @splat(@as([NUM_SLOTS]?u256, @splat(null))));
                }
            },
            else => { // commit the newest snapshot
                if (depth > 0) {
                    depth -= 1;
                    try db.commit_snapshot(snapshot_ids[depth]);
                }
            },
        }

        // The database and the model agree after every operation.
        var overlay_entries: usize = 0;
        for (0..NUM_ACCOUNTS) |a| {
            const a_address = makeAddr(@intCast(a));
            var base_non_zero: usize = 0;
            var visible_non_zero = false;
            for (0..NUM_SLOTS) |s| {
                try std.testing.expectEqual(model.visible(active, a, s), try db.get_storage(a_address, s));
                if (model.base[a][s] != 0) base_non_zero += 1;
                if (model.visible(active, a, s) != 0) visible_non_zero = true;
                if (model.overlay[a][s] != null) overlay_entries += 1;
            }
            try std.testing.expectEqual(base_non_zero, db.storage.nonZeroCount(a_address));
            try std.testing.expectEqual(visible_non_zero, try db.has_storage(a_address));
            // The key list names each held slot once.
            const keys = db.storage.keysOf(a_address);
            try std.testing.expect(keys.len <= NUM_SLOTS);
            for (keys, 0..) |key, index| {
                try std.testing.expect(key < NUM_SLOTS);
                try std.testing.expect(std.mem.indexOfScalar(u256, keys[0..index], key) == null);
            }
        }
        try std.testing.expectEqual(overlay_entries, db.overlay_storage.count());
        // A clean overlay holds nothing; a view that is not active shows nothing.
        if (db.overlayIsClean()) try std.testing.expectEqual(@as(usize, 0), db.overlay_storage.count());
        if (!active) try std.testing.expectEqual(@as(usize, 0), overlay_entries);
    }
}

const slot_store_corpus: []const []const u8 = &.{
    &.{},
    &.{ 0, 0, 1, 0, 0, 2, 0, 0, 3, 3, 0, 0 }, // writes, a zero write, then clear
    &.{ 0, 1, 1, 4, 0, 0, 0, 1, 3, 0, 1, 2, 5, 0, 0, 0, 1, 4 }, // a view shadows and is discarded
    &.{ 6, 0, 0, 0, 2, 1, 4, 0, 0, 0, 2, 2, 3, 2, 0, 5, 0, 0, 7, 0, 0 }, // snapshot open across a view
    &.{ 0, 3, 1, 0, 3, 2, 6, 0, 0, 3, 3, 0, 7, 0, 0, 6, 0, 0, 3, 3, 0, 8, 0, 0 }, // clear under revert and commit
    &.{ 4, 0, 0, 6, 0, 0, 0, 4, 1, 3, 4, 0, 7, 0, 0, 5, 0, 0, 4, 0, 0, 5, 0, 0 }, // revert inside a view, re-enter
    &.{ 6, 0, 0, 4, 0, 0, 0, 5, 1, 5, 0, 0, 4, 0, 0, 0, 5, 2, 7, 0, 0, 5, 0, 0 }, // revert past a discarded view
};

const seed_corpus: []const []const u8 = &.{
    &.{},
    &.{ 0, 0, 10, 4, 0, 40, 6, 0, 0, 1, 0, 99, 4, 0, 50, 7, 0, 0 },
    &.{ 0, 1, 5, 6, 0, 0, 3, 1, 7, 6, 0, 0, 5, 1, 0, 7, 0, 1, 8, 0, 0 },
    &.{ 1, 0, 20, 9, 0, 3, 10, 0, 4, 10, 0, 5, 4, 0, 10 },
    &.{ 0, 0, 1, 2, 0, 0, 0, 0, 2, 2, 0, 0, 0, 0, 3, 3, 0, 0, 3, 0, 0 },
};

test "fuzz database nested snapshots, ephemeral views, and storage model" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzDatabaseSnapshotsAndViews), .{ .corpus = seed_corpus });
}

test "fuzz journal O(1) original storage index vs brute-force log under nested reverts" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzJournalOriginalStorageIndex), .{ .corpus = seed_corpus });
}

test "fuzz EIP-2929 access list warm/cold gas accounting and cloning" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzAccessListWarmCold), .{ .corpus = seed_corpus });
}

test "fuzz slot store counts, zeroSlots, overlay shadowing and overlay dirtiness" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzSlotStoreAndOverlayDirtiness), .{ .corpus = slot_store_corpus });
}

test "storage_db: slot store model holds for pseudo-random operation streams" {
    var prng = std.Random.DefaultPrng.init(0x736c6f74);
    const random = prng.random();
    var input: [600]u8 = undefined;
    for (0..40) |_| {
        random.bytes(&input);
        try fuzzSlotStoreAndOverlayDirtiness({}, &input);
    }
}

// Found by `zig build fuzz-campaign` (seed 1795676221327508486, iteration 47):
// set_storage on account 1, then delete_account(1). The reference model kept
// the deleted account's storage while Database.delete_account clears it.
test "storage_db: delete_account clears storage under snapshots" {
    const input = [_]u8{
        0xdd, 0x70, 0x52, 0x71, 0x40, 0xf5, 0xe8, 0xb3, 0xad, 0x88, 0xf7, 0x73, 0x53, 0xec, 0xea, 0xc5,
        0xdd, 0x9b, 0xee, 0x35, 0x3d, 0xeb, 0x5a, 0x14, 0xce, 0x42, 0x49, 0x62, 0x19, 0x49, 0x22, 0x77,
        0xd8, 0xe4, 0x42, 0x32, 0x09, 0x28, 0x41, 0x52, 0xd3, 0x7b, 0xcc, 0xd1, 0x16, 0x3d, 0xeb, 0x5a,
        0x14, 0xce, 0x42, 0x49, 0x62, 0x19, 0x49, 0x22, 0x77, 0xd8, 0xe4, 0x42, 0x32,
    };
    try fuzzDatabaseSnapshotsAndViews({}, &input);
}
