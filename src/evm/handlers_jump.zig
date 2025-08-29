const std = @import("std");
const FrameConfig = @import("frame_config.zig").FrameConfig;
const log = @import("log.zig");

/// Jump operation handlers for the EVM stack frame.
/// These handle control flow operations including JUMP, JUMPI, JUMPDEST, and PC.
pub fn Handlers(comptime FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;

        /// JUMP opcode (0x56) - Unconditional jump.
        /// Pops destination from stack and transfers control to that location.
        /// The destination must be a valid JUMPDEST.
        pub fn jump(self: *FrameType, dispatch: Dispatch) Error!noreturn {
            const dest = try self.stack.pop();

            // Validate jump destination range
            if (dest > std.math.maxInt(u32)) {
                return Error.InvalidJump;
            }

            const dest_pc: FrameType.PcType = @intCast(dest);

            // Look up the destination in the jump table
            if (dispatch.findJumpTarget(dest_pc)) |jump_dispatch| {
                // Found valid JUMPDEST - tail call to the jump destination
                return @call(FrameType.getTailCallModifier(), jump_dispatch.cursor[0].opcode_handler, .{ self, jump_dispatch });
            } else {
                // Not a valid JUMPDEST
                return Error.InvalidJump;
            }
        }

        /// JUMPI opcode (0x57) - Conditional jump.
        /// Pops destination and condition from stack.
        /// Jumps to destination if condition is non-zero, otherwise continues to next instruction.
        pub fn jumpi(self: *FrameType, dispatch: Dispatch) Error!noreturn {
            const dest = try self.stack.pop();
            const condition = try self.stack.pop();

            if (condition != 0) {
                // Take the jump - validate destination range
                if (dest > std.math.maxInt(u32)) {
                    return Error.InvalidJump;
                }

                const dest_pc: FrameType.PcType = @intCast(dest);

                // Look up the destination in the jump table
                if (dispatch.findJumpTarget(dest_pc)) |jump_dispatch| {
                    // Found valid JUMPDEST - tail call to the jump destination
                    return @call(FrameType.getTailCallModifier(), jump_dispatch.cursor[0].opcode_handler, .{ self, jump_dispatch });
                } else {
                    // Not a valid JUMPDEST
                    return Error.InvalidJump;
                }
            } else {
                // Continue to next instruction
                const next = dispatch.getNext();
                return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next });
            }
        }

        /// JUMPDEST opcode (0x5b) - Mark valid jump destination.
        /// This opcode marks a valid destination for JUMP and JUMPI operations.
        /// It also serves as a gas consumption point for the entire basic block.
        pub fn jumpdest(self: *FrameType, dispatch: Dispatch) Error!noreturn {
            // JUMPDEST consumes gas for the entire basic block (static + dynamic)
            const metadata = dispatch.getJumpDestMetadata();
            const gas_cost = metadata.gas;

            // Check and consume gas for the entire basic block
            if (self.gas_remaining < gas_cost) {
                return Error.OutOfGas;
            }
            self.gas_remaining -= @as(FrameType.GasType, @intCast(gas_cost));

            // Continue to next operation
            const next = dispatch.skipMetadata();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next });
        }

        /// PC opcode (0x58) - Get program counter.
        /// Pushes the current program counter onto the stack.
        /// The actual PC value is provided by the planner through metadata.
        pub fn pc(self: *FrameType, dispatch: Dispatch) Error!noreturn {
            // Get PC value from metadata
            const metadata = dispatch.getPcMetadata();
            try self.stack.push(metadata.value);

            const next = dispatch.skipMetadata();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next });
        }
    };
}

// ====== TESTS ======

const testing = std.testing;
const Frame = @import("frame.zig").Frame;
const dispatch_mod = @import("dispatch.zig");
const NoOpTracer = @import("tracer.zig").NoOpTracer;
const bytecode_mod = @import("bytecode.zig");

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

fn createTestFrame(allocator: std.mem.Allocator) !TestFrame {
    const bytecode = TestBytecode.initEmpty();
    return try TestFrame.init(allocator, bytecode, 1_000_000, null, null);
}

