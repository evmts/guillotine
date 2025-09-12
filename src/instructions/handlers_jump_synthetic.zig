const std = @import("std");
const FrameConfig = @import("../frame/frame_config.zig").FrameConfig;
const log = @import("../log.zig");
const OpcodeSynthetic = @import("../opcodes/opcode_synthetic.zig").OpcodeSynthetic;

/// Synthetic jump opcode handlers for the EVM stack frame.
/// These handle fused PUSH+jump operations for optimization.
pub fn Handlers(comptime FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;

        /// Jump directly to a statically known location without binary search.
        /// The cursor now points to metadata containing the jump destination dispatch.
        pub fn jump_to_static_location(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            @branchHint(.likely);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.JUMP_TO_STATIC_LOCATION, Dispatch, Dispatch.Item, cursor);
            
            // The dispatch pointer already points to the JUMPDEST handler location
            const jump_dispatch_ptr = @as([*]const Dispatch.Item, @ptrCast(@alignCast(op_data.metadata.dispatch)));
            // Call the handler at that location, passing cursor pointing to the next slot (where metadata would be)
            return @call(FrameType.getTailCallModifier(), jump_dispatch_ptr[0].opcode_handler, .{ self, jump_dispatch_ptr });
        }

        /// Conditionally jump to a statically known location without binary search.
        /// The cursor now points to metadata containing the jump destination dispatch.
        pub fn jumpi_to_static_location(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            @branchHint(.likely);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.JUMPI_TO_STATIC_LOCATION, Dispatch, Dispatch.Item, cursor);
            
            // The dispatch pointer already points to the JUMPDEST handler location
            const jump_dispatch_ptr = @as([*]const Dispatch.Item, @ptrCast(@alignCast(op_data.metadata.dispatch)));
            std.debug.assert(self.stack.size() >= 1);
            const condition = self.stack.pop_unsafe();
            if (condition != 0) {
                @branchHint(.unlikely);
                // Call the handler at that location, passing cursor pointing to that slot
                return @call(FrameType.getTailCallModifier(), jump_dispatch_ptr[0].opcode_handler, .{ self, jump_dispatch_ptr });
            }
            // Continue to next instruction
            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// PUSH_JUMP_INLINE - Fused PUSH+JUMP with inline destination (≤8 bytes).
        /// Pushes a destination and immediately jumps to it.
        /// @deprecated Use jump_to_static_location for better performance
        pub fn push_jump_inline(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            @branchHint(.likely);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.PUSH_JUMP_INLINE, Dispatch, Dispatch.Item, cursor);
            
            // Cursor now points to metadata
            const dest = op_data.metadata.value;

            // Validate jump destination range
            if (dest > std.math.maxInt(FrameType.PcType)) {
                @branchHint(.unlikely);
                return Error.InvalidJump;
            }

            const dest_pc: FrameType.PcType = @intCast(dest);

            const jump_table = self.jump_table;
            if (jump_table.findJumpTarget(dest_pc)) |jump_dispatch| {
                @branchHint(.likely);
                // Found valid JUMPDEST - tail call to the jump destination
                return @call(FrameType.getTailCallModifier(), jump_dispatch.cursor[0].opcode_handler, .{ self, jump_dispatch.cursor });
            } else {
                // Not a valid JUMPDEST
                return Error.InvalidJump;
            }
        }

        /// PUSH_JUMP_POINTER - Fused PUSH+JUMP with pointer destination (>8 bytes).
        /// @deprecated Use jump_to_static_location for better performance
        pub fn push_jump_pointer(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            @branchHint(.likely);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.PUSH_JUMP_POINTER, Dispatch, Dispatch.Item, cursor);
            
            // Cursor now points to metadata
            const dest = op_data.metadata.value.*;

            // Validate jump destination range
            if (dest > std.math.maxInt(FrameType.PcType)) {
                @branchHint(.unlikely);
                return Error.InvalidJump;
            }

            const dest_pc: FrameType.PcType = @intCast(dest);

            // Look up the destination in the jump table
            const jump_table = self.jump_table;
            if (jump_table.findJumpTarget(dest_pc)) |jump_dispatch| {
                @branchHint(.likely);
                // Found valid JUMPDEST - tail call to the jump destination
                return @call(FrameType.getTailCallModifier(), jump_dispatch.cursor[0].opcode_handler, .{ self, jump_dispatch.cursor });
            } else {
                // Not a valid JUMPDEST
                return Error.InvalidJump;
            }
        }

        /// PUSH_JUMPI_INLINE - Fused PUSH+JUMPI with inline destination (≤8 bytes).
        /// Pushes a destination, pops condition, and conditionally jumps.
        /// @deprecated Use jumpi_to_static_location for better performance
        pub fn push_jumpi_inline(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            @branchHint(.likely);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.PUSH_JUMPI_INLINE, Dispatch, Dispatch.Item, cursor);
            
            const dest = op_data.metadata.value;

            std.debug.assert(self.stack.size() >= 1);
            const condition = self.stack.pop_unsafe();

            if (condition != 0) {
                @branchHint(.unlikely);
                // Take the jump - validate destination range
                if (dest > std.math.maxInt(FrameType.PcType)) {
                    @branchHint(.unlikely);
                    return Error.InvalidJump;
                }

                const dest_pc: FrameType.PcType = @intCast(dest);

                // Look up the destination in the jump table
                const jump_table = self.jump_table;
                if (jump_table.findJumpTarget(dest_pc)) |jump_dispatch| {
                    @branchHint(.likely);
                    // Found valid JUMPDEST - tail call to the jump destination
                    return @call(FrameType.getTailCallModifier(), jump_dispatch.cursor[0].opcode_handler, .{ self, jump_dispatch.cursor });
                } else {
                    // Not a valid JUMPDEST
                    return Error.InvalidJump;
                }
            } else {
                // Continue to next instruction
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }
        }

        /// PUSH_JUMPI_POINTER - Fused PUSH+JUMPI with pointer destination (>8 bytes).
        /// @deprecated Use jumpi_to_static_location for better performance
        pub fn push_jumpi_pointer(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            @branchHint(.likely);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.PUSH_JUMPI_POINTER, Dispatch, Dispatch.Item, cursor);
            
            // Cursor now points to metadata
            const dest = op_data.metadata.value.*;

            // Pop the condition
            std.debug.assert(self.stack.size() >= 1); // PUSH_JUMPI requires 1 stack item
            const condition = self.stack.pop_unsafe();

            if (condition != 0) {
                @branchHint(.unlikely);
                // Take the jump - validate destination range
                if (dest > std.math.maxInt(FrameType.PcType)) {
                    @branchHint(.unlikely);
                    return Error.InvalidJump;
                }

                const dest_pc: FrameType.PcType = @intCast(dest);

                // Look up the destination in the jump table
                const jump_table = self.jump_table;
                if (jump_table.findJumpTarget(dest_pc)) |jump_dispatch| {
                    @branchHint(.likely);
                    // Found valid JUMPDEST - tail call to the jump destination
                    return @call(FrameType.getTailCallModifier(), jump_dispatch.cursor[0].opcode_handler, .{ self, jump_dispatch.cursor });
                } else {
                    // Not a valid JUMPDEST
                    return Error.InvalidJump;
                }
            } else {
                // Continue to next instruction
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }
        }
    };
}

