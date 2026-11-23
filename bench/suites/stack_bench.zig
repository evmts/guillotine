const std = @import("std");
const micro = @import("micro");
const Stack = @import("stack").Stack;

const DefaultStack = Stack(.{
    .stack_size = 1024,
    .WordType = u256,
});

const BATCH: usize = 512;

fn benchPushPopSafe(allocator: std.mem.Allocator) !u64 {
    var stack = try DefaultStack.init(allocator, null);
    defer stack.deinit(allocator);
    var acc: u64 = 0;
    for (0..BATCH) |i| {
        try stack.push(@as(u256, i) *% 0x9e3779b97f4a7c15 +% 1);
    }
    for (0..BATCH) |_| {
        const v = try stack.pop();
        acc +%= @truncate(v);
    }
    return acc;
}

fn benchPushPopUnsafe(allocator: std.mem.Allocator) !u64 {
    var stack = try DefaultStack.init(allocator, null);
    defer stack.deinit(allocator);
    var acc: u64 = 0;
    for (0..BATCH) |i| {
        stack.push_unsafe(@as(u256, i) *% 0x9e3779b97f4a7c15 +% 1);
    }
    for (0..BATCH) |_| {
        const v = stack.pop_unsafe();
        acc +%= @truncate(v);
    }
    return acc;
}

fn benchDupUnsafe(allocator: std.mem.Allocator) !u64 {
    var stack = try DefaultStack.init(allocator, null);
    defer stack.deinit(allocator);
    for (0..16) |i| stack.push_unsafe(@as(u256, i + 1) *% 17);
    var acc: u64 = 0;
    for (0..BATCH) |i| {
        switch (i & 3) {
            0 => stack.dup_n_unsafe(1),
            1 => stack.dup_n_unsafe(4),
            2 => stack.dup_n_unsafe(8),
            else => stack.dup_n_unsafe(16),
        }
        acc +%= @truncate(stack.pop_unsafe());
    }
    return acc;
}

fn benchSwapUnsafe(allocator: std.mem.Allocator) !u64 {
    var stack = try DefaultStack.init(allocator, null);
    defer stack.deinit(allocator);
    for (0..17) |i| stack.push_unsafe(@as(u256, i + 1) *% 31);
    for (0..BATCH) |i| {
        switch (i & 3) {
            0 => stack.swap_n_unsafe(1),
            1 => stack.swap_n_unsafe(4),
            2 => stack.swap_n_unsafe(8),
            else => stack.swap_n_unsafe(16),
        }
    }
    var acc: u64 = 0;
    while (stack.size() > 0) acc +%= @truncate(stack.pop_unsafe());
    return acc;
}

fn benchPeekSetTopUnsafe(allocator: std.mem.Allocator) !u64 {
    var stack = try DefaultStack.init(allocator, null);
    defer stack.deinit(allocator);
    stack.push_unsafe(1);
    stack.push_unsafe(2);
    for (0..BATCH) |i| {
        const top = stack.peek_unsafe();
        stack.set_top_unsafe(top +% @as(u256, i));
    }
    return @truncate(stack.pop_unsafe() +% stack.pop_unsafe());
}

fn benchBinaryOpPattern(allocator: std.mem.Allocator) !u64 {
    var stack = try DefaultStack.init(allocator, null);
    defer stack.deinit(allocator);
    stack.push_unsafe(1);
    for (0..BATCH) |i| {
        stack.push_unsafe(@as(u256, i + 3));
        const b = stack.pop_unsafe();
        const a = stack.peek_unsafe();
        stack.set_top_unsafe(a +% b);
    }
    return @truncate(stack.pop_unsafe());
}

pub fn main() void {
    micro.runSuite("stack", &.{
        .{ .name = "stack/push-pop-safe", .operations = BATCH * 2, .run = benchPushPopSafe },
        .{ .name = "stack/push-pop-unsafe", .operations = BATCH * 2, .run = benchPushPopUnsafe },
        .{ .name = "stack/dup-unsafe", .operations = BATCH, .run = benchDupUnsafe },
        .{ .name = "stack/swap-unsafe", .operations = BATCH, .run = benchSwapUnsafe },
        .{ .name = "stack/peek-set-top-unsafe", .operations = BATCH, .run = benchPeekSetTopUnsafe },
        .{ .name = "stack/binary-op-pattern", .operations = BATCH, .run = benchBinaryOpPattern },
    });
}