// Mock dispatch that simulates successful execution flow
fn createMockDispatch() TestFrame.Dispatch {
    const mock_handler = struct {
        fn handler(frame: TestFrame, dispatch: TestFrame.Dispatch) TestFrame.Error!TestFrame.Success {
            _ = frame;
            _ = dispatch;
            return TestFrame.Success.stop;
        }
    }.handler;

    var cursor: [1]dispatch_mod.ScheduleElement(TestFrame) = undefined;
    cursor[0] = .{ .opcode_handler = &mock_handler };

    return TestFrame.Dispatch{
        .cursor = &cursor,
        .bytecode_length = 0,
    };
}

test "JUMP opcode - basic jump" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Push jump destination
    try frame.stack.push(100); // Jump to PC 100

    const dispatch = createMockDispatch();
    const result = TestFrame.JumpHandlers.jump(frame, dispatch);

    // Currently returns Stop as placeholder
    try testing.expectEqual(TestFrame.Success.Stop, try result);

    // Stack should be empty after jump
    try testing.expectEqual(@as(usize, 0), frame.stack.len());
}

test "JUMPI opcode - conditional jump taken" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Push destination and non-zero condition
    try frame.stack.push(200); // destination
    try frame.stack.push(1); // condition (non-zero = jump)

    const dispatch = createMockDispatch();
    const result = TestFrame.JumpHandlers.jumpi(frame, dispatch);

    // Should take the jump (returns Stop as placeholder)
    try testing.expectEqual(TestFrame.Success.Stop, try result);

    // Stack should be empty
    try testing.expectEqual(@as(usize, 0), frame.stack.len());
}

test "JUMPI opcode - conditional jump not taken" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Push destination and zero condition
    try frame.stack.push(200); // destination
    try frame.stack.push(0); // condition (zero = no jump)

    const dispatch = createMockDispatch();
    _ = try TestFrame.JumpHandlers.jumpi(frame, dispatch);

    // Should continue to next instruction
    // Stack should be empty
    try testing.expectEqual(@as(usize, 0), frame.stack.len());
}

test "JUMPDEST opcode - gas consumption" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Set initial gas
    frame.gas_remaining = 10_000;
    const initial_gas = frame.gas_remaining;

    // Create dispatch with jump dest metadata
    var cursor: [2]dispatch_mod.ScheduleElement(TestFrame) = undefined;
    const mock_handler = struct {
        fn handler(f: TestFrame, d: TestFrame.Dispatch) TestFrame.Error!TestFrame.Success {
            _ = f;
            _ = d;
            return TestFrame.Success.stop;
        }
    }.handler;

    cursor[0] = .{ .opcode_handler = &mock_handler };
    cursor[1] = .{ .opcode_handler = &mock_handler };

    // Set jump dest metadata with gas cost for the basic block
    cursor[0].metadata = .{ .jump_dest = .{ .gas = 500 } };

    const dispatch = TestFrame.Dispatch{
        .cursor = &cursor,
        .bytecode_length = 0,
    };

    _ = try TestFrame.JumpHandlers.jumpdest(frame, dispatch);

    // Gas should be consumed
    try testing.expectEqual(@as(i64, initial_gas - 500), frame.gas_remaining);
}

test "JUMPDEST opcode - out of gas" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Set very low gas
    frame.gas_remaining = 100;

    // Create dispatch with high gas cost
    var cursor: [2]dispatch_mod.ScheduleElement(TestFrame) = undefined;
    const mock_handler = struct {
        fn handler(f: TestFrame, d: TestFrame.Dispatch) TestFrame.Error!TestFrame.Success {
            _ = f;
            _ = d;
            return TestFrame.Success.stop;
        }
    }.handler;

    cursor[0] = .{ .opcode_handler = &mock_handler };
    cursor[1] = .{ .opcode_handler = &mock_handler };

    // Set jump dest metadata with high gas cost
    cursor[0].metadata = .{ .jump_dest = .{ .gas = 1000 } };

    const dispatch = TestFrame.Dispatch{
        .cursor = &cursor,
        .bytecode_length = 0,
    };

    const result = TestFrame.JumpHandlers.jumpdest(frame, dispatch);

    try testing.expectError(TestFrame.Error.OutOfGas, result);
}

