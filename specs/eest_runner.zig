//! Strict runner for the official pre-filled Ethereum Execution Spec Tests
//! (EEST) `state_tests/**/*.json` fixtures.
//!
//! For every test, every supported fork and every `post[fork][i]` entry the
//! runner loads the pre-state, validates the transaction, executes it on the
//! Guillotine EVM, finalizes the transaction (refunds, fees, selfdestructs,
//! EIP-161 cleanup), then compares the exact Merkle Patricia Trie state root
//! and the RLP logs hash with the fixture. A case passes only when both hashes
//! match, or when an expected invalid-transaction exception is raised and the
//! untouched pre-state hashes to the expected root.
//!
//! Configuration (a command-line flag overrides the environment variable):
//!   EEST_FIXTURES_DIR  --fixtures=<dir>   fixture root (default
//!                                         .cache/eest-fixtures/current/fixtures/state_tests)
//!   EEST_FORK          --fork=<a,b>       run only these forks
//!   EEST_FILTER        --filter=<text>    substring of "<file>::<test name>"
//!   EEST_REPORT_JSON   --report=<path>    write the JSON summary here
//!   EEST_JOBS          --jobs=<n>         worker processes (0 = in-process)
//!   EEST_TIMEOUT_SECS  --timeout=<secs>   per-case limit for worker processes
//!   EEST_VERBOSE       --verbose          print every failure, keep worker stderr
//!
//! Process model: the parent starts `jobs` copies of itself as workers. Each
//! worker owns a shard of the sorted file list and streams one line per case.
//! A worker that crashes or exceeds the time limit costs exactly one case: the
//! parent records it as `crash` or `timeout` and restarts the worker after it.
//!
//! Exit code: 0 all cases passed, 1 at least one failure, 2 usage error.

const std = @import("std");
const builtin = @import("builtin");

/// Process-wide I/O and environment, set once at the start of `main`.
var io: std.Io = undefined;
var environ_map: *const std.process.Environ.Map = undefined;
const evm = @import("evm");
const crypto = @import("crypto");

const primitives = evm.Primitives;
const Database = evm.Database;
const Account = evm.Account;
const Keccak256 = std.crypto.hash.sha3.Keccak256;
const Allocator = std.mem.Allocator;

const default_fixtures_dir = ".cache/eest-fixtures/current/fixtures/state_tests";
const report_schema = "guillotine-eest-report/v1";
const max_fixture_bytes = 1 << 30;
const examples_per_reason = 5;
const worker_stack_bytes = 1 << 30;

// ---------------------------------------------------------------------------
// Forks
// ---------------------------------------------------------------------------

pub const Fork = enum {
    Frontier,
    Homestead,
    TangerineWhistle,
    SpuriousDragon,
    Byzantium,
    Constantinople,
    ConstantinopleFix,
    Istanbul,
    Berlin,
    London,
    Paris,
    Shanghai,
    Cancun,
    Prague,
    Osaka,

    const Alias = struct { name: []const u8, fork: Fork };
    const aliases = [_]Alias{
        .{ .name = "EIP150", .fork = .TangerineWhistle },
        .{ .name = "EIP158", .fork = .SpuriousDragon },
        .{ .name = "Petersburg", .fork = .ConstantinopleFix },
        .{ .name = "Merge", .fork = .Paris },
    };

    pub fn parse(name: []const u8) ?Fork {
        for (std.meta.tags(Fork)) |fork| {
            if (std.ascii.eqlIgnoreCase(name, @tagName(fork))) return fork;
        }
        for (aliases) |alias| {
            if (std.ascii.eqlIgnoreCase(name, alias.name)) return alias.fork;
        }
        return null;
    }

    pub fn hardfork(comptime self: Fork) evm.Hardfork {
        return switch (self) {
            .Frontier => .FRONTIER,
            .Homestead => .HOMESTEAD,
            .TangerineWhistle => .TANGERINE_WHISTLE,
            .SpuriousDragon => .SPURIOUS_DRAGON,
            .Byzantium => .BYZANTIUM,
            .Constantinople => .CONSTANTINOPLE,
            .ConstantinopleFix => .PETERSBURG,
            .Istanbul => .ISTANBUL,
            .Berlin => .BERLIN,
            .London => .LONDON,
            .Paris => .MERGE,
            .Shanghai => .SHANGHAI,
            .Cancun => .CANCUN,
            .Prague => .PRAGUE,
            .Osaka => .OSAKA,
        };
    }

    pub fn atLeast(self: Fork, other: Fork) bool {
        return @intFromEnum(self) >= @intFromEnum(other);
    }
};

const ForkSet = std.EnumSet(Fork);

/// One Guillotine EVM type per fork. The hardfork is a comptime parameter of
/// the EVM, so every fork is a separate instantiation.
fn VmFor(comptime fork: Fork) type {
    return evm.Evm(.{
        .eips = .{ .hardfork = fork.hardfork() },
        // Fixtures use transaction gas limits far above 30M.
        .block_gas_limit = std.math.maxInt(i64),
        .loop_quota = null,
        // State tests run one transaction and no block-level system calls.
        .enable_beacon_roots = false,
        .enable_historical_block_hashes = false,
        .enable_validator_deposits = false,
        .enable_validator_withdrawals = false,
    });
}

// ---------------------------------------------------------------------------
// Hex and JSON access (strict)
// ---------------------------------------------------------------------------

fn hexDigits(text: []const u8) ![]const u8 {
    if (text.len < 2 or text[0] != '0' or (text[1] != 'x' and text[1] != 'X')) return error.MissingHexPrefix;
    return text[2..];
}

fn parseU256(text: []const u8) !u256 {
    const digits = std.mem.trimStart(u8, try hexDigits(text), "0");
    if (digits.len == 0) return 0;
    if (digits.len > 64) return error.HexValueTooLarge;
    return std.fmt.parseInt(u256, digits, 16);
}

fn parseU64(text: []const u8) !u64 {
    const value = try parseU256(text);
    if (value > std.math.maxInt(u64)) return error.HexValueTooLarge;
    return @intCast(value);
}

fn parseBytes(a: Allocator, text: []const u8) ![]u8 {
    const digits = try hexDigits(text);
    if (digits.len % 2 != 0) return error.OddHexLength;
    const out = try a.alloc(u8, digits.len / 2);
    _ = try std.fmt.hexToBytes(out, digits);
    return out;
}

fn parseFixed(comptime n: usize, text: []const u8) ![n]u8 {
    const digits = try hexDigits(text);
    if (digits.len != n * 2) return error.WrongHexLength;
    var out: [n]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, digits);
    return out;
}

fn hexAlloc(a: Allocator, bytes: []const u8) ![]u8 {
    const alphabet = "0123456789abcdef";
    const out = try a.alloc(u8, 2 + bytes.len * 2);
    out[0] = '0';
    out[1] = 'x';
    for (bytes, 0..) |byte, i| {
        out[2 + i * 2] = alphabet[byte >> 4];
        out[3 + i * 2] = alphabet[byte & 0x0f];
    }
    return out;
}

fn asObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.ExpectedJsonObject,
    };
}

fn asArray(value: std.json.Value) ![]const std.json.Value {
    return switch (value) {
        .array => |array| array.items,
        else => error.ExpectedJsonArray,
    };
}

fn asString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |string| string,
        else => error.ExpectedJsonString,
    };
}

fn asIndex(value: std.json.Value) !usize {
    return switch (value) {
        .integer => |integer| if (integer < 0) error.NegativeIndex else @intCast(integer),
        else => error.ExpectedJsonInteger,
    };
}

fn field(object: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return object.get(name) orelse error.MissingField;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return asString(try field(object, name));
}

// ---------------------------------------------------------------------------
// RLP
// ---------------------------------------------------------------------------

fn rlpAppendHeader(a: Allocator, out: *std.ArrayList(u8), short_base: u8, len: usize) !void {
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

fn rlpAppendBytes(a: Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    if (bytes.len == 1 and bytes[0] < 0x80) {
        try out.append(a, bytes[0]);
        return;
    }
    try rlpAppendHeader(a, out, 0x80, bytes.len);
    try out.appendSlice(a, bytes);
}

fn rlpAppendUint(a: Allocator, out: *std.ArrayList(u8), value: u256) !void {
    var be: [32]u8 = undefined;
    std.mem.writeInt(u256, &be, value, .big);
    try rlpAppendBytes(a, out, std.mem.trimStart(u8, &be, &[_]u8{0}));
}

fn rlpWrapList(a: Allocator, payload: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try rlpAppendHeader(a, &out, 0xc0, payload.len);
    try out.appendSlice(a, payload);
    return out.toOwnedSlice(a);
}

const RlpItem = struct {
    is_list: bool,
    payload: []const u8,
    /// Bytes consumed, header included.
    size: usize,
};

fn rlpDecode(data: []const u8) !RlpItem {
    if (data.len == 0) return error.RlpTruncated;
    const first = data[0];
    if (first < 0x80) return .{ .is_list = false, .payload = data[0..1], .size = 1 };
    const is_list = first >= 0xc0;
    const base: u8 = if (is_list) 0xc0 else 0x80;
    const tag = first - base;
    var header: usize = 1;
    var len: usize = tag;
    if (tag > 55) {
        const len_bytes: usize = tag - 55;
        if (data.len < 1 + len_bytes) return error.RlpTruncated;
        len = 0;
        for (data[1 .. 1 + len_bytes]) |byte| len = (len << 8) | byte;
        header += len_bytes;
    }
    if (data.len - header < len) return error.RlpTruncated;
    return .{ .is_list = is_list, .payload = data[header .. header + len], .size = header + len };
}

/// State tests carry no ancestor headers. The reference consumers (geth `evm
/// statetest`, `vmTestBlockHash`) define the hash of block `n` as keccak256 of its
/// decimal string, so BLOCKHASH(0) from block 1 is keccak256("0").
/// Returns the 256 hashes before `number`, newest first.
fn stateTestBlockHashes(a: std.mem.Allocator, number: u64) ![]const [32]u8 {
    const count: usize = @intCast(@min(number, 256));
    const hashes = try a.alloc([32]u8, count);
    var buf: [20]u8 = undefined;
    for (hashes, 0..) |*hash, i| {
        const ancestor = number - 1 - @as(u64, @intCast(i));
        hash.* = keccak(try std.fmt.bufPrint(&buf, "{d}", .{ancestor}));
    }
    return hashes;
}

fn keccak(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    Keccak256.hash(bytes, &out, .{});
    return out;
}

// ---------------------------------------------------------------------------
// Merkle Patricia Trie root over fixed 32-byte keys
// ---------------------------------------------------------------------------

const TrieEntry = struct {
    key: [32]u8,
    value: []const u8,

    fn lessThan(_: void, lhs: TrieEntry, rhs: TrieEntry) bool {
        return std.mem.order(u8, &lhs.key, &rhs.key) == .lt;
    }
};

const empty_trie_root = [32]u8{
    0x56, 0xe8, 0x1f, 0x17, 0x1b, 0xcc, 0x55, 0xa6, 0xff, 0x83, 0x45, 0xe6, 0x92, 0xc0, 0xf8, 0x6e,
    0x5b, 0x48, 0xe0, 0x1b, 0x99, 0x6c, 0xad, 0xc0, 0x01, 0x62, 0x2f, 0xb5, 0xe3, 0x63, 0xb4, 0x21,
};

fn nibbleAt(key: *const [32]u8, index: usize) u8 {
    const byte = key[index / 2];
    return if (index % 2 == 0) byte >> 4 else byte & 0x0f;
}

/// Hex-prefix encoding of the nibbles `key[from..to]`.
fn hexPrefix(a: Allocator, key: *const [32]u8, from: usize, to: usize, leaf: bool) ![]u8 {
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
/// `depth` nibbles and are sorted by key.
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

fn trieAppendRef(a: Allocator, out: *std.ArrayList(u8), entries: []const TrieEntry, depth: usize) Allocator.Error!void {
    const encoded = try trieNode(a, entries, depth);
    if (encoded.len < 32) {
        try out.appendSlice(a, encoded);
        return;
    }
    const digest = keccak(encoded);
    try rlpAppendBytes(a, out, &digest);
}

/// Root of the trie holding `entries`. Sorts `entries` in place.
fn trieRoot(a: Allocator, entries: []TrieEntry) Allocator.Error![32]u8 {
    if (entries.len == 0) return empty_trie_root;
    std.mem.sort(TrieEntry, entries, {}, TrieEntry.lessThan);
    return keccak(try trieNode(a, entries, 0));
}

// ---------------------------------------------------------------------------
// Account helpers on top of the Guillotine Database
// ---------------------------------------------------------------------------

const zero_hash = @as([32]u8, @splat(0));
const delegation_prefix = [_]u8{ 0xef, 0x01, 0x00 };

fn emptyCodeHash() [32]u8 {
    return keccak(&[_]u8{});
}

fn hasNoCode(account: Account) bool {
    return std.mem.eql(u8, &account.code_hash, &zero_hash) or std.mem.eql(u8, &account.code_hash, &emptyCodeHash());
}

fn isEmptyAccount(account: Account) bool {
    return account.nonce == 0 and account.balance == 0 and hasNoCode(account) and account.delegated_address == null;
}

fn delegationCode(target: [20]u8) [23]u8 {
    var code: [23]u8 = undefined;
    @memcpy(code[0..3], &delegation_prefix);
    @memcpy(code[3..23], &target);
    return code;
}

/// Code of an account as the state trie sees it.
fn accountCode(a: Allocator, db: *Database, account: Account) ![]const u8 {
    if (hasNoCode(account)) {
        if (account.delegated_address) |target| return a.dupe(u8, &delegationCode(target.bytes));
        return &[_]u8{};
    }
    return db.get_code(account.code_hash);
}

fn accountCodeHash(account: Account) [32]u8 {
    if (hasNoCode(account)) {
        if (account.delegated_address) |target| return keccak(&delegationCode(target.bytes));
        return emptyCodeHash();
    }
    return account.code_hash;
}

fn accountOrZero(db: *Database, address: [20]u8) !Account {
    return (try db.get_account(address)) orelse Account.zero();
}

/// Removes an account and every storage slot it owns.
fn destroyAccount(a: Allocator, db: *Database, address: [20]u8) !void {
    var keys: std.ArrayList(u256) = .empty;
    var it = db.storage.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, &entry.key_ptr.address, &address)) try keys.append(a, entry.key_ptr.key);
    }
    // Writing zero through the Database keeps its own bookkeeping consistent;
    // zero slots are excluded from the storage trie.
    for (keys.items) |key| try db.set_storage(address, key, 0);
    try db.delete_account(address);
}

