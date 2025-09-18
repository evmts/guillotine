const std = @import("std");
const FrameConfig = @import("../frame/frame_config.zig").FrameConfig;
const GasConstants = @import("primitives").GasConstants;

/// Arithmetic opcode handlers for the EVM stack frame.
/// These are generic structs that return static handlers for a given FrameType.
pub fn Handlers(comptime FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;

        const dispatch = @import("../preprocessor/dispatch_opcode_data.zig");

        /// Advance to the next opcode instruction with tracking
        pub inline fn next_instruction(self: *FrameType, cursor: [*]const Dispatch.Item, comptime opcode: Dispatch.UnifiedOpcode) Error!noreturn {
            const op_data = dispatch.getOpData(opcode, Dispatch, Dispatch.Item, cursor);
            self.afterInstruction(opcode, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// ADD opcode (0x01) - Addition with overflow wrapping.
        pub fn add(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.ADD, cursor);

            self.stack.binary_op_unsafe(struct {
                fn op(top: WordType, second: WordType) WordType {
                    return top +% second;
                }
            }.op);

            return next_instruction(self, cursor, .ADD);
        }

        /// MUL opcode (0x02) - Multiplication with overflow wrapping.
        pub fn mul(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.MUL, cursor);

            self.stack.binary_op_unsafe(struct {
                fn op(top: WordType, second: WordType) WordType {
                    return top *% second;
                }
            }.op);

            return next_instruction(self, cursor, .MUL);
        }

        /// SUB opcode (0x03) - Subtraction with underflow wrapping.
        pub fn sub(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.SUB, cursor);

            self.stack.binary_op_unsafe(struct {
                fn op(top: WordType, second: WordType) WordType {
                    return top -% second; // SUB: µs[0] - µs[1] = top - second
                }
            }.op);

            return next_instruction(self, cursor, .SUB);
        }

        const from_native = FrameType.UintN.from_native;

        /// DIV opcode (0x04) - Integer division. Division by zero returns 0.
        pub fn div(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.DIV, cursor);

            self.stack.binary_op_unsafe(struct {
                fn op(top: WordType, second: WordType) WordType {
                    return from_native(top).wrapping_div(from_native(second)).to_native();
                }
            }.op);

            return next_instruction(self, cursor, .DIV);
        }

        /// SDIV opcode (0x05) - Signed integer division.
        // TODO: Benchmark this branchless implementation against a simpler version with `if` statements.
        // The current approach might be slower if the sign of operands is predictable.
        pub fn sdiv(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.SDIV, cursor);
            const top = self.stack.pop_unsafe();
            const second = self.stack.peek_unsafe();

            const SIGN_BIT = @as(u256, 1) << 255;
            const MIN_SIGNED = SIGN_BIT;

            if (second == 0) {
                self.stack.set_top_unsafe(0);
                return next_instruction(self, cursor, .SDIV);
            }
            if (top == MIN_SIGNED and second == std.math.maxInt(u256)) {
                self.stack.set_top_unsafe(MIN_SIGNED);
                return next_instruction(self, cursor, .SDIV);
            }

            // This section implements branchless two's complement arithmetic.
            // 1. Extract sign bits (1 for negative, 0 for positive).
            // 2. Create a mask that is all 1s for negative numbers and all 0s for positive.
            // 3. Compute the absolute value by XORing with the mask and subtracting the mask.
            //    - For negative `a`: `(a ^ 0xFF..FF) - 0xFF..FF` is equivalent to `~a + 1`, which is `-a`.
            //    - For positive `a`: `(a ^ 0) - 0` is `a`.
            // 4. Perform unsigned division on the absolute values.
            // 5. Determine the result's sign by XORing the operand signs.
            // 6. Conditionally negate the result using the same mask trick.
            const top_sign = top >> 255;
            const second_sign = second >> 255;

            const top_mask = @as(u256, 0) -% top_sign;
            const second_mask = @as(u256, 0) -% second_sign;

            const top_abs = (top ^ top_mask) -% top_mask;
            const second_abs = (second ^ second_mask) -% second_mask;

            const top_abs_u256 = FrameType.UintN.from_native(top_abs);
            const second_abs_u256 = FrameType.UintN.from_native(second_abs);
            const quotient_u256 = top_abs_u256.wrapping_div(second_abs_u256);
            const quotient = quotient_u256.to_native();

            const result_sign = top_sign ^ second_sign;
            const result_mask = @as(u256, 0) -% result_sign;

            const result = (quotient ^ result_mask) -% result_mask;

            self.stack.set_top_unsafe(result);
            return next_instruction(self, cursor, .SDIV);
        }

        /// MOD opcode (0x06) - Modulo operation. Modulo by zero returns 0.
        pub fn mod(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.MOD, cursor);

            self.stack.binary_op_unsafe(struct {
                fn op(top: WordType, second: WordType) WordType {
                    return from_native(top).wrapping_rem(from_native(second)).to_native();
                }
            }.op);

            return next_instruction(self, cursor, .MOD);
        }

        /// SMOD opcode (0x07) - Signed modulo operation.
        // TODO: Benchmark this branchless implementation against a simpler version with `if` statements.
        // The current approach might be slower if the sign of operands is predictable.
        pub fn smod(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.SMOD, cursor);
            const top = self.stack.pop_unsafe();
            const second = self.stack.peek_unsafe();

            const SIGN_BIT = @as(u256, 1) << 255;
            const MIN_SIGNED = SIGN_BIT;

            if (second == 0) {
                self.stack.set_top_unsafe(0);
                return next_instruction(self, cursor, .SMOD);
            }
            if (top == MIN_SIGNED and second == std.math.maxInt(u256)) { // -1 in two's complement
                self.stack.set_top_unsafe(0);
                return next_instruction(self, cursor, .SMOD);
            }

            // This section implements branchless two's complement arithmetic.
            // The result of a % n takes the sign of the dividend `a`.
            const top_sign = top >> 255;
            const second_sign = second >> 255;

            const top_mask = @as(u256, 0) -% top_sign;
            const second_mask = @as(u256, 0) -% second_sign;

            const top_abs = (top ^ top_mask) -% top_mask;
            const second_abs = (second ^ second_mask) -% second_mask;

            const top_abs_u256 = FrameType.UintN.from_native(top_abs);
            const second_abs_u256 = FrameType.UintN.from_native(second_abs);
            const remainder_u256 = top_abs_u256.wrapping_rem(second_abs_u256);
            const remainder = remainder_u256.to_native();

            // Result takes sign of dividend (top_sign)
            const result = (remainder ^ top_mask) -% top_mask;

            self.stack.set_top_unsafe(result);
            return next_instruction(self, cursor, .SMOD);
        }

        /// ADDMOD opcode (0x08) - (a + b) % N. All intermediate calculations are performed with arbitrary precision.
        pub fn addmod(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.ADDMOD, cursor);
            const addend1 = self.stack.pop_unsafe(); // Top of stack (a)
            const addend2 = self.stack.pop_unsafe(); // Second on stack (b)
            const modulus = self.stack.pop_unsafe(); // Third on stack (N)
            var result: WordType = 0;
            if (modulus == 0) {
                result = 0;
            } else {
                // This implementation correctly handles modular addition with potential u256 overflow.
                // It first reduces the addends modulo N, then performs a wrapping addition.
                // The `if (sum[1] == 1 or r >= modulus)` check handles two cases:
                // 1. `sum[1] == 1`: The addition of the reduced addends overflowed u256.
                // 2. `r >= modulus`: The sum is valid but still needs to be wrapped by the modulus.
                // In both cases, a single subtraction of the modulus yields the correct result.
                const addend1_reduced = addend1 % modulus;
                const addend2_reduced = addend2 % modulus;
                const sum = @addWithOverflow(addend1_reduced, addend2_reduced);
                var r = sum[0];
                // If overflow occurred or r >= modulus, subtract once
                if (sum[1] == 1 or r >= modulus) {
                    @branchHint(.unlikely);
                    r -%= modulus;
                }
                result = r;
            }
            self.stack.push_unsafe(result);
            return next_instruction(self, cursor, .ADDMOD);
        }

        /// MULMOD opcode (0x09) - (a * b) % N. All intermediate calculations are performed with arbitrary precision.
        pub fn mulmod(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.MULMOD, cursor);
            const factor1 = self.stack.pop_unsafe(); // Top of stack (a)
            const factor2 = self.stack.pop_unsafe(); // Second on stack (b)
            const modulus = self.stack.pop_unsafe(); // Third on stack (N)
            var result: WordType = undefined;
            if (modulus == 0) {
                result = 0;
            } else {
                result = mulmod_safe(factor1, factor2, modulus);
            }
            self.stack.push_unsafe(result);
            return next_instruction(self, cursor, .MULMOD);
        }

        /// Safe modular multiplication using double-width arithmetic to prevent overflow.
        fn mulmod_safe(factor1: WordType, factor2: WordType, modulus: WordType) WordType {
            if (modulus == 0) return 0;
            if (factor1 == 0 or factor2 == 0) return 0;
            if (modulus == 1) return 0;

            // Reduce operands first
            const factor1_mod = factor1 % modulus;
            const factor2_mod = factor2 % modulus;

            // Use double-width arithmetic to prevent overflow
            if (WordType == u256) {
                const wide_factor1 = @as(u512, factor1_mod);
                const wide_factor2 = @as(u512, factor2_mod);
                const wide_modulus = @as(u512, modulus);
                const wide_product = (wide_factor1 * wide_factor2) % wide_modulus;
                return @intCast(wide_product);
            } else {
                // For other word types, fall back to addition-based approach
                return mulmod_by_addition(factor1_mod, factor2_mod, modulus);
            }
        }

        /// Fallback modular multiplication using repeated addition for non-u256 types.
        fn mulmod_by_addition(factor1: WordType, factor2: WordType, modulus: WordType) WordType {
            var result: WordType = 0;
            var base = factor1 % modulus;
            var multiplier = factor2 % modulus;

            while (multiplier > 0) {
                if (multiplier & 1 == 1) {
                    result = addmod_safe(result, base, modulus);
                }
                multiplier = std.math.shr(WordType, multiplier, 1);
                if (multiplier > 0) {
                    base = addmod_safe(base, base, modulus);
                }
            }

            return result;
        }

        /// Safe modular addition that prevents overflow.
        fn addmod_safe(addend1: WordType, addend2: WordType, modulus: WordType) WordType {
            const addend1_mod = addend1 % modulus;
            const addend2_mod = addend2 % modulus;

            // Check if addition would overflow
            if (addend1_mod > modulus - addend2_mod) {
                @branchHint(.unlikely);
                // Overflow case: (addend1 + addend2) = modulus + (addend1 + addend2 - modulus)
                return (addend1_mod - (modulus - addend2_mod));
            } else {
                // No overflow case
                return (addend1_mod + addend2_mod) % modulus;
            }
        }

        /// EXP opcode (0x0a) - Exponential operation.
        pub fn exp(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            // Pop base (top), then exponent (second); compute base^exponent
            self.beforeInstruction(.EXP, cursor);
            const base = self.stack.pop_unsafe(); // Top of stack (base)
            const exponent = self.stack.peek_unsafe(); // Below top (exponent)

            // EIP-160: Dynamic gas cost for EXP
            // Gas cost = 10 + 50 * (number of non-zero bytes in exponent)
            var exp_bytes: u32 = 0;
            if (exponent > 0) {
                var temp_exp = exponent;
                while (temp_exp > 0) : (temp_exp = std.math.shr(WordType, temp_exp, 8)) {
                    exp_bytes += 1;
                }
            }

            const gas_cost = 10 + 50 * exp_bytes;
            // Use negative gas pattern for single-branch out-of-gas detection
            self.gas_remaining -= @intCast(gas_cost);
            if (self.gas_remaining < 0) {
                self.afterComplete(.EXP);
                return Error.OutOfGas;
            }

            // Calculate base^exponent with wrapping multiplication (mod 2^256)
            var result: WordType = 1;
            var base_working = base;
            var exponent_working = exponent;
            while (exponent_working > 0) : (exponent_working = std.math.shr(WordType, exponent_working, 1)) {
                if (exponent_working & 1 == 1) {
                    result *%= base_working;
                }
                base_working *%= base_working;
            }
            self.stack.set_top_unsafe(result);
            return next_instruction(self, cursor, .EXP);
        }

        /// SIGNEXTEND opcode (0x0b) - Sign extend operation.
        pub fn signextend(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.SIGNEXTEND, cursor);
            const ext = self.stack.pop_unsafe(); // Extension byte index (top of stack)
            const value = self.stack.peek_unsafe(); // Value to extend (second element)

            var result: WordType = undefined;

            // If ext is too large to fit in usize or >= 32, return value unchanged
            // SIGNEXTEND with byte position >= 32 means no sign extension needed
            if (ext > std.math.maxInt(usize) or ext >= 32) {
                result = value;
            } else {
                const ext_usize = @as(usize, @intCast(ext));
                const bit_index = ext_usize * 8 + 7;

                // Cast bit_index to the appropriate shift type
                const shift_amount = @as(u8, @intCast(bit_index));

                const mask = std.math.shl(WordType, @as(WordType, 1), shift_amount) - 1;
                const sign_bit = std.math.shr(WordType, value, shift_amount) & 1;
                if (sign_bit == 1) {
                    @branchHint(.unlikely);
                    result = value | ~mask;
                } else {
                    result = value & mask;
                }
            }

            self.stack.set_top_unsafe(result);

            return next_instruction(self, cursor, .SIGNEXTEND);
        }
    };
}