test "PC opcode - push program counter" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Create dispatch with PC metadata
    var cursor: [2]dispatch_mod.ScheduleElement(TestFrame) = undefined;
    const mock_handler = struct {
        fn handler(f: TestFrame, d: TestFrame.Dispatch) TestFrame.Error!TestFrame.Success {
            _ = f;
            _ = d;
            return TestFrame.Success.stop;
        }
    }.handler;

    cursor[0] = .{ .opcode_handler = &mock_handler };
    cursor[1] = .{ .opcode_handler = &mock_handler };

    // Set PC metadata
    cursor[0].metadata = .{ .pc = .{ .value = 42 } };

    const dispatch = TestFrame.Dispatch{
        .cursor = &cursor,
        .bytecode_length = 0,
    };

    _ = try TestFrame.JumpHandlers.pc(frame, dispatch);

    // PC value should be on stack
    try testing.expectEqual(@as(u256, 42), try frame.stack.pop());
}

test "JUMPI opcode - various conditions" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test with different condition values
    const test_cases = [_]struct { condition: u256, should_jump: bool }{
        .{ .condition = 0, .should_jump = false },
        .{ .condition = 1, .should_jump = true },
        .{ .condition = 0xFF, .should_jump = true },
        .{ .condition = std.math.maxInt(u256), .should_jump = true },
        .{ .condition = 0x8000000000000000, .should_jump = true },
    };

    for (test_cases) |tc| {
        // Clear stack
        while (frame.stack.len() > 0) {
            _ = try frame.stack.pop();
        }

        // Push destination and condition
        try frame.stack.push(300); // destination
        try frame.stack.push(tc.condition); // condition

        const dispatch = createMockDispatch();
        const result = TestFrame.JumpHandlers.jumpi(frame, dispatch);

        if (tc.should_jump) {
            // Should jump (returns Stop)
            try testing.expectEqual(TestFrame.Success.Stop, try result);
        } else {
            // Should continue (mock returns stop)
            try testing.expectEqual(TestFrame.Success.stop, try result);
        }

        // Stack should be empty
        try testing.expectEqual(@as(usize, 0), frame.stack.len());
    }
}

test "Jump operations - stack underflow" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test JUMP with empty stack
    const dispatch = createMockDispatch();
    var result = TestFrame.JumpHandlers.jump(frame, dispatch);
    try testing.expectError(TestFrame.Error.StackUnderflow, result);

    // Test JUMPI with only one element
    try frame.stack.push(100);
    result = TestFrame.JumpHandlers.jumpi(frame, dispatch);
    try testing.expectError(TestFrame.Error.StackUnderflow, result);

    // Clear stack
    _ = try frame.stack.pop();

    // Test JUMPI with empty stack
    result = TestFrame.JumpHandlers.jumpi(frame, dispatch);
    try testing.expectError(TestFrame.Error.StackUnderflow, result);
}

test "PC opcode - different values" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test various PC values
    const pc_values = [_]u256{ 0, 1, 100, 1000, 65535, std.math.maxInt(u32) };

    for (pc_values) |pc_val| {
        // Clear stack
        while (frame.stack.len() > 0) {
            _ = try frame.stack.pop();
        }

        // Create dispatch with PC metadata
        var cursor: [2]dispatch_mod.ScheduleElement(TestFrame) = undefined;
        const mock_handler = struct {
            fn handler(f: TestFrame, d: TestFrame.Dispatch) TestFrame.Error!TestFrame.Success {
                _ = f;
                _ = d;
                return TestFrame.Success.stop;
            }
        }.handler;

        cursor[0] = .{ .opcode_handler = &mock_handler };
        cursor[1] = .{ .opcode_handler = &mock_handler };

        cursor[0].metadata = .{ .pc = .{ .value = pc_val } };

        const dispatch = TestFrame.Dispatch{
            .cursor = &cursor,
            .bytecode_length = 0,
        };

        _ = try TestFrame.JumpHandlers.pc(frame, dispatch);

        try testing.expectEqual(pc_val, try frame.stack.pop());
    }
}