/// Exact post-state root: storage tries first, then the account trie.
fn stateRoot(a: Allocator, db: *Database) ![32]u8 {
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

// ---------------------------------------------------------------------------
// Fixture model
// ---------------------------------------------------------------------------

const Slot = struct { key: u256, value: u256 };

const PreAccount = struct {
    address: [20]u8,
    nonce: u64,
    balance: u256,
    code: []const u8,
    storage: []const Slot,
};

const AccessEntry = struct {
    address: [20]u8,
    keys: []const u256,
};

const Authorization = struct {
    chain_id: u256,
    address: [20]u8,
    nonce: u256,
    y_parity: u256,
    r: u256,
    s: u256,
    /// Absent when the fixture's signature does not recover to an address.
    signer: ?[20]u8,
};

const Env = struct {
    coinbase: [20]u8,
    gas_limit: u64,
    number: u64,
    timestamp: u64,
    difficulty: u256,
    base_fee: ?u256,
    random: ?[32]u8,
    excess_blob_gas: ?u64,
};

const TxTemplate = struct {
    chain_id: ?u256,
    nonce: u256,
    gas_price: ?u256,
    max_fee_per_gas: ?u256,
    max_priority_fee_per_gas: ?u256,
    max_fee_per_blob_gas: ?u256,
    to: ?[20]u8,
    sender: [20]u8,
    data: []const []const u8,
    gas_limit: []const u256,
    value: []const u256,
    /// One optional access list per `data` entry.
    access_lists: ?[]const ?[]const AccessEntry,
    blob_hashes: ?[]const [32]u8,
    authorizations: ?[]const Authorization,
};

const TestCase = struct {
    pre: []const PreAccount,
    env: Env,
    tx: TxTemplate,
    chain_id: u64,
    blob_schedule: ?std.json.ObjectMap,
    post: std.json.ObjectMap,
};

/// The transaction selected by one `post[fork][i].indexes` entry.
const Tx = struct {
    template: *const TxTemplate,
    data: []const u8,
    gas_limit: u256,
    value: u256,
    access_list: []const AccessEntry,
};

const Receipt = struct {
    status: ?bool,
    gas_used: ?u64,
};

const Post = struct {
    hash: [32]u8,
    logs: [32]u8,
    tx_bytes: []const u8,
    expect_exception: ?[]const u8,
    receipt: ?Receipt,
    state: ?std.json.ObjectMap,
    data_index: usize,
    gas_index: usize,
    value_index: usize,
};

fn optionalU256(object: std.json.ObjectMap, name: []const u8) !?u256 {
    const value = object.get(name) orelse return null;
    return try parseU256(try asString(value));
}

fn addressFromSecretKey(secret: [32]u8) ![20]u8 {
    const scalar = std.mem.readInt(u256, &secret, .big);
    if (scalar == 0 or scalar >= crypto.secp256k1.SECP256K1_N) return error.InvalidSecretKey;
    const point = crypto.secp256k1.AffinePoint.generator().scalarMul(scalar);
    if (point.infinity) return error.InvalidSecretKey;
    var public_key: [64]u8 = undefined;
    std.mem.writeInt(u256, public_key[0..32], point.x, .big);
    std.mem.writeInt(u256, public_key[32..64], point.y, .big);
    const digest = keccak(&public_key);
    return digest[12..32].*;
}

fn parseSlots(a: Allocator, object: std.json.ObjectMap) ![]const Slot {
    const slots = try a.alloc(Slot, object.count());
    var it = object.iterator();
    var index: usize = 0;
    while (it.next()) |entry| : (index += 1) {
        slots[index] = .{
            .key = try parseU256(entry.key_ptr.*),
            .value = try parseU256(try asString(entry.value_ptr.*)),
        };
    }
    return slots;
}

fn parsePre(a: Allocator, object: std.json.ObjectMap) ![]const PreAccount {
    const accounts = try a.alloc(PreAccount, object.count());
    var it = object.iterator();
    var index: usize = 0;
    while (it.next()) |entry| : (index += 1) {
        const account = try asObject(entry.value_ptr.*);
        accounts[index] = .{
            .address = try parseFixed(20, entry.key_ptr.*),
            .nonce = try parseU64(try stringField(account, "nonce")),
            .balance = try parseU256(try stringField(account, "balance")),
            .code = try parseBytes(a, try stringField(account, "code")),
            .storage = try parseSlots(a, try asObject(try field(account, "storage"))),
        };
    }
    return accounts;
}

fn parseEnv(object: std.json.ObjectMap) !Env {
    var env = Env{
        .coinbase = try parseFixed(20, try stringField(object, "currentCoinbase")),
        .gas_limit = try parseU64(try stringField(object, "currentGasLimit")),
        .number = try parseU64(try stringField(object, "currentNumber")),
        .timestamp = try parseU64(try stringField(object, "currentTimestamp")),
        .difficulty = 0,
        .base_fee = try optionalU256(object, "currentBaseFee"),
        .random = null,
        .excess_blob_gas = null,
    };
    if (object.get("currentDifficulty")) |value| env.difficulty = try parseU256(try asString(value));
    if (object.get("currentRandom")) |value| env.random = try parseFixed(32, try asString(value));
    if (object.get("currentExcessBlobGas")) |value| env.excess_blob_gas = try parseU64(try asString(value));
    return env;
}

fn parseAccessList(a: Allocator, value: std.json.Value) ![]const AccessEntry {
    const items = try asArray(value);
    const entries = try a.alloc(AccessEntry, items.len);
    for (items, entries) |item, *entry| {
        const object = try asObject(item);
        const key_items = try asArray(try field(object, "storageKeys"));
        const keys = try a.alloc(u256, key_items.len);
        for (key_items, keys) |key_item, *key| key.* = try parseU256(try asString(key_item));
        entry.* = .{ .address = try parseFixed(20, try stringField(object, "address")), .keys = keys };
    }
    return entries;
}

fn parseAuthorizations(a: Allocator, value: std.json.Value) ![]const Authorization {
    const items = try asArray(value);
    const authorizations = try a.alloc(Authorization, items.len);
    for (items, authorizations) |item, *authorization| {
        const object = try asObject(item);
        // `yParity` and the legacy alias `v` carry the same value.
        const parity = object.get("yParity") orelse try field(object, "v");
        authorization.* = .{
            .chain_id = try parseU256(try stringField(object, "chainId")),
            .address = try parseFixed(20, try stringField(object, "address")),
            .nonce = try parseU256(try stringField(object, "nonce")),
            .y_parity = try parseU256(try asString(parity)),
            .r = try parseU256(try stringField(object, "r")),
            .s = try parseU256(try stringField(object, "s")),
            .signer = null,
        };
        if (object.get("signer")) |signer| authorization.signer = try parseFixed(20, try asString(signer));
    }
    return authorizations;
}

fn parseTxTemplate(a: Allocator, object: std.json.ObjectMap) !TxTemplate {
    const data_items = try asArray(try field(object, "data"));
    const data = try a.alloc([]const u8, data_items.len);
    for (data_items, data) |item, *target| target.* = try parseBytes(a, try asString(item));

    const gas_items = try asArray(try field(object, "gasLimit"));
    const gas_limit = try a.alloc(u256, gas_items.len);
    for (gas_items, gas_limit) |item, *target| target.* = try parseU256(try asString(item));

    const value_items = try asArray(try field(object, "value"));
    const value = try a.alloc(u256, value_items.len);
    for (value_items, value) |item, *target| target.* = try parseU256(try asString(item));

    const to_text = try stringField(object, "to");
    const sender = blk: {
        if (object.get("sender")) |sender_value| break :blk try parseFixed(20, try asString(sender_value));
        break :blk try addressFromSecretKey(try parseFixed(32, try stringField(object, "secretKey")));
    };

    var template = TxTemplate{
        .chain_id = try optionalU256(object, "chainId"),
        .nonce = try parseU256(try stringField(object, "nonce")),
        .gas_price = try optionalU256(object, "gasPrice"),
        .max_fee_per_gas = try optionalU256(object, "maxFeePerGas"),
        .max_priority_fee_per_gas = try optionalU256(object, "maxPriorityFeePerGas"),
        .max_fee_per_blob_gas = try optionalU256(object, "maxFeePerBlobGas"),
        .to = if (to_text.len == 0) null else try parseFixed(20, to_text),
        .sender = sender,
        .data = data,
        .gas_limit = gas_limit,
        .value = value,
        .access_lists = null,
        .blob_hashes = null,
        .authorizations = null,
    };

    if (object.get("accessLists")) |lists_value| {
        const lists = try asArray(lists_value);
        const parsed = try a.alloc(?[]const AccessEntry, lists.len);
        for (lists, parsed) |list, *target| {
            target.* = switch (list) {
                .null => null,
                else => try parseAccessList(a, list),
            };
        }
        template.access_lists = parsed;
    }
    if (object.get("blobVersionedHashes")) |hashes_value| {
        const items = try asArray(hashes_value);
        const hashes = try a.alloc([32]u8, items.len);
        for (items, hashes) |item, *target| target.* = try parseFixed(32, try asString(item));
        template.blob_hashes = hashes;
    }
    if (object.get("authorizationList")) |list| template.authorizations = try parseAuthorizations(a, list);
    return template;
}

fn parseTestCase(a: Allocator, value: std.json.Value) !TestCase {
    const object = try asObject(value);
    var chain_id: u64 = 1;
    var blob_schedule: ?std.json.ObjectMap = null;
    if (object.get("config")) |config_value| {
        const config = try asObject(config_value);
        if (config.get("chainid")) |chain| chain_id = try parseU64(try asString(chain));
        if (config.get("blobSchedule")) |schedule| blob_schedule = try asObject(schedule);
    }
    return .{
        .pre = try parsePre(a, try asObject(try field(object, "pre"))),
        .env = try parseEnv(try asObject(try field(object, "env"))),
        .tx = try parseTxTemplate(a, try asObject(try field(object, "transaction"))),
        .chain_id = chain_id,
        .blob_schedule = blob_schedule,
        .post = try asObject(try field(object, "post")),
    };
}

fn parsePost(a: Allocator, value: std.json.Value) !Post {
    const object = try asObject(value);
    const indexes = try asObject(try field(object, "indexes"));
    var post = Post{
        .hash = try parseFixed(32, try stringField(object, "hash")),
        .logs = try parseFixed(32, try stringField(object, "logs")),
        .tx_bytes = try parseBytes(a, try stringField(object, "txbytes")),
        .expect_exception = null,
        .receipt = null,
        .state = null,
        .data_index = try asIndex(try field(indexes, "data")),
        .gas_index = try asIndex(try field(indexes, "gas")),
        .value_index = try asIndex(try field(indexes, "value")),
    };
    if (object.get("expectException")) |expected| post.expect_exception = try asString(expected);
    if (object.get("state")) |state| post.state = try asObject(state);
    if (object.get("receipt")) |receipt_value| {
        const receipt_object = try asObject(receipt_value);
        var receipt = Receipt{ .status = null, .gas_used = null };
        if (receipt_object.get("status")) |status| {
            receipt.status = switch (status) {
                .bool => |flag| flag,
                else => return error.ExpectedJsonBool,
            };
        }
        if (receipt_object.get("cumulativeGasUsed")) |gas| receipt.gas_used = try parseU64(try asString(gas));
        post.receipt = receipt;
    }
    return post;
}

fn selectTx(template: *const TxTemplate, post: Post) !Tx {
    if (post.data_index >= template.data.len) return error.DataIndexOutOfRange;
    if (post.gas_index >= template.gas_limit.len) return error.GasIndexOutOfRange;
    if (post.value_index >= template.value.len) return error.ValueIndexOutOfRange;
    var access_list: []const AccessEntry = &.{};
    if (template.access_lists) |lists| {
        if (post.data_index >= lists.len) return error.AccessListIndexOutOfRange;
        if (lists[post.data_index]) |list| access_list = list;
    }
    return .{
        .template = template,
        .data = template.data[post.data_index],
        .gas_limit = template.gas_limit[post.gas_index],
        .value = template.value[post.value_index],
        .access_list = access_list,
    };
}

// ---------------------------------------------------------------------------
// Transaction validation
// ---------------------------------------------------------------------------

pub const TxException = enum {
    TYPE_1_TX_PRE_FORK,
    TYPE_2_TX_PRE_FORK,
    TYPE_3_TX_PRE_FORK,
    TYPE_4_TX_PRE_FORK,
    INVALID_CHAINID,
    INVALID_SIGNATURE_VRS,
    INTRINSIC_GAS_TOO_LOW,
    INTRINSIC_GAS_BELOW_FLOOR_GAS_COST,
    NONCE_IS_MAX,
    INITCODE_SIZE_EXCEEDED,
    GAS_LIMIT_EXCEEDS_MAXIMUM,
    GAS_ALLOWANCE_EXCEEDED,
    TYPE_3_TX_MAX_BLOB_GAS_ALLOWANCE_EXCEEDED,
    TYPE_3_TX_BLOB_COUNT_EXCEEDED,
    PRIORITY_GREATER_THAN_MAX_FEE_PER_GAS,
    INSUFFICIENT_MAX_FEE_PER_GAS,
    TYPE_3_TX_ZERO_BLOBS,
    TYPE_3_TX_INVALID_BLOB_VERSIONED_HASH,
    INSUFFICIENT_MAX_FEE_PER_BLOB_GAS,
    TYPE_3_TX_CONTRACT_CREATION,
    TYPE_4_TX_CONTRACT_CREATION,
    TYPE_4_EMPTY_AUTHORIZATION_LIST,
    NONCE_MISMATCH_TOO_LOW,
    NONCE_MISMATCH_TOO_HIGH,
    GASLIMIT_PRICE_PRODUCT_OVERFLOW,
    INSUFFICIENT_ACCOUNT_FUNDS,
    SENDER_NOT_EOA,
};

const exception_prefix = "TransactionException.";

/// True when `expected` (alternatives joined by `|`) names `exception`.
fn exceptionExpected(expected: []const u8, exception: TxException) bool {
    var it = std.mem.splitScalar(u8, expected, '|');
    while (it.next()) |alternative| {
        if (!std.mem.startsWith(u8, alternative, exception_prefix)) continue;
        if (std.mem.eql(u8, alternative[exception_prefix.len..], @tagName(exception))) return true;
    }
    return false;
}

const secp256k1_n: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
const gas_per_blob: u64 = 131072;
const tx_gas_cap_osaka: u64 = 1 << 24;
const max_initcode_size: usize = 49152;
const max_blobs_per_tx_osaka: usize = 6;

const BlobParams = struct {
    max_blobs: u64,
    update_fraction: u256,
};

fn blobParams(fork: Fork, fork_name: []const u8, schedule: ?std.json.ObjectMap) !BlobParams {
    if (schedule) |object| {
        if (object.get(fork_name)) |entry_value| {
            const entry = try asObject(entry_value);
            return .{
                .max_blobs = try parseU64(try stringField(entry, "max")),
                .update_fraction = try parseU256(try stringField(entry, "baseFeeUpdateFraction")),
            };
        }
    }
    if (fork.atLeast(.Prague)) return .{ .max_blobs = 9, .update_fraction = 5007716 };
    return .{ .max_blobs = 6, .update_fraction = 3338477 };
}

/// EIP-4844 `fake_exponential(1, excess_blob_gas, update_fraction)`.
fn blobBaseFee(excess_blob_gas: u64, update_fraction: u256) u256 {
    var index: u256 = 1;
    var output: u256 = 0;
    var accumulator: u256 = update_fraction;
    while (accumulator > 0) {
        output += accumulator;
        accumulator = (accumulator * excess_blob_gas) / (update_fraction * index);
        index += 1;
    }
    return output / update_fraction;
}

const Signature = struct {
    tx_type: u8,
    v: u256,
    r: u256,
    s: u256,
};

fn rlpScalar(item: RlpItem) !u256 {
    if (item.is_list) return error.RlpExpectedString;
    if (item.payload.len > 32) return error.RlpScalarTooLarge;
    var value: u256 = 0;
    for (item.payload) |byte| value = (value << 8) | byte;
    return value;
}

/// Reads the transaction type and the trailing `v, r, s` fields of `txbytes`.
fn decodeSignature(tx_bytes: []const u8) !Signature {
    if (tx_bytes.len == 0) return error.RlpTruncated;
    var tx_type: u8 = 0;
    var body = tx_bytes;
    if (tx_bytes[0] < 0x80) {
        tx_type = tx_bytes[0];
        body = tx_bytes[1..];
    }
    const list = try rlpDecode(body);
    if (!list.is_list) return error.RlpExpectedList;
    var last: [3]RlpItem = undefined;
    var count: usize = 0;
    var rest = list.payload;
    while (rest.len > 0) {
        const item = try rlpDecode(rest);
        last[0] = last[1];
        last[1] = last[2];
        last[2] = item;
        count += 1;
        rest = rest[item.size..];
    }
    if (count < 3) return error.RlpTooFewFields;
    return .{
        .tx_type = tx_type,
        .v = try rlpScalar(last[0]),
        .r = try rlpScalar(last[1]),
        .s = try rlpScalar(last[2]),
    };
}

fn checkSignature(fork: Fork, chain_id: u64, template: *const TxTemplate, signature: Signature) ?TxException {
    if (signature.tx_type == 0) {
        if (signature.v != 27 and signature.v != 28) {
            if (!fork.atLeast(.SpuriousDragon) or signature.v < 35) return .INVALID_SIGNATURE_VRS;
            if ((signature.v - 35) / 2 != chain_id) return .INVALID_CHAINID;
        }
    } else {
        if (template.chain_id) |tx_chain_id| {
            if (tx_chain_id != chain_id) return .INVALID_CHAINID;
        }
        if (signature.v > 1) return .INVALID_SIGNATURE_VRS;
    }
    if (signature.r == 0 or signature.r >= secp256k1_n) return .INVALID_SIGNATURE_VRS;
    if (signature.s == 0 or signature.s >= secp256k1_n) return .INVALID_SIGNATURE_VRS;
    if (fork.atLeast(.Homestead) and signature.s > secp256k1_n / 2) return .INVALID_SIGNATURE_VRS;
    if (!isCurveX(signature.r)) return .INVALID_SIGNATURE_VRS;
    return null;
}

/// True when `x` is the x-coordinate of a secp256k1 point, which public-key
/// recovery requires of `r`. Euler's criterion on x^3 + 7.
fn isCurveX(x: u256) bool {
    const secp = crypto.secp256k1;
    const p = secp.SECP256K1_P;
    if (x >= p) return false;
    const x_cubed = secp.unauditedMulmod(secp.unauditedMulmod(x, x, p), x, p);
    const y_squared = secp.unauditedAddmod(x_cubed, secp.SECP256K1_B, p);
    if (y_squared == 0) return true;
    return secp.unauditedPowmod(y_squared, (p - 1) / 2, p) == 1;
}

const Intrinsic = struct {
    gas: u64,
    /// EIP-7623 calldata floor, 0 before Prague.
    floor: u64,
};

fn intrinsicGas(fork: Fork, tx: Tx) Intrinsic {
    var zero_bytes: u64 = 0;
    for (tx.data) |byte| {
        if (byte == 0) zero_bytes += 1;
    }
    const nonzero_bytes: u64 = tx.data.len - zero_bytes;
    const nonzero_cost: u64 = if (fork.atLeast(.Istanbul)) 16 else 68;
    var gas: u64 = 21000 + zero_bytes * 4 + nonzero_bytes * nonzero_cost;
    if (tx.template.to == null) {
        if (fork.atLeast(.Homestead)) gas += 32000;
        if (fork.atLeast(.Shanghai)) gas += 2 * ((tx.data.len + 31) / 32);
    }
    if (fork.atLeast(.Berlin)) {
        for (tx.access_list) |entry| gas += 2400 + 1900 * entry.keys.len;
    }
    if (fork.atLeast(.Prague)) {
        if (tx.template.authorizations) |authorizations| gas += 25000 * authorizations.len;
    }
    var floor: u64 = 0;
    if (fork.atLeast(.Prague)) floor = 21000 + 10 * (zero_bytes + 4 * nonzero_bytes);
    return .{ .gas = gas, .floor = floor };
}

const Validated = struct {
    exception: ?TxException = null,
    gas_limit: u64 = 0,
    intrinsic: Intrinsic = .{ .gas = 0, .floor = 0 },
    effective_gas_price: u256 = 0,
    /// Wei burned for blob gas.
    blob_fee: u256 = 0,
    blob_base_fee: u256 = 0,

    fn reject(exception: TxException) Validated {
        return .{ .exception = exception };
    }
};

fn validateTx(
    fork: Fork,
    fork_name: []const u8,
    test_case: *const TestCase,
    tx: Tx,
    tx_bytes: []const u8,
    sender: Account,
) !Validated {
    const template = tx.template;
    const env = test_case.env;

    const signature = decodeSignature(tx_bytes) catch |err| switch (err) {
        // A signature field wider than 256 bits cannot be a valid scalar.
        error.RlpScalarTooLarge => return Validated.reject(.INVALID_SIGNATURE_VRS),
        else => return err,
    };
    const tx_type = signature.tx_type;
    if (tx_type == 1 and !fork.atLeast(.Berlin)) return Validated.reject(.TYPE_1_TX_PRE_FORK);
    if (tx_type == 2 and !fork.atLeast(.London)) return Validated.reject(.TYPE_2_TX_PRE_FORK);
    if (tx_type == 3 and !fork.atLeast(.Cancun)) return Validated.reject(.TYPE_3_TX_PRE_FORK);
    if (tx_type == 4 and !fork.atLeast(.Prague)) return Validated.reject(.TYPE_4_TX_PRE_FORK);
    if (tx_type > 4) return error.UnsupportedTransactionType;

    const intrinsic = intrinsicGas(fork, tx);
    if (tx.gas_limit < intrinsic.gas) return Validated.reject(.INTRINSIC_GAS_TOO_LOW);
    if (tx.gas_limit < intrinsic.floor) return Validated.reject(.INTRINSIC_GAS_BELOW_FLOOR_GAS_COST);
    if (template.nonce >= std.math.maxInt(u64)) return Validated.reject(.NONCE_IS_MAX);
    if (fork.atLeast(.Shanghai) and template.to == null and tx.data.len > max_initcode_size) {
        return Validated.reject(.INITCODE_SIZE_EXCEEDED);
    }
    if (fork.atLeast(.Osaka) and tx.gas_limit > tx_gas_cap_osaka) return Validated.reject(.GAS_LIMIT_EXCEEDS_MAXIMUM);
    if (tx.gas_limit > env.gas_limit) return Validated.reject(.GAS_ALLOWANCE_EXCEEDED);
    const gas_limit: u64 = @intCast(tx.gas_limit);

    const blob_count: usize = if (template.blob_hashes) |hashes| hashes.len else 0;
    var blob: ?BlobParams = null;
    if (tx_type == 3) {
        const params = try blobParams(fork, fork_name, test_case.blob_schedule);
        if (blob_count > params.max_blobs) return Validated.reject(.TYPE_3_TX_MAX_BLOB_GAS_ALLOWANCE_EXCEEDED);
        if (fork.atLeast(.Osaka) and blob_count > max_blobs_per_tx_osaka) return Validated.reject(.TYPE_3_TX_BLOB_COUNT_EXCEEDED);
        blob = params;
    }

    if (checkSignature(fork, test_case.chain_id, template, signature)) |exception| return Validated.reject(exception);

    const base_fee: u256 = if (fork.atLeast(.London)) env.base_fee orelse return error.MissingBaseFee else 0;
    var effective_gas_price: u256 = 0;
    var max_fee_per_gas: u256 = 0;
    if (tx_type >= 2) {
        const max_fee = template.max_fee_per_gas orelse return error.MissingMaxFeePerGas;
        const max_priority = template.max_priority_fee_per_gas orelse return error.MissingMaxPriorityFeePerGas;
        if (max_fee < max_priority) return Validated.reject(.PRIORITY_GREATER_THAN_MAX_FEE_PER_GAS);
        if (max_fee < base_fee) return Validated.reject(.INSUFFICIENT_MAX_FEE_PER_GAS);
        effective_gas_price = base_fee + @min(max_priority, max_fee - base_fee);
        max_fee_per_gas = max_fee;
    } else {
        const gas_price = template.gas_price orelse return error.MissingGasPrice;
        if (gas_price < base_fee) return Validated.reject(.INSUFFICIENT_MAX_FEE_PER_GAS);
        effective_gas_price = gas_price;
        max_fee_per_gas = gas_price;
    }

    var blob_fee: u256 = 0;
    var blob_base_fee: u256 = 0;
    var max_blob_fee: u256 = 0;
    if (fork.atLeast(.Cancun)) {
        const params = blob orelse try blobParams(fork, fork_name, test_case.blob_schedule);
        blob_base_fee = blobBaseFee(env.excess_blob_gas orelse 0, params.update_fraction);
    }
    if (tx_type == 3) {
        const hashes = template.blob_hashes orelse return error.MissingBlobVersionedHashes;
        if (hashes.len == 0) return Validated.reject(.TYPE_3_TX_ZERO_BLOBS);
        for (hashes) |hash| {
            if (hash[0] != 0x01) return Validated.reject(.TYPE_3_TX_INVALID_BLOB_VERSIONED_HASH);
        }
        const max_fee_per_blob_gas = template.max_fee_per_blob_gas orelse return error.MissingMaxFeePerBlobGas;
        if (max_fee_per_blob_gas < blob_base_fee) return Validated.reject(.INSUFFICIENT_MAX_FEE_PER_BLOB_GAS);
        const blob_gas: u256 = gas_per_blob * @as(u256, blob_count);
        blob_fee = blob_gas * blob_base_fee;
        max_blob_fee = std.math.mul(u256, blob_gas, max_fee_per_blob_gas) catch |err| switch (err) {
            error.Overflow => return Validated.reject(.INSUFFICIENT_ACCOUNT_FUNDS),
        };
        if (template.to == null) return Validated.reject(.TYPE_3_TX_CONTRACT_CREATION);
    }
    if (tx_type == 4) {
        if (template.to == null) return Validated.reject(.TYPE_4_TX_CONTRACT_CREATION);
        const authorizations = template.authorizations orelse return error.MissingAuthorizationList;
        if (authorizations.len == 0) return Validated.reject(.TYPE_4_EMPTY_AUTHORIZATION_LIST);
    }

    if (sender.nonce > template.nonce) return Validated.reject(.NONCE_MISMATCH_TOO_LOW);
    if (sender.nonce < template.nonce) return Validated.reject(.NONCE_MISMATCH_TOO_HIGH);

    const max_gas_fee = std.math.mul(u256, gas_limit, max_fee_per_gas) catch |err| switch (err) {
        error.Overflow => return Validated.reject(.GASLIMIT_PRICE_PRODUCT_OVERFLOW),
    };
    const with_blobs = std.math.add(u256, max_gas_fee, max_blob_fee) catch |err| switch (err) {
        error.Overflow => return Validated.reject(.INSUFFICIENT_ACCOUNT_FUNDS),
    };
    const total = std.math.add(u256, with_blobs, tx.value) catch |err| switch (err) {
        error.Overflow => return Validated.reject(.INSUFFICIENT_ACCOUNT_FUNDS),
    };
    if (sender.balance < total) return Validated.reject(.INSUFFICIENT_ACCOUNT_FUNDS);

    // EIP-3607. A Prague delegation designator is stored as a delegation, not
    // as code, so a delegated sender passes.
    if (!hasNoCode(sender)) return Validated.reject(.SENDER_NOT_EOA);

    return .{
        .gas_limit = gas_limit,
        .intrinsic = intrinsic,
        .effective_gas_price = effective_gas_price,
        .blob_fee = blob_fee,
        .blob_base_fee = blob_base_fee,
    };
}

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

const Outcome = union(enum) {
    pass,
    fail: Failure,

    const Failure = struct {
        category: []const u8,
        detail: []const u8,
    };

    fn failure(category: []const u8, detail: []const u8) Outcome {
        return .{ .fail = .{ .category = category, .detail = detail } };
    }
};

fn loadPre(fork: Fork, db: *Database, pre: []const PreAccount) !void {
    for (pre) |entry| {
        var account = Account.zero();
        account.nonce = entry.nonce;
        account.balance = entry.balance;
        const is_delegation = fork.atLeast(.Prague) and entry.code.len == 23 and std.mem.startsWith(u8, entry.code, &delegation_prefix);
        if (is_delegation) {
            account.delegated_address = .{ .bytes = entry.code[3..23].* };
        } else if (entry.code.len > 0) {
            account.code_hash = try db.set_code(entry.code);
        }
        try db.set_account(entry.address, account);
        for (entry.storage) |slot| {
            if (slot.value != 0) try db.set_storage(entry.address, slot.key, slot.value);
        }
    }
}

fn precompileAddresses(fork: Fork) []const u16 {
    if (fork.atLeast(.Osaka)) return &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x100 };
    if (fork.atLeast(.Prague)) return &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11 };
    if (fork.atLeast(.Cancun)) return &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 0x0a };
    if (fork.atLeast(.Istanbul)) return &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    if (fork.atLeast(.Byzantium)) return &.{ 1, 2, 3, 4, 5, 6, 7, 8 };
    return &.{ 1, 2, 3, 4 };
}

