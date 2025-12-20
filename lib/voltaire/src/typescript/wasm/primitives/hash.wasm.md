# Code Review: hash.wasm.ts

## Overview
WASM wrapper for cryptographic hash functions (SHA-256, RIPEMD-160, BLAKE2b) and Solidity-style hash operations. Provides TypeScript bindings to Zig-implemented hash algorithms used in Ethereum and Bitcoin.

## Code Quality

### Strengths
- **Clean function API**: Simple, focused functions for each hash type
- **Type flexibility**: Accepts both strings and Uint8Array
- **Good documentation**: JSDoc explains each hash algorithm
- **Consistent pattern**: All hash functions follow same structure
- **Defensive copying**: Creates new Uint8Array before WASM calls

### Weaknesses
- **Inconsistent empty input handling**: Throws error for empty input (lines 18, 36, 52, 68, 82)
- **No output size documentation**: Doesn't specify hash output lengths in JSDoc
- **Limited error context**: Generic "cannot be empty" messages
- **No test file**: Missing companion test file

## Completeness

### Complete Features
- ✅ SHA-256 hashing
- ✅ RIPEMD-160 hashing
- ✅ BLAKE2b hashing
- ✅ Solidity Keccak-256 (for packed data)
- ✅ Solidity SHA-256 (for packed data)
- ✅ String and byte array input support

### Missing Features
- ❌ No Solidity RIPEMD-160 wrapper
- ❌ No BLAKE2s (256-bit variant)
- ❌ No incremental/streaming hashing
- ❌ No HMAC variants

### TODOs/Stubs
- ✅ No TODOs found
- ✅ All functions fully implemented
- ❌ **CRITICAL: No test file exists**

## Test Coverage

Test file: **MISSING** ❌

### Critical Issue
No test file found at `hash.wasm.test.ts`. This is a serious gap for cryptographic code.

### Required Tests
Should include:
- Known test vectors for each hash algorithm
- Parity tests with native implementation
- Empty input handling
- Large input handling
- String vs byte array equivalence
- Comparison with standard hash libraries

## Issues Found

### 1. Empty Input Rejection (Critical Design Issue)
**Location**: Lines 18-20, 36-38, 52-54, 68-70, 82-84
```typescript
if (input.length === 0) {
    throw new Error("Input data cannot be empty");
}
```
**Issue**: Empty input is valid for cryptographic hashes and has well-defined outputs
**Impact**:
- Breaks compatibility with standard hash libraries
- SHA-256 of empty string is well-known: `0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- RIPEMD-160 empty: `0x9c1185a5c5e9fc54612808977ee8f548b2258d31`
- Makes hashing empty arrays impossible
**Recommendation**: Remove these checks - cryptographic hashes are defined for empty input
```typescript
export function sha256(data: string | Uint8Array): Uint8Array {
    const input = typeof data === "string"
        ? new TextEncoder().encode(data)
        : new Uint8Array(data);

    return loader.sha256(input); // Let WASM handle all cases
}
```

### 2. Missing Output Size Documentation
**Location**: All function JSDoc comments
```typescript
/**
 * Compute SHA-256 hash
 * @param data - Input data (string, Uint8Array, or Buffer)
 * @returns 32-byte SHA-256 hash  // ❌ Not documented
 */
```
**Issue**: Return type says `Uint8Array` but doesn't specify size
**Impact**: Developers must look at implementation or know hash sizes
**Recommendation**: Document output sizes:
```typescript
/**
 * Compute SHA-256 hash
 * @param data - Input data (string, Uint8Array, or Buffer)
 * @returns 32-byte SHA-256 hash digest
 */
export function sha256(data: string | Uint8Array): Uint8Array
```

### 3. "Solidity" Naming May Be Confusing
**Location**: Lines 64-72, 79-87
```typescript
export function solidityKeccak256(packedData: Uint8Array): Uint8Array
export function soliditySha256(packedData: Uint8Array): Uint8Array
```
**Issue**: Names suggest Solidity-specific behavior, but they just hash pre-packed bytes
**Impact**: Users may think these functions do the packing
**Recommendation**: Clarify in documentation:
```typescript
/**
 * Compute Keccak-256 hash of tightly packed data
 *
 * Note: This function expects data to already be packed according to
 * Solidity rules. Use a separate packing function to prepare data.
 *
 * Solidity packing rules:
 * - uint: encoded as big-endian, left-padded to type size
 * - address: encoded as 20 bytes
 * - bytes: encoded as-is, no padding
 * - string: encoded as UTF-8 bytes
 *
 * @param packedData - Pre-packed data bytes
 * @returns 32-byte Keccak-256 hash
 */
