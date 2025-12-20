/// Arithmetic opcode handlers for the EVM
const std = @import("std");
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;

/// Handlers struct - provides arithmetic operation handlers for a Frame type
/// The FrameType must have methods: consumeGas, popStack, pushStack
/// and a field: pc (program counter)
pub fn Handlers(FrameType: type) type {
    return struct {
        /// ADD opcode (0x01) - Addition with overflow wrapping
        pub fn add(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasFastestStep);
            const a = try frame.popStack();
            const b = try frame.popStack();
            try frame.pushStack(a +% b);
            frame.pc += 1;
        }

        /// MUL opcode (0x02) - Multiplication with overflow wrapping
        pub fn mul(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasFastStep);
            const a = try frame.popStack();
            const b = try frame.popStack();
            try frame.pushStack(a *% b);
            frame.pc += 1;
        }

        /// SUB opcode (0x03) - Subtraction with underflow wrapping
        pub fn sub(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasFastestStep);
            const top = try frame.popStack();
            const second = try frame.popStack();
            try frame.pushStack(top -% second);
            frame.pc += 1;
        }

        /// DIV opcode (0x04) - Integer division (division by zero returns 0)
        pub fn div(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasFastStep);
            const top = try frame.popStack();
            const second = try frame.popStack();
            const result = if (second == 0) 0 else top / second;
            try frame.pushStack(result);
            frame.pc += 1;
        }

        /// SDIV opcode (0x05) - Signed integer division
        pub fn sdiv(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasFastStep);
            const top = try frame.popStack();
            const second = try frame.popStack();
            const top_signed = @as(i256, @bitCast(top));
            const second_signed = @as(i256, @bitCast(second));
            const MIN_SIGNED = @as(u256, 1) << 255;
            const result = if (second == 0)
                0
            else if (top == MIN_SIGNED and second == std.math.maxInt(u256))
                MIN_SIGNED
            else
                @as(u256, @bitCast(@divTrunc(top_signed, second_signed)));
            try frame.pushStack(result);
            frame.pc += 1;
        }

        /// MOD opcode (0x06) - Modulo operation (mod by zero returns 0)
        pub fn mod(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasFastStep);
            const top = try frame.popStack();
            const second = try frame.popStack();
            const result = if (second == 0) 0 else top % second;
            try frame.pushStack(result);
            frame.pc += 1;
        }

        /// SMOD opcode (0x07) - Signed modulo operation
        pub fn smod(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasFastStep);
            const top = try frame.popStack();
            const second = try frame.popStack();
            const top_signed = @as(i256, @bitCast(top));
            const second_signed = @as(i256, @bitCast(second));
            const MIN_SIGNED = @as(u256, 1) << 255;
            const result = if (second == 0)
                0
            else if (top == MIN_SIGNED and second == std.math.maxInt(u256))
                0
            else
                @as(u256, @bitCast(@rem(top_signed, second_signed)));
            try frame.pushStack(result);
            frame.pc += 1;
        }

        /// ADDMOD opcode (0x08) - Addition modulo n (mod by zero returns 0)
        pub fn addmod(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasMidStep);
            const a = try frame.popStack();
            const b = try frame.popStack();
            const n = try frame.popStack();
            const result = if (n == 0) 0 else blk: {
                const a_wide = @as(u512, a);
                const b_wide = @as(u512, b);
                const n_wide = @as(u512, n);
                break :blk @as(u256, @truncate((a_wide + b_wide) % n_wide));
            };
            try frame.pushStack(result);
            frame.pc += 1;
        }

        /// MULMOD opcode (0x09) - Multiplication modulo n (mod by zero returns 0)
        pub fn mulmod(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasMidStep);
            const a = try frame.popStack();
            const b = try frame.popStack();
            const n = try frame.popStack();
            const result = if (n == 0) 0 else blk: {
                // Use u512 to avoid overflow
                const a_wide = @as(u512, a);
                const b_wide = @as(u512, b);
                const n_wide = @as(u512, n);
                break :blk @as(u256, @truncate((a_wide * b_wide) % n_wide));
            };
            try frame.pushStack(result);
            frame.pc += 1;
        }

        /// EXP opcode (0x0a) - Exponential operation
        pub fn exp(frame: *FrameType) FrameType.EvmError!void {
            const base = try frame.popStack();
            const exponent = try frame.popStack();

            // Calculate dynamic gas cost based on exponent byte length
            // Per EIP-160: GAS_EXP_BYTE * byte_length(exponent)
            const byte_len = blk: {
                if (exponent == 0) break :blk 0;
                var temp_exp = exponent;
                var len: u64 = 0;
                while (temp_exp > 0) : (temp_exp >>= 8) {
                    len += 1;
                }
                break :blk len;
            };
            // EIP-160: GAS_EXPONENTIATION_PER_BYTE = 50 (missing from primitives lib)
            const EXP_BYTE_COST: u64 = 50;
            const dynamic_gas = EXP_BYTE_COST * byte_len;
            try frame.consumeGas(GasConstants.GasSlowStep + dynamic_gas);

            // Compute result (wrapping on overflow)
            var result: u256 = 1;
            var b = base;
            var e = exponent;
            while (e > 0) {
                if (e & 1 == 1) {
                    result = result *% b;
                }
                b = b *% b;
                e >>= 1;
            }

            try frame.pushStack(result);
            frame.pc += 1;
        }

        /// SIGNEXTEND opcode (0x0b) - Sign extension
        pub fn signextend(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasFastStep);
            const byte_index = try frame.popStack();
            const value = try frame.popStack();

            // If byte_index >= 31, no sign extension needed
            const result = if (byte_index >= 31) value else blk: {
                const bit_index = @as(u8, @truncate(byte_index * 8 + 7));
                const sign_bit = @as(u256, 1) << @as(u8, bit_index);
                const mask = sign_bit - 1;

                // Check if sign bit is set
                const is_negative = (value & sign_bit) != 0;

                if (is_negative) {
                    // Sign extend with 1s
                    break :blk value | ~mask;
                } else {
                    // Zero extend (clear upper bits)
                    break :blk value & mask;
                }
            };

            try frame.pushStack(result);
            frame.pc += 1;
        }
    };
}
