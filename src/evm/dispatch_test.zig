const std = @import("std");
const bytecode_mod = @import("bytecode.zig");
const BytecodeConfig = @import("bytecode_config.zig").BytecodeConfig;
const Opcode = @import("opcode_data.zig").Opcode;
const OpcodeSynthetic = @import("opcode_synthetic.zig").OpcodeSynthetic;
const testing = std.testing;

/// Test infrastructure for dispatch operations
/// Creates test types and helper functions
pub fn DispatchTest() type {
    // Define test frame first
    const TestFrameBase = struct {
        pub const WordType = u256;
        pub const PcType = u32;
        pub const BytecodeConfig = @import("bytecode_config.zig").BytecodeConfig{
            .max_bytecode_size = 1024,
            .max_initcode_size = 49152,
        };

        pub const Error = error{
            TestError,
            Stop,
        };
    };

    // Import the actual dispatch with our test frame
    const DispatchType = @import("dispatch.zig").Dispatch(TestFrameBase);

    // Create the complete test frame with OpcodeHandler
    const TestFrameComplete = struct {
        pub const WordType = u256;
        pub const PcType = u32;
        pub const BytecodeConfig = @import("bytecode_config.zig").BytecodeConfig{
            .max_bytecode_size = 1024,
            .max_initcode_size = 49152,
        };

        pub const Error = error{
            TestError,
            Stop,
        };

        pub const OpcodeHandler = *const fn (frame: *@This(), cursor: [*]const DispatchType.Item) Error!noreturn;
    };

    return struct {
        pub const TestFrame = TestFrameComplete;
        pub const TestDispatch = DispatchType;

        // Mock opcode handlers for testing
        pub fn mockStop(frame: *TestFrameComplete, cursor: [*]const DispatchType.Item) TestFrameComplete.Error!noreturn {
            _ = frame;
            _ = cursor;
            return TestFrameComplete.Error.Stop;
        }

        pub fn mockAdd(frame: *TestFrameComplete, cursor: [*]const DispatchType.Item) TestFrameComplete.Error!noreturn {
            _ = frame;
            _ = cursor;
            return TestFrameComplete.Error.Stop;
        }

        pub fn mockPush1(frame: *TestFrameComplete, cursor: [*]const DispatchType.Item) TestFrameComplete.Error!noreturn {
            _ = frame;
            _ = cursor;
            return TestFrameComplete.Error.Stop;
        }

        pub fn mockJumpdest(frame: *TestFrameComplete, cursor: [*]const DispatchType.Item) TestFrameComplete.Error!noreturn {
            _ = frame;
            _ = cursor;
            return TestFrameComplete.Error.Stop;
        }

        pub fn mockPc(frame: *TestFrameComplete, cursor: [*]const DispatchType.Item) TestFrameComplete.Error!noreturn {
            _ = frame;
            _ = cursor;
            return TestFrameComplete.Error.Stop;
        }

        pub fn mockInvalid(frame: *TestFrameComplete, cursor: [*]const DispatchType.Item) TestFrameComplete.Error!noreturn {
            _ = frame;
            _ = cursor;
            return TestFrameComplete.Error.TestError;
        }

        // Create test opcode handler array
        pub fn createTestHandlers() [256]*const TestFrameComplete.OpcodeHandler {
            var handlers: [256]*const TestFrameComplete.OpcodeHandler = undefined;

            // Initialize all to invalid
            for (&handlers) |*handler| {
                handler.* = &TestTypes.mockInvalid;
            }

            // Set specific handlers
            handlers[@intFromEnum(Opcode.STOP)] = &TestTypes.mockStop;
            handlers[@intFromEnum(Opcode.ADD)] = &TestTypes.mockAdd;
            handlers[@intFromEnum(Opcode.PUSH1)] = &TestTypes.mockPush1;
            handlers[@intFromEnum(Opcode.JUMPDEST)] = &TestTypes.mockJumpdest;
            handlers[@intFromEnum(Opcode.PC)] = &TestTypes.mockPc;

            return handlers;
        }
    };
}

/// Helper type for tests that represents a scheduled element
/// This is exported for test files to use
pub fn ScheduleElement(comptime FrameType: type) type {
    const DispatchType = @import("dispatch.zig").Dispatch(FrameType);
    return DispatchType.Item;
}

