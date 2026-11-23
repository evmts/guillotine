const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const log = evm.log;

const TestFrame = evm.DefaultEvm.Frame;
const TestDispatch = TestFrame.Dispatch;
const TestBytecode = evm.DefaultEvm.Bytecode;

test "simple JUMPI with valid JUMPDEST" {
    const allocator = testing.allocator;

    const bytecode_data = [_]u8{
        0x60, 0x05, // PUSH1 0x05
        0x60, 0x01, // PUSH1 0x01
        0x57, // JUMPI (PC=4)
        0x00, // STOP (PC=5)
        0x00, // STOP (PC=6)
        0x5b, // JUMPDEST (PC=7)
        0x60, 0x42, // PUSH1 0x42
        0x00, // STOP
    };

    var bytecode = try TestBytecode.init(allocator, &bytecode_data);
    defer bytecode.deinit();

    var tracer = evm.Tracer.init(allocator, .{});
    defer tracer.deinit();
    var schedule = try TestDispatch.DispatchSchedule.init(allocator, &bytecode, &TestFrame.opcode_handlers, @as(?*evm.Tracer, &tracer));
    defer schedule.deinit();

    const jump_table = try TestDispatch.createDenseJumpTable(allocator, schedule.items, &bytecode);
    defer jump_table.deinit(allocator);

    try testing.expect(jump_table.entries.len > 0);
    try testing.expect(jump_table.findJumpTarget(7) != null);
    try testing.expect(jump_table.findJumpTargetU256(7) != null);
    try testing.expect(jump_table.findJumpTarget(0) == null);
    try testing.expect(jump_table.findJumpTarget(5) == null);
    try testing.expect(jump_table.findJumpTargetU256(std.math.maxInt(u256)) == null);
}

test "JUMPI jumping to PC 3 should fail" {
    const allocator = testing.allocator;

    const bytecode_data = [_]u8{
        0x60, 0x03, // PUSH1 0x03
        0x60, 0x01, // PUSH1 0x01
        0x57, // JUMPI (PC=4)
        0x00, // STOP (PC=5)
    };

    var bytecode = try TestBytecode.init(allocator, &bytecode_data);
    defer bytecode.deinit();

    var tracer = evm.Tracer.init(allocator, .{});
    defer tracer.deinit();
    var schedule = try TestDispatch.DispatchSchedule.init(allocator, &bytecode, &TestFrame.opcode_handlers, @as(?*evm.Tracer, &tracer));
    defer schedule.deinit();

    const jump_table = try TestDispatch.createDenseJumpTable(allocator, schedule.items, &bytecode);
    defer jump_table.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), jump_table.entries.len);
    try testing.expect(jump_table.findJumpTarget(3) == null);
    try testing.expect(jump_table.findJumpTargetU256(3) == null);
}

test "simple looping bytecode" {
    const allocator = testing.allocator;

    const bytecode_data = [_]u8{
        0x5b, // JUMPDEST (PC=0)
        0x60, 0x01, // PUSH1 0x01
        0x01, // ADD
        0x80, // DUP1
        0x61, 0x03, 0xe8, // PUSH2 0x03e8
        0x10, // LT
        0x60, 0x00, // PUSH1 0x00
        0x57, // JUMPI
        0x50, // POP
        0x00, // STOP
    };

    var bytecode = try TestBytecode.init(allocator, &bytecode_data);
    defer bytecode.deinit();

    var tracer = evm.Tracer.init(allocator, .{});
    defer tracer.deinit();
    var schedule = try TestDispatch.DispatchSchedule.init(allocator, &bytecode, &TestFrame.opcode_handlers, @as(?*evm.Tracer, &tracer));
    defer schedule.deinit();

    const jump_table = try TestDispatch.createDenseJumpTable(allocator, schedule.items, &bytecode);
    defer jump_table.deinit(allocator);

    log.debug("Jump table entries: {}", .{jump_table.entries.len});
    try testing.expectEqual(@as(usize, 1), jump_table.entries.len);
    try testing.expectEqual(@as(TestFrame.PcType, 0), jump_table.entries[0].pc);
    try testing.expect(jump_table.findJumpTarget(0) != null);
    try testing.expect(jump_table.findJumpTargetU256(0) != null);
    try testing.expect(jump_table.findJumpTarget(3) == null);
}
