const std = @import("std");
const FrameConfig = @import("frame_config.zig").FrameConfig;
const log = @import("log.zig");

/// Bitwise opcode handlers for the EVM stack frame.
/// These are generic structs that return static handlers for a given FrameType.
pub fn Handlers(comptime FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;

        /// AND opcode (0x16) - Bitwise AND operation.
        pub fn @"and"(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const b = try self.stack.pop(); // Top of stack - second operand
            const a = try self.stack.peek(); // Second from top - first operand
            self.stack.set_top_unsafe(a & b);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }

        /// OR opcode (0x17) - Bitwise OR operation.
        pub fn @"or"(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const b = try self.stack.pop(); // Top of stack - second operand
            const a = try self.stack.peek(); // Second from top - first operand
            self.stack.set_top_unsafe(a | b);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }

        /// XOR opcode (0x18) - Bitwise XOR operation.
        pub fn xor(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const b = try self.stack.pop(); // Top of stack - second operand
            const a = try self.stack.peek(); // Second from top - first operand
            self.stack.set_top_unsafe(a ^ b);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }

        /// NOT opcode (0x19) - Bitwise NOT operation.
        pub fn not(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const value = try self.stack.peek();
            self.stack.set_top_unsafe(~value);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }

        /// BYTE opcode (0x1a) - Extract byte from word.
        /// Takes byte index from stack top, value from second position.
        /// Returns the byte at that index or 0 if index >= 32.
        /// Uses std.math.shr for consistent cross-platform behavior.
        /// See: https://ziglang.org/documentation/master/std/#std.math.shr
        pub fn byte(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const byte_index = try self.stack.pop(); // Top of stack - byte index
            const value = try self.stack.peek(); // Second from top - value to extract from
            const result = if (byte_index >= 32) 0 else blk: {
                const index_usize = @as(usize, @intCast(byte_index));
                const shift_amount = (31 - index_usize) * 8;
                const ShiftType = std.math.Log2Int(WordType);
                break :blk std.math.shr(WordType, value, @as(ShiftType, @intCast(shift_amount))) & 0xFF;
            };
            self.stack.set_top_unsafe(result);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }

        /// SHL opcode (0x1b) - Shift left operation using std.math.shl for consistent behavior.
        /// See: https://ziglang.org/documentation/master/std/#std.math.shl
        pub fn shl(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const shift = try self.stack.pop(); // Top of stack - shift amount
            const value = try self.stack.peek(); // Second from top - value to shift
            const result = if (shift >= @bitSizeOf(WordType)) blk: {
                break :blk 0;
            } else blk: {
                const ShiftType = std.math.Log2Int(WordType);
                // shift is guaranteed to be < 256 here, safe to cast
                break :blk std.math.shl(WordType, value, @as(ShiftType, @truncate(shift)));
            };
            self.stack.set_top_unsafe(result);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }

        /// SHR opcode (0x1c) - Logical shift right operation using std.math.shr.
        /// See: https://ziglang.org/documentation/master/std/#std.math.shr
        pub fn shr(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const shift = try self.stack.pop(); // Top of stack - shift amount
            const value = try self.stack.peek(); // Second from top - value to shift
            const result = if (shift >= @bitSizeOf(WordType)) blk: {
                break :blk 0;
            } else blk: {
                const ShiftType = std.math.Log2Int(WordType);
                // shift is guaranteed to be < 256 here, safe to cast
                break :blk std.math.shr(WordType, value, @as(ShiftType, @truncate(shift)));
            };
            self.stack.set_top_unsafe(result);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }

        /// SAR opcode (0x1d) - Arithmetic shift right operation using std.math.shr.
        /// Preserves the sign bit during shift.
        /// See: https://ziglang.org/documentation/master/std/#std.math.shr
        pub fn sar(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const shift = try self.stack.pop(); // Top of stack - shift amount
            const value = try self.stack.peek(); // Second from top - value to shift
            const word_bits = @bitSizeOf(WordType);
            const result = if (shift >= word_bits) blk: {
                const sign_bit = std.math.shr(WordType, value, word_bits - 1);
                break :blk if (sign_bit == 1) @as(WordType, std.math.maxInt(WordType)) else @as(WordType, 0);
            } else blk: {
                const ShiftType = std.math.Log2Int(WordType);
                const shift_amount = @as(ShiftType, @truncate(shift));
                const value_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(value));
                // For signed types, right shift maintains sign bit semantics
                const result_signed = std.math.shr(std.meta.Int(.signed, @bitSizeOf(WordType)), value_signed, shift_amount);
                break :blk @as(WordType, @bitCast(result_signed));
            };
            self.stack.set_top_unsafe(result);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }
    };
}