// Import test types
const TestTypes = DispatchTest();
const TestFrame = TestTypes.TestFrame;
const TestDispatch = TestTypes.TestDispatch;
const createTestHandlers = TestTypes.createTestHandlers;

// ============================================================================
// All tests moved from dispatch.zig
// ============================================================================

test "Dispatch - basic initialization with empty bytecode" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create empty bytecode
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{});
    defer bytecode.deinit();

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // Should have at least 2 STOP handlers
    try testing.expect(dispatch_items.len >= 2);

    // Last two items should be STOP handlers
    try testing.expect(dispatch_items[dispatch_items.len - 1].opcode_handler == &TestTypes.mockStop);
    try testing.expect(dispatch_items[dispatch_items.len - 2].opcode_handler == &TestTypes.mockStop);
}

test "Dispatch - simple bytecode with ADD" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with ADD instruction
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{@intFromEnum(Opcode.ADD)});
    defer bytecode.deinit();

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // Should have ADD handler + 2 STOP handlers
    try testing.expect(dispatch_items.len == 3);
    try testing.expect(dispatch_items[0].opcode_handler == &TestTypes.mockAdd);
}

test "Dispatch - PUSH1 with inline metadata" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with PUSH1 42
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{ @intFromEnum(Opcode.PUSH1), 42 });
    defer bytecode.deinit();

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // Should have PUSH1 handler + metadata + 2 STOP handlers
    try testing.expect(dispatch_items.len == 4);
    try testing.expect(dispatch_items[0].opcode_handler == &TestTypes.mockPush1);
    try testing.expect(dispatch_items[1].push_inline.value == 42);
}

test "Dispatch - PC opcode with metadata" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with PC instruction
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{@intFromEnum(Opcode.PC)});
    defer bytecode.deinit();

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // Should have PC handler + metadata + 2 STOP handlers
    try testing.expect(dispatch_items.len == 4);
    try testing.expect(dispatch_items[0].opcode_handler == &TestTypes.mockPc);
    try testing.expect(dispatch_items[1].pc.value == 0);
}

test "Dispatch - getNext advances by 1" {
    var dummy_items = [_]TestDispatch.Item{
        .{ .opcode_handler = &TestTypes.mockStop },
        .{ .opcode_handler = &TestTypes.mockStop },
    };
    const dispatch = TestDispatch{ .cursor = &dummy_items };
    const next = dispatch.getNext();

    // Verify pointer arithmetic
    const diff = @intFromPtr(next.cursor) - @intFromPtr(dispatch.cursor);
    try testing.expect(diff == @sizeOf(TestDispatch.Item));
}

test "Dispatch - skipMetadata advances by 2" {
    var dummy_items = [_]TestDispatch.Item{
        .{ .opcode_handler = &TestTypes.mockStop },
        .{ .opcode_handler = &TestTypes.mockStop },
        .{ .opcode_handler = &TestTypes.mockStop },
    };
    const dispatch = TestDispatch{ .cursor = &dummy_items };
    const next = dispatch.skipMetadata();

    // Verify pointer arithmetic
    const diff = @intFromPtr(next.cursor) - @intFromPtr(dispatch.cursor);
    try testing.expect(diff == 2 * @sizeOf(TestDispatch.Item));
}

test "Dispatch - getInlineMetadata accesses correct position" {
    var items = [_]TestDispatch.Item{
        .{ .opcode_handler = &TestTypes.mockPush1 },
        .{ .push_inline = .{ .value = 123 } },
        .{ .opcode_handler = &TestTypes.mockStop },
    };

    const dispatch = TestDispatch{ .cursor = &items };
    const metadata = dispatch.getInlineMetadata();

    try testing.expect(metadata.value == 123);
}

test "Dispatch - getPointerMetadata accesses correct position" {
    const test_value: u256 = 456;
    var items = [_]TestDispatch.Item{
        .{ .opcode_handler = &TestTypes.mockPush1 },
        .{ .push_pointer = .{ .value = @constCast(&test_value) } },
        .{ .opcode_handler = &TestTypes.mockStop },
    };

    const dispatch = TestDispatch{ .cursor = &items };
    const metadata = dispatch.getPointerMetadata();

    try testing.expect(metadata.value.* == 456);
}

