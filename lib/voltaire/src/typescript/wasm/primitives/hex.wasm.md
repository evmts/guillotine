# Code Review: hex.wasm.ts

## Overview
Minimal WASM wrapper for hexadecimal encoding/decoding operations. Provides simple TypeScript bindings to Zig-implemented hex conversion functions.

## Code Quality

### Strengths
- **Minimal and focused**: Only two functions, clear purpose
- **Defensive copying**: Creates new Uint8Array before WASM call (line 23)
- **Clean API**: Simple function names match their behavior
- **Documentation**: JSDoc present for both functions

### Weaknesses
- **Asymmetric copying**: `bytesToHex` copies input, `hexToBytes` doesn't
- **No validation**: No client-side input validation
- **Limited documentation**: Missing details about format (lowercase/uppercase, 0x prefix)
- **No test file**: Missing companion test file

## Completeness

### Complete Features
- ✅ Hex string to bytes conversion
- ✅ Bytes to hex string conversion
- ✅ Handles 0x prefix (presumably in WASM)

### Missing Features
- ❌ No uppercase/lowercase control
- ❌ No validation utilities (isValidHex, etc.)
- ❌ No padding/trimming options
- ❌ No bigint conversion helpers

### TODOs/Stubs
- ✅ No TODOs found
- ✅ Functions fully implemented
- ❌ **No test file exists**

## Test Coverage

Test file: **MISSING** ❌

### Critical Issue
No test file found at `hex.wasm.test.ts`. Basic utilities like hex encoding need validation.

### Required Tests
Should include:
- Roundtrip consistency (bytes → hex → bytes)
- With/without 0x prefix
- Uppercase/lowercase handling
- Empty input
- Odd-length hex strings
- Invalid hex characters
- Parity with native implementation

## Issues Found

### 1. Inconsistent Defensive Copying
**Location**: Lines 13-14 vs 22-24
```typescript
export function hexToBytes(hex: string): Uint8Array {
    return loader.hexToBytes(hex); // No copy needed (string input)
}

export function bytesToHex(data: Uint8Array): string {
    const input = new Uint8Array(data); // Defensive copy
    return loader.bytesToHex(input);
}
```
**Analysis**: Actually correct - strings are immutable, but bytes could be mutated
**Issue**: Not documented why one copies and one doesn't
**Recommendation**: Add comments explaining the pattern

### 2. CRITICAL: No Test File
**Issue**: `hex.wasm.test.ts` does not exist
**Impact**: Basic encoding utilities without validation
**Recommendation**: Create test file immediately

### 3. Missing Format Documentation
**Location**: Lines 8-25
```typescript
/**
 * Convert hex string to bytes
 * @param hex - Hex string (with or without 0x prefix)
 * @returns Raw bytes
 */
export function hexToBytes(hex: string): Uint8Array
```
**Issue**: Doesn't specify:
- Are both uppercase and lowercase accepted?
- What about mixed case?
- Are odd-length strings accepted (e.g., "0xF")?
- What errors are thrown for invalid input?

**Recommendation**: Document format clearly:
```typescript
/**
 * Convert hex string to bytes
 *
 * Format:
 * - Accepts both "0x" prefix and without
 * - Case insensitive (accepts both "0xAB" and "0xab")
 * - Must be even length (after removing 0x prefix)
 *
 * @param hex - Hex string (with or without 0x prefix)
 * @returns Raw bytes
 * @throws {Error} if hex contains non-hex characters or is odd length
 *
 * @example
 * hexToBytes("0x48656c6c6f") // Uint8Array([0x48, 0x65, 0x6c, 0x6c, 0x6f])
 * hexToBytes("48656c6c6f")   // Same result
 * hexToBytes("0xFF")         // Uint8Array([0xFF])
 */
```

### 4. No Output Format Documentation
**Location**: Lines 17-25
```typescript
/**
 * Convert bytes to hex string
 * @param data - Raw bytes
 * @returns Hex string with 0x prefix
 */
```
**Issue**: Doesn't specify if output is lowercase or uppercase
**Recommendation**: Document output format:
```typescript
/**
 * Convert bytes to hex string
 *
 * Output format:
 * - Always includes "0x" prefix
 * - Always lowercase (a-f, not A-F)
 * - Always even length
 *
 * @param data - Raw bytes
 * @returns Hex string with 0x prefix (lowercase)
 *
 * @example
 * bytesToHex(new Uint8Array([0x48, 0x65])) // "0x4865"
 * bytesToHex(new Uint8Array([]))           // "0x"
 */
```

### 5. No Validation Utilities
**Issue**: Common hex validation tasks not provided
**Impact**: Users must implement their own validation
**Recommendation**: Add utility functions:
```typescript
/**
 * Check if string is valid hex
 */
export function isValidHex(hex: string): boolean {
    if (!hex) return false;
    const withoutPrefix = hex.startsWith("0x") ? hex.slice(2) : hex;
    return /^[0-9a-fA-F]*$/.test(withoutPrefix) && withoutPrefix.length % 2 === 0;
}

/**
 * Normalize hex string (add 0x prefix, lowercase)
 */
export function normalizeHex(hex: string): string {
    const cleaned = hex.startsWith("0x") ? hex : `0x${hex}`;
    return cleaned.toLowerCase();
}
```

