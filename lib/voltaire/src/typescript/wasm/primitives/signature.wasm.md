# Code Review: signature.wasm.ts

## Overview
WASM wrapper for secp256k1 ECDSA signature operations. Provides TypeScript bindings to Zig-implemented cryptographic signature functions including public key recovery, address recovery, signature validation, and normalization.

## Code Quality

**Grade: B** (Good)

### Strengths
- **Comprehensive signature operations**: Recovery, validation, normalization, parsing, serialization
- **Strong input validation**: All functions validate input lengths and ranges
- **Type safety**: Clear interfaces and types
- **Good documentation**: JSDoc explains each parameter

### Weaknesses
- **Inconsistent module import**: Uses `require()` instead of ES6 import (line 6)
- **No actual signing function**: Can recover signatures but not create them
- **Redundant defensive copying**: Creates copies unnecessarily in some places
- **No test file**: Missing companion test file (CRITICAL for crypto code)

## Completeness

### Complete Features
- ✅ Public key recovery from signature
- ✅ Address recovery from signature
- ✅ Public key derivation from private key
- ✅ Signature validation
- ✅ Signature normalization (EIP-2 low-S)
- ✅ Canonical signature checking
- ✅ Signature parsing (64/65 bytes)
- ✅ Signature serialization

### Missing Features
- ❌ **CRITICAL: No signing function** (can recover but not create signatures)
- ❌ No typed data signing (EIP-712)
- ❌ No batch signature operations
- ❌ No signature verification (only validation of components)

### TODOs/Stubs
- ✅ No TODOs in code
- ❌ **CRITICAL: No test file exists**

## Test Coverage

Test file: **MISSING** ❌

### Critical Issue
No test file found at `signature.wasm.test.ts`. This is **unacceptable for cryptographic code**.

### Required Tests
Must include:
- Known test vectors for signature recovery
- Public key derivation validation
- Signature normalization correctness
- Canonical signature detection
- Parsing and serialization roundtrip
- Error handling for invalid inputs
- Parity with native implementation

## Issues Found

### 1. CRITICAL: No Test File
**Issue**: Cryptographic signature operations with no tests
**Impact**: Cannot validate correctness, extremely dangerous
**Recommendation**: CREATE IMMEDIATELY

### 2. CRITICAL: No Signing Function
**Issue**: Can verify signatures but not create them
**Location**: Missing functionality
**Impact**: Cannot actually sign messages or transactions
**Recommendation**: Add signing function:
```typescript
/**
 * Sign message hash with private key
 * WARNING: This function is unaudited. Only use for testing.
 * @param messageHash - 32-byte message hash
 * @param privateKey - 32-byte private key
 * @returns Signature with r, s, v components
 */
export function secp256k1Sign(
    messageHash: Uint8Array,
    privateKey: Uint8Array,
): ParsedSignature {
    if (messageHash.length !== 32) {
        throw new Error("Message hash must be 32 bytes");
    }
    if (privateKey.length !== 32) {
        throw new Error("Private key must be 32 bytes");
    }

    const [r, s, v] = primitives.secp256k1Sign(messageHash, privateKey);
    return {
        r: new Uint8Array(r),
        s: new Uint8Array(s),
        v: v,
    };
}
```

### 3. CommonJS Import in ES Module
**Location**: Line 6
```typescript
const primitives = require('../../../wasm/loader.js');
```
**Issue**: Uses `require()` while rest of codebase uses ES6 imports
**Impact**: Inconsistent module system
**Recommendation**: Change to ES6 import:
```typescript
import * as primitives from '../../../wasm/loader.js';
```

### 4. Redundant Defensive Copies
**Location**: Lines 44-46, 55-57, 76-77, 110-111, 131-132, 149-150
```typescript
const hashArr = new Uint8Array(messageHash);
const rArr = new Uint8Array(r);
const sArr = new Uint8Array(s);
```
**Issue**: Creates copies even though Uint8Arrays are already immutable references
**Analysis**: Actually, this is defensive against mutation. However, could be more efficient
**Recommendation**: Document why copying is done or remove if not needed

### 5. V Parameter Range Not Fully Validated
**Location**: Lines 40-42, 70-72
```typescript
if (v < 0 || v > 3) {
    throw new Error("Recovery parameter v must be 0-3");
}
```
**Issue**: Ethereum uses v=27/28 in signatures, this validates 0-3
**Analysis**: This is recovery ID (0-3), not Ethereum v value (27-28, 35+)
**Recommendation**: Clarify in documentation:
```typescript
/**
 * Recover public key from ECDSA signature
 * @param messageHash - 32-byte message hash
 * @param r - R component of signature (32 bytes)
 * @param s - S component of signature (32 bytes)
 * @param v - Recovery ID (0-3, not Ethereum v value 27/28)
 * @returns Uncompressed public key (64 bytes, no 0x04 prefix)
 */
```

### 6. No EIP-2 Enforcement Option
**Issue**: Can normalize signatures but can't enforce low-S during recovery
**Recommendation**: Add option to auto-normalize:
```typescript
export interface RecoveryOptions {
    /** Automatically normalize to canonical (low-S) form */
    normalize?: boolean;
}

export function secp256k1RecoverPubkey(
    messageHash: Uint8Array,
    r: Uint8Array,
    s: Uint8Array,
    v: number,
    options?: RecoveryOptions,
): Uint8Array {
    if (options?.normalize && !signatureIsCanonical(r, s)) {
        [r, s] = signatureNormalize(r, s);
    }

    // ... existing recovery logic
}
```

