const std = @import("std");
const FrameConfig = @import("frame_config.zig").FrameConfig;
const log = @import("log.zig");
const memory_mod = @import("memory.zig");
const GasConstants = @import("primitives").GasConstants;

/// Memory operation handlers for the EVM stack frame.
/// These are generic structs that return static handlers for a given FrameType.
pub fn Handlers(comptime FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;

        /// MLOAD opcode (0x51) - Load word from memory.
        /// Pops memory offset from stack and pushes the 32-byte word at that offset.
        pub fn mload(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor, .jump_table = null };
            // MLOAD loads a 32-byte word from memory
            const offset = try self.stack.pop();

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

            // Read 32 bytes from memory (EVM-compliant with automatic expansion)
            const value_u256 = self.memory.get_u256_evm(self.allocator, @as(u24, @intCast(offset_usize))) catch |err| switch (err) {
                memory_mod.MemoryError.OutOfBounds => return Error.OutOfBounds,
                memory_mod.MemoryError.MemoryOverflow => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };

            // Convert to WordType (truncate if necessary for smaller word types)
            const value = @as(WordType, @truncate(value_u256));
            try self.stack.push(value);

            const next = dispatch.getNext();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next.cursor });
        }

        /// MSTORE opcode (0x52) - Store word to memory.
        /// Pops memory offset and value from stack, stores 32 bytes at that offset.
        pub fn mstore(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor, .jump_table = null };
            // MSTORE stores a 32-byte word to memory
            const offset = try self.stack.pop();
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

            // Convert to u256 if necessary and store
            const value_u256 = @as(u256, value);
            log.debug("MSTORE: Converting value {} (type: {s}) to u256: {}", .{ value, @typeName(@TypeOf(value)), value_u256 });
            self.memory.set_u256_evm(self.allocator, @as(u24, @intCast(offset_usize)), value_u256) catch |err| switch (err) {
                memory_mod.MemoryError.OutOfBounds => return Error.OutOfBounds,
                memory_mod.MemoryError.MemoryOverflow => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };

            log.debug("MSTORE: successfully stored value {} at offset {}", .{ value_u256, offset_usize });
            log.debug("MSTORE: Memory size after store: {}", .{self.memory.size()});

            const next = dispatch.getNext();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next.cursor });
        }

        /// MSTORE8 opcode (0x53) - Store byte to memory.
        /// Pops memory offset and value from stack, stores the least significant byte at that offset.
        pub fn mstore8(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor, .jump_table = null };
            const offset = try self.stack.pop();
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

            const next = dispatch.getNext();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next.cursor });
        }

        /// MSIZE opcode (0x59) - Get size of active memory.
        /// Pushes the size of active memory in bytes onto the stack.
        pub fn msize(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor, .jump_table = null };
            const size = self.memory.size();
            try self.stack.push(@as(WordType, @intCast(size)));

            const next = dispatch.getNext();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next.cursor });
        }

        /// MCOPY opcode (0x5e) - Memory copy operation (EIP-5656).
        /// Copies memory from one location to another.
        pub fn mcopy(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor, .jump_table = null };
            const dest_offset = try self.stack.pop();
            const src_offset = try self.stack.pop();
            const size = try self.stack.pop();

            // Check if offsets and size fit in usize
            if (dest_offset > std.math.maxInt(usize) or
                src_offset > std.math.maxInt(usize) or
                size > std.math.maxInt(usize))
            {
                return Error.OutOfBounds;
            }

            const dest_usize = @as(usize, @intCast(dest_offset));
            const src_usize = @as(usize, @intCast(src_offset));
            const size_usize = @as(usize, @intCast(size));

            if (size_usize == 0) {
                // No operation for zero size
                const next = dispatch.getNext();
                return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next.cursor });
            }

            // Calculate gas cost
            const words = (size_usize + 31) / 32;
            const copy_gas_cost = GasConstants.GasFastestStep + words * GasConstants.CopyGas;

            // Calculate memory expansion cost for both source and destination
            const src_expansion_cost = self.memory.get_expansion_cost(@as(u24, @intCast(src_usize + size_usize)));
            const dest_expansion_cost = self.memory.get_expansion_cost(@as(u24, @intCast(dest_usize + size_usize)));
            const memory_expansion_cost = @max(src_expansion_cost, dest_expansion_cost);

            const total_gas_cost = copy_gas_cost + memory_expansion_cost;
            if (self.gas_remaining < total_gas_cost) {
                return Error.OutOfGas;
            }
            self.gas_remaining -= @intCast(total_gas_cost);

            // Perform the memory copy
            // Get source data
            const src_data = self.memory.get_slice(@as(u24, @intCast(src_usize)), @as(u24, @intCast(size_usize))) catch |err| switch (err) {
                memory_mod.MemoryError.OutOfBounds => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };

            // Copy to destination
            self.memory.set_data_evm(self.allocator, @as(u24, @intCast(dest_usize)), src_data) catch |err| switch (err) {
                memory_mod.MemoryError.MemoryOverflow => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };

            const next = dispatch.getNext();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next.cursor });
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