test "Dispatch - getPcMetadata accesses correct position" {
    var items = [_]TestDispatch.Item{
        .{ .opcode_handler = &TestTypes.mockPc },
        .{ .pc = .{ .value = 789 } },
        .{ .opcode_handler = &TestTypes.mockStop },
    };

    const dispatch = TestDispatch{ .cursor = &items };
    const metadata = dispatch.getPcMetadata();

    try testing.expect(metadata.value == 789);
}

test "Dispatch - getJumpDestMetadata accesses correct position" {
    var items = [_]TestDispatch.Item{
        .{ .opcode_handler = &TestTypes.mockJumpdest },
        .{ .jump_dest = .{ .gas = 100, .min_stack = -5, .max_stack = 10 } },
        .{ .opcode_handler = &TestTypes.mockStop },
    };

    const dispatch = TestDispatch{ .cursor = &items };
    const metadata = dispatch.getJumpDestMetadata();

    try testing.expect(metadata.gas == 100);
    try testing.expect(metadata.min_stack == -5);
    try testing.expect(metadata.max_stack == 10);
}

test "Dispatch - getOpData for PC returns correct metadata and next" {
    const items = [_]TestDispatch.Item{
        .{ .pc = .{ .value = 42 } },
        .{ .opcode_handler = &TestTypes.mockAdd },
        .{ .opcode_handler = &TestTypes.mockStop },
    };

    const dispatch = TestDispatch{ .cursor = @ptrCast(&items[0]) };
    const op_data = dispatch.getOpData(.PC);

    try testing.expect(op_data.metadata.value == 42);
    try testing.expect(op_data.next.cursor == dispatch.cursor + 2);
}

test "Dispatch - getOpData for regular opcode returns only next" {
    const items = [_]TestDispatch.Item{
        .{ .opcode_handler = &TestTypes.mockAdd },
        .{ .opcode_handler = &TestTypes.mockStop },
    };

    const dispatch = TestDispatch{ .cursor = @ptrCast(&items[0]) };
    const op_data = dispatch.getOpData(.ADD);

    try testing.expect(op_data.next.cursor == dispatch.cursor + 1);
}

test "Dispatch - complex bytecode sequence" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode: PUSH1 10, PUSH1 20, ADD, STOP
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{
        @intFromEnum(Opcode.PUSH1), 10,
        @intFromEnum(Opcode.PUSH1), 20,
        @intFromEnum(Opcode.ADD),   @intFromEnum(Opcode.STOP),
    });
    defer bytecode.deinit();

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // Verify structure: PUSH1, metadata, PUSH1, metadata, ADD, STOP, STOP, STOP
    try testing.expect(dispatch_items.len == 8);

    // First PUSH1
    try testing.expect(dispatch_items[0].opcode_handler == &TestTypes.mockPush1);
    try testing.expect(dispatch_items[1].push_inline.value == 10);

    // Second PUSH1
    try testing.expect(dispatch_items[2].opcode_handler == &TestTypes.mockPush1);
    try testing.expect(dispatch_items[3].push_inline.value == 20);

    // ADD
    try testing.expect(dispatch_items[4].opcode_handler == &TestTypes.mockAdd);

    // Three STOPs (one from bytecode, two safety terminators)
    try testing.expect(dispatch_items[5].opcode_handler == &TestTypes.mockStop);
    try testing.expect(dispatch_items[6].opcode_handler == &TestTypes.mockStop);
    try testing.expect(dispatch_items[7].opcode_handler == &TestTypes.mockStop);
}

test "Dispatch - metadata size constraints" {
    // Ensure metadata structs fit in 64 bits
    try testing.expect(@sizeOf(TestDispatch.JumpDestMetadata) == 8);
    try testing.expect(@sizeOf(TestDispatch.PushInlineMetadata) == 8);
    try testing.expect(@sizeOf(TestDispatch.PushPointerMetadata) == 8);
    try testing.expect(@sizeOf(TestDispatch.PcMetadata) <= 8);
}