fn precompileAddress(number: u16) [20]u8 {
    var bytes = @as([20]u8, @splat(0));
    std.mem.writeInt(u16, bytes[18..20], number, .big);
    return bytes;
}

fn isPrecompile(fork: Fork, address: [20]u8) bool {
    for (precompileAddresses(fork)) |number| {
        if (std.mem.eql(u8, &precompileAddress(number), &address)) return true;
    }
    return false;
}

fn createAddress(a: Allocator, sender: [20]u8, nonce: u64) ![20]u8 {
    var payload: std.ArrayList(u8) = .empty;
    try rlpAppendBytes(a, &payload, &sender);
    try rlpAppendUint(a, &payload, nonce);
    const digest = keccak(try rlpWrapList(a, payload.items));
    return digest[12..32].*;
}

const Executed = struct {
    success: bool,
    gas_used: u64,
    logs_hash: [32]u8,
};

const AddressSet = std.AutoHashMapUnmanaged([20]u8, void);

/// EIP-7702 authorization list. Returns the gas refund it earns.
fn applyAuthorizations(
    a: Allocator,
    db: *Database,
    access_list: anytype,
    chain_id: u64,
    authorizations: []const Authorization,
    touched: *AddressSet,
) !u64 {
    var refund: u64 = 0;
    for (authorizations) |authorization| {
        if (authorization.chain_id != 0 and authorization.chain_id != chain_id) continue;
        if (authorization.nonce >= std.math.maxInt(u64)) continue;
        if (authorization.y_parity > 1) continue;
        if (authorization.r == 0 or authorization.r >= secp256k1_n) continue;
        if (authorization.s == 0 or authorization.s > secp256k1_n / 2) continue;
        const authority = authorization.signer orelse continue;

        try access_list.pre_warm_addresses(&.{primitives.Address{ .bytes = authority }});
        const existing = try db.get_account(authority);
        var account = existing orelse Account.zero();
        if (!hasNoCode(account)) continue;
        if (account.nonce != authorization.nonce) continue;

        if (existing != null) refund += 25000 - 12500;
        if (std.mem.eql(u8, &authorization.address, &(@as([20]u8, @splat(0))))) {
            account.delegated_address = null;
        } else {
            account.delegated_address = .{ .bytes = authorization.address };
        }
        account.nonce += 1;
        try db.set_account(authority, account);
        try touched.put(a, authority, {});
    }
    return refund;
}