test "MLOAD opcode - basic load" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Store a value at offset 0
    frame.memory.set_u256_evm(0, 0x1234567890ABCDEF) catch unreachable;

    // Load from offset 0
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.MemoryHandlers.mload(frame, dispatch);

    try testing.expectEqual(@as(u256, 0x1234567890ABCDEF), try frame.stack.pop());
}

test "MLOAD opcode - load from uninitialized memory" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Load from offset 64 (uninitialized, should return 0)
    try frame.stack.push(64);

    const dispatch = createMockDispatch();
    _ = try TestFrame.MemoryHandlers.mload(frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "MSTORE opcode - basic store" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Store 0xDEADBEEF at offset 32
    try frame.stack.push(32); // offset
    try frame.stack.push(0xDEADBEEF); // value

    const dispatch = createMockDispatch();
    _ = try TestFrame.MemoryHandlers.mstore(frame, dispatch);

    // Verify the value was stored
    const stored_value = frame.memory.get_u256_evm(32) catch unreachable;
    try testing.expectEqual(@as(u256, 0xDEADBEEF), stored_value);
}

test "MSTORE8 opcode - store single byte" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Store byte 0xFF at offset 0
    try frame.stack.push(0); // offset
    try frame.stack.push(0x11FF); // value (only 0xFF will be stored)

    const dispatch = createMockDispatch();
    _ = try TestFrame.MemoryHandlers.mstore8(frame, dispatch);

    // Verify only the least significant byte was stored
    const stored_byte = frame.memory.get_byte(0) catch unreachable;
    try testing.expectEqual(@as(u8, 0xFF), stored_byte);
}

test "MSIZE opcode - memory size tracking" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Initial memory size should be 0
    var dispatch = createMockDispatch();
    _ = try TestFrame.MemoryHandlers.msize(frame, dispatch);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());

    // Store at offset 31 - should expand memory to 32 bytes
    frame.memory.set_byte_evm(testing.allocator, 31, 0xFF) catch unreachable;

    dispatch = createMockDispatch();
    _ = try TestFrame.MemoryHandlers.msize(frame, dispatch);
    try testing.expectEqual(@as(u256, 32), try frame.stack.pop());

    // Store at offset 63 - should expand memory to 64 bytes
    frame.memory.set_byte_evm(testing.allocator, 63, 0xFF) catch unreachable;

    dispatch = createMockDispatch();
    _ = try TestFrame.MemoryHandlers.msize(frame, dispatch);
    try testing.expectEqual(@as(u256, 64), try frame.stack.pop());
}

test "MCOPY opcode - basic copy" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Store some data at source location
    frame.memory.set_u256_evm(0, 0x1234567890ABCDEF) catch unreachable;

    // Copy from offset 0 to offset 32, size 32 bytes
    try frame.stack.push(32); // dest
    try frame.stack.push(0); // src
    try frame.stack.push(32); // size

    const dispatch = createMockDispatch();
    _ = try TestFrame.MemoryHandlers.mcopy(frame, dispatch);

    // Verify the data was copied
    const copied_value = frame.memory.get_u256_evm(32) catch unreachable;
    try testing.expectEqual(@as(u256, 0x1234567890ABCDEF), copied_value);
}