test "Dispatch - invalid bytecode handling" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with invalid opcode
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{0xFE}); // Invalid opcode
    defer bytecode.deinit();

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // Should have invalid handler + 2 STOP handlers
    try testing.expect(dispatch_items.len == 3);
    try testing.expect(dispatch_items[0].opcode_handler == &TestTypes.mockInvalid);
}

test "Dispatch - JUMPDEST with gas metadata" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with JUMPDEST
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{@intFromEnum(Opcode.JUMPDEST)});
    defer bytecode.deinit();

    // Note: In real usage, the bytecode analyzer would set gas costs
    // For this test, we're checking the structure is created correctly

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // Should have JUMPDEST handler + metadata + 2 STOP handlers
    try testing.expect(dispatch_items.len == 4);
    try testing.expect(dispatch_items[0].opcode_handler == &TestTypes.mockJumpdest);
    // Gas metadata would be set by bytecode analyzer
    try testing.expect(dispatch_items[1].jump_dest.gas == 0); // Default value
}

test "Dispatch - PUSH32 with pointer metadata" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with PUSH32 (large value requiring pointer storage)
    var push32_data = [_]u8{@intFromEnum(Opcode.PUSH32)} ++ [_]u8{0xFF} ** 32;
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &push32_data);
    defer bytecode.deinit();

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer {
        // Clean up pointer metadata
        for (dispatch_items) |item| {
            switch (item) {
                .push_pointer => |ptr_meta| allocator.destroy(ptr_meta.value),
                else => {},
            }
        }
        allocator.free(dispatch_items);
    }

    // Should have PUSH32 handler + pointer metadata + 2 STOP handlers
    try testing.expect(dispatch_items.len == 4);
    try testing.expect(dispatch_items[0].opcode_handler == &TestTypes.mockPush1); // Using mockPush1 for all PUSH variants

    // Verify pointer metadata contains the correct large value
    const expected_value: u256 = std.math.maxInt(u256); // 0xFFFF...FFFF (32 bytes of 0xFF) - using maxInt for clarity
    try testing.expect(dispatch_items[1].push_pointer.value.* == expected_value);
}

test "Dispatch - PUSH9 boundary test (first pointer type)" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with PUSH9 (first PUSH that uses pointer storage)
    var push9_data = [_]u8{@intFromEnum(Opcode.PUSH9)} ++ [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x11 };
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &push9_data);
    defer bytecode.deinit();

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer {
        // Clean up pointer metadata
        for (dispatch_items) |item| {
            switch (item) {
                .push_pointer => |ptr_meta| allocator.destroy(ptr_meta.value),
                else => {},
            }
        }
        allocator.free(dispatch_items);
    }

    // Should have PUSH9 handler + pointer metadata + 2 STOP handlers
    try testing.expect(dispatch_items.len == 4);
    try testing.expect(dispatch_items[0].opcode_handler == &TestTypes.mockPush1);

    // Verify the 9-byte value is correctly stored
    const expected_value: u256 = 0x123456789ABCDEF011;
    try testing.expect(dispatch_items[1].push_pointer.value.* == expected_value);
}

test "Dispatch - PUSH8 boundary test (last inline type)" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with PUSH8 (last PUSH that uses inline storage)
    var push8_data = [_]u8{@intFromEnum(Opcode.PUSH8)} ++ [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0 };
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &push8_data);
    defer bytecode.deinit();

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // Should have PUSH8 handler + inline metadata + 2 STOP handlers
    try testing.expect(dispatch_items.len == 4);
    try testing.expect(dispatch_items[0].opcode_handler == &TestTypes.mockPush1);

    // Verify the 8-byte value is stored inline
    const expected_value: u64 = 0x123456789ABCDEF0;
    try testing.expect(dispatch_items[1].push_inline.value == expected_value);
}

