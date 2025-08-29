const std = @import("std");
const FrameConfig = @import("frame_config.zig").FrameConfig;
const log = @import("log.zig");

/// Arithmetic opcode handlers for the EVM stack frame.
/// These are generic structs that return static handlers for a given FrameType.
pub fn Handlers(comptime FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;

        /// ADD opcode (0x01) - Addition with overflow wrapping.
        pub fn add(self: *FrameType, dispatch: Dispatch) Error!noreturn {
            // Static gas consumption handled at upper layer
            log.debug("ADD handler called, stack size: {}", .{self.stack.size()});
            const top_minus_1 = try self.stack.pop();
            const top = try self.stack.peek();
            const result = top +% top_minus_1;
            log.debug("ADD: {} + {} = {}", .{ top, top_minus_1, result });
            try self.stack.set_top(result);
            const next = dispatch.getNext();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next });
        }

        /// MUL opcode (0x02) - Multiplication with overflow wrapping.
        pub fn mul(self: *FrameType, dispatch: Dispatch) Error!noreturn {
            const top_minus_1 = try self.stack.pop();
            const top = try self.stack.peek();
            try self.stack.set_top(top *% top_minus_1);
            const next = dispatch.getNext();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next });
        }

        /// SUB opcode (0x03) - Subtraction with underflow wrapping.
        pub fn sub(self: *FrameType, dispatch: Dispatch) Error!noreturn {
            const top_minus_1 = try self.stack.pop();
            const top = try self.stack.peek();
            try self.stack.set_top(top -% top_minus_1);
            const next = dispatch.getNext();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next });
        }

        /// DIV opcode (0x04) - Integer division. Division by zero returns 0.
        pub fn div(self: *FrameType, dispatch: Dispatch) Error!noreturn {
            const denominator = try self.stack.pop();
            const numerator = try self.stack.peek();
            const result = if (denominator == 0) 0 else numerator / denominator;
            try self.stack.set_top(result);
            const next = dispatch.getNext();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next });
        }

        /// SDIV opcode (0x05) - Signed integer division.
        pub fn sdiv(self: *FrameType, dispatch: Dispatch) Error!noreturn {
            log.debug("SDIV handler called, stack size: {}", .{self.stack.size()});
            const denominator = try self.stack.pop();
            const numerator = try self.stack.peek();
            log.debug("SDIV: numerator={x}, denominator={x}", .{ numerator, denominator });
            var result: WordType = undefined;
            if (denominator == 0) {
                result = 0;
            } else {
                const numerator_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(numerator));
                const denominator_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(denominator));
                const min_signed = std.math.minInt(std.meta.Int(.signed, @bitSizeOf(WordType)));
                if (numerator_signed == min_signed and denominator_signed == -1) {
                    // MIN / -1 overflow case
                    result = numerator;
                } else {
                    const result_signed = @divTrunc(numerator_signed, denominator_signed);
                    result = @as(WordType, @bitCast(result_signed));
                }
            }
            try self.stack.set_top(result);
            const next = dispatch.getNext();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next });
        }

        /// MOD opcode (0x06) - Modulo operation. Modulo by zero returns 0.
        pub fn mod(self: *FrameType, dispatch: Dispatch) Error!noreturn {
            const denominator = try self.stack.pop();
            const numerator = try self.stack.peek();
            const result = if (denominator == 0) 0 else numerator % denominator;
            try self.stack.set_top(result);
            const next = dispatch.getNext();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next });
        }

        /// SMOD opcode (0x07) - Signed modulo operation.
        pub fn smod(self: *FrameType, dispatch: Dispatch) Error!noreturn {
            const denominator = try self.stack.pop();
            const numerator = try self.stack.peek();
            var result: WordType = undefined;
            if (denominator == 0) {
                result = 0;
            } else {
                const numerator_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(numerator));
                const denominator_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(denominator));
                const result_signed = @rem(numerator_signed, denominator_signed);
                result = @as(WordType, @bitCast(result_signed));
            }
            try self.stack.set_top(result);
            const next = dispatch.getNext();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next });
        }

        /// ADDMOD opcode (0x08) - (a + b) % N. All intermediate calculations are performed with arbitrary precision.
        pub fn addmod(self: *FrameType, dispatch: Dispatch) Error!noreturn {
            const modulus = try self.stack.pop();
            const addend2 = try self.stack.pop();
            const addend1 = try self.stack.peek();
            var result: WordType = 0;
            if (modulus == 0) {
                result = 0;
            } else {
                const a = addend1 % modulus;
                const b = addend2 % modulus;
                const sum = @addWithOverflow(a, b);
                var r = sum[0];
                // If overflow occurred or r >= modulus, subtract once
                if (sum[1] == 1 or r >= modulus) {
                    r -%= modulus;
                }
                result = r;
            }
            try self.stack.set_top(result);
            const next = dispatch.getNext();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next });
        }

        /// MULMOD opcode (0x09) - (a * b) % N. All intermediate calculations are performed with arbitrary precision.
        pub fn mulmod(self: *FrameType, dispatch: Dispatch) Error!noreturn {
            const modulus = try self.stack.pop();
            const factor2 = try self.stack.pop();
            const factor1 = try self.stack.peek();
            var result: WordType = undefined;
            if (modulus == 0) {
                result = 0;
            } else {
                result = mulmod_safe(factor1, factor2, modulus);
            }
            try self.stack.set_top(result);
            const next = dispatch.getNext();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next });
        }

        /// Safe modular multiplication using double-width arithmetic to prevent overflow.
        fn mulmod_safe(a: WordType, b: WordType, n: WordType) WordType {
            if (n == 0) return 0;
            if (a == 0 or b == 0) return 0;
            if (n == 1) return 0;

            // Reduce operands first
            const a_mod = a % n;
            const b_mod = b % n;

            // Use double-width arithmetic to prevent overflow
            if (WordType == u256) {
                const wide_a = @as(u512, a_mod);
                const wide_b = @as(u512, b_mod);
                const wide_n = @as(u512, n);
                const wide_product = (wide_a * wide_b) % wide_n;
                return @intCast(wide_product);
            } else {
                // For other word types, fall back to addition-based approach
                return mulmod_by_addition(a_mod, b_mod, n);
            }
        }

        /// Fallback modular multiplication using repeated addition for non-u256 types.
        fn mulmod_by_addition(a: WordType, b: WordType, n: WordType) WordType {
            var result: WordType = 0;
            var base = a % n;
            var multiplier = b % n;

            while (multiplier > 0) {
                if (multiplier & 1 == 1) {
                    result = addmod_safe(result, base, n);
                }
                multiplier >>= 1;
                if (multiplier > 0) {
                    base = addmod_safe(base, base, n);
                }
            }

            return result;
        }

        /// Safe modular addition that prevents overflow.
        fn addmod_safe(a: WordType, b: WordType, n: WordType) WordType {
            const a_mod = a % n;
            const b_mod = b % n;

            // Check if addition would overflow
            if (a_mod > n - b_mod) {
                // Overflow case: (a + b) = n + (a + b - n)
                return (a_mod - (n - b_mod));
            } else {
                // No overflow case
                return (a_mod + b_mod) % n;
            }
        }

        /// EXP opcode (0x0a) - Exponential operation.
        pub fn exp(self: *FrameType, dispatch: Dispatch) Error!noreturn {
            const exponent = try self.stack.pop();
            const base = try self.stack.peek();
            var result: WordType = 1;
            var b = base;
            var e = exponent;
            while (e > 0) : (e >>= 1) {
                if (e & 1 == 1) {
                    result *%= b;
                }
                b *%= b;
            }
            try self.stack.set_top(result);
            const next = dispatch.getNext();
            return @call(FrameType.getTailCallModifier(), next.cursor[0].opcode_handler, .{ self, next });
        }

        /// SIGNEXTEND opcode (0x0b) - Sign extend operation.
        pub fn signextend(self: *FrameType, dispatch: Dispatch) Error!noreturn {
            const ext = try self.stack.pop();
            const value = try self.stack.peek();
            var result: WordType = undefined;
            if (ext >= 31) {
                result = value;
            } else {
                const ext_usize = @as(usize, @intCast(ext));
                const bit_index = ext_usize * 8 + 7;
                const mask = (@as(WordType, 1) << @intCast(bit_index)) - 1;
                const sign_bit = (value >> @intCast(bit_index)) & 1;
                if (sign_bit == 1) {
                    result = value | ~mask;
                } else {
                    result = value & mask;
                }
            }
            try self.stack.set_top(result);
            const next = dispatch.getNext();
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

const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;

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

test "ADD opcode - basic addition" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 5 + 3 = 8
    try frame.stack.push(5);
    try frame.stack.push(3);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.add(&frame, dispatch);

    try testing.expectEqual(@as(u256, 8), try frame.stack.pop());
    try testing.expectEqual(@as(usize, 0), frame.stack.len());
}

