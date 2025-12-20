import { describe, test, expect } from "bun:test";
import {
  // Constants
  MAX_U256,
  MAX_U128,
  MAX_U64,
  MAX_U32,
  MIN_SIGNED_256,
  MAX_SIGNED_256,
  // Wrapping
  wrap256,
  wrap128,
  wrap64,
  wrap32,
  toU256,
  // Arithmetic
  addMod256,
  subMod256,
  mulMod256,
  divMod256,
  modMod256,
  // Signed conversions
  isNegative,
  toSigned,
  toUnsigned,
  abs256,
  sdivMod256,
  smodMod256,
  // Comparisons
  slt,
  sgt,
} from "./bigint";

// ============================================================================
// Constants Tests
// ============================================================================

describe("Constants", () => {
  test("MAX_U256 is 2^256 - 1", () => {
    expect(MAX_U256).toBe((1n << 256n) - 1n);
    expect(MAX_U256.toString(16).length).toBe(64); // 64 hex digits
  });

  test("MAX_U128 is 2^128 - 1", () => {
    expect(MAX_U128).toBe((1n << 128n) - 1n);
  });

  test("MAX_U64 is 2^64 - 1", () => {
    expect(MAX_U64).toBe((1n << 64n) - 1n);
  });

  test("MAX_U32 is 2^32 - 1", () => {
    expect(MAX_U32).toBe((1n << 32n) - 1n);
  });

  test("MIN_SIGNED_256 is -2^255", () => {
    expect(MIN_SIGNED_256).toBe(-(1n << 255n));
  });

  test("MAX_SIGNED_256 is 2^255 - 1", () => {
    expect(MAX_SIGNED_256).toBe((1n << 255n) - 1n);
  });
});

// ============================================================================
// Wrapping Operations Tests
// ============================================================================

describe("Wrapping Operations", () => {
  describe("wrap256", () => {
    test("identity for values in range", () => {
      expect(wrap256(0n)).toBe(0n);
      expect(wrap256(42n)).toBe(42n);
      expect(wrap256(MAX_U256)).toBe(MAX_U256);
    });

    test("wraps overflow", () => {
      expect(wrap256(MAX_U256 + 1n)).toBe(0n);
      expect(wrap256(MAX_U256 + 2n)).toBe(1n);
      expect(wrap256((1n << 256n) + 42n)).toBe(42n);
    });

    test("wraps negative values", () => {
      expect(wrap256(-1n)).toBe(MAX_U256);
      expect(wrap256(-2n)).toBe(MAX_U256 - 1n);
    });

    test("wraps large negative values", () => {
      const largeNegative = -(1n << 256n) - 42n;
      expect(wrap256(largeNegative)).toBe(MAX_U256 - 41n);
    });
  });

  describe("wrap128", () => {
    test("wraps at 2^128 boundary", () => {
      expect(wrap128(0n)).toBe(0n);
      expect(wrap128(MAX_U128)).toBe(MAX_U128);
      expect(wrap128(MAX_U128 + 1n)).toBe(0n);
      expect(wrap128((1n << 128n) + 42n)).toBe(42n);
    });
  });

  describe("wrap64", () => {
    test("wraps at 2^64 boundary", () => {
      expect(wrap64(0n)).toBe(0n);
      expect(wrap64(MAX_U64)).toBe(MAX_U64);
      expect(wrap64(MAX_U64 + 1n)).toBe(0n);
      expect(wrap64((1n << 64n) + 42n)).toBe(42n);
    });
  });

  describe("wrap32", () => {
    test("wraps at 2^32 boundary", () => {
      expect(wrap32(0n)).toBe(0n);
      expect(wrap32(MAX_U32)).toBe(MAX_U32);
      expect(wrap32(MAX_U32 + 1n)).toBe(0n);
      expect(wrap32((1n << 32n) + 42n)).toBe(42n);
    });
  });

  describe("toU256", () => {
    test("accepts valid u256 values", () => {
      expect(toU256(0n)).toBe(0n);
      expect(toU256(42n)).toBe(42n);
      expect(toU256(MAX_U256)).toBe(MAX_U256);
    });

    test("throws on negative values", () => {
      expect(() => toU256(-1n)).toThrow(RangeError);
      expect(() => toU256(-42n)).toThrow(RangeError);
    });

    test("throws on overflow", () => {
      expect(() => toU256(MAX_U256 + 1n)).toThrow(RangeError);
      expect(() => toU256((1n << 256n) + 1n)).toThrow(RangeError);
    });
  });
});

