const std = @import("std");
const builtin = @import("builtin");
const bytecode_mod = @import("../bytecode/bytecode.zig");
const BytecodeConfig = @import("../bytecode/bytecode_config.zig").BytecodeConfig;
const Opcode = @import("../opcodes/opcode_data.zig").Opcode;
const OpcodeSynthetic = @import("../opcodes/opcode_synthetic.zig").OpcodeSynthetic;
const testing = std.testing;

const TestFrame = @import("../evm.zig").Evm(.{}).Frame;
const TestDispatch = TestFrame.Dispatch;

// Mock opcode handlers for schedule structure checks
fn mockStop(frame: *TestFrame, cursor: [*]const TestDispatch.Item) TestFrame.Error!noreturn {
    _ = frame;
    _ = cursor;
    return TestFrame.Error.Stop;
}

fn mockAdd(frame: *TestFrame, cursor: [*]const TestDispatch.Item) TestFrame.Error!noreturn {
    _ = frame;
    _ = cursor;
    return TestFrame.Error.Stop;
}

fn mockPush1(frame: *TestFrame, cursor: [*]const TestDispatch.Item) TestFrame.Error!noreturn {
    _ = frame;
    _ = cursor;
    return TestFrame.Error.Stop;
}

fn mockJumpdest(frame: *TestFrame, cursor: [*]const TestDispatch.Item) TestFrame.Error!noreturn {
    _ = frame;
    _ = cursor;
    return TestFrame.Error.Stop;
}

fn mockPc(frame: *TestFrame, cursor: [*]const TestDispatch.Item) TestFrame.Error!noreturn {
    _ = frame;
    _ = cursor;
    return TestFrame.Error.Stop;
}

fn mockInvalid(frame: *TestFrame, cursor: [*]const TestDispatch.Item) TestFrame.Error!noreturn {
    _ = frame;
    _ = cursor;
    return TestFrame.Error.InvalidOpcode;
}

fn createTestHandlers() [256]TestFrame.OpcodeHandler {
    var handlers: [256]TestFrame.OpcodeHandler = undefined;
    for (&handlers) |*handler| handler.* = &mockInvalid;
    handlers[@intFromEnum(Opcode.STOP)] = &mockStop;
    handlers[@intFromEnum(Opcode.ADD)] = &mockAdd;
    for (@intFromEnum(Opcode.PUSH1)..@as(usize, @intFromEnum(Opcode.PUSH32)) + 1) |opcode| {
        handlers[opcode] = &mockPush1;
    }
    handlers[@intFromEnum(Opcode.JUMPDEST)] = &mockJumpdest;
    handlers[@intFromEnum(Opcode.PC)] = &mockPc;
    return handlers;
}

// ============================================================================
// All tests moved from dispatch.zig
// ============================================================================

test "Dispatch - basic initialization with empty bytecode" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create empty bytecode
    const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
        .max_bytecode_size = TestFrame.config.max_bytecode_size,
        .max_initcode_size = TestFrame.config.max_initcode_size,
        .fusions_enabled = true,
    });
    var bytecode = try Bytecode.init(allocator, &[_]u8{});
    defer bytecode.deinit();

    // Create dispatch
    var dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers, null);
    defer dispatch_items.deinit();

    // Should have at least 2 STOP handlers
    try testing.expect(dispatch_items.items.len >= 2);

    // Last two items should be STOP handlers
    try testing.expect(dispatch_items.items[dispatch_items.items.len - 1].opcode_handler == &mockStop);
    try testing.expect(dispatch_items.items[dispatch_items.items.len - 2].opcode_handler == &mockStop);
}

test "Dispatch - simple bytecode with ADD" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with ADD instruction
    const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
        .max_bytecode_size = TestFrame.config.max_bytecode_size,
        .max_initcode_size = TestFrame.config.max_initcode_size,
        .fusions_enabled = true,
    });
    var bytecode = try Bytecode.init(allocator, &[_]u8{@intFromEnum(Opcode.ADD)});
    defer bytecode.deinit();

    // Create dispatch
    var dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers, null);
    defer dispatch_items.deinit();

    // Should have ADD handler + 4 terminal items
    const offset0: usize = @intFromBool(dispatch_items.has_first_block_gas);
    try testing.expect(dispatch_items.items.len == offset0 + 5);
    try testing.expect(dispatch_items.items[offset0].opcode_handler == &mockAdd);
}

test "Dispatch - PUSH1 with inline metadata" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with PUSH1 42
    const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
        .max_bytecode_size = TestFrame.config.max_bytecode_size,
        .max_initcode_size = TestFrame.config.max_initcode_size,
        .fusions_enabled = true,
    });
    var bytecode = try Bytecode.init(allocator, &[_]u8{ @intFromEnum(Opcode.PUSH1), 42 });
    defer bytecode.deinit();

    // Create dispatch
    var dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers, null);
    defer dispatch_items.deinit();

    // Should have PUSH1 handler + metadata + 4 terminal items
    const offset1: usize = @intFromBool(dispatch_items.has_first_block_gas);
    try testing.expect(dispatch_items.items.len == offset1 + 6);
    try testing.expect(dispatch_items.items[offset1].opcode_handler == &mockPush1);
    try testing.expect(dispatch_items.items[offset1 + 1].push_inline.value == 42);
}