## Memory Management Analysis

### WASM Binding Pattern
- `hexToBytes`: Returns new array from WASM
- `bytesToHex`: Creates defensive copy before call
- No explicit cleanup needed

### Concerns
None - simple functions with no memory leak potential

## Recommendations

### Critical Priority (MUST FIX)

1. **Create Comprehensive Test File**:
   ```typescript
   // hex.wasm.test.ts
   import { test, expect, describe } from "bun:test";
   import { hexToBytes, bytesToHex } from "./hex.wasm";
   import * as native from "../../native/primitives/hex.native";

   describe("WASM Hex parity", () => {
       test("roundtrip consistency", () => {
           const testCases = [
               new Uint8Array([]),
               new Uint8Array([0x00]),
               new Uint8Array([0xFF]),
               new Uint8Array([0x48, 0x65, 0x6c, 0x6c, 0x6f]), // "Hello"
           ];

           for (const bytes of testCases) {
               const hex = bytesToHex(bytes);
               const decoded = hexToBytes(hex);
               expect(decoded).toEqual(bytes);
           }
       });

       test("hexToBytes with and without 0x prefix", () => {
           const withPrefix = hexToBytes("0x48656c6c6f");
           const withoutPrefix = hexToBytes("48656c6c6f");

           expect(withPrefix).toEqual(withoutPrefix);
           expect(withPrefix).toEqual(new Uint8Array([0x48, 0x65, 0x6c, 0x6c, 0x6f]));
       });

       test("case insensitivity", () => {
           const lower = hexToBytes("0xabcdef");
           const upper = hexToBytes("0xABCDEF");
           const mixed = hexToBytes("0xAbCdEf");

           expect(lower).toEqual(upper);
           expect(lower).toEqual(mixed);
       });

       test("matches native implementation", () => {
           const testData = [
               "0x",
               "0x00",
               "0xFF",
               "0x48656c6c6f",
               "48656c6c6f",
           ];

           for (const hex of testData) {
               expect(hexToBytes(hex)).toEqual(native.hexToBytes(hex));
           }

           const testBytes = [
               new Uint8Array([]),
               new Uint8Array([0x00]),
               new Uint8Array([0xFF]),
           ];

           for (const bytes of testBytes) {
               expect(bytesToHex(bytes)).toBe(native.bytesToHex(bytes));
           }
       });

       test("error handling", () => {
           expect(() => hexToBytes("0xGG")).toThrow(); // Invalid hex
           expect(() => hexToBytes("0x1")).toThrow();  // Odd length
           expect(() => hexToBytes("not-hex")).toThrow();
       });
   });
   ```

### High Priority

2. **Document Output Format** (as shown in Issue #4)

3. **Document Input Format** (as shown in Issue #3)

4. **Add Explanatory Comments**:
   ```typescript
   export function hexToBytes(hex: string): Uint8Array {
       // No defensive copy needed - strings are immutable
       return loader.hexToBytes(hex);
   }

   export function bytesToHex(data: Uint8Array): string {
       // Defensive copy - caller might mutate original array
       const input = new Uint8Array(data);
       return loader.bytesToHex(input);
   }
   ```

### Medium Priority

5. **Add Validation Utilities** (as shown in Issue #5)

6. **Add Convenience Functions**:
   ```typescript
   /**
    * Ensure hex string has 0x prefix
    */
   export function ensureHexPrefix(hex: string): string {
       return hex.startsWith("0x") ? hex : `0x${hex}`;
   }

   /**
    * Remove 0x prefix if present
    */
   export function stripHexPrefix(hex: string): string {
       return hex.startsWith("0x") ? hex.slice(2) : hex;
   }

   /**
    * Pad hex string to specified byte length
    */
   export function padHex(hex: string, byteLength: number): string {
       const stripped = stripHexPrefix(hex);
       const padded = stripped.padStart(byteLength * 2, "0");
       return ensureHexPrefix(padded);
   }
   ```

### Low Priority

7. **Add Bigint Conversion Helpers**:
   ```typescript
   export function hexToBigInt(hex: string): bigint {
       return BigInt(ensureHexPrefix(hex));
   }

   export function bigIntToHex(value: bigint, byteLength?: number): string {
       let hex = value.toString(16);
       if (byteLength) {
           hex = hex.padStart(byteLength * 2, "0");
       }
       return `0x${hex}`;
   }
   ```

## Overall Assessment

**Grade: C+** (Needs Work)

The core functionality is simple and likely correct, but the **complete absence of tests is unacceptable** for a utility library. Documentation is minimal and doesn't clarify important format details.

**Ready for production use**: ❌ NO - Missing tests
**Requires changes before merge**: ✅ YES - Must add tests

### Blocking Issues
1. ❌ No test file - MUST CREATE
2. ⚠️ Missing format documentation

### Must Address Before Production
- Create comprehensive test file
- Document input/output formats clearly
- Add error handling examples

### After Fixes
Once tests are added and documentation improved, this module should be production-ready. The simplicity is actually a strength - fewer things to break.

### Comparison to Other Modules
This is one of the simpler modules in the codebase. While that's good for maintainability, it also means tests are quick to write and absolutely necessary before production use.
