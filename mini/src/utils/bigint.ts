/**
 * BigInt Utilities for EVM Operations
 *
 * Provides comprehensive bigint helpers matching EVM semantics:
 * - Wrapping for different integer sizes (u256, u128, u64, u32)
 * - Arithmetic with modular wrapping
 * - Signed/unsigned conversions (two's complement)
 * - EVM-compliant division by zero handling
 */

// ============================================================================
// Constants
// ============================================================================

/** Maximum unsigned 256-bit integer (2^256 - 1) */
export const MAX_U256 = (1n << 256n) - 1n;

/** Maximum unsigned 128-bit integer (2^128 - 1) */
export const MAX_U128 = (1n << 128n) - 1n;

/** Maximum unsigned 64-bit integer (2^64 - 1) */
export const MAX_U64 = (1n << 64n) - 1n;

/** Maximum unsigned 32-bit integer (2^32 - 1) */
export const MAX_U32 = (1n << 32n) - 1n;

/** Minimum signed 256-bit integer (-2^255) */
export const MIN_SIGNED_256 = -(1n << 255n);

/** Maximum signed 256-bit integer (2^255 - 1) */
export const MAX_SIGNED_256 = (1n << 255n) - 1n;

/** Sign bit position for 256-bit integers */
const SIGN_BIT_256 = 1n << 255n;

// ============================================================================
// Wrapping Operations (Bitwise AND with max value)
// ============================================================================

/**
 * Wrap value to unsigned 256-bit integer.
 * Equivalent to: value & MAX_U256
 *
 * @example
 * wrap256(2n ** 256n) // 0n (overflow wraps to 0)
 * wrap256(-1n) // MAX_U256 (wraps around)
 */
export function wrap256(value: bigint): bigint {
  return value & MAX_U256;
}

/**
 * Wrap value to unsigned 128-bit integer.
 *
 * @example
 * wrap128(2n ** 128n) // 0n
 */
export function wrap128(value: bigint): bigint {
  return value & MAX_U128;
}

/**
 * Wrap value to unsigned 64-bit integer.
 *
 * @example
 * wrap64(2n ** 64n) // 0n
 */
export function wrap64(value: bigint): bigint {
  return value & MAX_U64;
}

/**
 * Wrap value to unsigned 32-bit integer.
 *
 * @example
 * wrap32(2n ** 32n) // 0n
 */
export function wrap32(value: bigint): bigint {
  return value & MAX_U32;
}

/**
 * Ensure value is a valid unsigned 256-bit integer.
 * Throws if value is negative or exceeds MAX_U256.
 *
 * @throws {RangeError} If value is out of u256 range
 */
export function toU256(value: bigint): bigint {
  if (value < 0n) {
    throw new RangeError(`Value ${value} is negative (u256 must be >= 0)`);
  }
  if (value > MAX_U256) {
    throw new RangeError(`Value ${value} exceeds MAX_U256`);
  }
  return value;
}

// ============================================================================
// Modular Arithmetic (with wrapping)
// ============================================================================

/**
 * Addition with u256 modular wrapping.
 * Matches EVM ADD opcode semantics.
 *
 * @example
 * addMod256(MAX_U256, 1n) // 0n (wraps)
 * addMod256(5n, 10n) // 15n
 */
export function addMod256(a: bigint, b: bigint): bigint {
  return wrap256(a + b);
}

/**
 * Subtraction with u256 modular wrapping.
 * Matches EVM SUB opcode semantics.
 *
 * @example
 * subMod256(0n, 1n) // MAX_U256 (wraps)
 * subMod256(10n, 5n) // 5n
 */
export function subMod256(a: bigint, b: bigint): bigint {
  return wrap256(a - b);
}

/**
 * Multiplication with u256 modular wrapping.
 * Matches EVM MUL opcode semantics.
 *
 * @example
 * mulMod256(2n ** 255n, 2n) // 0n (overflow)
 * mulMod256(5n, 10n) // 50n
 */
export function mulMod256(a: bigint, b: bigint): bigint {
  return wrap256(a * b);
}

/**
 * Division with u256 wrapping.
 * Matches EVM DIV opcode semantics: division by zero returns 0.
 *
 * @example
 * divMod256(10n, 0n) // 0n (EVM: div by 0 = 0)
 * divMod256(10n, 3n) // 3n (truncates)
 */
export function divMod256(a: bigint, b: bigint): bigint {
  if (b === 0n) {
    return 0n; // EVM semantics: div by 0 = 0
  }
  return wrap256(a / b);
}

/**
 * Modulo with u256 wrapping.
 * Matches EVM MOD opcode semantics: mod by zero returns 0.
 *
 * @example
 * modMod256(10n, 0n) // 0n (EVM: mod by 0 = 0)
 * modMod256(10n, 3n) // 1n
 */
export function modMod256(a: bigint, b: bigint): bigint {
  if (b === 0n) {
    return 0n; // EVM semantics: mod by 0 = 0
  }
  return wrap256(a % b);
}