test "Dispatch - PC opcode with metadata" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with PC instruction
    const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
        .max_bytecode_size = TestFrame.config.max_bytecode_size,
        .max_initcode_size = TestFrame.config.max_initcode_size,
        .fusions_enabled = true,
    });
    var bytecode = try Bytecode.init(allocator, &[_]u8{@intFromEnum(Opcode.PC)});
    defer bytecode.deinit();

    // Create dispatch
    var dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers, null);
    defer dispatch_items.deinit();

    // Should have PC handler + metadata + 4 terminal items
    const offset2: usize = @intFromBool(dispatch_items.has_first_block_gas);
    try testing.expect(dispatch_items.items.len == offset2 + 6);
    try testing.expect(dispatch_items.items[offset2].opcode_handler == &mockPc);
    try testing.expect(dispatch_items.items[offset2 + 1].pc.value == 0);
}

// Helper metadata accessor tests removed due to API changes; covered by getOpData checks below.

test "Dispatch - getOpData for PC returns correct metadata and next" {
    const items = [_]TestDispatch.Item{
        .{ .opcode_handler = &mockPc },
        .{ .pc = .{ .value = 42 } },
        .{ .opcode_handler = &mockAdd },
    };

    const dispatch = TestDispatch{ .cursor = @ptrCast(&items[0]) };
    const op_data = dispatch.getOpData(.PC);

    try testing.expect(op_data.metadata.value == 42);
    try testing.expect(op_data.next_cursor.cursor == dispatch.cursor + 2);
}

test "Dispatch - getOpData for regular opcode returns only next" {
    const items = [_]TestDispatch.Item{
        .{ .opcode_handler = &mockAdd },
        .{ .opcode_handler = &mockStop },
    };

    const dispatch = TestDispatch{ .cursor = @ptrCast(&items[0]) };
    const op_data = dispatch.getOpData(.ADD);

    try testing.expect(op_data.next_cursor.cursor == dispatch.cursor + 1);
}

test "Dispatch - complex bytecode sequence" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode: PUSH1 10, PUSH1 20, ADD, STOP
    const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
        .max_bytecode_size = TestFrame.config.max_bytecode_size,
        .max_initcode_size = TestFrame.config.max_initcode_size,
        .fusions_enabled = false,
    });
    var bytecode = try Bytecode.init(allocator, &[_]u8{
        @intFromEnum(Opcode.PUSH1), 10,
        @intFromEnum(Opcode.PUSH1), 20,
        @intFromEnum(Opcode.ADD),   @intFromEnum(Opcode.STOP),
    });
    defer bytecode.deinit();

    // Create dispatch
    var dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers, null);
    defer dispatch_items.deinit();

    // Six bytecode items followed by four terminal items.
    const start: usize = @intFromBool(dispatch_items.has_first_block_gas);
    try testing.expect(dispatch_items.items.len == start + 10);

    // First PUSH1
    try testing.expect(dispatch_items.items[start + 0].opcode_handler == &mockPush1);
    try testing.expect(dispatch_items.items[start + 1].push_inline.value == 10);

    // Second PUSH1
    try testing.expect(dispatch_items.items[start + 2].opcode_handler == &mockPush1);
    try testing.expect(dispatch_items.items[start + 3].push_inline.value == 20);

    // ADD
    try testing.expect(dispatch_items.items[start + 4].opcode_handler == &mockAdd);

    // Explicit STOP, implicit STOP, invalid-jump handler, then STOP padding.
    try testing.expect(dispatch_items.items[start + 5].opcode_handler == &mockStop);
    try testing.expect(dispatch_items.items[start + 6].opcode_handler == &mockStop);
    try testing.expect(dispatch_items.items[start + 8].opcode_handler == &mockStop);
    try testing.expect(dispatch_items.items[start + 9].opcode_handler == &mockStop);
}

test "Dispatch - metadata size constraints" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(TestDispatch.Item));
    try testing.expect(@typeInfo(TestDispatch.Item).@"union".layout == .@"extern");
    try testing.expect(@typeInfo(TestDispatch.Item).@"union".tag_type == null);
    // Ensure metadata structs fit in 64 bits
    try testing.expect(@sizeOf(TestDispatch.JumpDestMetadata) == 8);
    try testing.expect(@sizeOf(TestDispatch.PushInlineMetadata) == 8);
    try testing.expect(@sizeOf(TestDispatch.PushPointerMetadata) <= 8);
    try testing.expect(@sizeOf(TestDispatch.JumpStaticMetadata) <= 8);
    try testing.expect(@sizeOf(TestDispatch.FirstBlockMetadata) == 8);
    try testing.expect(@sizeOf(TestDispatch.PcMetadata) <= 8);
}

test "Dispatch - invalid bytecode handling" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with invalid opcode
    const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
        .max_bytecode_size = TestFrame.config.max_bytecode_size,
        .max_initcode_size = TestFrame.config.max_initcode_size,
        .fusions_enabled = true,
    });
    var bytecode = try Bytecode.init(allocator, &[_]u8{0xFE}); // Invalid opcode
    defer bytecode.deinit();

    // Create dispatch
    var dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers, null);
    defer dispatch_items.deinit();

    // Invalid handler plus four terminal items.
    try testing.expect(dispatch_items.items.len == 5);
    try testing.expect(dispatch_items.items[0].opcode_handler == &mockInvalid);
}

test "Dispatch - JUMPDEST with gas metadata" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with JUMPDEST
    const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
        .max_bytecode_size = TestFrame.config.max_bytecode_size,
        .max_initcode_size = TestFrame.config.max_initcode_size,
        .fusions_enabled = true,
    });
    var bytecode = try Bytecode.init(allocator, &[_]u8{@intFromEnum(Opcode.JUMPDEST)});
    defer bytecode.deinit();

    // Create dispatch
    var dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers, null);
    defer dispatch_items.deinit();

    // Should have JUMPDEST handler + metadata + 4 terminal items
    const offset3: usize = @intFromBool(dispatch_items.has_first_block_gas);
    try testing.expect(dispatch_items.items.len == offset3 + 6);
    try testing.expect(dispatch_items.items[offset3].opcode_handler == &mockJumpdest);
    try testing.expect(dispatch_items.items[offset3 + 1].jump_dest.gas == 1);
}

