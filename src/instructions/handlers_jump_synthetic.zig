const std = @import("std");
const FrameConfig = @import("../frame/frame_config.zig").FrameConfig;
const log = @import("../log.zig");
const OpcodeSynthetic = @import("../opcodes/opcode_synthetic.zig").OpcodeSynthetic;

/// Synthetic jump opcode handlers for the EVM stack frame.
/// These handle statically optimized jump operations.
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
            // Call the handler at that location, passing cursor pointing to the handler itself
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
            // Continue to next instruction - advance past metadata
            return @call(FrameType.getTailCallModifier(), cursor[1].opcode_handler, .{ self, cursor + 2 });
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
                return @call(FrameType.getTailCallModifier(), jump_dispatch.cursor[0].opcode_handler, .{ self, jump_dispatch.cursor + 1 });
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
                return @call(FrameType.getTailCallModifier(), jump_dispatch.cursor[0].opcode_handler, .{ self, jump_dispatch.cursor + 1 });
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
                    return @call(FrameType.getTailCallModifier(), jump_dispatch.cursor[0].opcode_handler, .{ self, jump_dispatch.cursor + 1 });
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
                    return @call(FrameType.getTailCallModifier(), jump_dispatch.cursor[0].opcode_handler, .{ self, jump_dispatch.cursor + 1 });
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

test "jump_to_static_location - performance comparison" {
    // This test demonstrates the benefit of jump_to_static_location
    // by avoiding the binary search in findJumpTarget, jumping directly
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