### 7. Missing Signature Verification
**Issue**: Can validate components (r, s) but not verify signature against message+pubkey
**Recommendation**: Add verification function:
```typescript
/**
 * Verify ECDSA signature
 * @param messageHash - 32-byte message hash
 * @param signature - Parsed signature (r, s, v)
 * @param publicKey - 64-byte uncompressed public key
 * @returns true if signature is valid
 */
export function secp256k1Verify(
    messageHash: Uint8Array,
    signature: ParsedSignature,
    publicKey: Uint8Array,
): boolean {
    if (messageHash.length !== 32) {
        throw new Error("Message hash must be 32 bytes");
    }
    if (publicKey.length !== 64) {
        throw new Error("Public key must be 64 bytes");
    }

    return primitives.secp256k1Verify(
        messageHash,
        signature.r,
        signature.s,
        publicKey,
    );
}
```

## Memory Management Analysis

### WASM Binding Pattern
- Creates defensive copies before WASM calls
- WASM returns new arrays
- No explicit cleanup needed

### Concerns
- ⚠️ Multiple temporary allocations per operation
- ❌ No memory leak tests

## Recommendations

### Critical Priority (MUST FIX)

1. **Create Comprehensive Test File** (Issue #1):
   ```typescript
   // signature.wasm.test.ts
   import { test, expect, describe } from "bun:test";
   import * as wasm from "./signature.wasm";
   import * as native from "../../native/primitives/signature.native";

   describe("WASM Signature parity", () => {
       test("public key recovery matches native", () => {
           // Use known test vectors
           const messageHash = new Uint8Array(32).fill(0x42);
           const r = new Uint8Array(32); // Known r value
           const s = new Uint8Array(32); // Known s value
           const v = 0;

           const nativePubkey = native.secp256k1RecoverPubkey(messageHash, r, s, v);
           const wasmPubkey = wasm.secp256k1RecoverPubkey(messageHash, r, s, v);

           expect(wasmPubkey).toEqual(nativePubkey);
       });

       test("signature normalization", () => {
           // Test with high-S signature
           const highS = new Uint8Array(32).fill(0xFF);
           const r = new Uint8Array(32).fill(0x01);

           expect(wasm.signatureIsCanonical(r, highS)).toBe(false);

           const [normalizedR, normalizedS] = wasm.signatureNormalize(r, highS);
           expect(wasm.signatureIsCanonical(normalizedR, normalizedS)).toBe(true);
       });

       // ... more tests
   });
   ```

2. **Add Signing Function** (Issue #2)

3. **Fix Import Style** (Issue #3)

### High Priority

4. **Clarify V Parameter Documentation** (Issue #5)

5. **Add Signature Verification** (Issue #7)

### Medium Priority

6. **Add EIP-2 Enforcement Option** (Issue #6)

7. **Document Defensive Copying** (Issue #4)

8. **Add Batch Operations**:
   ```typescript
   export function secp256k1RecoverAddressBatch(
       signatures: Array<{
           messageHash: Uint8Array;
           r: Uint8Array;
           s: Uint8Array;
           v: number;
       }>,
   ): Uint8Array[] {
       // Single WASM call for better performance
   }
   ```

### Low Priority

9. **Add Convenience Methods**:
   ```typescript
   /**
    * Recover address from compact signature (65 bytes)
    */
   export function recoverAddressFromCompact(
       messageHash: Uint8Array,
       compactSig: Uint8Array,
   ): Uint8Array {
       const parsed = signatureParse(compactSig);
       return secp256k1RecoverAddress(
           messageHash,
           parsed.r,
           parsed.s,
           parsed.v,
       );
   }
   ```

## Security Considerations

### Critical Issues
- ❌ **NO TESTS**: Crypto code without tests is extremely dangerous
- ❌ **NO SIGNING FUNCTION**: Incomplete implementation
- ⚠️ V parameter range unclear (recovery ID vs Ethereum v)

### Positive
- ✅ Input validation on all functions
- ✅ EIP-2 canonical signature support
- ✅ Signature component validation

### Required Actions
1. CREATE TEST FILE IMMEDIATELY
2. Add known test vectors
3. Cross-validate with standard libraries (ethers, viem)
4. Add signing function if needed

## Overall Assessment

**Grade: D** (Incomplete and Untested)

The code structure is good and input validation is present, but:
1. **No test file for cryptographic code is unacceptable**
2. Missing signing functionality makes it incomplete
3. Cannot validate correctness without tests

**Ready for production use**: ❌ NO - Missing tests and signing
**Requires changes before merge**: ✅ YES - Critical issues must be fixed

### Blocking Issues
1. ❌ No test file - MUST CREATE
2. ❌ No signing function - SHOULD ADD
3. ❌ CommonJS import - MUST FIX

### After Fixes
Once tests are added, signing is implemented, and imports are fixed, this should be reviewed again for production readiness. The underlying WASM implementation is presumably correct, but TypeScript wrapper needs comprehensive validation.

### Risk Assessment
**CRITICAL RISK**: Using cryptographic code without tests is extremely dangerous. This module should not be used in production until comprehensive tests are added.
