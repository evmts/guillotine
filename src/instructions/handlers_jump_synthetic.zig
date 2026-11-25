const std = @import("std");
const FrameConfig = @import("../frame/frame_config.zig").FrameConfig;
const log = @import("../log.zig");
const OpcodeSynthetic = @import("../opcodes/opcode_synthetic.zig").OpcodeSynthetic;
const jump_handlers = @import("handlers_jump.zig");

/// Synthetic jump opcode handlers for the EVM stack frame.
/// These handle statically optimized jump operations.
pub fn Handlers(FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;
        const handler_abi = @import("../preprocessor/handler_abi.zig");
        const N = handler_abi.Native(FrameType);

        /// The schedule cursor stored in a jump_static metadata item.
        inline fn staticTarget(item: Dispatch.Item) [*]const Dispatch.Item {
            return @ptrCast(@alignCast(item.jump_static.dispatch));
        }

        /// Jump directly to a statically known location without a jump table lookup.
        /// The cursor points to: [0] = handler, [1] = jump_static metadata.
        pub fn jump_to_static_location(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
            N.before(self, .JUMP_TO_STATIC_LOCATION, cursor, sp, gas);
            return N.jump(self, .JUMP_TO_STATIC_LOCATION, staticTarget(cursor[1]), sp, gas);
        }

        /// Conditionally jump to a statically known location without a jump table lookup.
        /// The cursor points to: [0] = handler, [1] = jump_static metadata.
        pub fn jumpi_to_static_location(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
            N.before(self, .JUMPI_TO_STATIC_LOCATION, cursor, sp, gas);
            var s = N.StackView{ .sp = sp };
            const condition = s.pop_unsafe();
            if (condition != 0) return N.jump(self, .JUMPI_TO_STATIC_LOCATION, staticTarget(cursor[1]), s.sp, gas);
            return N.next(self, .JUMPI_TO_STATIC_LOCATION, cursor, s.sp, gas);
        }

        /// BACKWARD_LOOP_JUMPI - Optimized backward loop with branch prediction for loops.
        /// The cursor points to: [0] = handler, [1] = loop target, [2] = exit target.
        /// A zero condition continues the loop (the hot path); non-zero exits it.
        pub fn backward_loop_jumpi(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
            N.before(self, .BACKWARD_LOOP_JUMPI, cursor, sp, gas);
            var s = N.StackView{ .sp = sp };
            const condition = s.pop_unsafe();
            if (condition == 0) {
                @branchHint(.likely);
                return N.jump(self, .BACKWARD_LOOP_JUMPI, staticTarget(cursor[1]), s.sp, gas);
            }
            return N.jump(self, .BACKWARD_LOOP_JUMPI, staticTarget(cursor[2]), s.sp, gas);
        }

        /// INVALID_JUMP_TARGET - where a static jump to a non-JUMPDEST lands. Invalid
        /// targets in unreachable code are legal, so preprocessing points such jumps here
        /// and the error surfaces only when the jump is taken. It maps to no bytecode
        /// instruction: the jump handler already stepped MinimalEvm through the failed JUMP.
        pub fn invalid_jump_target(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
            _ = cursor;
            return N.exit(self, .INVALID_JUMP_TARGET, sp, gas, .invalid_jump);
        }

        /// BLOCK_BEGIN - start of a basic block reached by falling through a non-taken JUMPI
        /// or a gas-observing instruction. It maps to no bytecode instruction. Like JUMPDEST
        /// it charges the block's static gas and validates the block's stack bounds in one
        /// shot, but it charges no gas of its own.
        pub fn block_begin(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
            return jump_handlers.Handlers(FrameType).enterBlock(self, .BLOCK_BEGIN, cursor, sp, gas);
        }
    };
}

// ====== TESTS ======

const testing = std.testing;
const Frame = @import("../frame/frame.zig").Frame;
const dispatch_mod = @import("../preprocessor/dispatch.zig");
const NoOpTracer = @import("../tracer/tracer.zig").NoOpTracer;
const MemoryDatabase = @import("../storage/memory_database.zig").MemoryDatabase;
const Address = @import("voltaire").Address;

