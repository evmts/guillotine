/**
 * Tests for BigInt bitwise utilities
 */

import { describe, it, expect } from 'vitest';
import {
  MASK_256,
  SIGN_BIT_256,
  mask256,
  isNegative256,
  toSigned256,
  toUnsigned256,
  sar256,
  shr256,
  shl256,
  byte256,
} from './bigint-bitwise';

describe('bigint-bitwise', () => {
  describe('constants', () => {
    it('MASK_256 should be 2^256 - 1', () => {
      expect(MASK_256).toBe((1n << 256n) - 1n);
    });

    it('SIGN_BIT_256 should be 2^255', () => {
      expect(SIGN_BIT_256).toBe(1n << 255n);
    });
  });

  describe('mask256', () => {
    it('should mask small values unchanged', () => {
      expect(mask256(0n)).toBe(0n);
      expect(mask256(1n)).toBe(1n);
      expect(mask256(255n)).toBe(255n);
    });

    it('should mask large values to 256 bits', () => {
      const overflowed = (1n << 256n) + 123n;
      expect(mask256(overflowed)).toBe(123n);
    });

    it('should handle max 256-bit value', () => {
      expect(mask256(MASK_256)).toBe(MASK_256);
    });

    it('should mask negative values', () => {
      // JavaScript bigint negatives should be masked properly
      const negative = -1n;
      const masked = mask256(negative);
      expect(masked).toBe(MASK_256);
    });
  });

  describe('isNegative256', () => {
    it('should return false for positive values', () => {
      expect(isNegative256(0n)).toBe(false);
      expect(isNegative256(1n)).toBe(false);
      expect(isNegative256(SIGN_BIT_256 - 1n)).toBe(false);
    });

    it('should return true for values with sign bit set', () => {
      expect(isNegative256(SIGN_BIT_256)).toBe(true);
      expect(isNegative256(MASK_256)).toBe(true);
    });

    it('should handle edge cases', () => {
      // Just below sign bit
      expect(isNegative256((1n << 255n) - 1n)).toBe(false);
      // Just at sign bit
      expect(isNegative256(1n << 255n)).toBe(true);
    });
  });

  describe('toSigned256', () => {
    it('should keep positive values unchanged', () => {
      expect(toSigned256(0n)).toBe(0n);
      expect(toSigned256(1n)).toBe(1n);
      expect(toSigned256(127n)).toBe(127n);
    });

    it('should convert negative values', () => {
      // Max positive (2^255 - 1)
      expect(toSigned256(SIGN_BIT_256 - 1n)).toBe(SIGN_BIT_256 - 1n);

      // -1 in two's complement
      expect(toSigned256(MASK_256)).toBe(-1n);

      // -128 in two's complement
      const neg128 = MASK_256 - 127n;
      expect(toSigned256(neg128)).toBe(-128n);
    });
  });

  describe('toUnsigned256', () => {
    it('should keep positive values unchanged', () => {
      expect(toUnsigned256(0n)).toBe(0n);
      expect(toUnsigned256(1n)).toBe(1n);
      expect(toUnsigned256(127n)).toBe(127n);
    });

    it('should convert negative values to two\'s complement', () => {
      expect(toUnsigned256(-1n)).toBe(MASK_256);
      expect(toUnsigned256(-128n)).toBe(MASK_256 - 127n);
    });

    it('should round-trip with toSigned256', () => {
      const values = [0n, 1n, 127n, -1n, -128n, -256n];
      for (const value of values) {
        const unsigned = toUnsigned256(value);
        const signed = toSigned256(unsigned);
        expect(signed).toBe(value);
      }
    });
  });

  describe('shl256', () => {
    it('should shift left by small amounts', () => {
      expect(shl256(1n, 0n)).toBe(1n);
      expect(shl256(1n, 1n)).toBe(2n);
      expect(shl256(1n, 4n)).toBe(16n);
      expect(shl256(0xfn, 4n)).toBe(0xf0n);
    });

    it('should return 0 for shift >= 256', () => {
      expect(shl256(1n, 256n)).toBe(0n);
      expect(shl256(MASK_256, 256n)).toBe(0n);
      expect(shl256(1n, 1000n)).toBe(0n);
    });

    it('should mask result to 256 bits', () => {
      const value = 1n << 255n;
      const shifted = shl256(value, 1n);
      expect(shifted).toBe(0n); // Overflows to 0
    });

    it('should handle large shifts under 256', () => {
      expect(shl256(1n, 255n)).toBe(SIGN_BIT_256);
    });
  });

  describe('shr256', () => {
    it('should shift right by small amounts', () => {
      expect(shr256(16n, 0n)).toBe(16n);
      expect(shr256(16n, 1n)).toBe(8n);
      expect(shr256(16n, 4n)).toBe(1n);
      expect(shr256(0xf0n, 4n)).toBe(0xfn);
    });

    it('should return 0 for shift >= 256', () => {
      expect(shr256(MASK_256, 256n)).toBe(0n);
      expect(shr256(SIGN_BIT_256, 256n)).toBe(0n);
      expect(shr256(1n, 1000n)).toBe(0n);
    });

    it('should zero-fill (not sign-extend)', () => {
      // Most significant bit set
      const value = SIGN_BIT_256;
      const shifted = shr256(value, 4n);

      // Should shift right with zeros
      expect(shifted).toBe(SIGN_BIT_256 >> 4n);
      // After shifting right by 4, the sign bit is no longer set
      expect(isNegative256(shifted)).toBe(false);
    });

    it('should handle edge case at 255 bits', () => {
      expect(shr256(SIGN_BIT_256, 255n)).toBe(1n);
    });
  });

  describe('sar256', () => {
    it('should shift right positive values like shr', () => {
      expect(sar256(16n, 0n)).toBe(16n);
      expect(sar256(16n, 1n)).toBe(8n);
      expect(sar256(16n, 4n)).toBe(1n);
    });

    it('should sign-extend negative values', () => {
      // All bits set (-1)
      const allOnes = MASK_256;
      expect(sar256(allOnes, 1n)).toBe(MASK_256);
      expect(sar256(allOnes, 4n)).toBe(MASK_256);
      expect(sar256(allOnes, 255n)).toBe(MASK_256);

      // Sign bit only
      const signBit = SIGN_BIT_256;
      const shifted = sar256(signBit, 4n);
      expect(isNegative256(shifted)).toBe(true);
      // Should have 4 more 1s at the top
      expect(shifted).toBe(0xf800000000000000000000000000000000000000000000000000000000000000n);
    });

    it('should return all 1s for negative value with shift >= 256', () => {
      expect(sar256(SIGN_BIT_256, 256n)).toBe(MASK_256);
      expect(sar256(MASK_256, 256n)).toBe(MASK_256);
      expect(sar256(SIGN_BIT_256, 1000n)).toBe(MASK_256);
    });

    it('should return 0 for positive value with shift >= 256', () => {
      expect(sar256(0n, 256n)).toBe(0n);
      expect(sar256(1n, 256n)).toBe(0n);
      expect(sar256(SIGN_BIT_256 - 1n, 256n)).toBe(0n);
    });

    it('should differ from shr for negative values', () => {
      const negative = SIGN_BIT_256;
      const shift = 4n;

      const shrResult = shr256(negative, shift);
      const sarResult = sar256(negative, shift);

      // SHR shifts right with zero-fill, so sign bit is lost
      expect(isNegative256(shrResult)).toBe(false);
      // SAR preserves sign bit with sign extension
      expect(isNegative256(sarResult)).toBe(true);

      // SAR should have more 1s (sign extension)
      expect(sarResult).toBeGreaterThan(shrResult);
    });
  });

  describe('byte256', () => {
    it('should extract byte 0 (most significant)', () => {
      const value = 0xff00000000000000000000000000000000000000000000000000000000000000n;
      expect(byte256(0n, value)).toBe(0xffn);
    });

    it('should extract byte 31 (least significant)', () => {
      const value = 0x00000000000000000000000000000000000000000000000000000000000000ffn;
      expect(byte256(31n, value)).toBe(0xffn);
    });

    it('should extract middle bytes', () => {
      // byte 15 is at bit positions 128-135 (counting from MSB)
      // 0xab at byte position 15 means: shift left by (31-15)*8 = 128 bits
      const value = 0xabn << 128n;
      expect(byte256(15n, value)).toBe(0xabn);
    });

    it('should return 0 for out of bounds index', () => {
      const value = MASK_256;
      expect(byte256(32n, value)).toBe(0n);
      expect(byte256(100n, value)).toBe(0n);
      expect(byte256(1000n, value)).toBe(0n);
    });

    it('should extract all bytes from sequential value', () => {
      const value = 0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdefn;
      const expected = [
        0x01n, 0x23n, 0x45n, 0x67n, 0x89n, 0xabn, 0xcdn, 0xefn,
        0x01n, 0x23n, 0x45n, 0x67n, 0x89n, 0xabn, 0xcdn, 0xefn,
        0x01n, 0x23n, 0x45n, 0x67n, 0x89n, 0xabn, 0xcdn, 0xefn,
        0x01n, 0x23n, 0x45n, 0x67n, 0x89n, 0xabn, 0xcdn, 0xefn,
      ];

      for (let i = 0; i < 32; i++) {
        expect(byte256(BigInt(i), value)).toBe(expected[i]);
      }
    });

    it('should handle zero value', () => {
      for (let i = 0; i < 32; i++) {
        expect(byte256(BigInt(i), 0n)).toBe(0n);
      }
    });

    it('should handle all ones value', () => {
      for (let i = 0; i < 32; i++) {
        expect(byte256(BigInt(i), MASK_256)).toBe(0xffn);
      }
    });
  });

  describe('edge cases', () => {
    it('should handle max 256-bit value in all operations', () => {
      const max = MASK_256;

      expect(mask256(max)).toBe(max);
      expect(isNegative256(max)).toBe(true);
      expect(shl256(max, 1n)).toBe(max - 1n);
      expect(shr256(max, 1n)).toBe(max >> 1n);
      expect(sar256(max, 1n)).toBe(max);
    });

    it('should handle zero in all operations', () => {
      expect(mask256(0n)).toBe(0n);
      expect(isNegative256(0n)).toBe(false);
      expect(shl256(0n, 4n)).toBe(0n);
      expect(shr256(0n, 4n)).toBe(0n);
      expect(sar256(0n, 4n)).toBe(0n);
      expect(byte256(0n, 0n)).toBe(0n);
    });
  });
});
