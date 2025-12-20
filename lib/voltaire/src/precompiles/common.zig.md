# Review: common.zig

## Overview
Defines common types shared across all precompile implementations: `PrecompileResult` for successful outputs with gas accounting, and `PrecompileError` for all possible failure modes.

## Code Quality

### Strengths
- Simple, focused module with clear purpose
- Proper memory management pattern with `deinit()` method
- Uses Zig naming conventions correctly (TitleCase for types, camelCase for methods)
- Clean error union composition with `std.mem.Allocator.Error`

### Issues
- No validation in `PrecompileResult` struct (could have invalid gas_used or null output)
- `deinit()` doesn't zero out the output for security (sensitive cryptographic data)
- No documentation comments explaining when each error type should be used

## Completeness

### Complete
- All necessary fields present in `PrecompileResult`
- Comprehensive error set covering all precompile failure modes
- Proper integration with allocator error types

### Incomplete/TODOs
- No TODOs found
- Missing error types:
  - `PointNotOnCurve` (for elliptic curve operations)
  - `InvalidCompression` (for BLS/BN254 point encoding)
  - `InvalidLength` (more specific than InvalidInput)
  - `MalleableSignature` (for signature malleability detection)

## Test Coverage

### Issues
- **No tests in this file** - critical types should have basic tests
- Should test `PrecompileResult.deinit()` with allocator
- Should test error type compatibility

### Missing Test Cases
- Test that `deinit()` properly frees allocated memory
- Test that error union includes all expected errors
- Test struct field sizes and alignment
- Memory leak detection test

## Gas Calculation

### Assessment
- `gas_used` field is u64 - appropriate type for Ethereum gas
- No validation that gas_used doesn't exceed gas_limit
- No maximum gas constant defined
- Should consider if gas_used = 0 is valid (it is for some precompiles)

## Issues Found

### Critical
1. **Missing Security Zeroing**: Line 9 should zero memory before freeing for cryptographic operations
   ```zig
   pub fn deinit(self: PrecompileResult, allocator: std.mem.Allocator) void {
       @memset(self.output, 0); // Clear sensitive data
       allocator.free(self.output);
   }
   ```

### Major
2. **No Validation**: `PrecompileResult` accepts any gas_used value without validation
3. **Incomplete Error Set**: Missing specific error types for elliptic curve and BLS operations
4. **Error.Unknown**: Line 26 includes `Unknown` error which violates the principle of explicit error handling

### Minor
5. **Keccak-specific errors**: Lines 21-26 include Keccak-specific errors in a generic precompile error set
6. **No Documentation**: No doc comments explaining usage patterns

## Recommendations

### Critical Priority
1. **Add memory zeroing**: Zero sensitive data in `deinit()` before freeing
2. **Remove Unknown error**: Replace with specific error types
3. **Add tests**: At minimum, test memory management and error types

### High Priority
4. **Add missing error types**:
   - `InvalidPointEncoding`
   - `PointNotOnCurve`
   - `MalleableSignature`
   - `InvalidCompression`
5. **Add validation helper**: `PrecompileResult.validate()` to check invariants
6. **Document errors**: Add doc comments explaining when each error should be returned

### Medium Priority
7. **Consider splitting Keccak errors**: Move Keccak-specific errors to separate error set
8. **Add convenience constructors**:
   - `PrecompileResult.initFixed(allocator, comptime size: usize, gas_used: u64)`
   - `PrecompileResult.initEmpty(allocator, gas_used: u64)`
9. **Add gas constants**: Define `MAX_GAS_LIMIT` for validation

## Ethereum Specification Compliance

### Compliant
- Error types align with common EVM precompile failure modes
- `PrecompileResult` structure matches expected return pattern

### Needs Verification
- Should verify error types cover all cases in EIPs:
  - EIP-196/197 (alt_bn128)
  - EIP-152 (Blake2f)
  - EIP-2537 (BLS12-381)
  - EIP-4844 (KZG)

## Security Concerns

### Critical
1. **Memory Not Cleared**: Cryptographic outputs (signatures, keys, hashes) remain in memory after `deinit()`
2. **No Constant-Time Guarantee**: Structure doesn't enforce constant-time operations

### Medium
3. **No Output Size Limit**: Could allocate arbitrary amounts of memory
4. **Gas Overflow**: No protection against gas_used overflow when summing across operations

## Code Smells

- `Unknown` error is a red flag - indicates incomplete error handling
- Keccak-specific errors in generic module suggests poor separation of concerns
- No constraints on output slice length
- Missing doc comments makes API unclear

## Additional Notes

This is a foundational module that all precompiles depend on. Issues here propagate to all implementations. The lack of tests is particularly concerning given its critical role in memory management and error handling.

**Recommendation**: This file should be considered high priority for improvement before marking any precompile as "complete."
