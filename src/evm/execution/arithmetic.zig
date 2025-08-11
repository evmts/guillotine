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
const ExecutionError = @import("execution_error.zig");
const Frame = @import("../frame.zig").Frame;
const primitives = @import("primitives");
const U256 = primitives.Uint(256, 4);
const Log = @import("../log.zig");

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
pub fn op_add(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 2);

    const top = frame.stack.pop_unsafe(); // top
    const top_minus_1 = frame.stack.peek_unsafe().*; // second from top
    const result = top_minus_1 +% top;
    frame.stack.set_top_unsafe(result);
}

/// MUL opcode (0x02) - Multiplication operation
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
/// ## Gas Cost
/// 5 gas (GasFastStep)
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
pub fn op_mul(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 2);

    const top = frame.stack.pop_unsafe();
    const top_minus_1 = frame.stack.peek_unsafe().*;

    // Use optimized U256 multiplication
    const a_u256 = U256.from_u256_unsafe(top_minus_1);
    const b_u256 = U256.from_u256_unsafe(top);
    const product_u256 = a_u256.wrapping_mul(b_u256);
    const product = product_u256.to_u256_unsafe();

    frame.stack.set_top_unsafe(product);
}

/// SUB opcode (0x03) - Subtraction operation
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
/// ## Gas Cost
/// 3 gas (GasFastestStep)
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
pub fn op_sub(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 2);

    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;

    // EVM semantics: a - b (second - top)
    const result = a -% b;

    Log.debug("SUB: a(second)={x:0>64} b(top)={x:0>64} -> res={x:0>64}", .{ a, b, result });

    frame.stack.set_top_unsafe(result);
}

/// DIV opcode (0x04) - Unsigned integer division
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
/// ## Gas Cost
/// 5 gas (GasFastStep)
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
pub fn op_div(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 2);

    const divisor = frame.stack.pop_unsafe();
    const dividend = frame.stack.peek_unsafe().*;

    // EVM semantics: dividend / divisor
    const result = if (divisor == 0) blk: {
        break :blk 0;
    } else blk: {
        const result_u256 = U256.from_u256_unsafe(dividend).wrapping_div(U256.from_u256_unsafe(divisor));
        break :blk result_u256.to_u256_unsafe();
    };

    frame.stack.set_top_unsafe(result);
}

/// SDIV opcode (0x05) - Signed integer division
///
/// Pops two values from the stack, interprets them as signed integers,
/// divides the first popped value by the second, and pushes the signed quotient.
/// Division by zero returns 0.
///
/// ## Stack Input
/// - `b`: Dividend as signed i256 (top)
/// - `a`: Divisor as signed i256 (second from top)
///
/// ## Stack Output
/// - `b / a`: Signed integer quotient, or 0 if a = 0
///
/// ## Gas Cost
/// 5 gas (GasFastStep)
///
/// ## Execution
/// 1. Pop b from stack (dividend)
/// 2. Peek a from stack (divisor, stays on stack)
/// 3. Interpret both as two's complement signed integers
/// 4. If a = 0, result = 0
/// 5. Else if b = -2^255 and a = -1, result = -2^255 (overflow case)
/// 6. Else result = truncated division b / a
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
pub fn op_sdiv(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 2);

    const divisor = frame.stack.pop_unsafe();
    const dividend = frame.stack.peek_unsafe().*;

    // EVM semantics: dividend / divisor - signed division
    var result: u256 = undefined;
    if (divisor == 0) {
        @branchHint(.unlikely);
        result = 0;
    } else {
        const dividend_i256 = @as(i256, @bitCast(dividend));
        const divisor_i256 = @as(i256, @bitCast(divisor));
        const min_i256 = std.math.minInt(i256);
        if (dividend_i256 == min_i256 and divisor_i256 == -1) {
            @branchHint(.unlikely);
            // MIN_I256 / -1 = MIN_I256 (overflow wraps)
            // This matches EVM behavior where overflow wraps around
            result = dividend;
        } else {
            const result_i256 = @divTrunc(dividend_i256, divisor_i256);
            result = @as(u256, @bitCast(result_i256));
        }
    }

    frame.stack.set_top_unsafe(result);
}

/// MOD opcode (0x06) - Modulo remainder operation
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
/// ## Gas Cost
/// 5 gas (GasFastStep)
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
pub fn op_mod(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 2);

    const divisor = frame.stack.pop_unsafe();
    const dividend = frame.stack.peek_unsafe().*;

    // EVM semantics: dividend % divisor
    const result = if (divisor == 0) blk: {
        @branchHint(.unlikely);
        break :blk 0;
    } else blk: {
        // Use optimized U256 modulo
        const dividend_u256 = U256.from_u256_unsafe(dividend);
        const divisor_u256 = U256.from_u256_unsafe(divisor);
        const div_rem_result = dividend_u256.div_rem(divisor_u256);
        break :blk div_rem_result.remainder.to_u256_unsafe();
    };

    frame.stack.set_top_unsafe(result);
}

