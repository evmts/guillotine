const std = @import("std");
const bytecode_mod = @import("bytecode.zig");
const Opcode = @import("opcode_data.zig").Opcode;
const testing = std.testing;

/// Test infrastructure for dispatch operations
/// Creates test types and helper functions
pub fn DispatchTest() type {
    // Define test frame first
    const TestFrameBase = struct {
        pub const WordType = u256;
        pub const PcType = u32;
        pub const BytecodeConfig = bytecode_mod.BytecodeConfig{
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
        pub const BytecodeConfig = bytecode_mod.BytecodeConfig{
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
        pub fn mockStop(frame: *TestFrame, cursor: [*]const TestDispatch.Item) TestFrame.Error!noreturn {
            _ = frame;
            _ = cursor;
            return TestFrame.Error.Stop;
        }

        pub fn mockAdd(frame: *TestFrame, cursor: [*]const TestDispatch.Item) TestFrame.Error!noreturn {
            _ = frame;
            _ = cursor;
            return TestFrame.Error.Stop;
        }

        pub fn mockPush1(frame: *TestFrame, cursor: [*]const TestDispatch.Item) TestFrame.Error!noreturn {
            _ = frame;
            _ = cursor;
            return TestFrame.Error.Stop;
        }

        pub fn mockJumpdest(frame: *TestFrame, cursor: [*]const TestDispatch.Item) TestFrame.Error!noreturn {
            _ = frame;
            _ = cursor;
            return TestFrame.Error.Stop;
        }

        pub fn mockPc(frame: *TestFrame, cursor: [*]const TestDispatch.Item) TestFrame.Error!noreturn {
            _ = frame;
            _ = cursor;
            return TestFrame.Error.Stop;
        }

        pub fn mockInvalid(frame: *TestFrame, cursor: [*]const TestDispatch.Item) TestFrame.Error!noreturn {
            _ = frame;
            _ = cursor;
            return TestFrame.Error.TestError;
        }

        // Create test opcode handler array
        pub fn createTestHandlers() [256]*const TestFrame.OpcodeHandler {
            var handlers: [256]*const TestFrame.OpcodeHandler = undefined;

            // Initialize all to invalid
            for (&handlers) |*handler| {
                handler.* = mockInvalid;
            }

            // Set specific handlers
            handlers[@intFromEnum(Opcode.STOP)] = mockStop;
            handlers[@intFromEnum(Opcode.ADD)] = mockAdd;
            handlers[@intFromEnum(Opcode.PUSH1)] = mockPush1;
            handlers[@intFromEnum(Opcode.JUMPDEST)] = mockJumpdest;
            handlers[@intFromEnum(Opcode.PC)] = mockPc;

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