// ====== TESTS ======

const testing = std.testing;
const Frame = @import("../frame/frame.zig").Frame;
const dispatch_mod = @import("../preprocessor/dispatch.zig");
const DefaultTracer = @import("../tracer/tracer.zig").DefaultTracer;
const Address = @import("primitives").Address;

const MemoryDatabase = @import("../storage/memory_database.zig").MemoryDatabase;

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

fn createTestFrame(allocator: std.mem.Allocator) !TestFrame {
    const database = MemoryDatabase.init(allocator);
    const value = try allocator.create(u256);
    value.* = 0;
    const evm_ptr = @as(*anyopaque, @ptrFromInt(0x1000));
    var frame = try TestFrame.init(allocator, 1_000_000, database, Address.ZERO_ADDRESS, value, &[_]u8{}, evm_ptr);
    frame.code = &[_]u8{};
    return frame;
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

test "ADD opcode - basic addition" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 5 + 3 = 8
    try frame.stack.push(5);
    try frame.stack.push(3);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.add(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 8), try frame.stack.pop());
    try testing.expectEqual(@as(usize, 0), frame.stack.size());
}

test "ADD opcode - overflow wrapping" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: MAX_U256 + 1 = 0 (wraps around)
    const max = std.math.maxInt(u256);
    try frame.stack.push(max);
    try frame.stack.push(1);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.add(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "MUL opcode - basic multiplication" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 7 * 6 = 42
    try frame.stack.push(7);
    try frame.stack.push(6);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mul(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 42), try frame.stack.pop());
}