// ====== TESTS ======

const testing = std.testing;
const Frame = @import("../frame/frame.zig").Frame;
const dispatch_mod = @import("../preprocessor/dispatch.zig");
const NoOpTracer = @import("../tracer/tracer.zig").NoOpTracer;
const MemoryDatabase = @import("../storage/memory_database.zig").MemoryDatabase;
const Address = @import("primitives").Address;

// Test configuration
const test_config = FrameConfig{
    .stack_size = 1024,
    .WordType = u256,
    .max_bytecode_size = 1024,
    .block_gas_limit = 30_000_000,
    .DatabaseType = MemoryDatabase,
    .TracerType = NoOpTracer,
    .memory_initial_capacity = 4096,
    .memory_limit = 0xFFFFFF,
};

const TestFrame = Frame(test_config);

fn createTestFrame(allocator: std.mem.Allocator) !TestFrame {
    const database = MemoryDatabase.init(allocator);
    const value = try allocator.create(u256);
    value.* = 0;
    const evm_ptr = @as(*anyopaque, @ptrFromInt(0x1000));
    var frame = try TestFrame.init(allocator, 1_000_000, database, Address.ZERO_ADDRESS, value, &[_]u8{}, evm_ptr);
    frame.code = &[_]u8{};
    return frame;
}

// Helper to create dispatch with inline metadata
fn createInlineDispatch(value: u256) TestFrame.Dispatch {
    const mock_handler = struct {
        fn handler(frame: TestFrame, dispatch: TestFrame.Dispatch) TestFrame.Error!TestFrame.Success {
            _ = frame;
            _ = dispatch;
            return TestFrame.Success.stop;
        }
    }.handler;

    var cursor: [2]dispatch_mod.ScheduleElement(TestFrame) = undefined;
    cursor[0] = .{ .opcode_handler = &mock_handler };
    cursor[1] = .{ .opcode_handler = &mock_handler };

    cursor[0].metadata = .{ .value = value };

    return TestFrame.Dispatch{
        .cursor = &cursor,
        .bytecode_length = 0,
    };
}