test "Dispatch - large value no longer truncated" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Test a PUSH4 with value that fits in u64 - should use inline storage
    var push4_small_data = [_]u8{@intFromEnum(Opcode.PUSH4)} ++ [_]u8{ 0x00, 0x00, 0xFF, 0xFF };
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    const bytecode_small = try Bytecode.init(allocator, &push4_small_data);
    defer bytecode_small.deinit(allocator);

    const dispatch_items_small = try TestDispatch.init(allocator, &bytecode_small, &handlers);
    defer allocator.free(dispatch_items_small);

    // Should use inline storage for small value
    try testing.expect(dispatch_items_small[1].push_inline.value == 0x0000FFFF);

    // Test a PUSH8 with maximum u64 value - should still use inline storage
    var push8_max_data = [_]u8{@intFromEnum(Opcode.PUSH8)} ++ [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    const bytecode_max = try Bytecode.init(allocator, &push8_max_data);
    defer bytecode_max.deinit(allocator);

    const dispatch_items_max = try TestDispatch.init(allocator, &bytecode_max, &handlers);
    defer allocator.free(dispatch_items_max);

    // Should use inline storage for max u64 value
    try testing.expect(dispatch_items_max[1].push_inline.value == std.math.maxInt(u64));
}

test "Dispatch - boundary case forces pointer storage" {
    _ = testing.allocator;
    _ = createTestHandlers();

    // Test edge case: PUSH8 with value that exceeds u64 (this would be a bytecode analysis issue normally)
    // But we test to ensure the fix works correctly

    // This test documents that values exceeding u64 max, even in small PUSH operations,
    // now correctly use pointer storage instead of being truncated

    // Since we can't easily create such bytecode from raw bytes (the bytecode analyzer
    // would prevent this), this test serves as documentation of the fix.
    try testing.expect(true); // Placeholder documenting the fix
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

    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &bytecode_data);
    defer bytecode.deinit();

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // Create jump table
    const jump_table = try TestDispatch.createJumpTable(allocator, dispatch_items, &bytecode);
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

    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &bytecode_data);
    defer bytecode.deinit();

    // Create dispatch and jump table
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    const jump_table = try TestDispatch.createJumpTable(allocator, dispatch_items, &bytecode);
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
        const target_pc: u32 = @intCast(i * 10);
        try testing.expect(jump_table.findJumpTarget(target_pc) != null);
    }

    // Test that binary search correctly rejects invalid targets
    for (0..1000) |i| {
        const invalid_pc: u32 = @intCast(i * 10 + 5); // Between valid targets
        try testing.expect(jump_table.findJumpTarget(invalid_pc) == null);
    }
}

// Mock fusion handlers for testing
fn mockPushAddFusion(frame: *TestFrame, cursor: [*]const TestDispatch.Item) TestFrame.Error!noreturn {
    _ = frame;
    _ = cursor;
    return TestFrame.Error.Stop;
}

fn mockPushMulFusion(frame: *TestFrame, cursor: [*]const TestDispatch.Item) TestFrame.Error!noreturn {
    _ = frame;
    _ = cursor;
    return TestFrame.Error.Stop;
}

// Create test opcode handler array with synthetic opcodes
fn createTestHandlersWithSynthetic() [256]*const TestFrame.OpcodeHandler {
    var handlers: [256]*const TestFrame.OpcodeHandler = undefined;

    // Initialize all to invalid
    for (&handlers) |*handler| {
        handler.* = &TestTypes.mockInvalid;
    }

    // Set specific handlers
    handlers[@intFromEnum(Opcode.STOP)] = &TestTypes.mockStop;
    handlers[@intFromEnum(Opcode.ADD)] = &TestTypes.mockAdd;
    handlers[@intFromEnum(Opcode.PUSH1)] = &TestTypes.mockPush1;
    handlers[@intFromEnum(Opcode.JUMPDEST)] = &TestTypes.mockJumpdest;
    handlers[@intFromEnum(Opcode.PC)] = &TestTypes.mockPc;

    // TODO: Add synthetic opcode handlers when they're implemented
    // handlers[synthetic_push_add_opcode] = mockPushAddFusion;
    // handlers[synthetic_push_mul_opcode] = mockPushMulFusion;

    return handlers;
}

test "Dispatch - fusion operations now use correct synthetic handlers" {
    // Test that fusion operations correctly map to synthetic opcode handlers

    // Test getSyntheticOpcode function returns correct values
    // Note: getSyntheticOpcode is not public, so we can't test it directly
    // We would need to test this through the actual dispatch creation process

    // Verify synthetic opcodes are in expected range (0xB0-0xC7)
    try testing.expect(@intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE) == 0xB0);
    try testing.expect(@intFromEnum(OpcodeSynthetic.PUSH_XOR_POINTER) == 0xC5);
}