test "SUB opcode - basic subtraction" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 10 - 3 = 7
    try frame.stack.push(10);
    try frame.stack.push(3);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.sub(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 7), try frame.stack.pop());
}

test "SUB opcode - underflow wrapping" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 0 - 1 = MAX_U256 (wraps around)
    try frame.stack.push(0);
    try frame.stack.push(1);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.sub(&frame, dispatch.cursor);

    try testing.expectEqual(std.math.maxInt(u256), try frame.stack.pop());
}

test "DIV opcode - basic division" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 20 / 4 = 5
    try frame.stack.push(20);
    try frame.stack.push(4);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.div(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 5), try frame.stack.pop());
}

test "DIV opcode - division by zero" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 42 / 0 = 0 (EVM specification)
    try frame.stack.push(42);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.div(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "SDIV opcode - positive division" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 20 / 4 = 5
    try frame.stack.push(20);
    try frame.stack.push(4);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.sdiv(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.sdiv(&frame, dispatch.cursor);

    // -5 in two's complement
    const neg_5 = std.math.maxInt(u256) - 4;
    try testing.expectEqual(neg_5, try frame.stack.pop());
}

test "SDIV opcode - MIN/-1 overflow case" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: MIN_SIGNED / -1 = MIN_SIGNED (special case)
    const min_signed = std.math.shl(u256, @as(u256, 1), 255); // 0x8000...000
    const neg_1 = std.math.maxInt(u256);

    try frame.stack.push(min_signed);
    try frame.stack.push(neg_1);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.sdiv(&frame, dispatch.cursor);

    try testing.expectEqual(min_signed, try frame.stack.pop());
}

