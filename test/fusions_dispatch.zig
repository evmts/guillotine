const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const log = evm.log;
const frame_mod = evm.frame;
const Tracer = @import("evm").Tracer;

// The frame type the default EVM executes, with its bytecode analyzer.
const TestFrame = evm.DefaultEvm.Frame;
const TestBytecode = evm.Bytecode(.{ .max_bytecode_size = TestFrame.config.max_bytecode_size });
const TestDispatch = evm.FrameDispatch(TestFrame);

test "fusion dispatch: verify jump resolution for ten-thousand-hashes" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;

    // Deployment bytecode for ten-thousand-hashes from benches
    const deployment_hex = "6080604052348015600e575f5ffd5b50609780601a5f395ff3fe6080604052348015600e575f5ffd5b50600436106026575f3560e01c806330627b7c14602a575b5f5ffd5b60306032565b005b5f5b614e20811015605e5760408051602081018390520160408051601f19818403019052526001016034565b5056fea26469706673582212202c247f39d615d7f66942cd6ed505d8ea34fbfcbe16ac875ed08c4a9c229325f364736f6c634300081e0033";

    // Convert hex to bytes
    var buf: [2048]u8 = undefined;
    const len = deployment_hex.len / 2;
    for (0..len) |i| {
        const byte_str = deployment_hex[i * 2 .. i * 2 + 2];
        buf[i] = std.fmt.parseInt(u8, byte_str, 16) catch unreachable;
    }
    const deployment_bytes = buf[0..len];

    // Analyze with fusions enabled
    var bc = try TestBytecode.init(allocator, deployment_bytes);
    defer bc.deinit();

    // Count fusions using iterator
    var iter = bc.createIterator();
    var push_jump_count: usize = 0;
    var push_jumpi_count: usize = 0;
    while (try iter.next()) |op_data| {
        switch (op_data) {
            .push_jump_fusion => push_jump_count += 1,
            .push_jumpi_fusion => push_jumpi_count += 1,
            else => {},
        }
    }
    std.log.info("Bytecode analysis found {} PUSH_JUMP and {} PUSH_JUMPI fusions", .{ push_jump_count, push_jumpi_count });
    try testing.expect(push_jump_count > 0 or push_jumpi_count > 0);

    // Build opcode handlers and dispatch schedule
    const frame_handlers = @import("evm").frame_handlers;
    const opcode_handlers = frame_handlers.getOpcodeHandlers(TestFrame, &.{});
    var tracer = Tracer.init(allocator, .{}); // Add a tracer for the init call
    defer tracer.deinit();
    var schedule = try TestDispatch.DispatchSchedule.init(allocator, bc, &opcode_handlers, @as(?*Tracer, &tracer));
    defer schedule.deinit();

    // Build jump table from schedule
    // The schedule owns the jump table for its code.
    const jump_table = schedule.jump_table;

    std.log.info("Jump table created with {} entries", .{jump_table.count()});
    try testing.expect(jump_table.count() > 0);
}

test "fusion dispatch: simple PUSH+JUMPI resolution" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;

    // Simple bytecode with PUSH+JUMPI that should be fused
    // PC: 0: PUSH1 1 (condition)
    // PC: 2: PUSH1 7 (jump dest)
    // PC: 4: JUMPI
    // PC: 5: INVALID
    // PC: 6: INVALID
    // PC: 7: JUMPDEST
    // PC: 8: STOP
    const bytecode_hex = "6001600757FEFE5B00";

    std.log.info("Testing simple PUSH+JUMPI dispatch resolution", .{});

    // Convert hex to bytes and analyze
    var buf: [128]u8 = undefined;
    const len = bytecode_hex.len / 2;
    for (0..len) |i| {
        const byte_str = bytecode_hex[i * 2 .. i * 2 + 2];
        buf[i] = std.fmt.parseInt(u8, byte_str, 16) catch unreachable;
    }
    var bc = try TestBytecode.init(allocator, buf[0..len]);
    defer bc.deinit();

    // Create dispatch
    const frame_handlers = @import("evm").frame_handlers;
    const opcode_handlers = frame_handlers.getOpcodeHandlers(TestFrame, &.{});
    var tracer2 = Tracer.init(allocator, .{}); // Add a tracer for the init call
    defer tracer2.deinit();
    var schedule = try TestDispatch.DispatchSchedule.init(allocator, bc, &opcode_handlers, @as(?*Tracer, &tracer2));
    defer schedule.deinit();

    // Create jump table
    // The schedule owns the jump table for its code.
    const jump_table = schedule.jump_table;

    std.log.info("Jump table has {} entries", .{jump_table.count()});

    // Verify resolution
    // Verify a known JUMPDEST is resolvable (PC=7)
    const maybe = jump_table.findJumpTarget(7);
    try testing.expect(maybe != null);
}