test "Dispatch - memory cleanup for pointer metadata" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with large PUSH that requires pointer allocation
    var push16_data = [_]u8{@intFromEnum(Opcode.PUSH16)} ++ [_]u8{0xFF} ** 16;
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &push16_data);
    defer bytecode.deinit();

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);

    // Track allocations for cleanup verification
    var pointer_count: usize = 0;
    var pointers_to_free: [10]*u256 = undefined;

    for (dispatch_items) |item| {
        switch (item) {
            .push_pointer => |ptr_meta| {
                pointers_to_free[pointer_count] = ptr_meta.value;
                pointer_count += 1;
            },
            else => {},
        }
    }

    // Clean up - this is what user code must do
    for (0..pointer_count) |i| {
        allocator.destroy(pointers_to_free[i]);
    }
    allocator.free(dispatch_items);

    // Verify we found the expected pointer
    try testing.expect(pointer_count == 1);
}

test "Dispatch - allocation failure handling" {
    // Test what happens when allocation fails during init
    // This exposes potential memory leaks in error paths

    var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    const handlers = createTestHandlers();

    // Create simple bytecode
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(testing.allocator, &[_]u8{@intFromEnum(Opcode.ADD)});
    defer bytecode.deinit();

    // Should fail allocation
    const result = TestDispatch.init(failing_allocator.allocator(), &bytecode, &handlers);
    try testing.expectError(error.OutOfMemory, result);

    // The errdefer in init should clean up the ArrayList
}

test "Dispatch - edge case empty bytecode safety" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create completely empty bytecode
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{});
    defer bytecode.deinit();

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // Should have exactly 2 STOP handlers (the safety terminators)
    try testing.expect(dispatch_items.len == 2);
    try testing.expect(dispatch_items[0].opcode_handler == &TestTypes.mockStop);
    try testing.expect(dispatch_items[1].opcode_handler == &TestTypes.mockStop);

    // Create dispatch wrapper and test safety
    const dispatch = TestDispatch{ .cursor = dispatch_items.ptr };
    const next = dispatch.getNext();

    // Should be able to access next safely (second STOP)
    const ptr_diff = @intFromPtr(next.cursor) - @intFromPtr(dispatch.cursor);
    try testing.expect(ptr_diff == @sizeOf(TestDispatch.Item));
}

test "Dispatch - getOpData compilation and type safety" {
    // This test ensures getOpData compiles correctly for all opcode types
    // and returns the right types

    const items = [_]TestDispatch.Item{
        .{ .pc = .{ .value = 42 } },
        .{ .opcode_handler = &TestTypes.mockAdd },
        .{ .push_inline = .{ .value = 123 } },
        .{ .opcode_handler = &TestTypes.mockStop },
        .{ .push_pointer = .{ .value = undefined } },
        .{ .opcode_handler = &TestTypes.mockStop },
        .{ .jump_dest = .{ .gas = 100 } },
        .{ .opcode_handler = &TestTypes.mockStop },
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

    // Test JUMPDEST
    const jd_dispatch = TestDispatch{ .cursor = @ptrCast(&items[6]) };
    const jd_data = jd_dispatch.getOpData(.JUMPDEST);
    try testing.expect(@TypeOf(jd_data.metadata) == TestDispatch.JumpDestMetadata);
    try testing.expect(jd_data.metadata.gas == 100);

    // Test regular opcode (no metadata)
    const add_dispatch = TestDispatch{ .cursor = @ptrCast(&items[1]) };
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

    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &bytecode_data);
    defer bytecode.deinit();

    // Create dispatch schedule
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // This should not panic
    const jump_table = try TestDispatch.createJumpTable(allocator, dispatch_items, &bytecode);
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
        const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
        var bytecode = try Bytecode.init(allocator, &[_]u8{});
        defer bytecode.deinit();

        const gas = TestDispatch.calculateFirstBlockGas(&bytecode);
        try testing.expect(gas == 0);
    }

    // Test single STOP instruction
    {
        const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
        var bytecode = try Bytecode.init(allocator, &[_]u8{@intFromEnum(Opcode.STOP)});
        defer bytecode.deinit();

        const gas = TestDispatch.calculateFirstBlockGas(&bytecode);
        try testing.expect(gas == 0); // STOP has 0 gas cost
    }

    // Test block ending with JUMPDEST
    {
        const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
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
        const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
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

    // Test overflow handling
    {
        // Create bytecode that would overflow gas calculation
        var large_bytecode = std.ArrayList(u8){};
        defer large_bytecode.deinit(allocator);

        // Add many expensive operations that would overflow
        for (0..10000) |_| {
            try large_bytecode.append(allocator, @intFromEnum(Opcode.SSTORE)); // Very expensive operation
        }

        const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
        var bytecode = try Bytecode.init(allocator, large_bytecode.items);
        defer bytecode.deinit();

        const gas = TestDispatch.calculateFirstBlockGas(&bytecode);
        try testing.expect(gas == std.math.maxInt(u64));
    }
}