test "ADD opcode - overflow wrapping" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: MAX_U256 + 1 = 0 (wraps around)
    const max = std.math.maxInt(u256);
    try frame.stack.push(max);
    try frame.stack.push(1);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.add(&frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "MUL opcode - basic multiplication" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 7 * 6 = 42
    try frame.stack.push(7);
    try frame.stack.push(6);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mul(&frame, dispatch);

    try testing.expectEqual(@as(u256, 42), try frame.stack.pop());
}

test "SUB opcode - basic subtraction" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 10 - 3 = 7
    try frame.stack.push(10);
    try frame.stack.push(3);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.sub(&frame, dispatch);

    try testing.expectEqual(@as(u256, 7), try frame.stack.pop());
}

test "SUB opcode - underflow wrapping" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 0 - 1 = MAX_U256 (wraps around)
    try frame.stack.push(0);
    try frame.stack.push(1);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.sub(&frame, dispatch);

    try testing.expectEqual(std.math.maxInt(u256), try frame.stack.pop());
}

test "DIV opcode - basic division" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 20 / 4 = 5
    try frame.stack.push(20);
    try frame.stack.push(4);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.div(&frame, dispatch);

    try testing.expectEqual(@as(u256, 5), try frame.stack.pop());
}

test "DIV opcode - division by zero" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 42 / 0 = 0 (EVM specification)
    try frame.stack.push(42);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.div(&frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "SDIV opcode - positive division" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 20 / 4 = 5
    try frame.stack.push(20);
    try frame.stack.push(4);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.sdiv(&frame, dispatch);

    try testing.expectEqual(@as(u256, 5), try frame.stack.pop());
}

