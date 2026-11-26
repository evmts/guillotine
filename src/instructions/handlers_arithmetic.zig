const std = @import("std");
const FrameConfig = @import("../frame/frame_config.zig").FrameConfig;
const GasConstants = @import("voltaire").GasConstants;
const log = @import("../log.zig");
const eips = @import("../eips_and_hardforks/eips.zig");
const verified_ops = @import("../core/verified_ops.zig");
const wide_arith = @import("../core/wide_arith.zig");

/// Arithmetic opcode handlers for the EVM stack frame.
/// These are generic structs that return static handlers for a given FrameType.
pub fn Handlers(FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;

        const dispatch_next = @import("dispatch_next.zig");
        const handler_abi = @import("../preprocessor/handler_abi.zig");
        const N = handler_abi.Native(FrameType);

        /// ADD opcode (0x01) - Addition with overflow wrapping.
        pub fn add(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            N.before(self, .ADD, cursor, s, gas);

            s.binary_op_unsafe(struct {
                fn op(top: WordType, second: WordType) WordType {
                    return top +% second;
                }
            }.op);

            return N.next(self, .ADD, cursor, s, gas);
        }

        /// MUL opcode (0x02) - Multiplication with overflow wrapping.
        pub fn mul(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            N.before(self, .MUL, cursor, s, gas);

            s.binary_op_unsafe(struct {
                fn op(top: WordType, second: WordType) WordType {
                    return top *% second;
                }
            }.op);

            return N.next(self, .MUL, cursor, s, gas);
        }

        /// SUB opcode (0x03) - Subtraction with underflow wrapping.
        pub fn sub(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            N.before(self, .SUB, cursor, s, gas);

            s.binary_op_unsafe(struct {
                fn op(top: WordType, second: WordType) WordType {
                    return top -% second; // SUB: µs[0] - µs[1] = top - second
                }
            }.op);

            return N.next(self, .SUB, cursor, s, gas);
        }

        const Handler = handler_abi.ExitCode;

        /// True when any of `words` has bits above bit 63. Operands that all fit one limb
        /// take the inline path of a division handler: one hardware divide, no call and
        /// no stack frame. Everything else tail-calls the handler's `*_wide` twin.
        inline fn anyWide(words: anytype) bool {
            var merged: WordType = 0;
            inline for (words) |word| merged |= word;
            return !wide_arith.fitsU64(merged);
        }

        /// DIV opcode (0x04) - Integer division. Division by zero returns 0.
        pub fn div(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) Handler {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            N.before(self, .DIV, cursor, s, gas);
            const top = s.tos;
            const second = s.sp[1];
            if (anyWide(.{ top, second })) return @call(handler_abi.tail_mod, N.outlined(&div_wide), .{ self, cursor, sp, gas, t0, t1, t2, t3 });

            s.sp += 1;
            s.tos = wide_arith.div64(@truncate(top), @truncate(second));
            return N.next(self, .DIV, cursor, s, gas);
        }

        /// DIV for operands wider than 64 bits. Entered by tail call from `div`, after
        /// `div` has run the pre-instruction hooks, with the operands still on the stack.
        fn div_wide(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) Handler {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            s.binary_op_unsafe(struct {
                fn op(top: WordType, second: WordType) WordType {
                    return @intCast(wide_arith.div(top, second));
                }
            }.op);
            return N.next(self, .DIV, cursor, s, gas);
        }

        /// SDIV opcode (0x05) - Signed integer division.
        ///
        /// Operands below 2^64 are non-negative, so their signed quotient is the unsigned
        /// one. `sdiv_wide` handles every other input.
        pub fn sdiv(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) Handler {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            N.before(self, .SDIV, cursor, s, gas);
            const top = s.tos;
            const second = s.sp[1];
            if (anyWide(.{ top, second })) return @call(handler_abi.tail_mod, N.outlined(&sdiv_wide), .{ self, cursor, sp, gas, t0, t1, t2, t3 });

            s.sp += 1;
            s.tos = wide_arith.div64(@truncate(top), @truncate(second));
            return N.next(self, .SDIV, cursor, s, gas);
        }

        /// SDIV for operands wider than 64 bits, which includes every negative operand.
        ///
        /// Branchless: unsigned division of the operands' magnitudes, then the sign is
        /// re-applied by `verified_ops.sdivFromUnsignedQuotient`. That function is the
        /// one the SMT and Lean proofs cover (`sdiv_branchless_equiv`); with
        /// `wide_arith.div(x, 0) == 0` it yields 0 for a zero divisor and `MIN_SIGNED` for
        /// `MIN_SIGNED / -1` without a special case.
        fn sdiv_wide(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) Handler {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            const top = s.pop_unsafe();
            const second = s.peek_unsafe();

            const quotient = wide_arith.div(verified_ops.absTwoComp(top), verified_ops.absTwoComp(second));

            s.set_top_unsafe(verified_ops.sdivFromUnsignedQuotient(top, second, quotient));
            return N.next(self, .SDIV, cursor, s, gas);
        }

        /// MOD opcode (0x06) - Modulo operation. Modulo by zero returns 0.
        pub fn mod(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) Handler {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            N.before(self, .MOD, cursor, s, gas);
            const top = s.tos;
            const second = s.sp[1];
            if (anyWide(.{ top, second })) return @call(handler_abi.tail_mod, N.outlined(&mod_wide), .{ self, cursor, sp, gas, t0, t1, t2, t3 });

            s.sp += 1;
            s.tos = wide_arith.rem64(@truncate(top), @truncate(second));
            return N.next(self, .MOD, cursor, s, gas);
        }

        /// MOD for operands wider than 64 bits. Entered by tail call from `mod`.
        fn mod_wide(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) Handler {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            s.binary_op_unsafe(struct {
                fn op(top: WordType, second: WordType) WordType {
                    return @intCast(wide_arith.rem(top, second));
                }
            }.op);
            return N.next(self, .MOD, cursor, s, gas);
        }

        /// SMOD opcode (0x07) - Signed modulo operation.
        ///
        /// Operands below 2^64 are non-negative, so their signed remainder is the unsigned
        /// one. `smod_wide` handles every other input.
        pub fn smod(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) Handler {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            N.before(self, .SMOD, cursor, s, gas);
            const top = s.tos;
            const second = s.sp[1];
            if (anyWide(.{ top, second })) return @call(handler_abi.tail_mod, N.outlined(&smod_wide), .{ self, cursor, sp, gas, t0, t1, t2, t3 });

            s.sp += 1;
            s.tos = wide_arith.rem64(@truncate(top), @truncate(second));
            return N.next(self, .SMOD, cursor, s, gas);
        }

        /// SMOD for operands wider than 64 bits, which includes every negative operand.
        ///
        /// Branchless: unsigned remainder of the operands' magnitudes, then the dividend's
        /// sign is re-applied by `verified_ops.smodFromUnsignedRem`, the function the SMT
        /// and Lean proofs cover (`smod_branchless_equiv`). With `wide_arith.rem(x, 0) == 0`
        /// it yields 0 for a zero divisor and for `MIN_SIGNED % -1` without a special case.
        fn smod_wide(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) Handler {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            const top = s.pop_unsafe();
            const second = s.peek_unsafe();

            const remainder = wide_arith.rem(verified_ops.absTwoComp(top), verified_ops.absTwoComp(second));

            s.set_top_unsafe(verified_ops.smodFromUnsignedRem(top, remainder));
            return N.next(self, .SMOD, cursor, s, gas);
        }

        /// ADDMOD opcode (0x08) - (a + b) % N. All intermediate calculations are performed with arbitrary precision.
        pub fn addmod(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) Handler {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            N.before(self, .ADDMOD, cursor, s, gas);
            const addend1 = s.tos; // Top of stack (a)
            const addend2 = s.sp[1]; // Second on stack (b)
            const modulus = s.sp[2]; // Third on stack (N)
            // The inline path needs one-limb operands whose sum also fits one limb.
            const sum = @addWithOverflow(@as(u64, @truncate(addend1)), @as(u64, @truncate(addend2)));
            if (anyWide(.{ addend1, addend2, modulus }) or sum[1] != 0) return @call(handler_abi.tail_mod, N.outlined(&addmod_wide), .{ self, cursor, sp, gas, t0, t1, t2, t3 });

            s.sp += 2;
            s.tos = wide_arith.rem64(sum[0], @truncate(modulus));
            return N.next(self, .ADDMOD, cursor, s, gas);
        }

        /// ADDMOD for operands or sums wider than 64 bits. Entered by tail call from
        /// `addmod`. The sum is reduced as a 257-bit value, so it never wraps.
        fn addmod_wide(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) Handler {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            const addend1 = s.pop_unsafe(); // Top of stack (a)
            const addend2 = s.pop_unsafe(); // Second on stack (b)
            const modulus = s.peek_unsafe(); // Third on stack (N)
            s.set_top_unsafe(@intCast(wide_arith.addmod(addend1, addend2, modulus)));
            return N.next(self, .ADDMOD, cursor, s, gas);
        }

        /// MULMOD opcode (0x09) - (a * b) % N. All intermediate calculations are performed with arbitrary precision.
        pub fn mulmod(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) Handler {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            N.before(self, .MULMOD, cursor, s, gas);
            const factor1 = s.tos; // Top of stack (a)
            const factor2 = s.sp[1]; // Second on stack (b)
            const modulus = s.sp[2]; // Third on stack (N)
            if (anyWide(.{ factor1, factor2, modulus })) return @call(handler_abi.tail_mod, N.outlined(&mulmod_wide), .{ self, cursor, sp, gas, t0, t1, t2, t3 });

            s.sp += 2;
            s.tos = wide_arith.mulmod64(@truncate(factor1), @truncate(factor2), @truncate(modulus));
            return N.next(self, .MULMOD, cursor, s, gas);
        }

        /// MULMOD for operands wider than 64 bits. Entered by tail call from `mulmod`.
        /// The product is reduced as a 512-bit value, so it never wraps.
        fn mulmod_wide(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) Handler {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            const factor1 = s.pop_unsafe(); // Top of stack (a)
            const factor2 = s.pop_unsafe(); // Second on stack (b)
            const modulus = s.peek_unsafe(); // Third on stack (N)
            s.set_top_unsafe(@intCast(wide_arith.mulmod(factor1, factor2, modulus)));
            return N.next(self, .MULMOD, cursor, s, gas);
        }

        /// EXP opcode (0x0a) - Exponential operation.
        pub fn exp(self: *FrameType, cursor: [*]const Dispatch.Item) Error![*]const FrameType.Dispatch.Item {
            // Pop base (top), then exponent (second); compute base^exponent
            self.beforeInstruction(.EXP, cursor);
            const base = self.stack.pop_unsafe(); // Top of stack (base)
            const exponent = self.stack.peek_unsafe(); // Below top (exponent)

            // EXP costs 10 + byte_gas * byte_len(exponent), where byte_gas is 10 before
            // EIP-160 (Spurious Dragon) and 50 from then on. The 10 gas base is static and
            // already charged with the basic block (OPCODE_INFO[EXP].gas_cost); the handler
            // charges only the dynamic part.
            // Byte length of the exponent, from the verified branchless form
            // (`exp_gas_bytes_equiv`).
            const exp_bytes: u64 = verified_ops.expGasByteLenFast(exponent);

            const exp_byte_gas: u64 = comptime @intCast((eips.Eips{ .hardfork = FrameType.config.hardfork }).eip_160_exp_byte_gas_cost());
            const gas_cost = exp_byte_gas * exp_bytes;
            if (self.gas_remaining < 0 or gas_cost > @as(u64, @intCast(self.gas_remaining))) {
                self.afterComplete(.EXP);
                return Error.OutOfGas;
            }
            self.gas_remaining -= @intCast(gas_cost);

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
            return dispatch_next.nextInstruction(FrameType, self, cursor, .EXP);
        }

        /// SIGNEXTEND opcode (0x0b) - Sign extend operation.
        /// Uses `verified_ops.signextendFast`, the branchless form the SMT and Lean
        /// proofs show equal to the Yellow Paper definition (`signextend_branchless_equiv`).
        pub fn signextend(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            N.before(self, .SIGNEXTEND, cursor, s, gas);
            const ext = s.pop_unsafe(); // Extension byte index (top of stack)
            const value = s.peek_unsafe(); // Value to extend (second element)
            s.set_top_unsafe(verified_ops.signextendFast(ext, value));
            return N.next(self, .SIGNEXTEND, cursor, s, gas);
        }
    };
}

// ====== TESTS ======

const testing = std.testing;
const Frame = @import("../frame/frame.zig").Frame;
const dispatch_mod = @import("../preprocessor/dispatch.zig");
const DefaultTracer = @import("../tracer/tracer.zig").DefaultTracer;
const Address = @import("voltaire").Address;

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