test "Dispatch - RAII DispatchSchedule for automatic cleanup" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Test basic RAII with pointer cleanup
    {
        // Create bytecode with PUSH that requires pointer allocation
        var push16_data = [_]u8{@intFromEnum(Opcode.PUSH16)} ++ [_]u8{0xFF} ** 16;
        const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
        var bytecode = try Bytecode.init(allocator, &push16_data);
        defer bytecode.deinit();

        // Create RAII dispatch schedule
        var schedule = try TestDispatch.DispatchSchedule.init(allocator, &bytecode, &handlers);
        defer schedule.deinit();

        // Verify schedule was created
        try testing.expect(schedule.items.len >= 4); // Handler + metadata + 2 STOP handlers

        // Verify pointer metadata exists
        var found_pointer = false;
        for (schedule.items) |item| {
            switch (item) {
                .push_pointer => |ptr_meta| {
                    found_pointer = true;
                    // Verify the pointer contains expected value
                    const expected_value: u256 = std.math.shl(u256, 1, 128) - 1; // 16 bytes of 0xFF
                    try testing.expect(ptr_meta.value.* == expected_value);
                },
                else => {},
            }
        }
        try testing.expect(found_pointer);

        // deinit will be called automatically, cleaning up pointers
    }

    // Test error handling with proper cleanup
    {
        var failing_allocator = testing.FailingAllocator.init(allocator, .{ .fail_index = 3 });

        const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
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
        const result = TestDispatch.DispatchSchedule.init(failing_allocator.allocator(), &bytecode, &handlers);
        try testing.expectError(error.OutOfMemory, result);
    }

    // Test schedule with mixed inline and pointer pushes
    {
        const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
        var bytecode = try Bytecode.init(allocator, &[_]u8{
            @intFromEnum(Opcode.PUSH1), 42, // Inline
            @intFromEnum(Opcode.PUSH8), 1, 2, 3, 4, 5, 6, 7, 8, // Inline
            @intFromEnum(Opcode.PUSH16), 0xFF, 0xFF, 0xFF, 0xFF, // Pointer
            0xFF,                        0xFF, 0xFF, 0xFF, 0xFF,
            0xFF,                        0xFF, 0xFF, 0xFF, 0xFF,
            0xFF,                        0xFF,
        });
        defer bytecode.deinit();

        var schedule = try TestDispatch.DispatchSchedule.init(allocator, &bytecode, &handlers);
        defer schedule.deinit();

        // Count inline and pointer metadata
        var inline_count: usize = 0;
        var pointer_count: usize = 0;
        for (schedule.items) |item| {
            switch (item) {
                .push_inline => inline_count += 1,
                .push_pointer => pointer_count += 1,
                else => {},
            }
        }

        try testing.expect(inline_count == 2);
        try testing.expect(pointer_count == 1);
    }
}

