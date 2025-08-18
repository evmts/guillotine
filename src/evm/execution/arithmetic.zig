/// Arithmetic operations for the Ethereum Virtual Machine
///
/// This module implements all arithmetic opcodes for the EVM, including basic
/// arithmetic (ADD, SUB, MUL, DIV), signed operations (SDIV, SMOD), modular
/// arithmetic (MOD, ADDMOD, MULMOD), exponentiation (EXP), and sign extension
/// (SIGNEXTEND).
///
/// ## Design Philosophy
///
/// All operations follow a consistent pattern:
/// 1. Pop operands from the stack (validated by jump table)
/// 2. Perform the arithmetic operation
/// 3. Push the result back onto the stack
///
/// ## Performance Optimizations
///
/// - **Unsafe Operations**: Stack bounds checking is done by the jump table,
///   allowing opcodes to use unsafe stack operations for maximum performance
/// - **In-Place Updates**: Results are written directly to stack slots to
///   minimize memory operations
/// - **Wrapping Arithmetic**: Uses Zig's wrapping operators (`+%`, `*%`, `-%`)
///   for correct 256-bit overflow behavior
///
/// ## Safety Note
///
/// All handlers in this module use `unsafe` stack operations (pop_unsafe, peek_unsafe,
/// set_top_unsafe) because stack bounds checking and validation is performed by the
/// interpreter's jump table before dispatching to these handlers. This eliminates
/// redundant checks and maximizes performance.
///
/// ## EVM Arithmetic Rules
///
/// - All values are 256-bit unsigned integers (u256)
/// - Overflow wraps around (e.g., MAX_U256 + 1 = 0)
/// - Division by zero returns 0 (not an error)
/// - Modulo by zero returns 0 (not an error)
/// - Signed operations interpret u256 as two's complement i256
///
/// ## Gas Costs
///
/// - ADD, SUB, NOT: 3 gas (GasFastestStep)
/// - MUL, DIV, SDIV, MOD, SMOD: 5 gas (GasFastStep)
/// - ADDMOD, MULMOD, SIGNEXTEND: 8 gas (GasMidStep)
/// - EXP: 10 gas + 50 per byte of exponent
///
/// ## Stack Requirements
///
/// Operation    | Stack Input | Stack Output | Description
/// -------------|-------------|--------------|-------------
/// ADD          | [a, b]      | [a + b]      | Addition with overflow
/// MUL          | [a, b]      | [a * b]      | Multiplication with overflow
/// SUB          | [a, b]      | [a - b]      | Subtraction with underflow
/// DIV          | [a, b]      | [a / b]      | Division (b=0 returns 0)
/// SDIV         | [a, b]      | [a / b]      | Signed division
/// MOD          | [a, b]      | [a % b]      | Modulo (b=0 returns 0)
/// SMOD         | [a, b]      | [a % b]      | Signed modulo
/// ADDMOD       | [a, b, n]   | [(a+b)%n]    | Addition modulo n
/// MULMOD       | [a, b, n]   | [(a*b)%n]    | Multiplication modulo n
/// EXP          | [a, b]      | [a^b]        | Exponentiation
/// SIGNEXTEND   | [b, x]      | [y]          | Sign extend x from byte b
const std = @import("std");
const builtin = @import("builtin");
const ExecutionError = @import("execution_error.zig");
const Frame = @import("../stack_frame.zig").StackFrame;
const primitives = @import("primitives");
const U256 = primitives.Uint(256, 4);
const Log = @import("../log.zig");

// Safety check constants - only enabled in Debug and ReleaseSafe modes
// These checks are redundant after analysis.zig validates operations
const SAFE_STACK_CHECKS = builtin.mode != .ReleaseFast and builtin.mode != .ReleaseSmall;

const ArithmeticOpType = enum {
    add,
    mul,
    sub,
    div,
    sdiv,
    mod,
    smod,
    addmod,
    mulmod,
    exp,
    signextend,
};

// Imports for tests
const Vm = @import("../evm.zig");
const MemoryDatabase = @import("../state/memory_database.zig");
const Operation = @import("../opcodes/operation.zig");

