//! Tests for the layout of the dispatch schedule: which items the builder emits for
//! an instruction, and that handlers and builder agree on it.
//!
//! Schedule items carry a tag only in Debug, ReleaseSafe and traced builds. Untraced
//! release builds read the layout blind, so these tests pin it down where the tag is
//! available to check.
const std = @import("std");
const testing = std.testing;
const bytecode_mod = @import("../bytecode/bytecode.zig");
const dispatch_opcode_data = @import("dispatch_opcode_data.zig");
const frame_handlers = @import("../frame/frame_handlers.zig");
const OpcodeSynthetic = @import("../opcodes/opcode_synthetic.zig").OpcodeSynthetic;

const TestEvm = @import("../evm.zig").Evm(.{});
const TestFrame = TestEvm.Frame;
const Dispatch = TestFrame.Dispatch;
const TestBytecode = bytecode_mod.Bytecode(.{
    .max_bytecode_size = TestFrame.config.max_bytecode_size,
    .max_initcode_size = TestFrame.config.max_initcode_size,
    .fusions_enabled = true,
    .hardfork = TestFrame.config.hardfork,
});

test "PUSH9-PUSH32 store their value as inline 64-bit limbs" {
    if (!Dispatch.item_tagged) return error.SkipZigTest;
    const allocator = testing.allocator;

    // PUSH9, PUSH16, PUSH20, PUSH24, PUSH25, PUSH32, each with distinct bytes, then STOP.
    const sizes = [_]u8{ 9, 16, 20, 24, 25, 32 };
    var code = std.ArrayList(u8).empty;
    defer code.deinit(allocator);
    var expected: [sizes.len]u256 = undefined;
    for (sizes, 0..) |size, index| {
        try code.append(allocator, 0x5f + size);
        var value: u256 = 0;
        for (0..size) |byte_index| {
            const byte: u8 = @intCast(0x11 * (index + 1) + byte_index);
            try code.append(allocator, byte);
            value = (value << 8) | byte;
        }
        expected[index] = value;
    }
    try code.append(allocator, 0x00);

    var bytecode = try TestBytecode.init(allocator, code.items);
    defer bytecode.deinit();
    var schedule = try Dispatch.DispatchSchedule.init(allocator, &bytecode, &TestFrame.opcode_handlers, null);
    defer schedule.deinit();

    try testing.expect(schedule.validate());
    try testing.expect(schedule.has_first_block);
    try testing.expect(schedule.items[0] == .first_block_gas);

    var index: usize = 1;
    for (sizes, expected) |size, value| {
        try testing.expect(schedule.items[index] == .opcode_handler);
        try testing.expect(schedule.items[index].opcode_handler == TestFrame.opcode_handlers[0x5f + @as(usize, size)]);
        index += 1;

        const limbs = Dispatch.pushLimbCount(size);
        var rebuilt: u256 = 0;
        for (0..limbs) |limb| {
            try testing.expect(schedule.items[index] == .push_inline);
            rebuilt |= @as(u256, schedule.items[index].push_inline.value) << @intCast(64 * limb);
            index += 1;
        }
        try testing.expectEqual(value, rebuilt);
    }

    // No PUSH value went through the arena.
    try testing.expectEqual(@as(usize, 0), schedule.push_values_arena.queryCapacity());
}

test "push limb counts match the item counts handlers advance by" {
    try testing.expectEqual(@as(u8, 1), Dispatch.pushLimbCount(1));
    try testing.expectEqual(@as(u8, 1), Dispatch.pushLimbCount(8));
    try testing.expectEqual(@as(u8, 2), Dispatch.pushLimbCount(9));
    try testing.expectEqual(@as(u8, 2), Dispatch.pushLimbCount(16));
    try testing.expectEqual(@as(u8, 3), Dispatch.pushLimbCount(17));
    try testing.expectEqual(@as(u8, 3), Dispatch.pushLimbCount(24));
    try testing.expectEqual(@as(u8, 4), Dispatch.pushLimbCount(25));
    try testing.expectEqual(@as(u8, 4), Dispatch.pushLimbCount(32));

    // A handler steps over itself plus its limbs.
    try testing.expectEqual(@as(usize, 2), comptime dispatch_opcode_data.itemCount(.PUSH8));
    try testing.expectEqual(@as(usize, 3), comptime dispatch_opcode_data.itemCount(.PUSH9));
    try testing.expectEqual(@as(usize, 3), comptime dispatch_opcode_data.itemCount(.PUSH16));
    try testing.expectEqual(@as(usize, 4), comptime dispatch_opcode_data.itemCount(.PUSH20));
    try testing.expectEqual(@as(usize, 5), comptime dispatch_opcode_data.itemCount(.PUSH32));
}