// ============================================================================
// Modular Arithmetic Tests
// ============================================================================

describe("Modular Arithmetic", () => {
  describe("addMod256", () => {
    test("adds normally when no overflow", () => {
      expect(addMod256(5n, 10n)).toBe(15n);
      expect(addMod256(0n, 0n)).toBe(0n);
      expect(addMod256(42n, 0n)).toBe(42n);
    });

    test("wraps on overflow", () => {
      expect(addMod256(MAX_U256, 1n)).toBe(0n);
      expect(addMod256(MAX_U256, 2n)).toBe(1n);
      expect(addMod256(MAX_U256, MAX_U256)).toBe(MAX_U256 - 1n);
    });

    test("handles large values", () => {
      const half = 1n << 255n;
      expect(addMod256(half, half)).toBe(0n); // 2^255 + 2^255 = 2^256 = 0 (mod 2^256)
    });
  });

  describe("subMod256", () => {
    test("subtracts normally when no underflow", () => {
      expect(subMod256(10n, 5n)).toBe(5n);
      expect(subMod256(42n, 0n)).toBe(42n);
      expect(subMod256(42n, 42n)).toBe(0n);
    });

    test("wraps on underflow", () => {
      expect(subMod256(0n, 1n)).toBe(MAX_U256);
      expect(subMod256(0n, 2n)).toBe(MAX_U256 - 1n);
      expect(subMod256(5n, 10n)).toBe(MAX_U256 - 4n);
    });
  });

  describe("mulMod256", () => {
    test("multiplies normally when no overflow", () => {
      expect(mulMod256(5n, 10n)).toBe(50n);
      expect(mulMod256(0n, 42n)).toBe(0n);
      expect(mulMod256(1n, MAX_U256)).toBe(MAX_U256);
    });

    test("wraps on overflow", () => {
      expect(mulMod256(2n, 1n << 255n)).toBe(0n); // 2 * 2^255 = 2^256 = 0 (mod 2^256)
      expect(mulMod256(MAX_U256, 2n)).toBe(MAX_U256 - 1n);
    });

    test("handles large multiplications", () => {
      const large = (1n << 200n);
      const result = mulMod256(large, large);
      expect(result).toBe(wrap256(large * large));
    });
  });

  describe("divMod256", () => {
    test("divides normally", () => {
      expect(divMod256(10n, 3n)).toBe(3n); // Truncates
      expect(divMod256(42n, 1n)).toBe(42n);
      expect(divMod256(MAX_U256, MAX_U256)).toBe(1n);
    });

    test("returns 0 on division by zero (EVM semantics)", () => {
      expect(divMod256(0n, 0n)).toBe(0n);
      expect(divMod256(42n, 0n)).toBe(0n);
      expect(divMod256(MAX_U256, 0n)).toBe(0n);
    });

    test("truncates toward zero", () => {
      expect(divMod256(10n, 3n)).toBe(3n);
      expect(divMod256(7n, 2n)).toBe(3n);
    });
  });

  describe("modMod256", () => {
    test("computes modulo normally", () => {
      expect(modMod256(10n, 3n)).toBe(1n);
      expect(modMod256(42n, 10n)).toBe(2n);
      expect(modMod256(7n, 7n)).toBe(0n);
    });

    test("returns 0 on modulo by zero (EVM semantics)", () => {
      expect(modMod256(0n, 0n)).toBe(0n);
      expect(modMod256(42n, 0n)).toBe(0n);
      expect(modMod256(MAX_U256, 0n)).toBe(0n);
    });

    test("handles large values", () => {
      expect(modMod256(MAX_U256, 2n)).toBe(1n);
      expect(modMod256(MAX_U256, 256n)).toBe(255n);
    });
  });
});

// ============================================================================
// Signed/Unsigned Conversions Tests
// ============================================================================