/// ADD opcode (0x01) - Addition with wrapping overflow
/// Static gas cost (3 gas) is consumed externally by the interpreter
pub fn op_add(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        std.debug.assert(frame.stack.size() >= 2);
    }

    const top = frame.stack.pop_unsafe();
    const top_minus_1 = frame.stack.peek_unsafe();
    const result = top_minus_1 +% top;
    frame.stack.set_top_unsafe(result);
}

/// MUL opcode (0x02) - Multiplication operation
/// Static gas cost (5 gas) is consumed externally by the interpreter
///
/// Pops two values from the stack, multiplies them with wrapping overflow,
/// and pushes the result.
///
/// ## Stack Input
/// - `a`: First operand (second from top)
/// - `b`: Second operand (top)
///
/// ## Stack Output
/// - `a * b`: Product with 256-bit wrapping overflow
///
/// ## Execution
/// 1. Pop b from stack
/// 2. Pop a from stack
/// 3. Calculate product = (a * b) mod 2^256
/// 4. Push product to stack
///
/// ## Example
/// Stack: [10, 20] => [200]
/// Stack: [2^128, 2^128] => [0] (overflow wraps)
pub fn op_mul(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        std.debug.assert(frame.stack.size() >= 2);
    }

    const top = frame.stack.pop_unsafe();
    const top_minus_1 = frame.stack.peek_unsafe();

    // Use optimized U256 multiplication
    const top_u256 = U256.from_u256_unsafe(top);
    const top_minus_1_u256 = U256.from_u256_unsafe(top_minus_1);
    const product_u256 = top_minus_1_u256.wrapping_mul(top_u256);
    const product = product_u256.to_u256_unsafe();

    frame.stack.set_top_unsafe(product);
}

/// SUB opcode (0x03) - Subtraction operation
/// Static gas cost (3 gas) is consumed externally by the interpreter
///
/// Pops two values from the stack, subtracts the top from the second,
/// with wrapping underflow, and pushes the result.
///
/// ## Stack Input
/// - `a`: Minuend (second from top)
/// - `b`: Subtrahend (top)
///
/// ## Stack Output
/// - `a - b`: Difference with 256-bit wrapping underflow
///
/// ## Execution
/// 1. Pop b from stack
/// 2. Pop a from stack
/// 3. Calculate result = (a - b) mod 2^256
/// 4. Push result to stack
///
/// ## Example
/// Stack: [30, 10] => [20]
/// Stack: [10, 20] => [2^256 - 10] (underflow wraps)
pub fn op_sub(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        std.debug.assert(frame.stack.size() >= 2);
    }

    const top = frame.stack.pop_unsafe();
    const top_minus_1 = frame.stack.peek_unsafe();
    const result = top_minus_1 -% top;

    frame.stack.set_top_unsafe(result);
}

/// DIV opcode (0x04) - Unsigned integer division
/// Static gas cost (5 gas) is consumed externally by the interpreter
///
/// Pops two values from the stack, divides the second by the top,
/// and pushes the integer quotient. Division by zero returns 0.
///
/// ## Stack Input
/// - `a`: Dividend (second from top)
/// - `b`: Divisor (top)
///
/// ## Stack Output
/// - `a / b`: Integer quotient, or 0 if b = 0
///
/// ## Execution
/// 1. Pop b from stack
/// 2. Pop a from stack
/// 3. If b = 0, result = 0 (no error)
/// 4. Else result = floor(a / b)
/// 5. Push result to stack
///
/// ## Example
/// Stack: [20, 5] => [4]
/// Stack: [7, 3] => [2] (integer division)
/// Stack: [100, 0] => [0] (division by zero)
///
/// ## Note
/// Unlike most programming languages, EVM division by zero does not
/// throw an error but returns 0. This is a deliberate design choice
/// to avoid exceptional halting conditions.
pub fn op_div(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        std.debug.assert(frame.stack.size() >= 2);
    }

    const top = frame.stack.pop_unsafe();
    const top_minus_1 = frame.stack.peek_unsafe();

    // EVM semantics: second_from_top / top
    const result = if (top == 0) blk: {
        break :blk 0;
    } else blk: {
        const result_u256 = U256.from_u256_unsafe(top_minus_1).wrapping_div(U256.from_u256_unsafe(top));
        break :blk result_u256.to_u256_unsafe();
    };
    frame.stack.set_top_unsafe(result);
}

