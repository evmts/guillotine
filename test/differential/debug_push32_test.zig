const std = @import("std");
const evm = @import("evm");
const log = std.log.scoped(.push32_test);

test "PUSH32 dispatch investigation" {
    const allocator = std.testing.allocator;

    // Just PUSH32, PUSH1, SDIV bytecode
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xf8, // -8
        0x60, 0x03, // PUSH1 3
        0x05, // SDIV
        0x00, // STOP
    };

    const Bytecode = evm.Bytecode(.{});
    var bc = try Bytecode.init(allocator, &bytecode);
    defer bc.deinit();

    log.warn("\n=== Analyzing PUSH32 bytecode ===", .{});
    log.warn("Bytecode length: {}", .{bc.runtime_code.len});

    // Iterate through parsed bytecode
    var iter = bc.createIterator();
    var op_index: usize = 0;
    log.warn("\nParsed opcodes:", .{});
    while (iter.next()) |op_data| {
        switch (op_data) {
            .push => |data| {
                log.warn("  [{}] PC={}: PUSH{} value=0x{x}", .{ op_index, iter.pc - data.size - 1, data.size, data.value });
            },
            .regular => |data| {
                log.warn("  [{}] PC={}: opcode=0x{x:0>2}", .{ op_index, iter.pc - 1, data.opcode });
            },
            .stop => {
                log.warn("  [{}] PC={}: STOP", .{ op_index, iter.pc - 1 });
            },
            else => {
                log.warn("  [{}] PC={}: {s}", .{ op_index, iter.pc - 1, @tagName(op_data) });
            },
        }
        op_index += 1;
    }

    // Build dispatch schedule
    const Frame = evm.DefaultEvm.Frame;
    var schedule = try Frame.Dispatch.DispatchSchedule.init(allocator, bc, &Frame.opcode_handlers, @as(?*evm.Tracer, null));
    defer schedule.deinit();

    try std.testing.expect(schedule.validate());
    const opcode_index: usize = @intFromBool(schedule.has_first_block_gas);
    if (schedule.item_kinds.len != 0) {
        try std.testing.expectEqual(Frame.Dispatch.ItemKind.push_pointer, schedule.item_kinds[opcode_index + 1]);
    }
    try std.testing.expectEqual(@as(u256, @bitCast(@as(i256, -8))), schedule.items[opcode_index + 1].push_pointer.value_ptr.*);
}
