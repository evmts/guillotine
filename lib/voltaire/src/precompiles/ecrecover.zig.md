# Review: ecrecover.zig

## Overview
Implements the ECRECOVER precompile (0x01) for recovering Ethereum addresses from ECDSA signatures using secp256k1 elliptic curve cryptography. Takes message hash and signature components (v, r, s) as input and returns the 20-byte Ethereum address.

## Code Quality

### Strengths
- Clean, focused implementation with clear variable names
- Proper error handling for invalid signatures (returns zero instead of erroring)
- Correct input padding/truncation behavior per Ethereum spec
- Comprehensive test suite covering edge cases
- Proper memory management with defer
- Follows Zig naming conventions

### Issues
- **Critical Security Issue**: No malleability check on signature (s value must be in lower half of curve order)
- Line 30: Extracts v from byte 31 without validating it's in range [27, 28]
- Line 33: Silently catches all errors from `recoverPubkey` without logging
- No constant-time operations (though probably not required for public key recovery)

## Completeness

### Complete
- Gas cost constant (3000) matches Ethereum Yellow Paper
- Input handling (padding/truncation) per spec
- Output format (32 bytes, left-padded address)
- Error cases return zero output per spec

### Incomplete/TODOs
- No TODOs found
- **Missing**: EIP-2 compliance check (high s value malleability protection)
- **Missing**: Validation that r and s are non-zero and within curve order
- **Missing**: Documentation of input/output format

## Test Coverage

### Strong Coverage
- Valid signature test (line 57-78)
- Gas boundary tests: out of gas, exact gas (lines 80-98)
- Input length handling: too short, too long, empty (lines 100-131)
- V value tests: 27, 28, invalid (lines 133-170)
- All zero input (lines 172-184)
- Invalid signature graceful failure (lines 203-213)

### Missing Test Cases
- **Critical**: No test for signature malleability (high s value)
- No test with known valid signature and expected address
- No test for r=0 or s=0 (invalid signatures)
- No test for r or s > curve order
- No test with EIP-155 v values (v > 28)
- No cross-validation against reference implementation
- No test for maximum v value (255)
- No test verifying Keccak256 is called correctly

## Gas Calculation

### Assessment
- Constant gas cost: 3000 (line 8)
- Matches Ethereum Yellow Paper specification ✓
- Independent of input size (correct per spec) ✓
- No overflow possible ✓
- Test verifies constant at line 186-190

### Verification
Per Ethereum Yellow Paper and EIP-2:
- ECRECOVER gas cost = 3000 ✓
- No dynamic component ✓
- Pre-Byzantine gas cost also 3000 ✓

## Issues Found

### Critical Security Issues
1. **Signature Malleability (EIP-2)**: No check that s ≤ secp256k1n/2
   - Ethereum requires s in lower half of curve order to prevent malleability
   - Current implementation accepts both high and low s values
   - **Impact**: Transaction replay attacks possible if calling code doesn't validate
   - **Fix**: Add validation in secp256k1.recoverPubkey or here
   ```zig
   // After line 27, add:
   const CURVE_ORDER_HALF = secp256k1.CURVE_ORDER / 2;
   const s_value = std.mem.readInt(u256, s, .big);
   if (s_value == 0 or s_value > CURVE_ORDER_HALF) {
       // Return zero output
   }
   ```

2. **Missing r/s Validation**: No check that r and s are within valid range [1, n-1]
   - Zero values should be rejected
   - Values exceeding curve order should be rejected

3. **V Value Not Validated**: Line 30 extracts v without checking it's in valid range
   - Should verify v ∈ {27, 28} before passing to recoverPubkey
   - Current code allows any byte value

### Major Issues
4. **Silent Error Handling**: Line 33 catches all errors without differentiation
   - Cannot distinguish between malformed input, invalid signature, crypto library failure
   - For debugging: should at least have conditional logging in test builds

5. **No Known Test Vector**: Test at line 57-78 doesn't verify correct output
   - Should use official Ethereum test vectors from ethereum/tests repository
   - Currently only checks output length, not correctness

6. **Input Format Not Documented**: No comments explaining layout
   ```zig
   // Input format (128 bytes):
   //   [0..32]    hash    - Message hash (32 bytes)
   //   [32..64]   v       - Recovery id (32 bytes, right-aligned)
   //   [64..96]   r       - Signature component (32 bytes)
   //   [96..128]  s       - Signature component (32 bytes)
   ```

### Minor Issues
7. **Test Naming**: "valid signature" test doesn't validate correctness
8. **Magic Number**: Line 30 uses 31 without comment explaining right-alignment
9. **Redundant Test**: Lines 192-201 duplicate lines 172-184