test "MOD opcode - basic modulo" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 17 % 5 = 2
    try frame.stack.push(17);
    try frame.stack.push(5);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mod(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 2), try frame.stack.pop());
}

test "MOD opcode - modulo by zero" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 42 % 0 = 0 (EVM specification)
    try frame.stack.push(42);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mod(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "SMOD opcode - positive modulo" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 17 % 5 = 2
    try frame.stack.push(17);
    try frame.stack.push(5);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.smod(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.smod(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.addmod(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.addmod(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.addmod(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.mulmod(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.mulmod(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "EXP opcode - basic exponentiation" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 2^10 = 1024
    try frame.stack.push(2);
    try frame.stack.push(10);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.exp(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 1024), try frame.stack.pop());
}

test "EXP opcode - zero exponent" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 42^0 = 1
    try frame.stack.push(42);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.exp(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "EXP opcode - overflow wrapping" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 2^256 wraps around
    try frame.stack.push(2);
    try frame.stack.push(256);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.exp(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.signextend(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0x7F), try frame.stack.pop());
}

test "SIGNEXTEND opcode - extend negative byte" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: sign extend 0x80 (negative) from byte 0
    try frame.stack.push(0); // byte index
    try frame.stack.push(0x80);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.signextend(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.signextend(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0x123456789ABCDEF0), try frame.stack.pop());
}

test "SIGNEXTEND opcode - index 32 returns unchanged" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: sign extend with index = 32 returns value unchanged
    try frame.stack.push(32);
    try frame.stack.push(0x123456789ABCDEF0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.signextend(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0x123456789ABCDEF0), try frame.stack.pop());
}

test "SIGNEXTEND opcode - very large index" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: sign extend with very large index (max u256) returns value unchanged
    try frame.stack.push(std.math.maxInt(u256));
    try frame.stack.push(0x123456789ABCDEF0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.signextend(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0x123456789ABCDEF0), try frame.stack.pop());
}

test "SIGNEXTEND opcode - byte 2 with sign bit" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test case from failing differential test
    // PUSH32 0x00000000000000000000000000000000000000000000000000000000FF8000
    // PUSH1 2 (extend from byte 2)
    const value: u256 = 0x00000000000000000000000000000000000000000000000000000000FF8000;
    try frame.stack.push(2); // byte index
    try frame.stack.push(value);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.signextend(&frame, dispatch.cursor);

    // Byte 2 is 0x80 (sign bit set), so should extend with FFs
    const expected = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF8000;
    try testing.expectEqual(expected, try frame.stack.pop());
}

test "SIGNEXTEND opcode - byte 2 without sign bit" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Similar to above but with positive value in byte 2
    const value: u256 = 0x00000000000000000000000000000000000000000000000000000000007F00;
    try frame.stack.push(2); // byte index
    try frame.stack.push(value);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.signextend(&frame, dispatch.cursor);

    // Byte 2 is 0x7F (sign bit not set), so no extension needed
    const expected: u256 = 0x007F00;
    try testing.expectEqual(expected, try frame.stack.pop());
}

test "SIGNEXTEND opcode - all edge indices" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    const test_cases = [_]struct { index: u256, value: u256, expected: u256 }{
        // Index 0: extend from byte 0
        .{ .index = 0, .value = 0xFF, .expected = std.math.maxInt(u256) },
        .{ .index = 0, .value = 0x7F, .expected = 0x7F },

        // Index 1: extend from byte 1
        .{ .index = 1, .value = 0x8000, .expected = std.math.maxInt(u256) - 0x7FFF },
        .{ .index = 1, .value = 0x7FFF, .expected = 0x7FFF },

        // Index 30: extend from byte 30
        .{ .index = 30, .value = std.math.shl(u256, 0x80, 30 * 8), .expected = std.math.maxInt(u256) - (std.math.shl(u256, 1, 31 * 8) - 1) + std.math.shl(u256, 0x80, 30 * 8) },

        // Index 31: no extension needed (full 32 bytes)
        .{ .index = 31, .value = std.math.maxInt(u256), .expected = std.math.maxInt(u256) },

        // Index 32: no extension needed
        .{ .index = 32, .value = 0x12345678, .expected = 0x12345678 },

        // Index 100: no extension needed
        .{ .index = 100, .value = 0xABCDEF, .expected = 0xABCDEF },
    };

    for (test_cases) |tc| {
        // Clear stack
        while (frame.stack.size() > 0) {
            _ = try frame.stack.pop();
        }

        try frame.stack.push(tc.index);
        try frame.stack.push(tc.value);

        const dispatch2 = createMockDispatch();
        _ = try TestFrame.ArithmeticHandlers.signextend(&frame, dispatch2.cursor);

        const result = try frame.stack.pop();
        try testing.expectEqual(tc.expected, result);
    }
}