```

### 4. CRITICAL: No Test File
**Issue**: `hash.wasm.test.ts` does not exist
**Impact**: Cryptographic code without tests is extremely dangerous
**Recommendation**: Create comprehensive test file with known test vectors

### 5. No Maximum Input Size Documented
**Issue**: No documentation of maximum input size
**Impact**: Users don't know limits for large file hashing
**Recommendation**: Document or test maximum sizes

## Memory Management Analysis

### WASM Binding Pattern
- Creates `Uint8Array` copy for each call
- WASM returns new array
- No explicit cleanup needed

### Concerns
- ⚠️ Large input (GB-scale) creates temporary copies
- ❌ No streaming interface for large files

### Recommendations
- Document maximum practical input size
- Consider streaming API for large inputs

## Recommendations

### Critical Priority (MUST FIX)

1. **Create Comprehensive Test File**:
   ```typescript
   // hash.wasm.test.ts
   import { test, expect, describe } from "bun:test";
   import { sha256, ripemd160, blake2b } from "./hash.wasm";
   import * as native from "../../native/primitives/hash.native";

   describe("WASM Hash parity", () => {
       test("SHA-256 known test vectors", () => {
           // NIST test vectors
           expect(bytesToHex(sha256(""))).toBe(
               "0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
           );
           expect(bytesToHex(sha256("abc"))).toBe(
               "0xba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
           );
       });

       test("RIPEMD-160 known test vectors", () => {
           expect(bytesToHex(ripemd160(""))).toBe(
               "0x9c1185a5c5e9fc54612808977ee8f548b2258d31"
           );
       });

       test("BLAKE2b known test vectors", () => {
           // Test against reference implementation
       });

       test("matches native implementation", () => {
           const inputs = ["", "test", "hello world", new Uint8Array([0x42])];
           for (const input of inputs) {
               expect(sha256(input)).toEqual(native.sha256(input));
               expect(ripemd160(input)).toEqual(native.ripemd160(input));
               expect(blake2b(input)).toEqual(native.blake2b(input));
           }
       });
   });
   ```

2. **Remove Empty Input Checks** (as shown in Issue #1):
   Empty input is valid for all cryptographic hash functions

### High Priority

3. **Document Output Sizes** (as shown in Issue #2)

4. **Clarify Solidity Function Documentation** (as shown in Issue #3)

5. **Add Input Size Limits Documentation**:
   ```typescript
   /**
    * Compute SHA-256 hash
    *
    * Maximum input size: Determined by WASM memory limits (typically 2GB)
    * For files > 100MB, consider streaming APIs
    *
    * @param data - Input data (string, Uint8Array, or Buffer)
    * @returns 32-byte SHA-256 hash digest
    */
   ```

### Medium Priority

6. **Add Known Test Vectors as Documentation**:
   ```typescript
   /**
    * Compute SHA-256 hash
    *
    * @example
    * // NIST test vectors
    * sha256("") // 0xe3b0c442...
    * sha256("abc") // 0xba7816bf...
    *
    * @param data - Input data
    * @returns 32-byte SHA-256 hash digest
    */
   ```

7. **Add Type-Safe Wrappers for Solidity Functions**:
   ```typescript
   /**
    * Pack and hash multiple values according to Solidity rules
    */
   export function solidityKeccak256Multi(...values: SolidityValue[]): Uint8Array {
       const packed = solidityPack(values);
       return solidityKeccak256(packed);
   }
   ```

### Low Priority

8. **Add Convenience Methods**:
   ```typescript
   export function sha256Hex(data: string | Uint8Array): string {
       return bytesToHex(sha256(data));
   }

   export function ripemd160Hex(data: string | Uint8Array): string {
       return bytesToHex(ripemd160(data));
   }
   ```

9. **Add Streaming Interface** (for large files):
   ```typescript
   export class SHA256Stream {
       private context: Uint8Array;

       update(data: Uint8Array): void {
           this.context = loader.sha256Update(this.context, data);
       }

       finalize(): Uint8Array {
           return loader.sha256Finalize(this.context);
       }
   }
   ```

## Security Considerations

### Critical
- ❌ **NO TESTS**: Cryptographic code without tests is unacceptable
- ⚠️ Empty input rejection breaks standard behavior

### Positive
- ✅ Delegates to audited Zig implementation
- ✅ No direct memory manipulation in TypeScript
- ✅ Defensive copying

### Required Actions
1. Add comprehensive tests with known test vectors
2. Cross-validate against standard libraries (crypto-js, noble-hashes)
3. Remove empty input checks

## Overall Assessment

**Grade: C** (Needs Significant Work)

The code structure is clean, but the **complete absence of tests for cryptographic functions is unacceptable**. Additionally, the empty input rejection breaks standard hash behavior and compatibility with other libraries.

**Ready for production use**: ❌ NO - Missing tests
**Requires changes before merge**: ✅ YES - Critical issues must be fixed

### Blocking Issues
1. ❌ No test file - MUST CREATE
2. ❌ Empty input rejection - MUST REMOVE
3. ❌ No known test vectors validated

### Must Address Before Production
- Create comprehensive test file with known test vectors
- Remove empty input checks
- Document output sizes
- Validate against standard hash implementations

### After Fixes
Once tests are added and empty input checks removed, this could be production-ready. The underlying WASM implementation is presumably correct, but TypeScript wrapper needs validation.