fn logsHash(a: Allocator, logs: anytype) ![32]u8 {
    var list: std.ArrayList(u8) = .empty;
    for (logs) |log| {
        var topics: std.ArrayList(u8) = .empty;
        for (log.topics) |topic| {
            var topic_be: [32]u8 = undefined;
            std.mem.writeInt(u256, &topic_be, topic, .big);
            try rlpAppendBytes(a, &topics, &topic_be);
        }
        var entry: std.ArrayList(u8) = .empty;
        try rlpAppendBytes(a, &entry, &log.address.bytes);
        try entry.appendSlice(a, try rlpWrapList(a, topics.items));
        try rlpAppendBytes(a, &entry, log.data);
        try list.appendSlice(a, try rlpWrapList(a, entry.items));
    }
    return keccak(try rlpWrapList(a, list.items));
}

/// Applies one valid transaction to `db` and finalizes it.
fn applyTx(
    comptime fork: Fork,
    a: Allocator,
    gpa: Allocator,
    db: *Database,
    test_case: *const TestCase,
    tx: Tx,
    validated: Validated,
) !Executed {
    const Vm = VmFor(fork);
    const template = tx.template;
    const env = test_case.env;
    const sender_address = primitives.Address{ .bytes = template.sender };
    const coinbase_address = primitives.Address{ .bytes = env.coinbase };
    const tx_nonce: u64 = @intCast(template.nonce);
    const gas_price = validated.effective_gas_price;

    // Accounts that exist before the transaction, for EIP-161 cleanup.
    var existed: AddressSet = .empty;
    var existed_it = db.accounts.keyIterator();
    while (existed_it.next()) |key| try existed.put(a, key.*, {});

    var touched: AddressSet = .empty;
    try touched.put(a, template.sender, {});
    try touched.put(a, env.coinbase, {});
    if (template.to) |to| try touched.put(a, to, {});

    // Buy gas and increment the sender nonce. A creation transaction derives its
    // address from the pre-increment nonce (`tx_nonce`).
    var sender = try accountOrZero(db, template.sender);
    sender.balance -= @as(u256, validated.gas_limit) * gas_price + validated.blob_fee;
    sender.nonce = tx_nonce + 1;
    try db.set_account(template.sender, sender);

    const blob_hashes: []const [32]u8 = template.blob_hashes orelse &.{};
    const prevrandao: [32]u8 = env.random orelse zero_hash;
    const ancestor_hashes = try stateTestBlockHashes(a, env.number);
    var vm = try Vm.init(
        gpa,
        db,
        .{
            .chain_id = test_case.chain_id,
            .number = env.number,
            .timestamp = env.timestamp,
            // EIP-4399: from Paris the header's difficulty field carries prevrandao, and
            // opcode 0x44 (PREVRANDAO) reads it.
            .difficulty = if (fork.atLeast(.Paris)) std.mem.readInt(u256, &prevrandao, .big) else env.difficulty,
            .gas_limit = env.gas_limit,
            .coinbase = coinbase_address,
            .base_fee = env.base_fee orelse 0,
            .prev_randao = prevrandao,
            .blob_base_fee = validated.blob_base_fee,
            .blob_versioned_hashes = blob_hashes,
            .block_hashes = ancestor_hashes,
        },
        .{
            .gas_limit = validated.gas_limit,
            .coinbase = coinbase_address,
            // TransactionContext keeps 16 bits; CHAINID reads BlockInfo.chain_id.
            .chain_id = @truncate(test_case.chain_id),
            .blob_versioned_hashes = blob_hashes,
            .blob_base_fee = validated.blob_base_fee,
        },
        gas_price,
        sender_address,
    );
    defer vm.deinit();

    // EIP-2929 / EIP-2930 / EIP-3651 warm set.
    if (fork.atLeast(.Berlin)) {
        try vm.access_list.pre_warm_addresses(&.{sender_address});
        for (precompileAddresses(fork)) |number| {
            try vm.access_list.pre_warm_addresses(&.{primitives.Address{ .bytes = precompileAddress(number) }});
        }
        if (template.to) |to| {
            try vm.access_list.pre_warm_addresses(&.{primitives.Address{ .bytes = to }});
        } else {
            const created = try createAddress(a, template.sender, tx_nonce);
            try vm.access_list.pre_warm_addresses(&.{primitives.Address{ .bytes = created }});
        }
        if (fork.atLeast(.Shanghai)) try vm.access_list.pre_warm_addresses(&.{coinbase_address});
        for (tx.access_list) |entry| {
            const address = primitives.Address{ .bytes = entry.address };
            try vm.access_list.pre_warm_addresses(&.{address});
            for (entry.keys) |key| _ = try vm.access_list.access_storage_slot(address, key);
        }
    }

    var authorization_refund: u64 = 0;
    if (fork.atLeast(.Prague)) {
        if (template.authorizations) |authorizations| {
            authorization_refund = try applyAuthorizations(a, db, &vm.access_list, test_case.chain_id, authorizations, &touched);
        }
        if (template.to) |to| {
            if (try db.get_account(to)) |target| {
                if (target.delegated_address) |delegate| try vm.access_list.pre_warm_addresses(&.{delegate});
            }
        }
    }

    const execution_gas = validated.gas_limit - validated.intrinsic.gas;
    var success = false;
    var gas_left: u64 = 0;
    if (template.to) |to| {
        const target = try db.get_account(to);
        const has_code = if (target) |account| !hasNoCode(account) or account.delegated_address != null else false;
        if (execution_gas == 0 and !has_code and !isPrecompile(fork, to)) {
            // `Evm.inner_call` rejects a call that carries no gas. A plain
            // transfer that spends exactly its intrinsic gas executes no code,
            // so the runner applies it.
            success = true;
            if (tx.value > 0 and !std.mem.eql(u8, &to, &template.sender)) {
                var from = try accountOrZero(db, template.sender);
                var recipient = try accountOrZero(db, to);
                from.balance -= tx.value;
                recipient.balance += tx.value;
                try db.set_account(template.sender, from);
                try db.set_account(to, recipient);
            }
        } else {
            const result = vm.inner_call(.{ .call = .{
                .caller = sender_address,
                .to = .{ .bytes = to },
                .value = tx.value,
                .input = tx.data,
                .gas = execution_gas,
            } });
            success = result.success;
            gas_left = result.gas_left;
        }
    } else {
        // Intrinsic gas already paid CreateGas and the EIP-3860 initcode words, and the
        // sender nonce is already incremented. The flag makes the EVM run this as the
        // transaction's own creation: no opcode CREATE charge, no 1/64 retention, and
        // the address derived from the pre-increment nonce.
        vm.tx_sender_nonce_incremented = true;
        const result = vm.inner_call(.{ .create = .{
            .caller = sender_address,
            .value = tx.value,
            .init_code = tx.data,
            .gas = execution_gas,
        } });
        success = result.success;
        gas_left = result.gas_left;
    }
    if (gas_left > execution_gas) return error.EvmReturnedMoreGasThanSupplied;

    // Refunds (EIP-3529 cap from London) and the EIP-7623 floor.
    var gas_used = validated.gas_limit - gas_left;
    var refund_counter = authorization_refund;
    if (success) refund_counter += vm.gas_refund_counter;
    const refund_quotient: u64 = if (fork.atLeast(.London)) 5 else 2;
    gas_used -= @min(refund_counter, gas_used / refund_quotient);
    if (fork.atLeast(.Prague)) gas_used = @max(gas_used, validated.intrinsic.floor);

    // The nonce was incremented when gas was bought; a self-sponsored EIP-7702
    // authorization may have incremented it again, so it is not rewritten here.
    sender = try accountOrZero(db, template.sender);
    sender.balance += @as(u256, validated.gas_limit - gas_used) * gas_price;
    try db.set_account(template.sender, sender);

    // EIP-1559 burns the base fee; the coinbase receives the tip.
    const tip: u256 = if (fork.atLeast(.London)) gas_price - (env.base_fee orelse 0) else gas_price;
    var coinbase = try accountOrZero(db, env.coinbase);
    coinbase.balance += @as(u256, gas_used) * tip;
    try db.set_account(env.coinbase, coinbase);

    const logs_hash = if (success) try logsHash(a, vm.logs.items) else try logsHash(a, vm.logs.items[0..0]);

    if (success) {
        // The EVM records SELFDESTRUCT and moved the balance when the opcode ran; the
        // transaction deletes the accounts. Ether an account received after its
        // SELFDESTRUCT is burned with it. From Cancun the record holds only contracts
        // created in this transaction.
        const Destruction = struct { contract: [20]u8, recipient: [20]u8 };
        var destructions: std.ArrayList(Destruction) = .empty;
        var destruct_it = vm.self_destruct.iterator();
        while (destruct_it.next()) |entry| {
            try destructions.append(a, .{ .contract = entry.key_ptr.bytes, .recipient = entry.value_ptr.bytes });
        }
        for (destructions.items) |destruction| {
            try touched.put(a, destruction.recipient, {});
            try destroyAccount(a, db, destruction.contract);
        }
        // Before EIP-161 a successful call creates its target account.
        if (!fork.atLeast(.SpuriousDragon)) {
            if (template.to) |to| {
                if ((try db.get_account(to)) == null) try db.set_account(to, Account.zero());
            }
        }
    }

    // EIP-161: delete every touched account that is empty.
    if (fork.atLeast(.SpuriousDragon)) {
        var touched_it = vm.touched_addresses.keyIterator();
        while (touched_it.next()) |key| try touched.put(a, key.bytes, {});
        var doomed: std.ArrayList([20]u8) = .empty;
        var account_it = db.accounts.iterator();
        while (account_it.next()) |entry| {
            if (!isEmptyAccount(entry.value_ptr.*)) continue;
            const address = entry.key_ptr.*;
            // An empty account that did not exist before was created, and so
            // touched, by this transaction.
            if (touched.contains(address) or !existed.contains(address)) try doomed.append(a, address);
        }
        for (doomed.items) |address| try destroyAccount(a, db, address);
    }

    return .{ .success = success, .gas_used = gas_used, .logs_hash = logs_hash };
}

