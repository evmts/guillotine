//! Bitwise operations for the Ethereum Virtual Machine
//!
//! This module implements all bitwise opcodes for the EVM including AND, OR, XOR,
//! NOT, BYTE, SHL (shift left), SHR (shift right), and SAR (arithmetic shift right).
//!
//! All operations work on 256-bit unsigned integers and follow standard bitwise
//! semantics with EVM-specific behavior for edge cases.
//!
//! ## Safety Note
//!
//! All handlers in this module use `unsafe` stack operations (pop_unsafe, peek_unsafe,
//! set_top_unsafe) because stack bounds checking and validation is performed by the
//! interpreter's jump table before dispatching to these handlers. This eliminates
//! redundant checks and maximizes performance.
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
const builtin = @import("builtin");
const ExecutionError = @import("execution_error.zig");
const Frame = @import("../stack_frame.zig").StackFrame;
const primitives = @import("primitives");

// Safety check constants - only enabled in Debug and ReleaseSafe modes
const SAFE_STACK_CHECKS = builtin.mode != .ReleaseFast and builtin.mode != .ReleaseSmall;

/// AND opcode (0x16) - Bitwise AND operation
/// Static gas cost (3 gas) is consumed externally by the interpreter
///
/// Pops two values from the stack and pushes their bitwise AND.
///
/// ## Stack Input
/// - `a`: First operand (second from top)
/// - `b`: Second operand (top)
///
/// ## Stack Output
/// - `a & b`: Bitwise AND of the two operands
///
/// ## Example
/// Stack: [0xFF00, 0x0FF0] => [0x0F00]
/// Stack: [0xFFFF, 0x1234] => [0x1234]
pub fn op_and(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        std.debug.assert(frame.stack.size() >= 2);
    }
    
    const top = frame.stack.pop_unsafe();
    const top_minus_1 = frame.stack.peek_unsafe();
    const result = top_minus_1 & top;
    frame.stack.set_top_unsafe(result);
}

/// OR opcode (0x17) - Bitwise OR operation
/// Static gas cost (3 gas) is consumed externally by the interpreter
///
/// Pops two values from the stack and pushes their bitwise OR.
///
/// ## Stack Input
/// - `a`: First operand (second from top)
/// - `b`: Second operand (top)
///
/// ## Stack Output
/// - `a | b`: Bitwise OR of the two operands
///
/// ## Example
/// Stack: [0xFF00, 0x00FF] => [0xFFFF]
/// Stack: [0x1200, 0x0034] => [0x1234]
pub fn op_or(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        std.debug.assert(frame.stack.size() >= 2);
    }
    
    const top = frame.stack.pop_unsafe();
    const top_minus_1 = frame.stack.peek_unsafe();
    frame.stack.set_top_unsafe(top_minus_1 | top);
}

/// XOR opcode (0x18) - Bitwise XOR operation
/// Static gas cost (3 gas) is consumed externally by the interpreter
///
/// Pops two values from the stack and pushes their bitwise XOR.
///
/// ## Stack Input
/// - `a`: First operand (second from top)
/// - `b`: Second operand (top)
///
/// ## Stack Output
/// - `a ^ b`: Bitwise XOR of the two operands
///
/// ## Example
/// Stack: [0xFF00, 0xFFFF] => [0x00FF]
/// Stack: [0x1234, 0x1234] => [0x0000]
pub fn op_xor(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        std.debug.assert(frame.stack.size() >= 2);
    }
    
    const top = frame.stack.pop_unsafe();
    const top_minus_1 = frame.stack.peek_unsafe();
    frame.stack.set_top_unsafe(top_minus_1 ^ top);
}

/// NOT opcode (0x19) - Bitwise NOT operation
/// Static gas cost (3 gas) is consumed externally by the interpreter
///
/// Pops one value from the stack and pushes its bitwise complement.
///
/// ## Stack Input
/// - `a`: Value to complement (top)
///
/// ## Stack Output
/// - `~a`: Bitwise complement of the value
///
/// ## Example
/// Stack: [0x00FF] => [0xFFFFFFFF...FF00]
/// Stack: [0x0000] => [0xFFFFFFFF...FFFF]
pub fn op_not(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        std.debug.assert(frame.stack.size() >= 1);
    }
    
    const top = frame.stack.peek_unsafe();
    frame.stack.set_top_unsafe(~top);
}