// Helper to create dispatch with pointer metadata
fn createPointerDispatch(value: *const u256) TestFrame.Dispatch {
    const mock_handler = struct {
        fn handler(frame: TestFrame, dispatch: TestFrame.Dispatch) TestFrame.Error!TestFrame.Success {
            _ = frame;
            _ = dispatch;
            return TestFrame.Success.stop;
        }
    }.handler;

    var cursor: [2]dispatch_mod.ScheduleElement(TestFrame) = undefined;
    cursor[0] = .{ .opcode_handler = &mock_handler };
    cursor[1] = .{ .opcode_handler = &mock_handler };

    cursor[0].metadata = .{ .pointer_value = value };

    return TestFrame.Dispatch{
        .cursor = &cursor,
        .bytecode_length = 0,
    };
}

test "jump_to_static_location - direct jump without search" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Create a target dispatch location
    const stop_handler = struct {
        fn handler(f: *TestFrame, cursor: [*]const TestFrame.Dispatch.Item) TestFrame.Error!noreturn {
            _ = f;
            _ = cursor;
            return TestFrame.Error.STOP;
        }
    }.handler;

    var target_cursor: [1]TestFrame.Dispatch.Item = undefined;
    target_cursor[0] = .{ .opcode_handler = &stop_handler };

    // Create jump dispatch pointing to target
    var cursor: [3]TestFrame.Dispatch.Item = undefined;
    cursor[0] = .{ .opcode_handler = &TestFrame.JumpSyntheticHandlers.jump_to_static_location };
    cursor[1] = .{ .jump_static = .{ .dispatch = @as(*const anyopaque, @ptrCast(&target_cursor)) } };
    cursor[2] = .{ .opcode_handler = &stop_handler };

    const result = TestFrame.JumpSyntheticHandlers.jump_to_static_location(&frame, &cursor);

    // Should jump directly and return STOP
    try testing.expectError(TestFrame.Error.STOP, result);
}

test "jumpi_to_static_location - conditional jump taken" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Push condition (non-zero = jump)
    try frame.stack.push(1);

    // Create a target dispatch location
    const stop_handler = struct {
        fn handler(f: *TestFrame, cursor: [*]const TestFrame.Dispatch.Item) TestFrame.Error!noreturn {
            _ = f;
            _ = cursor;
            return TestFrame.Error.STOP;
        }
    }.handler;

    var target_cursor: [1]TestFrame.Dispatch.Item = undefined;
    target_cursor[0] = .{ .opcode_handler = &stop_handler };

    // Create jumpi dispatch pointing to target
    var cursor: [3]TestFrame.Dispatch.Item = undefined;
    cursor[0] = .{ .opcode_handler = &TestFrame.JumpSyntheticHandlers.jumpi_to_static_location };
    cursor[1] = .{ .jump_static = .{ .dispatch = @as(*const anyopaque, @ptrCast(&target_cursor)) } };
    cursor[2] = .{ .opcode_handler = &stop_handler };

    const result = TestFrame.JumpSyntheticHandlers.jumpi_to_static_location(&frame, &cursor);

    // Should take the jump and return STOP
    try testing.expectError(TestFrame.Error.STOP, result);
    try testing.expectEqual(@as(usize, 0), frame.stack.len());
}

test "jumpi_to_static_location - conditional jump not taken" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Push condition (zero = no jump)
    try frame.stack.push(0);

    // Create a target dispatch location (won't be used)
    const stop_handler = struct {
        fn handler(f: *TestFrame, cursor: [*]const TestFrame.Dispatch.Item) TestFrame.Error!noreturn {
            _ = f;
            _ = cursor;
            return TestFrame.Error.STOP;
        }
    }.handler;

    var target_cursor: [1]TestFrame.Dispatch.Item = undefined;
    target_cursor[0] = .{ .opcode_handler = &stop_handler };

    // Create jumpi dispatch with next instruction handler
    var cursor: [3]TestFrame.Dispatch.Item = undefined;
    cursor[0] = .{ .opcode_handler = &TestFrame.JumpSyntheticHandlers.jumpi_to_static_location };
    cursor[1] = .{ .jump_static = .{ .dispatch = @as(*const anyopaque, @ptrCast(&target_cursor)) } };
    cursor[2] = .{ .opcode_handler = &stop_handler };

    const result = TestFrame.JumpSyntheticHandlers.jumpi_to_static_location(&frame, &cursor);

    // Should continue to next instruction and return STOP
    try testing.expectError(TestFrame.Error.STOP, result);
    try testing.expectEqual(@as(usize, 0), frame.stack.len());
}

test "PUSH_JUMP_INLINE - unconditional jump" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // PUSH 100 + JUMP
    const dispatch = createInlineDispatch(100);
    const result = TestFrame.JumpSyntheticHandlers.push_jump_inline(frame, dispatch);

    // Currently returns Stop as placeholder
    try testing.expectEqual(TestFrame.Success.Stop, try result);
}