/// SMOD opcode (0x07) - Signed modulo remainder operation
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
/// ## Gas Cost
/// 5 gas (GasFastStep)
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
pub fn op_smod(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 2);

    const divisor = frame.stack.pop_unsafe();
    const dividend = frame.stack.peek_unsafe().*;

    // EVM semantics: dividend % divisor - signed modulo
    var result: u256 = undefined;
    if (divisor == 0) {
        @branchHint(.unlikely);
        result = 0;
    } else {
        const dividend_i256 = @as(i256, @bitCast(dividend));
        const divisor_i256 = @as(i256, @bitCast(divisor));
        const result_i256 = @rem(dividend_i256, divisor_i256);
        result = @as(u256, @bitCast(result_i256));
    }

    frame.stack.set_top_unsafe(result);
}

/// ADDMOD opcode (0x08) - Addition modulo n
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
/// ## Gas Cost
/// 8 gas (GasMidStep)
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
pub fn op_addmod(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 3);

    const top = frame.stack.pop_unsafe();
    const second = frame.stack.pop_unsafe();
    const third = frame.stack.peek_unsafe().*;

    // REVM pattern: for ADDMOD with stack [7, 10, 5], computes (5 + 10) % 7 = 1
    // So: top (5) + second (10) % third (7)
    const a = top;
    const b = second;
    const n = third;

    var result: u256 = undefined;
    if (n == 0) {
        result = 0;
    } else {
        // Use U256 add_mod to properly handle overflow
        const a_u256 = U256.from_u256_unsafe(a);
        const b_u256 = U256.from_u256_unsafe(b);
        const n_u256 = U256.from_u256_unsafe(n);
        const result_u256 = a_u256.add_mod(b_u256, n_u256);
        result = result_u256.to_u256_unsafe();
    }

    frame.stack.set_top_unsafe(result);
}

/// MULMOD opcode (0x09) - Multiplication modulo n
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
/// ## Gas Cost
/// 8 gas (GasMidStep)
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
pub fn op_mulmod(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 3);

    const top = frame.stack.pop_unsafe();
    const second = frame.stack.pop_unsafe();
    const third = frame.stack.peek_unsafe().*;

    // REVM pattern: same as ADDMOD
    const a = top;
    const b = second;
    const n = third;

    var result: u256 = undefined;
    if (n == 0) {
        result = 0;
    } else {
        // Use optimized U256 mulmod
        const a_u256 = U256.from_u256_unsafe(a);
        const b_u256 = U256.from_u256_unsafe(b);
        const n_u256 = U256.from_u256_unsafe(n);
        const result_u256 = a_u256.mul_mod(b_u256, n_u256);
        result = result_u256.to_u256_unsafe();
    }

    frame.stack.set_top_unsafe(result);
}

/// EXP opcode (0x0A) - Exponentiation
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
/// - Static: 10 gas
/// - Dynamic: 50 gas per byte of exponent
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
pub fn op_exp(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 2);

    const exponent = frame.stack.pop_unsafe();
    const base = frame.stack.peek_unsafe().*;

    // EVM semantics: base^exponent

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
        Log.debug("EXP: base={x:0>64} exp=0 -> 1", .{base});
        frame.stack.set_top_unsafe(1);
        return;
    }
    if (base == 0) {
        Log.debug("EXP: base=0 exp={x:0>64} -> 0", .{exponent});
        frame.stack.set_top_unsafe(0);
        return;
    }
    if (base == 1) {
        Log.debug("EXP: base=1 exp={x:0>64} -> 1", .{exponent});
        frame.stack.set_top_unsafe(1);
        return;
    }
    if (exponent == 1) {
        Log.debug("EXP: base={x:0>64} exp=1 -> base", .{base});
        frame.stack.set_top_unsafe(base);
        return;
    }

    // Square-and-multiply algorithm
    var result: u256 = 1;
    var b = base;
    var e = exponent;

    while (e > 0) {
        if ((e & 1) == 1) {
            const mul_result = @mulWithOverflow(result, b);
            result = mul_result[0];
        }
        if (e > 1) {
            const square_result = @mulWithOverflow(b, b);
            b = square_result[0];
        }
        e >>= 1;
    }

    Log.debug("EXP: base={x:0>64} exp={x:0>64} -> res={x:0>64}", .{ base, exponent, result });
    frame.stack.set_top_unsafe(result);
}

/// SIGNEXTEND opcode (0x0B) - Sign extension
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
/// ## Gas Cost
/// 5 gas (GasFastStep)
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
pub fn op_signextend(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 2);

    const byte_num = frame.stack.pop_unsafe();
    const x = frame.stack.peek_unsafe().*;

    var result: u256 = undefined;

    if (byte_num >= 31) {
        @branchHint(.unlikely);
        result = x;
    } else {
        const byte_index = @as(u8, @intCast(byte_num));
        const sign_bit_pos = byte_index * 8 + 7;

        const sign_bit = (x >> @intCast(sign_bit_pos)) & 1;

        const keep_bits = sign_bit_pos + 1;

        if (sign_bit == 1) {
            // Sign bit is 1, extend with 1s
            if (keep_bits >= 256) {
                result = x;
            } else {
                const ones_mask = ~((@as(u256, 1) << @intCast(keep_bits)) - 1);
                result = x | ones_mask;
            }
        } else {
            // Sign bit is 0, extend with 0s (just mask out upper bits)
            if (keep_bits >= 256) {
                result = x;
            } else {
                const zero_mask = (@as(u256, 1) << @intCast(keep_bits)) - 1;
                result = x & zero_mask;
            }
        }
    }

    frame.stack.set_top_unsafe(result);
}

