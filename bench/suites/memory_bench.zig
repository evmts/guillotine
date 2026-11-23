const std = @import("std");
const micro = @import("micro");
const memory_mod = @import("memory");

const OwnedMemory = memory_mod.Memory(.{
    .initial_capacity = 4096,
    .memory_limit = 16 * 1024 * 1024,
    .owned = true,
});

const WORDS: usize = 256;

fn benchWordReadWriteHot(allocator: std.mem.Allocator) !u64 {
    var mem = try OwnedMemory.init(allocator);
    defer mem.deinit(allocator);
    try mem.ensure_capacity(allocator, WORDS * 32);
    var acc: u64 = 0;
    for (0..WORDS) |i| {
        const off: u32 = @intCast(i * 32);
        const val: u256 = (@as(u256, i) << 128) | @as(u256, i *% 0x9e3779b97f4a7c15);
        try mem.set_u256_evm(allocator, off, val);
        const got = try mem.get_u256_evm(allocator, off);
        acc +%= @truncate(got);
    }
    return acc;
}

fn benchSequentialExpansion(allocator: std.mem.Allocator) !u64 {
    var mem = try OwnedMemory.init(allocator);
    defer mem.deinit(allocator);
    var acc: u64 = 0;
    for (0..WORDS) |i| {
        const off: u32 = @intCast(i * 32);
        try mem.set_u256_evm(allocator, off, @as(u256, i + 1));
        acc +%= mem.size();
    }
    return acc;
}

fn benchExpansionCost(allocator: std.mem.Allocator) !u64 {
    var mem = try OwnedMemory.init(allocator);
    defer mem.deinit(allocator);
    var total_cost: u64 = 0;
    for (1..WORDS + 1) |i| {
        const size: u32 = @intCast(i * 32);
        total_cost +%= mem.get_expansion_cost(size);
        try mem.ensure_capacity(allocator, size);
    }
    return total_cost;
}

fn benchSetDataSmall32B(allocator: std.mem.Allocator) !u64 {
    var mem = try OwnedMemory.init(allocator);
    defer mem.deinit(allocator);
    try mem.ensure_capacity(allocator, WORDS * 32);
    var buf = [_]u8{0xab} ** 32;
    for (0..WORDS) |i| {
        buf[0] = @truncate(i);
        try mem.set_data_evm(allocator, @intCast(i * 32), &buf);
    }
    const slice = try mem.get_slice(0, WORDS * 32);
    return @as(u64, slice[0]) + @as(u64, slice[slice.len - 1]) + slice.len;
}

fn benchSetDataLarge16KB(allocator: std.mem.Allocator) !u64 {
    var mem = try OwnedMemory.init(allocator);
    defer mem.deinit(allocator);
    const data = try allocator.alloc(u8, 16384);
    defer allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i *% 131);
    for (0..16) |i| {
        try mem.set_data_evm(allocator, @intCast(i * 1024), data);
    }
    const slice = try mem.get_slice(0, 16384);
    return @as(u64, slice[0]) + @as(u64, slice[16383]) + mem.size();
}

fn benchNestedChildFrames(allocator: std.mem.Allocator) !u64 {
    var parent = try OwnedMemory.init(allocator);
    defer parent.deinit(allocator);
    try parent.set_u256_evm(allocator, 0, 0xdeadbeef);
    var acc: u64 = 0;
    for (0..64) |i| {
        var child = try parent.init_child();
        defer child.deinit(allocator);
        try child.set_u256_evm(allocator, 0, @as(u256, i + 1));
        acc +%= @truncate(try child.get_u256_evm(allocator, 0));
    }
    return acc;
}

pub fn main() void {
    micro.runSuite("memory", &.{
        .{ .name = "memory/word-rw-hot", .operations = WORDS * 2, .bytes = WORDS * 64, .run = benchWordReadWriteHot },
        .{ .name = "memory/sequential-expand-8KB", .operations = WORDS, .bytes = WORDS * 32, .run = benchSequentialExpansion },
        .{ .name = "memory/expansion-cost", .operations = WORDS, .run = benchExpansionCost },
        .{ .name = "memory/set-data-32B", .operations = WORDS, .bytes = WORDS * 32, .run = benchSetDataSmall32B },
        .{ .name = "memory/set-data-16KB", .operations = 16, .bytes = 16 * 16384, .run = benchSetDataLarge16KB },
        .{ .name = "memory/nested-child-frames", .operations = 64, .run = benchNestedChildFrames },
    });
}
