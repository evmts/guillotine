# Review: bn254/FpMont.zig

## 1. Overview
Base field arithmetic using Montgomery representation for efficient modular multiplication. Implements Fp where p is the BN254 field modulus. Montgomery form: elements stored as a*R mod p where R=2^256.

## 2. Code Quality

### Strengths
- Correct Montgomery REDC implementation
- Comprehensive test suite (50+ tests)
- Mathematical properties verified
- Good edge case coverage
- Clear documentation of Montgomery algorithm

### Issues
- **No constant-time operations**: All operations are variable-time
- **No input sanitization**: init() reduces modulo but doesn't validate
- **Complex inverse** (Lines 133-169): Extended GCD implementation correct but opaque

## 3. Completeness

### Complete
- Full Montgomery arithmetic (add, sub, mul, square)
- Modular inverse (extended GCD)
- Power/exponentiation
- Conversion to/from standard form

### Missing
- **No constant-time variants**: All operations leak timing info
- **No batch inverse**: Montgomery's trick not implemented
- **No sqrt**: Square root operation missing
- **No serialization**: No direct bytes conversion

## 4. Test Coverage

**Excellent** - Very thorough testing of all operations including edge cases, mathematical properties, and round-trip conversions.

## 5. Security Issues

### MEDIUM
1. **Variable-time operations** (All): Multiplication, inversion, etc. leak information through timing. Acceptable for field operations in zkSNARK verification but should be documented.

2. **No overflow checks**: Relies on Zig's type system for safety. Safe but could document explicitly.

## 6. Issues Found

### Bugs
- None identified - implementation appears correct

### Code Smells
- Extended GCD inverse (lines 133-169) is complex and poorly commented
- Test duplication could use tables
- invAssign() at line 172 takes no error - type signature wrong?

## 7. Recommendations

### HIGH PRIORITY
1. **Document timing safety**:
   ```zig
   /// WARNING: All operations are variable-time and may leak secret values
   /// through timing side-channels. Safe for public field elements only.
   ```

2. **Add constant-time comparison** if needed:
   ```zig
   pub fn ctEqual(self: *const FpMont, other: *const FpMont) bool {
       var result: u256 = 0;
       result |= self.value ^ other.value;
       return result == 0;  // Constant-time
   }
   ```

3. **Fix invAssign** type signature (line 172):
   ```zig
   pub fn invAssign(self: *FpMont) !void {  // Missing !
       self.* = try self.inv();
   }
   ```

### MEDIUM PRIORITY
4. **Document extended GCD** algorithm with references
5. **Add batch inverse** for efficiency
6. **Implement sqrt** for completeness

**Overall**: Solid, correct implementation. Main issue is lack of timing safety documentation.
