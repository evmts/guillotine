# Code Review: wallet.wasm.ts

## Overview
WASM wrapper for cryptographic key generation and manipulation. Provides functions for generating private keys and compressing public keys for secp256k1 (Ethereum's elliptic curve).

## Code Quality

**Grade: C+** (Basic but needs work)

### Strengths
- **Simple API**: Two focused functions
- **Input validation**: Checks public key length
- **Documentation**: JSDoc present for both functions

### Weaknesses
- **CommonJS import**: Uses `require()` instead of ES6 import (line 6)
- **No test file**: Missing validation (CRITICAL for crypto)
- **Limited functionality**: Only 2 functions, no wallet operations
- **Misleading name**: "wallet" suggests more functionality than provided

## Completeness

### Complete Features
- ✅ Private key generation
- ✅ Public key compression

### Missing Features (Most Wallet Functionality)
- ❌ Wallet creation from mnemonic
- ❌ HD wallet derivation (BIP32/BIP44)
- ❌ Address derivation from private key
- ❌ Private key validation
- ❌ Public key decompression
- ❌ Key serialization (WIF, etc.)
- ❌ Keystore encryption/decryption

### TODOs/Stubs
- ✅ No TODOs found
- ❌ **No test file exists**
- ⚠️ Module name suggests wallet functionality but provides only key utilities

## Test Coverage

Test file: **MISSING** ❌

### Critical Issue
No test file for cryptographic key operations - UNACCEPTABLE.

### Required Tests
- Private key generation produces 32 bytes
- Generated keys are valid secp256k1 keys
- Key generation is cryptographically random
- Public key compression correctness
- Roundtrip compression/decompression
- Error handling for invalid public keys
- Parity with native implementation

## Issues Found

### 1. CRITICAL: No Test File
**Issue**: Cryptographic key generation without tests
**Impact**: Bad key generation could lead to loss of funds
**Recommendation**: CREATE IMMEDIATELY:
```typescript
// wallet.wasm.test.ts
import { test, expect, describe } from "bun:test";
import { generatePrivateKey, compressPublicKey } from "./wallet.wasm";
import { secp256k1PubkeyFromPrivate } from "./signature.wasm";

describe("WASM Wallet key generation", () => {
    test("generates valid 32-byte private key", () => {
        const privateKey = generatePrivateKey();

        expect(privateKey).toBeInstanceOf(Uint8Array);
        expect(privateKey.length).toBe(32);
    });

    test("generates unique keys", () => {
        const keys = new Set();
        for (let i = 0; i < 100; i++) {
            const key = generatePrivateKey();
            const hex = Buffer.from(key).toString("hex");
            keys.add(hex);
        }

        // All keys should be unique
        expect(keys.size).toBe(100);
    });

    test("generated keys are valid", () => {
        const privateKey = generatePrivateKey();

        // Should be able to derive public key
        expect(() => {
            secp256k1PubkeyFromPrivate(privateKey);
        }).not.toThrow();
    });

    test("compresses 64-byte public key to 33 bytes", () => {
        const privateKey = generatePrivateKey();
        const uncompressed = secp256k1PubkeyFromPrivate(privateKey);

        expect(uncompressed.length).toBe(64);

        const compressed = compressPublicKey(uncompressed);

        expect(compressed.length).toBe(33);
        expect([0x02, 0x03]).toContain(compressed[0]);
    });

    test("rejects invalid public key length", () => {
        const invalid = new Uint8Array(32); // Wrong length
        expect(() => compressPublicKey(invalid)).toThrow("64 bytes");
    });
});
```

### 2. Module Naming Misleads Users
**Issue**: Named "wallet" but only provides key utilities
**Impact**: Users expect full wallet functionality
**Recommendation**: Either:
- Rename to `key-utils.wasm.ts` or `key-generation.wasm.ts`
- OR expand to include full wallet functionality

### 3. CommonJS Import
**Location**: Line 6
```typescript
const primitives = require('../../../wasm/loader.js');
```
**Issue**: Inconsistent with rest of codebase
**Recommendation**: Use ES6 import:
```typescript
import * as primitives from '../../../wasm/loader.js';
```

### 4. No Entropy Source Documentation
**Location**: Lines 8-13
```typescript
/**
 * Generate a cryptographically secure random private key
 * @returns 32-byte private key
 */
export function generatePrivateKey(): Uint8Array {
    return primitives.generatePrivateKey();
}
```
**Issue**: Doesn't document entropy source
**Impact**: Users don't know if it's cryptographically secure
**Recommendation**: Document entropy:
```typescript
/**
 * Generate a cryptographically secure random private key
 *
 * Uses cryptographically secure random number generator (CSPRNG)
 * provided by the platform (Web Crypto API in browsers, /dev/urandom in Node.js)
 *
 * @returns 32-byte private key suitable for secp256k1
 *
 * @example
 * const privateKey = generatePrivateKey();
 * const publicKey = secp256k1PubkeyFromPrivate(privateKey);
 */
```

### 5. No Private Key Validation
**Issue**: Can generate keys but can't validate them
**Recommendation**: Add validation:
```typescript
/**
 * Validate that a private key is valid for secp256k1
 * @param privateKey - 32-byte private key
 * @returns true if valid
 */
export function isValidPrivateKey(privateKey: Uint8Array): boolean {
    if (privateKey.length !== 32) {
        return false;
    }

    // Private key must be in range [1, n-1] where n is curve order
    const keyBigInt = Buffer.from(privateKey).readBigUInt64BE();

    // secp256k1 curve order (simplified check)
    return keyBigInt > 0n && keyBigInt < 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141n;
}
```

### 6. Missing Public Key Decompression
**Issue**: Can compress but not decompress
**Impact**: Can't work with compressed keys from other sources
**Recommendation**: Add decompression:
```typescript
/**
 * Decompress compressed secp256k1 public key
 * @param compressed - 33-byte compressed public key (0x02/0x03 prefix + x coordinate)
 * @returns 64-byte uncompressed public key (x, y coordinates)
 */
export function decompressPublicKey(compressed: Uint8Array): Uint8Array {
    if (compressed.length !== 33) {
        throw new Error("Compressed public key must be 33 bytes");
    }
    if (compressed[0] !== 0x02 && compressed[0] !== 0x03) {
        throw new Error("Invalid compressed public key prefix (must be 0x02 or 0x03)");
    }

    return primitives.decompressPublicKey(compressed);
}
```

### 7. No HD Wallet Support
**Issue**: Modern wallets use HD derivation (BIP32/BIP44) but not supported
**Impact**: Cannot create hierarchical wallets
**Recommendation**: Add HD wallet support:
```typescript
/**
 * Derive child key from parent using BIP32
 * @param parentKey - Parent private key
 * @param index - Child index
 * @param hardened - Whether to use hardened derivation
 * @returns Child private key
 */
export function deriveChildKey(
    parentKey: Uint8Array,
    index: number,
    hardened: boolean = false,
): Uint8Array {
    if (parentKey.length !== 32) {
        throw new Error("Parent key must be 32 bytes");
    }

    const actualIndex = hardened ? index + 0x80000000 : index;
    return primitives.deriveChildKey(parentKey, actualIndex);
}

/**
 * Derive key from mnemonic phrase using BIP39/BIP44
 * @param mnemonic - 12 or 24 word mnemonic phrase
 * @param path - Derivation path (e.g., "m/44'/60'/0'/0/0")
 * @returns Private key
 */
export function fromMnemonic(mnemonic: string, path: string): Uint8Array {
    return primitives.fromMnemonic(mnemonic, path);
}
```

## Memory Management Analysis

### WASM Binding Pattern
- WASM generates and returns new arrays
- No explicit cleanup needed

### Security Concern
- ⚠️ Private keys in memory - should be zeroized after use
- No secure cleanup mechanism provided

### Recommendation
Add secure memory clearing:
```typescript
/**
 * Securely clear private key from memory
 * @param privateKey - Private key to clear
 */
export function clearPrivateKey(privateKey: Uint8Array): void {
    // Overwrite with zeros
    privateKey.fill(0);

    // Additional security: overwrite multiple times
    for (let i = 0; i < 3; i++) {
        privateKey.fill(Math.floor(Math.random() * 256));
    }
    privateKey.fill(0);
}
```

## Recommendations

### Critical Priority (MUST FIX)

1. **Create Test File** (Issue #1) - IMMEDIATELY

2. **Fix Import Style** (Issue #3)

3. **Rename Module** (Issue #2):
   Either rename to `key-utils.wasm.ts` or expand functionality

### High Priority

4. **Document Entropy Source** (Issue #4)

5. **Add Private Key Validation** (Issue #5)

6. **Add Public Key Decompression** (Issue #6)

7. **Add Secure Memory Clearing**

### Medium Priority

8. **Add HD Wallet Support** (Issue #7)

9. **Add Key Serialization**:
   ```typescript
   /**
    * Export private key to hex string
    * WARNING: Only for testing, never expose in production
    */
   export function privateKeyToHex(privateKey: Uint8Array): string {
       return "0x" + Buffer.from(privateKey).toString("hex");
   }

   /**
    * Import private key from hex string
    */
   export function privateKeyFromHex(hex: string): Uint8Array {
       const cleaned = hex.startsWith("0x") ? hex.slice(2) : hex;
       if (cleaned.length !== 64) {
           throw new Error("Private key hex must be 64 characters");
       }
       return Uint8Array.from(Buffer.from(cleaned, "hex"));
   }
   ```

### Low Priority

10. **Add Keystore Support** (encrypted JSON wallet format):
    ```typescript
    export interface Keystore {
        version: number;
        id: string;
        address: string;
        crypto: {
            cipher: string;
            ciphertext: string;
            cipherparams: { iv: string };
            kdf: string;
            kdfparams: any;
            mac: string;
        };
    }

    export function encryptKeystore(
        privateKey: Uint8Array,
        password: string,
    ): Keystore;

    export function decryptKeystore(
        keystore: Keystore,
        password: string,
    ): Uint8Array;
    ```

## Overall Assessment

**Grade: D+** (Severely Incomplete)

This module provides only 2 basic functions and is misnamed. A "wallet" module should provide comprehensive wallet functionality including HD derivation, mnemonic support, and key management.

**Ready for production use**: ❌ NO - Missing tests and core functionality
**Requires changes before merge**: ✅ YES - Critical issues

### Blocking Issues
1. ❌ No test file for crypto code - MUST CREATE
2. ❌ CommonJS import - MUST FIX
3. ⚠️ Misleading name - SHOULD RENAME or EXPAND

### Current State
This is essentially a stub providing only the most basic key operations. The name "wallet" is misleading and suggests much more functionality than is present.

### Recommendations
Either:
1. **Rename** to `key-utils.wasm.ts` and document as low-level utilities
2. **Expand** significantly to include:
   - HD wallet derivation (BIP32/BIP44)
   - Mnemonic support (BIP39)
   - Key validation
   - Secure key storage
   - Keystore encryption

### Security Concerns
- No tests for cryptographic operations
- No secure memory clearing
- No key validation
- No documentation of entropy source

This module should not be used in production until these issues are addressed.