test "JUMPDEST opcode - zero gas cost" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Set initial gas
    frame.gas_remaining = 1_000;
    const initial_gas = frame.gas_remaining;

    // Create dispatch with zero gas cost (empty basic block)
    var cursor: [2]dispatch_mod.ScheduleElement(TestFrame) = undefined;
    const mock_handler = struct {
        fn handler(f: TestFrame, d: TestFrame.Dispatch) TestFrame.Error!TestFrame.Success {
            _ = f;
            _ = d;
            return TestFrame.Success.stop;
        }
    }.handler;

    cursor[0] = .{ .opcode_handler = &mock_handler };
    cursor[1] = .{ .opcode_handler = &mock_handler };

    cursor[0].metadata = .{ .jump_dest = .{ .gas = 0 } };

    const dispatch = TestFrame.Dispatch{
        .cursor = &cursor,
        .bytecode_length = 0,
    };

    _ = try TestFrame.JumpHandlers.jumpdest(frame, dispatch);

    // No gas should be consumed
    try testing.expectEqual(initial_gas, frame.gas_remaining);
}

test "JUMP opcode - dynamic validation with valid destination" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Push the jump destination
    try frame.stack.push(5); // Valid JUMPDEST at PC 5

    const dispatch = createMockDispatch();
    const result = TestFrame.JumpHandlers.jump(frame, dispatch);

    // Currently returns Stop as placeholder - will be updated with actual validation
    try testing.expectEqual(TestFrame.Success.Stop, try result);
    try testing.expectEqual(@as(usize, 0), frame.stack.len());
}

test "JUMP opcode - dynamic validation with invalid destination" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Push invalid jump destination (no JUMPDEST at PC 10)
    try frame.stack.push(10);

    const dispatch = createMockDispatch();
    const result = TestFrame.JumpHandlers.jump(frame, dispatch);

    // Should fail with invalid jump destination
    try testing.expectError(TestFrame.Error.InvalidJump, result);
}

test "JUMPI opcode - dynamic validation with valid destination when taken" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Push destination and non-zero condition
    try frame.stack.push(5); // Valid destination (would need JUMPDEST in real bytecode)
    try frame.stack.push(1); // Non-zero condition

    const dispatch = createMockDispatch();
    const result = TestFrame.JumpHandlers.jumpi(frame, dispatch);

    // Currently returns Stop as placeholder - validation occurs
    try testing.expectEqual(TestFrame.Success.Stop, try result);
    try testing.expectEqual(@as(usize, 0), frame.stack.len());
}

test "JUMPI opcode - dynamic validation with invalid destination when taken" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Push invalid destination and non-zero condition
    try frame.stack.push(10); // Invalid destination (no JUMPDEST)
    try frame.stack.push(1); // Non-zero condition

    const dispatch = createMockDispatch();
    const result = TestFrame.JumpHandlers.jumpi(frame, dispatch);

    // Should fail with invalid jump destination when condition is non-zero
    try testing.expectError(TestFrame.Error.InvalidJump, result);
}

test "JUMPI opcode - no validation when not taken" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Push invalid destination but zero condition
    try frame.stack.push(10); // Invalid destination (but won't be used)
    try frame.stack.push(0); // Zero condition - jump not taken

    const dispatch = createMockDispatch();
    _ = try TestFrame.JumpHandlers.jumpi(frame, dispatch);

    // Should succeed - no validation when jump not taken
    try testing.expectEqual(@as(usize, 0), frame.stack.len());
}