test "Dispatch - PUSH32 with pointer metadata" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with PUSH32 (large value requiring pointer storage)
    const push32_data = [_]u8{@intFromEnum(Opcode.PUSH32)} ++ [_]u8{0xFF} ** 32;
    const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
        .max_bytecode_size = TestFrame.config.max_bytecode_size,
        .max_initcode_size = TestFrame.config.max_initcode_size,
        .fusions_enabled = true,
    });
    var bytecode = try Bytecode.init(allocator, &push32_data);
    defer bytecode.deinit();

    // Create dispatch (auto cleans up pointer metadata in deinit)
    var dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers, null);
    defer dispatch_items.deinit();

    const index: usize = @intFromBool(dispatch_items.has_first_block_gas);
    try testing.expect(dispatch_items.items.len == index + 6);
    try testing.expect(dispatch_items.items[index].opcode_handler == &mockPush1); // Using mockPush1 for all PUSH variants

    // Verify pointer metadata contains the correct large value
    const expected_value: u256 = std.math.maxInt(u256); // 0xFFFF...FFFF (32 bytes of 0xFF) - using maxInt for clarity
    try testing.expect(dispatch_items.items[index + 1].push_pointer.value_ptr.* == expected_value);
}

test "Dispatch - PUSH9 boundary test (first pointer type)" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with PUSH9 (first PUSH that uses pointer storage)
    const push9_data = [_]u8{@intFromEnum(Opcode.PUSH9)} ++ [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x11 };
    const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
        .max_bytecode_size = TestFrame.config.max_bytecode_size,
        .max_initcode_size = TestFrame.config.max_initcode_size,
        .fusions_enabled = true,
    });
    var bytecode = try Bytecode.init(allocator, &push9_data);
    defer bytecode.deinit();

    // Create dispatch (auto cleans up pointer metadata in deinit)
    var dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers, null);
    defer dispatch_items.deinit();

    const index: usize = @intFromBool(dispatch_items.has_first_block_gas);
    try testing.expect(dispatch_items.items.len == index + 6);
    try testing.expect(dispatch_items.items[index].opcode_handler == &mockPush1);

    // Verify the 9-byte value is correctly stored
    const expected_value: u256 = 0x123456789ABCDEF011;
    try testing.expect(dispatch_items.items[index + 1].push_pointer.value_ptr.* == expected_value);
}

test "Dispatch - PUSH8 boundary test (last inline type)" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with PUSH8 (last PUSH that uses inline storage)
    const push8_data = [_]u8{@intFromEnum(Opcode.PUSH8)} ++ [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0 };
    const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
        .max_bytecode_size = TestFrame.config.max_bytecode_size,
        .max_initcode_size = TestFrame.config.max_initcode_size,
        .fusions_enabled = true,
    });
    var bytecode = try Bytecode.init(allocator, &push8_data);
    defer bytecode.deinit();

    // Create dispatch
    var dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers, null);
    defer dispatch_items.deinit();

    const index: usize = @intFromBool(dispatch_items.has_first_block_gas);
    try testing.expect(dispatch_items.items.len == index + 6);
    try testing.expect(dispatch_items.items[index].opcode_handler == &mockPush1);

    // Verify the 8-byte value is stored inline
    const expected_value: u64 = 0x123456789ABCDEF0;
    try testing.expect(dispatch_items.items[index + 1].push_inline.value == expected_value);
}

test "Dispatch - large value no longer truncated" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Test a PUSH4 with value that fits in u64 - should use inline storage
    const push4_small_data = [_]u8{@intFromEnum(Opcode.PUSH4)} ++ [_]u8{ 0x00, 0x00, 0xFF, 0xFF };
    const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
        .max_bytecode_size = TestFrame.config.max_bytecode_size,
        .max_initcode_size = TestFrame.config.max_initcode_size,
        .fusions_enabled = true,
    });
    var bytecode_small = try Bytecode.init(allocator, &push4_small_data);
    defer bytecode_small.deinit();

    var dispatch_items_small = try TestDispatch.init(allocator, &bytecode_small, &handlers, null);
    defer dispatch_items_small.deinit();

    // Should use inline storage for small value
    try testing.expect(dispatch_items_small.items[@as(usize, @intFromBool(dispatch_items_small.has_first_block_gas)) + 1].push_inline.value == 0x0000FFFF);

    // Test a PUSH8 with maximum u64 value - should still use inline storage
    const push8_max_data = [_]u8{@intFromEnum(Opcode.PUSH8)} ++ [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    var bytecode_max = try Bytecode.init(allocator, &push8_max_data);
    defer bytecode_max.deinit();

    var dispatch_items_max = try TestDispatch.init(allocator, &bytecode_max, &handlers, null);
    defer dispatch_items_max.deinit();

    // Should use inline storage for max u64 value
    try testing.expect(dispatch_items_max.items[@as(usize, @intFromBool(dispatch_items_max.has_first_block_gas)) + 1].push_inline.value == std.math.maxInt(u64));
}

