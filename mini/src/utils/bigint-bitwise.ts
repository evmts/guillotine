/**
 * BigInt bitwise utilities for EVM operations
 *
 * JavaScript's bigint bitwise operations work on arbitrary precision,
 * but EVM operates on 256-bit values. These utilities ensure proper
 * masking and sign handling.
 */

/** Mask for 256-bit values (2^256 - 1) */
export const MASK_256 = (1n << 256n) - 1n;

/** Sign bit mask for 256-bit values (2^255) */
export const SIGN_BIT_256 = 1n << 255n;

/**
 * Mask a bigint to 256 bits
 * @param value - Value to mask
 * @returns Value masked to 256 bits
 */
export function mask256(value: bigint): bigint {
  return value & MASK_256;
}

/**
 * Check if a 256-bit value is negative (sign bit set)
 * @param value - 256-bit value
 * @returns true if sign bit is set
 */
export function isNegative256(value: bigint): boolean {
  return (value & SIGN_BIT_256) !== 0n;
}

/**
 * Convert unsigned 256-bit to signed (two's complement)
 * @param value - Unsigned 256-bit value
 * @returns Signed bigint representation
 */
export function toSigned256(value: bigint): bigint {
  if (isNegative256(value)) {
    // If sign bit is set, treat as negative
    // Two's complement: -(2^256 - value)
    return value - (1n << 256n);
  }
  return value;
}

/**
 * Convert signed to unsigned 256-bit (two's complement)
 * @param value - Signed bigint
 * @returns Unsigned 256-bit value
 */
export function toUnsigned256(value: bigint): bigint {
  if (value < 0n) {
    // Two's complement: 2^256 + value
    return mask256((1n << 256n) + value);
  }
  return mask256(value);
}

/**
 * Arithmetic right shift (sign-extending)
 * @param value - 256-bit value
 * @param shift - Shift amount
 * @returns Right-shifted value with sign extension
 */
export function sar256(value: bigint, shift: bigint): bigint {
  // For shifts >= 256, result is all 1s (if negative) or all 0s (if positive)
  if (shift >= 256n) {
    return isNegative256(value) ? MASK_256 : 0n;
  }

  // Convert to signed, shift, convert back to unsigned
  const signed = toSigned256(value);
  const shifted = signed >> shift;
  return toUnsigned256(shifted);
}

/**
 * Logical right shift (zero-fill)
 * @param value - 256-bit value
 * @param shift - Shift amount
 * @returns Right-shifted value with zero fill
 */
export function shr256(value: bigint, shift: bigint): bigint {
  // For shifts >= 256, result is always 0
  if (shift >= 256n) {
    return 0n;
  }

  return mask256(value >> shift);
}

/**
 * Left shift
 * @param value - 256-bit value
 * @param shift - Shift amount
 * @returns Left-shifted value masked to 256 bits
 */
export function shl256(value: bigint, shift: bigint): bigint {
  // For shifts >= 256, result is always 0
  if (shift >= 256n) {
    return 0n;
  }

  return mask256(value << shift);
}

/**
 * Extract byte from 256-bit word
 * @param i - Byte index (0-31, 0 is most significant)
 * @param x - 256-bit value
 * @returns Extracted byte (0-255)
 */
export function byte256(i: bigint, x: bigint): bigint {
  // If index >= 32, return 0
  if (i >= 32n) {
    return 0n;
  }

  // Extract byte at index i (counting from MSB)
  // byte 0 is at bits 248-255, byte 31 is at bits 0-7
  const bitOffset = 8n * (31n - i);
  return (x >> bitOffset) & 0xffn;
}
