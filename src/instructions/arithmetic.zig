/// Shared arithmetic instruction implementations
/// Phase 1.2 - Generic over FrameType, no gas charging, no PC manipulation
///
/// Source of truth: guillotine-mini/src/instructions/handlers_arithmetic.zig
/// These implementations are pure stack operations - caller must handle gas and PC

const std = @import("std");

/// ADD opcode (0x01) - Addition with overflow wrapping
pub fn AddInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const top = try frame.stack.pop();
            const second = try frame.stack.pop();
            try frame.stack.push(top +% second);
        }
    };
}

/// MUL opcode (0x02) - Multiplication with overflow wrapping
pub fn MulInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const top = try frame.stack.pop();
            const second = try frame.stack.pop();
            try frame.stack.push(top *% second);
        }
    };
}

/// SUB opcode (0x03) - Subtraction with underflow wrapping
/// EVM semantics: stack[1] - stack[0] (second - top)
pub fn SubInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const top = try frame.stack.pop(); // stack[0] - most recently pushed
            const second = try frame.stack.pop(); // stack[1] - pushed before top
            try frame.stack.push(second -% top); // second - top
        }
    };
}

/// DIV opcode (0x04) - Integer division (division by zero returns 0)
/// EVM semantics: stack[1] / stack[0] (second / top)
pub fn DivInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const top = try frame.stack.pop(); // divisor
            const second = try frame.stack.pop(); // dividend
            const result = if (top == 0) 0 else second / top;
            try frame.stack.push(result);
        }
    };
}

/// SDIV opcode (0x05) - Signed integer division
/// EVM semantics: stack[1] / stack[0] (second / top)
pub fn SdivInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const top = try frame.stack.pop(); // divisor
            const second = try frame.stack.pop(); // dividend
            const top_signed = @as(i256, @bitCast(top));
            const second_signed = @as(i256, @bitCast(second));
            const MIN_SIGNED = @as(u256, 1) << 255;
            const result = if (top == 0)
                0
            else if (second == MIN_SIGNED and top == std.math.maxInt(u256))
                MIN_SIGNED
            else
                @as(u256, @bitCast(@divTrunc(second_signed, top_signed)));
            try frame.stack.push(result);
        }
    };
}

/// MOD opcode (0x06) - Modulo operation (mod by zero returns 0)
/// EVM semantics: stack[1] % stack[0] (second % top)
pub fn ModInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const top = try frame.stack.pop(); // modulus
            const second = try frame.stack.pop(); // value
            const result = if (top == 0) 0 else second % top;
            try frame.stack.push(result);
        }
    };
}

/// SMOD opcode (0x07) - Signed modulo operation
/// EVM semantics: stack[1] % stack[0] (second % top)
pub fn SmodInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const top = try frame.stack.pop(); // modulus
            const second = try frame.stack.pop(); // value
            const top_signed = @as(i256, @bitCast(top));
            const second_signed = @as(i256, @bitCast(second));
            const MIN_SIGNED = @as(u256, 1) << 255;
            const result = if (top == 0)
                0
            else if (second == MIN_SIGNED and top == std.math.maxInt(u256))
                0
            else
                @as(u256, @bitCast(@rem(second_signed, top_signed)));
            try frame.stack.push(result);
        }
    };
}

/// ADDMOD opcode (0x08) - Addition modulo n (mod by zero returns 0)
pub fn AddmodInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const a = try frame.stack.pop();
            const b = try frame.stack.pop();
            const n = try frame.stack.pop();
            const result = if (n == 0) 0 else blk: {
                const a_wide = @as(u512, a);
                const b_wide = @as(u512, b);
                const n_wide = @as(u512, n);
                break :blk @as(u256, @truncate((a_wide + b_wide) % n_wide));
            };
            try frame.stack.push(result);
        }
    };
}

/// MULMOD opcode (0x09) - Multiplication modulo n (mod by zero returns 0)
pub fn MulmodInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const a = try frame.stack.pop();
            const b = try frame.stack.pop();
            const n = try frame.stack.pop();
            const result = if (n == 0) 0 else blk: {
                const a_wide = @as(u512, a);
                const b_wide = @as(u512, b);
                const n_wide = @as(u512, n);
                break :blk @as(u256, @truncate((a_wide * b_wide) % n_wide));
            };
            try frame.stack.push(result);
        }
    };
}

/// EXP opcode (0x0a) - Exponential operation
/// Note: This includes dynamic gas calculation but NOT static gas
/// Caller must charge static GasSlowStep before calling
pub fn ExpInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const base = try frame.stack.pop();
            const exponent = try frame.stack.pop();

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

            try frame.stack.push(result);
        }
    };
}

/// SIGNEXTEND opcode (0x0b) - Sign extension
pub fn SignextendInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const byte_index = try frame.stack.pop();
            const value = try frame.stack.pop();

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

            try frame.stack.push(result);
        }
    };
}