test "MCOPY opcode - overlapping copy" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Store pattern at offset 0
    frame.memory.set_u256_evm(0, 0x1111111111111111) catch unreachable;
    frame.memory.set_u256_evm(32, 0x2222222222222222) catch unreachable;

    // Copy from offset 0 to offset 16, size 48 bytes (overlapping)
    try frame.stack.push(16); // dest
    try frame.stack.push(0); // src
    try frame.stack.push(48); // size

    const dispatch = createMockDispatch();
    _ = try TestFrame.MemoryHandlers.mcopy(frame, dispatch);

    // Check results
    const val1 = frame.memory.get_u256_evm(0) catch unreachable;
    const val2 = frame.memory.get_u256_evm(16) catch unreachable;

    try testing.expectEqual(@as(u256, 0x1111111111111111), val1);
    try testing.expectEqual(@as(u256, 0x1111111111111111), val2);
}

test "MCOPY opcode - zero size" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Copy with size 0 should be no-op
    try frame.stack.push(100); // dest
    try frame.stack.push(200); // src
    try frame.stack.push(0); // size

    const initial_msize = frame.memory.len();

    const dispatch = createMockDispatch();
    _ = try TestFrame.MemoryHandlers.mcopy(frame, dispatch);

    // Memory size should not change
    try testing.expectEqual(initial_msize, frame.memory.len());
}

test "memory operations - gas consumption" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Set initial gas
    frame.gas_remaining = 100_000;
    const initial_gas = frame.gas_remaining;

    // MLOAD from offset 0
    try frame.stack.push(0);
    var dispatch = createMockDispatch();
    _ = try TestFrame.MemoryHandlers.mload(frame, dispatch);

    // Gas should be consumed
    try testing.expect(frame.gas_remaining < initial_gas);

    // MLOAD from large offset should consume more gas due to memory expansion
    const gas_before_expansion = frame.gas_remaining;
    try frame.stack.push(10000);
    dispatch = createMockDispatch();
    _ = try TestFrame.MemoryHandlers.mload(frame, dispatch);

    const gas_consumed = gas_before_expansion - frame.gas_remaining;
    try testing.expect(gas_consumed > GasConstants.GasFastestStep);
}

test "MSTORE opcode - out of gas" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Set very low gas
    frame.gas_remaining = 1;

    // Try to store at offset that requires memory expansion
    try frame.stack.push(1000); // offset
    try frame.stack.push(42); // value

    const dispatch = createMockDispatch();
    const result = TestFrame.MemoryHandlers.mstore(frame, dispatch);

    try testing.expectError(TestFrame.Error.OutOfGas, result);
}

// ====== COMPREHENSIVE TESTS ======

// MLOAD edge cases
test "MLOAD opcode - boundary values" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test loading from various boundaries
    const test_cases = [_]struct { offset: usize, value: u256 }{
        .{ .offset = 0, .value = 0x1111111111111111 },
        .{ .offset = 31, .value = 0x2222222222222222 }, // Boundary crossing
        .{ .offset = 32, .value = 0x3333333333333333 },
        .{ .offset = 64, .value = 0x4444444444444444 },
        .{ .offset = 1024, .value = 0x5555555555555555 }, // Large offset
    };

    for (test_cases) |tc| {
        frame.memory.set_u256_evm(tc.offset, tc.value) catch unreachable;
        try frame.stack.push(tc.offset);

        const dispatch = createMockDispatch();
        _ = try TestFrame.MemoryHandlers.mload(frame, dispatch);

        const loaded = try frame.stack.pop();
        try testing.expectEqual(tc.value, loaded);
    }
}

test "MLOAD opcode - cross-boundary reads" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Set up memory with pattern
    for (0..64) |i| {
        frame.memory.set_byte_evm(testing.allocator, @as(u24, @intCast(i)), @as(u8, @truncate(i))) catch unreachable;
    }

    // Load from offset 5 (not aligned to word boundary)
    try frame.stack.push(5);

    const dispatch = createMockDispatch();
    _ = try TestFrame.MemoryHandlers.mload(frame, dispatch);

    const loaded = try frame.stack.pop();

    // Verify we loaded bytes 5-36
    var expected: u256 = 0;
    for (5..37) |i| {
        expected = (expected << 8) | @as(u256, @truncate(i));
    }
    try testing.expectEqual(expected, loaded);
}

