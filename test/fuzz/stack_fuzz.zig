//! Stateful Stack Model-Checking Fuzz Tests
//!
//! Drives arbitrary sequences of EVM stack operations (push, pop, peek, set_top,
//! dup_n 1..16, swap_n 1..16, reset) against an independent flat ArrayList reference model.
//! Verifies exact LIFO ordering, StackOverflow at capacity (1024), StackUnderflow on
//! empty/insufficient stack, and exact element-by-element equality after every step.

const std = @import("std");
const evm = @import("evm");
const fuzz_alloc = @import("fuzz_alloc.zig");

const DefaultStack = evm.Stack(.{});
const SmallStack = evm.Stack(.{ .stack_size = 32 });

fn makeWord(seed_byte: u8, step: usize) u256 {
    const b: u256 = seed_byte;
    const s: u256 = step;
    return switch (seed_byte & 0x07) {
        0 => 0,
        1 => 1,
        2 => std.math.maxInt(u256),
        3 => (@as(u256, 1) << 255),
        4 => (@as(u256, 1) << 255) - 1,
        5 => (@as(u256, 1) << 128) | b,
        6 => (b << 248) | s,
        else => (b *% 0x9e3779b97f4a7c15) ^ (s << 64) ^ b,
    };
}

fn checkStackMatchesModel(comptime StackT: type, stack: *StackT, model: []const u256) !void {
    try std.testing.expectEqual(model.len, stack.size());
    const actual_slice = stack.get_slice();
    try std.testing.expectEqual(model.len, actual_slice.len);
    // stack.get_slice()[0] is top of stack; model[model.len - 1] is top of stack
    for (0..model.len) |idx| {
        const expected = model[model.len - 1 - idx];
        try std.testing.expectEqual(expected, actual_slice[idx]);
    }
}

fn runStackModel(comptime StackT: type, input: []const u8) !void {
    const allocator = fuzz_alloc.get();
    var stack = try StackT.init(allocator, null);
    defer stack.deinit(allocator);

    var model = std.ArrayList(u256).empty;
    defer model.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const op = input[i];
        const arg = if (i + 1 < input.len) input[i + 1] else op;

        switch (op % 9) {
            0, 1 => { // push (weighted 2x to grow stack deeply & test overflow)
                const val = makeWord(arg, i);
                if (model.items.len >= StackT.stack_capacity) {
                    try std.testing.expectError(StackT.Error.StackOverflow, stack.push(val));
                } else {
                    try stack.push(val);
                    try model.append(allocator, val);
                }
            },
            2 => { // pop
                if (model.items.len == 0) {
                    try std.testing.expectError(StackT.Error.StackUnderflow, stack.pop());
                } else {
                    const actual = try stack.pop();
                    const expected = model.pop().?;
                    try std.testing.expectEqual(expected, actual);
                }
            },
            3 => { // peek
                if (model.items.len == 0) {
                    try std.testing.expectError(StackT.Error.StackUnderflow, stack.peek());
                } else {
                    const actual = try stack.peek();
                    const expected = model.items[model.items.len - 1];
                    try std.testing.expectEqual(expected, actual);
                }
            },
            4 => { // set_top
                const val = makeWord(arg, i);
                if (model.items.len == 0) {
                    try std.testing.expectError(StackT.Error.StackUnderflow, stack.set_top(val));
                } else {
                    try stack.set_top(val);
                    model.items[model.items.len - 1] = val;
                }
            },
            5 => { // dup_n (1..16)
                const n: u8 = (arg % 16) + 1;
                if (model.items.len < n) {
                    try std.testing.expectError(StackT.Error.StackUnderflow, stack.dup_n(n));
                } else if (model.items.len >= StackT.stack_capacity) {
                    try std.testing.expectError(StackT.Error.StackOverflow, stack.dup_n(n));
                } else {
                    try stack.dup_n(n);
                    const val = model.items[model.items.len - n];
                    try model.append(allocator, val);
                }
            },
            6 => { // swap_n (1..16)
                const n: u8 = (arg % 16) + 1;
                if (model.items.len < @as(usize, n) + 1) {
                    try std.testing.expectError(StackT.Error.StackUnderflow, stack.swap_n(n));
                } else {
                    try stack.swap_n(n);
                    const top_idx = model.items.len - 1;
                    const nth_idx = model.items.len - 1 - n;
                    std.mem.swap(u256, &model.items[top_idx], &model.items[nth_idx]);
                }
            },
            7 => { // batch push burst (stress near capacity)
                const count: usize = (arg % 8) + 1;
                for (0..count) |k| {
                    const val = makeWord(arg +% @as(u8, @truncate(k)), i + k);
                    if (model.items.len >= StackT.stack_capacity) {
                        try std.testing.expectError(StackT.Error.StackOverflow, stack.push(val));
                        break;
                    }
                    try stack.push(val);
                    try model.append(allocator, val);
                }
            },
            else => { // binary_op_unsafe / dup_n_unsafe / swap_n_unsafe when preconditions hold
                if (arg < 64 and model.items.len >= 2) {
                    const n: u8 = @intCast((arg % @min(model.items.len - 1, 16)) + 1);
                    stack.swap_n_unsafe(n);
                    const top_idx = model.items.len - 1;
                    const nth_idx = model.items.len - 1 - n;
                    std.mem.swap(u256, &model.items[top_idx], &model.items[nth_idx]);
                } else if (arg < 128 and model.items.len >= 1 and model.items.len < StackT.stack_capacity) {
                    const n: u8 = @intCast((arg % @min(model.items.len, 16)) + 1);
                    stack.dup_n_unsafe(n);
                    const val = model.items[model.items.len - n];
                    try model.append(allocator, val);
                } else if (model.items.len >= 2) {
                    // Exercise binary_op_unsafe (wrapping add) when safe
                    const add_fn = struct {
                        fn wrapAdd(a: u256, b: u256) u256 {
                            return a +% b;
                        }
                    }.wrapAdd;
                    stack.binary_op_unsafe(add_fn);
                    const top = model.pop().?;
                    const second = model.pop().?;
                    try model.append(allocator, top +% second);
                }
            },
        }

        try checkStackMatchesModel(StackT, &stack, model.items);
    }
}