/// BYTE opcode (0x1A) - Extract single byte from word
/// Static gas cost (3 gas) is consumed externally by the interpreter
///
/// Pops an index i and value from the stack, then pushes the i-th byte of the value.
/// Bytes are indexed from left to right (big-endian), with 0 being the most significant byte.
/// If i >= 32, returns 0.
///
/// ## Stack Input
/// - `i`: Byte index (0-31) (top)
/// - `val`: Value to extract byte from (second from top)
///
/// ## Stack Output
/// - The i-th byte of val, or 0 if i >= 32
///
/// ## Example
/// Stack: [0x1234567890ABCDEF, 7] => [0xEF] (rightmost byte)
/// Stack: [0x1234567890ABCDEF, 0] => [0x12] (leftmost byte)
/// Stack: [0x1234567890ABCDEF, 32] => [0x00] (out of range)
pub fn op_byte(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        std.debug.assert(frame.stack.size() >= 2);
    }
    
    const top = frame.stack.pop_unsafe();
    const top_minus_1 = frame.stack.peek_unsafe();

    const result = if (top >= 32) 0 else blk: {
        const i_usize = @as(usize, @intCast(top));
        const shift_amount = (31 - i_usize) * 8;
        break :blk (top_minus_1 >> @intCast(shift_amount)) & 0xFF;
    };

    frame.stack.set_top_unsafe(result);
}

/// SHL opcode (0x1B) - Shift left operation
/// Static gas cost (3 gas) is consumed externally by the interpreter
///
/// Pops shift amount and value from the stack, then pushes value shifted left by shift bits.
/// If shift >= 256, returns 0.
///
/// ## Stack Input
/// - `shift`: Number of bits to shift (top)
/// - `value`: Value to be shifted (second from top)
///
/// ## Stack Output
/// - `value << shift`: Value shifted left, or 0 if shift >= 256
///
/// ## Example
/// Stack: [0x01, 4] => [0x10]
/// Stack: [0xFF, 8] => [0xFF00]
/// Stack: [0x01, 256] => [0x00] (shift too large)
pub fn op_shl(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        std.debug.assert(frame.stack.size() >= 2);
    }
    
    const top = frame.stack.pop_unsafe();
    const top_minus_1 = frame.stack.peek_unsafe();

    const result = if (top >= 256) 0 else top_minus_1 << @intCast(top);

    frame.stack.set_top_unsafe(result);
}

/// SHR opcode (0x1C) - Logical shift right operation
/// Static gas cost (3 gas) is consumed externally by the interpreter
///
/// Pops shift amount and value from the stack, then pushes value shifted right by shift bits.
/// Fills with zeros from the left. If shift >= 256, returns 0.
///
/// ## Stack Input
/// - `shift`: Number of bits to shift (top)
/// - `value`: Value to be shifted (second from top)
///
/// ## Stack Output
/// - `value >> shift`: Value shifted right, or 0 if shift >= 256
///
/// ## Example
/// Stack: [0x10, 4] => [0x01]
/// Stack: [0xFF00, 8] => [0xFF]
/// Stack: [0xFF, 256] => [0x00] (shift too large)
pub fn op_shr(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        std.debug.assert(frame.stack.size() >= 2);
    }
    
    const top = frame.stack.pop_unsafe();
    const top_minus_1 = frame.stack.peek_unsafe();

    const result = if (top >= 256) 0 else top_minus_1 >> @intCast(top);

    frame.stack.set_top_unsafe(result);
}

/// SAR opcode (0x1D) - Arithmetic shift right operation
/// Static gas cost (3 gas) is consumed externally by the interpreter
///
/// Pops shift amount and value from the stack, then pushes value arithmetically shifted right.
/// Sign extends by filling with the sign bit from the left. If shift >= 256, returns
/// 0 for positive numbers or MAX_U256 for negative numbers.
///
/// ## Stack Input
/// - `shift`: Number of bits to shift (top)
/// - `value`: Value to be shifted (second from top)
///
/// ## Stack Output
/// - Arithmetically shifted value with sign extension
///
/// ## Example
/// Stack: [0x10, 4] => [0x01] (positive number)
/// Stack: [0xFFFFFFF0, 4] => [0xFFFFFFFF] (negative number, sign extended)
/// Stack: [0x80000000...0000, 256] => [0xFFFFFFFF...FFFF] (negative, shift >= 256)
pub fn op_sar(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        std.debug.assert(frame.stack.size() >= 2);
    }
    
    const top = frame.stack.pop_unsafe();
    const top_minus_1 = frame.stack.peek_unsafe();

    const result = if (top >= 256) blk: {
        const sign_bit = top_minus_1 >> 255;
        break :blk if (sign_bit == 1) @as(u256, std.math.maxInt(u256)) else @as(u256, 0);
    } else blk: {
        const shift_amount = @as(u8, @intCast(top));
        const value_i256 = @as(i256, @bitCast(top_minus_1));
        const result_i256 = value_i256 >> shift_amount;
        break :blk @as(u256, @bitCast(result_i256));
    };

    frame.stack.set_top_unsafe(result);
}
