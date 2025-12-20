# Code Review: utils.ts

## Overview
Utility functions for signer operations. Provides helper functions for working with Signer instances.

## Code Quality

**Grade: D** (Minimal stub file)

### Strengths
- **Clean type imports**: Uses proper TypeScript types
- **Simple API**: Functions are straightforward

### Weaknesses
- **Mostly stubs**: Only 1 of 2 functions is implemented
- **Trivial implementation**: Working function just returns a field
- **No test file**: Missing validation
- **Minimal functionality**: Only 23 lines with one stub

## Completeness

### Complete Features
- ✅ `getAddress()` - Returns signer address

### Stub Features
- ❌ `recoverTransactionAddress()` - Throws "not yet implemented" (line 11-21)

### TODOs/Stubs
- ⚠️ Line 11-21: `recoverTransactionAddress()` is a stub
- ✅ Comment explains what's needed for implementation

## Test Coverage

Test file: **MISSING** ❌

### Critical Issue
No test file exists, even for the trivial implemented function.

## Issues Found

### 1. Trivial Implemented Function
**Location**: Lines 7-9
```typescript
export function getAddress(signer: Signer): string {
    return signer.address;
}
```
**Issue**: This function is completely unnecessary - just a field access
**Impact**: Adds no value, increases API surface area
**Recommendation**: REMOVE this function. Users can access `signer.address` directly.

**Analysis**: This might exist for interface compatibility with libraries like ethers.js which have `getAddress()` methods, but it's redundant here.

### 2. CRITICAL: Stub Implementation
**Location**: Lines 11-21
```typescript
export async function recoverTransactionAddress(_transaction: any): Promise<string> {
    // Note: Transaction address recovery requires:
    // 1. Deserialize transaction from RLP
    // 2. Extract signature (r, s, v)
    // 3. Reconstruct transaction hash
    // 4. Recover address from signature and hash using secp256k1RecoverAddress
    //
    // This requires additional WASM bindings
    throw new Error(
        "recoverTransactionAddress not yet implemented. Requires RLP deserialization and signature recovery bindings",
    );
}
```
**Issue**: Function exists but throws error
**Impact**: Cannot recover signer from transactions
**Recommendation**: Either implement or remove:

```typescript
import { decodeTransaction } from "../../primitives/transaction.wasm.js";
import { secp256k1RecoverAddress } from "../../primitives/signature.wasm.js";
import { Hash } from "../../primitives/keccak.wasm.js";
import { Address } from "../../primitives/address.wasm.js";

export async function recoverTransactionAddress(
    transaction: SignedTransaction | Uint8Array,
): Promise<string> {
    let tx: SignedTransaction;

    // Decode if bytes provided
    if (transaction instanceof Uint8Array) {
        tx = decodeTransaction(transaction);
    } else {
        tx = transaction;
    }

    // Reconstruct unsigned transaction hash
    const unsignedRlp = encodeUnsignedTransaction(tx);
    const txHash = Hash.keccak256(unsignedRlp);

    // Recover address from signature
    const recoveredAddress = secp256k1RecoverAddress(
        txHash.toBytes(),
        tx.r,
        tx.s,
        tx.v - 27, // Convert Ethereum v to recovery ID
    );

    return Address.fromBytes(recoveredAddress).toChecksumHex();
}
```

**Requires**:
- Transaction RLP encoding/decoding
- Proper transaction types

### 3. No Test File
**Issue**: Even trivial utilities need tests
**Recommendation**: CREATE test file:
```typescript
// utils.test.ts
import { test, expect, describe } from "bun:test";
import { getAddress } from "./utils";
import { PrivateKeySignerImpl } from "./private-key-signer";

describe("Signer utils", () => {
    test("getAddress returns signer address", () => {
        const signer = PrivateKeySignerImpl.fromPrivateKey({
            privateKey: "0x" + "1".repeat(64),
        });

        const address = getAddress(signer);
        expect(address).toBe(signer.address);
    });

    // TODO: Add transaction recovery tests once implemented
    test.skip("recoverTransactionAddress", async () => {
        // Will need signed transaction test vector
    });
});
```