describe("Signed/Unsigned Conversions", () => {
  describe("isNegative", () => {
    test("returns false for positive values", () => {
      expect(isNegative(0n)).toBe(false);
      expect(isNegative(1n)).toBe(false);
      expect(isNegative(MAX_SIGNED_256)).toBe(false); // 2^255 - 1
    });

    test("returns true for negative values (sign bit set)", () => {
      expect(isNegative(1n << 255n)).toBe(true); // MIN_SIGNED_256 as unsigned
      expect(isNegative(MAX_U256)).toBe(true); // -1 as unsigned
      expect(isNegative(MAX_U256 - 1n)).toBe(true); // -2 as unsigned
    });

    test("boundary cases", () => {
      expect(isNegative((1n << 255n) - 1n)).toBe(false); // Largest positive
      expect(isNegative(1n << 255n)).toBe(true); // Smallest negative
    });
  });

  describe("toSigned", () => {
    test("identity for positive values", () => {
      expect(toSigned(0n)).toBe(0n);
      expect(toSigned(42n)).toBe(42n);
      expect(toSigned(MAX_SIGNED_256)).toBe(MAX_SIGNED_256);
    });

    test("converts negative unsigned to signed", () => {
      expect(toSigned(MAX_U256)).toBe(-1n);
      expect(toSigned(MAX_U256 - 1n)).toBe(-2n);
      expect(toSigned(1n << 255n)).toBe(MIN_SIGNED_256); // -2^255
    });

    test("boundary cases", () => {
      expect(toSigned((1n << 255n) - 1n)).toBe((1n << 255n) - 1n); // Max positive
      expect(toSigned(1n << 255n)).toBe(MIN_SIGNED_256); // Min negative
    });
  });

  describe("toUnsigned", () => {
    test("identity for positive values", () => {
      expect(toUnsigned(0n)).toBe(0n);
      expect(toUnsigned(42n)).toBe(42n);
      expect(toUnsigned(MAX_SIGNED_256)).toBe(MAX_SIGNED_256);
    });

    test("converts negative signed to unsigned", () => {
      expect(toUnsigned(-1n)).toBe(MAX_U256);
      expect(toUnsigned(-2n)).toBe(MAX_U256 - 1n);
      expect(toUnsigned(MIN_SIGNED_256)).toBe(1n << 255n);
    });

    test("round-trip conversions", () => {
      const testValues = [0n, 1n, -1n, 42n, -42n, MIN_SIGNED_256, MAX_SIGNED_256];
      for (const val of testValues) {
        expect(toSigned(toUnsigned(val))).toBe(val);
      }
    });
  });

  describe("abs256", () => {
    test("identity for positive values", () => {
      expect(abs256(0n)).toBe(0n);
      expect(abs256(42n)).toBe(42n);
      expect(abs256(MAX_SIGNED_256)).toBe(MAX_SIGNED_256);
    });

    test("negates negative values", () => {
      expect(abs256(-1n)).toBe(1n);
      expect(abs256(-42n)).toBe(42n);
      expect(abs256(-1000n)).toBe(1000n);
    });

    test("handles MIN_SIGNED_256 edge case", () => {
      // abs(MIN_SIGNED_256) cannot be represented as positive signed
      // Returns unsigned representation (2^255)
      expect(abs256(MIN_SIGNED_256)).toBe(1n << 255n);
    });
  });
});

// ============================================================================
// Signed Arithmetic Tests
// ============================================================================

