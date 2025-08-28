const std = @import("std");
const FrameConfig = @import("frame_config.zig").FrameConfig;
const log = @import("log.zig");
const memory_mod = @import("memory.zig");
const GasConstants = @import("primitives").GasConstants;

/// Synthetic memory opcode handlers for the EVM stack frame.
/// These handle fused PUSH+memory operations for optimization.
pub fn Handlers(comptime FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Success = FrameType.Success;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;

        /// PUSH_MLOAD_INLINE - Fused PUSH+MLOAD with inline offset (≤8 bytes).
        /// Pushes an offset and immediately loads from that memory location.
        pub fn push_mload_inline(self: *FrameType, dispatch: Dispatch) Error!Success {
            const metadata = dispatch.getInlineMetadata();
            const offset = metadata.value;
            
            // Check if offset fits in usize
            if (offset > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            const offset_usize = @as(usize, @intCast(offset));
            
            // Calculate gas cost for memory expansion
            const memory_expansion_cost = self.memory.get_expansion_cost(@as(u24, @intCast(offset_usize + 32)));
            if (self.gas_remaining < GasConstants.GasFastestStep + memory_expansion_cost) {
                return Error.OutOfGas;
            }
            self.gas_remaining -= @intCast(GasConstants.GasFastestStep + memory_expansion_cost);
            
            // Read 32 bytes from memory
            const value_u256 = self.memory.get_u256_evm(self.allocator, @as(u24, @intCast(offset_usize))) catch |err| switch (err) {
                memory_mod.MemoryError.OutOfBounds => return Error.OutOfBounds,
                memory_mod.MemoryError.MemoryOverflow => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };
            
            const value = @as(WordType, @truncate(value_u256));
            try self.stack.push(value);

            const next = dispatch.skipMetadata();
            return @call(.auto, next.cursor[0].opcode_handler, .{ self, next });
        }

        /// PUSH_MLOAD_POINTER - Fused PUSH+MLOAD with pointer offset (>8 bytes).
        pub fn push_mload_pointer(self: *FrameType, dispatch: Dispatch) Error!Success {
            const metadata = dispatch.getPointerMetadata();
            const offset = metadata.value.*;
            
            // Check if offset fits in usize
            if (offset > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            const offset_usize = @as(usize, @intCast(offset));
            
            // Calculate gas cost for memory expansion
            const memory_expansion_cost = self.memory.get_expansion_cost(@as(u24, @intCast(offset_usize + 32)));
            if (self.gas_remaining < GasConstants.GasFastestStep + memory_expansion_cost) {
                return Error.OutOfGas;
            }
            self.gas_remaining -= @intCast(GasConstants.GasFastestStep + memory_expansion_cost);
            
            // Read 32 bytes from memory
            const value_u256 = self.memory.get_u256_evm(self.allocator, @as(u24, @intCast(offset_usize))) catch |err| switch (err) {
                memory_mod.MemoryError.OutOfBounds => return Error.OutOfBounds,
                memory_mod.MemoryError.MemoryOverflow => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };
            
            const value = @as(WordType, @truncate(value_u256));
            try self.stack.push(value);

            const next = dispatch.skipMetadata();
            return @call(.auto, next.cursor[0].opcode_handler, .{ self, next });
        }

        /// PUSH_MSTORE_INLINE - Fused PUSH+MSTORE with inline offset (≤8 bytes).
        /// Pushes an offset, then pops a value and stores it at that offset.
        pub fn push_mstore_inline(self: *FrameType, dispatch: Dispatch) Error!Success {
            const metadata = dispatch.getInlineMetadata();
            const offset = metadata.value;
            
            // Pop the value to store
            const value = try self.stack.pop();
            
            // Check if offset fits in usize
            if (offset > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            const offset_usize = @as(usize, @intCast(offset));
            
            // Calculate gas cost for memory expansion
            const memory_expansion_cost = self.memory.get_expansion_cost(@as(u24, @intCast(offset_usize + 32)));
            if (self.gas_remaining < GasConstants.GasFastestStep + memory_expansion_cost) {
                return Error.OutOfGas;
            }
            self.gas_remaining -= @intCast(GasConstants.GasFastestStep + memory_expansion_cost);
            
            // Store 32 bytes to memory
            const value_u256 = @as(u256, value);
            self.memory.set_u256_evm(self.allocator, @as(u24, @intCast(offset_usize)), value_u256) catch |err| switch (err) {
                memory_mod.MemoryError.OutOfBounds => return Error.OutOfBounds,
                memory_mod.MemoryError.MemoryOverflow => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };

            const next = dispatch.skipMetadata();
            return @call(.auto, next.cursor[0].opcode_handler, .{ self, next });
        }

        /// PUSH_MSTORE_POINTER - Fused PUSH+MSTORE with pointer offset (>8 bytes).
        pub fn push_mstore_pointer(self: *FrameType, dispatch: Dispatch) Error!Success {
            const metadata = dispatch.getPointerMetadata();
            const offset = metadata.value.*;
            
            // Pop the value to store
            const value = try self.stack.pop();
            
            // Check if offset fits in usize
            if (offset > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            const offset_usize = @as(usize, @intCast(offset));
            
            // Calculate gas cost for memory expansion
            const memory_expansion_cost = self.memory.get_expansion_cost(@as(u24, @intCast(offset_usize + 32)));
            if (self.gas_remaining < GasConstants.GasFastestStep + memory_expansion_cost) {
                return Error.OutOfGas;
            }
            self.gas_remaining -= @intCast(GasConstants.GasFastestStep + memory_expansion_cost);
            
            // Store 32 bytes to memory
            const value_u256 = @as(u256, value);
            self.memory.set_u256_evm(self.allocator, @as(u24, @intCast(offset_usize)), value_u256) catch |err| switch (err) {
                memory_mod.MemoryError.OutOfBounds => return Error.OutOfBounds,
                memory_mod.MemoryError.MemoryOverflow => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };

            const next = dispatch.skipMetadata();
            return @call(.auto, next.cursor[0].opcode_handler, .{ self, next });
        }

        /// PUSH_MSTORE8_INLINE - Fused PUSH+MSTORE8 with inline offset (≤8 bytes).
        /// Pushes an offset, then pops a value and stores the least significant byte.
        pub fn push_mstore8_inline(self: *FrameType, dispatch: Dispatch) Error!Success {
            const metadata = dispatch.getInlineMetadata();
            const offset = metadata.value;
            
            // Pop the value to store
            const value = try self.stack.pop();
            
            // Check if offset fits in usize
            if (offset > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            const offset_usize = @as(usize, @intCast(offset));
            
            // Calculate gas cost for memory expansion
            const memory_expansion_cost = self.memory.get_expansion_cost(@as(u24, @intCast(offset_usize + 1)));
            if (self.gas_remaining < GasConstants.GasFastestStep + memory_expansion_cost) {
                return Error.OutOfGas;
            }
            self.gas_remaining -= @intCast(GasConstants.GasFastestStep + memory_expansion_cost);
            
            // Store the least significant byte
            const byte_value = @as(u8, @truncate(value));
            self.memory.set_byte_evm(self.allocator, @as(u24, @intCast(offset_usize)), byte_value) catch |err| switch (err) {
                memory_mod.MemoryError.OutOfBounds => return Error.OutOfBounds,
                memory_mod.MemoryError.MemoryOverflow => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };

            const next = dispatch.skipMetadata();
            return @call(.auto, next.cursor[0].opcode_handler, .{ self, next });
        }

        /// PUSH_MSTORE8_POINTER - Fused PUSH+MSTORE8 with pointer offset (>8 bytes).
        pub fn push_mstore8_pointer(self: *FrameType, dispatch: Dispatch) Error!Success {
            const metadata = dispatch.getPointerMetadata();
            const offset = metadata.value.*;
            
            // Pop the value to store
            const value = try self.stack.pop();
            
            // Check if offset fits in usize
            if (offset > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            const offset_usize = @as(usize, @intCast(offset));
            
            // Calculate gas cost for memory expansion
            const memory_expansion_cost = self.memory.get_expansion_cost(@as(u24, @intCast(offset_usize + 1)));
            if (self.gas_remaining < GasConstants.GasFastestStep + memory_expansion_cost) {
                return Error.OutOfGas;
            }
            self.gas_remaining -= @intCast(GasConstants.GasFastestStep + memory_expansion_cost);
            
            // Store the least significant byte
            const byte_value = @as(u8, @truncate(value));
            self.memory.set_byte_evm(self.allocator, @as(u24, @intCast(offset_usize)), byte_value) catch |err| switch (err) {
                memory_mod.MemoryError.OutOfBounds => return Error.OutOfBounds,
                memory_mod.MemoryError.MemoryOverflow => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };

            const next = dispatch.skipMetadata();
            return @call(.auto, next.cursor[0].opcode_handler, .{ self, next });
        }
    };
}

// ====== TESTS ======

const testing = std.testing;
const StackFrame = @import("stack_frame.zig").StackFrame;
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

const TestFrame = StackFrame(test_config);
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

test "PUSH_MLOAD_INLINE - load from memory" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Pre-store a value at offset 32
    frame.memory.set_u256_evm(testing.allocator, 32, 0xDEADBEEF) catch unreachable;
    
    // PUSH 32 + MLOAD
    const dispatch = createInlineDispatch(32);
    _ = try TestFrame.MemorySyntheticHandlers.push_mload_inline(frame, dispatch);
    
    try testing.expectEqual(@as(u256, 0xDEADBEEF), try frame.stack.pop());
}

test "PUSH_MLOAD_INLINE - load from uninitialized memory" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // PUSH 100 + MLOAD (uninitialized memory should return 0)
    const dispatch = createInlineDispatch(100);
    _ = try TestFrame.MemorySyntheticHandlers.push_mload_inline(frame, dispatch);
    
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "PUSH_MSTORE_INLINE - store to memory" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Push value to store
    try frame.stack.push(0x1234567890ABCDEF);
    
    // PUSH 64 + MSTORE
    const dispatch = createInlineDispatch(64);
    _ = try TestFrame.MemorySyntheticHandlers.push_mstore_inline(frame, dispatch);
    
    // Verify the value was stored
    const stored = frame.memory.get_u256_evm(testing.allocator, 64) catch unreachable;
    try testing.expectEqual(@as(u256, 0x1234567890ABCDEF), stored);
}

test "PUSH_MSTORE8_INLINE - store single byte" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Push value to store (only LSB will be stored)
    try frame.stack.push(0x11FF);
    
    // PUSH 10 + MSTORE8
    const dispatch = createInlineDispatch(10);
    _ = try TestFrame.MemorySyntheticHandlers.push_mstore8_inline(frame, dispatch);
    
    // Verify only the least significant byte was stored
    const stored_byte = frame.memory.get_byte(10) catch unreachable;
    try testing.expectEqual(@as(u8, 0xFF), stored_byte);
}

test "synthetic memory - pointer variants" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test PUSH_MLOAD_POINTER
    frame.memory.set_u256_evm(1000, 0xCAFEBABE) catch unreachable;
    const load_offset: u256 = 1000;
    var dispatch = createPointerDispatch(&load_offset);
    _ = try TestFrame.MemorySyntheticHandlers.push_mload_pointer(frame, dispatch);
    try testing.expectEqual(@as(u256, 0xCAFEBABE), try frame.stack.pop());
    
    // Test PUSH_MSTORE_POINTER  
    try frame.stack.push(0xDEADBEEF);
    const store_offset: u256 = 2000;
    dispatch = createPointerDispatch(&store_offset);
    _ = try TestFrame.MemorySyntheticHandlers.push_mstore_pointer(frame, dispatch);
    const stored = frame.memory.get_u256_evm(2000) catch unreachable;
    try testing.expectEqual(@as(u256, 0xDEADBEEF), stored);
    
    // Test PUSH_MSTORE8_POINTER
    try frame.stack.push(0x12AB);
    const store8_offset: u256 = 3000;
    dispatch = createPointerDispatch(&store8_offset);
    _ = try TestFrame.MemorySyntheticHandlers.push_mstore8_pointer(frame, dispatch);
    const stored_byte = frame.memory.get_byte(3000) catch unreachable;
    try testing.expectEqual(@as(u8, 0xAB), stored_byte);
}

test "synthetic memory - gas consumption" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    frame.gas_remaining = 100_000;
    const initial_gas = frame.gas_remaining;
    
    // PUSH_MSTORE to large offset should consume more gas
    try frame.stack.push(42);
    const dispatch = createInlineDispatch(10_000);
    _ = try TestFrame.MemorySyntheticHandlers.push_mstore_inline(frame, dispatch);
    
    // Gas should be consumed for memory expansion
    try testing.expect(frame.gas_remaining < initial_gas);
    const gas_consumed = initial_gas - frame.gas_remaining;
    try testing.expect(gas_consumed > GasConstants.GasFastestStep);
}

test "synthetic memory - out of bounds" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test with offset that exceeds usize
    const huge_offset = std.math.maxInt(u256);
    const dispatch = createPointerDispatch(&huge_offset);
    const result = TestFrame.MemorySyntheticHandlers.push_mload_pointer(frame, dispatch);
    
    try testing.expectError(TestFrame.Error.OutOfBounds, result);
}