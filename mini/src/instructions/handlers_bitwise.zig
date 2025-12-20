/// Bitwise opcode handlers for the EVM
const std = @import("std");
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;

/// Handlers struct - provides bitwise operation handlers for a Frame type
/// The FrameType must have methods: consumeGas, popStack, pushStack, getEvm
/// and a field: pc (program counter), hardfork
pub fn Handlers(FrameType: type) type {
    return struct {
        /// AND opcode (0x16) - Bitwise AND operation
        pub fn op_and(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasFastestStep);
            const a = try frame.popStack();
            const b = try frame.popStack();
            try frame.pushStack(a & b);
            frame.pc += 1;
        }

        /// OR opcode (0x17) - Bitwise OR operation
        pub fn op_or(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasFastestStep);
            const a = try frame.popStack();
            const b = try frame.popStack();
            try frame.pushStack(a | b);
            frame.pc += 1;
        }

        /// XOR opcode (0x18) - Bitwise XOR operation
        pub fn op_xor(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasFastestStep);
            const a = try frame.popStack();
            const b = try frame.popStack();
            try frame.pushStack(a ^ b);
            frame.pc += 1;
        }

        /// NOT opcode (0x19) - Bitwise NOT operation
        pub fn op_not(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasFastestStep);
            const a = try frame.popStack();
            try frame.pushStack(~a);
            frame.pc += 1;
        }

        /// BYTE opcode (0x1a) - Extract byte from word
        pub fn byte(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasFastestStep);
            const i = try frame.popStack();
            const x = try frame.popStack();
            const result = if (i >= 32) 0 else (x >> @intCast(8 * (31 - i))) & 0xff;
            try frame.pushStack(result);
            frame.pc += 1;
        }

        /// SHL opcode (0x1b) - Shift left operation (EIP-145)
        pub fn shl(frame: *FrameType) FrameType.EvmError!void {
            const evm = frame.getEvm();
            // EIP-145: SHL opcode was introduced in Constantinople hardfork
            if (evm.hardfork.isBefore(.CONSTANTINOPLE)) return error.InvalidOpcode;

            try frame.consumeGas(GasConstants.GasFastestStep);
            // Pop shift (TOS), then value
            const shift = try frame.popStack();
            const value = try frame.popStack();
            // For shifts >= 256, result is always 0
            // Otherwise, shift left and wrap to 256 bits
            const result = if (shift >= 256)
                0
            else
                value << @as(u8, @intCast(shift));
            try frame.pushStack(result);
            frame.pc += 1;
        }

        /// SHR opcode (0x1c) - Logical shift right operation (EIP-145)
        pub fn shr(frame: *FrameType) FrameType.EvmError!void {
            const evm = frame.getEvm();
            // EIP-145: SHR opcode was introduced in Constantinople hardfork
            if (evm.hardfork.isBefore(.CONSTANTINOPLE)) return error.InvalidOpcode;

            try frame.consumeGas(GasConstants.GasFastestStep);
            // Pop shift (TOS), then value
            const shift = try frame.popStack();
            const value = try frame.popStack();
            // For shifts >= 256, result is always 0
            const result = if (shift >= 256)
                0
            else
                value >> @as(u8, @intCast(shift));
            try frame.pushStack(result);
            frame.pc += 1;
        }

        /// SAR opcode (0x1d) - Arithmetic shift right operation (EIP-145)
        pub fn sar(frame: *FrameType) FrameType.EvmError!void {
            const evm = frame.getEvm();
            // EIP-145: SAR opcode was introduced in Constantinople hardfork
            if (evm.hardfork.isBefore(.CONSTANTINOPLE)) return error.InvalidOpcode;

            try frame.consumeGas(GasConstants.GasFastestStep);
            // Pop shift (TOS), then value
            const shift = try frame.popStack();
            const value = try frame.popStack();
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
            try frame.pushStack(result);
            frame.pc += 1;
        }
    };
}