/// SDIV opcode (0x05) - Signed integer division
/// Static gas cost (5 gas) is consumed externally by the interpreter
///
/// Pops two values from the stack, interprets them as signed integers,
/// divides the second from top by the top, and pushes the signed quotient.
/// Division by zero returns 0.
///
/// ## Stack Input
/// - `a`: Dividend as signed i256 (second from top)
/// - `b`: Divisor as signed i256 (top)
///
/// ## Stack Output
/// - `a / b`: Signed integer quotient, or 0 if b = 0
///
/// ## Execution
/// 1. Pop b from stack (divisor)
/// 2. Peek a from stack (dividend, stays on stack)
/// 3. Interpret both as two's complement signed integers
/// 4. If b = 0, result = 0
/// 5. Else if a = -2^255 and b = -1, result = -2^255 (overflow case)
/// 6. Else result = truncated division a / b
/// 7. Replace top of stack with result
///
/// ## Example
/// Stack: [20, 5] => [4]
/// Stack: [-20, 5] => [-4] (0xfff...fec / 5)
/// Stack: [-20, -5] => [4]
/// Stack: [MIN_I256, -1] => [MIN_I256] (overflow protection)
///
/// ## Note
/// The special case for MIN_I256 / -1 prevents integer overflow,
/// as the mathematical result (2^255) cannot be represented in i256.
/// In this case, we return MIN_I256 to match EVM behavior.
pub fn op_sdiv(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        std.debug.assert(frame.stack.size() >= 2);
    }

    const top = frame.stack.pop_unsafe();
    const top_minus_1 = frame.stack.peek_unsafe();

    // EVM semantics: second_from_top / top - signed division
    var result: u256 = undefined;
    if (top == 0) {
        @branchHint(.unlikely);
        result = 0;
    } else {
        const top_minus_1_i256 = @as(i256, @bitCast(top_minus_1));
        const top_i256 = @as(i256, @bitCast(top));
        const min_i256 = std.math.minInt(i256);
        if (top_minus_1_i256 == min_i256 and top_i256 == -1) {
            @branchHint(.unlikely);
            // MIN_I256 / -1 = MIN_I256 (overflow wraps)
            // This matches EVM behavior where overflow wraps around
            result = top_minus_1;
        } else {
            const result_i256 = @divTrunc(top_minus_1_i256, top_i256);
            result = @as(u256, @bitCast(result_i256));
        }
    }

    frame.stack.set_top_unsafe(result);
}

/// MOD opcode (0x06) - Modulo remainder operation
/// Static gas cost (5 gas) is consumed externally by the interpreter
///
/// Pops two values from the stack, calculates the remainder of dividing
/// the second by the top, and pushes the result. Modulo by zero returns 0.
///
/// ## Stack Input
/// - `a`: Dividend (second from top)
/// - `b`: Divisor (top)
///
/// ## Stack Output
/// - `a % b`: Remainder of a / b, or 0 if b = 0
///
/// ## Execution
/// 1. Pop b from stack
/// 2. Pop a from stack
/// 3. If b = 0, result = 0 (no error)
/// 4. Else result = a modulo b
/// 5. Push result to stack
///
/// ## Example
/// Stack: [17, 5] => [2]
/// Stack: [100, 10] => [0]
/// Stack: [7, 0] => [0] (modulo by zero)
///
/// ## Note
/// The result is always in range [0, b-1] for b > 0.
/// Like DIV, modulo by zero returns 0 rather than throwing an error.
pub fn op_mod(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        std.debug.assert(frame.stack.size() >= 2);
    }

    const top = frame.stack.pop_unsafe();
    const top_minus_1 = frame.stack.peek_unsafe();

    // EVM semantics: second_from_top % top
    const result = if (top == 0) blk: {
        @branchHint(.unlikely);
        break :blk 0;
    } else blk: {
        // Use optimized U256 modulo
        const top_minus_1_u256 = U256.from_u256_unsafe(top_minus_1);
        const top_u256 = U256.from_u256_unsafe(top);
        const div_rem_result = top_minus_1_u256.div_rem(top_u256);
        break :blk div_rem_result.remainder.to_u256_unsafe();
    };

    frame.stack.set_top_unsafe(result);
}

