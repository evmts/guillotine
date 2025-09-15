const std = @import("std");
const testing = std.testing;
const Frame = @import("../src/evm/frame.zig").Frame;
const dispatch_mod = @import("../src/evm/dispatch.zig");
const bytecode_mod = @import("../src/evm/bytecode.zig");
const FrameConfig = @import("../src/evm/frame_config.zig").FrameConfig;
const DefaultTracer = @import("../src/tracer/tracer.zig").DefaultTracer;
const log = @import("../src/evm/log.zig");

// Test configuration
const test_config = FrameConfig{
    .stack_size = 1024,
    .WordType = u256,
    .max_bytecode_size = 1024,
    .block_gas_limit = 30_000_000,
    .DatabaseType = @TypeOf(null),
    .memory_initial_capacity = 4096,
    .memory_limit = 0xFFFFFF,
};

const TestFrame = Frame(test_config);
const TestBytecode = bytecode_mod.Bytecode(.{ .max_bytecode_size = test_config.max_bytecode_size });

test "simple JUMPI with valid JUMPDEST" {
    const allocator = testing.allocator;

    // Simple bytecode: PUSH1 0x05, PUSH1 0x01, JUMPI, STOP, STOP, JUMPDEST, PUSH1 0x42, STOP
    const bytecode_data = [_]u8{
        0x60, 0x05, // PUSH1 0x05 (jump destination)
        0x60, 0x01, // PUSH1 0x01 (condition - true)
        0x57, // JUMPI (PC=4)
        0x00, // STOP (PC=5)
        0x00, // STOP (PC=6)
        0x5b, // JUMPDEST (PC=7)
        0x60, 0x42, // PUSH1 0x42
        0x00, // STOP
    };

    const bytecode = try TestBytecode.init(allocator, &bytecode_data);
    defer bytecode.deinit();

    log.debug("\n=== Test: simple JUMPI with valid JUMPDEST ===", .{});
    log.debug("Bytecode: {any}", .{bytecode_data});

    // Create dispatch schedule
    const schedule = try TestFrame.Dispatch.init(allocator, &bytecode, &TestFrame.opcode_handlers);
    defer allocator.free(schedule);

    log.debug("Schedule length: {}", .{schedule.len});

    // Create jump table
    const jump_table = try TestFrame.Dispatch.createJumpTable(allocator, schedule, &bytecode);
    defer allocator.free(jump_table.entries);

    log.debug("Jump table entries: {}", .{jump_table.entries.len});
    for (jump_table.entries) |entry| {
        log.debug("  PC {x}: schedule_index={any}", .{ entry.pc, @intFromPtr(entry.dispatch.cursor) - @intFromPtr(schedule.ptr) });
    }

    // Verify jump table has correct entry
    try testing.expect(jump_table.entries.len > 0);

    // Find JUMPDEST at PC 7
    const jumpdest_dispatch = jump_table.findJumpTarget(7);
    try testing.expect(jumpdest_dispatch != null);

    // Should not find JUMPDEST at other locations
    try testing.expect(jump_table.findJumpTarget(0) == null);
    try testing.expect(jump_table.findJumpTarget(5) == null);
}

test "JUMPI jumping to PC 3 should fail" {
    const allocator = testing.allocator;

    // Bytecode that tries to jump to PC=3 (which is not a JUMPDEST)
    const bytecode_data = [_]u8{
        0x60, 0x03, // PUSH1 0x03 (jump destination - invalid!)
        0x60, 0x01, // PUSH1 0x01 (condition - true)
        0x57, // JUMPI (PC=4)
        0x00, // STOP (PC=5)
    };

    const bytecode = try TestBytecode.init(allocator, &bytecode_data);
    defer bytecode.deinit();

    log.debug("\n=== Test: JUMPI jumping to invalid PC 3 ===", .{});
    log.debug("Bytecode: {any}", .{bytecode_data});

    // Create dispatch schedule
    const schedule = try TestFrame.Dispatch.init(allocator, &bytecode, &TestFrame.opcode_handlers);
    defer allocator.free(schedule);

    log.debug("Schedule length: {}", .{schedule.len});

    // Create jump table
    const jump_table = try TestFrame.Dispatch.createJumpTable(allocator, schedule, &bytecode);
    defer allocator.free(jump_table.entries);

    log.debug("Jump table entries: {}", .{jump_table.entries.len});
    for (jump_table.entries) |entry| {
        log.debug("  PC {x}: schedule_index={any}", .{ entry.pc, @intFromPtr(entry.dispatch.cursor) - @intFromPtr(schedule.ptr) });
    }

    // Should have no valid jump destinations
    try testing.expect(jump_table.entries.len == 0);

    // Should not find JUMPDEST at PC 3
    const invalid_dispatch = jump_table.findJumpTarget(3);
    try testing.expect(invalid_dispatch == null);
    log.debug("PC 3 is not a valid JUMPDEST: {}", .{invalid_dispatch == null});
}

test "simple looping bytecode" {
    const allocator = testing.allocator;

    // Loop bytecode from gas_edge_cases_test
    const bytecode_data = [_]u8{
        0x5b, // JUMPDEST (PC=0) - loop start
        0x60, 0x01, // PUSH1 0x01
        0x01, // ADD
        0x80, // DUP1
        0x61, 0x03, 0xe8, // PUSH2 0x03e8 (1000)
        0x10, // LT
        0x60, 0x00, // PUSH1 0x00 (jump to JUMPDEST at PC=0)
        0x57, // JUMPI - jump to PC=0
        0x50, // POP
        0x00, // STOP
    };

    const bytecode = try TestBytecode.init(allocator, &bytecode_data);
    defer bytecode.deinit();

    // Create dispatch schedule
    const schedule = try TestFrame.Dispatch.init(allocator, &bytecode, &TestFrame.opcode_handlers);
    defer allocator.free(schedule);

    // Create jump table
    const jump_table = try TestFrame.Dispatch.createJumpTable(allocator, schedule, &bytecode);
    defer allocator.free(jump_table.entries);

    for (jump_table.entries) |entry| {
        log.debug("  PC {x}: schedule_index={any}", .{ entry.pc, @intFromPtr(entry.dispatch.cursor) - @intFromPtr(schedule.ptr) });
    }

    // Should have JUMPDEST at PC 0
    try testing.expect(jump_table.entries.len == 1);
    try testing.expect(jump_table.entries[0].pc == 0);

    // Should find JUMPDEST at PC 0
    const jumpdest_dispatch = jump_table.findJumpTarget(0);
    try testing.expect(jumpdest_dispatch != null);

    // Should NOT find JUMPDEST at PC 3
    const invalid_dispatch = jump_table.findJumpTarget(3);
    try testing.expect(invalid_dispatch == null);
}