// ====== TESTS ======

const testing = std.testing;
const Frame = @import("frame.zig").Frame;
const dispatch_mod = @import("dispatch.zig");
const NoOpTracer = @import("tracer.zig").NoOpTracer;
const bytecode_mod = @import("bytecode.zig");
const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;

// Test configuration
const test_config = FrameConfig{
    .stack_size = 1024,
    .WordType = u256,
    .max_bytecode_size = 1024,
    .block_gas_limit = 30_000_000,
    .DatabaseType = MemoryDatabase,
    .memory_initial_capacity = 4096,
    .memory_limit = 0xFFFFFF,
};

const TestFrame = Frame(test_config);
const TestBytecode = bytecode_mod.Bytecode(.{ .max_bytecode_size = test_config.max_bytecode_size });

fn createTestFrame(allocator: std.mem.Allocator) !TestFrame {
    const bytecode = TestBytecode.initEmpty();
    var db = MemoryDatabase.init();
    return try TestFrame.init(allocator, bytecode, 1_000_000, &db);
}

// Mock dispatch that simulates successful execution flow
fn createMockDispatch() TestFrame.Dispatch {
    const mock_handler = struct {
        fn handler(frame: *TestFrame, cursor: [*]const TestFrame.Dispatch.Item) TestFrame.Error!noreturn {
            _ = frame;
            _ = cursor;
            return TestFrame.Error.Stop;
        }
    }.handler;

    var cursor: [1]TestFrame.Dispatch.Item = undefined;
    cursor[0] = .{ .opcode_handler = &mock_handler };

    const empty_jump_table = TestFrame.Dispatch.JumpTable{ .entries = &[_]TestFrame.Dispatch.JumpTableEntry{} };

    return TestFrame.Dispatch{
        .cursor = &cursor,
        .jump_table = &empty_jump_table,
    };
}

test "AND opcode - basic bitwise AND" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 0xFF & 0xF0 = 0xF0
    try frame.stack.push(0xFF);
    try frame.stack.push(0xF0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.@"and"(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0xF0), try frame.stack.pop());
    try testing.expectEqual(@as(usize, 0), frame.stack.len());
}

test "OR opcode - basic bitwise OR" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 0xF0 | 0x0F = 0xFF
    try frame.stack.push(0xF0);
    try frame.stack.push(0x0F);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.@"or"(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0xFF), try frame.stack.pop());
}

test "XOR opcode - basic bitwise XOR" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 0xFF ^ 0xAA = 0x55
    try frame.stack.push(0xFF);
    try frame.stack.push(0xAA);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.xor(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0x55), try frame.stack.pop());
}

test "NOT opcode - bitwise NOT" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: ~0 = MAX_U256
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.not(&frame, dispatch.cursor);

    try testing.expectEqual(std.math.maxInt(u256), try frame.stack.pop());
}

test "NOT opcode - bitwise NOT of 1" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: ~1 = MAX_U256 - 1
    try frame.stack.push(1);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.not(&frame, dispatch.cursor);

    try testing.expectEqual(std.math.maxInt(u256) - 1, try frame.stack.pop());
}

test "BYTE opcode - extract first byte" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: byte 0 of 0xFF00000000...0 = 0xFF
    try frame.stack.push(std.math.shl(u256, @as(u256, 0xFF), 248));
    try frame.stack.push(0); // byte index

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.byte(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0xFF), try frame.stack.pop());
}

test "BYTE opcode - extract last byte" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: byte 31 of 0x...00FF = 0xFF
    try frame.stack.push(0xFF);
    try frame.stack.push(31); // byte index

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.byte(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0xFF), try frame.stack.pop());
}

test "BYTE opcode - out of bounds" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: byte 32 of any value = 0
    try frame.stack.push(0xFFFFFFFF);
    try frame.stack.push(32); // out of bounds

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.byte(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "SHL opcode - basic shift left" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 1 << 4 = 16
    try frame.stack.push(1);
    try frame.stack.push(4);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.shl(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 16), try frame.stack.pop());
}

