# BLS12-381 Map Fp2 to G2 Precompile Review

## Overview
Implements EIP-2537 0x13: BLS12_MAP_FP2_TO_G2 precompile for mapping an Fp2 element (quadratic extension field) to a point on the BLS12-381 G2 curve. Takes a 128-byte Fp2 element (c0=64 bytes, c1=64 bytes) and returns a 256-byte G2 point. Uses hash-to-curve algorithm for G2.

## Code Quality

### Strengths
- Clean implementation
- Proper input validation (exactly 128 bytes)
- Good memory management
- Consistent with other BLS precompiles

### Issues
- **CRITICAL**: Line 24 swallows error details with `catch { return error.InvalidPoint; }`
- No documentation about hash-to-curve for G2
- No explanation of Fp2 representation (c0, c1 ordering)

## Completeness

### Implementation Status
**COMPLETE** - No TODOs, stubs, or placeholders.

### Features
- Input length validation (exactly 128 bytes)
- Gas limit checking (75000 gas)
- Proper output allocation (256 bytes)
- Error handling for invalid field elements

## Test Coverage

### Test Quality: FAIR

#### Test Categories
1. **Gas validation tests** (3 tests)
   - Out of gas (correct)
   - Exact gas (uses error-accepting pattern)
   - Excess gas (uses error-accepting pattern)

2. **Input validation tests** (3 tests)
   - Too short (127 bytes)
   - Too long (129 bytes)
   - Empty input

3. **Fp2 element tests** (8 tests)
   - Zero Fp2 element (c0=0, c1=0) (uses error-accepting pattern)
   - Maximum c0, zero c1 (uses error-accepting pattern)
   - Zero c0, maximum c1 (uses error-accepting pattern)
   - Both components maximum (uses error-accepting pattern)
   - Test vector 1: c0=1, c1=0 (uses error-accepting pattern)
   - Test vector 2: c0=0, c1=1 (uses error-accepting pattern)
   - Test vector 3: arbitrary values (uses error-accepting pattern)
   - All include p-1 (field modulus minus 1) constants

4. **Validation tests** (2 tests)
   - Gas cost constant (correct: 75000)
   - Output size (uses error-accepting pattern)

#### Test Quality Issues
- Lines 44-56, 59-71, 92-104, 106-134, 136-163, 165-191, 193-210, 212-229, 231-256, 263-274 all use error-accepting pattern
- Tests have comments like "Currently returns error.InvalidPoint due to stub implementation"
- Tests include hardcoded BLS12-381 field modulus (p-1) but don't verify outputs
- No verification that outputs are on G2 curve
- Missing EIP-2537 test vectors

#### Missing Tests
- ❌ No verification of deterministic mapping
- ❌ No test that same input always gives same output
- ❌ No test that output is valid G2 point
- ❌ No test with invalid Fp2 elements (c0 or c1 > p)
- ❌ No test with Fp2 at field boundary (c0=p or c1=p)
- ❌ No EIP-2537 hash-to-curve G2 test vectors

