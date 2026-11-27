//! One hash for a storage slot `(address, key)`, shared by every table that is
//! keyed by a slot: the access list, the journal's original-value index and the
//! database's slot stores.
//!
//! SSTORE consults all of them for the same slot. With one shared hash over the
//! seven 64-bit limbs of `(address, key)` — four independent 64x64->128 multiply-
//! folds combined additively and finished with the bijective SplitMix64 avalanche —
//! the handler hashes the slot once and passes the digest to every lookup through
//! the hash maps' adapted interface (`Prehashed`, `PrehashedIndexed`), without
//! exposing any single-limb zero-cancellation multi-collision.

const std = @import("std");

const secret = [_]u64{
    0xa0761d6478bd642f,
    0xe7037ed1a0b428db,
    0x8ebc6af09c88c6e3,
    0x589965cc75374cc3,
    0x1d8e4e27c47d124f,
    0x2d358dccaa6c78a5,
};

/// Multiply two words and fold the 128-bit product to 64 bits.
inline fn fold(a: u64, b: u64) u64 {
    const product = @as(u128, a) *% @as(u128, b);
    return @as(u64, @truncate(product)) ^ @as(u64, @truncate(product >> 64));
}

/// Hash of the storage slot `key` of `address`.
pub inline fn hash(address: [20]u8, key: u256) u64 {
    const a0 = std.mem.readInt(u64, address[0..8], .little);
    const a1 = std.mem.readInt(u64, address[8..16], .little);
    const a2: u64 = std.mem.readInt(u32, address[16..20], .little);
    const k0: u64 = @truncate(key);
    const k1: u64 = @truncate(key >> 64);
    const k2: u64 = @truncate(key >> 128);
    const k3: u64 = @truncate(key >> 192);

    const low = fold(k0 ^ secret[0], a0 ^ secret[1]);
    const mid = fold(k1 ^ secret[2], a1 ^ secret[3]);
    const high = fold(k2 ^ secret[4], a2 ^ secret[5]);
    const top = fold(k3 ^ secret[1], (a0 ^ a1 ^ a2) ^ secret[2]);

    // Additive combination prevents any single limb from cancelling the whole hash,
    // followed by the bijective SplitMix64 finalizer for full 64-bit avalanche.
    var h = low +% mid +% high +% top +% 52;
    h = (h ^ (h >> 30)) *% 0xbf58476d1ce4e5b9;
    h = (h ^ (h >> 27)) *% 0x94d049bb133111eb;
    return h ^ (h >> 31);
}

/// Adapted `std.HashMap` context for a lookup whose hash is already known.
/// `eqlFn(lookup_key, stored_key)` compares keys, so each table keeps its own
/// key type.
pub fn Prehashed(comptime eqlFn: anytype) type {
    return struct {
        value: u64,

        pub fn hash(self: @This(), key: anytype) u64 {
            _ = key;
            return self.value;
        }

        pub fn eql(self: @This(), a: anytype, b: anytype) bool {
            _ = self;
            return eqlFn(a, b);
        }
    };
}

/// Adapted `std.array_hash_map` context for a lookup whose hash is already
/// known. Array hash maps use 32-bit hashes: the low half of the slot hash.
pub fn PrehashedIndexed(comptime eqlFn: anytype) type {
    return struct {
        value: u64,

        pub fn hash(self: @This(), key: anytype) u32 {
            _ = key;
            return @truncate(self.value);
        }

        pub fn eql(self: @This(), a: anytype, b: anytype, b_index: usize) bool {
            _ = self;
            _ = b_index;
            return eqlFn(a, b);
        }
    };
}

test "slot hash separates addresses, keys and limbs" {
    const a = @as([20]u8, @splat(0xA1));
    var b = a;
    b[19] ^= 1;
    try std.testing.expect(hash(a, 1) != hash(b, 1));
    try std.testing.expect(hash(a, 1) != hash(a, 2));
    try std.testing.expect(hash(a, 1) != hash(a, @as(u256, 1) << 64));
    try std.testing.expect(hash(a, 1) != hash(a, @as(u256, 1) << 128));
    try std.testing.expect(hash(a, 1) != hash(a, @as(u256, 1) << 192));
    try std.testing.expectEqual(hash(a, 7), hash(a, 7));
}

test "slot hash spreads sequential keys over the low and high bits" {
    // `std.HashMap` takes the bucket from the low bits and its 7-bit fingerprint
    // from the high bits, so both must vary for keys that differ by one.
    const address = @as([20]u8, @splat(0x33));
    var low_seen: [256]bool = @splat(false);
    var high_seen: [128]bool = @splat(false);
    var key: u256 = 0;
    while (key < 4096) : (key += 1) {
        const h = hash(address, key);
        low_seen[@as(u8, @truncate(h))] = true;
        high_seen[@as(u7, @truncate(h >> 57))] = true;
    }
    try std.testing.expectEqual(@as(usize, 256), std.mem.count(bool, &low_seen, &.{true}));
    try std.testing.expectEqual(@as(usize, 128), std.mem.count(bool, &high_seen, &.{true}));
}

test "slot hash resists single-limb cancellation multi-collisions" {
    const address = @as([20]u8, @splat(0x42));
    // Verify varying k0..k2 with arbitrary k3 produces distinct non-zero hashes.
    var prev = hash(address, 0);
    var distinct: usize = 0;
    for (1..65) |i| {
        const k = (@as(u256, i) << 192) | (@as(u256, i * 17) << 128) | (@as(u256, i * 31) << 64) | @as(u256, i);
        const h = hash(address, k);
        if (h != prev and h != 0) distinct += 1;
        prev = h;
    }
    try std.testing.expectEqual(@as(usize, 64), distinct);
}