/// SMOD opcode (0x07) - Signed modulo remainder operation
/// Static gas cost (5 gas) is consumed externally by the interpreter
///
/// Pops two values from the stack, interprets them as signed integers,
/// calculates the signed remainder, and pushes the result.
/// Modulo by zero returns 0.
///
/// ## Stack Input
/// - `a`: Dividend as signed i256 (second from top)
/// - `b`: Divisor as signed i256 (top)
///
/// ## Stack Output
/// - `a % b`: Signed remainder, or 0 if b = 0
///
/// ## Execution
/// 1. Pop b from stack
/// 2. Pop a from stack
/// 3. Interpret both as two's complement signed integers
/// 4. If b = 0, result = 0
/// 5. Else result = signed remainder of a / b
/// 6. Push result to stack
///
/// ## Example
/// Stack: [17, 5] => [2]
/// Stack: [-17, 5] => [-2] (sign follows dividend)
/// Stack: [17, -5] => [2]
/// Stack: [-17, -5] => [-2]
///
/// ## Note
/// In signed modulo, the result has the same sign as the dividend (a).
/// This follows the Euclidean division convention where:
/// a = b * q + r, where |r| < |b| and sign(r) = sign(a)
pub fn op_smod(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        std.debug.assert(frame.stack.size() >= 2);
    }

    const top = frame.stack.pop_unsafe();
    const top_minus_1 = frame.stack.peek_unsafe();

    // EVM semantics: second_from_top % top - signed modulo
    var result: u256 = undefined;
    if (top == 0) {
        @branchHint(.unlikely);
        result = 0;
    } else {
        const top_minus_1_i256 = @as(i256, @bitCast(top_minus_1));
        const top_i256 = @as(i256, @bitCast(top));
        const result_i256 = @rem(top_minus_1_i256, top_i256);
        result = @as(u256, @bitCast(result_i256));
    }

    frame.stack.set_top_unsafe(result);
}

/// ADDMOD opcode (0x08) - Addition modulo n
/// Static gas cost (8 gas) is consumed externally by the interpreter
///
/// Pops three values from the stack, adds the first two, then takes
/// the modulo with the third value. Handles overflow correctly by
/// computing (a + b) mod n, not ((a + b) mod 2^256) mod n.
///
/// ## Stack Input
/// - `a`: First addend (third from top)
/// - `b`: Second addend (second from top)
/// - `n`: Modulus (top)
///
/// ## Stack Output
/// - `(a + b) % n`: Sum modulo n, or 0 if n = 0
///
/// ## Execution
/// 1. Pop n from stack (modulus)
/// 2. Pop b from stack (second addend)
/// 3. Pop a from stack (first addend)
/// 4. If n = 0, result = 0
/// 5. Else result = (a + b) mod n
/// 6. Push result to stack
///
/// ## Example
/// Stack: [10, 20, 7] => [2] ((10 + 20) % 7)
/// Stack: [MAX_U256, 5, 10] => [4] (overflow handled)
/// Stack: [50, 50, 0] => [0] (modulo by zero)
///
/// ## Note
/// This operation correctly computes (a + b) mod n even when
/// a + b exceeds 2^256, using specialized algorithms to avoid
/// intermediate overflow.
pub fn op_addmod(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        std.debug.assert(frame.stack.size() >= 3);
    }

    const top = frame.stack.pop_unsafe();
    const top_minus_1 = frame.stack.pop_unsafe();
    const top_minus_2 = frame.stack.peek_unsafe();

    // EVM semantics: (second_from_top + third_from_top) % top
    var result: u256 = undefined;
    if (top == 0) {
        result = 0;
    } else {
        // Use U256 add_mod to properly handle overflow
        const top_minus_2_u256 = U256.from_u256_unsafe(top_minus_2);
        const top_minus_1_u256 = U256.from_u256_unsafe(top_minus_1);
        const top_u256 = U256.from_u256_unsafe(top);
        const result_u256 = top_minus_2_u256.add_mod(top_minus_1_u256, top_u256);
        result = result_u256.to_u256_unsafe();
    }

    frame.stack.set_top_unsafe(result);
}

