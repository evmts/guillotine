//! Ethereum state root over a `Database`: storage tries first, then the account
//! trie (Yellow Paper Appendix D, account RLP `[nonce, balance, storageRoot,
//! codeHash]`).
//!
//! The trie is built bottom-up from keys sorted once, so there is no node store
//! and no ownership graph: every intermediate buffer lives in an arena that is
//! freed before returning. The EEST state-test runner checks every post-state
//! root through this module.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Keccak256 = std.crypto.hash.sha3.Keccak256;

/// keccak256(rlp("")), the root of an empty trie.
pub const empty_trie_root = [32]u8{
    0x56, 0xe8, 0x1f, 0x17, 0x1b, 0xcc, 0x55, 0xa6, 0xff, 0x83, 0x45, 0xe6, 0x92, 0xc0, 0xf8, 0x6e,
    0x5b, 0x48, 0xe0, 0x1b, 0x99, 0x6c, 0xad, 0xc0, 0x01, 0x62, 0x2f, 0xb5, 0xe3, 0x63, 0xb4, 0x21,
};

/// keccak256(""), the code hash of an account without code.
pub const empty_code_hash = [32]u8{
    0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c, 0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0,
    0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b, 0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70,
};

const zero_hash = @as([32]u8, @splat(0));
const delegation_prefix = [_]u8{ 0xef, 0x01, 0x00 };

/// One trie leaf. Keys are 32 bytes (64 nibbles), as in the state and storage tries.
pub const TrieEntry = struct {
    key: [32]u8,
    value: []const u8,

    fn lessThan(_: void, lhs: TrieEntry, rhs: TrieEntry) bool {
        return std.mem.order(u8, &lhs.key, &rhs.key) == .lt;
    }
};

pub fn keccak(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    Keccak256.hash(bytes, &out, .{});
    return out;
}

fn rlpAppendHeader(a: Allocator, out: *std.ArrayList(u8), short_base: u8, len: usize) Allocator.Error!void {
    if (len < 56) {
        try out.append(a, short_base + @as(u8, @intCast(len)));
        return;
    }
    var be: [8]u8 = undefined;
    std.mem.writeInt(u64, &be, len, .big);
    const digits = std.mem.trimStart(u8, &be, &[_]u8{0});
    try out.append(a, short_base + 55 + @as(u8, @intCast(digits.len)));
    try out.appendSlice(a, digits);
}

fn rlpAppendBytes(a: Allocator, out: *std.ArrayList(u8), bytes: []const u8) Allocator.Error!void {
    if (bytes.len == 1 and bytes[0] < 0x80) {
        try out.append(a, bytes[0]);
        return;
    }
    try rlpAppendHeader(a, out, 0x80, bytes.len);
    try out.appendSlice(a, bytes);
}

fn rlpAppendUint(a: Allocator, out: *std.ArrayList(u8), value: u256) Allocator.Error!void {
    var be: [32]u8 = undefined;
    std.mem.writeInt(u256, &be, value, .big);
    try rlpAppendBytes(a, out, std.mem.trimStart(u8, &be, &[_]u8{0}));
}

fn rlpWrapList(a: Allocator, payload: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try rlpAppendHeader(a, &out, 0xc0, payload.len);
    try out.appendSlice(a, payload);
    return out.toOwnedSlice(a);
}

fn nibbleAt(key: *const [32]u8, index: usize) u8 {
    const byte = key[index / 2];
    return if (index % 2 == 0) byte >> 4 else byte & 0x0f;
}

/// Hex-prefix encoding of the nibbles `key[from..to]`.
fn hexPrefix(a: Allocator, key: *const [32]u8, from: usize, to: usize, leaf: bool) Allocator.Error![]u8 {
    const count = to - from;
    const out = try a.alloc(u8, count / 2 + 1);
    const flag: u8 = if (leaf) 2 else 0;
    var index = from;
    if (count % 2 == 1) {
        out[0] = ((flag | 1) << 4) | nibbleAt(key, index);
        index += 1;
    } else {
        out[0] = flag << 4;
    }
    var position: usize = 1;
    while (index < to) : (index += 2) {
        out[position] = (nibbleAt(key, index) << 4) | nibbleAt(key, index + 1);
        position += 1;
    }
    return out;
}

/// RLP encoding of the node that holds `entries`, which share the first
/// `depth` nibbles, are sorted by key, and have distinct keys.
fn trieNode(a: Allocator, entries: []const TrieEntry, depth: usize) Allocator.Error![]u8 {
    var payload: std.ArrayList(u8) = .empty;
    const first = &entries[0].key;
    if (entries.len == 1) {
        try rlpAppendBytes(a, &payload, try hexPrefix(a, first, depth, 64, true));
        try rlpAppendBytes(a, &payload, entries[0].value);
        return rlpWrapList(a, payload.items);
    }
    const last = &entries[entries.len - 1].key;
    var shared: usize = 0;
    while (depth + shared < 64 and nibbleAt(first, depth + shared) == nibbleAt(last, depth + shared)) shared += 1;
    if (shared > 0) {
        try rlpAppendBytes(a, &payload, try hexPrefix(a, first, depth, depth + shared, false));
        try trieAppendRef(a, &payload, entries, depth + shared);
        return rlpWrapList(a, payload.items);
    }
    var start: usize = 0;
    var nibble: u8 = 0;
    while (nibble < 16) : (nibble += 1) {
        var end = start;
        while (end < entries.len and nibbleAt(&entries[end].key, depth) == nibble) end += 1;
        if (end == start) {
            try payload.append(a, 0x80);
        } else {
            try trieAppendRef(a, &payload, entries[start..end], depth + 1);
        }
        start = end;
    }
    // Keys have equal length, so a branch never carries a value.
    try payload.append(a, 0x80);
    return rlpWrapList(a, payload.items);
}

