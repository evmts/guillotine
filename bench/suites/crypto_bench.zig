const std = @import("std");
const micro = @import("micro");
const primitives = @import("voltaire");
const crypto = @import("crypto");
const Uint256 = primitives.Uint(256, 4);

const N: usize = 512;

fn benchKeccak32B(_: std.mem.Allocator) !u64 {
    var data = [_]u8{0x42} ** 32;
    var out: [32]u8 = undefined;
    var acc: u64 = 0;
    for (0..N) |i| {
        data[0] = @truncate(i);
        std.crypto.hash.sha3.Keccak256.hash(&data, &out, .{});
        acc +%= out[0];
    }
    return acc;
}

fn benchKeccak1KB(allocator: std.mem.Allocator) !u64 {
    const data = try allocator.alloc(u8, 1024);
    defer allocator.free(data);
    @memset(data, 0xa5);
    var out: [32]u8 = undefined;
    var acc: u64 = 0;
    for (0..64) |i| {
        data[0] = @truncate(i);
        std.crypto.hash.sha3.Keccak256.hash(data, &out, .{});
        acc +%= out[0];
    }
    return acc;
}

fn benchSha2561KB(allocator: std.mem.Allocator) !u64 {
    const data = try allocator.alloc(u8, 1024);
    defer allocator.free(data);
    @memset(data, 0x5a);
    var out: [32]u8 = undefined;
    var acc: u64 = 0;
    for (0..64) |i| {
        data[0] = @truncate(i);
        std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
        acc +%= out[0];
    }
    return acc;
}

fn benchModexp256(allocator: std.mem.Allocator) !u64 {
    var base: [32]u8 = undefined;
    var exp: [32]u8 = undefined;
    var mod: [32]u8 = undefined;
    std.mem.writeInt(u256, &base, 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef, .big);
    std.mem.writeInt(u256, &exp, 65537, .big);
    std.mem.writeInt(u256, &mod, 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f, .big);
    const out = try crypto.ModExp.modexp(allocator, &base, &exp, &mod);
    defer allocator.free(out);
    return std.mem.readInt(u64, out[24..32], .big);
}

fn benchModexpSmall(allocator: std.mem.Allocator) !u64 {
    var base = [_]u8{42};
    var exp = [_]u8{ 1, 0, 1 };
    var mod = [_]u8{ 0x3b, 0x9a, 0xca, 0x07 };
    var acc: u64 = 0;
    for (0..1024) |_| {
        const out = try crypto.ModExp.modexp(allocator, &base, &exp, &mod);
        defer allocator.free(out);
        acc +%= std.mem.readInt(u32, out[0..4], .big);
    }
    return acc;
}

fn benchUint256DivRem(_: std.mem.Allocator) !u64 {
    var acc: u64 = 0;
    const divisor = Uint256.from_native(0x00000000000000000000000100000000000000000000000000000001000003d1);
    for (0..N) |i| {
        const dividend = Uint256.from_native(
            (@as(u256, i +% 1) << 192) | (@as(u256, i *% 0x9e3779b97f4a7c15) << 64) | 0xdeadbeefcafebabe,
        );
        const res = dividend.div_rem(divisor);
        acc +%= @truncate(res.quotient.to_native() ^ res.remainder.to_native());
    }
    return acc;
}

fn benchSecp256k1Recover(_: std.mem.Allocator) !u64 {
    var hash = [_]u8{0} ** 32;
    hash[31] = 1;
    const r: u256 = 0x79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798;
    const s: u256 = 0x79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81799;
    const addr = try crypto.secp256k1.unauditedRecoverAddress(&hash, 0, r, s);
    return std.mem.readInt(u64, addr.bytes[12..20], .big);
}

pub fn main() void {
    micro.runSuite("crypto", &.{
        .{ .name = "crypto/keccak256-32B", .operations = N, .bytes = N * 32, .run = benchKeccak32B },
        .{ .name = "crypto/keccak256-1KB", .operations = 64, .bytes = 64 * 1024, .run = benchKeccak1KB },
        .{ .name = "crypto/sha256-1KB", .operations = 64, .bytes = 64 * 1024, .run = benchSha2561KB },
        .{ .name = "crypto/modexp-256bit", .operations = 1, .run = benchModexp256 },
        .{ .name = "crypto/modexp-small-1024", .operations = 1024, .run = benchModexpSmall },
        .{ .name = "crypto/uint256-divrem-512", .operations = N, .run = benchUint256DivRem },
        .{ .name = "crypto/secp256k1-ecrecover", .operations = 1, .run = benchSecp256k1Recover },
    });
}