test "Jump operations - integration test" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Simulate a common pattern: PC, conditional jump based on comparison

    // First, get current PC
    var cursor: [2]dispatch_mod.ScheduleElement(TestFrame) = undefined;
    const mock_handler = struct {
        fn handler(f: TestFrame, d: TestFrame.Dispatch) TestFrame.Error!TestFrame.Success {
            _ = f;
            _ = d;
            return TestFrame.Success.stop;
        }
    }.handler;

    cursor[0] = .{ .opcode_handler = &mock_handler };
    cursor[1] = .{ .opcode_handler = &mock_handler };

    cursor[0].metadata = .{ .pc = .{ .value = 50 } };

    const dispatch = TestFrame.Dispatch{
        .cursor = &cursor,
        .bytecode_length = 0,
    };

    _ = try TestFrame.JumpHandlers.pc(frame, dispatch);

    // Stack: [50]

    // Push comparison value and destination
    try frame.stack.push(50); // Compare with current PC
    try frame.stack.push(100); // Jump destination

    // Stack: [50, 50, 100]

    // Simulate EQ comparison (would normally be done by comparison handler)
    const b = try frame.stack.pop();
    const a = try frame.stack.pop();
    try frame.stack.push(if (a == b) @as(u256, 1) else 0);

    // Stack: [50, 1]

    // Now JUMPI with condition = 1 (should jump)
    const dispatch2 = createMockDispatch();
    const result = TestFrame.JumpHandlers.jumpi(frame, dispatch2);

    try testing.expectEqual(TestFrame.Success.Stop, try result);
    try testing.expectEqual(@as(usize, 0), frame.stack.len());
}

// ====== COMPREHENSIVE TESTS ======

test "JUMP opcode - boundary destinations" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test various jump destinations
    const destinations = [_]u256{
        0, // Beginning of code
        1, // First byte
        0x5B, // JUMPDEST opcode value
        0xFF, // Byte boundary
        0xFFFF, // Word boundary
        0xFFFFFF, // 3-byte boundary
        std.math.maxInt(u32), // Max 32-bit value
        std.math.maxInt(u256), // Max destination
    };

    for (destinations) |dest| {
        // Clear stack
        while (frame.stack.len() > 0) {
            _ = try frame.stack.pop();
        }

        try frame.stack.push(dest);

        const dispatch = createMockDispatch();
        const result = TestFrame.JumpHandlers.jump(frame, dispatch);

        // Should handle all destinations (placeholder returns Stop)
        try testing.expectEqual(TestFrame.Success.Stop, try result);
        try testing.expectEqual(@as(usize, 0), frame.stack.len());
    }
}

test "JUMPI opcode - edge case conditions" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test edge case condition values
    const edge_cases = [_]struct {
        condition: u256,
        destination: u256,
        should_jump: bool,
        description: []const u8,
    }{
        .{ .condition = 0, .destination = 100, .should_jump = false, .description = "zero" },
        .{ .condition = 1, .destination = 200, .should_jump = true, .description = "one" },
        .{ .condition = 2, .destination = 300, .should_jump = true, .description = "two" },
        .{ .condition = 0x80, .destination = 400, .should_jump = true, .description = "0x80" },
        .{ .condition = 0xFF, .destination = 500, .should_jump = true, .description = "0xFF" },
        .{ .condition = 0x100, .destination = 600, .should_jump = true, .description = "0x100" },
        .{ .condition = 0x8000000000000000, .destination = 700, .should_jump = true, .description = "high bit" },
        .{ .condition = std.math.maxInt(u128), .destination = 800, .should_jump = true, .description = "max u128" },
        .{ .condition = std.math.maxInt(u256) - 1, .destination = 900, .should_jump = true, .description = "max-1" },
        .{ .condition = std.math.maxInt(u256), .destination = 1000, .should_jump = true, .description = "max u256" },
    };

    for (edge_cases) |tc| {
        // Clear stack
        while (frame.stack.len() > 0) {
            _ = try frame.stack.pop();
        }

        try frame.stack.push(tc.destination);
        try frame.stack.push(tc.condition);

        const dispatch = createMockDispatch();
        const result = TestFrame.JumpHandlers.jumpi(frame, dispatch);

        if (tc.should_jump) {
            try testing.expectEqual(TestFrame.Success.Stop, try result);
        } else {
            try testing.expectEqual(TestFrame.Success.stop, try result);
        }

        try testing.expectEqual(@as(usize, 0), frame.stack.len());
    }
}