// FIXME: Function temporarily disabled due to compilation issues during refactor
// Simple test-only arithmetic verification - no EVM setup needed
// pub fn test_arithmetic_operation(op_type: ArithmeticOpType, a: u256, b: u256, c: u256) !u256 {
//     switch (op_type) {
//         .add => return a +% b,
//         .mul => return a *% b,
//         .sub => return a -% b,
//         .div => {
//             if (b == 0) return 0;
//             return a / b;
//         },
//         .sdiv => {
//             if (b == 0) return 0;
//             const a_i256 = @as(i256, @bitCast(a));
//             const b_i256 = @as(i256, @bitCast(b));
//             const min_i256 = @as(i256, 1) << 255;
//             if (a_i256 == min_i256 and b_i256 == -1) {
//                 return @as(u256, @bitCast(min_i256));
//             }
//             const result_i256 = @divTrunc(a_i256, b_i256);
//             return @as(u256, @bitCast(result_i256));
//         },
//         .mod => {
//             if (b == 0) return 0;
//             return a % b;
//         },
//         .smod => {
//             if (b == 0) return 0;
//             const a_i256 = @as(i256, @bitCast(a));
//             const b_i256 = @as(i256, @bitCast(b));
//             const result_i256 = @rem(a_i256, b_i256);
//             return @as(u256, @bitCast(result_i256));
//         },
//         .addmod => {
//             if (c == 0) return 0;
//             return (a +% b) % c;
//         },
//         .mulmod => {
//             if (c == 0) return 0;
//             // Russian peasant multiplication with modular reduction
//             var result: u256 = 0;
//             var x = a % c;
//             var y = b % c;
//
//             while (y > 0) {
//                 if ((y & 1) == 1) {
//                     const sum = result +% x;
//                     result = sum % c;
//                 }
//                 x = (x +% x) % c;
//                 y >>= 1;
//             }
//             return result;
//         },
//         .exp => {
//             // Binary exponentiation
//             var result: u256 = 1;
//             var base = a;
//             var exp = b;
//
//             while (exp > 0) {
//                 if ((exp & 1) == 1) {
//                     result *%= base;
//                 }
//                 base *%= base;
//                 exp >>= 1;
//             }
//             return result;
//         },
//         .signextend => {
//             if (a >= 31) return b;
//
//             const byte_index = @as(u8, @intCast(a));
//             const sign_bit_pos = byte_index * 8 + 7;
//             const sign_bit = (b >> @intCast(sign_bit_pos)) & 1;
//             const keep_bits = sign_bit_pos + 1;
//
//             if (sign_bit == 1) {
//                 if (keep_bits >= 256) {
//                     return b;
//                 } else {
//                     const shift_amount = @as(u9, 256) - @as(u9, keep_bits);
//                     const ones_mask = ~(@as(u256, 0) >> @intCast(shift_amount));
//                     return b | ones_mask;
//                 }
//             } else {
//                 if (keep_bits >= 256) {
//                     return b;
//                 } else {
//                     const zero_mask = (@as(u256, 1) << @intCast(keep_bits)) - 1;
//                     return b & zero_mask;
//                 }
//             }
//         },
//     }
// }

// FIXME: All test functions and structs temporarily removed due to compilation issues during refactor

// test "fuzz_arithmetic_basic_operations" {
//     const operations = [_]FuzzArithmeticOperation{
//         .{ .op_type = .add, .a = 10, .b = 20 },
//         .{ .op_type = .mul, .a = 5, .b = 6 },
//         .{ .op_type = .sub, .a = 30, .b = 10 },
//         .{ .op_type = .div, .a = 100, .b = 5 },
//         .{ .op_type = .mod, .a = 17, .b = 5 },
//     };
//
//     for (operations) |op| {
//         try validate_and_test_arithmetic_operation(op);
//     }
// }

// test "fuzz_arithmetic_edge_cases" {
//     const operations = [_]FuzzArithmeticOperation{
//         .{ .op_type = .add, .a = std.math.maxInt(u256), .b = 1 }, // Overflow
//         .{ .op_type = .mul, .a = std.math.maxInt(u256), .b = 2 }, // Overflow
//         .{ .op_type = .sub, .a = 0, .b = 1 }, // Underflow
//         .{ .op_type = .div, .a = 100, .b = 0 }, // Division by zero
//         .{ .op_type = .mod, .a = 100, .b = 0 }, // Modulo by zero
//         .{ .op_type = .sdiv, .a = 1 << 255, .b = std.math.maxInt(u256) }, // Min i256 / -1
//         .{ .op_type = .addmod, .a = 10, .b = 20, .c = 0 }, // Modulo by zero
//         .{ .op_type = .mulmod, .a = 10, .b = 20, .c = 0 }, // Modulo by zero
//     };
//
//     for (operations) |op| {
//         try validate_and_test_arithmetic_operation(op);
//     }
// }

// test "fuzz_arithmetic_random_operations" {
//     const global = struct {
//         fn testArithmeticOperations(input: []const u8) anyerror!void {
//             if (input.len < 12) return;
//
//             const op_types = [_]ArithmeticOpType{ .add, .mul, .sub, .div, .mod, .addmod, .mulmod };
//
//             // Extract operation type and values from fuzz input
//             const op_type_idx = input[0] % op_types.len;
//             const op_type = op_types[op_type_idx];
//
//             // Extract three u256 values from fuzz input (using different parts for variety)
//             const a = std.mem.readInt(u64, input[1..9], .little); // Smaller values to avoid overflow issues
//             const b = std.mem.readInt(u64, input[4..12], .little);
//             const c = if (input.len >= 20) std.mem.readInt(u64, input[12..20], .little) else 1;
//
//             const operation = FuzzArithmeticOperation{
//                 .op_type = op_type,
//                 .a = @as(u256, a),
//                 .b = @as(u256, b),
//                 .c = @as(u256, c)
//             };
//
//             try validate_and_test_arithmetic_operation(operation);
//         }
//     };
//     try std.testing.fuzz(global.testArithmeticOperations, .{});
// }