test "PUSH+ADD+DUP1 selects the inline or the pointer handler by operand width" {
    if (!Dispatch.item_tagged) return error.SkipZigTest;
    const allocator = testing.allocator;

    // PUSH1 7, PUSH1 1, ADD, DUP1 | PUSH9 <9 bytes>, ADD, DUP1 | STOP
    const code = [_]u8{ 0x60, 0x07, 0x60, 0x01, 0x01, 0x80 } ++
        [_]u8{0x68} ++ [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09 } ++ [_]u8{ 0x01, 0x80 } ++
        [_]u8{0x00};

    var bytecode = try TestBytecode.init(allocator, &code);
    defer bytecode.deinit();
    var schedule = try Dispatch.DispatchSchedule.init(allocator, &bytecode, &TestFrame.opcode_handlers, null);
    defer schedule.deinit();
    try testing.expect(schedule.validate());

    const inline_handler = frame_handlers.getSyntheticHandler(TestFrame, @intFromEnum(OpcodeSynthetic.PUSH_ADD_DUP1_INLINE));
    const pointer_handler = frame_handlers.getSyntheticHandler(TestFrame, @intFromEnum(OpcodeSynthetic.PUSH_ADD_DUP1_POINTER));

    // [0] first block, [1..2] PUSH1 7, [3..4] PUSH_ADD_DUP1_INLINE 1, [5..6] PUSH_ADD_DUP1_POINTER.
    try testing.expect(schedule.items[1].opcode_handler == TestFrame.opcode_handlers[0x60]);
    try testing.expectEqual(@as(u64, 7), schedule.items[2].push_inline.value);
    try testing.expect(schedule.items[3].opcode_handler == inline_handler);
    try testing.expect(schedule.items[4] == .push_inline);
    try testing.expectEqual(@as(u64, 1), schedule.items[4].push_inline.value);
    try testing.expect(schedule.items[5].opcode_handler == pointer_handler);
    try testing.expect(schedule.items[6] == .push_pointer);
    try testing.expectEqual(@as(u256, 0x010203040506070809), schedule.items[6].push_pointer.value_ptr.*);
}

test "consecutive PUSH and POP instructions are not fused" {
    if (!Dispatch.item_tagged) return error.SkipZigTest;
    const allocator = testing.allocator;

    // PUSH1 1, PUSH1 2, PUSH1 3, POP, POP, POP, STOP
    const code = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 0x50, 0x50, 0x50, 0x00 };
    var bytecode = try TestBytecode.init(allocator, &code);
    defer bytecode.deinit();
    var schedule = try Dispatch.DispatchSchedule.init(allocator, &bytecode, &TestFrame.opcode_handlers, null);
    defer schedule.deinit();
    try testing.expect(schedule.validate());

    const push1 = TestFrame.opcode_handlers[0x60];
    const pop = TestFrame.opcode_handlers[0x50];
    const stop = TestFrame.opcode_handlers[0x00];
    const expected_handlers = [_]struct { index: usize, handler: TestFrame.OpcodeHandler }{
        .{ .index = 1, .handler = push1 },
        .{ .index = 3, .handler = push1 },
        .{ .index = 5, .handler = push1 },
        .{ .index = 7, .handler = pop },
        .{ .index = 8, .handler = pop },
        .{ .index = 9, .handler = pop },
        .{ .index = 10, .handler = stop },
    };
    for (expected_handlers) |entry| {
        try testing.expect(schedule.items[entry.index] == .opcode_handler);
        try testing.expect(schedule.items[entry.index].opcode_handler == entry.handler);
    }
}

test "a schedule without first-block metadata starts with a handler" {
    if (!Dispatch.item_tagged) return error.SkipZigTest;
    const allocator = testing.allocator;

    // Empty code: the first block charges nothing and needs no stack.
    var bytecode = try TestBytecode.init(allocator, &.{});
    defer bytecode.deinit();
    var schedule = try Dispatch.DispatchSchedule.init(allocator, &bytecode, &TestFrame.opcode_handlers, null);
    defer schedule.deinit();

    try testing.expect(!schedule.has_first_block);
    try testing.expect(schedule.items[0] == .opcode_handler);
    try testing.expect(schedule.endsWithStops());
    try testing.expect(schedule.validate());
}

test "bytecode analysis works with a u32 program counter" {
    const BigBytecode = bytecode_mod.Bytecode(.{ .max_bytecode_size = 100_000, .max_initcode_size = 200_000 });
    try testing.expectEqual(u32, BigBytecode.PcType);

    const allocator = testing.allocator;
    const code = try allocator.alloc(u8, 70_000);
    defer allocator.free(code);
    @memset(code, 0x5b); // JUMPDEST
    // PUSH3 0x011000, JUMP: a target beyond what u16 can hold.
    @memcpy(code[0..5], &[_]u8{ 0x62, 0x01, 0x10, 0x00, 0x56 });
    // Past offset 65535: ISZERO, PUSH3 0x011001, JUMPI, PUSH1 1, ADD, DUP1, PC, STOP.
    const tail = [_]u8{ 0x15, 0x62, 0x01, 0x10, 0x01, 0x57, 0x60, 0x01, 0x01, 0x80, 0x58, 0x00 };
    @memcpy(code[69_000..][0..tail.len], &tail);

    var bytecode = try BigBytecode.init(allocator, code);
    defer bytecode.deinit();
    try testing.expectEqual(@as(u32, 70_000), bytecode.len());

    var iter = bytecode.createIterator();
    var saw_pc: ?u32 = null;
    var saw_push_jump = false;
    var saw_iszero_jumpi = false;
    var saw_push_add_dup1 = false;
    while (iter.next()) |op| {
        switch (op) {
            .pc => |data| saw_pc = data.value,
            .push_jump_fusion => |data| {
                saw_push_jump = true;
                try testing.expectEqual(@as(u256, 0x011000), data.value);
            },
            .iszero_jumpi => |data| {
                saw_iszero_jumpi = true;
                try testing.expectEqual(@as(u256, 0x011001), data.target);
            },
            .push_add_dup1 => saw_push_add_dup1 = true,
            else => {},
        }
    }
    try testing.expect(saw_push_jump);
    try testing.expect(saw_iszero_jumpi);
    try testing.expect(saw_push_add_dup1);
    try testing.expectEqual(@as(?u32, 69_010), saw_pc);
}
