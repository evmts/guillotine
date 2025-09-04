const std = @import("std");
const FrameConfig = @import("frame_config.zig").FrameConfig;
const log = @import("log.zig");
const GasConstants = @import("primitives").GasConstants;

/// Arithmetic opcode handlers for the EVM stack frame.
/// These are generic structs that return static handlers for a given FrameType.
pub fn Handlers(comptime FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;

        /// ADD opcode (0x01) - Addition with overflow wrapping.
        pub fn add(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const b = try self.stack.pop(); // Second operand (top of stack)
            const a = try self.stack.peek(); // First operand (second element)
            const result = a +% b;
            self.stack.set_top_unsafe(result);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }

        /// MUL opcode (0x02) - Multiplication with overflow wrapping.
        pub fn mul(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const b = try self.stack.pop(); // Second operand (top of stack)
            const a = try self.stack.peek(); // First operand (second element)
            const result = a *% b;
            self.stack.set_top_unsafe(result);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }

        /// SUB opcode (0x03) - Subtraction with underflow wrapping.
        pub fn sub(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const a = try self.stack.pop(); // Top of stack (first operand)
            const b = try self.stack.peek(); // Second from top (second operand)
            // EVM semantics: top - second = a - b
            const result = a -% b;
            self.stack.set_top_unsafe(result);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }

        /// DIV opcode (0x04) - Integer division. Division by zero returns 0.
        pub fn div(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const a = try self.stack.pop(); // Top of stack (first operand)
            const b = try self.stack.peek(); // Second from top (second operand)
            // EVM semantics: top / second = a / b
            const result = if (b == 0) 0 else a / b;
            self.stack.set_top_unsafe(result);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }

        /// SDIV opcode (0x05) - Signed integer division.
        pub fn sdiv(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const a = try self.stack.pop(); // Top of stack (first operand)
            const b = try self.stack.peek(); // Second from top (second operand)

            log.debug("SDIV: first=0x{x}, second=0x{x}", .{ a, b });
            var result: WordType = undefined;
            if (b == 0) {
                result = 0;
                log.debug("SDIV: division by zero, result=0", .{});
            } else {
                const first_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(a));
                const second_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(b));
                log.debug("SDIV: first_signed={}, second_signed={}", .{ first_signed, second_signed });
                const min_signed = std.math.minInt(std.meta.Int(.signed, @bitSizeOf(WordType)));
                if (first_signed == min_signed and second_signed == -1) {
                    // MIN / -1 overflow case
                    result = a;
                    log.debug("SDIV: overflow case, result=0x{x}", .{result});
                } else {
                    const result_signed = @divTrunc(first_signed, second_signed);
                    result = @as(WordType, @bitCast(result_signed));
                    log.debug("SDIV: result_signed={}, result=0x{x}", .{ result_signed, result });
                }
            }
            self.stack.set_top_unsafe(result);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }

        /// MOD opcode (0x06) - Modulo operation. Modulo by zero returns 0.
        pub fn mod(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const a = try self.stack.pop(); // Top of stack (first operand)
            const b = try self.stack.peek(); // Second from top (second operand)
            // EVM semantics: top % second = a % b
            const result = if (b == 0) 0 else a % b;
            self.stack.set_top_unsafe(result);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }

        /// SMOD opcode (0x07) - Signed modulo operation.
        pub fn smod(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const a = try self.stack.pop(); // Top of stack (first operand)
            const b = try self.stack.peek(); // Second from top (second operand)
            var result: WordType = undefined;
            if (b == 0) {
                result = 0;
            } else {
                const first_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(a));
                const second_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(b));
                const min_signed = std.math.minInt(std.meta.Int(.signed, @bitSizeOf(WordType)));
                // Special case: MIN_INT % -1 = 0 (to avoid overflow)
                if (first_signed == min_signed and second_signed == -1) {
                    result = 0;
                } else {
                    const result_signed = @rem(first_signed, second_signed);
                    result = @as(WordType, @bitCast(result_signed));
                }
            }
            self.stack.set_top_unsafe(result);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }

        /// ADDMOD opcode (0x08) - (a + b) % N. All intermediate calculations are performed with arbitrary precision.
        pub fn addmod(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const addend1 = try self.stack.pop(); // Top of stack (a)
            const addend2 = try self.stack.pop(); // Second on stack (b)
            const modulus = try self.stack.pop(); // Third on stack (N)
            var result: WordType = 0;
            if (modulus == 0) {
                result = 0;
            } else {
                const addend1_reduced = addend1 % modulus;
                const addend2_reduced = addend2 % modulus;
                const sum = @addWithOverflow(addend1_reduced, addend2_reduced);
                var r = sum[0];
                // If overflow occurred or r >= modulus, subtract once
                if (sum[1] == 1 or r >= modulus) {
                    r -%= modulus;
                }
                result = r;
            }
            try self.stack.push(result);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }

        /// MULMOD opcode (0x09) - (a * b) % N. All intermediate calculations are performed with arbitrary precision.
        pub fn mulmod(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const factor1 = try self.stack.pop(); // Top of stack (a)
            const factor2 = try self.stack.pop(); // Second on stack (b)
            const modulus = try self.stack.pop(); // Third on stack (N)
            var result: WordType = undefined;
            if (modulus == 0) {
                result = 0;
            } else {
                result = mulmod_safe(factor1, factor2, modulus);
            }
            try self.stack.push(result);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
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
                multiplier >>= 1;
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
                // Overflow case: (addend1 + addend2) = modulus + (addend1 + addend2 - modulus)
                return (addend1_mod - (modulus - addend2_mod));
            } else {
                // No overflow case
                return (addend1_mod + addend2_mod) % modulus;
            }
        }

        /// EXP opcode (0x0a) - Exponential operation.
        pub fn exp(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            // Match REVM operand ordering: treat top-of-stack as base and
            // second-from-top as exponent, computing base^exponent.
            const base = try self.stack.pop(); // Top of stack (base)
            const exponent = try self.stack.peek(); // Below top (exponent)

            // EIP-160: Dynamic gas cost for EXP
            // Gas cost = 10 + 50 * (number of non-zero bytes in exponent)
            var exp_bytes: u32 = 0;
            if (exponent > 0) {
                var temp_exp = exponent;
                while (temp_exp > 0) : (temp_exp >>= 8) {
                    exp_bytes += 1;
                }
            }

            const gas_cost = 10 + 50 * exp_bytes;
            if (self.gas_remaining < gas_cost) {
                return Error.OutOfGas;
            }
            self.gas_remaining -= @intCast(gas_cost);

            // Calculate base^exponent with wrapping multiplication (mod 2^256)
            var result: WordType = 1;
            var base_working = base;
            var exponent_working = exponent;
            while (exponent_working > 0) : (exponent_working >>= 1) {
                if (exponent_working & 1 == 1) {
                    result *%= base_working;
                }
                base_working *%= base_working;
            }
            self.stack.set_top_unsafe(result);
            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }

        /// SIGNEXTEND opcode (0x0b) - Sign extend operation.
        pub fn signextend(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {




            const ext = try self.stack.pop(); // Extension byte index (top of stack)


            const value = try self.stack.peek(); // Value to extend (second element)

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

                const mask = (@as(WordType, 1) << shift_amount) - 1;
                const sign_bit = (value >> shift_amount) & 1;
                if (sign_bit == 1) {
                    result = value | ~mask;
                } else {
                    result = value & mask;
                }
            }



            self.stack.set_top_unsafe(result);


            const next_cursor = cursor + 1;
            return @call(FrameType.getTailCallModifier(), next_cursor[0].opcode_handler, .{ self, next_cursor });
        }
    };
}