test "JumpTable - legacy builder skips PUSH payloads and fallthrough metadata" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();
    const Bytecode = bytecode_mod.Bytecode(.{ .fusions_enabled = false });
    var code = [_]u8{0x67} ++ [_]u8{0} ** 8 ++ [_]u8{ 0x5a, 0x50, 0x5b, 0x00 };
    std.mem.writeInt(u64, code[1..9], @intFromPtr(&mockJumpdest), .big);
    var bytecode = try Bytecode.init(allocator, &code);
    defer bytecode.deinit();

    var analysis = try TestDispatch.initWithJumpTable(allocator, &bytecode, &handlers, null);
    defer analysis.schedule.deinit();
    defer analysis.jump_table.deinit(allocator);

    const legacy = try TestDispatch.createJumpTable(allocator, analysis.schedule.items, &bytecode);
    defer legacy.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), legacy.entries.len);
    try testing.expect(legacy.find_jump_target(2) == null);
    const target = legacy.find_jump_target(11) orelse return error.MissingJumpDestination;
    const expected = analysis.jump_table.find_jump_target(11) orelse return error.MissingJumpDestination;
    try testing.expectEqual(expected, target);
    try testing.expectEqual(@as(TestFrame.OpcodeHandler, &mockJumpdest), target[0].opcode_handler);
}

test "JumpTable - empty jump table" {
    // Create empty jump table
    // Create an empty jump table for testing
    const entries: []const TestDispatch.JumpTable.JumpTableEntry = &.{};
    const jump_table = TestDispatch.JumpTable{ .entries = entries };

    // Should return null for any target
    try testing.expect(jump_table.findJumpTarget(0) == null);
    try testing.expect(jump_table.findJumpTarget(100) == null);
    try testing.expect(jump_table.findJumpTarget(0xFFFF) == null);
}

test "JumpTable - single entry" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with single JUMPDEST at PC 5
    const bytecode_data = [_]u8{
        @intFromEnum(Opcode.PUSH1), 10, // PC 0-1
        @intFromEnum(Opcode.PUSH1), 20, // PC 2-3
        @intFromEnum(Opcode.ADD), // PC 4
        @intFromEnum(Opcode.JUMPDEST), // PC 5 <- target
        @intFromEnum(Opcode.STOP), // PC 6
    };

    const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
        .max_bytecode_size = TestFrame.config.max_bytecode_size,
        .max_initcode_size = TestFrame.config.max_initcode_size,
        .fusions_enabled = true,
    });
    var bytecode = try Bytecode.init(allocator, &bytecode_data);
    defer bytecode.deinit();

    // Create dispatch
    var dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers, null);
    defer dispatch_items.deinit();

    // Create jump table
    const jump_table = try TestDispatch.createJumpTable(allocator, dispatch_items.items, bytecode);
    defer allocator.free(jump_table.entries);

    // Should have exactly one entry
    try testing.expect(jump_table.entries.len == 1);
    try testing.expect(jump_table.entries[0].pc == 5);

    // Test binary search
    try testing.expect(jump_table.findJumpTarget(5) != null);
    try testing.expect(jump_table.findJumpTarget(0) == null);
    try testing.expect(jump_table.findJumpTarget(4) == null);
    try testing.expect(jump_table.findJumpTarget(6) == null);
}

test "JumpTable - multiple entries sorted order" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with multiple JUMPDESTs
    const bytecode_data = [_]u8{
        @intFromEnum(Opcode.JUMPDEST), // PC 0
        @intFromEnum(Opcode.PUSH1), 10, // PC 1-2
        @intFromEnum(Opcode.JUMPDEST), // PC 3
        @intFromEnum(Opcode.ADD), // PC 4
        @intFromEnum(Opcode.JUMPDEST), // PC 5
        @intFromEnum(Opcode.STOP), // PC 6
    };

    const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
        .max_bytecode_size = TestFrame.config.max_bytecode_size,
        .max_initcode_size = TestFrame.config.max_initcode_size,
        .fusions_enabled = true,
    });
    var bytecode = try Bytecode.init(allocator, &bytecode_data);
    defer bytecode.deinit();

    // Create dispatch and jump table
    var dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers, null);
    defer dispatch_items.deinit();

    const jump_table = try TestDispatch.createJumpTable(allocator, dispatch_items.items, bytecode);
    defer allocator.free(jump_table.entries);

    // Should have 3 entries
    try testing.expect(jump_table.entries.len == 3);

    // Verify entries are sorted by PC
    try testing.expect(jump_table.entries[0].pc == 0);
    try testing.expect(jump_table.entries[1].pc == 3);
    try testing.expect(jump_table.entries[2].pc == 5);

    // Test binary search for all valid targets
    try testing.expect(jump_table.findJumpTarget(0) != null);
    try testing.expect(jump_table.findJumpTarget(3) != null);
    try testing.expect(jump_table.findJumpTarget(5) != null);

    // Test binary search for invalid targets
    try testing.expect(jump_table.findJumpTarget(1) == null);
    try testing.expect(jump_table.findJumpTarget(2) == null);
    try testing.expect(jump_table.findJumpTarget(4) == null);
    try testing.expect(jump_table.findJumpTarget(6) == null);
}