describe("Signed Arithmetic", () => {
  describe("sdivMod256", () => {
    test("divides positive values", () => {
      expect(sdivMod256(10n, 3n)).toBe(3n);
      expect(sdivMod256(42n, 2n)).toBe(21n);
    });

    test("divides negative dividend by positive divisor", () => {
      const neg10 = toUnsigned(-10n);
      expect(sdivMod256(neg10, 3n)).toBe(toUnsigned(-3n));
    });

    test("divides positive dividend by negative divisor", () => {
      const neg3 = toUnsigned(-3n);
      expect(sdivMod256(10n, neg3)).toBe(toUnsigned(-3n));
    });

    test("divides negative by negative", () => {
      const neg10 = toUnsigned(-10n);
      const neg3 = toUnsigned(-3n);
      expect(sdivMod256(neg10, neg3)).toBe(3n);
    });

    test("returns 0 on division by zero", () => {
      expect(sdivMod256(42n, 0n)).toBe(0n);
      expect(sdivMod256(toUnsigned(-42n), 0n)).toBe(0n);
    });

    test("handles MIN_SIGNED_256 / -1 overflow", () => {
      const minSigned = toUnsigned(MIN_SIGNED_256);
      const negOne = toUnsigned(-1n);
      // -2^255 / -1 would be 2^255, which overflows
      // EVM returns -2^255 (same as input)
      expect(sdivMod256(minSigned, negOne)).toBe(minSigned);
    });
  });

  describe("smodMod256", () => {
    test("computes modulo with positive values", () => {
      expect(smodMod256(10n, 3n)).toBe(1n);
      expect(smodMod256(42n, 10n)).toBe(2n);
    });

    test("sign matches dividend (negative dividend, positive divisor)", () => {
      const neg10 = toUnsigned(-10n);
      expect(smodMod256(neg10, 3n)).toBe(toUnsigned(-1n));
    });

    test("sign matches dividend (positive dividend, negative divisor)", () => {
      const neg3 = toUnsigned(-3n);
      expect(smodMod256(10n, neg3)).toBe(1n); // Positive remainder
    });

    test("sign matches dividend (both negative)", () => {
      const neg10 = toUnsigned(-10n);
      const neg3 = toUnsigned(-3n);
      expect(smodMod256(neg10, neg3)).toBe(toUnsigned(-1n));
    });

    test("returns 0 on modulo by zero", () => {
      expect(smodMod256(42n, 0n)).toBe(0n);
      expect(smodMod256(toUnsigned(-42n), 0n)).toBe(0n);
    });
  });
});

// ============================================================================
// Comparison Tests
// ============================================================================

describe("Signed Comparisons", () => {
  describe("slt (signed less-than)", () => {
    test("compares positive values", () => {
      expect(slt(5n, 10n)).toBe(true);
      expect(slt(10n, 5n)).toBe(false);
      expect(slt(5n, 5n)).toBe(false);
    });

    test("compares negative values", () => {
      const neg5 = toUnsigned(-5n);
      const neg10 = toUnsigned(-10n);
      expect(slt(neg10, neg5)).toBe(true); // -10 < -5
      expect(slt(neg5, neg10)).toBe(false);
    });

    test("compares negative and positive", () => {
      const neg1 = toUnsigned(-1n);
      expect(slt(neg1, 0n)).toBe(true); // -1 < 0
      expect(slt(0n, neg1)).toBe(false);
      expect(slt(neg1, 5n)).toBe(true); // -1 < 5
    });

    test("boundary cases", () => {
      const minSigned = toUnsigned(MIN_SIGNED_256);
      const maxSigned = MAX_SIGNED_256;
      expect(slt(minSigned, maxSigned)).toBe(true);
      expect(slt(maxSigned, minSigned)).toBe(false);
    });
  });

  describe("sgt (signed greater-than)", () => {
    test("compares positive values", () => {
      expect(sgt(10n, 5n)).toBe(true);
      expect(sgt(5n, 10n)).toBe(false);
      expect(sgt(5n, 5n)).toBe(false);
    });

    test("compares negative values", () => {
      const neg5 = toUnsigned(-5n);
      const neg10 = toUnsigned(-10n);
      expect(sgt(neg5, neg10)).toBe(true); // -5 > -10
      expect(sgt(neg10, neg5)).toBe(false);
    });

    test("compares positive and negative", () => {
      const neg1 = toUnsigned(-1n);
      expect(sgt(0n, neg1)).toBe(true); // 0 > -1
      expect(sgt(neg1, 0n)).toBe(false);
      expect(sgt(5n, neg1)).toBe(true); // 5 > -1
    });

    test("boundary cases", () => {
      const minSigned = toUnsigned(MIN_SIGNED_256);
      const maxSigned = MAX_SIGNED_256;
      expect(sgt(maxSigned, minSigned)).toBe(true);
      expect(sgt(minSigned, maxSigned)).toBe(false);
    });
  });
});