// test "fuzz_arithmetic_boundary_values" {
//     const allocator = std.testing.allocator;
//
//     const boundary_values = [_]u256{
//         0,
//         1,
//         2,
//         std.math.maxInt(u8),
//         std.math.maxInt(u16),
//         std.math.maxInt(u32),
//         std.math.maxInt(u64),
//         std.math.maxInt(u128),
//         std.math.maxInt(u256),
//         std.math.maxInt(u256) - 1,
//         1 << 128,
//         1 << 255,
//         (1 << 255) - 1,
//         (1 << 255) + 1,
//     };
//
//     var operations = std.ArrayList(FuzzArithmeticOperation).init(allocator);
//     defer operations.deinit();
//
//     for (boundary_values) |a| {
//         for (boundary_values) |b| {
//             try operations.append(.{ .op_type = .add, .a = a, .b = b });
//             try operations.append(.{ .op_type = .mul, .a = a, .b = b });
//             try operations.append(.{ .op_type = .sub, .a = a, .b = b });
//             try operations.append(.{ .op_type = .div, .a = a, .b = b });
//             try operations.append(.{ .op_type = .mod, .a = a, .b = b });
//
//             if (operations.items.len > 200) break; // Limit to prevent test timeout
//         }
//         if (operations.items.len > 200) break;
//     }
//
//     for (operations.items) |op| {
//         try validate_and_test_arithmetic_operation(op);
//     }
// }

// test "fuzz_arithmetic_edge_cases_found" {
//     // Test potential bugs found through fuzzing
//     const operations = [_]FuzzArithmeticOperation{
//         .{ .op_type = .div, .a = 100, .b = 0 },
//         .{ .op_type = .mod, .a = 100, .b = 0 },
//         .{ .op_type = .sdiv, .a = 1 << 255, .b = std.math.maxInt(u256) },
//         .{ .op_type = .addmod, .a = std.math.maxInt(u256), .b = std.math.maxInt(u256), .c = 0 },
//         .{ .op_type = .mulmod, .a = std.math.maxInt(u256), .b = std.math.maxInt(u256), .c = 0 },
//     };
//
//     for (operations) |op| {
//         try validate_and_test_arithmetic_operation(op);
//     }
// }

// test "fuzz_signed_operations_comprehensive" {
//     const allocator = std.testing.allocator;
//
//     // Constants for signed operations
//     const MIN_I256 = @as(u256, 1) << 255; // Most negative i256 value
//     const MAX_I256 = MIN_I256 - 1; // Most positive i256 value
//     const NEG_ONE = @as(u256, @bitCast(@as(i256, -1))); // -1 in two's complement
//
//     var operations = std.ArrayList(FuzzArithmeticOperation).init(allocator);
//     defer operations.deinit();
//
//     // Test all combinations of positive/negative operands for SDIV
//     const test_values = [_]u256{ 20, 100, MAX_I256, MIN_I256 };
//     const sign_variants = [_]u256{ 5, NEG_ONE *% 5 }; // 5 and -5
//
//     for (test_values) |a| {
//         for (sign_variants) |b| {
//             try operations.append(.{ .op_type = .sdiv, .a = a, .b = b });
//             try operations.append(.{ .op_type = .smod, .a = a, .b = b });
//
//             // Test with negated a
//             const neg_a = @as(u256, @bitCast(-@as(i256, @bitCast(a))));
//             try operations.append(.{ .op_type = .sdiv, .a = neg_a, .b = b });
//             try operations.append(.{ .op_type = .smod, .a = neg_a, .b = b });
//         }
//     }
//
//     // Critical edge cases
//     try operations.append(.{ .op_type = .sdiv, .a = MIN_I256, .b = NEG_ONE }); // MIN_I256 / -1 overflow case
//     try operations.append(.{ .op_type = .smod, .a = MIN_I256, .b = NEG_ONE }); // MIN_I256 % -1
//     try operations.append(.{ .op_type = .sdiv, .a = MIN_I256, .b = 0 }); // Division by zero
//     try operations.append(.{ .op_type = .smod, .a = MIN_I256, .b = 0 }); // Modulo by zero
//
//     for (operations.items) |op| {
//         try validate_and_test_arithmetic_operation(op);
//     }
// }