test "JumpTable - binary search edge cases" {
    // Create manual jump table with edge case PCs
    const entries = [_]TestDispatch.JumpTable.JumpTableEntry{
        .{ .pc = 0, .dispatch = TestDispatch{ .cursor = undefined } },
        .{ .pc = 1, .dispatch = TestDispatch{ .cursor = undefined } },
        .{ .pc = 100, .dispatch = TestDispatch{ .cursor = undefined } },
        .{ .pc = 0xFFFE, .dispatch = TestDispatch{ .cursor = undefined } },
        .{ .pc = 0xFFFF, .dispatch = TestDispatch{ .cursor = undefined } },
    };

    const jump_table = TestDispatch.JumpTable{ .entries = &entries };

    // Test boundary conditions
    try testing.expect(jump_table.findJumpTarget(0) != null); // First entry
    try testing.expect(jump_table.findJumpTarget(0xFFFF) != null); // Last entry
    try testing.expect(jump_table.findJumpTarget(1) != null); // Second entry
    try testing.expect(jump_table.findJumpTarget(0xFFFE) != null); // Second to last
    try testing.expect(jump_table.findJumpTarget(100) != null); // Middle entry

    // Test just outside boundaries
    try testing.expect(jump_table.findJumpTarget(2) == null);
    try testing.expect(jump_table.findJumpTarget(99) == null);
    try testing.expect(jump_table.findJumpTarget(101) == null);
    try testing.expect(jump_table.findJumpTarget(0xFFFD) == null);
}

test "JumpTable - large jump table performance" {
    const allocator = testing.allocator;

    // Create large jump table (simulate many JUMPDESTs)
    const entries = try allocator.alloc(TestDispatch.JumpTable.JumpTableEntry, 1000);
    defer allocator.free(entries);

    // Fill with sorted PCs (every 10th PC is a JUMPDEST)
    for (entries, 0..) |*entry, i| {
        entry.* = .{
            .pc = @intCast(i * 10),
            .dispatch = TestDispatch{ .cursor = undefined },
        };
    }

    const jump_table = TestDispatch.JumpTable{ .entries = entries };

    // Test that binary search finds all valid targets efficiently
    for (0..1000) |i| {
        const target_pc: TestFrame.PcType = @intCast(i * 10);
        try testing.expect(jump_table.findJumpTarget(target_pc) != null);
    }

    // Test that binary search correctly rejects invalid targets
    for (0..1000) |i| {
        const invalid_pc: TestFrame.PcType = @intCast(i * 10 + 5); // Between valid targets
        try testing.expect(jump_table.findJumpTarget(invalid_pc) == null);
    }
}

test "Dispatch - fusion emits the correct handler and debug kinds" {
    const allocator = testing.allocator;
    const Bytecode = bytecode_mod.Bytecode(.{ .fusions_enabled = true });
    var bytecode = try Bytecode.init(allocator, &.{ 0x60, 0x01, 0x01, 0x00 });
    defer bytecode.deinit();

    var schedule = try TestDispatch.init(allocator, &bytecode, &TestFrame.opcode_handlers, null);
    defer schedule.deinit();

    try testing.expect(schedule.has_first_block_gas);
    const frame_handlers = @import("../frame/frame_handlers.zig");
    const handler = frame_handlers.getSyntheticHandler(TestFrame, @intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE));
    try testing.expectEqual(handler, schedule.items[1].opcode_handler);
    try testing.expectEqual(@as(u64, 1), schedule.items[2].push_inline.value);
    try testing.expect(schedule.validate());
    if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        try testing.expectEqual(schedule.items.len, schedule.item_kinds.len);
        try testing.expectEqualSlices(TestDispatch.ItemKind, &.{ .first_block_gas, .opcode_handler, .push_inline }, schedule.item_kinds[0..3]);

        var bad_schedule = schedule;
        bad_schedule.has_first_block_gas = false;
        try testing.expect(!bad_schedule.validate());
    } else {
        try testing.expectEqual(@as(usize, 0), schedule.item_kinds.len);
    }
}

test "Dispatch - arena owns pointer metadata" {
    const allocator = testing.allocator;
    const code = [_]u8{@intFromEnum(Opcode.PUSH16)} ++ [_]u8{0xff} ** 16;
    const Bytecode = bytecode_mod.Bytecode(.{});
    var bytecode = try Bytecode.init(allocator, &code);
    defer bytecode.deinit();

    const handlers = createTestHandlers();
    var schedule = try TestDispatch.init(allocator, &bytecode, &handlers, null);
    defer schedule.deinit();

    const index: usize = @intFromBool(schedule.has_first_block_gas);
    try testing.expectEqual(@as(u256, std.math.maxInt(u128)), schedule.items[index + 1].push_pointer.value_ptr.*);
}

test "Dispatch - allocation failure handling" {
    // Test what happens when allocation fails during init
    // This exposes potential memory leaks in error paths

    var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const handlers = createTestHandlers();

    // Create simple bytecode
    const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
        .max_bytecode_size = TestFrame.config.max_bytecode_size,
        .max_initcode_size = TestFrame.config.max_initcode_size,
        .fusions_enabled = true,
    });
    var bytecode = try Bytecode.init(testing.allocator, &[_]u8{@intFromEnum(Opcode.ADD)});
    defer bytecode.deinit();

    // Should fail allocation
    const result = TestDispatch.init(failing_allocator.allocator(), &bytecode, &handlers, null);
    try testing.expectError(error.OutOfMemory, result);

    // The errdefer in init should clean up the ArrayList
}

test "Dispatch - edge case empty bytecode safety" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create completely empty bytecode
    const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
        .max_bytecode_size = TestFrame.config.max_bytecode_size,
        .max_initcode_size = TestFrame.config.max_initcode_size,
        .fusions_enabled = true,
    });
    var bytecode = try Bytecode.init(allocator, &[_]u8{});
    defer bytecode.deinit();

    // Create dispatch
    var dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers, null);
    defer dispatch_items.deinit();

    try testing.expect(!dispatch_items.has_first_block_gas);
    try testing.expect(dispatch_items.items.len == 4);
    try testing.expect(dispatch_items.items[0].opcode_handler == &mockStop);
    try testing.expect(dispatch_items.items[2].opcode_handler == &mockStop);
    try testing.expect(dispatch_items.items[3].opcode_handler == &mockStop);

    // Create dispatch wrapper and test safety
    const dispatch = TestDispatch{ .cursor = dispatch_items.items.ptr };
    const next = TestDispatch{ .cursor = dispatch.cursor + 1 };

    // Adjacent items are exactly one dispatch word apart.
    const ptr_diff = @intFromPtr(next.cursor) - @intFromPtr(dispatch.cursor);
    try testing.expect(ptr_diff == @sizeOf(TestDispatch.Item));
}

