const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const Frame = evm.DefaultEvm.Frame;
const Dispatch = Frame.Dispatch;
const Bytecode = evm.Bytecode(.{});
const OpcodeSynthetic = evm.OpcodeSynthetic.OpcodeSynthetic;

test "static jump optimization - valid jump to JUMPDEST" {
    const allocator = testing.allocator;
    const code = [_]u8{ 0x60, 5, 0x56, 0xfe, 0xfe, 0x5b, 0x00 };
    var bytecode = try Bytecode.init(allocator, &code);
    defer bytecode.deinit();

    var built = try Dispatch.DispatchSchedule.initWithJumpTable(allocator, bytecode, &Frame.opcode_handlers, @as(?*evm.Tracer, null));
    defer built.schedule.deinit();
    defer built.jump_table.deinit(allocator);

    const schedule = &built.schedule;
    const index: usize = @intFromBool(schedule.has_first_block_gas);
    try testing.expect(schedule.validate());
    if (schedule.item_kinds.len != 0) {
        try testing.expectEqualSlices(Dispatch.ItemKind, &.{ .opcode_handler, .jump_static }, schedule.item_kinds[index..][0..2]);
    }
    try testing.expectEqual(evm.frame_handlers.getSyntheticHandler(Frame, @intFromEnum(OpcodeSynthetic.JUMP_TO_STATIC_LOCATION)), schedule.items[index].opcode_handler);
    const target = built.jump_table.find_jump_target(5) orelse return error.MissingJumpTarget;
    try testing.expectEqual(@as(*const anyopaque, @ptrCast(target)), schedule.items[index + 1].jump_static.dispatch);
}

test "static jump optimization - invalid jump resolves to invalid-target handler" {
    const allocator = testing.allocator;
    const code = [_]u8{ 0x60, 3, 0x56, 0xfe, 0x00 };
    var bytecode = try Bytecode.init(allocator, &code);
    defer bytecode.deinit();

    var schedule = try Dispatch.DispatchSchedule.init(allocator, bytecode, &Frame.opcode_handlers, @as(?*evm.Tracer, null));
    defer schedule.deinit();

    const index: usize = @intFromBool(schedule.has_first_block_gas);
    try testing.expect(schedule.validate());
    if (schedule.item_kinds.len != 0) {
        try testing.expectEqualSlices(Dispatch.ItemKind, &.{ .opcode_handler, .jump_static }, schedule.item_kinds[index..][0..2]);
    }
    try testing.expectEqual(evm.frame_handlers.getSyntheticHandler(Frame, @intFromEnum(OpcodeSynthetic.JUMP_TO_STATIC_LOCATION)), schedule.items[index].opcode_handler);
    const target: [*]const Dispatch.Item = @ptrCast(@alignCast(schedule.items[index + 1].jump_static.dispatch));
    try testing.expectEqual(evm.frame_handlers.getSyntheticHandler(Frame, @intFromEnum(OpcodeSynthetic.INVALID_JUMP_TARGET)), target[0].opcode_handler);
}

test "static jumpi optimization - conditional jump to valid JUMPDEST" {
    const allocator = testing.allocator;
    const code = [_]u8{ 0x60, 1, 0x60, 6, 0x57, 0xfe, 0x5b, 0x00 };
    var bytecode = try Bytecode.init(allocator, &code);
    defer bytecode.deinit();

    var built = try Dispatch.DispatchSchedule.initWithJumpTable(allocator, bytecode, &Frame.opcode_handlers, @as(?*evm.Tracer, null));
    defer built.schedule.deinit();
    defer built.jump_table.deinit(allocator);

    const schedule = &built.schedule;
    const index = @as(usize, @intFromBool(schedule.has_first_block_gas)) + 2;
    try testing.expect(schedule.validate());
    if (schedule.item_kinds.len != 0) {
        try testing.expectEqualSlices(Dispatch.ItemKind, &.{ .opcode_handler, .jump_static }, schedule.item_kinds[index..][0..2]);
    }
    try testing.expectEqual(evm.frame_handlers.getSyntheticHandler(Frame, @intFromEnum(OpcodeSynthetic.JUMPI_TO_STATIC_LOCATION)), schedule.items[index].opcode_handler);
    const target = built.jump_table.find_jump_target(6) orelse return error.MissingJumpTarget;
    try testing.expectEqual(@as(*const anyopaque, @ptrCast(target)), schedule.items[index + 1].jump_static.dispatch);
}