/// Appends a child reference: the node itself when its encoding is shorter than
/// 32 bytes, otherwise its hash.
fn trieAppendRef(a: Allocator, out: *std.ArrayList(u8), entries: []const TrieEntry, depth: usize) Allocator.Error!void {
    const encoded = try trieNode(a, entries, depth);
    if (encoded.len < 32) {
        try out.appendSlice(a, encoded);
        return;
    }
    const digest = keccak(encoded);
    try rlpAppendBytes(a, out, &digest);
}

/// Root of the trie holding `entries`. Sorts `entries` in place. Keys must be
/// distinct. Allocations are made in `arena` and are not freed individually.
pub fn trieRoot(arena: Allocator, entries: []TrieEntry) Allocator.Error![32]u8 {
    if (entries.len == 0) return empty_trie_root;
    std.mem.sort(TrieEntry, entries, {}, TrieEntry.lessThan);
    return keccak(try trieNode(arena, entries, 0));
}

fn hasNoCode(code_hash: [32]u8) bool {
    return std.mem.eql(u8, &code_hash, &zero_hash) or std.mem.eql(u8, &code_hash, &empty_code_hash);
}

/// Code hash as the state trie sees it. A zero hash means "no code"; an EOA with
/// an EIP-7702 delegation hashes its `0xef0100 ++ address` designator.
fn accountCodeHash(account: anytype) [32]u8 {
    if (hasNoCode(account.code_hash)) {
        if (account.delegated_address) |target| {
            var code: [23]u8 = undefined;
            @memcpy(code[0..3], &delegation_prefix);
            @memcpy(code[3..23], &target.bytes);
            return keccak(&code);
        }
        return empty_code_hash;
    }
    return account.code_hash;
}

/// State root of `db`'s base layer (`db.accounts` and `db.storage`). Storage
/// roots are computed from `db.storage`; zero slots are not in the trie. The
/// `Account.storage_root` field is ignored. Uses `allocator` only for a
/// temporary arena.
pub fn stateRoot(allocator: Allocator, db: anytype) Allocator.Error![32]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const OwnedSlot = struct {
        address: [20]u8,
        entry: TrieEntry,

        fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
            return std.mem.order(u8, &lhs.address, &rhs.address) == .lt;
        }
    };
    var slots: std.ArrayList(OwnedSlot) = .empty;
    var storage_it = db.storage.iterator();
    while (storage_it.next()) |entry| {
        const value = entry.value_ptr.*;
        if (value == 0) continue;
        var key_be: [32]u8 = undefined;
        std.mem.writeInt(u256, &key_be, entry.key_ptr.key, .big);
        var encoded: std.ArrayList(u8) = .empty;
        try rlpAppendUint(a, &encoded, value);
        try slots.append(a, .{
            .address = entry.key_ptr.address,
            .entry = .{ .key = keccak(&key_be), .value = encoded.items },
        });
    }
    std.mem.sort(OwnedSlot, slots.items, {}, OwnedSlot.lessThan);

    const Range = struct { start: usize, end: usize };
    var ranges: std.AutoHashMapUnmanaged([20]u8, Range) = .empty;
    var start: usize = 0;
    while (start < slots.items.len) {
        var end = start + 1;
        while (end < slots.items.len and std.mem.eql(u8, &slots.items[end].address, &slots.items[start].address)) end += 1;
        try ranges.put(a, slots.items[start].address, .{ .start = start, .end = end });
        start = end;
    }

    var accounts: std.ArrayList(TrieEntry) = .empty;
    var account_it = db.accounts.iterator();
    while (account_it.next()) |entry| {
        const address = entry.key_ptr.*;
        const account = entry.value_ptr.*;
        var storage_root = empty_trie_root;
        if (ranges.get(address)) |range| {
            const owned = try a.alloc(TrieEntry, range.end - range.start);
            for (slots.items[range.start..range.end], owned) |slot, *target| target.* = slot.entry;
            storage_root = try trieRoot(a, owned);
        }
        var payload: std.ArrayList(u8) = .empty;
        try rlpAppendUint(a, &payload, account.nonce);
        try rlpAppendUint(a, &payload, account.balance);
        try rlpAppendBytes(a, &payload, &storage_root);
        try rlpAppendBytes(a, &payload, &accountCodeHash(account));
        try accounts.append(a, .{ .key = keccak(&address), .value = try rlpWrapList(a, payload.items) });
    }
    return trieRoot(a, accounts.items);
}
