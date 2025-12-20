# Review: ripemd160.zig

## Overview
Implements the RIPEMD160 precompile (0x03) which computes the RIPEMD-160 hash (20 bytes) and returns it left-padded to 32 bytes. One of the four original Frontier precompiles, primarily used for Bitcoin interoperability.

## Code Quality

### Strengths
- Clean, straightforward implementation
- Correct gas calculation matching SHA256 pattern
- Proper output padding (12 zeros + 20 byte hash)
- Good test coverage for gas and padding
- Follows Zig naming conventions
- Proper memory management

### Issues
- No documentation explaining why RIPEMD160 exists (Bitcoin compatibility)
- No validation that gas calculation doesn't overflow
- No known test vectors from official sources
- Left-padding logic not documented

## Completeness

### Complete ✓
- Gas constants (BASE=600, PER_WORD=120) match Ethereum spec
- Input handling (any length)
- Output format (32 bytes: 12 zero + 20 hash)
- Edge cases (empty input, large input)

### Incomplete/TODOs
- No TODOs found
- Missing: Known test vectors from RIPEMD160 spec
- Missing: Bitcoin address test case (main use case)
- Missing: Comparison with well-known RIPEMD160 implementation

## Test Coverage

### Good Coverage
- Empty input (lines 37-50)
- Gas calculation for 1, 2 words (lines 52-74)
- Partial word rounding (lines 76-86)
- Out of gas / exact gas (lines 88-110)
- Gas constants verification (lines 112-117)
- Output size verification (lines 119-128)
- Left-padding verification (lines 130-142)
- Large input (1000 bytes) (lines 144-155)

### Missing Test Cases
- No known test vector from RIPEMD160 specification
- No test vector from Ethereum test suite
- No Bitcoin address derivation test (primary use case)
- No test comparing against reference implementation
- No test for maximum input size
- No test for gas overflow protection
- No cross-validation with other RIPEMD160 libraries

## Gas Calculation

### Formula
```zig
num_words = (input.len + 31) / 32
gas_cost = BASE_GAS + PER_WORD_GAS * num_words
```

### Verification
Per Ethereum Yellow Paper Appendix E:
- BASE_GAS = 600 ✓
- PER_WORD_GAS = 120 ✓
- Word size = 32 bytes ✓
- Rounding up partial words ✓

Note: RIPEMD160 is 10x more expensive than SHA256 (600 vs 60 base, 120 vs 12 per word)

### Test Cases Verified
| Input Size | Words | Expected Gas | Test Line |
|------------|-------|--------------|-----------|
| 0 bytes    | 0     | 600          | Implicit line 41 |
| 32 bytes   | 1     | 720          | Line 60 |
| 64 bytes   | 2     | 840          | Line 72 |
| 33 bytes   | 2     | 840          | Line 84 |
| 1000 bytes | 32    | 4440         | Line 153 |

All verified correct ✓

### Cost Comparison
| Precompile | Base | Per Word | 1KB Cost |
|------------|------|----------|----------|
| SHA256     | 60   | 12       | 444      |
| RIPEMD160  | 600  | 120      | 4440     |

RIPEMD160 is exactly 10x more expensive than SHA256 ✓

## Issues Found

### Medium Priority
1. **No Overflow Protection**: Gas calculation could theoretically overflow
   ```zig
   // Lines 17-18 could overflow with huge input
   const num_words = (input.len + 31) / 32;
   const gas_cost = BASE_GAS + PER_WORD_GAS * num_words;
   ```
   Same issue as SHA256 - should use checked arithmetic

2. **No Known Test Vectors**: Need official test cases
   - RIPEMD160 spec provides test vectors
   - Ethereum test suite has examples
   - Bitcoin community has well-known test cases

3. **No Documentation of Use Case**: Should explain why RIPEMD160 exists
   - Used for Bitcoin address derivation
   - Bitcoin uses RIPEMD160(SHA256(pubkey)) for addresses
   - Important for Bitcoin-Ethereum bridges

4. **Left-Padding Not Documented**: Line 25 zeros first 12 bytes
   - Should explain why (EVM word size is 32 bytes)
   - Should reference spec requirement

### Low Priority
5. **No Maximum Input Size Test**: Should test reasonable maximum
6. **No Comparison Test**: Should verify against reference implementation
7. **Magic Number**: Line 148 uses hardcoded 1000 bytes

## Recommendations

### Critical Priority
1. **Add overflow protection** (same as SHA256):
   ```zig
   pub fn execute(
       allocator: std.mem.Allocator,
       input: []const u8,
       gas_limit: u64,
   ) PrecompileError!PrecompileResult {
       const num_words = (input.len + 31) / 32;
       const word_gas = std.math.mul(u64, PER_WORD_GAS, num_words)
           catch return error.OutOfGas;
       const gas_cost = std.math.add(u64, BASE_GAS, word_gas)
           catch return error.OutOfGas;

       if (gas_limit < gas_cost) {
           return error.OutOfGas;
       }
       // ... rest
   }
   ```