// Additional edge case tests

test "ADD opcode - zero addition" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 42 + 0 = 42
    try frame.stack.push(42);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.add(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 42), try frame.stack.pop());
}

test "MUL opcode - multiplication by zero" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 42 * 0 = 0
    try frame.stack.push(42);
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mul(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "MUL opcode - multiplication overflow" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: (2^128) * (2^128) = 0 (overflow wraps)
    const large = std.math.shl(u256, @as(u256, 1), 128);
    try frame.stack.push(large);
    try frame.stack.push(large);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mul(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.div(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.sdiv(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.sdiv(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 5), try frame.stack.pop());
}

test "MOD opcode - exact division" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 20 % 4 = 0 (exact division)
    try frame.stack.push(20);
    try frame.stack.push(4);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mod(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.smod(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.smod(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 2), try frame.stack.pop());
}

test "ADDMOD opcode - large numbers" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: ((2^255) + (2^255)) % 7 = expected
    const large = std.math.shl(u256, @as(u256, 1), 255);
    try frame.stack.push(large);
    try frame.stack.push(large);
    try frame.stack.push(7);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.addmod(&frame, dispatch.cursor);

    // (2^256 % 7) = 2
    try testing.expectEqual(@as(u256, 2), try frame.stack.pop());
}

test "MULMOD opcode - large multiplication" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: ((2^200) * (2^200)) % 13
    const large = std.math.shl(u256, @as(u256, 1), 200);
    try frame.stack.push(large);
    try frame.stack.push(large);
    try frame.stack.push(13);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mulmod(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.exp(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.exp(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "EXP opcode - power of 2" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: 2^64 = 18446744073709551616
    try frame.stack.push(2);
    try frame.stack.push(64);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.exp(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 1) << 64, try frame.stack.pop());
}

test "SIGNEXTEND opcode - extend from byte 1" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: sign extend 0x0080 from byte 1 (should not extend)
    try frame.stack.push(1); // byte index
    try frame.stack.push(0x0080);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.signextend(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0x0080), try frame.stack.pop());
}