test "JUMPDEST opcode - various gas costs" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test different gas costs for basic blocks
    const gas_costs = [_]i64{
        0, // Empty block
        1, // Single gas
        3, // Base cost
        10, // Small block
        100, // Medium block
        1000, // Large block
        10000, // Very large block
        100000, // Huge block
    };

    for (gas_costs) |gas_cost| {
        // Set sufficient gas
        frame.gas_remaining = 1_000_000;
        const initial_gas = frame.gas_remaining;

        var cursor: [2]dispatch_mod.ScheduleElement(TestFrame) = undefined;
        const mock_handler = struct {
            fn handler(f: TestFrame, d: TestFrame.Dispatch) TestFrame.Error!TestFrame.Success {
                _ = f;
                _ = d;
                return TestFrame.Success.stop;
            }
        }.handler;

        cursor[0] = .{ .opcode_handler = &mock_handler };
        cursor[1] = .{ .opcode_handler = &mock_handler };

        cursor[0].metadata = .{ .jump_dest = .{ .gas = gas_cost } };

        const dispatch = TestFrame.Dispatch{
            .cursor = &cursor,
            .bytecode_length = 0,
        };

        _ = try TestFrame.JumpHandlers.jumpdest(frame, dispatch);

        // Verify exact gas consumption
        try testing.expectEqual(initial_gas - gas_cost, frame.gas_remaining);
    }
}

test "JUMPDEST opcode - exact gas boundary" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test exact gas boundary conditions
    const test_cases = [_]struct {
        available_gas: i64,
        required_gas: i64,
        should_succeed: bool,
    }{
        .{ .available_gas = 100, .required_gas = 99, .should_succeed = true },
        .{ .available_gas = 100, .required_gas = 100, .should_succeed = true },
        .{ .available_gas = 100, .required_gas = 101, .should_succeed = false },
        .{ .available_gas = 1, .required_gas = 1, .should_succeed = true },
        .{ .available_gas = 0, .required_gas = 0, .should_succeed = true },
        .{ .available_gas = 0, .required_gas = 1, .should_succeed = false },
    };

    for (test_cases) |tc| {
        frame.gas_remaining = tc.available_gas;

        var cursor: [2]dispatch_mod.ScheduleElement(TestFrame) = undefined;
        const mock_handler = struct {
            fn handler(f: TestFrame, d: TestFrame.Dispatch) TestFrame.Error!TestFrame.Success {
                _ = f;
                _ = d;
                return TestFrame.Success.stop;
            }
        }.handler;

        cursor[0] = .{ .opcode_handler = &mock_handler };
        cursor[1] = .{ .opcode_handler = &mock_handler };

        cursor[0].metadata = .{ .jump_dest = .{ .gas = tc.required_gas } };

        const dispatch = TestFrame.Dispatch{
            .cursor = &cursor,
            .bytecode_length = 0,
        };

        const result = TestFrame.JumpHandlers.jumpdest(frame, dispatch);

        if (tc.should_succeed) {
            _ = try result;
            try testing.expectEqual(tc.available_gas - tc.required_gas, frame.gas_remaining);
        } else {
            try testing.expectError(TestFrame.Error.OutOfGas, result);
        }
    }
}

