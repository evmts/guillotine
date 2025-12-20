# Code Review: secp256k1.zig

**Review Date:** 2025-10-26
**File:** `/Users/williamcory/primitives/src/crypto/secp256k1.zig`
**Lines of Code:** 2566
**Purpose:** Custom secp256k1 elliptic curve cryptography implementation for ECDSA signature recovery

---

## 1. Overview

This file implements a custom secp256k1 elliptic curve cryptography library for Ethereum signature recovery. It provides:

- **Affine point arithmetic** (add, double, scalar multiplication, negation)
- **Signature validation** (EIP-2 malleability protection)
- **Public key recovery** from ECDSA signatures (64-byte uncompressed format)
- **Address recovery** from signatures (20-byte Ethereum address)
- **Modular arithmetic primitives** (mulmod, addmod, submod, powmod, invmod)
- **Comprehensive test suite** (1400+ lines of tests with Bitcoin/Ethereum test vectors)

The implementation is explicitly marked as **UNAUDITED** and contains extensive warnings about its lack of security audit.

---

## 2. Code Quality: 7/10

### Strengths

1. **Excellent Documentation**: Clear warnings about unaudited status throughout
2. **Well-Structured**: Logical organization with clear separation of concerns
3. **Naming Conventions**: Follows Zig style guide correctly (camelCase for functions, snake_case for variables)
4. **Error Handling**: Proper error propagation with descriptive error types
5. **Test Coverage**: Exceptional test coverage (56% of file is tests) with:
   - Bitcoin Core test vectors
   - Ethereum test vectors
   - SEC2 specification vectors
   - Edge case tests for all operations
   - Malleability tests (EIP-2 compliance)
   - Curve property validation tests

### Weaknesses

1. **Memory Safety Concerns**: Uses i512 for intermediate calculations in `unauditedInvmod` which could overflow
2. **Performance**: Naive implementations (e.g., square-and-multiply for scalar multiplication)
3. **Code Duplication**: Significant duplication between `recoverPubkey` and `unauditedRecoverAddress` (lines 148-225 vs 232-302)
4. **Magic Numbers**: Some calculations lack explanatory comments (e.g., line 182: `(SECP256K1_P + 1) >> 2`)
5. **Inconsistent Patterns**: Some functions use optional returns, others use error returns

---

## 3. Completeness: 9/10

### Implemented Features

- **Core ECC Operations**: All essential elliptic curve operations are complete
- **Signature Validation**: Full EIP-2 malleability protection implemented
- **Recovery Functions**: Both public key (64-byte) and address (20-byte) recovery
- **Edge Case Handling**: Comprehensive handling of:
  - Point at infinity
  - Zero values
  - Boundary conditions (r=0, s=0, r=n, s=n, s>n/2)
  - Invalid recovery IDs
  - Invalid input lengths

### Missing/Incomplete

1. **No TODOs Found**: No explicit TODOs or FIXMEs in code
2. **No Stub Implementations**: All functions are fully implemented
3. **Limited Recovery ID Support**: Only supports v=0,1,27,28 (lines 163-170)
   - Does not support EIP-155 chain ID encoding (v=29,30+ for chain-specific signatures)
   - Comment on line 2072 mentions v=29,30 but implementation rejects them
4. **No Batch Operations**: No batch signature recovery optimizations
5. **No Side-Channel Protections**: Acknowledged in warnings but not implemented

---

## 4. Test Coverage: 10/10

### Exceptional Test Quality

The test suite is **outstanding** with 1400+ lines covering:

#### Functional Tests
- Basic operations: point addition, doubling, scalar multiplication (lines 524-573)
- Field arithmetic: mulmod, addmod, submod, powmod, invmod (lines 575-602)
- Signature validation: malleability checks, boundary values (lines 487-509, 920-959)
- Recovery operations: address and public key recovery (lines 458-485, 1585-1633)

#### Edge Case Tests
- Point at infinity operations (lines 999-1044)
- Zero scalar multiplication (lines 1187-1230)
- Invalid signatures: zero/boundary r/s values (lines 712-764, 1046-1092, 1094-1140)
- Hash length validation (lines 1465-1498)
- Recovery ID validation (lines 1142-1185, 1635-1691)
- Invalid input lengths (lines 1693-1725)

#### Test Vectors
- **Bitcoin Core vectors** (lines 608-659, 802-860, 1886-1985)
- **Ethereum JSON-RPC vectors** (lines 661-710, 1986-2045)
- **SEC2 specification vectors** (lines 1816-1884) - official secp256k1 test vectors
  - Verifies 2G, 3G, 4G match specification exactly
  - Validates curve equation and generator properties