test "SHL opcode - shift overflow" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 1 << 256 = 0 (shift >= bit size)
    try frame.stack.push(1);
    try frame.stack.push(256);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.shl(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "SHR opcode - basic shift right" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 16 >> 4 = 1
    try frame.stack.push(16);
    try frame.stack.push(4);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.shr(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "SHR opcode - shift overflow" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: MAX >> 256 = 0 (shift >= bit size)
    try frame.stack.push(std.math.maxInt(u256));
    try frame.stack.push(256);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.shr(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "SAR opcode - positive number" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 16 >> 2 = 4 (arithmetic shift preserves sign)
    try frame.stack.push(16);
    try frame.stack.push(2);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.sar(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 4), try frame.stack.pop());
}

test "SAR opcode - negative number" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: -16 >> 2 = -4 (preserves sign bit)
    // -16 in two's complement for u256
    const neg_16 = std.math.maxInt(u256) - 15;
    try frame.stack.push(neg_16);
    try frame.stack.push(2);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.sar(&frame, dispatch.cursor);

    // -4 in two's complement
    const neg_4 = std.math.maxInt(u256) - 3;
    try testing.expectEqual(neg_4, try frame.stack.pop());
}

test "SAR opcode - shift overflow negative" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: negative >> 256 = MAX (all 1s)
    const neg_1 = std.math.maxInt(u256);
    try frame.stack.push(neg_1);
    try frame.stack.push(256);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.sar(&frame, dispatch.cursor);

    try testing.expectEqual(std.math.maxInt(u256), try frame.stack.pop());
}

test "SAR opcode - shift overflow positive" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: positive >> 256 = 0
    try frame.stack.push(42);
    try frame.stack.push(256);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.sar(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// Additional comprehensive tests

test "AND opcode - with zeros" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: x & 0 = 0
    try frame.stack.push(0xDEADBEEF);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.@"and"(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "AND opcode - with max value" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: x & MAX = x
    const value = 0x123456789ABCDEF0;
    try frame.stack.push(value);
    try frame.stack.push(std.math.maxInt(u256));

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.@"and"(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, value), try frame.stack.pop());
}

test "OR opcode - with zeros" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: x | 0 = x
    const value = 0xCAFEBABE;
    try frame.stack.push(value);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.@"or"(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, value), try frame.stack.pop());
}

test "OR opcode - with max value" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: x | MAX = MAX
    try frame.stack.push(42);
    try frame.stack.push(std.math.maxInt(u256));

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.@"or"(&frame, dispatch.cursor);

    try testing.expectEqual(std.math.maxInt(u256), try frame.stack.pop());
}

test "XOR opcode - same values" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: x ^ x = 0
    const value = 0x123456789ABCDEF0;
    try frame.stack.push(value);
    try frame.stack.push(value);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.xor(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "XOR opcode - with zero" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: x ^ 0 = x
    const value = 0xDEADBEEF;
    try frame.stack.push(value);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.xor(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, value), try frame.stack.pop());
}

test "XOR opcode - with max value" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: x ^ MAX = ~x
    const value = 0x123456789ABCDEF0;
    try frame.stack.push(value);
    try frame.stack.push(std.math.maxInt(u256));

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.xor(&frame, dispatch.cursor);

    try testing.expectEqual(~value, try frame.stack.pop());
}

test "NOT opcode - max value" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: ~MAX = 0
    try frame.stack.push(std.math.maxInt(u256));

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.not(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "NOT opcode - double negation" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: ~~x = x
    const value = 0x123456789ABCDEF0;
    try frame.stack.push(value);

    var dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.not(&frame, dispatch.cursor);

    dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.not(&frame, dispatch.cursor);

    try testing.expectEqual(value, try frame.stack.pop());
}

test "BYTE opcode - extract middle byte" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: extract byte 15 (middle of 32 bytes)
    // Create value with 0xAB at byte position 15
    const value = std.math.shl(u256, @as(u256, 0xAB), (31 - 15) * 8);
    try frame.stack.push(value);
    try frame.stack.push(15);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.byte(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0xAB), try frame.stack.pop());
}