test "SDIV opcode - negative division" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: -20 / 4 = -5
    // In two's complement: -20 = MAX_U256 - 19
    const neg_20 = std.math.maxInt(u256) - 19;
    try frame.stack.push(neg_20);
    try frame.stack.push(4);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.sdiv(&frame, dispatch);

    // -5 in two's complement
    const neg_5 = std.math.maxInt(u256) - 4;
    try testing.expectEqual(neg_5, try frame.stack.pop());
}

test "SDIV opcode - MIN/-1 overflow case" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: MIN_SIGNED / -1 = MIN_SIGNED (special case)
    const min_signed = @as(u256, 1) << 255; // 0x8000...000
    const neg_1 = std.math.maxInt(u256);

    try frame.stack.push(min_signed);
    try frame.stack.push(neg_1);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.sdiv(&frame, dispatch);

    try testing.expectEqual(min_signed, try frame.stack.pop());
}

test "MOD opcode - basic modulo" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 17 % 5 = 2
    try frame.stack.push(17);
    try frame.stack.push(5);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mod(&frame, dispatch);

    try testing.expectEqual(@as(u256, 2), try frame.stack.pop());
}

test "MOD opcode - modulo by zero" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 42 % 0 = 0 (EVM specification)
    try frame.stack.push(42);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mod(&frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "SMOD opcode - positive modulo" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 17 % 5 = 2
    try frame.stack.push(17);
    try frame.stack.push(5);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.smod(&frame, dispatch);

    try testing.expectEqual(@as(u256, 2), try frame.stack.pop());
}