test "MLOAD opcode - max offset" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Try to load from max offset
    try frame.stack.push(std.math.maxInt(u256));

    const dispatch = createMockDispatch();
    const result = TestFrame.MemoryHandlers.mload(frame, dispatch);

    try testing.expectError(TestFrame.Error.OutOfBounds, result);
}

test "MLOAD opcode - memory expansion tracking" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Initial memory size
    try testing.expectEqual(@as(usize, 0), frame.memory.len());

    // Load from offset 100 (should expand to 132 bytes)
    try frame.stack.push(100);

    const dispatch = createMockDispatch();
    _ = try TestFrame.MemoryHandlers.mload(frame, dispatch);

    // Memory should be expanded to next 32-byte boundary
    try testing.expectEqual(@as(usize, 128), frame.memory.len()); // 100 + 32 = 132, rounded to 128

    _ = try frame.stack.pop(); // Clear result
}

// MSTORE comprehensive tests
test "MSTORE opcode - patterns" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Store various patterns
    const patterns = [_]u256{
        0,
        std.math.maxInt(u256),
        0xDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF,
        0x0000000000000000FFFFFFFFFFFFFFFFFFFFFFFF0000000000000000FFFFFFFF,
        1,
    };

    for (patterns, 0..) |pattern, i| {
        const offset = i * 32;
        try frame.stack.push(@as(u256, offset)); // offset
        try frame.stack.push(pattern); // value

        const dispatch = createMockDispatch();
        _ = try TestFrame.MemoryHandlers.mstore(frame, dispatch);

        // Verify stored
        const stored = frame.memory.get_u256_evm(offset) catch unreachable;
        try testing.expectEqual(pattern, stored);
    }
}

test "MSTORE opcode - overwrite existing data" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Store initial value
    frame.memory.set_u256_evm(64, 0x1111111111111111) catch unreachable;

    // Overwrite with new value
    try frame.stack.push(64); // offset
    try frame.stack.push(0x2222222222222222); // value

    const dispatch = createMockDispatch();
    _ = try TestFrame.MemoryHandlers.mstore(frame, dispatch);

    // Verify overwritten
    const stored = frame.memory.get_u256_evm(64) catch unreachable;
    try testing.expectEqual(@as(u256, 0x2222222222222222), stored);
}

test "MSTORE opcode - unaligned writes" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Store at unaligned offset 13
    const value: u256 = 0xAABBCCDDEEFF00112233445566778899AABBCCDDEEFF00112233445566778899;
    try frame.stack.push(13); // offset
    try frame.stack.push(value); // value

    const dispatch = createMockDispatch();
    _ = try TestFrame.MemoryHandlers.mstore(frame, dispatch);

    // Read back and verify
    const stored = frame.memory.get_u256_evm(13) catch unreachable;
    try testing.expectEqual(value, stored);

    // Also verify no corruption of adjacent memory
    const before = frame.memory.get_u256_evm(0) catch unreachable;
    try testing.expectEqual(@as(u256, 0), before); // Should still be zero
}

// MSTORE8 comprehensive tests
test "MSTORE8 opcode - all byte values" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Store all possible byte values
    for (0..256) |i| {
        try frame.stack.push(i); // offset
        try frame.stack.push(i); // value (will be truncated to u8)

        const dispatch = createMockDispatch();
        _ = try TestFrame.MemoryHandlers.mstore8(frame, dispatch);

        const stored = frame.memory.get_byte(@as(u24, @intCast(i))) catch unreachable;
        try testing.expectEqual(@as(u8, @truncate(i)), stored);
    }
}

test "MSTORE8 opcode - truncation" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test that only least significant byte is stored
    const test_values = [_]u256{
        0x1234567890ABCDEF, // Should store 0xEF
        0xFFFFFFFFFFFFFF00, // Should store 0x00
        0x0000000000000011, // Should store 0x11
        std.math.maxInt(u256), // Should store 0xFF
    };

    for (test_values, 0..) |value, i| {
        try frame.stack.push(i * 4); // offset
        try frame.stack.push(value); // value

        const dispatch = createMockDispatch();
        _ = try TestFrame.MemoryHandlers.mstore8(frame, dispatch);

        const stored = frame.memory.get_byte(@as(u24, @intCast(i * 4))) catch unreachable;
        try testing.expectEqual(@as(u8, @truncate(value)), stored);
    }
}