// test "fuzz_exponentiation_comprehensive" {
//     const allocator = std.testing.allocator;
//
//     var operations = std.ArrayList(FuzzArithmeticOperation).init(allocator);
//     defer operations.deinit();
//
//     // Test small exponents
//     const small_exponents = [_]u256{ 0, 1, 2, 3, 4, 5, 10 };
//     const bases = [_]u256{ 0, 1, 2, 3, 10, 100, 255 };
//
//     for (bases) |base| {
//         for (small_exponents) |exp| {
//             try operations.append(.{ .op_type = .exp, .a = base, .b = exp });
//         }
//     }
//
//     // Test powers of 2 exponents
//     const power_of_two_exponents = [_]u256{ 1, 2, 4, 8, 16, 32, 64, 128 };
//     for (power_of_two_exponents) |exp| {
//         try operations.append(.{ .op_type = .exp, .a = 2, .b = exp });
//         try operations.append(.{ .op_type = .exp, .a = 3, .b = exp });
//     }
//
//     // Test large bases with small exponents
//     const large_bases = [_]u256{
//         std.math.maxInt(u8),
//         std.math.maxInt(u16),
//         std.math.maxInt(u32),
//         1 << 128,
//         std.math.maxInt(u256) >> 1 // Prevent immediate overflow
//     };
//
//     for (large_bases) |base| {
//         for (small_exponents[0..4]) |exp| { // Only test with 0,1,2,3 to prevent overflow
//             try operations.append(.{ .op_type = .exp, .a = base, .b = exp });
//         }
//     }
//
//     // Edge cases
//     try operations.append(.{ .op_type = .exp, .a = 0, .b = 0 }); // 0^0 = 1 in EVM
//     try operations.append(.{ .op_type = .exp, .a = 1, .b = std.math.maxInt(u256) }); // 1^huge = 1
//
//     for (operations.items) |op| {
//         try validate_and_test_arithmetic_operation(op);
//     }
// }

// test "fuzz_signextend_comprehensive" {
//     const allocator = std.testing.allocator;
//
//     var operations = std.ArrayList(FuzzArithmeticOperation).init(allocator);
//     defer operations.deinit();
//
//     // Test all byte positions (0-31)
//     var byte_pos: u256 = 0;
//     while (byte_pos <= 31) : (byte_pos += 1) {
//         // Test with values that have sign bit set/unset at the target byte
//         const bit_pos = byte_pos * 8 + 7; // Sign bit position
//
//         // Value with sign bit = 0 (positive)
//         const positive_val = (@as(u256, 1) << @intCast(bit_pos)) - 1;
//         try operations.append(.{ .op_type = .signextend, .a = byte_pos, .b = positive_val });
//
//         // Value with sign bit = 1 (negative)
//         const negative_val = @as(u256, 1) << @intCast(bit_pos);
//         try operations.append(.{ .op_type = .signextend, .a = byte_pos, .b = negative_val });
//
//         // Mixed values
//         const mixed_val = positive_val | negative_val;
//         try operations.append(.{ .op_type = .signextend, .a = byte_pos, .b = mixed_val });
//     }
//
//     // Test edge cases
//     try operations.append(.{ .op_type = .signextend, .a = 32, .b = 0x12345678 }); // byte_num > 31
//     try operations.append(.{ .op_type = .signextend, .a = std.math.maxInt(u256), .b = 0xFF00 }); // huge byte_num
//     try operations.append(.{ .op_type = .signextend, .a = 0, .b = 0x7F }); // Positive 8-bit
//     try operations.append(.{ .op_type = .signextend, .a = 0, .b = 0x80 }); // Negative 8-bit
//     try operations.append(.{ .op_type = .signextend, .a = 1, .b = 0x7FFF }); // Positive 16-bit
//     try operations.append(.{ .op_type = .signextend, .a = 1, .b = 0x8000 }); // Negative 16-bit
//     try operations.append(.{ .op_type = .signextend, .a = 31, .b = std.math.maxInt(u256) }); // Full width
//
//     for (operations.items) |op| {
//         try validate_and_test_arithmetic_operation(op);
//     }
// }

// test "fuzz_arithmetic_invariants" {
//     const global = struct {
//         fn testArithmeticInvariants(input: []const u8) anyerror!void {
//             if (input.len < 16) return;
//
//             const invariant_type = input[0] % 4;
//
//             switch (invariant_type) {
//                 0 => {
//                     // Test invariant: (a + b) - b = a (modulo 2^256)
//                     const a = std.mem.readInt(u64, input[1..9], .little);
//                     const b = std.mem.readInt(u64, input[9..17], .little);
//
//                     const op1 = FuzzArithmeticOperation{ .op_type = .add, .a = @as(u256, a), .b = @as(u256, b) };
//                     try validate_and_test_arithmetic_operation(op1);
//
//                     // Verify invariant properties with simple calculations
//                     const sum = @as(u256, a) +% @as(u256, b);
//                     const diff = sum -% @as(u256, b);
//                     try std.testing.expectEqual(@as(u256, a), diff);
//                 },
//                 1 => {
//                     // Test invariant: a * 0 = 0
//                     const a = std.mem.readInt(u64, input[1..9], .little);
//
//                     const op2 = FuzzArithmeticOperation{ .op_type = .mul, .a = @as(u256, a), .b = 0 };
//                     try validate_and_test_arithmetic_operation(op2);
//
//                     // Verify: a * 0 = 0
//                     const product = @as(u256, a) *% 0;
//                     try std.testing.expectEqual(@as(u256, 0), product);
//                 },
//                 2 => {
//                     // Test invariant: a / 1 = a
//                     const a = std.mem.readInt(u64, input[1..9], .little);
//
//                     const op3 = FuzzArithmeticOperation{ .op_type = .div, .a = @as(u256, a), .b = 1 };
//                     try validate_and_test_arithmetic_operation(op3);
//
//                     // Verify: a / 1 = a
//                     const quotient = @as(u256, a) / 1;
//                     try std.testing.expectEqual(@as(u256, a), quotient);
//                 },
//                 3 => {
//                     // Test invariant: a % a = 0 (when a != 0)
//                     var a = std.mem.readInt(u64, input[1..9], .little);
//                     if (a == 0) a = 1; // Ensure non-zero
//
//                     const op4 = FuzzArithmeticOperation{ .op_type = .mod, .a = @as(u256, a), .b = @as(u256, a) };
//                     try validate_and_test_arithmetic_operation(op4);
//
//                     // Verify: a % a = 0
//                     const remainder = @as(u256, a) % @as(u256, a);
//                     try std.testing.expectEqual(@as(u256, 0), remainder);
//                 },
//             }
//         }
//     };
//     try std.testing.fuzz(global.testArithmeticInvariants, .{});
// }