/// MULMOD opcode (0x09) - Multiplication modulo n
/// Static gas cost (8 gas) is consumed externally by the interpreter
///
/// Pops three values from the stack, multiplies the first two, then
/// takes the modulo with the third value. Correctly handles cases where
/// the product exceeds 2^256.
///
/// ## Stack Input
/// - `a`: First multiplicand (third from top)
/// - `b`: Second multiplicand (second from top)
/// - `n`: Modulus (top)
///
/// ## Stack Output
/// - `(a * b) % n`: Product modulo n, or 0 if n = 0
///
/// ## Execution
/// 1. Pop n from stack (modulus)
/// 2. Pop b from stack (second multiplicand)
/// 3. Pop a from stack (first multiplicand)
/// 4. If n = 0, result = 0
/// 5. Else compute (a * b) mod n using Russian peasant algorithm
/// 6. Push result to stack
///
/// ## Algorithm
/// Uses Russian peasant multiplication with modular reduction:
/// - Reduces inputs modulo n first
/// - Builds product bit by bit, reducing modulo n at each step
/// - Avoids need for 512-bit intermediate values
///
/// ## Example
/// Stack: [10, 20, 7] => [4] ((10 * 20) % 7)
/// Stack: [2^128, 2^128, 100] => [0] (handles overflow)
/// Stack: [50, 50, 0] => [0] (modulo by zero)
///
/// ## Note
/// This operation correctly computes (a * b) mod n even when
/// a * b exceeds 2^256, unlike naive (a *% b) % n approach.
pub fn op_mulmod(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        std.debug.assert(frame.stack.size() >= 3);
    }

    const top = frame.stack.pop_unsafe();
    const top_minus_1 = frame.stack.pop_unsafe();
    const top_minus_2 = frame.stack.peek_unsafe();

    // EVM semantics: (second_from_top * third_from_top) % top
    var result: u256 = undefined;
    if (top == 0) {
        result = 0;
    } else {
        // Use optimized U256 mulmod
        const top_minus_2_u256 = U256.from_u256_unsafe(top_minus_2);
        const top_minus_1_u256 = U256.from_u256_unsafe(top_minus_1);
        const top_u256 = U256.from_u256_unsafe(top);
        const result_u256 = top_minus_2_u256.mul_mod(top_minus_1_u256, top_u256);
        result = result_u256.to_u256_unsafe();
    }

    frame.stack.set_top_unsafe(result);
}

/// EXP opcode (0x0A) - Exponentiation
/// Static gas cost (10 gas) is consumed externally by the interpreter
/// Dynamic gas cost (50 per byte of exponent) is consumed here
///
/// Pops two values from the stack and raises the second to the power
/// of the top. All operations are modulo 2^256.
///
/// ## Stack Input
/// - `a`: Base (second from top)
/// - `b`: Exponent (top)
///
/// ## Stack Output
/// - `a^b`: Result of a raised to power b, modulo 2^256
///
/// ## Gas Cost
/// - Static: 10 gas (consumed externally)
/// - Dynamic: 50 gas per byte of exponent (consumed here)
/// - Total: 10 + 50 * byte_size_of_exponent
///
/// ## Execution
/// 1. Pop b from stack (exponent)
/// 2. Pop a from stack (base)
/// 3. Calculate dynamic gas cost based on exponent size
/// 4. Consume the dynamic gas
/// 5. Calculate a^b using binary exponentiation
/// 6. Push result to stack
///
/// ## Algorithm
/// Uses optimized square-and-multiply algorithm:
/// - Processes exponent bit by bit from right to left
/// - Only multiplies when a bit is set in the exponent
/// - Reduces operations from O(n) to O(log n)
/// - Example: 2^255 requires only 8 multiplications instead of 255
///
/// ## Example
/// Stack: [2, 10] => [1024]
/// Stack: [3, 4] => [81]
/// Stack: [10, 0] => [1] (anything^0 = 1)
/// Stack: [0, 10] => [0] (0^anything = 0, except 0^0 = 1)
///
/// ## Gas Examples
/// - 2^10: 10 + 50*1 = 60 gas (exponent fits in 1 byte)
/// - 2^256: 10 + 50*2 = 110 gas (exponent needs 2 bytes)
/// - 2^(2^255): 10 + 50*32 = 1610 gas (huge exponent)
pub fn op_exp(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        std.debug.assert(frame.stack.size() >= 2);
    }

    const top = frame.stack.pop_unsafe();
    const top_minus_1 = frame.stack.peek_unsafe();

    // EVM semantics: second_from_top ^ top
    const base = top_minus_1;
    const exponent = top;

    // Calculate gas cost based on exponent byte size
    var exp_copy = exponent;
    var byte_size: u64 = 0;
    while (exp_copy > 0) : (exp_copy >>= 8) {
        byte_size += 1;
    }
    if (byte_size > 0) {
        @branchHint(.likely);
        const gas_cost = 50 * byte_size;
        try frame.consume_gas(gas_cost);
    }

    // Early exit optimizations
    if (exponent == 0) {
        frame.stack.set_top_unsafe(1);
        return;
    }
    if (base == 0) {
        frame.stack.set_top_unsafe(0);
        return;
    }
    if (base == 1) {
        frame.stack.set_top_unsafe(1);
        return;
    }
    if (exponent == 1) {
        frame.stack.set_top_unsafe(base);
        return;
    }

    // Square-and-multiply algorithm
    var result: u256 = 1;
    var b_copy = base;
    var e = exponent;

    while (e > 0) {
        if ((e & 1) == 1) {
            const mul_result = @mulWithOverflow(result, b_copy);
            result = mul_result[0];
        }
        if (e > 1) {
            const square_result = @mulWithOverflow(b_copy, b_copy);
            b_copy = square_result[0];
        }
        e >>= 1;
    }

    frame.stack.set_top_unsafe(result);
}