// ============================================================================
// EVM Opcode Semantics Tests (Integration)
// ============================================================================

describe("EVM Opcode Semantics", () => {
  test("ADD opcode behavior", () => {
    // ADD: (a, b) => a + b (mod 2^256)
    expect(addMod256(MAX_U256, 1n)).toBe(0n);
    expect(addMod256(5n, 10n)).toBe(15n);
  });

  test("SUB opcode behavior", () => {
    // SUB: (a, b) => a - b (mod 2^256)
    expect(subMod256(0n, 1n)).toBe(MAX_U256);
    expect(subMod256(10n, 5n)).toBe(5n);
  });

  test("MUL opcode behavior", () => {
    // MUL: (a, b) => a * b (mod 2^256)
    expect(mulMod256(2n, 1n << 255n)).toBe(0n);
    expect(mulMod256(5n, 10n)).toBe(50n);
  });

  test("DIV opcode behavior", () => {
    // DIV: (a, b) => a / b (or 0 if b == 0)
    expect(divMod256(10n, 0n)).toBe(0n);
    expect(divMod256(10n, 3n)).toBe(3n);
  });

  test("MOD opcode behavior", () => {
    // MOD: (a, b) => a % b (or 0 if b == 0)
    expect(modMod256(10n, 0n)).toBe(0n);
    expect(modMod256(10n, 3n)).toBe(1n);
  });

  test("SDIV opcode behavior", () => {
    // SDIV: signed division
    const neg10 = toUnsigned(-10n);
    expect(sdivMod256(neg10, 3n)).toBe(toUnsigned(-3n));
    expect(sdivMod256(10n, 0n)).toBe(0n); // div by 0 = 0
  });

  test("SMOD opcode behavior", () => {
    // SMOD: signed modulo (sign from dividend)
    const neg10 = toUnsigned(-10n);
    expect(smodMod256(neg10, 3n)).toBe(toUnsigned(-1n));
    expect(smodMod256(10n, 0n)).toBe(0n); // mod by 0 = 0
  });

  test("SLT opcode behavior", () => {
    // SLT: signed less-than
    const neg1 = toUnsigned(-1n);
    expect(slt(neg1, 0n)).toBe(true);
    expect(slt(5n, 10n)).toBe(true);
  });

  test("SGT opcode behavior", () => {
    // SGT: signed greater-than
    const neg1 = toUnsigned(-1n);
    expect(sgt(0n, neg1)).toBe(true);
    expect(sgt(10n, 5n)).toBe(true);
  });
});

// ============================================================================
// Edge Cases and Special Values
// ============================================================================

describe("Edge Cases", () => {
  test("zero handling", () => {
    expect(wrap256(0n)).toBe(0n);
    expect(addMod256(0n, 0n)).toBe(0n);
    expect(subMod256(0n, 0n)).toBe(0n);
    expect(mulMod256(0n, MAX_U256)).toBe(0n);
    expect(divMod256(0n, 1n)).toBe(0n);
    expect(toSigned(0n)).toBe(0n);
    expect(toUnsigned(0n)).toBe(0n);
  });

  test("MAX_U256 handling", () => {
    expect(wrap256(MAX_U256)).toBe(MAX_U256);
    expect(addMod256(MAX_U256, 1n)).toBe(0n);
    expect(subMod256(MAX_U256, MAX_U256)).toBe(0n);
    expect(toSigned(MAX_U256)).toBe(-1n);
  });

  test("power of 2 boundaries", () => {
    for (let i = 0; i < 256; i++) {
      const pow = 1n << BigInt(i);
      expect(wrap256(pow)).toBe(pow);
    }
    expect(wrap256(1n << 256n)).toBe(0n);
  });

  test("signed/unsigned round-trips", () => {
    const testCases = [
      0n, 1n, -1n, 42n, -42n,
      MIN_SIGNED_256, MAX_SIGNED_256,
      1n << 100n, -(1n << 100n),
    ];

    for (const val of testCases) {
      const unsigned = toUnsigned(val);
      const signed = toSigned(unsigned);
      expect(signed).toBe(val);
    }
  });
});