## Recommendations

### Critical Priority (Fix Before Production)
1. **Add signature malleability check**:
   ```zig
   // After extracting s, before recovery:
   const s_value = std.mem.readInt(u256, s, .big);
   if (s_value == 0 or s_value > secp256k1.CURVE_ORDER_HALF) {
       const output = try allocator.alloc(u8, 32);
       @memset(output, 0);
       return PrecompileResult{ .output = output, .gas_used = GAS };
   }
   ```

2. **Add r validation**:
   ```zig
   const r_value = std.mem.readInt(u256, r, .big);
   if (r_value == 0 or r_value >= secp256k1.CURVE_ORDER) {
       // Return zero
   }
   ```

3. **Add v validation**:
   ```zig
   const v = v_bytes[31];
   if (v != 27 and v != 28) {
       // Return zero output
   }
   ```

4. **Add known test vectors**: Use official Ethereum test suite
   ```zig
   test "ecRecover - ethereum test vector 1" {
       // From: ethereum/tests/GeneralStateTests/stPreCompiledContracts/
       const hash = try hex.decode("...");
       const expected_address = try hex.decode("...");
       // ... verify exact match
   }
   ```

### High Priority
5. **Document input/output format** in function comment
6. **Add malleability test**:
   ```zig
   test "ecRecover - rejects high s value (malleability)" {
       var input = [_]u8{0} ** 128;
       // Set s > CURVE_ORDER / 2
       const result = try execute(allocator, &input, GAS);
       defer result.deinit(allocator);
       // Should return all zeros
       for (result.output) |byte| {
           try testing.expectEqual(@as(u8, 0), byte);
       }
   }
   ```

7. **Improve error handling**: Differentiate error cases
8. **Add EIP-155 test**: Verify behavior with EIP-155 v values (v > 28)

### Medium Priority
9. **Add benchmark for valid vs invalid signatures** to ecrecover.bench.zig
10. **Cross-validation test**: Compare against go-ethereum, nethermind, etc.
11. **Add fuzzing test** with random inputs
12. **Document gas cost**: Add comment explaining why 3000 gas

## Ethereum Specification Compliance

### Compliant ✓
- Gas cost (3000) matches Yellow Paper
- Input format (128 bytes) correct
- Output format (32 bytes, left-padded) correct
- Returns zero for invalid signatures
- Handles variable-length input with padding

### Non-Compliant ✗
- **Missing EIP-2 malleability protection**: Must reject s > n/2
- **Should validate r, s ∈ [1, n-1]**: Yellow Paper implies this
- **Should validate v ∈ {27, 28}**: Spec requires specific values

### References
- Ethereum Yellow Paper: Appendix E (Precompiled Contracts)
- EIP-2: Homestead Hard-fork Changes (signature malleability)
- ethereum/tests: GeneralStateTests/stPreCompiledContracts/

## Security Concerns

### Critical
1. **Signature Malleability**: Allows dual valid signatures for same message
2. **Invalid Curve Points**: No validation that r is valid x-coordinate
3. **Missing Input Validation**: Accepts out-of-range r, s, v values

### Medium
4. **Timing Attacks**: Not constant-time (but likely acceptable for public key recovery)
5. **Memory Not Cleared**: hash_output at line 44 not zeroed (contains sensitive data)
6. **No Rate Limiting**: Could be used for DoS (though gas provides economic limit)

## Code Smells

- Silent error catch-all at line 33
- Duplicate zero-checking tests
- No reference to EIP-2 in comments
- Magic number 31 for v extraction
- Test names don't match what they test (e.g., "valid signature" doesn't verify validity)

## Benchmark Review (ecrecover.bench.zig)

### Coverage
- Valid signature benchmark ✓
- Minimum gas benchmark ✓
- Short input benchmark ✓
- Invalid signature benchmark ✓
- V=27 benchmark ✓

### Issues
- Benchmark silently swallows errors with `catch return`
- Should differentiate hot/cold cache performance
- Missing benchmark for malformed v values
- No comparison with other implementations

### Recommendations
- Add error reporting in benchmarks
- Add benchmark with real-world Ethereum transaction signatures
- Benchmark signature validation overhead separately

## Overall Assessment

**Status**: Partially complete - requires critical security fixes before production use

**Security Rating**: ⚠️ HIGH RISK - Missing EIP-2 malleability protection

**Quality Rating**: Good code structure but missing essential validation

**Compliance Rating**: Non-compliant with EIP-2 (signature malleability)

**Priority**: CRITICAL - This precompile is widely used and security vulnerabilities have severe implications for transaction integrity.

**Estimated Work**: 4-8 hours to add validation, tests, and documentation