pub fn fuzzDefaultStack(_: void, input: []const u8) !void {
    try runStackModel(DefaultStack, input);
}

pub fn fuzzSmallStackOverflow(_: void, input: []const u8) !void {
    // Small 32-slot stack rapidly exercises exact capacity overflow boundaries with DUP & PUSH
    try runStackModel(SmallStack, input);
}

pub fn fuzzBorrowedStack(_: void, input: []const u8) !void {
    // Exercise pre-validated *_unsafe fast paths & LIFO slice invariants against a reference model
    const allocator = fuzz_alloc.get();
    var stack = try SmallStack.init(allocator, null);
    defer stack.deinit(allocator);

    var model = std.ArrayList(u256).empty;
    defer model.deinit(allocator);

    for (input, 0..) |b, i| {
        if ((b & 3) == 0) {
            const val = makeWord(b, i);
            if (model.items.len >= SmallStack.stack_capacity) {
                try std.testing.expectError(SmallStack.Error.StackOverflow, stack.push(val));
            } else {
                stack.push_unsafe(val);
                try model.append(allocator, val);
            }
        } else if ((b & 3) == 1) {
            if (model.items.len == 0) {
                try std.testing.expectError(SmallStack.Error.StackUnderflow, stack.pop());
            } else {
                try std.testing.expectEqual(model.pop().?, stack.pop_unsafe());
            }
        } else if ((b & 3) == 2 and model.items.len > 0) {
            const new_val = makeWord(b ^ 0x5a, i);
            stack.set_top_unsafe(new_val);
            model.items[model.items.len - 1] = new_val;
            try std.testing.expectEqual(new_val, stack.peek_unsafe());
        } else if (model.items.len >= 2) {
            const sub_fn = struct {
                fn wrapSub(a: u256, c: u256) u256 {
                    return a -% c;
                }
            }.wrapSub;
            stack.binary_op_unsafe(sub_fn);
            const top = model.pop().?;
            const second = model.pop().?;
            try model.append(allocator, top -% second);
        }
        try checkStackMatchesModel(SmallStack, &stack, model.items);
    }
}

const seed_corpus: []const []const u8 = &.{
    &.{},
    &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 },
    &.{ 0, 0, 0, 0, 5, 0, 5, 1, 6, 1, 2, 2, 2, 2, 2 },
    &.{ 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 5, 15, 6, 15 },
    &.{ 1, 0xff, 1, 0x02, 8, 0x20, 3, 0, 2, 0 },
};

test "fuzz default 1024-slot stack model checker" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzDefaultStack), .{ .corpus = seed_corpus });
}

test "fuzz 32-slot stack overflow and boundary model checker" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzSmallStackOverflow), .{ .corpus = seed_corpus });
}

test "fuzz borrowed stack buffer alignment and reset" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzBorrowedStack), .{ .corpus = seed_corpus });
}