test "Dispatch - getOpData compilation and type safety" {
    const value: TestFrame.WordType = @as(u256, 1) << 128;
    const items = [_]TestDispatch.Item{
        .{ .opcode_handler = &mockPc },
        .{ .pc = .{ .value = 42 } },
        .{ .opcode_handler = &mockPush1 },
        .{ .push_inline = .{ .value = 123 } },
        .{ .opcode_handler = &mockPush1 },
        .{ .push_pointer = .{ .value_ptr = &value } },
        .{ .opcode_handler = &mockJumpdest },
        .{ .jump_dest = .{ .gas = 100, .min_stack = 0, .max_stack = 0 } },
        .{ .opcode_handler = &mockStop },
    };

    // Test PC opcode
    const pc_dispatch = TestDispatch{ .cursor = @ptrCast(&items[0]) };
    const pc_data = pc_dispatch.getOpData(.PC);
    try testing.expect(@TypeOf(pc_data.metadata) == TestDispatch.PcMetadata);
    try testing.expect(pc_data.metadata.value == 42);

    // Test PUSH1 (inline)
    const push1_dispatch = TestDispatch{ .cursor = @ptrCast(&items[2]) };
    const push1_data = push1_dispatch.getOpData(.PUSH1);
    try testing.expect(@TypeOf(push1_data.metadata) == TestDispatch.PushInlineMetadata);
    try testing.expect(push1_data.metadata.value == 123);

    // Test PUSH32 (pointer)
    const push32_dispatch = TestDispatch{ .cursor = @ptrCast(&items[4]) };
    const push32_data = push32_dispatch.getOpData(.PUSH32);
    try testing.expect(@TypeOf(push32_data.metadata) == TestDispatch.PushPointerMetadata);
    try testing.expectEqual(value, push32_data.metadata.value_ptr.*);

    // Test JUMPDEST
    const jd_dispatch = TestDispatch{ .cursor = @ptrCast(&items[6]) };
    const jd_data = jd_dispatch.getOpData(.JUMPDEST);
    try testing.expect(@TypeOf(jd_data.metadata) == TestDispatch.JumpDestMetadata);
    try testing.expect(jd_data.metadata.gas == 100);

    // Test regular opcode (no metadata)
    const add_items = [_]TestDispatch.Item{ .{ .opcode_handler = &mockAdd }, .{ .opcode_handler = &mockStop } };
    const add_dispatch = TestDispatch{ .cursor = &add_items };
    const add_data = add_dispatch.getOpData(.ADD);
    try testing.expect(!@hasField(@TypeOf(add_data), "metadata"));
}

test "Dispatch - createJumpTable with arithmetic bytecode" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode similar to our differential test
    const bytecode_data = [_]u8{
        // ADD: 5 + 3
        @intFromEnum(Opcode.PUSH1),  0x05,
        @intFromEnum(Opcode.PUSH1),  0x03,
        @intFromEnum(Opcode.ADD),

        // SUB: 10 - 4
           @intFromEnum(Opcode.PUSH1),
        0x0a,                        @intFromEnum(Opcode.PUSH1),
        0x04,                        @intFromEnum(Opcode.SUB),

        // MUL
        @intFromEnum(Opcode.MUL),

        // Store and return
           @intFromEnum(Opcode.PUSH1),
        0x00,                        @intFromEnum(Opcode.MSTORE),
        @intFromEnum(Opcode.PUSH1),  0x20,
        @intFromEnum(Opcode.PUSH1),  0x00,
        @intFromEnum(Opcode.RETURN),
    };

    const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
        .max_bytecode_size = TestFrame.config.max_bytecode_size,
        .max_initcode_size = TestFrame.config.max_initcode_size,
        .fusions_enabled = true,
    });
    var bytecode = try Bytecode.init(allocator, &bytecode_data);
    defer bytecode.deinit();

    // Create dispatch schedule
    var dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers, null);
    defer dispatch_items.deinit();

    // This should not panic
    const jump_table = try TestDispatch.createJumpTable(allocator, dispatch_items.items, bytecode);
    defer allocator.free(jump_table.entries);

    // Should have no entries since there are no JUMPDESTs
    try testing.expect(jump_table.entries.len == 0);
}

test "JumpTable - sorting validation catches unsorted entries" {
    // Test that manual JumpTable construction properly sorts entries
    const allocator = testing.allocator;

    // Create manual entries in reverse order
    var entries = try allocator.alloc(TestDispatch.JumpTable.JumpTableEntry, 3);
    defer allocator.free(entries);

    entries[0] = .{ .pc = 100, .dispatch = TestDispatch{ .cursor = undefined } };
    entries[1] = .{ .pc = 10, .dispatch = TestDispatch{ .cursor = undefined } };
    entries[2] = .{ .pc = 50, .dispatch = TestDispatch{ .cursor = undefined } };

    // Sort them manually using the same algorithm
    std.sort.block(TestDispatch.JumpTable.JumpTableEntry, entries, {}, struct {
        pub fn lessThan(context: void, a: TestDispatch.JumpTable.JumpTableEntry, b: TestDispatch.JumpTable.JumpTableEntry) bool {
            _ = context;
            return a.pc < b.pc;
        }
    }.lessThan);

    // Verify proper sorting
    try testing.expect(entries[0].pc == 10);
    try testing.expect(entries[1].pc == 50);
    try testing.expect(entries[2].pc == 100);

    // Verify they're actually sorted
    for (entries[0..entries.len -| 1], entries[1..]) |current, next| {
        try testing.expect(current.pc < next.pc);
    }
}