// test "fuzz_cross_operation_verification" {
//     const global = struct {
//         fn testCrossOperationVerification(input: []const u8) anyerror!void {
//             if (input.len < 25) return;
//
//             const verification_type = input[0] % 3;
//
//             switch (verification_type) {
//                 0 => {
//                     // Test DIV and MOD relationship: a = (a/b)*b + (a%b) when b != 0
//                     const a = std.mem.readInt(u64, input[1..9], .little);
//                     var b = std.mem.readInt(u64, input[9..17], .little);
//                     if (b == 0) b = 1; // Ensure non-zero divisor
//
//                     const a_u256 = @as(u256, a);
//                     const b_u256 = @as(u256, b);
//
//                     const quotient = a_u256 / b_u256;
//                     const remainder = a_u256 % b_u256;
//
//                     // Verify: a = (a/b)*b + (a%b)
//                     const reconstructed = quotient *% b_u256 +% remainder;
//                     try std.testing.expectEqual(a_u256, reconstructed);
//                 },
//                 1 => {
//                     // Test ADDMOD property: (a+b)%n = ((a%n)+(b%n))%n when n != 0
//                     const a = std.mem.readInt(u64, input[1..9], .little);
//                     const b = std.mem.readInt(u64, input[9..17], .little);
//                     var n = std.mem.readInt(u64, input[17..25], .little);
//                     if (n == 0) n = 1; // Ensure non-zero modulus
//
//                     const a_u256 = @as(u256, a);
//                     const b_u256 = @as(u256, b);
//                     const n_u256 = @as(u256, n);
//
//                     const direct = (a_u256 +% b_u256) % n_u256;
//                     const indirect = ((a_u256 % n_u256) +% (b_u256 % n_u256)) % n_u256;
//
//                     try std.testing.expectEqual(direct, indirect);
//                 },
//                 2 => {
//                     // Test SIGNEXTEND invariant: SIGNEXTEND(31, x) = x
//                     const x = std.mem.readInt(u64, input[1..9], .little);
//
//                     const operation = FuzzArithmeticOperation{ .op_type = .signextend, .a = 31, .b = @as(u256, x) };
//                     try validate_and_test_arithmetic_operation(operation);
//                 },
//             }
//         }
//     };
//     try std.testing.fuzz(global.testCrossOperationVerification, .{});
// }

// test "fuzz_combined_operations" {
//     const global = struct {
//         fn testCombinedOperations(input: []const u8) anyerror!void {
//             if (input.len < 24) return;
//
//             // Extract three u64 values from fuzz input
//             const a = std.mem.readInt(u64, input[0..8], .little) % 1000000 + 1; // Keep values reasonable
//             const b = std.mem.readInt(u64, input[8..16], .little) % 1000000 + 1;
//             const c = std.mem.readInt(u64, input[16..24], .little) % 1000000 + 1;
//
//             const a_u256 = @as(u256, a);
//             const b_u256 = @as(u256, b);
//             const c_u256 = @as(u256, c);
//
//             // Test (a + b) operation
//             const op1 = FuzzArithmeticOperation{ .op_type = .add, .a = a_u256, .b = b_u256 };
//             try validate_and_test_arithmetic_operation(op1);
//
//             // Test (a * b) operation
//             const op2 = FuzzArithmeticOperation{ .op_type = .mul, .a = a_u256, .b = b_u256 };
//             try validate_and_test_arithmetic_operation(op2);
//
//             // Test distributive property verification with bounded values
//             if (a < 1000 and b < 1000 and c < 1000) {
//                 // (a + b) * c vs a*c + b*c - verify they're equal
//                 const left_side = (a_u256 +% b_u256) *% c_u256;
//                 const right_side = (a_u256 *% c_u256) +% (b_u256 *% c_u256);
//
//                 try std.testing.expectEqual(left_side, right_side);
//             }
//         }
//     };
//     try std.testing.fuzz(global.testCombinedOperations, .{});
// }