/// Explains a state-root mismatch with the fixture's expected `state` dump.
fn diagnoseState(a: Allocator, db: *Database, expected: std.json.ObjectMap) !?Outcome.Failure {
    var it = expected.iterator();
    while (it.next()) |entry| {
        const address_text = entry.key_ptr.*;
        const address = try parseFixed(20, address_text);
        const want = try asObject(entry.value_ptr.*);
        const account = (try db.get_account(address)) orelse {
            return .{ .category = "account_missing", .detail = try std.fmt.allocPrint(a, "{s} missing from post-state", .{address_text}) };
        };
        const want_nonce = try parseU64(try stringField(want, "nonce"));
        if (account.nonce != want_nonce) {
            return .{ .category = "nonce_mismatch", .detail = try std.fmt.allocPrint(a, "{s} nonce expected {d} got {d}", .{ address_text, want_nonce, account.nonce }) };
        }
        const want_code = try parseBytes(a, try stringField(want, "code"));
        const code = try accountCode(a, db, account);
        if (!std.mem.eql(u8, code, want_code)) {
            return .{ .category = "code_mismatch", .detail = try std.fmt.allocPrint(a, "{s} code expected {d} bytes got {d} bytes", .{ address_text, want_code.len, code.len }) };
        }
        const want_storage = try asObject(try field(want, "storage"));
        var storage_it = want_storage.iterator();
        while (storage_it.next()) |slot| {
            const key = try parseU256(slot.key_ptr.*);
            const want_value = try parseU256(try asString(slot.value_ptr.*));
            const value = try db.get_storage(address, key);
            if (value != want_value) {
                return .{ .category = "storage_mismatch", .detail = try std.fmt.allocPrint(a, "{s} slot 0x{x} expected 0x{x} got 0x{x}", .{ address_text, key, want_value, value }) };
            }
        }
        var db_storage_it = db.storage.iterator();
        while (db_storage_it.next()) |slot| {
            if (slot.value_ptr.* == 0) continue;
            if (!std.mem.eql(u8, &slot.key_ptr.address, &address)) continue;
            var found = false;
            var want_it = want_storage.iterator();
            while (want_it.next()) |want_slot| {
                if (try parseU256(want_slot.key_ptr.*) == slot.key_ptr.key) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                return .{ .category = "storage_mismatch", .detail = try std.fmt.allocPrint(a, "{s} slot 0x{x} expected 0x0 got 0x{x}", .{ address_text, slot.key_ptr.key, slot.value_ptr.* }) };
            }
        }
        const want_balance = try parseU256(try stringField(want, "balance"));
        if (account.balance != want_balance) {
            return .{ .category = "balance_mismatch", .detail = try std.fmt.allocPrint(a, "{s} balance expected 0x{x} got 0x{x}", .{ address_text, want_balance, account.balance }) };
        }
    }
    var account_it = db.accounts.keyIterator();
    while (account_it.next()) |key| {
        const text = try hexAlloc(a, key);
        if (!expected.contains(text)) {
            return .{ .category = "unexpected_account", .detail = try std.fmt.allocPrint(a, "{s} present in post-state", .{text}) };
        }
    }
    return null;
}

fn runPostFor(
    comptime fork: Fork,
    a: Allocator,
    gpa: Allocator,
    fork_name: []const u8,
    test_case: *const TestCase,
    post: Post,
) !Outcome {
    var db = Database.init(gpa);
    defer db.deinit();
    try loadPre(fork, &db, test_case.pre);

    const tx = try selectTx(&test_case.tx, post);
    const sender = try accountOrZero(&db, test_case.tx.sender);
    const validated = try validateTx(fork, fork_name, test_case, tx, post.tx_bytes, sender);

    if (post.expect_exception) |expected| {
        const exception = validated.exception orelse {
            return Outcome.failure("expected_exception_not_raised", try std.fmt.allocPrint(a, "expected {s}, transaction accepted", .{expected}));
        };
        if (!exceptionExpected(expected, exception)) {
            return Outcome.failure("wrong_exception", try std.fmt.allocPrint(a, "expected {s}, got {s}{s}", .{ expected, exception_prefix, @tagName(exception) }));
        }
    } else if (validated.exception) |exception| {
        return Outcome.failure("unexpected_tx_rejection", try std.fmt.allocPrint(a, "valid transaction rejected with {s}{s}", .{ exception_prefix, @tagName(exception) }));
    }

    var executed: ?Executed = null;
    if (validated.exception == null) executed = try applyTx(fork, a, gpa, &db, test_case, tx, validated);

    const root = try stateRoot(a, &db);
    const logs_hash = if (executed) |result| result.logs_hash else try logsHash(a, &[_]evm.Log{});
    const root_matches = std.mem.eql(u8, &root, &post.hash);
    const logs_match = std.mem.eql(u8, &logs_hash, &post.logs);
    if (root_matches and logs_match) return .pass;

    // The first account difference, appended to receipt mismatches so one line shows
    // both the symptom and where the state went wrong.
    const state_failure: ?Outcome.Failure = if (root_matches) null else if (post.state) |state| try diagnoseState(a, &db, state) else null;
    const state_note: []const u8 = if (state_failure) |failure| try std.fmt.allocPrint(a, "; first state difference: {s}", .{failure.detail}) else "";

    if (executed) |result| {
        if (post.receipt) |receipt| {
            if (receipt.status) |status| {
                if (status != result.success) {
                    return Outcome.failure("status_mismatch", try std.fmt.allocPrint(a, "expected success={any}, got success={any}, gas used {d}{s}", .{ status, result.success, result.gas_used, state_note }));
                }
            }
            if (receipt.gas_used) |gas_used| {
                if (gas_used != result.gas_used) {
                    return Outcome.failure("gas_used_mismatch", try std.fmt.allocPrint(a, "expected gas used {d}, got {d}{s}", .{ gas_used, result.gas_used, state_note }));
                }
            }
        }
    }
    if (!root_matches) {
        if (post.state) |_| {
            if (state_failure) |failure| return .{ .fail = failure };
            return Outcome.failure("state_root_mismatch_unexplained", try std.fmt.allocPrint(a, "accounts match the expected state, root expected {s} got {s}", .{ try hexAlloc(a, &post.hash), try hexAlloc(a, &root) }));
        }
        return Outcome.failure("state_root_mismatch", try std.fmt.allocPrint(a, "expected {s} got {s}", .{ try hexAlloc(a, &post.hash), try hexAlloc(a, &root) }));
    }
    return Outcome.failure("logs_hash_mismatch", try std.fmt.allocPrint(a, "expected {s} got {s}", .{ try hexAlloc(a, &post.logs), try hexAlloc(a, &logs_hash) }));
}

fn runPost(fork: Fork, a: Allocator, gpa: Allocator, fork_name: []const u8, test_case: *const TestCase, post: Post) !Outcome {
    return switch (fork) {
        inline else => |comptime_fork| runPostFor(comptime_fork, a, gpa, fork_name, test_case, post),
    };
}

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

const CaseInfo = struct {
    ordinal: usize = 0,
    fork: []const u8 = "",
    suite: []const u8 = "",
    file: []const u8 = "",
    name: []const u8 = "",
    post_index: usize = 0,
};

const Counts = struct {
    passed: u64 = 0,
    failed: u64 = 0,
};

const ForkStats = struct {
    counts: Counts = .{},
    reasons: std.StringArrayHashMapUnmanaged(u64) = .empty,
    suites: std.StringArrayHashMapUnmanaged(Counts) = .empty,
};

const Example = struct {
    fork: []const u8,
    file: []const u8,
    name: []const u8,
    post_index: usize,
    detail: []const u8,
};

const Reason = struct {
    count: u64 = 0,
    examples: std.ArrayList(Example) = .empty,
};

const LeakCheck = enum { not_run, clean, leaked };

const Aggregator = struct {
    /// Arena: every stored string lives until the process exits.
    a: Allocator,
    verbose: bool,
    forks: std.StringArrayHashMapUnmanaged(ForkStats) = .empty,
    reasons: std.StringArrayHashMapUnmanaged(Reason) = .empty,
    skipped: std.StringArrayHashMapUnmanaged(u64) = .empty,
    passed: u64 = 0,
    failed: u64 = 0,
    skipped_total: u64 = 0,
    leak_check: LeakCheck = .not_run,

    fn forkStats(self: *Aggregator, fork: []const u8) !*ForkStats {
        const entry = try self.forks.getOrPut(self.a, fork);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.a.dupe(u8, fork);
            entry.value_ptr.* = .{};
        }
        return entry.value_ptr;
    }

    fn suiteCounts(self: *Aggregator, stats: *ForkStats, suite: []const u8) !*Counts {
        const entry = try stats.suites.getOrPut(self.a, suite);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.a.dupe(u8, suite);
            entry.value_ptr.* = .{};
        }
        return entry.value_ptr;
    }

    fn pass(self: *Aggregator, info: CaseInfo) !void {
        const stats = try self.forkStats(info.fork);
        stats.counts.passed += 1;
        (try self.suiteCounts(stats, info.suite)).passed += 1;
        self.passed += 1;
    }

    fn fail(self: *Aggregator, info: CaseInfo, category: []const u8, detail: []const u8) !void {
        const stats = try self.forkStats(info.fork);
        stats.counts.failed += 1;
        (try self.suiteCounts(stats, info.suite)).failed += 1;
        self.failed += 1;

        const fork_reason = try stats.reasons.getOrPut(self.a, category);
        if (!fork_reason.found_existing) {
            fork_reason.key_ptr.* = try self.a.dupe(u8, category);
            fork_reason.value_ptr.* = 0;
        }
        fork_reason.value_ptr.* += 1;

        const reason = try self.reasons.getOrPut(self.a, category);
        if (!reason.found_existing) {
            reason.key_ptr.* = try self.a.dupe(u8, category);
            reason.value_ptr.* = .{};
        }
        reason.value_ptr.count += 1;
        if (reason.value_ptr.examples.items.len < examples_per_reason) {
            try reason.value_ptr.examples.append(self.a, .{
                .fork = try self.a.dupe(u8, info.fork),
                .file = try self.a.dupe(u8, info.file),
                .name = try self.a.dupe(u8, info.name),
                .post_index = info.post_index,
                .detail = try self.a.dupe(u8, detail),
            });
        }
        if (self.verbose) {
            const line = try std.fmt.allocPrint(self.a, "FAIL [{s}] {s} {s}::{s} #{d}: {s}\n", .{ info.fork, category, info.file, info.name, info.post_index, detail });
            try std.Io.File.stdout().writeStreamingAll(io, line);
        }
    }

    fn skip(self: *Aggregator, fork: []const u8, count: u64) !void {
        const entry = try self.skipped.getOrPut(self.a, fork);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.a.dupe(u8, fork);
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += count;
        self.skipped_total += count;
    }
};

/// Where a worker sends results: straight into the aggregator (in-process) or
/// as protocol lines on stdout (worker process).
const Sink = struct {
    target: union(enum) {
        direct: *Aggregator,
        pipe: std.Io.File,
    },
    a: Allocator,
    line: std.ArrayList(u8) = .empty,
    current: CaseInfo = .{},

    fn appendField(self: *Sink, text: []const u8) !void {
        try self.line.append(self.a, '\t');
        for (text) |char| {
            try self.line.append(self.a, if (char == '\t' or char == '\n' or char == '\r') ' ' else char);
        }
    }

    fn appendNumber(self: *Sink, value: usize) !void {
        try self.appendField(try std.fmt.allocPrint(self.a, "{d}", .{value}));
    }

    fn send(self: *Sink, file: std.Io.File) !void {
        try self.line.append(self.a, '\n');
        try file.writeStreamingAll(io, self.line.items);
        self.line.clearRetainingCapacity();
    }

    fn fileStart(self: *Sink, index: usize) !void {
        switch (self.target) {
            .direct => {},
            .pipe => |file| {
                try self.line.append(self.a, 'F');
                try self.appendNumber(index);
                try self.send(file);
            },
        }
    }

    fn fileDone(self: *Sink, index: usize) !void {
        switch (self.target) {
            .direct => {},
            .pipe => |file| {
                try self.line.append(self.a, 'D');
                try self.appendNumber(index);
                try self.send(file);
            },
        }
    }

    fn caseStart(self: *Sink, info: CaseInfo) !void {
        self.current = info;
        switch (self.target) {
            .direct => {},
            .pipe => |file| {
                try self.line.append(self.a, 'S');
                try self.appendNumber(info.ordinal);
                try self.appendField(info.fork);
                try self.appendField(info.suite);
                try self.appendField(info.file);
                try self.appendField(info.name);
                try self.appendNumber(info.post_index);
                try self.send(file);
            },
        }
    }

    fn pass(self: *Sink) !void {
        switch (self.target) {
            .direct => |aggregator| try aggregator.pass(self.current),
            .pipe => |file| {
                try self.line.append(self.a, 'P');
                try self.send(file);
            },
        }
    }

    fn fail(self: *Sink, category: []const u8, detail: []const u8) !void {
        switch (self.target) {
            .direct => |aggregator| try aggregator.fail(self.current, category, detail),
            .pipe => |file| {
                try self.line.append(self.a, 'X');
                try self.appendField(category);
                try self.appendField(detail);
                try self.send(file);
            },
        }
    }

    fn skip(self: *Sink, ordinal: usize, fork: []const u8, count: usize) !void {
        switch (self.target) {
            .direct => |aggregator| try aggregator.skip(fork, count),
            .pipe => |file| {
                try self.line.append(self.a, 'K');
                try self.appendNumber(ordinal);
                try self.appendField(fork);
                try self.appendNumber(count);
                try self.send(file);
            },
        }
    }

    fn end(self: *Sink, leak_check: LeakCheck) !void {
        switch (self.target) {
            .direct => |aggregator| aggregator.leak_check = leak_check,
            .pipe => |file| {
                try self.line.append(self.a, 'E');
                try self.appendField(@tagName(leak_check));
                try self.send(file);
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const WorkerArgs = struct {
    shard: usize,
    shards: usize,
    start_file: usize,
    skip_cases: usize,
};

const Config = struct {
    fixtures_dir: []const u8 = default_fixtures_dir,
    fork_text: ?[]const u8 = null,
    forks: ForkSet = ForkSet.full,
    filter: ?[]const u8 = null,
    report: ?[]const u8 = null,
    jobs: usize = 1,
    timeout_secs: u64 = 600,
    verbose: bool = false,
    worker: ?WorkerArgs = null,
};

/// Prints a usage problem to stderr and returns `error.Usage`, or the write
/// error when stderr itself fails.
fn usage(a: Allocator, comptime format: []const u8, args: anytype) anyerror {
    const message = std.fmt.allocPrint(a, "eest-runner: " ++ format ++ "\n", args) catch |err| return err;
    std.Io.File.stderr().writeStreamingAll(io, message) catch |err| return err;
    return error.Usage;
}

fn envValue(a: Allocator, name: []const u8) !?[]const u8 {
    const value = environ_map.get(name) orelse return null;
    if (value.len == 0) return null;
    return try a.dupe(u8, value);
}

fn flagValue(arg: []const u8, comptime name: []const u8) ?[]const u8 {
    const prefix = "--" ++ name ++ "=";
    if (std.mem.startsWith(u8, arg, prefix)) return arg[prefix.len..];
    return null;
}

fn parseNumber(a: Allocator, comptime T: type, name: []const u8, text: []const u8) !T {
    return std.fmt.parseInt(T, text, 10) catch |err| switch (err) {
        error.Overflow, error.InvalidCharacter => usage(a, "{s} must be a non-negative integer, got '{s}'", .{ name, text }),
    };
}

fn parseForks(a: Allocator, text: []const u8) !ForkSet {
    var set = ForkSet.empty;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        if (name.len == 0) continue;
        const fork = Fork.parse(name) orelse return usage(a, "unsupported fork '{s}' (supported: Frontier through Osaka)", .{name});
        set.insert(fork);
    }
    if (set.count() == 0) return usage(a, "fork list '{s}' names no fork", .{text});
    return set;
}

fn loadConfig(a: Allocator, args: []const []const u8) !Config {
    var config = Config{};
    config.jobs = try std.Thread.getCpuCount();

    if (try envValue(a, "EEST_FIXTURES_DIR")) |value| config.fixtures_dir = value;
    if (try envValue(a, "EEST_FORK")) |value| config.fork_text = value;
    if (try envValue(a, "EEST_FILTER")) |value| config.filter = value;
    if (try envValue(a, "EEST_REPORT_JSON")) |value| config.report = value;
    if (try envValue(a, "EEST_JOBS")) |value| config.jobs = try parseNumber(a, usize, "EEST_JOBS", value);
    if (try envValue(a, "EEST_TIMEOUT_SECS")) |value| config.timeout_secs = try parseNumber(a, u64, "EEST_TIMEOUT_SECS", value);
    if (try envValue(a, "EEST_VERBOSE")) |value| config.verbose = !std.mem.eql(u8, value, "0");

    var is_worker = false;
    var worker = WorkerArgs{ .shard = 0, .shards = 1, .start_file = 0, .skip_cases = 0 };
    for (args[1..]) |arg| {
        if (flagValue(arg, "fixtures")) |value| {
            config.fixtures_dir = value;
        } else if (flagValue(arg, "fork")) |value| {
            config.fork_text = if (value.len == 0) null else value;
        } else if (flagValue(arg, "filter")) |value| {
            config.filter = if (value.len == 0) null else value;
        } else if (flagValue(arg, "report")) |value| {
            config.report = if (value.len == 0) null else value;
        } else if (flagValue(arg, "jobs")) |value| {
            config.jobs = try parseNumber(a, usize, "--jobs", value);
        } else if (flagValue(arg, "timeout")) |value| {
            config.timeout_secs = try parseNumber(a, u64, "--timeout", value);
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            config.verbose = true;
        } else if (std.mem.eql(u8, arg, "--worker")) {
            is_worker = true;
        } else if (flagValue(arg, "shard")) |value| {
            worker.shard = try parseNumber(a, usize, "--shard", value);
        } else if (flagValue(arg, "shards")) |value| {
            worker.shards = try parseNumber(a, usize, "--shards", value);
        } else if (flagValue(arg, "start-file")) |value| {
            worker.start_file = try parseNumber(a, usize, "--start-file", value);
        } else if (flagValue(arg, "skip-cases")) |value| {
            worker.skip_cases = try parseNumber(a, usize, "--skip-cases", value);
        } else {
            return usage(a, "unknown argument '{s}'", .{arg});
        }
    }
    if (config.fork_text) |text| config.forks = try parseForks(a, text);
    if (config.timeout_secs == 0) return usage(a, "the timeout must be at least 1 second", .{});
    if (is_worker) {
        if (worker.shards == 0 or worker.shard >= worker.shards) return usage(a, "invalid worker shard {d} of {d}", .{ worker.shard, worker.shards });
        config.worker = worker;
    }
    return config;
}

// ---------------------------------------------------------------------------
// Worker: files -> cases -> results
// ---------------------------------------------------------------------------

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

/// Sorted paths, relative to `root`, of every `*.json` fixture below it.
fn collectFiles(a: Allocator, root: []const u8) ![]const []const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".json")) continue;
        // `.meta/index.json` describes the release; it is not a fixture.
        if (std.mem.startsWith(u8, entry.path, ".meta")) continue;
        try files.append(a, try a.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, files.items, {}, stringLessThan);
    return files.items;
}