### High Priority
2. **Add official test vectors**:
   ```zig
   test "ripemd160 - RIPEMD160 spec test vector" {
       const testing = std.testing;
       const allocator = testing.allocator;

       // From RIPEMD160 specification
       const input = ""; // Empty string
       const result = try execute(allocator, input, 1000000);
       defer result.deinit(allocator);

       // RIPEMD160("") = 9c1185a5c5e9fc54612808977ee8f548b2258d31
       const expected_hash = [_]u8{
           0x9c, 0x11, 0x85, 0xa5, 0xc5, 0xe9, 0xfc, 0x54,
           0x61, 0x28, 0x08, 0x97, 0x7e, 0xe8, 0xf5, 0x48,
           0xb2, 0x25, 0x8d, 0x31,
       };
       try testing.expectEqualSlices(u8, &expected_hash, result.output[12..32]);
   }

   test "ripemd160 - abc test vector" {
       const testing = std.testing;
       const allocator = testing.allocator;

       // RIPEMD160("abc") = 8eb208f7e05d987a9b044a8e98c6b087f15a0bfc
       const input = "abc";
       const result = try execute(allocator, input, 1000000);
       defer result.deinit(allocator);

       const expected_hash = [_]u8{
           0x8e, 0xb2, 0x08, 0xf7, 0xe0, 0x5d, 0x98, 0x7a,
           0x9b, 0x04, 0x4a, 0x8e, 0x98, 0xc6, 0xb0, 0x87,
           0xf1, 0x5a, 0x0b, 0xfc,
       };
       try testing.expectEqualSlices(u8, &expected_hash, result.output[12..32]);
   }

   test "ripemd160 - Bitcoin address derivation" {
       const testing = std.testing;
       const allocator = testing.allocator;

       // Simulate Bitcoin address generation:
       // Address = RIPEMD160(SHA256(pubkey))
       // This tests the primary use case

       // Use known Bitcoin public key (compressed)
       const pubkey = [_]u8{ /* 33 bytes */ };

       // First SHA256
       var sha_output: [32]u8 = undefined;
       std.crypto.hash.sha2.Sha256.hash(&pubkey, &sha_output, .{});

       // Then RIPEMD160
       const result = try execute(allocator, &sha_output, 1000000);
       defer result.deinit(allocator);

       // Verify against known Bitcoin address hash
       const expected = [_]u8{ /* known hash160 */ };
       try testing.expectEqualSlices(u8, &expected, result.output[12..32]);
   }
   ```

3. **Add comprehensive documentation**:
   ```zig
   /// 0x03: RIPEMD160 - RIPEMD-160 hash function
   ///
   /// Computes the RIPEMD-160 cryptographic hash (20 bytes) and returns it
   /// left-padded with zeros to 32 bytes for EVM compatibility.
   ///
   /// Gas cost: 600 + 120 * ceil(input.len / 32)
   ///
   /// Input: Arbitrary length byte array
   /// Output: 32 bytes (12 zero bytes + 20 byte RIPEMD-160 hash)
   ///
   /// Use cases:
   /// - Bitcoin address derivation (RIPEMD160(SHA256(pubkey)))
   /// - Bitcoin-Ethereum cross-chain bridges
   /// - Legacy cryptographic systems
   ///
   /// Note: RIPEMD160 is 10x more expensive than SHA256 due to lower
   /// usage and incentive to prefer more modern hash functions.
   ///
   /// Available since: Frontier (EIP-0)
   ///
   /// References:
   /// - RIPEMD160 spec: https://homes.esat.kuleuven.be/~bosselae/ripemd160.html
   /// - Ethereum Yellow Paper: Appendix E
   /// - Bitcoin Wiki: https://en.bitcoin.it/wiki/RIPEMD-160
   pub fn execute(...) { ... }
   ```

4. **Document padding**:
   ```zig
   const output = try allocator.alloc(u8, 32);
   // Left-pad with zeros to fill EVM word (32 bytes)
   // Output: [0x00 * 12][RIPEMD160 hash 20 bytes]
   @memset(output[0..12], 0);

   var hash_output: [20]u8 = undefined;
   Ripemd160.hash(input, &hash_output);
   @memcpy(output[12..32], &hash_output);
   ```

### Medium Priority
5. **Add overflow test**:
   ```zig
   test "ripemd160 - gas calculation overflow protection" {
       const testing = std.testing;
       const allocator = testing.allocator;

       // Test that huge input sizes don't cause overflow
       // (Implementation detail: need to add overflow checks first)
   }
   ```

6. **Add maximum size test**:
   ```zig
   test "ripemd160 - reasonable maximum input" {
       const testing = std.testing;
       const allocator = testing.allocator;

       const MAX_SIZE = 32 * 1024 * 1024; // 32MB
       const input = try allocator.alloc(u8, MAX_SIZE);
       defer allocator.free(input);

       const result = try execute(allocator, input, std.math.maxInt(u64));
       defer result.deinit(allocator);

       try testing.expectEqual(@as(usize, 32), result.output.len);
       // First 12 bytes should be zero
       for (result.output[0..12]) |byte| {
           try testing.expectEqual(@as(u8, 0), byte);
       }
   }
   ```