// test "fuzz_gas_cost_boundaries" {
//     const allocator = std.testing.allocator;
//
//     // Test EXP with different exponent sizes to verify gas cost calculation
//     const exp_test_cases = [_]struct { base: u256, exp: u256, expected_gas_bytes: u64 }{
//         .{ .base = 2, .exp = 0, .expected_gas_bytes = 0 }, // 0 bytes for exp=0
//         .{ .base = 2, .exp = 255, .expected_gas_bytes = 1 }, // 1 byte for exp=255
//         .{ .base = 2, .exp = 256, .expected_gas_bytes = 2 }, // 2 bytes for exp=256
//         .{ .base = 2, .exp = 65535, .expected_gas_bytes = 2 }, // 2 bytes for exp=65535
//         .{ .base = 2, .exp = 65536, .expected_gas_bytes = 3 }, // 3 bytes for exp=65536
//     };
//
//     var operations = std.ArrayList(FuzzArithmeticOperation).init(allocator);
//     defer operations.deinit();
//
//     for (exp_test_cases) |test_case| {
//         try operations.append(.{ .op_type = .exp, .a = test_case.base, .b = test_case.exp });
//
//         // Verify byte size calculation manually
//         var exp_copy = test_case.exp;
//         var byte_size: u64 = 0;
//         while (exp_copy > 0) : (exp_copy >>= 8) {
//             byte_size += 1;
//         }
//
//         std.testing.expectEqual(test_case.expected_gas_bytes, byte_size) catch |err| {
//             std.log.debug("Gas calculation mismatch for exp={}: expected {} bytes, got {} bytes", .{ test_case.exp, test_case.expected_gas_bytes, byte_size });
//             return err;
//         };
//     }
//
//     for (operations.items) |op| {
//         try validate_and_test_arithmetic_operation(op);
//     }
// }

// test "fuzz_performance_stress" {
//     const global = struct {
//         fn testPerformanceStress(input: []const u8) anyerror!void {
//             if (input.len < 32) return;
//
//             const op_types = [_]ArithmeticOpType{ .add, .mul, .sub, .div, .mod, .sdiv, .smod, .addmod, .mulmod, .exp, .signextend };
//
//             // Extract operation parameters from fuzz input
//             const op_type_idx = input[0] % op_types.len;
//             const op_type = op_types[op_type_idx];
//
//             // Use different parts of input for values to ensure variety
//             const a = std.mem.readInt(u64, input[1..9], .little); // Using u64 to avoid extreme values
//             const b = std.mem.readInt(u64, input[9..17], .little);
//             const c = std.mem.readInt(u64, input[17..25], .little);
//
//             const operation = FuzzArithmeticOperation{
//                 .op_type = op_type,
//                 .a = @as(u256, a),
//                 .b = @as(u256, b),
//                 .c = @as(u256, c)
//             };
//
//             // Test the operation - this tests performance under fuzz load
//             try validate_and_test_arithmetic_operation(operation);
//         }
//     };
//     try std.testing.fuzz(global.testPerformanceStress, .{});
// }

// FIXME: Comment out test functions that use Frame/Contract until ExecutionContext migration is complete
// test "arithmetic_benchmarks" {
// const Timer = std.time.Timer;
// var timer = try Timer.start();
// const allocator = std.testing.allocator;

// FIXME: All test functions that used Frame/Contract have been removed
// defer memory_db.deinit();
// const db_interface = memory_db.to_database_interface();
// var vm = try Vm.init(allocator, db_interface, null, null);
// defer vm.deinit();

// const iterations = 100000;

// Benchmark 1: Basic arithmetic operations (ADD, SUB, MUL)
// timer.reset();
// var i: usize = 0;
// while (i < iterations) : (i += 1) {
// var contract = try @import("../frame/contract.zig").Contract.init(allocator, &[_]u8{0x01}, .{ .address = [_]u8{0} ** 20 });
// defer contract.deinit(allocator, null);
// var frame = try Frame.init(allocator, &vm, 1000000, contract, [_]u8{0} ** 20, &.{});
// defer frame.deinit();

// Test ADD operation
// try frame.stack.append(@intCast(i));
// try frame.stack.append(@intCast(i * 2));
// try op_add(&frame);
// }
// const basic_arithmetic_ns = timer.read();

// // Benchmark 2: Division operations (handling edge cases)
// timer.reset();
// i = 0;
// while (i < iterations) : (i += 1) {
// var contract = try @import("../frame/contract.zig").Contract.init(allocator, &[_]u8{0x04}, .{ .address = [_]u8{0} ** 20 });
// // defer contract.deinit(allocator, null);
// // var frame = try Frame.init(allocator, &vm, 1000000, contract, [_]u8{0} ** 20, &.{});
// // defer frame.deinit();

// // Test DIV with various values including edge cases
// const dividend: u256 = @intCast(if (i == 0) 1 else i);
// const divisor: u256 = @intCast(if (i % 100 == 0) 0 else (i % 1000) + 1); // Include div by zero
// // try frame.stack.append(dividend);
// // try frame.stack.append(divisor);
// // try op_div(&frame);
// }
// const division_ops_ns = timer.read();

// // Benchmark 3: Modular arithmetic (ADDMOD, MULMOD)
// timer.reset();
// i = 0;
// while (i < iterations / 10) : (i += 1) { // Fewer iterations due to complexity
// var contract = try @import("../frame/contract.zig").Contract.init(allocator, &[_]u8{0x08}, .{ .address = [_]u8{0} ** 20 });
// // defer contract.deinit(allocator, null);
// // var frame = try Frame.init(allocator, &vm, 1000000, contract, [_]u8{0} ** 20, &.{});
// // defer frame.deinit();

// // Test ADDMOD operation
// // try frame.stack.append(@intCast(i * 1000));
// // try frame.stack.append(@intCast(i * 2000));
// // try frame.stack.append(@intCast(if (i == 0) 1 else i + 1)); // Avoid mod by zero
// // try op_addmod(&frame);
// }
// const modular_arithmetic_ns = timer.read();