test "BYTE opcode - large index" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: byte 100 of any value = 0
    try frame.stack.push(std.math.maxInt(u256));
    try frame.stack.push(100); // way out of bounds

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.byte(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "BYTE opcode - extract from complex value" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: extract various bytes from 0x0123456789ABCDEF
    const value = @as(u256, 0x0123456789ABCDEF);

    // Extract byte 31 (least significant) = 0xEF
    try frame.stack.push(value);
    try frame.stack.push(31);
    var dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.byte(&frame, dispatch.cursor);
    try testing.expectEqual(@as(u256, 0xEF), try frame.stack.pop());

    // Extract byte 30 = 0xCD
    try frame.stack.push(value);
    try frame.stack.push(30);
    dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.byte(&frame, dispatch.cursor);
    try testing.expectEqual(@as(u256, 0xCD), try frame.stack.pop());

    // Extract byte 24 = 0x01
    try frame.stack.push(value);
    try frame.stack.push(24);
    dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.byte(&frame, dispatch.cursor);
    try testing.expectEqual(@as(u256, 0x01), try frame.stack.pop());
}

test "SHL opcode - shift by 0" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: x << 0 = x
    const value = 0x123456789ABCDEF0;
    try frame.stack.push(value);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.shl(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, value), try frame.stack.pop());
}

test "SHL opcode - large shifts" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 1 << 255 = 0x8000...000
    try frame.stack.push(1);
    try frame.stack.push(255);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.shl(&frame, dispatch.cursor);

    const expected = std.math.shl(u256, @as(u256, 1), 255);
    try testing.expectEqual(expected, try frame.stack.pop());
}

test "SHL opcode - partial overflow" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 0xFF << 252 should overflow partially
    try frame.stack.push(0xFF);
    try frame.stack.push(252);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.shl(&frame, dispatch.cursor);

    const expected = std.math.shl(u256, @as(u256, 0xF), 252);
    try testing.expectEqual(expected, try frame.stack.pop());
}

test "SHR opcode - shift by 0" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: x >> 0 = x
    const value = 0x123456789ABCDEF0;
    try frame.stack.push(value);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.shr(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, value), try frame.stack.pop());
}

test "SHR opcode - exact division by power of 2" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 256 >> 8 = 1
    try frame.stack.push(256);
    try frame.stack.push(8);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.shr(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "SAR opcode - shift by 0" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: x >> 0 = x (arithmetic)
    const neg_value = std.math.maxInt(u256) - 41; // -42
    try frame.stack.push(neg_value);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.sar(&frame, dispatch.cursor);

    try testing.expectEqual(neg_value, try frame.stack.pop());
}

test "SAR opcode - sign bit preservation" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: Ensure sign bit is preserved for negative numbers
    // -256 >> 4 = -16 (preserving sign)
    const neg_256 = std.math.maxInt(u256) - 255;
    try frame.stack.push(neg_256);
    try frame.stack.push(4);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.sar(&frame, dispatch.cursor);

    const neg_16 = std.math.maxInt(u256) - 15;
    try testing.expectEqual(neg_16, try frame.stack.pop());
}

test "SAR opcode - positive large shift" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: large positive >> 255 = 0
    const value = std.math.shl(u256, @as(u256, 1), 254) - 1; // 0x3FFF...FFF
    try frame.stack.push(value);
    try frame.stack.push(255);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.sar(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// Combination and edge case tests
test "bitwise operations - De Morgan's laws" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: ~(value1 & value2) = (~value1 | ~value2)
    const value1 = 0x123456789ABCDEF0;
    const value2 = 0xFEDCBA9876543210;

    // Calculate ~(value1 & value2)
    try frame.stack.push(value1);
    try frame.stack.push(value2);
    var dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.@"and"(&frame, dispatch.cursor);

    dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.not(&frame, dispatch.cursor);
    const left_side = try frame.stack.pop();

    // Calculate (~value1 | ~value2)
    try frame.stack.push(value1);
    dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.not(&frame, dispatch.cursor);
    const not_value1 = try frame.stack.pop();

    try frame.stack.push(value2);
    dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.not(&frame, dispatch.cursor);
    const not_value2 = try frame.stack.pop();

    try frame.stack.push(not_value1);
    try frame.stack.push(not_value2);
    dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.@"or"(&frame, dispatch.cursor);
    const right_side = try frame.stack.pop();

    try testing.expectEqual(left_side, right_side);
}

