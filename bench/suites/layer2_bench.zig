const std = @import("std");
const micro = @import("micro");
const layer2 = @import("layer2").layer2;
const fast_lz = layer2.optimism.fast_lz;
const da_footprint = layer2.optimism.da_footprint;

fn makeCalldata(allocator: std.mem.Allocator, len: usize) ![]u8 {
    const buf = try allocator.alloc(u8, len);
    // Realistic EVM ABI calldata: 4-byte selector, zero-padded 32-byte words, addresses, amounts
    for (buf, 0..) |*b, i| {
        const rem = i & 31;
        if (rem < 12) {
            b.* = 0;
        } else if (rem < 20) {
            b.* = @truncate((i >> 5) +% rem);
        } else {
            b.* = @truncate((i *% 37) ^ 0x5a);
        }
    }
    return buf;
}

fn benchFastLz68B(allocator: std.mem.Allocator) !u64 {
    const data = try makeCalldata(allocator, 68);
    defer allocator.free(data);
    var acc: u64 = 0;
    for (0..64) |_| acc +%= fast_lz.flzCompressLen(data);
    return acc;
}

fn benchFastLz512B(allocator: std.mem.Allocator) !u64 {
    const data = try makeCalldata(allocator, 512);
    defer allocator.free(data);
    var acc: u64 = 0;
    for (0..32) |_| acc +%= fast_lz.flzCompressLen(data);
    return acc;
}

fn benchFastLz4KB(allocator: std.mem.Allocator) !u64 {
    const data = try makeCalldata(allocator, 4096);
    defer allocator.free(data);
    var acc: u64 = 0;
    for (0..8) |_| acc +%= fast_lz.flzCompressLen(data);
    return acc;
}

fn benchFastLz32KB(allocator: std.mem.Allocator) !u64 {
    const data = try makeCalldata(allocator, 32768);
    defer allocator.free(data);
    return fast_lz.flzCompressLen(data);
}

fn benchDaFootprint4KB(allocator: std.mem.Allocator) !u64 {
    const data = try makeCalldata(allocator, 4096);
    defer allocator.free(data);
    var acc: u64 = 0;
    for (0..8) |_| {
        acc +%= da_footprint.txDaFootprint(data, 400);
    }
    return acc;
}

pub fn main() void {
    micro.runSuite("layer2", &.{
        .{ .name = "layer2/fast-lz-68B", .operations = 64, .bytes = 64 * 68, .run = benchFastLz68B },
        .{ .name = "layer2/fast-lz-512B", .operations = 32, .bytes = 32 * 512, .run = benchFastLz512B },
        .{ .name = "layer2/fast-lz-4KB", .operations = 8, .bytes = 8 * 4096, .run = benchFastLz4KB },
        .{ .name = "layer2/fast-lz-32KB", .operations = 1, .bytes = 32768, .run = benchFastLz32KB },
        .{ .name = "layer2/da-footprint-4KB", .operations = 8, .bytes = 8 * 4096, .run = benchDaFootprint4KB },
    });
}
