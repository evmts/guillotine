const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const log = evm.log;
const frame_mod = evm.frame;
const FrameConfig = evm.FrameConfig;
const MemoryDatabase = evm.MemoryDatabase;
const Address = @import("voltaire").Address.Address;
const Tracer = @import("evm").Tracer;

// Test configuration for frame
const test_config = FrameConfig{
    .stack_size = 1024,
    .WordType = u256,
    .max_bytecode_size = 1024,
    .block_gas_limit = 30_000_000,
    .DatabaseType = MemoryDatabase,
    .memory_initial_capacity = 4096,
    .memory_limit = 0xFFFFFF,
};

const TestFrame = frame_mod.Frame(test_config, evm.DefaultEvm);
const TestBytecode = evm.Bytecode(.{ .max_bytecode_size = test_config.max_bytecode_size });
const TestDispatch = evm.FrameDispatch(TestFrame);

test {
    _ = @import("static_jump_test.zig");
    _ = @import("dispatch_observability_test.zig");
    _ = @import("differential/debug_push32_test.zig");
}

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
    while (iter.next()) |op_data| {
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
    const jump_table = try TestDispatch.createJumpTable(allocator, schedule.items, &bc);
    defer jump_table.deinit(allocator);

    std.log.info("Jump table created with {} entries", .{jump_table.entries.len});
    try testing.expect(jump_table.entries.len > 0);
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
    const jump_table = try TestDispatch.createJumpTable(
        allocator,
        schedule.items,
        &bc,
    );
    defer jump_table.deinit(allocator);

    std.log.info("Jump table has {} entries", .{jump_table.entries.len});

    // Verify resolution
    // Verify a known JUMPDEST is resolvable (PC=7)
    const maybe = jump_table.findJumpTarget(7);
    try testing.expect(maybe != null);
}

test "fusion dispatch: ISZERO+PUSH+JUMPI stores a short target as a pointer" {
    const allocator = testing.allocator;
    const code = [_]u8{ 0x5f, 0x15, 0x60, 6, 0x57, 0xfe, 0x5b, 0x00 };
    var bytecode = try TestBytecode.init(allocator, &code);
    defer bytecode.deinit();

    var schedule = try TestDispatch.DispatchSchedule.init(allocator, bytecode, &TestFrame.opcode_handlers, @as(?*Tracer, null));
    defer schedule.deinit();
    try testing.expect(schedule.validate());

    const index = @as(usize, @intFromBool(schedule.has_first_block_gas)) + 1;
    if (schedule.item_kinds.len != 0) {
        try testing.expectEqualSlices(TestDispatch.ItemKind, &.{ .opcode_handler, .push_pointer }, schedule.item_kinds[index..][0..2]);
    }
    const opcode = evm.OpcodeSynthetic.OpcodeSynthetic.ISZERO_JUMPI;
    try testing.expectEqual(evm.frame_handlers.getSyntheticHandler(TestFrame, @intFromEnum(opcode)), schedule.items[index].opcode_handler);
    try testing.expectEqual(@as(u256, 6), schedule.items[index + 1].push_pointer.value_ptr.*);
}