7. **Add comparison test with another implementation**:
   ```zig
   test "ripemd160 - matches known implementation" {
       // Compare against trusted RIPEMD160 library
       // or cross-validate with go-ethereum, etc.
   }
   ```

### Low Priority
8. **Add usage example in comments**:
   ```zig
   // Example: Bitcoin address derivation
   // const pubkey_hash = ripemd160(sha256(pubkey));
   // const address = base58check_encode(pubkey_hash);
   ```

9. **Add constant for output sizes**:
   ```zig
   pub const RIPEMD160_SIZE: usize = 20;
   pub const PADDED_OUTPUT_SIZE: usize = 32;
   pub const PADDING_SIZE: usize = 12;
   ```

## Ethereum Specification Compliance

### Fully Compliant ✓
- Gas costs match Yellow Paper exactly
- Input handling correct (any length)
- Output format correct (32 bytes, left-padded)
- Rounding behavior correct
- Available since Frontier ✓

### Verification Against Spec
| Requirement | Status | Evidence |
|-------------|--------|----------|
| BASE_GAS = 600 | ✓ | Line 8 |
| PER_WORD_GAS = 120 | ✓ | Line 9 |
| Output = 32 bytes | ✓ | Line 24 |
| Left-padded with zeros | ✓ | Line 25 |
| Hash is 20 bytes | ✓ | Lines 27-29 |
| Rounds up words | ✓ | Line 17, test line 76 |

### References
- Ethereum Yellow Paper: Appendix E.1
- EIP-0 (implicit): Original precompiles
- RIPEMD160 specification: https://homes.esat.kuleuven.be/~bosselae/ripemd160.html

## Security Concerns

### Low Priority
1. **RIPEMD160 Security**: Considered weaker than SHA256
   - Not broken, but less studied
   - 160-bit output smaller than SHA256's 256-bit
   - Primarily used for Bitcoin compatibility

2. **DoS via Large Input**: Same as SHA256
   - Mitigated by high gas cost (10x SHA256)
   - 32MB input costs ~120,000,000 gas
   - Practically limited by block gas limit

3. **Memory Not Cleared**: hash_output at line 27 not zeroed
   - Low impact (public hashes, not secrets)

### Not Concerns
- Timing attacks: Not relevant for public hash computation
- Collision resistance: RIPEMD160 has no known practical collisions
- Input validation: All inputs valid by design

## Code Smells

### Minor
- Magic numbers: 12 (padding), 20 (hash size), 32 (output)
- No named constants for these values
- Hardcoded 1000 in test (line 148)
- No reference to Bitcoin use case

## Usage Context

### Primary Use Case: Bitcoin Interoperability
RIPEMD160 is rarely used except for:
1. **Bitcoin address derivation**: `Address = Base58Check(RIPEMD160(SHA256(pubkey)))`
2. **Bitcoin script verification**: Some Bitcoin scripts use RIPEMD160
3. **Cross-chain bridges**: Ethereum↔Bitcoin bridges need this

### Why It Exists
- Bitcoin Core uses RIPEMD160 for addresses
- For Ethereum to interact with Bitcoin, must support RIPEMD160
- Expensive gas cost discourages use outside Bitcoin compatibility

### Alternatives
For new systems, prefer:
- SHA256 (0x02): Faster, better studied, cheaper
- Keccak256: Ethereum's native hash

## Overall Assessment

**Status**: ✅ Production-ready with minor improvements recommended

**Security Rating**: ✅ SECURE - No critical issues (RIPEMD160 itself has known weaknesses but acceptable for Bitcoin compatibility)

**Quality Rating**: ✅ HIGH - Clean code, good tests, correct implementation

**Compliance Rating**: ✅ FULLY COMPLIANT - Matches Ethereum spec exactly

**Priority**: LOW - Works correctly, improvements are hardening/documentation

**Estimated Work**: 2-3 hours for overflow protection, test vectors, documentation

## Comparison with SHA256 Implementation

Both RIPEMD160 and SHA256 implementations are high quality and follow same patterns:
- ✓ Correct gas calculation
- ✓ Good test coverage
- ✓ Proper memory management
- ✗ No overflow protection (both need this)
- ✗ Missing official test vectors (both need this)
- ✗ No documentation (both need this)

The implementations are consistent and well-structured. Main improvements needed are defensive programming and better documentation.

## Key Differences from SHA256

| Aspect | SHA256 | RIPEMD160 |
|--------|--------|-----------|
| Output size | 32 bytes | 20 bytes |
| Gas base | 60 | 600 (10x) |
| Gas per word | 12 | 120 (10x) |
| Padding | None | Left-pad 12 zeros |
| Use case | General hashing | Bitcoin compatibility |
| Security | Strong (256-bit) | Adequate (160-bit) |

RIPEMD160's higher gas cost reflects its specialized nature and incentivizes using more modern alternatives when Bitcoin compatibility isn't required.