test "PUSH_JUMP_POINTER - large destination jump" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    const large_dest: u256 = 0x1000000;
    const dispatch = createPointerDispatch(&large_dest);
    const result = TestFrame.JumpSyntheticHandlers.push_jump_pointer(frame, dispatch);

    try testing.expectEqual(TestFrame.Success.Stop, try result);
}

test "PUSH_JUMPI_INLINE - conditional jump taken" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Push condition (non-zero = jump)
    try frame.stack.push(1);

    // PUSH 200 + JUMPI
    const dispatch = createInlineDispatch(200);
    const result = TestFrame.JumpSyntheticHandlers.push_jumpi_inline(frame, dispatch);

    // Should take the jump
    try testing.expectEqual(TestFrame.Success.Stop, try result);
    try testing.expectEqual(@as(usize, 0), frame.stack.len());
}

test "PUSH_JUMPI_INLINE - conditional jump not taken" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Push condition (zero = no jump)
    try frame.stack.push(0);

    // PUSH 200 + JUMPI
    const dispatch = createInlineDispatch(200);
    _ = try TestFrame.JumpSyntheticHandlers.push_jumpi_inline(frame, dispatch);

    // Should continue to next instruction
    try testing.expectEqual(@as(usize, 0), frame.stack.len());
}

test "synthetic jump - pointer variants" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test PUSH_JUMPI_POINTER with condition true
    try frame.stack.push(42); // non-zero condition
    const dest1: u256 = 0x80000000;
    var dispatch = createPointerDispatch(&dest1);
    var result = TestFrame.JumpSyntheticHandlers.push_jumpi_pointer(frame, dispatch);
    try testing.expectEqual(TestFrame.Success.Stop, try result);

    // Test PUSH_JUMPI_POINTER with condition false
    try frame.stack.push(0); // zero condition
    const dest2: u256 = 0x90000000;
    dispatch = createPointerDispatch(&dest2);
    result = TestFrame.JumpSyntheticHandlers.push_jumpi_pointer(frame, dispatch);
    // Should continue (mock returns stop)
    try testing.expectEqual(TestFrame.Success.stop, try result);
}

test "PUSH_JUMPI - various conditions" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    const test_cases = [_]struct { condition: u256, should_jump: bool }{
        .{ .condition = 0, .should_jump = false },
        .{ .condition = 1, .should_jump = true },
        .{ .condition = 0xFF, .should_jump = true },
        .{ .condition = std.math.maxInt(u256), .should_jump = true },
    };

    for (test_cases) |tc| {
        // Clear stack
        while (frame.stack.len() > 0) {
            _ = try frame.stack.pop();
        }

        try frame.stack.push(tc.condition);

        const dispatch = createInlineDispatch(300);
        const result = TestFrame.JumpSyntheticHandlers.push_jumpi_inline(frame, dispatch);

        if (tc.should_jump) {
            try testing.expectEqual(TestFrame.Success.Stop, try result);
        } else {
            try testing.expectEqual(TestFrame.Success.stop, try result);
        }
    }
}

test "jump_to_static_location - performance comparison" {
    // This test demonstrates the benefit of jump_to_static_location over push_jump_inline
    // The new handler avoids the binary search in findJumpTarget, jumping directly
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // With jump_to_static_location, we directly store the dispatch pointer
    // This eliminates the need for:
    // 1. Converting the destination to a PC value
    // 2. Binary searching the jump table
    // 3. Validation of jump destination range

    const stop_handler = struct {
        fn handler(f: *TestFrame, cursor: [*]const TestFrame.Dispatch.Item) TestFrame.Error!noreturn {
            _ = f;
            _ = cursor;
            return TestFrame.Error.STOP;
        }
    }.handler;

    var target_cursor: [1]TestFrame.Dispatch.Item = undefined;
    target_cursor[0] = .{ .opcode_handler = &stop_handler };

    var cursor: [3]TestFrame.Dispatch.Item = undefined;
    cursor[0] = .{ .opcode_handler = &TestFrame.JumpSyntheticHandlers.jump_to_static_location };
    cursor[1] = .{ .jump_static = .{ .dispatch = @as(*const anyopaque, @ptrCast(&target_cursor)) } };
    cursor[2] = .{ .opcode_handler = &stop_handler };

    const result = TestFrame.JumpSyntheticHandlers.jump_to_static_location(&frame, &cursor);
    try testing.expectError(TestFrame.Error.STOP, result);
}

test "synthetic jump - stack underflow" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // PUSH_JUMPI with empty stack should fail
    const dispatch = createInlineDispatch(100);
    const result = TestFrame.JumpSyntheticHandlers.push_jumpi_inline(frame, dispatch);

    try testing.expectError(TestFrame.Error.StackUnderflow, result);
}