// // Benchmark 4: Exponentiation with various exponent sizes
// timer.reset();
// const exp_cases = [_]struct { base: u256, exp: u256 }{
// .{ .base = 2, .exp = 1 }, // Small exponent
// .{ .base = 2, .exp = 8 }, // Medium exponent
// .{ .base = 2, .exp = 256 }, // Large exponent
// .{ .base = 3, .exp = 100 }, // Different base
// .{ .base = 0, .exp = 100 }, // Zero base
// .{ .base = 100, .exp = 0 }, // Zero exponent
// };

// for (exp_cases) |exp_case| {
// var contract = try @import("../frame/contract.zig").Contract.init(allocator, &[_]u8{0x0a}, .{ .address = [_]u8{0} ** 20 });
// // defer contract.deinit(allocator, null);
// // var frame = try Frame.init(allocator, &vm, 1000000, contract, [_]u8{0} ** 20, &.{});
// // defer frame.deinit();

// // try frame.stack.append(exp_case.base);
// // try frame.stack.append(exp_case.exp);
// // try op_exp(&frame);
// }
// const exponentiation_ns = timer.read();

// // Benchmark 5: Sign extension with different byte positions
// timer.reset();
// i = 0;
// while (i < iterations) : (i += 1) {
// var contract = try @import("../frame/contract.zig").Contract.init(allocator, &[_]u8{0x0b}, .{ .address = [_]u8{0} ** 20 });
// // defer contract.deinit(allocator, null);
// // var frame = try Frame.init(allocator, &vm, 1000000, contract, [_]u8{0} ** 20, &.{});
// // defer frame.deinit();

// // Test SIGNEXTEND with various byte positions
// const byte_pos: u256 = i % 32; // Valid byte positions 0-31
// const value: u256 = @intCast(i * 0x123456);
// // try frame.stack.append(byte_pos);
// // try frame.stack.append(value);
// // try op_signextend(&frame);
// }
// const sign_extension_ns = timer.read();

// // Benchmark 6: Signed arithmetic (SDIV, SMOD)
// timer.reset();
// i = 0;
// while (i < iterations) : (i += 1) {
// var contract = try @import("../frame/contract.zig").Contract.init(allocator, &[_]u8{0x05}, .{ .address = [_]u8{0} ** 20 });
// // defer contract.deinit(allocator, null);
// // var frame = try Frame.init(allocator, &vm, 1000000, contract, [_]u8{0} ** 20, &.{});
// // defer frame.deinit();

// // Test SDIV with mix of positive and negative values
// const a: u256 = if (i % 2 == 0) @intCast(i + 1) else std.math.maxInt(u256) - @as(u256, @intCast(i)); // Simulate negative
// const b: u256 = @intCast(if (i % 100 == 0) 1 else (i % 1000) + 1); // Avoid div by zero
// // try frame.stack.append(a);
// // try frame.stack.append(b);
// // try op_sdiv(&frame);
// }
// const signed_arithmetic_ns = timer.read();

// // Print benchmark results
// std.log.debug("Arithmetic Operation Benchmarks:", .{});
// std.log.debug("  Basic arithmetic ({} ops): {} ns", .{ iterations, basic_arithmetic_ns });
// std.log.debug("  Division operations ({} ops): {} ns", .{ iterations, division_ops_ns });
// std.log.debug("  Modular arithmetic ({} ops): {} ns", .{ iterations / 10, modular_arithmetic_ns });
// std.log.debug("  Exponentiation (6 cases): {} ns", .{exponentiation_ns});
// std.log.debug("  Sign extension ({} ops): {} ns", .{ iterations, sign_extension_ns });
// std.log.debug("  Signed arithmetic ({} ops): {} ns", .{ iterations, signed_arithmetic_ns });

// // Performance analysis
// const avg_basic_ns = basic_arithmetic_ns / iterations;
// const avg_division_ns = division_ops_ns / iterations;
// const avg_signed_ns = signed_arithmetic_ns / iterations;

// std.log.debug("  Average basic arithmetic: {} ns/op", .{avg_basic_ns});
// std.log.debug("  Average division: {} ns/op", .{avg_division_ns});
// std.log.debug("  Average signed arithmetic: {} ns/op", .{avg_signed_ns});

// // Gas calculation throughput benchmark
// timer.reset();
// i = 0;
// const gas_iterations = 1000000;
// while (i < gas_iterations) : (i += 1) {
// // Simulate gas cost calculation for EXP with varying exponent sizes
// const exp: u256 = @intCast(i % 10000);
// var byte_size: u64 = 0;
// var exp_copy = exp;
// while (exp_copy > 0) : (exp_copy >>= 8) {
// byte_size += 1;
// }
// // Simulate gas calculation: 10 + 50 * byte_size
// _ = 10 + 50 * byte_size;
// }
// const gas_calculation_ns = timer.read();

// std.log.debug("  Gas calculation throughput ({} calcs): {} ns", .{ gas_iterations, gas_calculation_ns });
// std.log.debug("  Average gas calculation: {} ns/calc", .{gas_calculation_ns / gas_iterations});
// }

// Tests for ADDMOD overflow bug fix (Issue #331)
// FIXME: All test functions using Frame/Contract have been temporarily disabled
// They need to be rewritten to use ExecutionContext when the migration is complete
