//! Bitwise operations for the Ethereum Virtual Machine
//!
//! This module implements all bitwise opcodes for the EVM including AND, OR, XOR,
//! NOT, BYTE, SHL (shift left), SHR (shift right), and SAR (arithmetic shift right).
//!
//! All operations work on 256-bit unsigned integers and follow standard bitwise
//! semantics with EVM-specific behavior for edge cases.
//!
//! ## Gas Costs
//! - AND, OR, XOR, NOT: 3 gas
//! - BYTE: 3 gas
//! - SHL, SHR, SAR: 3 gas
//!
//! ## Stack Effects
//! - Binary operations (AND, OR, XOR): pop 2, push 1
//! - Unary operations (NOT): pop 1, push 1
//! - BYTE: pop 2, push 1
//! - Shift operations: pop 2, push 1

const std = @import("std");
const ExecutionError = @import("execution_error.zig");
const Frame = @import("../stack_frame.zig").StackFrame;
const primitives = @import("primitives");

/// AND opcode (0x16) - Bitwise AND operation
///
/// Pops two values from the stack and pushes their bitwise AND.
/// Stack: [a, b] → [a & b]
pub fn op_and(frame: *Frame) ExecutionError.Error!void {
    std.debug.assert(frame.stack.size() >= 2);
    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe();
    const r = a & b;
    frame.stack.set_top_unsafe(r);
}

/// OR opcode (0x17) - Bitwise OR operation
///
/// Pops two values from the stack and pushes their bitwise OR.
/// Stack: [a, b] → [a | b]
pub fn op_or(frame: *Frame) ExecutionError.Error!void {
    std.debug.assert(frame.stack.size() >= 2);
    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe();
    frame.stack.set_top_unsafe(a | b);
}

/// XOR opcode (0x18) - Bitwise XOR operation
///
/// Pops two values from the stack and pushes their bitwise XOR.
/// Stack: [a, b] → [a ^ b]
pub fn op_xor(frame: *Frame) ExecutionError.Error!void {
    std.debug.assert(frame.stack.size() >= 2);
    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe();
    frame.stack.set_top_unsafe(a ^ b);
}

/// NOT opcode (0x19) - Bitwise NOT operation
///
/// Pops one value from the stack and pushes its bitwise complement.
/// Stack: [a] → [~a]
pub fn op_not(frame: *Frame) ExecutionError.Error!void {
    std.debug.assert(frame.stack.size() >= 1);
    const a = frame.stack.peek_unsafe();
    frame.stack.set_top_unsafe(~a);
}

/// BYTE opcode (0x1A) - Extract single byte from word
///
/// Pops an index i and value from the stack, then pushes the i-th byte of the value.
/// Bytes are indexed from left to right (big-endian), with 0 being the most significant byte.
/// If i >= 32, returns 0.
///
/// Stack: [i, val] → [byte]
pub fn op_byte(frame: *Frame) ExecutionError.Error!void {
    std.debug.assert(frame.stack.size() >= 2);
    const i = frame.stack.pop_unsafe();
    const val = frame.stack.peek_unsafe();

    const result = if (i >= 32) 0 else blk: {
        const i_usize = @as(usize, @intCast(i));
        const shift_amount = (31 - i_usize) * 8;
        break :blk (val >> @intCast(shift_amount)) & 0xFF;
    };

    frame.stack.set_top_unsafe(result);
}

/// SHL opcode (0x1B) - Shift left operation
///
/// Pops shift amount and value from the stack, then pushes value shifted left by shift bits.
/// If shift >= 256, returns 0.
///
/// Stack: [shift, value] → [value << shift]
pub fn op_shl(frame: *Frame) ExecutionError.Error!void {
    std.debug.assert(frame.stack.size() >= 2);
    const shift = frame.stack.pop_unsafe();
    const value = frame.stack.peek_unsafe();

    const result = if (shift >= 256) 0 else value << @intCast(shift);

    frame.stack.set_top_unsafe(result);
}

/// SHR opcode (0x1C) - Logical shift right operation
///
/// Pops shift amount and value from the stack, then pushes value shifted right by shift bits.
/// Fills with zeros from the left. If shift >= 256, returns 0.
///
/// Stack: [shift, value] → [value >> shift]
pub fn op_shr(frame: *Frame) ExecutionError.Error!void {
    std.debug.assert(frame.stack.size() >= 2);
    const shift = frame.stack.pop_unsafe();
    const value = frame.stack.peek_unsafe();

    const result = if (shift >= 256) 0 else value >> @intCast(shift);
    if (shift == 224) {
        @import("../log.zig").debug("[SHR] value=0x{x:0>64} >> 224 = 0x{x:0>64}", .{ value, result });
    }

    frame.stack.set_top_unsafe(result);
}

/// SAR opcode (0x1D) - Arithmetic shift right operation
///
/// Pops shift amount and value from the stack, then pushes value arithmetically shifted right.
/// Sign extends by filling with the sign bit from the left. If shift >= 256, returns
/// 0 for positive numbers or MAX_U256 for negative numbers.
///
/// Stack: [shift, value] → [value >> shift] (arithmetic)
pub fn op_sar(frame: *Frame) ExecutionError.Error!void {
    std.debug.assert(frame.stack.size() >= 2);
    const shift = frame.stack.pop_unsafe();
    const value = frame.stack.peek_unsafe();

    const result = if (shift >= 256) blk: {
        const sign_bit = value >> 255;
        break :blk if (sign_bit == 1) @as(u256, std.math.maxInt(u256)) else @as(u256, 0);
    } else blk: {
        const shift_amount = @as(u8, @intCast(shift));
        const value_i256 = @as(i256, @bitCast(value));
        const result_i256 = value_i256 >> shift_amount;
        break :blk @as(u256, @bitCast(result_i256));
    };

    frame.stack.set_top_unsafe(result);
}