#### Coverage Assessment
- Edge cases: **FAIR** (tests boundaries but doesn't verify)
- Normal operations: **POOR**
- Error conditions: **MINIMAL**
- Real test vectors: **MISSING**

## Gas Calculation

### Specification Compliance
- Gas cost: **75000** (line 7)
- Matches EIP-2537 specification: ✅ CORRECT
- Constant gas (correct for hash-to-curve G2)
- More expensive than map_fp_to_g1 (5500) which is correct (G2 is more complex)
- Ratio: 75000/5500 ≈ 13.6x (reasonable for G2 vs G1)

### Implementation
- Pre-execution gas check (line 15-17)
- Returns exact gas used (line 30)

## Issues Found

### Critical Issues
1. **Error swallowing** (line 24): `crypto.Crypto.bls12_381.mapFp2ToG2(input, output) catch { return error.InvalidPoint; }`

2. **Unclear implementation status**:
   - Tests have comments saying "stub implementation"
   - All substantive tests use error-accepting pattern
   - Not clear if crypto.mapFp2ToG2 is actually implemented

3. **No correctness verification**: Cannot determine if hash-to-curve G2 works
   - Tests don't check outputs
   - No verification of G2 curve membership
   - No verification of algorithm correctness

### High Issues
4. **No EIP-2537 test vectors**: Missing official hash-to-curve G2 test cases

5. **No documentation**: No explanation of:
   - Which hash-to-curve variant is used
   - Fp2 representation format (c0 first or c1 first?)
   - Field modulus p
   - Ordering of Fp2 components in output
   - G2 point representation

6. **Fp2 field modulus** (multiple tests):
   - Tests include hardcoded p-1 = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab
   - Good: Uses actual BLS12-381 modulus
   - Bad: Not extracted to constant or documented
   - Duplicated across multiple tests (lines 113-120, 143-150, 170-177)

### Medium Issues
7. **Test quality**: All substantive tests accept failures via error-accepting pattern

8. **No invalid Fp2 tests**: Should test:
   - c0 > p-1
   - c1 > p-1
   - Both c0 and c1 > p-1
   - c0 = p (should error)
   - c1 = p (should error)

9. **Magic number duplication**: Field modulus p-1 duplicated 3+ times in tests

### Security Concerns
- Hash-to-curve algorithm not documented
- Cannot verify constant-time implementation
- Cannot verify uniform distribution of outputs on G2
- Fp2 ordering not documented (could affect security)
- **Implementation is UNVERIFIED**

### Code Smells
- Test comments mention "stub implementation" repeatedly
- Error-accepting patterns in all tests
- Tests were written but never validated with real outputs
- Duplicated field modulus constants

## Recommendations

### Critical Priority
1. **VERIFY IMPLEMENTATION STATUS**
   - Determine if crypto.mapFp2ToG2 is actually implemented
   - If not implemented, mark as stub clearly
   - If implemented, add tests that verify it works

2. **ADD CORRECTNESS TESTS**
   - Test that outputs are valid G2 points
   - Test deterministic property (same input → same output)
   - Verify outputs are on G2 curve
   - Test with known G2 hash-to-curve test vectors

3. **Fix error handling** - Stop swallowing errors

### High Priority
4. **Add EIP-2537 test vectors** - Official hash-to-curve G2 test cases from:
   - draft-irtf-cfrg-hash-to-curve (G2 suite)
   - EIP-2537 specification

5. **Add documentation**:
   - Document hash-to-curve variant for G2
   - Explain Fp2 input format (c0 vs c1 ordering, big-endian?)
   - Document field modulus p
   - Explain G2 output format (Fp2 x and y coordinates)
   - Document any padding schemes

6. **Add invalid Fp2 element tests**:
   - Test with c0 > p
   - Test with c1 > p
   - Test with c0 = p and c1 = p
   - Should return error, not silently accept

7. **Extract field modulus constant**:
   - Create constant for p-1
   - Reuse across tests
   - Document value

### Medium Priority
8. Remove error-accepting patterns once implementation is verified

9. Add test verifying uniform distribution (statistical)

10. Add multiple known test vectors from specifications

11. Document security properties of G2 hash-to-curve

12. Add test comparing Fp2 ordering (ensure consistent with spec)

### Low Priority
13. Add performance benchmarks
14. Add constant-time verification
15. Compare against reference implementation (sage, go-ethereum)

## Overall Assessment

**Grade: D**

- **Implementation**: **STATUS UNCLEAR** - May be stub or unverified
- **Testing**: Fair edge case coverage but no correctness verification
- **Documentation**: Minimal, missing critical Fp2 and algorithm details
- **Code Quality**: Has critical error handling issue and duplicated constants
- **Specification Compliance**: Gas cost correct, implementation unverified

**STATUS UNKNOWN** - Tests indicate "stub implementation" but code appears complete. Cannot verify if this works without tests that check outputs. The duplication of field modulus constants and lack of output verification make it impossible to assess correctness.

### Action Items
1. **URGENT**: Determine actual implementation status
2. **URGENT**: Add tests that verify G2 point outputs are valid
3. **URGENT**: Get and run EIP-2537 hash-to-curve G2 test vectors
4. **URGENT**: Extract field modulus to documented constant
5. Fix error handling
6. Add comprehensive documentation about Fp2 and G2
7. Add invalid input tests (c0/c1 > p)
8. Document Fp2 component ordering

Until proven to work with test vectors, consider this precompile **STATUS UNKNOWN** and potentially **BROKEN**. The higher gas cost (75000 vs 5500 for G1) suggests this is more critical to get right.