#### Property-Based Tests
- Curve arithmetic properties: commutativity, associativity, distributivity (lines 1232-1275, 2356-2424)
- Determinism: multiple recoveries produce identical results (lines 862-887, 1500-1526, 1727-1761, 2292-2355)
- Negation and cancellation: P + (-P) = O (lines 1385-1422, 1528-1546)

#### Consensus-Critical Tests
- Signature malleability (EIP-2 compliance) (lines 1763-1810, 2266-2290)
- Cross-validation tests (lines 2046-2087, 2088-2265)
- Modular arithmetic correctness (lines 2426-2491)

### Test Coverage Assessment

**Estimated Coverage: 95%+**

The only untested paths are likely:
- Rare error conditions in point arithmetic (division by zero in slope calculations)
- Some branches in modular arithmetic for edge values

---

## 5. Security Issues: CRITICAL

### 1. **NOT CONSTANT-TIME (CRITICAL)**

**Severity:** CRITICAL - Enables timing attacks
**Location:** All modular arithmetic functions (lines 338-452)

All cryptographic operations are **vulnerable to timing attacks**:

```zig
// Lines 351-362: unauditedMulmod
while (multiplier > 0) {  // ❌ Variable-time loop
    if (multiplier & 1 == 1) {  // ❌ Branches on secret data
        result = unauditedAddmod(result, multiplicand, m);
    }
    multiplicand = unauditedAddmod(multiplicand, multiplicand, m);
    multiplier >>= 1;
}
```

**Impact:**
- Attackers can extract private keys by measuring operation timing
- Scalar multiplication timing leaks scalar value (private key material)
- All signature operations are vulnerable

**Mitigation Required:**
- Implement constant-time Montgomery multiplication
- Use constant-time point addition formulas (e.g., Jacobian coordinates with unified addition)
- Eliminate all data-dependent branches in crypto code

### 2. **NO SECURE MEMORY HANDLING (HIGH)**

**Severity:** HIGH - Memory disclosure attacks
**Location:** Throughout, especially lines 195-225, 289-301

Sensitive data (private key material, intermediate values) is not zeroed:

```zig
// Line 195: hash_array left in memory
var hash_array: [32]u8 = undefined;
@memcpy(&hash_array, hash);
const e = std.mem.readInt(u256, &hash_array, .big);
// ❌ hash_array never zeroed before return
```

**Impact:**
- Private keys may persist in memory
- Memory disclosure vulnerabilities can leak keys
- Heap/stack dumps reveal sensitive data

**Mitigation Required:**
- Use `crypto.secureZero()` or equivalent
- Clear all sensitive buffers before function return
- Use `defer` for automatic cleanup

### 3. **MALLEABLE v PARAMETER HANDLING (MEDIUM)**

**Severity:** MEDIUM - Transaction malleability
**Location:** Lines 163-170

The v parameter handling accepts both raw recoveryId (0,1) and Ethereum format (27,28) without clear documentation:

```zig
var recoveryId: u8 = undefined;
if (v >= 27 and v <= 28) {
    recoveryId = v - 27;
} else if (v <= 1) {
    recoveryId = v;
} else {
    return error.InvalidRecoveryId;
}
```

**Issues:**
- v=0 and v=27 both map to recoveryId=0 (different representations)
- v=1 and v=28 both map to recoveryId=1
- Creates signature malleability through v value variations
- Does not support EIP-155 chain ID encoding

**Impact:**
- Two different v values produce same result
- Transaction hash malleability (different serializations, same signature)
- Replay attacks across chains (no EIP-155 support)

### 4. **INCOMPLETE SIGNATURE VERIFICATION (MEDIUM)**

**Severity:** MEDIUM - May accept invalid signatures
**Location:** Lines 305-331

The `verifySignature` function only validates the signature **after** recovery, not before:

```zig
// Line 217: Verification only happens AFTER expensive recovery
if (!verifySignature(hash_array, r_u256, s_u256, Q)) return error.InvalidSignature;
```

**Issues:**
- Expensive point arithmetic performed before validation
- DoS vulnerability: attackers can force expensive operations with invalid signatures
- Should validate r,s ranges before recovery

**Impact:**
- CPU exhaustion attacks
- Wasted computation on invalid signatures

### 5. **INTEGER OVERFLOW IN INVMOD (MEDIUM)**

**Severity:** MEDIUM - Incorrect results or crashes
**Location:** Lines 422-452

Uses i512 for intermediate calculations but doesn't check for overflow:

```zig
// Lines 440, 448: Potential overflow
s = old_s - @as(i512, @intCast(quotient)) * s;  // ❌ No overflow check
old_s += @as(i512, @intCast(m));  // ❌ No overflow check
```