/// `for_prague/prague/eip7702_set_code_tx/x.json` -> `prague/eip7702_set_code_tx`.
fn suiteOf(path: []const u8) []const u8 {
    var rest = path;
    if (std.mem.startsWith(u8, rest, "for_")) {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return rest;
        rest = rest[slash + 1 ..];
    }
    const first = std.mem.indexOfScalar(u8, rest, '/') orelse return rest;
    const second = std.mem.indexOfScalarPos(u8, rest, first + 1, '/') orelse return rest[0..first];
    return rest[0..second];
}

/// True when the raw fixture text names one of the selected forks as a key.
fn mentionsSelectedFork(data: []const u8, forks: ForkSet) bool {
    inline for (comptime std.meta.tags(Fork)) |fork| {
        if (forks.contains(fork)) {
            if (std.mem.indexOf(u8, data, "\"" ++ @tagName(fork) ++ "\"") != null) return true;
        }
    }
    inline for (Fork.aliases) |alias| {
        if (forks.contains(alias.fork)) {
            if (std.mem.indexOf(u8, data, "\"" ++ alias.name ++ "\"") != null) return true;
        }
    }
    return false;
}

const Worker = struct {
    gpa: Allocator,
    config: *const Config,
    sink: *Sink,
    root: std.Io.Dir,

    fn run(self: *Worker, files: []const []const u8, args: WorkerArgs) !void {
        for (files, 0..) |path, index| {
            if (index < args.start_file or index % args.shards != args.shard) continue;
            try self.sink.fileStart(index);
            try self.runFile(path, if (index == args.start_file) args.skip_cases else 0);
            try self.sink.fileDone(index);
        }
    }

    fn runFile(self: *Worker, path: []const u8, skip_cases: usize) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // A filter that names a "<file>::<test>" pair can only match this
        // file when the path contains its file part.
        if (self.config.filter) |filter| {
            if (std.mem.indexOf(u8, filter, "::")) |separator| {
                if (!std.mem.endsWith(u8, path, filter[0..separator]) and std.mem.indexOf(u8, path, filter[0..separator]) == null) return;
            }
        }
        const data = try self.root.readFileAlloc(io, path, arena, .limited(max_fixture_bytes + 1));
        if (self.config.fork_text != null and !mentionsSelectedFork(data, self.config.forks)) return;
        // Skip the JSON parse when neither the path nor the text can match.
        if (self.config.filter) |filter| {
            const name_part = if (std.mem.indexOf(u8, filter, "::")) |separator| filter[separator + 2 ..] else filter;
            if (std.mem.indexOf(u8, path, filter) == null and std.mem.indexOf(u8, data, name_part) == null) return;
        }

        const suite = suiteOf(path);
        var ordinal: usize = 0;
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try self.reportFixtureError(&ordinal, skip_cases, suite, path, "", @errorName(err));
                return;
            },
        };
        const tests = asObject(root) catch |err| {
            try self.reportFixtureError(&ordinal, skip_cases, suite, path, "", @errorName(err));
            return;
        };

        var it = tests.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (self.config.filter) |filter| {
                const id = try std.fmt.allocPrint(arena, "{s}::{s}", .{ path, name });
                if (std.mem.indexOf(u8, id, filter) == null) continue;
            }
            const test_case = parseTestCase(arena, entry.value_ptr.*) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    try self.reportFixtureError(&ordinal, skip_cases, suite, path, name, @errorName(err));
                    continue;
                },
            };
            try self.runTest(&ordinal, skip_cases, suite, path, name, &test_case);
        }
    }

    fn reportFixtureError(self: *Worker, ordinal: *usize, skip_cases: usize, suite: []const u8, path: []const u8, name: []const u8, detail: []const u8) !void {
        defer ordinal.* += 1;
        if (ordinal.* < skip_cases) return;
        try self.sink.caseStart(.{ .ordinal = ordinal.*, .fork = "(fixture)", .suite = suite, .file = path, .name = name });
        try self.sink.fail("fixture_error", detail);
    }

    fn runTest(self: *Worker, ordinal: *usize, skip_cases: usize, suite: []const u8, path: []const u8, name: []const u8, test_case: *const TestCase) !void {
        var it = test_case.post.iterator();
        while (it.next()) |entry| {
            const fork_name = entry.key_ptr.*;
            const posts: []const std.json.Value = switch (entry.value_ptr.*) {
                .array => |array| array.items,
                else => {
                    try self.reportFixtureError(ordinal, skip_cases, suite, path, name, "ExpectedJsonArray");
                    continue;
                },
            };
            const fork = Fork.parse(fork_name) orelse {
                // A fork Guillotine does not implement yet (Amsterdam, BPO*).
                if (self.config.fork_text == null) {
                    if (ordinal.* >= skip_cases) try self.sink.skip(ordinal.*, fork_name, posts.len);
                    ordinal.* += 1;
                }
                continue;
            };
            if (!self.config.forks.contains(fork)) continue;

            for (posts, 0..) |post_value, post_index| {
                defer ordinal.* += 1;
                if (ordinal.* < skip_cases) continue;
                try self.sink.caseStart(.{
                    .ordinal = ordinal.*,
                    .fork = @tagName(fork),
                    .suite = suite,
                    .file = path,
                    .name = name,
                    .post_index = post_index,
                });

                var case_arena = std.heap.ArenaAllocator.init(self.gpa);
                defer case_arena.deinit();
                const a = case_arena.allocator();

                const post = parsePost(a, post_value) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => {
                        try self.sink.fail("fixture_error", @errorName(err));
                        continue;
                    },
                };
                const outcome = runPost(fork, a, self.gpa, fork_name, test_case, post) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => {
                        try self.sink.fail("runner_error", @errorName(err));
                        continue;
                    },
                };
                switch (outcome) {
                    .pass => try self.sink.pass(),
                    .fail => |failure| try self.sink.fail(failure.category, failure.detail),
                }
            }
        }
    }
};

const WorkerThread = struct {
    config: *const Config,
    sink: *Sink,
    files: []const []const u8,
    args: WorkerArgs,
    err: ?anyerror = null,

    /// Runs on a large stack: the EVM recurses once per call depth.
    fn entry(self: *WorkerThread) void {
        self.body() catch |err| {
            self.err = err;
        };
    }

    fn body(self: *WorkerThread) !void {
        var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
        const use_debug_allocator = builtin.mode == .debug;
        const gpa = if (use_debug_allocator) debug_allocator.allocator() else std.heap.smp_allocator;

        var root = try std.Io.Dir.cwd().openDir(io, self.config.fixtures_dir, .{});
        defer root.close(io);

        // The KZG point-evaluation precompile needs the trusted setup.
        try evm.kzg_setup.init();

        var worker = Worker{ .gpa = gpa, .config = self.config, .sink = self.sink, .root = root };
        try worker.run(self.files, self.args);

        var leak_check = LeakCheck.not_run;
        if (use_debug_allocator) {
            evm.kzg_setup.deinit(gpa);
            leak_check = if (debug_allocator.deinit() == .leak) .leaked else .clean;
        }
        try self.sink.end(leak_check);
    }
};

fn runWorkerThread(config: *const Config, sink: *Sink, files: []const []const u8, args: WorkerArgs) !void {
    var context = WorkerThread{ .config = config, .sink = sink, .files = files, .args = args };
    const thread = try std.Thread.spawn(.{ .stack_size = worker_stack_bytes }, WorkerThread.entry, .{&context});
    thread.join();
    if (context.err) |err| return err;
}

// ---------------------------------------------------------------------------
// Parent: worker processes, crash isolation, time limits
// ---------------------------------------------------------------------------

const Supervised = struct {
    shard: usize,
    child: ?std.process.Child = null,
    buffer: std.ArrayList(u8) = .empty,
    /// File and case in flight, used to attribute a crash.
    open_file: ?usize = null,
    open_case: ?CaseInfo = null,
    case_started_ms: i64 = 0,
    /// Where a restarted worker resumes.
    next_file: usize = 0,
    next_ordinal: usize = 0,
    /// Resume point of the previous start; a restart must move past it.
    last_start_file: ?usize = null,
    last_start_ordinal: usize = 0,
    finished: bool = false,
    timed_out: bool = false,
};