// Test configuration
const test_config = FrameConfig{
    .stack_size = 1024,
    .WordType = u256,
    .max_bytecode_size = 1024,
    .block_gas_limit = 30_000_000,
    .DatabaseType = MemoryDatabase,
    .TracerType = null,
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

test "backward_loop_jumpi - continue loop (condition == 0)" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Push condition 0 (continue loop)
    try frame.stack.push(0);

    // Create loop and exit dispatch locations
    const loop_handler = struct {
        fn handler(f: *TestFrame, cursor: [*]const TestFrame.Dispatch.Item) TestFrame.Error!noreturn {
            _ = f;
            _ = cursor;
            return TestFrame.Error.STOP; // Use STOP as a marker for loop continuation
        }
    }.handler;

    const exit_handler = struct {
        fn handler(f: *TestFrame, cursor: [*]const TestFrame.Dispatch.Item) TestFrame.Error!noreturn {
            _ = f;
            _ = cursor;
            return TestFrame.Error.InvalidJump; // Use a different error as marker for exit
        }
    }.handler;

    var loop_cursor: [1]TestFrame.Dispatch.Item = undefined;
    loop_cursor[0] = .{ .opcode_handler = &loop_handler };

    var exit_cursor: [1]TestFrame.Dispatch.Item = undefined;
    exit_cursor[0] = .{ .opcode_handler = &exit_handler };

    // Create backward_loop_jumpi dispatch: [handler, loop_dispatch, exit_dispatch, next]
    var cursor: [4]TestFrame.Dispatch.Item = undefined;
    cursor[0] = .{ .opcode_handler = &TestFrame.JumpSyntheticHandlers.backward_loop_jumpi };
    cursor[1] = .{ .jump_static = .{ .dispatch = @as(*const anyopaque, @ptrCast(&loop_cursor)) } };
    cursor[2] = .{ .jump_static = .{ .dispatch = @as(*const anyopaque, @ptrCast(&exit_cursor)) } };
    cursor[3] = .{ .opcode_handler = &exit_handler };

    const result = TestFrame.JumpSyntheticHandlers.backward_loop_jumpi(&frame, &cursor);

    // With condition 0, should go to loop target and return STOP
    try testing.expectError(TestFrame.Error.STOP, result);
    try testing.expectEqual(@as(usize, 0), frame.stack.len());
}

test "backward_loop_jumpi - exit loop (condition != 0)" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Push non-zero condition (exit loop)
    try frame.stack.push(1);

    // Create loop and exit dispatch locations
    const loop_handler = struct {
        fn handler(f: *TestFrame, cursor: [*]const TestFrame.Dispatch.Item) TestFrame.Error!noreturn {
            _ = f;
            _ = cursor;
            return TestFrame.Error.STOP; // Marker for loop continuation
        }
    }.handler;

    const exit_handler = struct {
        fn handler(f: *TestFrame, cursor: [*]const TestFrame.Dispatch.Item) TestFrame.Error!noreturn {
            _ = f;
            _ = cursor;
            return TestFrame.Error.InvalidJump; // Marker for exit
        }
    }.handler;

    var loop_cursor: [1]TestFrame.Dispatch.Item = undefined;
    loop_cursor[0] = .{ .opcode_handler = &loop_handler };

    var exit_cursor: [1]TestFrame.Dispatch.Item = undefined;
    exit_cursor[0] = .{ .opcode_handler = &exit_handler };

    // Create backward_loop_jumpi dispatch: [handler, loop_dispatch, exit_dispatch, next]
    var cursor: [4]TestFrame.Dispatch.Item = undefined;
    cursor[0] = .{ .opcode_handler = &TestFrame.JumpSyntheticHandlers.backward_loop_jumpi };
    cursor[1] = .{ .jump_static = .{ .dispatch = @as(*const anyopaque, @ptrCast(&loop_cursor)) } };
    cursor[2] = .{ .jump_static = .{ .dispatch = @as(*const anyopaque, @ptrCast(&exit_cursor)) } };
    cursor[3] = .{ .opcode_handler = &exit_handler };

    const result = TestFrame.JumpSyntheticHandlers.backward_loop_jumpi(&frame, &cursor);

    // With non-zero condition, should go to exit target and return InvalidJump
    try testing.expectError(TestFrame.Error.InvalidJump, result);
    try testing.expectEqual(@as(usize, 0), frame.stack.len());
}