test "fusion dispatch: a static JUMPI carries both successor blocks and no BLOCK_BEGIN follows" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;

    // PC 0: PUSH1 1   PC 2: PUSH1 7   PC 4: JUMPI   PC 5: INVALID   PC 6: INVALID
    // PC 7: JUMPDEST  PC 8: STOP
    const code = [_]u8{ 0x60, 0x01, 0x60, 0x07, 0x57, 0xFE, 0xFE, 0x5B, 0x00 };
    var bc = try TestBytecode.init(allocator, &code);
    defer bc.deinit();
    try testing.expectEqual(@as(usize, 1), bc.jumpdest_count);
    try testing.expectEqual(@as(usize, 7), bc.opcode_count);

    const frame_handlers = @import("evm").frame_handlers;
    const opcode_handlers = frame_handlers.getOpcodeHandlers(TestFrame, &.{});
    var tracer = Tracer.init(allocator, .{});
    defer tracer.deinit();
    var schedule = try TestDispatch.DispatchSchedule.init(allocator, bc, &opcode_handlers, @as(?*Tracer, &tracer));
    defer schedule.deinit();
    try testing.expect(schedule.validate());

    // [0] first block  [1] PUSH1  [2] 1  [3] JUMPI_TO_STATIC  [4] target cursor
    // [5] target block  [6] fall-through block  [7] INVALID  [8] INVALID
    // [9] JUMPDEST  [10] its block  [11] STOP  [12] implicit STOP
    // [13] INVALID_JUMP_TARGET  [14] STOP  [15] STOP
    const items = schedule.items;
    try testing.expectEqual(@as(usize, 16), items.len);
    const static_jumpi = frame_handlers.getSyntheticHandler(TestFrame, .JUMPI_TO_STATIC_LOCATION);
    try testing.expectEqual(static_jumpi, items[3].opcode_handler);

    // The jump lands on the instruction after the JUMPDEST, not on the JUMPDEST.
    try testing.expectEqual(@intFromPtr(&items[11]), @intFromPtr(items[4].jump_static.dispatch));
    // Its item carries a copy of the JUMPDEST's block metadata.
    try testing.expectEqual(@as(u64, @bitCast(items[10].jump_dest)), @as(u64, @bitCast(items[5].jump_dest)));
    // JUMPDEST (1 gas) and STOP (0 gas): the block costs 1 and needs no stack.
    try testing.expectEqual(@as(u32, 1), items[5].jump_dest.gas);

    // The fall-through block is charged from the jump's last item; the next item is
    // the block's first instruction, with no BLOCK_BEGIN in between.
    try testing.expectEqual(opcode_handlers[0xFE], items[7].opcode_handler);
    try testing.expectEqual(opcode_handlers[0xFE], items[8].opcode_handler);
    try testing.expectEqual(opcode_handlers[0x5B], items[9].opcode_handler);
    if (comptime TestDispatch.item_tagged) {
        try testing.expect(items[4] == .jump_static);
        try testing.expect(items[5] == .jump_dest);
        try testing.expect(items[6] == .jump_dest);
        try testing.expect(items[7] == .opcode_handler);
    }

    // Dynamic jumps still land on the JUMPDEST itself.
    try testing.expectEqual(@as(usize, 1), schedule.jump_table.count());
    try testing.expectEqual(@intFromPtr(&items[9]), @intFromPtr(schedule.jump_table.findJumpTarget(7).?.cursor));
    try testing.expect(schedule.jump_table.findJumpTarget(8) == null);
}