test "MSTORE8 opcode - memory expansion" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Store byte at high offset
    try frame.stack.push(1000); // offset
    try frame.stack.push(0xFF); // value

    const dispatch = createMockDispatch();
    _ = try TestFrame.MemoryHandlers.mstore8(frame, dispatch);

    // Memory should expand to accommodate
    try testing.expect(frame.memory.len() >= 1001);

    // Verify byte was stored
    const stored = frame.memory.get_byte(1000) catch unreachable;
    try testing.expectEqual(@as(u8, 0xFF), stored);
}

test "MSTORE8 opcode - consecutive writes" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Write string "Hello"
    const hello = "Hello";
    for (hello, 0..) |char, i| {
        try frame.stack.push(i); // offset
        try frame.stack.push(@as(u256, char)); // value

        const dispatch = createMockDispatch();
        _ = try TestFrame.MemoryHandlers.mstore8(frame, dispatch);
    }

    // Read back and verify
    for (hello, 0..) |expected_char, i| {
        const stored = frame.memory.get_byte(@as(u24, @intCast(i))) catch unreachable;
        try testing.expectEqual(expected_char, stored);
    }
}

// MSIZE comprehensive tests
test "MSIZE opcode - growth tracking" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test various memory operations and size tracking
    const operations = [_]struct { action: enum { mload, mstore, mstore8 }, offset: usize, expected_size: usize }{
        .{ .action = .mload, .offset = 0, .expected_size = 32 },
        .{ .action = .mstore, .offset = 32, .expected_size = 64 },
        .{ .action = .mstore8, .offset = 65, .expected_size = 96 }, // Rounds to 32-byte boundary
        .{ .action = .mload, .offset = 100, .expected_size = 128 },
        .{ .action = .mstore, .offset = 1000, .expected_size = 1024 },
    };

    for (operations) |op| {
        switch (op.action) {
            .mload => {
                try frame.stack.push(op.offset);
                const dispatch = createMockDispatch();
                _ = try TestFrame.MemoryHandlers.mload(frame, dispatch);
                _ = try frame.stack.pop(); // Discard result
            },
            .mstore => {
                try frame.stack.push(op.offset);
                try frame.stack.push(0xABCD);
                const dispatch = createMockDispatch();
                _ = try TestFrame.MemoryHandlers.mstore(frame, dispatch);
            },
            .mstore8 => {
                try frame.stack.push(op.offset);
                try frame.stack.push(0xFF);
                const dispatch = createMockDispatch();
                _ = try TestFrame.MemoryHandlers.mstore8(frame, dispatch);
            },
        }

        // Check MSIZE
        const dispatch = createMockDispatch();
        _ = try TestFrame.MemoryHandlers.msize(frame, dispatch);
        const size = try frame.stack.pop();
        try testing.expectEqual(@as(u256, op.expected_size), size);
    }
}

test "MSIZE opcode - no spurious growth" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Access memory at offset 31 (should grow to 32)
    frame.memory.set_byte_evm(testing.allocator, 31, 0xFF) catch unreachable;

    // Check size multiple times - should remain constant
    for (0..5) |_| {
        const dispatch = createMockDispatch();
        _ = try TestFrame.MemoryHandlers.msize(frame, dispatch);
        const size = try frame.stack.pop();
        try testing.expectEqual(@as(u256, 32), size);
    }
}

// MCOPY comprehensive tests
test "MCOPY opcode - various sizes" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test copying different sizes
    const sizes = [_]usize{ 1, 31, 32, 33, 64, 100, 1024 };

    for (sizes) |size| {
        // Fill source with pattern
        for (0..size) |i| {
            frame.memory.set_byte_evm(testing.allocator, @as(u24, @intCast(i)), @as(u8, @truncate(i & 0xFF))) catch unreachable;
        }

        // Copy to destination at offset 2000
        try frame.stack.push(2000); // dest
        try frame.stack.push(0); // src
        try frame.stack.push(size); // size

        const dispatch = createMockDispatch();
        _ = try TestFrame.MemoryHandlers.mcopy(frame, dispatch);

        // Verify all bytes copied correctly
        for (0..size) |i| {
            const src_byte = frame.memory.get_byte(@as(u24, @intCast(i))) catch unreachable;
            const dst_byte = frame.memory.get_byte(@as(u24, @intCast(2000 + i))) catch unreachable;
            try testing.expectEqual(src_byte, dst_byte);
        }
    }
}