/// SIGNEXTEND opcode (0x0B) - Sign extension
/// Static gas cost (5 gas) is consumed externally by the interpreter
///
/// Extends the sign bit of a value from a given byte position to fill
/// all higher-order bits. Used to convert smaller signed integers to
/// full 256-bit representation.
///
/// ## Stack Input
/// - `b`: Byte position of sign bit (0-indexed from right)
/// - `x`: Value to sign-extend
///
/// ## Stack Output
/// - Sign-extended value
///
/// ## Execution
/// 1. Pop b from stack (byte position)
/// 2. Pop x from stack (value to extend)
/// 3. If b >= 31, return x unchanged (already full width)
/// 4. Find sign bit at position (b * 8 + 7)
/// 5. If sign bit = 1, fill higher bits with 1s
/// 6. If sign bit = 0, fill higher bits with 0s
/// 7. Push result to stack
///
/// ## Byte Position
/// - b = 0: Extend from byte 0 (bits 0-7, rightmost byte)
/// - b = 1: Extend from byte 1 (bits 8-15)
/// - b = 31: Extend from byte 31 (bits 248-255, leftmost byte)
///
/// ## Example
/// Stack: [0, 0x7F] => [0x7F] (positive sign, no change)
/// Stack: [0, 0x80] => [0xFFFF...FF80] (negative sign extended)
/// Stack: [1, 0x80FF] => [0xFFFF...80FF] (extend from byte 1)
/// Stack: [31, x] => [x] (already full width)
///
/// ## Use Cases
/// - Converting int8/int16/etc to int256
/// - Arithmetic on mixed-width signed integers
/// - Implementing higher-level language semantics
pub fn op_signextend(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        std.debug.assert(frame.stack.size() >= 2);
    }

    const top = frame.stack.pop_unsafe();
    const top_minus_1 = frame.stack.peek_unsafe();

    var result: u256 = undefined;

    if (top >= 31) {
        @branchHint(.unlikely);
        result = top_minus_1;
    } else {
        const byte_index = @as(u8, @intCast(top));
        const sign_bit_pos = byte_index * 8 + 7;

        const sign_bit = (top_minus_1 >> @intCast(sign_bit_pos)) & 1;

        const keep_bits = sign_bit_pos + 1;

        if (sign_bit == 1) {
            // Sign bit is 1, extend with 1s
            if (keep_bits >= 256) {
                result = top_minus_1;
            } else {
                const ones_mask = ~((@as(u256, 1) << @intCast(keep_bits)) - 1);
                result = top_minus_1 | ones_mask;
            }
        } else {
            // Sign bit is 0, extend with 0s (just mask out upper bits)
            if (keep_bits >= 256) {
                result = top_minus_1;
            } else {
                const zero_mask = (@as(u256, 1) << @intCast(keep_bits)) - 1;
                result = top_minus_1 & zero_mask;
            }
        }
    }

    frame.stack.set_top_unsafe(result);
}