test "PC opcode - boundary values" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test PC at various boundaries
    const pc_boundaries = [_]u256{
        0, // Start of code
        1, // First instruction
        0x5B, // JUMPDEST value
        0xFF, // Max single byte
        0x100, // First two-byte value
        0xFFFF, // Max two bytes
        0x10000, // First three-byte value
        0xFFFFFF, // Max three bytes (typical max contract size)
        0x1000000, // Beyond typical contract size
        std.math.maxInt(u32), // Max 32-bit PC
        std.math.maxInt(u64), // Max 64-bit PC
        (1 << 128) - 1, // Max 128-bit PC
        std.math.maxInt(u256) - 1, // Near max
        std.math.maxInt(u256), // Max possible PC
    };

    for (pc_boundaries) |pc_val| {
        // Clear stack
        while (frame.stack.len() > 0) {
            _ = try frame.stack.pop();
        }

        var cursor: [2]dispatch_mod.ScheduleElement(TestFrame) = undefined;
        const mock_handler = struct {
            fn handler(f: TestFrame, d: TestFrame.Dispatch) TestFrame.Error!TestFrame.Success {
                _ = f;
                _ = d;
                return TestFrame.Success.stop;
            }
        }.handler;

        cursor[0] = .{ .opcode_handler = &mock_handler };
        cursor[1] = .{ .opcode_handler = &mock_handler };

        cursor[0].metadata = .{ .pc = .{ .value = pc_val } };

        const dispatch = TestFrame.Dispatch{
            .cursor = &cursor,
            .bytecode_length = 0,
        };

        _ = try TestFrame.JumpHandlers.pc(frame, dispatch);

        const stack_val = try frame.stack.pop();
        try testing.expectEqual(pc_val, stack_val);
        try testing.expectEqual(@as(usize, 0), frame.stack.len());
    }
}

test "Jump operations - gas consumption patterns" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // JUMP and JUMPI should not consume gas directly (gas is consumed by JUMPDEST)
    frame.gas_remaining = 100;
    const initial_gas = frame.gas_remaining;

    // Test JUMP
    try frame.stack.push(50);
    var dispatch = createMockDispatch();
    _ = try TestFrame.JumpHandlers.jump(frame, dispatch);

    // Gas should not change
    try testing.expectEqual(initial_gas, frame.gas_remaining);

    // Test JUMPI (taken)
    try frame.stack.push(100);
    try frame.stack.push(1);
    dispatch = createMockDispatch();
    _ = try TestFrame.JumpHandlers.jumpi(frame, dispatch);

    // Gas should not change
    try testing.expectEqual(initial_gas, frame.gas_remaining);

    // Test JUMPI (not taken)
    try frame.stack.push(100);
    try frame.stack.push(0);
    dispatch = createMockDispatch();
    _ = try TestFrame.JumpHandlers.jumpi(frame, dispatch);

    // Gas should not change
    try testing.expectEqual(initial_gas, frame.gas_remaining);

    // Test PC
    var cursor: [2]dispatch_mod.ScheduleElement(TestFrame) = undefined;
    const mock_handler = struct {
        fn handler(f: TestFrame, d: TestFrame.Dispatch) TestFrame.Error!TestFrame.Success {
            _ = f;
            _ = d;
            return TestFrame.Success.stop;
        }
    }.handler;

    cursor[0] = .{ .opcode_handler = &mock_handler };
    cursor[1] = .{ .opcode_handler = &mock_handler };

    cursor[0].metadata = .{ .pc = .{ .value = 42 } };

    dispatch = TestFrame.Dispatch{
        .cursor = &cursor,
        .bytecode_length = 0,
    };

    _ = try TestFrame.JumpHandlers.pc(frame, dispatch);

    // Gas should not change (PC is a simple push operation, gas handled elsewhere)
    try testing.expectEqual(initial_gas, frame.gas_remaining);
}