test "MCOPY opcode - self-overlapping forward" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Setup: [AAAA][BBBB][CCCC]
    frame.memory.set_u256_evm(0, 0xAAAAAAAA) catch unreachable;
    frame.memory.set_u256_evm(32, 0xBBBBBBBB) catch unreachable;
    frame.memory.set_u256_evm(64, 0xCCCCCCCC) catch unreachable;

    // Copy from 0 to 16 with size 64 (overlapping forward)
    try frame.stack.push(16); // dest
    try frame.stack.push(0); // src
    try frame.stack.push(64); // size

    const dispatch = createMockDispatch();
    _ = try TestFrame.MemoryHandlers.mcopy(frame, dispatch);

    // Verify correct copying with overlap
    const val0 = frame.memory.get_u256_evm(0) catch unreachable;
    const val16 = frame.memory.get_u256_evm(16) catch unreachable;
    const val32 = frame.memory.get_u256_evm(32) catch unreachable;
    const val48 = frame.memory.get_u256_evm(48) catch unreachable;

    try testing.expectEqual(@as(u256, 0xAAAAAAAA), val0);
    try testing.expectEqual(@as(u256, 0xAAAAAAAA), val16);
    try testing.expectEqual(@as(u256, 0xBBBBBBBB), val32);
    try testing.expectEqual(@as(u256, 0xBBBBBBBB), val48);
}

test "MCOPY opcode - self-overlapping backward" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Setup pattern
    frame.memory.set_u256_evm(32, 0x11111111) catch unreachable;
    frame.memory.set_u256_evm(64, 0x22222222) catch unreachable;

    // Copy from 32 to 16 with size 64 (overlapping backward)
    try frame.stack.push(16); // dest
    try frame.stack.push(32); // src
    try frame.stack.push(64); // size

    const dispatch = createMockDispatch();
    _ = try TestFrame.MemoryHandlers.mcopy(frame, dispatch);

    // Verify
    const val16 = frame.memory.get_u256_evm(16) catch unreachable;
    const val48 = frame.memory.get_u256_evm(48) catch unreachable;

    try testing.expectEqual(@as(u256, 0x11111111), val16);
    try testing.expectEqual(@as(u256, 0x22222222), val48);
}

test "MCOPY opcode - exact overlap" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Store pattern
    frame.memory.set_u256_evm(100, 0xDEADBEEF) catch unreachable;

    // Copy to same location (should be no-op)
    try frame.stack.push(100); // dest
    try frame.stack.push(100); // src
    try frame.stack.push(32); // size

    const dispatch = createMockDispatch();
    _ = try TestFrame.MemoryHandlers.mcopy(frame, dispatch);

    // Should still be same value
    const val = frame.memory.get_u256_evm(100) catch unreachable;
    try testing.expectEqual(@as(u256, 0xDEADBEEF), val);
}

test "MCOPY opcode - large copy" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Copy 10KB
    const size = 10240;

    // Fill source with pattern
    for (0..size) |i| {
        const byte = @as(u8, @truncate((i * 7 + 3) % 256));
        frame.memory.set_byte_evm(testing.allocator, @as(u24, @intCast(i)), byte) catch unreachable;
    }

    // Copy to high offset
    try frame.stack.push(50000); // dest
    try frame.stack.push(0); // src
    try frame.stack.push(size); // size

    const dispatch = createMockDispatch();
    _ = try TestFrame.MemoryHandlers.mcopy(frame, dispatch);

    // Verify first and last few bytes
    for ([_]usize{ 0, 1, 2, size - 3, size - 2, size - 1 }) |offset| {
        const src = frame.memory.get_byte(@as(u24, @intCast(offset))) catch unreachable;
        const dst = frame.memory.get_byte(@as(u24, @intCast(50000 + offset))) catch unreachable;
        try testing.expectEqual(src, dst);
    }
}

