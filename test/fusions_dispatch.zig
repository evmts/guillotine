const std = @import("std");
const testing = std.testing;
const log = @import("log");
const evm = @import("evm");
const frame_mod = evm.frame;
const FrameConfig = evm.FrameConfig;
const MemoryDatabase = evm.MemoryDatabase;
const Address = @import("primitives").Address.Address;
const DefaultTracer = @import("evm").tracer.DefaultTracer;
const Evm = @import("evm").evm.Evm;

// Test configuration for frame
const test_config = FrameConfig{
    .stack_size = 1024,
    .WordType = u256,
    .max_bytecode_size = 1024,
    .block_gas_limit = 30_000_000,
    .DatabaseType = MemoryDatabase,
    .TracerType = DefaultTracer,
    .memory_initial_capacity = 4096,
    .memory_limit = 0xFFFFFF,
};

const TestFrame = frame_mod.Frame(test_config);
const TestBytecode = evm.Bytecode(.{ .max_bytecode_size = test_config.max_bytecode_size });
const TestDispatch = evm.FrameDispatch(TestFrame);

test "fusion dispatch: verify jump resolution for ten-thousand-hashes" {
    std.testing.log_level = .debug;
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
    const opcode_handlers = frame_handlers.getOpcodeHandlers(TestFrame);
    var schedule = try TestDispatch.DispatchSchedule.init(allocator, bc, &opcode_handlers);
    defer schedule.deinit();

    // Build jump table from schedule
    const jump_table = try TestDispatch.createJumpTable(allocator, schedule.items, bc);
    defer allocator.free(jump_table.entries);

    std.log.info("Jump table created with {} entries", .{jump_table.entries.len});
    try testing.expect(jump_table.entries.len > 0);
}

test "fusion dispatch: simple PUSH+JUMPI resolution" {
    std.testing.log_level = .debug;
    const allocator = testing.allocator;

    // Simple bytecode with PUSH+JUMPI that should be fused
    // PC: 0: PUSH1 1 (condition)
    // PC: 2: PUSH1 7 (jump dest)
    // PC: 4: JUMPI
    // PC: 5: INVALID
    // PC: 6: INVALID
    // PC: 7: JUMPDEST
    // PC: 8: STOP
    const bytecode_hex = "60016007576EFEFE5B00";

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
    const opcode_handlers = frame_handlers.getOpcodeHandlers(TestFrame);
    var schedule = try TestDispatch.DispatchSchedule.init(allocator, bc, &opcode_handlers);
    defer schedule.deinit();

    // Create jump table
    const jump_table = try TestDispatch.createJumpTable(
        allocator,
        schedule.items,
        bc,
    );
    defer allocator.free(jump_table.entries);

    std.log.info("Jump table has {} entries", .{jump_table.entries.len});

    // Verify resolution
    // Verify a known JUMPDEST is resolvable (PC=7)
    const maybe = jump_table.findJumpTarget(7);
    try testing.expect(maybe != null);
}