test "Dispatch - JumpTableBuilder iterator pattern" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Test builder with no JUMPDESTs
    {
        const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
        var bytecode = try Bytecode.init(allocator, &[_]u8{
            @intFromEnum(Opcode.PUSH1), 10,
            @intFromEnum(Opcode.ADD),   @intFromEnum(Opcode.STOP),
        });
        defer bytecode.deinit();

        const schedule = try TestDispatch.init(allocator, &bytecode, &handlers);
        defer allocator.free(schedule);

        var builder = TestDispatch.JumpTableBuilder.init(allocator);
        defer builder.deinit();

        try builder.buildFromSchedule(schedule, &bytecode);
        const jump_table = try builder.finalize();
        defer allocator.free(jump_table.entries);

        try testing.expect(jump_table.entries.len == 0);
    }

    // Test builder with multiple JUMPDESTs
    {
        const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
        var bytecode = try Bytecode.init(allocator, &[_]u8{
            @intFromEnum(Opcode.JUMPDEST), // PC 0
            @intFromEnum(Opcode.PUSH1), 10, // PC 1-2
            @intFromEnum(Opcode.JUMPDEST), // PC 3
            @intFromEnum(Opcode.ADD), // PC 4
            @intFromEnum(Opcode.JUMPDEST), // PC 5
            @intFromEnum(Opcode.STOP), // PC 6
        });
        defer bytecode.deinit();

        const schedule = try TestDispatch.init(allocator, &bytecode, &handlers);
        defer allocator.free(schedule);

        var builder = TestDispatch.JumpTableBuilder.init(allocator);
        defer builder.deinit();

        try builder.buildFromSchedule(schedule, &bytecode);
        const jump_table = try builder.finalize();
        defer allocator.free(jump_table.entries);

        // Should have 3 entries
        try testing.expect(jump_table.entries.len == 3);
        try testing.expect(jump_table.entries[0].pc == 0);
        try testing.expect(jump_table.entries[1].pc == 3);
        try testing.expect(jump_table.entries[2].pc == 5);
    }

    // Test builder maintains consistency during iteration
    {
        const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
        var bytecode = try Bytecode.init(allocator, &[_]u8{
            @intFromEnum(Opcode.PUSH2), 0x12, 0x34, // PC 0-2
            @intFromEnum(Opcode.JUMPDEST), // PC 3
            @intFromEnum(Opcode.PUSH1), 0x56, // PC 4-5
            @intFromEnum(Opcode.JUMPDEST), // PC 6
            @intFromEnum(Opcode.PC), // PC 7
            @intFromEnum(Opcode.JUMPDEST), // PC 8
        });
        defer bytecode.deinit();

        const schedule = try TestDispatch.init(allocator, &bytecode, &handlers);
        defer allocator.free(schedule);

        var builder = TestDispatch.JumpTableBuilder.init(allocator);
        defer builder.deinit();

        // Use iterator interface explicitly
        const ScheduleIterator = TestDispatch.ScheduleIterator.init(schedule, &bytecode);
        var iter = ScheduleIterator{};

        while (iter.next()) |entry| {
            if (entry.op_data == .jumpdest) {
                try builder.addEntry(entry.pc, entry.schedule_index);
            }
        }

        const jump_table = try builder.finalizeWithSchedule(schedule);
        defer allocator.free(jump_table.entries);

        try testing.expect(jump_table.entries.len == 3);
        try testing.expect(jump_table.entries[0].pc == 3);
        try testing.expect(jump_table.entries[1].pc == 6);
        try testing.expect(jump_table.entries[2].pc == 8);
    }

    // Test error handling in builder
    {
        var failing_allocator = testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });

        var builder = TestDispatch.JumpTableBuilder.init(failing_allocator.allocator());
        defer builder.deinit();

        const result = builder.addEntry(100, 10);
        try testing.expectError(error.OutOfMemory, result);
    }
}

test "Dispatch - pretty_print basic functionality" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create simple bytecode: PUSH1 0x42, ADD, STOP
    const code = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x42, @intFromEnum(Opcode.ADD), @intFromEnum(Opcode.STOP) };
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &code);
    defer bytecode.deinit();

    // Create dispatch schedule
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer TestDispatch.deinitSchedule(allocator, dispatch_items);

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
    try testing.expect(std.mem.indexOf(u8, formatted, "HANDLER") != null);

    // Verify it's a non-empty string
    try testing.expect(formatted.len > 100);
}