**Impact:**
- Incorrect modular inverse calculation
- Silent failures leading to invalid signatures
- Potential crashes if overflow occurs

### 6. **NO INPUT VALIDATION IN POINT ARITHMETIC (LOW)**

**Severity:** LOW - May produce incorrect results
**Location:** Lines 30-124 (AffinePoint methods)

Point arithmetic methods don't validate that points are on the curve before operations:

```zig
pub fn add(self: Self, other: Self) Self {
    // ❌ No validation that self.isOnCurve() or other.isOnCurve()
    if (self.infinity) return other;
    if (other.infinity) return self;
    // ... proceeds with arithmetic
}
```

**Impact:**
- Operating on invalid points produces undefined results
- May enable curve twist attacks
- Violates cryptographic assumptions

---

## 6. Issues Found

### Critical Issues

1. **All operations are timing-vulnerable** (Lines 338-452)
   - No constant-time implementations
   - Branches leak secret data
   - Variable-time loops expose key material

2. **No memory zeroing** (Throughout)
   - Sensitive data persists in memory
   - Memory disclosure leaks keys

### High-Priority Issues

3. **Code duplication** (Lines 148-225 vs 232-302)
   - ~70 lines duplicated between `recoverPubkey` and `unauditedRecoverAddress`
   - Maintenance burden and inconsistency risk

4. **Missing EIP-155 support** (Lines 163-170)
   - Cannot handle chain-specific v values
   - Replay attack vulnerability

5. **Performance inefficiency** (Lines 108-123)
   - Naive double-and-add scalar multiplication
   - No windowing or precomputation
   - ~256 point additions/doublings per scalar mul

### Medium-Priority Issues

6. **Unsafe type conversion** (Lines 440, 448, 451)
   - `@intCast` without overflow validation
   - May panic or produce incorrect results

7. **Inconsistent error handling** (Line 68 vs others)
   - `unauditedInvmod` returns `?u256` (optional)
   - Other functions return errors
   - Should standardize on error returns

8. **Magic number** (Line 182)
   - `(SECP256K1_P + 1) >> 2` lacks explanation
   - Should document: "Tonelli-Shanks square root for p ≡ 3 mod 4"

### Low-Priority Issues

9. **Redundant curve checks** (Lines 192, 261)
   - `isOnCurve()` called after construction from validated r
   - Already validated by y² = x³ + 7 check on line 185/254

10. **Incomplete documentation** (Line 148)
    - `recoverPubkey` doesn't document v parameter variations
    - Should clarify v=0,1 (raw) vs v=27,28 (Ethereum) handling

---

## 7. Recommendations

### Immediate Actions (Before Production Use)

1. **MUST: Security Audit**
   - Engage professional cryptography auditor
   - Focus on timing attacks and side-channel resistance
   - Validate against known attack vectors

2. **MUST: Implement Constant-Time Operations**
   ```zig
   // Replace with Montgomery arithmetic
   fn constantTimeMulmod(a: u256, b: u256, m: u256) u256 {
       // Use Montgomery multiplication
       // No branches on secret data
       // Fixed number of operations
   }
   ```

3. **MUST: Add Memory Zeroing**
   ```zig
   pub fn recoverPubkey(...) ![64]u8 {
       var hash_array: [32]u8 = undefined;
       defer crypto.utils.secureZero(u8, &hash_array);
       // ... rest of function
   }
   ```

4. **MUST: Standardize v Parameter Handling**
   ```zig
   // Define clear semantics:
   // - Accept ONLY v=27,28 for Ethereum (non-EIP-155)
   // - Accept v >= 35 for EIP-155 (v = 35 + 2*chainId + recoveryId)
   // - Reject v=0,1 (ambiguous with raw recoveryId)
   ```

### High-Priority Improvements

5. **Eliminate Code Duplication**
   - Extract common recovery logic into shared function
   - Make `unauditedRecoverAddress` call `recoverPubkey` internally

6. **Add EIP-155 Support**
   ```zig
   fn parseRecoveryId(v: u64) !struct { recoveryId: u8, chainId: ?u64 } {
       if (v == 27 or v == 28) {
           return .{ .recoveryId = @intCast(v - 27), .chainId = null };
       } else if (v >= 35) {
           const chain_id = (v - 35) / 2;
           const recovery_id = (v - 35) % 2;
           return .{ .recoveryId = @intCast(recovery_id), .chainId = chain_id };
       }
       return error.InvalidV;
   }
   ```

7. **Optimize Scalar Multiplication**
   - Implement windowed non-adjacent form (wNAF)
   - Or use projective/Jacobian coordinates for 20-30% speedup
   - Precompute small multiples of generator

### Medium-Priority Improvements