test "shift operations - round trip" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: (x << n) >> n = x (for small n)
    const value = 0x123456789ABCDEF0;
    const shift = 16;

    try frame.stack.push(value);
    try frame.stack.push(shift);

    var dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.shl(&frame, dispatch.cursor);

    try frame.stack.push(shift);
    dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.shr(&frame, dispatch.cursor);

    // Due to overflow, only lower bits are preserved
    const mask = std.math.shl(u256, @as(u256, 1), (256 - shift)) - 1;
    try testing.expectEqual(value & mask, try frame.stack.pop());
}

test "BYTE opcode - all bytes of a pattern" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: Create a pattern and extract each byte
    var value: u256 = 0;
    var i: u8 = 0;
    while (i < 32) : (i += 1) {
        value |= std.math.shl(u256, @as(u256, i), (31 - i) * 8);
    }

    // Verify each byte
    i = 0;
    while (i < 32) : (i += 1) {
        try frame.stack.push(value);
        try frame.stack.push(i);

        const dispatch = createMockDispatch();
        _ = try TestFrame.BitwiseHandlers.byte(&frame, dispatch.cursor);

        try testing.expectEqual(@as(u256, i), try frame.stack.pop());
    }
}

test "SHL opcode - edge cases with maximum value" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: MAX_U256 << 1 = MAX_U256 - 1
    const max = std.math.maxInt(u256);
    try frame.stack.push(max);
    try frame.stack.push(1);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.shl(&frame, dispatch.cursor);

    try testing.expectEqual(max - 1, try frame.stack.pop());
}

test "SHR opcode - single bit patterns" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 0x8000...000 >> 1 = 0x4000...000
    const high_bit = std.math.shl(u256, @as(u256, 1), 255);
    try frame.stack.push(high_bit);
    try frame.stack.push(1);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.shr(&frame, dispatch.cursor);

    try testing.expectEqual(std.math.shl(u256, @as(u256, 1), 254), try frame.stack.pop());
}

test "SAR opcode - boundary value (-1)" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: -1 >> any_amount = -1 (all bits set)
    const neg_1 = std.math.maxInt(u256);
    try frame.stack.push(neg_1);
    try frame.stack.push(128);

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.sar(&frame, dispatch.cursor);

    try testing.expectEqual(neg_1, try frame.stack.pop());
}

test "bitwise operations - pattern testing" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: Alternating bit patterns
    const pattern1 = std.math.shl(u256, @as(u256, 0xAAAAAAAAAAAAAAAA), 192) | std.math.shl(u256, @as(u256, 0xAAAAAAAAAAAAAAAA), 128) |
        std.math.shl(u256, @as(u256, 0xAAAAAAAAAAAAAAAA), 64) | @as(u256, 0xAAAAAAAAAAAAAAAA);
    const pattern2 = std.math.shl(u256, @as(u256, 0x5555555555555555), 192) | std.math.shl(u256, @as(u256, 0x5555555555555555), 128) |
        std.math.shl(u256, @as(u256, 0x5555555555555555), 64) | @as(u256, 0x5555555555555555);

    // Test: pattern1 XOR pattern2 = MAX
    try frame.stack.push(pattern1);
    try frame.stack.push(pattern2);
    var dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.xor(&frame, dispatch.cursor);
    try testing.expectEqual(std.math.maxInt(u256), try frame.stack.pop());

    // Test: pattern1 AND pattern2 = 0
    try frame.stack.push(pattern1);
    try frame.stack.push(pattern2);
    dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.@"and"(&frame, dispatch.cursor);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "shift operations - extreme shifts" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    const max = std.math.maxInt(u256);

    // Test: MAX << 257 = 0 (way past bit size)
    try frame.stack.push(max);
    try frame.stack.push(257);
    var dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.shl(&frame, dispatch.cursor);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());

    // Test: MAX >> 257 = 0 (way past bit size)
    try frame.stack.push(max);
    try frame.stack.push(257);
    dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.shr(&frame, dispatch.cursor);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());

    // Test: -1 >> 300 = -1 (SAR with extreme shift)
    try frame.stack.push(max);
    try frame.stack.push(300);
    dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.sar(&frame, dispatch.cursor);
    try testing.expectEqual(max, try frame.stack.pop());
}

test "BYTE opcode - maximum index values" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test with maximum u256 as index
    try frame.stack.push(0x123456789ABCDEF0);
    try frame.stack.push(std.math.maxInt(u256));

    const dispatch = createMockDispatch();
    _ = try TestFrame.BitwiseHandlers.byte(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}