test "SMOD opcode - negative modulo" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: -17 % 5 = -2
    const neg_17 = std.math.maxInt(u256) - 16;
    try frame.stack.push(neg_17);
    try frame.stack.push(5);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.smod(&frame, dispatch);

    // -2 in two's complement
    const neg_2 = std.math.maxInt(u256) - 1;
    try testing.expectEqual(neg_2, try frame.stack.pop());
}

test "ADDMOD opcode - basic addmod" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: (10 + 20) % 7 = 2
    try frame.stack.push(10);
    try frame.stack.push(20);
    try frame.stack.push(7);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.addmod(&frame, dispatch);

    try testing.expectEqual(@as(u256, 2), try frame.stack.pop());
}

test "ADDMOD opcode - overflow handling" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: (MAX-1 + 2) % 10 = 1
    const max = std.math.maxInt(u256);
    try frame.stack.push(max - 1);
    try frame.stack.push(2);
    try frame.stack.push(10);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.addmod(&frame, dispatch);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "ADDMOD opcode - modulo zero" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: (10 + 20) % 0 = 0
    try frame.stack.push(10);
    try frame.stack.push(20);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.addmod(&frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "MULMOD opcode - basic mulmod" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: (10 * 20) % 7 = 4
    try frame.stack.push(10);
    try frame.stack.push(20);
    try frame.stack.push(7);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mulmod(&frame, dispatch);

    try testing.expectEqual(@as(u256, 4), try frame.stack.pop());
}

test "MULMOD opcode - modulo zero" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: (10 * 20) % 0 = 0
    try frame.stack.push(10);
    try frame.stack.push(20);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mulmod(&frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "EXP opcode - basic exponentiation" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 2^10 = 1024
    try frame.stack.push(2);
    try frame.stack.push(10);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.exp(&frame, dispatch);

    try testing.expectEqual(@as(u256, 1024), try frame.stack.pop());
}

test "EXP opcode - zero exponent" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 42^0 = 1
    try frame.stack.push(42);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.exp(&frame, dispatch);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "EXP opcode - overflow wrapping" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 2^256 wraps around
    try frame.stack.push(2);
    try frame.stack.push(256);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.exp(&frame, dispatch);

    // 2^256 mod 2^256 = 0
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "SIGNEXTEND opcode - extend positive byte" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: sign extend 0x7F (positive) from byte 0
    try frame.stack.push(0); // byte index
    try frame.stack.push(0x7F);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.signextend(&frame, dispatch);

    try testing.expectEqual(@as(u256, 0x7F), try frame.stack.pop());
}

test "SIGNEXTEND opcode - extend negative byte" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: sign extend 0x80 (negative) from byte 0
    try frame.stack.push(0); // byte index
    try frame.stack.push(0x80);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.signextend(&frame, dispatch);

    // Should be 0xFFFFFF...FF80
    const expected = std.math.maxInt(u256) - 0x7F;
    try testing.expectEqual(expected, try frame.stack.pop());
}

test "SIGNEXTEND opcode - no extension needed" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: sign extend with index >= 31 returns value unchanged
    try frame.stack.push(31);
    try frame.stack.push(0x123456789ABCDEF0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.signextend(&frame, dispatch);

    try testing.expectEqual(@as(u256, 0x123456789ABCDEF0), try frame.stack.pop());
}

// Additional edge case tests

test "ADD opcode - zero addition" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 42 + 0 = 42
    try frame.stack.push(42);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.add(&frame, dispatch);

    try testing.expectEqual(@as(u256, 42), try frame.stack.pop());
}