8. **Add Input Validation**
   ```zig
   pub fn add(self: Self, other: Self) Self {
       std.debug.assert(self.isOnCurve());  // Debug builds only
       std.debug.assert(other.isOnCurve());
       // ... rest of function
   }
   ```

9. **Improve Error Types**
   - Add `error.TimingAttackVulnerable` to remind callers
   - Add `error.ChainIdMismatch` for EIP-155
   - Make `unauditedInvmod` return `error.NotInvertible` instead of null

10. **Add Performance Benchmarks**
    - Benchmark against libsecp256k1
    - Track performance regressions
    - Document expected performance characteristics

### Documentation Improvements

11. **Add Safety Warnings to Public API**
    ```zig
    /// ⚠️ SECURITY WARNING ⚠️
    /// This function is NOT constant-time and WILL leak timing information.
    /// DO NOT use with secret key material.
    /// Only safe for signature recovery (public operations).
    pub fn recoverPubkey(...) ![64]u8 { ... }
    ```

12. **Document Cryptographic Assumptions**
    - Explain why timing attacks are acceptable for recovery
    - Document that recovery uses only public data
    - Clarify security boundary

13. **Add Usage Examples**
    ```zig
    /// Example:
    /// ```zig
    /// const hash = keccak256("message");
    /// const r = signature[0..32];
    /// const s = signature[32..64];
    /// const v = signature[64];
    /// const pubkey = try recoverPubkey(&hash, r, s, v);
    /// ```
    ```

---

## 8. Comparison to Standards

### Bitcoin Core (libsecp256k1)
- **This implementation:** ~450 LOC core + 1400 LOC tests
- **libsecp256k1:** ~15,000 LOC with extensive optimizations
- **Gap:** No constant-time guarantees, ~10-100x slower

### Ethereum (go-ethereum)
- Uses libsecp256k1 via C bindings
- Full EIP-155 support
- Battle-tested in production

### Recommendations
Consider using existing audited libraries:
- Link against libsecp256k1 via C FFI
- Or use Zig's std.crypto if/when secp256k1 added
- Custom implementation only if performance/dependencies justify risk

---

## 9. Test Quality Assessment

### Coverage Analysis

**Strong Coverage:**
- All public functions tested ✓
- Edge cases comprehensively covered ✓
- Consensus-critical validation (EIP-2) ✓
- Cross-validation with standard test vectors ✓
- Property-based testing of curve arithmetic ✓

**Missing Coverage:**
- Timing attack resistance (by design - not constant-time)
- Memory safety under adversarial conditions
- Concurrent access patterns
- Large-scale fuzzing results

### Test Strengths

1. **Real-World Vectors**: Uses actual Bitcoin/Ethereum test data
2. **Specification Compliance**: SEC2 vectors validate correctness
3. **Determinism Tests**: Verifies no randomness in recovery
4. **Boundary Testing**: Exhaustive testing of r,s,v boundaries

### Test Weaknesses

1. **No Negative Security Tests**: Should test that timing attacks ARE possible (to document limitation)
2. **No Performance Tests**: Should validate O(n) complexity
3. **No Memory Leak Tests**: Should verify cleanup
4. **No Fuzzing Evidence**: No corpus or fuzzing harness

---

## 10. Summary

### Overall Assessment: 7/10

**Strengths:**
- Excellent test coverage (10/10)
- Complete implementation (9/10)
- Clear documentation of limitations
- Good code structure and organization

**Critical Weaknesses:**
- NOT constant-time (timing attacks possible)
- No memory security
- Performance significantly slower than production libraries

### Production Readiness: NOT READY

**Blockers for Production:**
1. Security audit required
2. Constant-time implementation needed
3. Memory zeroing required
4. EIP-155 support needed

### Recommendation

**For Testing/Development:** Acceptable with caveats
- Clear warnings present
- Good for understanding algorithm
- Useful for non-production prototypes

**For Production:** Use libsecp256k1 instead
- This implementation lacks critical security features
- Performance gap is significant
- Audit cost exceeds maintenance savings

**If Production Use is Required:**
1. Must complete all "Immediate Actions"
2. Must undergo professional security audit
3. Must implement constant-time operations
4. Must add comprehensive fuzzing
5. Budget 2-3 months for hardening + audit

### Final Score Breakdown

- **Code Quality:** 7/10 (good structure, needs security hardening)
- **Completeness:** 9/10 (missing only EIP-155)
- **Test Coverage:** 10/10 (exceptional)
- **Security:** 2/10 (critical vulnerabilities present)
- **Performance:** 4/10 (correct but slow)

**Overall:** 7/10 (Good implementation for understanding/testing, NOT production-ready)