test "Dispatch - calculateFirstBlockGas helper function" {
    const allocator = testing.allocator;

    // Test empty bytecode
    {
        const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
            .max_bytecode_size = TestFrame.config.max_bytecode_size,
            .max_initcode_size = TestFrame.config.max_initcode_size,
            .fusions_enabled = true,
        });
        var bytecode = try Bytecode.init(allocator, &[_]u8{});
        defer bytecode.deinit();

        const gas = TestDispatch.calculateFirstBlockGas(&bytecode);
        try testing.expect(gas == 0);
    }

    // Test single STOP instruction
    {
        const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
            .max_bytecode_size = TestFrame.config.max_bytecode_size,
            .max_initcode_size = TestFrame.config.max_initcode_size,
            .fusions_enabled = true,
        });
        var bytecode = try Bytecode.init(allocator, &[_]u8{@intFromEnum(Opcode.STOP)});
        defer bytecode.deinit();

        const gas = TestDispatch.calculateFirstBlockGas(&bytecode);
        try testing.expect(gas == 0); // STOP has 0 gas cost
    }

    // Test block ending with JUMPDEST
    {
        const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
            .max_bytecode_size = TestFrame.config.max_bytecode_size,
            .max_initcode_size = TestFrame.config.max_initcode_size,
            .fusions_enabled = true,
        });
        var bytecode = try Bytecode.init(allocator, &[_]u8{
            @intFromEnum(Opcode.PUSH1), 42, // 3 gas
            @intFromEnum(Opcode.ADD), // 3 gas
            @intFromEnum(Opcode.JUMPDEST), // 1 gas (but terminates block)
        });
        defer bytecode.deinit();

        const gas = TestDispatch.calculateFirstBlockGas(&bytecode);
        try testing.expect(gas == 6); // PUSH1(3) + ADD(3), JUMPDEST not included
    }

    // Test block ending with JUMP
    {
        const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
            .max_bytecode_size = TestFrame.config.max_bytecode_size,
            .max_initcode_size = TestFrame.config.max_initcode_size,
            .fusions_enabled = true,
        });
        var bytecode = try Bytecode.init(allocator, &[_]u8{
            @intFromEnum(Opcode.PUSH1), 10, // 3 gas
            @intFromEnum(Opcode.PUSH1), 20, // 3 gas
            @intFromEnum(Opcode.MUL), // 5 gas
            @intFromEnum(Opcode.JUMP), // 8 gas
        });
        defer bytecode.deinit();

        const gas = TestDispatch.calculateFirstBlockGas(&bytecode);
        try testing.expect(gas == 19); // 3 + 3 + 5 + 8
    }

    // SSTORE has dynamic gas only, but the first block still needs a stack check.
    {
        const Bytecode = bytecode_mod.Bytecode(.{});
        var bytecode = try Bytecode.init(allocator, &.{ @intFromEnum(Opcode.SSTORE), @intFromEnum(Opcode.STOP) });
        defer bytecode.deinit();

        var schedule = try TestDispatch.init(allocator, &bytecode, &TestFrame.opcode_handlers, null);
        defer schedule.deinit();

        try testing.expect(schedule.has_first_block_gas);
        try testing.expectEqual(@as(u32, 0), schedule.items[0].first_block_gas.gas);
        try testing.expectEqual(@as(i16, 2), schedule.items[0].first_block_gas.min_stack);
    }
}

test "JumpTable dispatch pointers reference provided schedule buffer" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Bytecode with a single JUMPDEST
    const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
        .max_bytecode_size = TestFrame.config.max_bytecode_size,
        .max_initcode_size = TestFrame.config.max_initcode_size,
        .fusions_enabled = true,
    });
    var bytecode = try Bytecode.init(allocator, &[_]u8{ @intFromEnum(Opcode.JUMPDEST) });
    defer bytecode.deinit();

    // Build initial schedule
    var sched1 = try TestDispatch.init(allocator, &bytecode, &handlers, null);
    defer sched1.deinit();

    // Build jump table from schedule 1
    const jt1 = try TestDispatch.createJumpTable(allocator, sched1.items, &bytecode);
    defer allocator.free(jt1.entries);
    try testing.expect(jt1.entries.len == 1);

    // Expect the first entry to point into sched1 at index 0
    const expected_ptr1 = sched1.items.ptr; // JUMPDEST is first (index 0)
    try testing.expect(@intFromPtr(jt1.entries[0].dispatch.cursor) == @intFromPtr(expected_ptr1));

    // Create a second schedule buffer at a (likely) different address
    const sched2 = try allocator.alloc(TestDispatch.Item, sched1.items.len);
    defer allocator.free(sched2);
    @memcpy(sched2, sched1.items);

    // Build jump table from schedule 2
    const jt2 = try TestDispatch.createJumpTable(allocator, sched2, bytecode);
    defer allocator.free(jt2.entries);
    try testing.expect(jt2.entries.len == 1);

    // Pointer should now point into sched2
    const expected_ptr2 = sched2.ptr;
    try testing.expect(@intFromPtr(jt2.entries[0].dispatch.cursor) == @intFromPtr(expected_ptr2));
}