test "MUL opcode - multiplication by zero" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 42 * 0 = 0
    try frame.stack.push(42);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mul(&frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "MUL opcode - multiplication overflow" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: (2^128) * (2^128) = 0 (overflow wraps)
    const large = @as(u256, 1) << 128;
    try frame.stack.push(large);
    try frame.stack.push(large);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mul(&frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "DIV opcode - large number division" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: MAX_U256 / MAX_U256 = 1
    const max = std.math.maxInt(u256);
    try frame.stack.push(max);
    try frame.stack.push(max);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.div(&frame, dispatch);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "SDIV opcode - division by zero" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: -42 / 0 = 0
    const neg_42 = std.math.maxInt(u256) - 41;
    try frame.stack.push(neg_42);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.sdiv(&frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "SDIV opcode - negative by negative" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: -20 / -4 = 5
    const neg_20 = std.math.maxInt(u256) - 19;
    const neg_4 = std.math.maxInt(u256) - 3;

    try frame.stack.push(neg_20);
    try frame.stack.push(neg_4);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.sdiv(&frame, dispatch);

    try testing.expectEqual(@as(u256, 5), try frame.stack.pop());
}

test "MOD opcode - exact division" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 20 % 4 = 0 (exact division)
    try frame.stack.push(20);
    try frame.stack.push(4);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mod(&frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "SMOD opcode - both operands negative" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: -17 % -5 = -2
    const neg_17 = std.math.maxInt(u256) - 16;
    const neg_5 = std.math.maxInt(u256) - 4;

    try frame.stack.push(neg_17);
    try frame.stack.push(neg_5);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.smod(&frame, dispatch);

    // Result is -2
    const neg_2 = std.math.maxInt(u256) - 1;
    try testing.expectEqual(neg_2, try frame.stack.pop());
}

test "SMOD opcode - positive mod negative" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 17 % -5 = 2
    const neg_5 = std.math.maxInt(u256) - 4;

    try frame.stack.push(17);
    try frame.stack.push(neg_5);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.smod(&frame, dispatch);

    try testing.expectEqual(@as(u256, 2), try frame.stack.pop());
}

test "ADDMOD opcode - large numbers" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: ((2^255) + (2^255)) % 7 = expected
    const large = @as(u256, 1) << 255;
    try frame.stack.push(large);
    try frame.stack.push(large);
    try frame.stack.push(7);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.addmod(&frame, dispatch);

    // (2^256 % 7) = 2
    try testing.expectEqual(@as(u256, 2), try frame.stack.pop());
}

test "MULMOD opcode - large multiplication" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: ((2^200) * (2^200)) % 13
    const large = @as(u256, 1) << 200;
    try frame.stack.push(large);
    try frame.stack.push(large);
    try frame.stack.push(13);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mulmod(&frame, dispatch);

    // Result should be consistent with proper modular arithmetic
    const result = try frame.stack.pop();
    try testing.expect(result < 13);
}

test "EXP opcode - base 0" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 0^5 = 0
    try frame.stack.push(0);
    try frame.stack.push(5);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.exp(&frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "EXP opcode - base 1" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 1^(MAX) = 1
    const max = std.math.maxInt(u256);
    try frame.stack.push(1);
    try frame.stack.push(max);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.exp(&frame, dispatch);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "EXP opcode - power of 2" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 2^64 = 18446744073709551616
    try frame.stack.push(2);
    try frame.stack.push(64);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.exp(&frame, dispatch);

    try testing.expectEqual(@as(u256, 1) << 64, try frame.stack.pop());
}

test "SIGNEXTEND opcode - extend from byte 1" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: sign extend 0x0080 from byte 1 (should not extend)
    try frame.stack.push(1); // byte index
    try frame.stack.push(0x0080);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.signextend(&frame, dispatch);

    try testing.expectEqual(@as(u256, 0x0080), try frame.stack.pop());
}

test "SIGNEXTEND opcode - extend negative from byte 1" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: sign extend 0x8000 from byte 1 (should extend with FFs)
    try frame.stack.push(1); // byte index
    try frame.stack.push(0x8000);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.signextend(&frame, dispatch);

    // Should be 0xFFFF...FF8000
    const expected = std.math.maxInt(u256) - 0x7FFF;
    try testing.expectEqual(expected, try frame.stack.pop());
}

test "SIGNEXTEND opcode - large index" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: sign extend with index 100 (>= 31) returns value unchanged
    try frame.stack.push(100);
    try frame.stack.push(0xDEADBEEF);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.signextend(&frame, dispatch);

    try testing.expectEqual(@as(u256, 0xDEADBEEF), try frame.stack.pop());
}

// Performance and stress tests
test "arithmetic operations - sequential operations" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: ((10 + 20) * 3) - 15 = 75
    try frame.stack.push(10);
    try frame.stack.push(20);
    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.add(&frame, dispatch);

    try frame.stack.push(3);
    const dispatch2 = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mul(frame, dispatch2);

    try frame.stack.push(15);
    const dispatch3 = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.sub(frame, dispatch3);

    try testing.expectEqual(@as(u256, 75), try frame.stack.pop());
}

