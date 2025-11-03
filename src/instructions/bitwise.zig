/// Shared bitwise instruction implementations
/// Phase 1.3 - Generic over FrameType, no gas charging, no PC manipulation
///
/// Source of truth: guillotine-mini/src/instructions/handlers_bitwise.zig
/// These implementations are pure stack operations - caller must handle gas and PC

const std = @import("std");

/// AND opcode (0x16) - Bitwise AND operation
pub fn AndInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const a = try frame.stack.pop();
            const b = try frame.stack.pop();
            try frame.stack.push(a & b);
        }
    };
}

/// OR opcode (0x17) - Bitwise OR operation
pub fn OrInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const a = try frame.stack.pop();
            const b = try frame.stack.pop();
            try frame.stack.push(a | b);
        }
    };
}

/// XOR opcode (0x18) - Bitwise XOR operation
pub fn XorInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const a = try frame.stack.pop();
            const b = try frame.stack.pop();
            try frame.stack.push(a ^ b);
        }
    };
}

/// NOT opcode (0x19) - Bitwise NOT operation
pub fn NotInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const a = try frame.stack.pop();
            try frame.stack.push(~a);
        }
    };
}

/// BYTE opcode (0x1a) - Extract byte from word
pub fn ByteInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const i = try frame.stack.pop();
            const x = try frame.stack.pop();
            const result = if (i >= 32) 0 else (x >> @intCast(8 * (31 - i))) & 0xff;
            try frame.stack.push(result);
        }
    };
}

/// SHL opcode (0x1b) - Shift left operation (EIP-145, Constantinople+)
/// Note: Hardfork check must be done by caller
pub fn ShlInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            // Pop shift (TOS), then value
            const shift = try frame.stack.pop();
            const value = try frame.stack.pop();
            // For shifts >= 256, result is always 0
            // Otherwise, shift left and wrap to 256 bits
            const result = if (shift >= 256)
                0
            else
                value << @as(u8, @intCast(shift));
            try frame.stack.push(result);
        }
    };
}

/// SHR opcode (0x1c) - Logical shift right operation (EIP-145, Constantinople+)
/// Note: Hardfork check must be done by caller
pub fn ShrInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            // Pop shift (TOS), then value
            const shift = try frame.stack.pop();
            const value = try frame.stack.pop();
            // For shifts >= 256, result is always 0
            const result = if (shift >= 256)
                0
            else
                value >> @as(u8, @intCast(shift));
            try frame.stack.push(result);
        }
    };
}

/// SAR opcode (0x1d) - Arithmetic shift right operation (EIP-145, Constantinople+)
/// Note: Hardfork check must be done by caller
pub fn SarInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            // Pop shift (TOS), then value
            const shift = try frame.stack.pop();
            const value = try frame.stack.pop();
            const value_signed = @as(i256, @bitCast(value));
            // For shifts >= 256, result depends on sign bit
            const result = if (shift >= 256) blk: {
                // If negative, result is all 1s (-1); if positive, result is 0
                break :blk if (value_signed < 0)
                    @as(u256, @bitCast(@as(i256, -1)))
                else
                    0;
            } else blk: {
                break :blk @as(u256, @bitCast(value_signed >> @as(u8, @intCast(shift))));
            };
            try frame.stack.push(result);
        }
    };
}