test "Aligned bytes can be safely reinterpreted as schedule" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Small bytecode to produce a short schedule
    const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
        .max_bytecode_size = TestFrame.config.max_bytecode_size,
        .max_initcode_size = TestFrame.config.max_initcode_size,
        .fusions_enabled = true,
    });
    var bytecode = try Bytecode.init(allocator, &[_]u8{ @intFromEnum(Opcode.STOP) });
    defer bytecode.deinit();

    var sched = try TestDispatch.init(allocator, &bytecode, &handlers, null);
    defer sched.deinit();

    // Slice as bytes, allocate an aligned u8 buffer, copy, then reinterpret
    const bytes = std.mem.sliceAsBytes(sched.items);
    const item_alignment: std.mem.Alignment = @as(std.mem.Alignment, @enumFromInt(std.math.log2_int(usize, @alignOf(TestDispatch.Item))));
    const buf = try allocator.alignedAlloc(u8, item_alignment, bytes.len);
    defer allocator.free(buf);
    @memcpy(buf, bytes);

    // Reinterpret aligned bytes as typed schedule
    const typed: []const TestDispatch.Item = @as([*]const TestDispatch.Item, @ptrCast(@alignCast(buf.ptr)))[0 .. buf.len / @sizeOf(TestDispatch.Item)];

    // Basic sanity: lengths match and pointer is aligned
    try testing.expect(typed.len == sched.items.len);
    try testing.expect(@intFromPtr(typed.ptr) % @alignOf(TestDispatch.Item) == 0);
}

test "Dispatch - RAII DispatchSchedule for automatic cleanup" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Test error handling with proper cleanup
    {
        var failing_allocator = testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });

        const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
            .max_bytecode_size = TestFrame.config.max_bytecode_size,
            .max_initcode_size = TestFrame.config.max_initcode_size,
            .fusions_enabled = true,
        });
        var bytecode = try Bytecode.init(allocator, &[_]u8{
            @intFromEnum(Opcode.PUSH32), 0xFF, 0xFF, 0xFF, 0xFF, // Will need pointer
            0xFF,                        0xFF, 0xFF, 0xFF, 0xFF,
            0xFF,                        0xFF, 0xFF, 0xFF, 0xFF,
            0xFF,                        0xFF, 0xFF, 0xFF, 0xFF,
            0xFF,                        0xFF, 0xFF, 0xFF, 0xFF,
            0xFF,                        0xFF, 0xFF, 0xFF, 0xFF,
            0xFF,                        0xFF, 0xFF,
        });
        defer bytecode.deinit();

        // Should fail during allocation and clean up properly
        const result = TestDispatch.DispatchSchedule.init(failing_allocator.allocator(), &bytecode, &handlers, null);
        try testing.expectError(error.OutOfMemory, result);
    }

    // Test schedule with mixed inline and pointer pushes
    {
        const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
            .max_bytecode_size = TestFrame.config.max_bytecode_size,
            .max_initcode_size = TestFrame.config.max_initcode_size,
            .fusions_enabled = true,
        });
        var bytecode = try Bytecode.init(allocator, &[_]u8{
            @intFromEnum(Opcode.PUSH1), 42, // Inline
            @intFromEnum(Opcode.PUSH8), 1, 2, 3, 4, 5, 6, 7, 8, // Inline
            @intFromEnum(Opcode.PUSH16), 0xFF, 0xFF, 0xFF, 0xFF, // Pointer
            0xFF,                        0xFF, 0xFF, 0xFF, 0xFF,
            0xFF,                        0xFF, 0xFF, 0xFF, 0xFF,
            0xFF,                        0xFF,
        });
        defer bytecode.deinit();

        var schedule = try TestDispatch.DispatchSchedule.init(allocator, bytecode, &handlers, null);
        defer schedule.deinit();

        if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            try testing.expectEqual(@as(usize, 2), std.mem.count(TestDispatch.ItemKind, schedule.item_kinds, &.{.push_inline}));
            try testing.expectEqual(@as(usize, 1), std.mem.count(TestDispatch.ItemKind, schedule.item_kinds, &.{.push_pointer}));
        } else {
            try testing.expectEqual(@as(usize, 0), schedule.item_kinds.len);
        }
    }
}

test "Dispatch - pretty_print basic functionality" {
    const allocator = testing.allocator;
    const handlers = TestFrame.opcode_handlers;

    // Create simple bytecode: PUSH1 0x42, ADD, STOP
    const code = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x42, @intFromEnum(Opcode.ADD), @intFromEnum(Opcode.STOP) };
    const Bytecode = bytecode_mod.Bytecode(BytecodeConfig{
        .max_bytecode_size = TestFrame.config.max_bytecode_size,
        .max_initcode_size = TestFrame.config.max_initcode_size,
        .fusions_enabled = false,
    });
    var bytecode = try Bytecode.init(allocator, &code);
    defer bytecode.deinit();

    // Create dispatch schedule
    var dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers, null);
    defer dispatch_items.deinit();

    // Test pretty_print
    const formatted = try TestDispatch.pretty_print(allocator, dispatch_items, &bytecode);
    defer allocator.free(formatted);

    // Verify the output contains expected elements
    try testing.expect(std.mem.indexOf(u8, formatted, "=== EVM Dispatch Instruction Stream ===") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "--- Original Bytecode ---") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "--- Dispatch Instruction Stream ---") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "--- Summary ---") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "PUSH1") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "0x42") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "FIRST_BLOCK_GAS") != null);

    const raw = try TestDispatch.pretty_print(allocator, dispatch_items.items, &bytecode);
    defer allocator.free(raw);
    try testing.expectEqualStrings(formatted, raw);
}