test "fusion dispatch: a static jump to a non-JUMPDEST targets the invalid-jump item and charges nothing" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;

    // PC 0: PUSH1 3   PC 2: JUMP   PC 3: STOP
    const code = [_]u8{ 0x60, 0x03, 0x56, 0x00 };
    var bc = try TestBytecode.init(allocator, &code);
    defer bc.deinit();

    const frame_handlers = @import("evm").frame_handlers;
    const opcode_handlers = frame_handlers.getOpcodeHandlers(TestFrame, &.{});
    var tracer = Tracer.init(allocator, .{});
    defer tracer.deinit();
    var schedule = try TestDispatch.DispatchSchedule.init(allocator, bc, &opcode_handlers, @as(?*Tracer, &tracer));
    defer schedule.deinit();
    try testing.expect(schedule.validate());

    // [0] first block  [1] JUMP_TO_STATIC  [2] target cursor  [3] target block
    // [4] STOP  [5] implicit STOP  [6] INVALID_JUMP_TARGET  [7] STOP  [8] STOP
    const items = schedule.items;
    try testing.expectEqual(@as(usize, 9), items.len);
    try testing.expectEqual(frame_handlers.getSyntheticHandler(TestFrame, .JUMP_TO_STATIC_LOCATION), items[1].opcode_handler);
    try testing.expectEqual(frame_handlers.getSyntheticHandler(TestFrame, .INVALID_JUMP_TARGET), items[6].opcode_handler);
    try testing.expectEqual(@intFromPtr(&items[6]), @intFromPtr(items[2].jump_static.dispatch));
    try testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(items[3].jump_dest)));
    try testing.expectEqual(@as(usize, 0), schedule.jump_table.count());
    try testing.expectEqual(@as(usize, 0), schedule.jump_table.byteSize());
}

test "fusion dispatch: the schedule keeps one compact jump table and BLOCK_BEGIN only where no jump enters the block" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;

    // Runtime code of ten-thousand-hashes: static and dynamic jumps, gas-observing
    // instructions and JUMPDESTs.
    const runtime_hex = "6080604052348015600e575f5ffd5b50600436106026575f3560e01c806330627b7c14602a575b5f5ffd5b60306032565b005b5f5b614e20811015605e5760408051602081018390520160408051601f19818403019052526001016034565b5056";
    var buf: [256]u8 = undefined;
    const len = runtime_hex.len / 2;
    for (0..len) |i| buf[i] = try std.fmt.parseInt(u8, runtime_hex[i * 2 .. i * 2 + 2], 16);
    var bc = try TestBytecode.init(allocator, buf[0..len]);
    defer bc.deinit();

    const frame_handlers = @import("evm").frame_handlers;
    const opcode_handlers = frame_handlers.getOpcodeHandlers(TestFrame, &.{});
    var tracer = Tracer.init(allocator, .{});
    defer tracer.deinit();
    var schedule = try TestDispatch.DispatchSchedule.init(allocator, bc, &opcode_handlers, @as(?*Tracer, &tracer));
    defer schedule.deinit();
    try testing.expect(schedule.validate());

    // The JUMPDEST positions live in the jump table and nowhere else.
    try testing.expect(!@hasField(TestDispatch.DispatchSchedule, "jumpdests"));
    try testing.expectEqual(bc.jumpdest_count, schedule.jump_table.count());
    try testing.expect(schedule.jump_table.byteSize() <= 24 * @max(bc.jumpdest_count, 1));

    // Walk the code: every JUMPDEST resolves, nothing else does, and a block that
    // is entered by falling through gets a BLOCK_BEGIN unless a static conditional
    // jump enters it.
    var iter = bc.createIterator();
    var expected_block_begins: usize = 0;
    var jumpdests: usize = 0;
    while (true) {
        const pc = iter.pc;
        const op_data = try iter.next() orelse break;
        switch (op_data) {
            .jumpdest => {
                jumpdests += 1;
                try testing.expect(schedule.jump_table.findJumpTarget(pc) != null);
            },
            else => try testing.expect(schedule.jump_table.findJumpTarget(pc) == null),
        }
        const enters_own_successor = op_data == .push_jumpi_fusion or op_data == .iszero_jumpi;
        if (!enters_own_successor and try TestDispatch.blockBeginFollows(iter.bytecode, pc, iter.pc)) {
            expected_block_begins += 1;
        }
    }
    try testing.expectEqual(bc.jumpdest_count, jumpdests);

    if (comptime TestDispatch.item_tagged) {
        // Debug builds keep BLOCK_BEGIN and JUMPDEST as distinct handlers.
        const block_begin = frame_handlers.getSyntheticHandler(TestFrame, .BLOCK_BEGIN);
        var block_begins: usize = 0;
        for (schedule.items) |item| {
            if (item == .opcode_handler and item.opcode_handler == block_begin) block_begins += 1;
        }
        try testing.expectEqual(expected_block_begins, block_begins);
    }
}