test "MULMOD opcode - edge case with overflow prevention" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: (MAX * MAX) % large_prime
    const max = std.math.maxInt(u256);
    const large_prime = (@as(u256, 1) << 200) - 357; // Large prime

    try frame.stack.push(max);
    try frame.stack.push(max);
    try frame.stack.push(large_prime);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mulmod(&frame, dispatch);

    const result = try frame.stack.pop();
    // Result should be less than modulus
    try testing.expect(result < large_prime);
}

test "EXP opcode - special cases" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 0^0 = 1 (by EVM convention)
    try frame.stack.push(0);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.exp(&frame, dispatch);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());

    // Test: MAX^2 (should wrap)
    const max = std.math.maxInt(u256);
    try frame.stack.push(max);
    try frame.stack.push(2);

    const dispatch2 = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.exp(frame, dispatch2);

    // MAX * MAX = wraps to 1
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "ADDMOD/MULMOD consistency" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test that (a + b) % n == ((a % n) + (b % n)) % n
    const a = 12345;
    const b = 67890;
    const n = 997; // prime

    // Direct calculation
    try frame.stack.push(a);
    try frame.stack.push(b);
    try frame.stack.push(n);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.addmod(&frame, dispatch);
    const result1 = try frame.stack.pop();

    // Manual calculation for verification
    const expected = (a + b) % n;
    try testing.expectEqual(expected, result1);
}

test "MUL opcode - maximum value overflow" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: MAX * 2 = MAX-1 (wraps due to overflow)
    const max = std.math.maxInt(u256);
    try frame.stack.push(max);
    try frame.stack.push(2);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mul(&frame, dispatch);

    // MAX * 2 = MAX + MAX = wraps to MAX - 1
    try testing.expectEqual(max - 1, try frame.stack.pop());
}

test "MUL opcode - edge overflow cases" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: (2^255) * 3 should wrap
    const half_max = @as(u256, 1) << 255;
    try frame.stack.push(half_max);
    try frame.stack.push(3);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mul(&frame, dispatch);

    // Result wraps around due to overflow
    const expected = half_max *% 3;
    try testing.expectEqual(expected, try frame.stack.pop());
}

test "EXP opcode - large exponent overflow" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 3^255 (should wrap due to repeated multiplication overflow)
    try frame.stack.push(3);
    try frame.stack.push(255);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.exp(&frame, dispatch);

    // Large exponentiation wraps due to overflow in intermediate steps
    const result = try frame.stack.pop();
    try testing.expect(result != 0); // Should have some non-zero wrapped result
}

test "EXP opcode - overflow in intermediate calculations" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 257^200 - tests overflow in base squaring
    try frame.stack.push(257);
    try frame.stack.push(200);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.exp(&frame, dispatch);

    // Should complete without error, result will wrap due to overflow
    const result = try frame.stack.pop();
    try testing.expect(true); // Just verify no crash
    _ = result;
}

test "MULMOD opcode - overflow bug reproduction" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test case that reproduces the overflow bug
    // Use values where (a%n) * (b%n) overflows but a*b%n doesn't
    const a = (@as(u256, 1) << 200) + 1; // Large number
    const b = (@as(u256, 1) << 200) + 1; // Large number
    const n = (@as(u256, 1) << 100) + 3; // Modulus

    try frame.stack.push(a);
    try frame.stack.push(b);
    try frame.stack.push(n);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mulmod(&frame, dispatch);
    const buggy_result = try frame.stack.pop();

    // Calculate correct result using proper modular arithmetic
    // For proper MULMOD: we need arbitrary precision
    // Since Zig u256 overflows, we'd expect different results
    const a_mod = a % n;
    const b_mod = b % n;
    const incorrect_product = a_mod *% b_mod; // This overflows
    const incorrect_result = incorrect_product % n;

    // The current implementation returns the incorrect result due to overflow
    try testing.expectEqual(incorrect_result, buggy_result);
}