### 4. Inconsistent Function Purpose
**Issue**: File mixes two unrelated utilities
- `getAddress`: Works with Signer interface
- `recoverTransactionAddress`: Works with transactions (not Signer)

**Recommendation**: Either:
1. Move `recoverTransactionAddress` to transaction utilities
2. Rename file to be more general
3. Add more signer-specific utilities

### 5. Missing Useful Utilities
**Issue**: File claims to be utils but has minimal functionality
**Recommendation**: Add actually useful utilities:

```typescript
/**
 * Check if an object implements the Signer interface
 */
export function isSigner(obj: any): obj is Signer {
    return (
        obj &&
        typeof obj.address === "string" &&
        typeof obj.signMessage === "function" &&
        typeof obj.signTransaction === "function" &&
        typeof obj.signTypedData === "function"
    );
}

/**
 * Verify that a signature was created by this signer
 */
export async function verifySignature(
    signer: Signer,
    message: string | Uint8Array,
    signature: string,
): Promise<boolean> {
    const messageHash = eip191HashMessage(message);
    const parsed = signatureParse(hexToBytes(signature));

    const recoveredAddress = secp256k1RecoverAddress(
        messageHash.toBytes(),
        parsed.r,
        parsed.s,
        parsed.v,
    );

    const recovered = Address.fromBytes(recoveredAddress).toChecksumHex();
    return recovered.toLowerCase() === signer.address.toLowerCase();
}

/**
 * Sign multiple messages in batch
 */
export async function signMessageBatch(
    signer: Signer,
    messages: Array<string | Uint8Array>,
): Promise<string[]> {
    return Promise.all(messages.map((msg) => signer.signMessage(msg)));
}

/**
 * Verify message signature without signer instance
 */
export function recoverMessageSigner(
    message: string | Uint8Array,
    signature: string,
): string {
    const messageHash = eip191HashMessage(message);
    const parsed = signatureParse(hexToBytes(signature));

    const recoveredAddress = secp256k1RecoverAddress(
        messageHash.toBytes(),
        parsed.r,
        parsed.s,
        parsed.v,
    );

    return Address.fromBytes(recoveredAddress).toChecksumHex();
}
```

## Memory Management Analysis

No memory management concerns - simple utility functions.

## Recommendations

### Critical Priority (MUST FIX)

1. **Remove `getAddress()` function** (Issue #1):
   It adds no value - users can access `signer.address` directly

2. **Complete or Remove `recoverTransactionAddress()`** (Issue #2)

3. **Create Test File** (Issue #3)

### High Priority

4. **Add Useful Utilities** (Issue #5):
   - Signature verification
   - Signer type guard
   - Message signer recovery

5. **Reorganize File** (Issue #4):
   Move transaction recovery to transaction utils

### Medium Priority

6. **Add JSDoc Examples**:
   ```typescript
   /**
    * Verify that a signature was created by this signer
    *
    * @example
    * const signature = await signer.signMessage("Hello");
    * const isValid = await verifySignature(signer, "Hello", signature);
    * // isValid === true
    */
   ```

## Overall Assessment

**Grade: D** (Minimal and Mostly Stubs)

This file contains one trivial function (unnecessary field access) and one stub. It provides almost no actual utility.

**Ready for production use**: ❌ NO - Mostly stubs
**Requires changes before merge**: ✅ YES - Needs major work

### Blocking Issues
1. ❌ One function is stub - COMPLETE or REMOVE
2. ❌ Other function is trivial - REMOVE
3. ❌ No tests - MUST CREATE

### Current State
This file should either be:
1. Removed entirely (if no useful utilities to add)
2. Expanded significantly with actual utility functions
3. Renamed and reorganized to better reflect its purpose

Currently it's dead weight - 23 lines with no real functionality.

### Recommendation
**Remove this file** unless planning to add substantial utilities. The `getAddress()` function should be removed (users can access `signer.address`), and `recoverTransactionAddress()` should be moved to transaction utilities once implemented.

If keeping the file, add the useful utilities suggested in Issue #5.