// ============================================================================
// Signed/Unsigned Conversions (Two's Complement)
// ============================================================================

/**
 * Check if a u256 value should be interpreted as negative in two's complement.
 * Negative if bit 255 is set (value >= 2^255).
 *
 * @example
 * isNegative(0n) // false
 * isNegative(2n ** 255n) // true (sign bit set)
 * isNegative(MAX_U256) // true (-1 in two's complement)
 */
export function isNegative(value: bigint): boolean {
  return (value & SIGN_BIT_256) !== 0n;
}

/**
 * Convert unsigned u256 to signed interpretation (two's complement).
 * Matches EVM SDIV/SMOD/SLT/SGT semantics.
 *
 * Range mapping:
 * - 0 to 2^255-1 → 0 to 2^255-1 (positive)
 * - 2^255 to 2^256-1 → -2^255 to -1 (negative)
 *
 * @example
 * toSigned(0n) // 0n
 * toSigned(MAX_U256) // -1n
 * toSigned(SIGN_BIT_256) // MIN_SIGNED_256 (-2^255)
 */
export function toSigned(value: bigint): bigint {
  const wrapped = wrap256(value);
  if (isNegative(wrapped)) {
    // Two's complement: invert and add 1, then negate
    // Equivalent to: wrapped - 2^256
    return wrapped - (1n << 256n);
  }
  return wrapped;
}

/**
 * Convert signed value to unsigned u256 (two's complement).
 * Inverse of toSigned().
 *
 * @example
 * toUnsigned(-1n) // MAX_U256
 * toUnsigned(MIN_SIGNED_256) // SIGN_BIT_256 (2^255)
 * toUnsigned(0n) // 0n
 */
export function toUnsigned(value: bigint): bigint {
  if (value < 0n) {
    // Two's complement: value + 2^256
    return wrap256((1n << 256n) + value);
  }
  return wrap256(value);
}

/**
 * Get absolute value of a signed 256-bit integer.
 * Handles MIN_SIGNED_256 edge case (wraps to same value).
 *
 * @example
 * abs256(toSigned(-5n)) // 5n
 * abs256(MIN_SIGNED_256) // MIN_SIGNED_256 (cannot represent +2^255)
 */
export function abs256(value: bigint): bigint {
  if (value < 0n) {
    // Handle MIN_SIGNED_256 edge case: -MIN_SIGNED_256 = MIN_SIGNED_256
    if (value === MIN_SIGNED_256) {
      return toUnsigned(MIN_SIGNED_256); // 2^255
    }
    return -value;
  }
  return value;
}

// ============================================================================
// Signed Arithmetic (two's complement)
// ============================================================================

/**
 * Signed division with two's complement semantics.
 * Matches EVM SDIV opcode.
 *
 * Special cases:
 * - Division by zero: returns 0
 * - MIN_SIGNED_256 / -1: returns MIN_SIGNED_256 (overflow)
 *
 * @example
 * sdivMod256(toUnsigned(-10n), toUnsigned(-3n)) // toUnsigned(3n)
 * sdivMod256(toUnsigned(-10n), 3n) // toUnsigned(-3n)
 */
export function sdivMod256(a: bigint, b: bigint): bigint {
  if (b === 0n) {
    return 0n; // EVM: div by 0 = 0
  }

  const aSigned = toSigned(a);
  const bSigned = toSigned(b);

  // Handle MIN_SIGNED_256 / -1 overflow
  if (aSigned === MIN_SIGNED_256 && bSigned === -1n) {
    return toUnsigned(MIN_SIGNED_256); // Overflow wraps to same value
  }

  const result = aSigned / bSigned;
  return toUnsigned(result);
}

/**
 * Signed modulo with two's complement semantics.
 * Matches EVM SMOD opcode.
 *
 * Sign of result matches sign of dividend (a).
 *
 * @example
 * smodMod256(toUnsigned(-10n), 3n) // toUnsigned(-1n) (sign from dividend)
 * smodMod256(10n, toUnsigned(-3n)) // 1n (sign from dividend)
 */
export function smodMod256(a: bigint, b: bigint): bigint {
  if (b === 0n) {
    return 0n; // EVM: mod by 0 = 0
  }

  const aSigned = toSigned(a);
  const bSigned = toSigned(b);

  const result = aSigned % bSigned;
  return toUnsigned(result);
}

// ============================================================================
// Comparison Helpers
// ============================================================================

/**
 * Signed less-than comparison.
 * Matches EVM SLT opcode semantics.
 *
 * @example
 * slt(toUnsigned(-1n), 0n) // true (-1 < 0)
 * slt(5n, 10n) // true
 */
export function slt(a: bigint, b: bigint): boolean {
  return toSigned(a) < toSigned(b);
}

/**
 * Signed greater-than comparison.
 * Matches EVM SGT opcode semantics.
 *
 * @example
 * sgt(0n, toUnsigned(-1n)) // true (0 > -1)
 * sgt(10n, 5n) // true
 */
export function sgt(a: bigint, b: bigint): boolean {
  return toSigned(a) > toSigned(b);
}