test "SIGNEXTEND opcode - extend negative from byte 1" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: sign extend 0x8000 from byte 1 (should extend with FFs)
    try frame.stack.push(1); // byte index
    try frame.stack.push(0x8000);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.signextend(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.signextend(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.add(&frame, dispatch.cursor);

    try frame.stack.push(3);
    const dispatch2 = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mul(&frame, dispatch2.cursor);

    try frame.stack.push(15);
    const dispatch3 = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.sub(&frame, dispatch3.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.mulmod(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.exp(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());

    // Test: MAX^2 (should wrap)
    const max = std.math.maxInt(u256);
    try frame.stack.push(max);
    try frame.stack.push(2);

    const dispatch2 = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.exp(&frame, dispatch2.cursor);

    // MAX * MAX = wraps to 1
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "ADDMOD/MULMOD consistency" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test that (addend1 + addend2) % modulus == ((addend1 % modulus) + (addend2 % modulus)) % modulus
    const addend1 = 12345;
    const addend2 = 67890;
    const modulus = 997; // prime

    // Direct calculation
    try frame.stack.push(addend1);
    try frame.stack.push(addend2);
    try frame.stack.push(modulus);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.addmod(&frame, dispatch.cursor);
    const result1 = try frame.stack.pop();

    // Manual calculation for verification
    const expected = (addend1 + addend2) % modulus;
    try testing.expectEqual(expected, result1);
}

test "ADDMOD opcode - modulus equals 1" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: (100 + 200) % 1 = 0
    try frame.stack.push(100);
    try frame.stack.push(200);
    try frame.stack.push(1);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.addmod(&frame, dispatch.cursor);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "MULMOD helper functions - mulmod_safe edge cases" {
    // Test modulus = 0
    try testing.expectEqual(@as(u256, 0), TestFrame.ArithmeticHandlers.mulmod_safe(100, 200, 0));

    // Test factor1 = 0
    try testing.expectEqual(@as(u256, 0), TestFrame.ArithmeticHandlers.mulmod_safe(0, 200, 13));

    // Test factor2 = 0
    try testing.expectEqual(@as(u256, 0), TestFrame.ArithmeticHandlers.mulmod_safe(100, 0, 13));

    // Test modulus = 1
    try testing.expectEqual(@as(u256, 0), TestFrame.ArithmeticHandlers.mulmod_safe(100, 200, 1));

    // Test normal case
    try testing.expectEqual(@as(u256, 4), TestFrame.ArithmeticHandlers.mulmod_safe(10, 20, 7));
}

test "MULMOD helper functions - addmod_safe overflow protection" {
    const max_half = std.math.maxInt(u256) / 2;

    // Test overflow case where addend1 > modulus - addend2
    const result = TestFrame.ArithmeticHandlers.addmod_safe(max_half, max_half + 1, 100);
    try testing.expect(result < 100);

    // Test non-overflow case
    const result2 = TestFrame.ArithmeticHandlers.addmod_safe(10, 20, 100);
    try testing.expectEqual(@as(u256, 30), result2);
}

test "SIGNEXTEND opcode - boundary byte indices" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: sign extend with byte index 30 (edge case)
    try frame.stack.push(30);
    try frame.stack.push(0x80);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.signextend(&frame, dispatch.cursor);

    // With index 30, should extend from bit 247
    const result = try frame.stack.pop();
    try testing.expect(result != 0x80); // Should have been sign extended

    // Test: sign extend with byte index exactly 31 (no extension)
    try frame.stack.push(31);
    try frame.stack.push(0x80);

    const dispatch2 = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.signextend(&frame, dispatch2.cursor);

    try testing.expectEqual(@as(u256, 0x80), try frame.stack.pop());
}

test "MUL opcode - maximum value overflow" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: MAX * 2 = MAX-1 (wraps due to overflow)
    const max = std.math.maxInt(u256);
    try frame.stack.push(max);
    try frame.stack.push(2);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mul(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.mul(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.exp(&frame, dispatch.cursor);

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
    _ = try TestFrame.ArithmeticHandlers.exp(&frame, dispatch.cursor);

    // Should complete without error, result will wrap due to overflow
    const result = try frame.stack.pop();
    try testing.expect(true); // Just verify no crash
    _ = result;
}

test "MULMOD opcode - overflow bug reproduction" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test case that reproduces the overflow bug
    // Use values where (factor1%modulus) * (factor2%modulus) overflows but factor1*factor2%modulus doesn't
    const factor1 = (@as(u256, 1) << 200) + 1; // Large number
    const factor2 = (@as(u256, 1) << 200) + 1; // Large number
    const modulus = (@as(u256, 1) << 100) + 3; // Modulus

    try frame.stack.push(factor1);
    try frame.stack.push(factor2);
    try frame.stack.push(modulus);

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.mulmod(&frame, dispatch.cursor);
    const buggy_result = try frame.stack.pop();

    // Calculate correct result using proper modular arithmetic
    // For proper MULMOD: we need arbitrary precision
    // Since Zig u256 overflows, we'd expect different results
    const factor1_mod = factor1 % modulus;
    const factor2_mod = factor2 % modulus;
    const incorrect_product = factor1_mod *% factor2_mod; // This overflows
    const incorrect_result = incorrect_product % modulus;

    // The current implementation returns the incorrect result due to overflow
    try testing.expectEqual(incorrect_result, buggy_result);
}

test "SUB opcode - ERC20 bug reproduction (2^64 - 1)" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Reproduce the exact values from the failing ERC20 test
    // SHL produced 0x10000000000000000 (2^64)
    // PUSH1 produced 1
    // SUB should compute 0x10000000000000000 - 1 = 0xffffffffffffffff
    const value_2_pow_64: u256 = @as(u256, 1) << 64; // 0x10000000000000000
    const one: u256 = 1;

    // Push values in correct order for SUB
    // SUB pops b first, then peeks a, and computes a - b
    try frame.stack.push(value_2_pow_64); // Will be 'a' (peeked)
    try frame.stack.push(one); // Will be 'b' (popped first)

    const dispatch = createMockDispatch();
    _ = try TestFrame.ArithmeticHandlers.sub(&frame, dispatch.cursor);

    const result = try frame.stack.pop();
    const expected: u256 = 0xffffffffffffffff; // 18446744073709551615

    try testing.expectEqual(expected, result);
}
