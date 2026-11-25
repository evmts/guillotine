//! Known-answer tests for `Database.get_state_root`.
//!
//! Expected roots come from an independent pure-Python Keccak-256 and Merkle
//! Patricia Trie that reproduces the Ethereum "puppy" trie vector
//! (0x5991bb8c...e9ac84). Before Round 1 integration, get_state_root used
//! src/trie/hash_builder.zig, which double-freed key nibbles, read freed
//! account encodings (index out of bounds), encoded nonces in native byte order,
//! and ignored storage.

const std = @import("std");
const evm = @import("evm");

test "state root: empty state is the empty trie root" {
    var db = evm.Database.init(std.testing.allocator);
    defer db.deinit();
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421");
    try std.testing.expectEqualSlices(u8, &expected, &try db.get_state_root());
}

test "state root: one account without code or storage" {
    var db = evm.Database.init(std.testing.allocator);
    defer db.deinit();
    var account = evm.Account.zero();
    account.nonce = 1;
    account.balance = 100;
    try db.set_account(([_]u8{1} ++ @as([19]u8, @splat(0))), account);
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "72876a3f96934b848192ceca8054921d913e1d87c76ac7128b3cc943299ce2d5");
    try std.testing.expectEqualSlices(u8, &expected, &try db.get_state_root());
}

test "state root: 0x80 nonce and balance, storage, zero slot, and code" {
    var db = evm.Database.init(std.testing.allocator);
    defer db.deinit();

    var a1 = evm.Account.zero();
    a1.nonce = 0x80;
    a1.balance = 0x80;
    try db.set_account(([_]u8{1} ++ @as([19]u8, @splat(0))), a1);

    var a2 = evm.Account.zero();
    a2.balance = 1_000_000_000_000_000_000;
    try db.set_account(([_]u8{2} ++ @as([19]u8, @splat(0))), a2);
    try db.set_storage(([_]u8{2} ++ @as([19]u8, @splat(0))), 1, 0x80);
    try db.set_storage(([_]u8{2} ++ @as([19]u8, @splat(0))), 2, 0); // zero slots are not in the trie
    try db.set_storage(([_]u8{2} ++ @as([19]u8, @splat(0))), 0xdeadbeef, @as(u256, 1) << 255);

    const code = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55, 0x00 };
    var a3 = evm.Account.zero();
    a3.nonce = 1;
    a3.code_hash = try db.set_code(&code);
    try db.set_account(([_]u8{3} ++ @as([19]u8, @splat(0))), a3);

    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "f3da82c858f78fb994976088a17c8124e6d17c9ac66c14c3d001e03ef74fc6b9");
    try std.testing.expectEqualSlices(u8, &expected, &try db.get_state_root());
    // Deterministic and free of leaks across repeated calls.
    try std.testing.expectEqualSlices(u8, &expected, &try db.commit_changes());
}

test "state root: 200 accounts with one storage slot each" {
    var db = evm.Database.init(std.testing.allocator);
    defer db.deinit();
    var i: u64 = 1;
    while (i <= 200) : (i += 1) {
        var a: [20]u8 = @splat(0);
        a[0] = 0xA0;
        std.mem.writeInt(u64, a[12..20], i, .big);
        var account = evm.Account.zero();
        account.nonce = i;
        account.balance = @as(u256, i) * 1000;
        try db.set_account(a, account);
        try db.set_storage(a, i, i);
    }
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "9e16e685b15ff5f40fe48ff9a754a8adeecc45b8e027bbd08b5a809bfd6834fd");
    try std.testing.expectEqualSlices(u8, &expected, &try db.get_state_root());
}