// Gas tests
test "memory operations - gas edge cases" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test gas consumption for various memory sizes
    const test_cases = [_]struct { offset: usize, size: usize }{
        .{ .offset = 0, .size = 32 }, // No expansion
        .{ .offset = 32, .size = 32 }, // Small expansion
        .{ .offset = 1024, .size = 32 }, // Medium expansion
        .{ .offset = 10000, .size = 1000 }, // Large expansion
    };

    for (test_cases) |tc| {
        frame.gas_remaining = 1_000_000; // Reset gas
        const gas_before = frame.gas_remaining;

        // MCOPY operation
        try frame.stack.push(tc.offset + tc.size * 2); // dest
        try frame.stack.push(0); // src
        try frame.stack.push(tc.size); // size

        const dispatch = createMockDispatch();
        _ = try TestFrame.MemoryHandlers.mcopy(frame, dispatch);

        const gas_used = gas_before - frame.gas_remaining;

        // Verify gas was consumed
        try testing.expect(gas_used > 0);

        // Larger operations should use more gas
        if (tc.offset > 1000) {
            try testing.expect(gas_used > 1000);
        }
    }
}

test "memory operations - out of bounds protection" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test operations at max values
    const max_tests = [_]struct {
        op: enum { mload, mstore, mstore8, mcopy },
        stack_values: []const u256,
        expect_error: bool,
    }{
        // MLOAD at max offset
        .{ .op = .mload, .stack_values = &[_]u256{std.math.maxInt(u256)}, .expect_error = true },

        // MSTORE at max offset
        .{ .op = .mstore, .stack_values = &[_]u256{ std.math.maxInt(u256), 42 }, .expect_error = true },

        // MSTORE8 at max offset
        .{ .op = .mstore8, .stack_values = &[_]u256{ std.math.maxInt(u256), 0xFF }, .expect_error = true },

        // MCOPY with max size
        .{ .op = .mcopy, .stack_values = &[_]u256{ 0, 0, std.math.maxInt(u256) }, .expect_error = true },
    };

    for (max_tests) |tc| {
        // Clear stack
        while (frame.stack.len() > 0) {
            _ = try frame.stack.pop();
        }

        // Push test values
        for (tc.stack_values) |val| {
            try frame.stack.push(val);
        }

        const dispatch = createMockDispatch();
        const result = switch (tc.op) {
            .mload => TestFrame.MemoryHandlers.mload(frame, dispatch),
            .mstore => TestFrame.MemoryHandlers.mstore(frame, dispatch),
            .mstore8 => TestFrame.MemoryHandlers.mstore8(frame, dispatch),
            .mcopy => TestFrame.MemoryHandlers.mcopy(frame, dispatch),
        };

        if (tc.expect_error) {
            try testing.expectError(TestFrame.Error.OutOfBounds, result);
        }
    }
}

test "memory operations - stack underflow" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    const dispatch = createMockDispatch();

    // Test each operation with empty stack
    const mload_result = TestFrame.MemoryHandlers.mload(frame, dispatch);
    try testing.expectError(TestFrame.Error.StackUnderflow, mload_result);

    const mstore_result = TestFrame.MemoryHandlers.mstore(frame, dispatch);
    try testing.expectError(TestFrame.Error.StackUnderflow, mstore_result);

    const mstore8_result = TestFrame.MemoryHandlers.mstore8(frame, dispatch);
    try testing.expectError(TestFrame.Error.StackUnderflow, mstore8_result);

    const mcopy_result = TestFrame.MemoryHandlers.mcopy(frame, dispatch);
    try testing.expectError(TestFrame.Error.StackUnderflow, mcopy_result);
}

test "MCOPY opcode - gas calculation" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test gas calculation for different copy sizes
    const copy_sizes = [_]usize{ 32, 64, 128, 256, 512, 1024 };

    for (copy_sizes) |size| {
        frame.gas_remaining = 100_000;
        const gas_before = frame.gas_remaining;

        try frame.stack.push(1000); // dest
        try frame.stack.push(0); // src
        try frame.stack.push(size); // size

        const dispatch = createMockDispatch();
        _ = try TestFrame.MemoryHandlers.mcopy(frame, dispatch);

        const gas_used = gas_before - frame.gas_remaining;
        const expected_words = (size + 31) / 32;
        const expected_min_gas = GasConstants.GasFastestStep + expected_words * GasConstants.CopyGas;

        // Gas used should be at least the copy cost
        try testing.expect(gas_used >= expected_min_gas);
    }
}