const Supervisor = struct {
    a: Allocator,
    config: *const Config,
    aggregator: *Aggregator,
    exe_path: []const u8,
    files: []const []const u8,
    workers: []Supervised,

    fn spawn(self: *Supervisor, worker: *Supervised, start_file: usize, skip_cases: usize) !void {
        if (worker.last_start_file) |previous| {
            if (previous == start_file and worker.last_start_ordinal == skip_cases) return error.WorkerMadeNoProgress;
        }
        worker.last_start_file = start_file;
        worker.last_start_ordinal = skip_cases;

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(self.a, self.exe_path);
        try argv.append(self.a, "--worker");
        try argv.append(self.a, try std.fmt.allocPrint(self.a, "--shard={d}", .{worker.shard}));
        try argv.append(self.a, try std.fmt.allocPrint(self.a, "--shards={d}", .{self.workers.len}));
        try argv.append(self.a, try std.fmt.allocPrint(self.a, "--start-file={d}", .{start_file}));
        try argv.append(self.a, try std.fmt.allocPrint(self.a, "--skip-cases={d}", .{skip_cases}));
        try argv.append(self.a, try std.fmt.allocPrint(self.a, "--fixtures={s}", .{self.config.fixtures_dir}));
        try argv.append(self.a, try std.fmt.allocPrint(self.a, "--fork={s}", .{self.config.fork_text orelse ""}));
        try argv.append(self.a, try std.fmt.allocPrint(self.a, "--filter={s}", .{self.config.filter orelse ""}));

        worker.child = try std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = if (self.config.verbose) .inherit else .ignore,
        });
        worker.open_file = null;
        worker.open_case = null;
        worker.timed_out = false;
        worker.buffer.clearRetainingCapacity();
    }

    fn column(fields: *std.mem.SplitIterator(u8, .scalar)) ![]const u8 {
        return fields.next() orelse error.MalformedWorkerLine;
    }

    fn handleLine(self: *Supervisor, worker: *Supervised, line: []const u8) !void {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const tag = try column(&fields);
        if (tag.len != 1) return error.MalformedWorkerLine;
        switch (tag[0]) {
            'F' => {
                worker.open_file = try std.fmt.parseInt(usize, try column(&fields), 10);
                worker.next_ordinal = 0;
            },
            'D' => {
                const index = try std.fmt.parseInt(usize, try column(&fields), 10);
                worker.open_file = null;
                worker.next_file = index + 1;
                worker.next_ordinal = 0;
            },
            'S' => {
                const ordinal = try std.fmt.parseInt(usize, try column(&fields), 10);
                const fork = try self.a.dupe(u8, try column(&fields));
                const suite = try self.a.dupe(u8, try column(&fields));
                const file = try self.a.dupe(u8, try column(&fields));
                const name = try self.a.dupe(u8, try column(&fields));
                const post_index = try std.fmt.parseInt(usize, try column(&fields), 10);
                worker.open_case = .{ .ordinal = ordinal, .fork = fork, .suite = suite, .file = file, .name = name, .post_index = post_index };
                worker.case_started_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
            },
            'P' => {
                const info = worker.open_case orelse return error.MalformedWorkerLine;
                try self.aggregator.pass(info);
                worker.next_ordinal = info.ordinal + 1;
                worker.open_case = null;
            },
            'X' => {
                const info = worker.open_case orelse return error.MalformedWorkerLine;
                const category = try column(&fields);
                try self.aggregator.fail(info, category, try column(&fields));
                worker.next_ordinal = info.ordinal + 1;
                worker.open_case = null;
            },
            'K' => {
                const ordinal = try std.fmt.parseInt(usize, try column(&fields), 10);
                const fork = try column(&fields);
                try self.aggregator.skip(fork, try std.fmt.parseInt(u64, try column(&fields), 10));
                worker.next_ordinal = ordinal + 1;
            },
            'E' => {
                const leak = std.meta.stringToEnum(LeakCheck, try column(&fields)) orelse return error.MalformedWorkerLine;
                // One leaking worker marks the run; a clean one never clears it.
                if (leak == .leaked or self.aggregator.leak_check == .not_run) self.aggregator.leak_check = leak;
                worker.finished = true;
            },
            else => return error.MalformedWorkerLine,
        }
    }

    fn drain(self: *Supervisor, worker: *Supervised) !void {
        while (std.mem.indexOfScalar(u8, worker.buffer.items, '\n')) |newline| {
            try self.handleLine(worker, worker.buffer.items[0..newline]);
            const rest = worker.buffer.items[newline + 1 ..];
            std.mem.copyForwards(u8, worker.buffer.items[0..rest.len], rest);
            worker.buffer.shrinkRetainingCapacity(rest.len);
        }
    }

    /// The worker's stdout closed: reap it, record a lost case, restart.
    fn exited(self: *Supervisor, worker: *Supervised) !void {
        var child = worker.child orelse return error.WorkerNotRunning;
        const term = try child.wait(io);
        worker.child = null;
        if (worker.finished) return;

        const how = switch (term) {
            .exited => |code| try std.fmt.allocPrint(self.a, "worker exited with code {d}", .{code}),
            .signal => |signal| try std.fmt.allocPrint(self.a, "worker killed by signal {d}", .{@intFromEnum(signal)}),
            .stopped => |signal| try std.fmt.allocPrint(self.a, "worker stopped by signal {d}", .{@intFromEnum(signal)}),
            .unknown => |status| try std.fmt.allocPrint(self.a, "worker ended with status {d}", .{status}),
        };
        const category: []const u8 = if (worker.timed_out) "timeout" else "crash";
        const detail = if (worker.timed_out)
            try std.fmt.allocPrint(self.a, "exceeded {d} s, {s}", .{ self.config.timeout_secs, how })
        else
            how;

        if (worker.open_case) |info| {
            try self.aggregator.fail(info, category, detail);
            try self.spawn(worker, worker.open_file orelse worker.next_file, info.ordinal + 1);
            return;
        }
        if (worker.open_file) |index| {
            const started_here = worker.last_start_file == index;
            const start_ordinal = if (started_here) worker.last_start_ordinal else 0;
            if (worker.next_ordinal > start_ordinal) {
                // Died between two cases: resume after the last finished one.
                try self.spawn(worker, index, worker.next_ordinal);
                return;
            }
            if (!started_here) {
                // Died before the first case of a file it reached after other
                // files. An earlier case may have corrupted the heap, so a
                // fresh process gets one attempt at this file.
                try self.spawn(worker, index, 0);
                return;
            }
            // A fresh process died before reaching a case: the rest of the
            // file is lost.
            try self.aggregator.fail(.{ .fork = "(fixture)", .suite = suiteOf(self.files[index]), .file = self.files[index] }, category, detail);
            try self.spawn(worker, index + 1, 0);
            return;
        }
        // Died outside any file. Restart where it stopped; `spawn` refuses a
        // restart that cannot make progress.
        const message = try std.fmt.allocPrint(self.a, "eest-runner: worker {d} failed outside a fixture: {s}\n", .{ worker.shard, how });
        try std.Io.File.stderr().writeStreamingAll(io, message);
        try self.spawn(worker, worker.next_file, 0);
    }

    fn run(self: *Supervisor) !void {
        for (self.workers) |*worker| try self.spawn(worker, 0, 0);

        const fds = try self.a.alloc(std.posix.pollfd, self.workers.len);
        const owners = try self.a.alloc(*Supervised, self.workers.len);
        var chunk: [64 * 1024]u8 = undefined;
        while (true) {
            var live: usize = 0;
            for (self.workers) |*worker| {
                const child = worker.child orelse continue;
                const stdout = child.stdout orelse return error.WorkerHasNoStdout;
                fds[live] = .{ .fd = stdout.handle, .events = std.posix.POLL.IN, .revents = 0 };
                owners[live] = worker;
                live += 1;
            }
            if (live == 0) break;

            _ = try std.posix.poll(fds[0..live], 1000);
            for (fds[0..live], owners[0..live]) |fd, worker| {
                if (fd.revents == 0) continue;
                const count = try std.posix.read(fd.fd, &chunk);
                if (count == 0) {
                    try self.drain(worker);
                    try self.exited(worker);
                    continue;
                }
                try worker.buffer.appendSlice(self.a, chunk[0..count]);
                try self.drain(worker);
            }

            const now = std.Io.Timestamp.now(io, .awake).toMilliseconds();
            const limit_ms: i64 = @intCast(self.config.timeout_secs * 1000);
            for (self.workers) |*worker| {
                const child = worker.child orelse continue;
                if (worker.open_case == null or worker.timed_out) continue;
                if (now - worker.case_started_ms <= limit_ms) continue;
                worker.timed_out = true;
                const pid = child.id orelse continue;
                std.posix.kill(pid, std.posix.SIG.KILL) catch |err| switch (err) {
                    // Already gone: the closed pipe reports the exit.
                    error.ProcessNotFound => {},
                    else => return err,
                };
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

fn jsonString(a: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(a, '"');
    for (text) |char| {
        switch (char) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            else => {
                if (char < 0x20) {
                    const digits = "0123456789abcdef";
                    try out.appendSlice(a, &.{ '\\', 'u', '0', '0', digits[char >> 4], digits[char & 0x0f] });
                } else {
                    try out.append(a, char);
                }
            },
        }
    }
    try out.append(a, '"');
}

fn jsonKey(a: Allocator, out: *std.ArrayList(u8), first: *bool, key: []const u8) !void {
    if (!first.*) try out.append(a, ',');
    first.* = false;
    try jsonString(a, out, key);
    try out.append(a, ':');
}

fn jsonNumber(a: Allocator, out: *std.ArrayList(u8), value: u64) !void {
    try out.appendSlice(a, try std.fmt.allocPrint(a, "{d}", .{value}));
}

fn jsonOptionalString(a: Allocator, out: *std.ArrayList(u8), value: ?[]const u8) !void {
    if (value) |text| return jsonString(a, out, text);
    try out.appendSlice(a, "null");
}

const RunInfo = struct {
    config: *const Config,
    release: ?[]const u8,
    files: usize,
    duration_ms: u64,
};

fn renderReport(a: Allocator, aggregator: *const Aggregator, info: RunInfo) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var first = true;
    try out.append(a, '{');
    try jsonKey(a, &out, &first, "schema");
    try jsonString(a, &out, report_schema);
    try jsonKey(a, &out, &first, "fixtures_dir");
    try jsonString(a, &out, info.config.fixtures_dir);
    try jsonKey(a, &out, &first, "release");
    try jsonOptionalString(a, &out, info.release);
    try jsonKey(a, &out, &first, "fork_filter");
    try jsonOptionalString(a, &out, info.config.fork_text);
    try jsonKey(a, &out, &first, "test_filter");
    try jsonOptionalString(a, &out, info.config.filter);
    try jsonKey(a, &out, &first, "optimize");
    try jsonString(a, &out, @tagName(builtin.mode));
    try jsonKey(a, &out, &first, "jobs");
    try jsonNumber(a, &out, info.config.jobs);
    try jsonKey(a, &out, &first, "duration_ms");
    try jsonNumber(a, &out, info.duration_ms);
    try jsonKey(a, &out, &first, "leak_check");
    try jsonString(a, &out, @tagName(aggregator.leak_check));

    try jsonKey(a, &out, &first, "totals");
    try out.append(a, '{');
    var totals_first = true;
    try jsonKey(a, &out, &totals_first, "files");
    try jsonNumber(a, &out, info.files);
    try jsonKey(a, &out, &totals_first, "cases");
    try jsonNumber(a, &out, aggregator.passed + aggregator.failed);
    try jsonKey(a, &out, &totals_first, "passed");
    try jsonNumber(a, &out, aggregator.passed);
    try jsonKey(a, &out, &totals_first, "failed");
    try jsonNumber(a, &out, aggregator.failed);
    try jsonKey(a, &out, &totals_first, "skipped");
    try jsonNumber(a, &out, aggregator.skipped_total);
    try out.append(a, '}');

    try jsonKey(a, &out, &first, "forks");
    try out.append(a, '{');
    var forks_first = true;
    var fork_it = aggregator.forks.iterator();
    while (fork_it.next()) |fork| {
        try jsonKey(a, &out, &forks_first, fork.key_ptr.*);
        try out.append(a, '{');
        var fork_first = true;
        try jsonKey(a, &out, &fork_first, "passed");
        try jsonNumber(a, &out, fork.value_ptr.counts.passed);
        try jsonKey(a, &out, &fork_first, "failed");
        try jsonNumber(a, &out, fork.value_ptr.counts.failed);
        try jsonKey(a, &out, &fork_first, "failure_reasons");
        try out.append(a, '{');
        var reasons_first = true;
        var reason_it = fork.value_ptr.reasons.iterator();
        while (reason_it.next()) |reason| {
            try jsonKey(a, &out, &reasons_first, reason.key_ptr.*);
            try jsonNumber(a, &out, reason.value_ptr.*);
        }
        try out.append(a, '}');
        try jsonKey(a, &out, &fork_first, "suites");
        try out.append(a, '{');
        var suites_first = true;
        var suite_it = fork.value_ptr.suites.iterator();
        while (suite_it.next()) |suite| {
            try jsonKey(a, &out, &suites_first, suite.key_ptr.*);
            try out.append(a, '{');
            var suite_first = true;
            try jsonKey(a, &out, &suite_first, "passed");
            try jsonNumber(a, &out, suite.value_ptr.passed);
            try jsonKey(a, &out, &suite_first, "failed");
            try jsonNumber(a, &out, suite.value_ptr.failed);
            try out.append(a, '}');
        }
        try out.append(a, '}');
        try out.append(a, '}');
    }
    try out.append(a, '}');

    try jsonKey(a, &out, &first, "skipped_forks");
    try out.append(a, '{');
    var skipped_first = true;
    var skipped_it = aggregator.skipped.iterator();
    while (skipped_it.next()) |skipped| {
        try jsonKey(a, &out, &skipped_first, skipped.key_ptr.*);
        try jsonNumber(a, &out, skipped.value_ptr.*);
    }
    try out.append(a, '}');

    try jsonKey(a, &out, &first, "failure_reasons");
    try out.append(a, '{');
    var reasons_first = true;
    var reason_it = aggregator.reasons.iterator();
    while (reason_it.next()) |reason| {
        try jsonKey(a, &out, &reasons_first, reason.key_ptr.*);
        try out.append(a, '{');
        var reason_first = true;
        try jsonKey(a, &out, &reason_first, "count");
        try jsonNumber(a, &out, reason.value_ptr.count);
        try jsonKey(a, &out, &reason_first, "examples");
        try out.append(a, '[');
        for (reason.value_ptr.examples.items, 0..) |example, index| {
            if (index > 0) try out.append(a, ',');
            try out.append(a, '{');
            var example_first = true;
            try jsonKey(a, &out, &example_first, "fork");
            try jsonString(a, &out, example.fork);
            try jsonKey(a, &out, &example_first, "file");
            try jsonString(a, &out, example.file);
            try jsonKey(a, &out, &example_first, "test");
            try jsonString(a, &out, example.name);
            try jsonKey(a, &out, &example_first, "index");
            try jsonNumber(a, &out, example.post_index);
            try jsonKey(a, &out, &example_first, "detail");
            try jsonString(a, &out, example.detail);
            try out.append(a, '}');
        }
        try out.append(a, ']');
        try out.append(a, '}');
    }
    try out.append(a, '}');
    try out.appendSlice(a, "}\n");
    return out.toOwnedSlice(a);
}

fn forkOrder(_: void, lhs: []const u8, rhs: []const u8) bool {
    const left = Fork.parse(lhs);
    const right = Fork.parse(rhs);
    if (left != null and right != null) return @intFromEnum(left.?) < @intFromEnum(right.?);
    if (left != null) return true;
    if (right != null) return false;
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn renderSummary(a: Allocator, aggregator: *const Aggregator, info: RunInfo) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, try std.fmt.allocPrint(a, "EEST state tests: {s} ({s}), {d} files, {d} ms, {s}\n\n", .{
        info.release orelse "unknown release",
        info.config.fixtures_dir,
        info.files,
        info.duration_ms,
        @tagName(builtin.mode),
    }));
    try out.appendSlice(a, try std.fmt.allocPrint(a, "{s:<20} {s:>8} {s:>8} {s:>8} {s:>8}\n", .{ "fork", "passed", "failed", "total", "pass %" }));

    const names = try a.dupe([]const u8, aggregator.forks.keys());
    std.mem.sort([]const u8, names, {}, forkOrder);
    for (names) |name| {
        const counts = (aggregator.forks.get(name) orelse continue).counts;
        const total = counts.passed + counts.failed;
        const percent: f64 = if (total == 0) 0 else @as(f64, @floatFromInt(counts.passed)) * 100.0 / @as(f64, @floatFromInt(total));
        try out.appendSlice(a, try std.fmt.allocPrint(a, "{s:<20} {d:>8} {d:>8} {d:>8} {d:>8.2}\n", .{ name, counts.passed, counts.failed, total, percent }));
    }
    const total = aggregator.passed + aggregator.failed;
    const percent: f64 = if (total == 0) 0 else @as(f64, @floatFromInt(aggregator.passed)) * 100.0 / @as(f64, @floatFromInt(total));
    try out.appendSlice(a, try std.fmt.allocPrint(a, "{s:<20} {d:>8} {d:>8} {d:>8} {d:>8.2}\n", .{ "TOTAL", aggregator.passed, aggregator.failed, total, percent }));

    if (aggregator.skipped_total > 0) {
        try out.appendSlice(a, "\nskipped (fork not supported):");
        var skipped_it = aggregator.skipped.iterator();
        while (skipped_it.next()) |skipped| {
            try out.appendSlice(a, try std.fmt.allocPrint(a, " {s}={d}", .{ skipped.key_ptr.*, skipped.value_ptr.* }));
        }
        try out.append(a, '\n');
    }

    if (aggregator.reasons.count() > 0) {
        try out.appendSlice(a, "\nfailure reasons:\n");
        var reason_it = aggregator.reasons.iterator();
        while (reason_it.next()) |reason| {
            try out.appendSlice(a, try std.fmt.allocPrint(a, "  {d:>7}  {s}\n", .{ reason.value_ptr.count, reason.key_ptr.* }));
            if (reason.value_ptr.examples.items.len > 0) {
                const example = reason.value_ptr.examples.items[0];
                try out.appendSlice(a, try std.fmt.allocPrint(a, "           e.g. [{s}] {s}::{s} #{d}\n                {s}\n", .{ example.fork, example.file, example.name, example.post_index, example.detail }));
            }
        }
    }
    try out.appendSlice(a, try std.fmt.allocPrint(a, "\nleak check: {s}\n", .{@tagName(aggregator.leak_check)}));
    return out.toOwnedSlice(a);
}