test "Jump operations - maximum stack depth" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Fill stack to near maximum
    const max_items = 1022; // Leave room for 2 items
    for (0..max_items) |i| {
        try frame.stack.push(@as(u256, i));
    }

    // JUMP should work with full stack (pops 1)
    try frame.stack.push(100);
    var dispatch = createMockDispatch();
    _ = try TestFrame.JumpHandlers.jump(frame, dispatch);
    try testing.expectEqual(@as(usize, max_items), frame.stack.len());

    // JUMPI should work with full stack (pops 2)
    try frame.stack.push(200);
    try frame.stack.push(1);
    dispatch = createMockDispatch();
    _ = try TestFrame.JumpHandlers.jumpi(frame, dispatch);
    try testing.expectEqual(@as(usize, max_items), frame.stack.len());

    // PC with full stack should fail
    // Fill to maximum
    try frame.stack.push(0);
    try frame.stack.push(0);

    var cursor: [2]dispatch_mod.ScheduleElement(TestFrame) = undefined;
    const mock_handler = struct {
        fn handler(f: TestFrame, d: TestFrame.Dispatch) TestFrame.Error!TestFrame.Success {
            _ = f;
            _ = d;
            return TestFrame.Success.stop;
        }
    }.handler;

    cursor[0] = .{ .opcode_handler = &mock_handler };
    cursor[1] = .{ .opcode_handler = &mock_handler };

    cursor[0].metadata = .{ .pc = .{ .value = 42 } };

    dispatch = TestFrame.Dispatch{
        .cursor = &cursor,
        .bytecode_length = 0,
    };

    const result = TestFrame.JumpHandlers.pc(frame, dispatch);
    try testing.expectError(TestFrame.Error.StackOverflow, result);
}

test "JUMPI opcode - pattern analysis" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Common JUMPI patterns
    const patterns = [_]struct {
        name: []const u8,
        setup: fn (*TestFrame) anyerror!void,
        destination: u256,
        should_jump: bool,
    }{
        .{
            .name = "after equality check",
            .setup = struct {
                fn setup(f: *TestFrame) !void {
                    // Simulate: PUSH 5, PUSH 5, EQ, JUMPI
                    const eq_result: u256 = 1; // 5 == 5
                    try f.stack.push(eq_result);
                }
            }.setup,
            .destination = 100,
            .should_jump = true,
        },
        .{
            .name = "after inequality check",
            .setup = struct {
                fn setup(f: *TestFrame) !void {
                    // Simulate: PUSH 5, PUSH 6, EQ, JUMPI
                    const eq_result: u256 = 0; // 5 != 6
                    try f.stack.push(eq_result);
                }
            }.setup,
            .destination = 200,
            .should_jump = false,
        },
        .{
            .name = "after ISZERO true",
            .setup = struct {
                fn setup(f: *TestFrame) !void {
                    // Simulate: PUSH 0, ISZERO, JUMPI
                    const iszero_result: u256 = 1; // 0 == 0
                    try f.stack.push(iszero_result);
                }
            }.setup,
            .destination = 300,
            .should_jump = true,
        },
        .{
            .name = "after ISZERO false",
            .setup = struct {
                fn setup(f: *TestFrame) !void {
                    // Simulate: PUSH 5, ISZERO, JUMPI
                    const iszero_result: u256 = 0; // 5 != 0
                    try f.stack.push(iszero_result);
                }
            }.setup,
            .destination = 400,
            .should_jump = false,
        },
        .{
            .name = "after LT true",
            .setup = struct {
                fn setup(f: *TestFrame) !void {
                    // Simulate: PUSH 10, PUSH 5, LT, JUMPI
                    const lt_result: u256 = 1; // 5 < 10
                    try f.stack.push(lt_result);
                }
            }.setup,
            .destination = 500,
            .should_jump = true,
        },
    };

    for (patterns) |pattern| {
        // Clear stack
        while (frame.stack.len() > 0) {
            _ = try frame.stack.pop();
        }

        // Setup condition
        try pattern.setup(&frame);

        // Push destination
        try frame.stack.push(pattern.destination);

        // Swap to get [destination, condition]
        const condition = try frame.stack.pop();
        const dest = try frame.stack.pop();
        try frame.stack.push(dest);
        try frame.stack.push(condition);

        const dispatch = createMockDispatch();
        const result = TestFrame.JumpHandlers.jumpi(frame, dispatch);

        if (pattern.should_jump) {
            try testing.expectEqual(TestFrame.Success.Stop, try result);
        } else {
            try testing.expectEqual(TestFrame.Success.stop, try result);
        }
    }
}
