const std = @import("std");
const FrameConfig = @import("frame_config.zig").FrameConfig;
const log = @import("log.zig");

/// Synthetic jump opcode handlers for the EVM stack frame.
/// These handle fused PUSH+jump operations for optimization.
pub fn Handlers(comptime FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Success = FrameType.Success;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;

        /// PUSH_JUMP_INLINE - Fused PUSH+JUMP with inline destination (≤8 bytes).
        /// Pushes a destination and immediately jumps to it.
        pub fn push_jump_inline(self: *FrameType, dispatch: Dispatch) Error!Success {
            
            const metadata = dispatch.getInlineMetadata();
            const dest = metadata.value;
            
            // Validate jump destination range
            if (dest > std.math.maxInt(u32)) {
                return Error.InvalidJump;
            }
            
            const dest_pc: u16 = @intCast(dest);
            
            // Look up the destination in the jump table
            if (dispatch.findJumpTarget(dest_pc)) |jump_dispatch| {
                // Found valid JUMPDEST - tail call to the jump destination
                return @call(.auto, jump_dispatch.cursor[0].opcode_handler, .{ self, jump_dispatch });
            } else {
                // Not a valid JUMPDEST
                return Error.InvalidJump;
            }
        }

        /// PUSH_JUMP_POINTER - Fused PUSH+JUMP with pointer destination (>8 bytes).
        pub fn push_jump_pointer(self: *FrameType, dispatch: Dispatch) Error!Success {
            
            const metadata = dispatch.getPointerMetadata();
            const dest = metadata.value.*;
            
            // Validate jump destination range
            if (dest > std.math.maxInt(u32)) {
                return Error.InvalidJump;
            }
            
            const dest_pc: u16 = @intCast(dest);
            
            // Look up the destination in the jump table
            if (dispatch.findJumpTarget(dest_pc)) |jump_dispatch| {
                // Found valid JUMPDEST - tail call to the jump destination
                return @call(.auto, jump_dispatch.cursor[0].opcode_handler, .{ self, jump_dispatch });
            } else {
                // Not a valid JUMPDEST
                return Error.InvalidJump;
            }
        }

        /// PUSH_JUMPI_INLINE - Fused PUSH+JUMPI with inline destination (≤8 bytes).
        /// Pushes a destination, pops condition, and conditionally jumps.
        pub fn push_jumpi_inline(self: *FrameType, dispatch: Dispatch) Error!Success {
            
            const metadata = dispatch.getInlineMetadata();
            const dest = metadata.value;
            
            // Pop the condition
            const condition = try self.stack.pop();
            
            if (condition != 0) {
                // Take the jump - validate destination range
                if (dest > std.math.maxInt(u32)) {
                    return Error.InvalidJump;
                }
                
                const dest_pc: u16 = @intCast(dest);
                
                // Look up the destination in the jump table
                if (dispatch.findJumpTarget(dest_pc)) |jump_dispatch| {
                    // Found valid JUMPDEST - tail call to the jump destination
                    return @call(.auto, jump_dispatch.cursor[0].opcode_handler, .{ self, jump_dispatch });
                } else {
                    // Not a valid JUMPDEST
                    return Error.InvalidJump;
                }
            } else {
                // Continue to next instruction
                const next = dispatch.skipMetadata();
                return @call(.auto, next.cursor[0].opcode_handler, .{ self, next });
            }
        }

        /// PUSH_JUMPI_POINTER - Fused PUSH+JUMPI with pointer destination (>8 bytes).
        pub fn push_jumpi_pointer(self: *FrameType, dispatch: Dispatch) Error!Success {
            
            const metadata = dispatch.getPointerMetadata();
            const dest = metadata.value.*;
            
            // Pop the condition
            const condition = try self.stack.pop();
            
            if (condition != 0) {
                // Take the jump - validate destination range
                if (dest > std.math.maxInt(u32)) {
                    return Error.InvalidJump;
                }
                
                const dest_pc: u16 = @intCast(dest);
                
                // Look up the destination in the jump table
                if (dispatch.findJumpTarget(dest_pc)) |jump_dispatch| {
                    // Found valid JUMPDEST - tail call to the jump destination
                    return @call(.auto, jump_dispatch.cursor[0].opcode_handler, .{ self, jump_dispatch });
                } else {
                    // Not a valid JUMPDEST
                    return Error.InvalidJump;
                }
            } else {
                // Continue to next instruction
                const next = dispatch.skipMetadata();
                return @call(.auto, next.cursor[0].opcode_handler, .{ self, next });
            }
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
    .has_database = false,
    .TracerType = NoOpTracer,
    .memory_initial_capacity = 4096,
    .memory_limit = 0xFFFFFF,
};

const TestFrame = Frame(test_config);
const TestBytecode = bytecode_mod.Bytecode(.{ .max_bytecode_size = test_config.max_bytecode_size });

fn createTestFrame(allocator: std.mem.Allocator) !TestFrame {
    const bytecode = TestBytecode.initEmpty();
    return try TestFrame.init(allocator, bytecode, 1_000_000, null, null);
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
    
    cursor[0].metadata = .{ .inline_value = value };
    
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

test "synthetic jump - stack underflow" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // PUSH_JUMPI with empty stack should fail
    const dispatch = createInlineDispatch(100);
    const result = TestFrame.JumpSyntheticHandlers.push_jumpi_inline(frame, dispatch);
    
    try testing.expectError(TestFrame.Error.StackUnderflow, result);
}