/// Reads the release tag that `scripts/fetch-eest-fixtures.sh` stamps beside
/// the `fixtures` directory.
fn readRelease(a: Allocator, fixtures_dir: []const u8) !?[]const u8 {
    const path = try std.Io.Dir.path.join(a, &.{ fixtures_dir, "..", "..", "STAMP" });
    const stamp = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096 + 1)) catch |err| switch (err) {
        // Fixtures fetched by other means carry no stamp.
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    var lines = std.mem.splitScalar(u8, stamp, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "tag=")) return line["tag=".len..];
    }
    return null;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Maps a reported usage problem to exit code 2; any other error propagates.
fn exitUsage(err: anyerror) !u8 {
    if (err == error.Usage) return 2;
    return err;
}

pub fn main(init: std.process.Init) !u8 {
    io = init.io;
    environ_map = init.environ_map;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const args = try init.minimal.args.toSlice(a);
    const config = loadConfig(a, args) catch |err| return exitUsage(err);

    const files = collectFiles(a, config.fixtures_dir) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return exitUsage(usage(a, "fixture directory '{s}' not found; run scripts/fetch-eest-fixtures.sh or set EEST_FIXTURES_DIR", .{config.fixtures_dir})),
        else => return err,
    };

    if (config.worker) |worker_args| {
        var sink = Sink{ .target = .{ .pipe = std.Io.File.stdout() }, .a = a };
        try runWorkerThread(&config, &sink, files, worker_args);
        return 0;
    }

    if (files.len == 0) return exitUsage(usage(a, "no *.json fixtures below '{s}'", .{config.fixtures_dir}));

    const started = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    var aggregator = Aggregator{ .a = a, .verbose = config.verbose };
    if (config.jobs == 0) {
        var sink = Sink{ .target = .{ .direct = &aggregator }, .a = a };
        try runWorkerThread(&config, &sink, files, .{ .shard = 0, .shards = 1, .start_file = 0, .skip_cases = 0 });
    } else {
        const count = @min(config.jobs, files.len);
        const workers = try a.alloc(Supervised, count);
        for (workers, 0..) |*worker, shard| worker.* = .{ .shard = shard };
        var supervisor = Supervisor{
            .a = a,
            .config = &config,
            .aggregator = &aggregator,
            .exe_path = try std.process.executablePathAlloc(io, a),
            .files = files,
            .workers = workers,
        };
        try supervisor.run();
    }

    const info = RunInfo{
        .config = &config,
        .release = try readRelease(a, config.fixtures_dir),
        .files = files.len,
        .duration_ms = @intCast(std.Io.Timestamp.now(io, .awake).toMilliseconds() - started),
    };
    try std.Io.File.stdout().writeStreamingAll(io, try renderSummary(a, &aggregator, info));
    if (config.report) |path| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try renderReport(a, &aggregator, info) });
    }

    if (aggregator.passed + aggregator.failed == 0) {
        return exitUsage(usage(a, "no test case matched the fork and filter selection", .{}));
    }
    return if (aggregator.failed == 0) 0 else 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Fork.parse accepts fixture names and aliases" {
    try std.testing.expectEqual(Fork.Paris, Fork.parse("Paris").?);
    try std.testing.expectEqual(Fork.Paris, Fork.parse("merge").?);
    try std.testing.expectEqual(Fork.TangerineWhistle, Fork.parse("EIP150").?);
    try std.testing.expectEqual(Fork.SpuriousDragon, Fork.parse("EIP158").?);
    try std.testing.expectEqual(Fork.ConstantinopleFix, Fork.parse("ConstantinopleFix").?);
    try std.testing.expect(Fork.parse("Amsterdam") == null);
    try std.testing.expect(Fork.parse("ShanghaiToCancunAtTime15k") == null);
}

test "parseU256 is strict about the 0x prefix and width" {
    try std.testing.expectEqual(@as(u256, 0), try parseU256("0x"));
    try std.testing.expectEqual(@as(u256, 0x2015), try parseU256("0x2015"));
    try std.testing.expectEqual(@as(u256, 1), try parseU256("0x0000000000000000000000000000000000000000000000000000000000000000000001"));
    try std.testing.expectError(error.MissingHexPrefix, parseU256("2015"));
    try std.testing.expectError(error.HexValueTooLarge, parseU256("0x10000000000000000000000000000000000000000000000000000000000000000"));
    try std.testing.expectError(error.HexValueTooLarge, parseU64("0x10000000000000000"));
}

test "RLP encodes scalars, strings and long lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayList(u8) = .empty;
    try rlpAppendUint(a, &out, 0);
    try rlpAppendUint(a, &out, 0x7f);
    try rlpAppendUint(a, &out, 0x80);
    try rlpAppendUint(a, &out, 0x0400);
    try rlpAppendBytes(a, &out, "dog");
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x7f, 0x81, 0x80, 0x82, 0x04, 0x00, 0x83, 'd', 'o', 'g' }, out.items);

    const long = try rlpWrapList(a, &(@as([60]u8, @splat(0x01))));
    try std.testing.expectEqual(@as(u8, 0xf8), long[0]);
    try std.testing.expectEqual(@as(u8, 60), long[1]);
    try std.testing.expectEqual(@as(usize, 62), long.len);

    const decoded = try rlpDecode(long);
    try std.testing.expect(decoded.is_list);
    try std.testing.expectEqual(@as(usize, 60), decoded.payload.len);
    try std.testing.expectEqual(@as(usize, 62), decoded.size);
}

test "empty trie and empty log list hash to the well-known constants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualSlices(u8, &empty_trie_root, &keccak(&.{0x80}));
    try std.testing.expectEqualSlices(u8, &empty_trie_root, &try trieRoot(a, &.{}));

    const empty_logs = try parseFixed(32, "0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347");
    try std.testing.expectEqualSlices(u8, &empty_logs, &try logsHash(a, &[_]evm.Log{}));
}

test "state root of one funded account matches the reference value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var db = Database.init(std.testing.allocator);
    defer db.deinit();
    var account = Account.zero();
    account.balance = 1;
    try db.set_account(try parseFixed(20, "0x0000000000000000000000000000000000000001"), account);

    // A one-leaf trie: keccak(rlp([hexPrefix(keccak(address)), rlp(account)])).
    const address = try parseFixed(20, "0x0000000000000000000000000000000000000001");
    var payload: std.ArrayList(u8) = .empty;
    try rlpAppendUint(a, &payload, 0);
    try rlpAppendUint(a, &payload, 1);
    try rlpAppendBytes(a, &payload, &empty_trie_root);
    try rlpAppendBytes(a, &payload, &emptyCodeHash());
    const account_rlp = try rlpWrapList(a, payload.items);
    var leaf: std.ArrayList(u8) = .empty;
    var path: [33]u8 = undefined;
    path[0] = 0x20;
    @memcpy(path[1..], &keccak(&address));
    try rlpAppendBytes(a, &leaf, &path);
    try rlpAppendBytes(a, &leaf, account_rlp);
    const expected = keccak(try rlpWrapList(a, leaf.items));

    try std.testing.expectEqualSlices(u8, &expected, &try stateRoot(a, &db));
}

test "trie root does not depend on insertion order and separates branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var forward: [3]TrieEntry = undefined;
    var backward: [3]TrieEntry = undefined;
    const values = [_][]const u8{ "one", "two", "three" };
    for (values, 0..) |value, index| {
        const key = keccak(value);
        forward[index] = .{ .key = key, .value = value };
        backward[2 - index] = .{ .key = key, .value = value };
    }
    const root = try trieRoot(a, &forward);
    try std.testing.expectEqualSlices(u8, &root, &try trieRoot(a, &backward));

    var changed = forward;
    changed[0].value = "ONE";
    try std.testing.expect(!std.mem.eql(u8, &root, &try trieRoot(a, &changed)));
}

test "intrinsic gas follows each fork's schedule" {
    const template = TxTemplate{
        .chain_id = 1,
        .nonce = 0,
        .gas_price = 10,
        .max_fee_per_gas = null,
        .max_priority_fee_per_gas = null,
        .max_fee_per_blob_gas = null,
        .to = null,
        .sender = @as([20]u8, @splat(0)),
        .data = &.{},
        .gas_limit = &.{},
        .value = &.{},
        .access_lists = null,
        .blob_hashes = null,
        .authorizations = null,
    };
    const data = [_]u8{ 0x00, 0x01 } ++ @as([31]u8, @splat(0x02));
    const tx = Tx{ .template = &template, .data = &data, .gas_limit = 0, .value = 0, .access_list = &.{} };

    // Frontier: no creation surcharge, 68 gas per non-zero byte.
    try std.testing.expectEqual(@as(u64, 21000 + 4 + 32 * 68), intrinsicGas(.Frontier, tx).gas);
    // Homestead adds 32000 for creation.
    try std.testing.expectEqual(@as(u64, 53000 + 4 + 32 * 68), intrinsicGas(.Homestead, tx).gas);
    // Istanbul lowers non-zero bytes to 16.
    try std.testing.expectEqual(@as(u64, 53000 + 4 + 32 * 16), intrinsicGas(.Istanbul, tx).gas);
    // Shanghai charges 2 gas per initcode word (33 bytes = 2 words).
    try std.testing.expectEqual(@as(u64, 53000 + 4 + 32 * 16 + 4), intrinsicGas(.Shanghai, tx).gas);
    // Prague adds the calldata floor: 21000 + 10 * (1 + 4 * 32).
    try std.testing.expectEqual(@as(u64, 21000 + 10 * 129), intrinsicGas(.Prague, tx).floor);
    try std.testing.expectEqual(@as(u64, 0), intrinsicGas(.Cancun, tx).floor);
}

test "blob base fee matches EIP-4844 reference points" {
    try std.testing.expectEqual(@as(u256, 1), blobBaseFee(0, 3338477));
    try std.testing.expectEqual(@as(u256, 1), blobBaseFee(2314057, 3338477));
    try std.testing.expectEqual(@as(u256, 2), blobBaseFee(2314058, 3338477));
    try std.testing.expectEqual(@as(u256, 23), blobBaseFee(10 * 1024 * 1024, 3338477));
}

test "exceptionExpected matches any listed alternative" {
    const expected = "TransactionException.INSUFFICIENT_ACCOUNT_FUNDS|TransactionException.INTRINSIC_GAS_TOO_LOW";
    try std.testing.expect(exceptionExpected(expected, .INTRINSIC_GAS_TOO_LOW));
    try std.testing.expect(exceptionExpected(expected, .INSUFFICIENT_ACCOUNT_FUNDS));
    try std.testing.expect(!exceptionExpected(expected, .NONCE_IS_MAX));
}

test "decodeSignature reads legacy and typed transactions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fields: std.ArrayList(u8) = .empty;
    for ([_]u256{ 0, 10, 21000 }) |value| try rlpAppendUint(a, &fields, value);
    try rlpAppendBytes(a, &fields, &(@as([20]u8, @splat(0xaa))));
    for ([_]u256{ 1, 0, 37, 0x1234, 0x5678 }) |value| try rlpAppendUint(a, &fields, value);
    const legacy = try rlpWrapList(a, fields.items);

    const legacy_signature = try decodeSignature(legacy);
    try std.testing.expectEqual(@as(u8, 0), legacy_signature.tx_type);
    try std.testing.expectEqual(@as(u256, 37), legacy_signature.v);
    try std.testing.expectEqual(@as(u256, 0x1234), legacy_signature.r);
    try std.testing.expectEqual(@as(u256, 0x5678), legacy_signature.s);

    const typed = try std.mem.concat(a, u8, &.{ &[_]u8{0x02}, legacy });
    try std.testing.expectEqual(@as(u8, 2), (try decodeSignature(typed)).tx_type);
}

test "isCurveX accepts the generator and rejects a non-residue" {
    try std.testing.expect(isCurveX(crypto.secp256k1.SECP256K1_GX));
    // x = 5: 5^3 + 7 = 132 is not a square modulo p.
    try std.testing.expect(!isCurveX(5));
    try std.testing.expect(!isCurveX(crypto.secp256k1.SECP256K1_P));
}

test "suiteOf strips the per-fork directory" {
    try std.testing.expectEqualStrings("prague/eip7702_set_code_tx", suiteOf("for_prague/prague/eip7702_set_code_tx/calls/x.json"));
    try std.testing.expectEqualStrings("shanghai/eip3855_push0", suiteOf("shanghai/eip3855_push0/push0.json"));
    try std.testing.expectEqualStrings("x.json", suiteOf("x.json"));
}

test "state test block hashes are keccak256 of the decimal block number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(usize, 0), (try stateTestBlockHashes(a, 0)).len);
    const one = try stateTestBlockHashes(a, 1);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "044852b2a670ade5407e78fb2863c51de9fcb96542a07186fe3aeda6bb8a116d");
    try std.testing.expectEqualSlices(u8, &expected, &one[0]);
    const many = try stateTestBlockHashes(a, 1000);
    try std.testing.expectEqual(@as(usize, 256), many.len);
    try std.testing.expectEqualSlices(u8, &keccak("999"), &many[0]);
    try std.testing.expectEqualSlices(u8, &keccak("744"), &many[255]);
}
