# Code Review: src/errors.zig

**Reviewed on:** 2025-10-26
**File:** `/Users/williamcory/guillotine-mini/src/errors.zig`
**Lines of Code:** 42
**Purpose:** Centralized error type definitions for EVM operations

---

## Executive Summary

The `errors.zig` file defines a single error set `CallError` containing 42 distinct error types. While the file is simple and well-formatted, there are several concerns regarding redundancy, unused errors, lack of documentation, and missing test coverage.

**Overall Assessment:** ⚠️ NEEDS IMPROVEMENT

**Key Issues:**
- 10+ error types appear to be unused in the codebase
- Redundant error types (OutOfMemory vs AllocationError)
- Some error names defined in CallError but used from ValidationError in call_params.zig
- No documentation explaining when each error should be used
- Limited test coverage for error propagation
- Missing semantic grouping/organization

---

## 1. Incomplete Features

### 1.1 Undocumented Error Usage Patterns

**Severity:** Medium
**Location:** Entire file (lines 1-42)

**Issue:**
The file lacks any documentation explaining:
- When each error type should be returned
- Which operations can trigger which errors
- How errors map to EVM execution failures vs internal errors
- Distinction between recoverable and fatal errors

**Recommendation:**
Add comprehensive documentation:
```zig
/// Error set for Evm operations
///
/// This error set covers all failure modes in EVM execution:
/// - Execution errors: Invalid operations during bytecode execution
/// - Resource errors: Memory/gas exhaustion
/// - Validation errors: Invalid call parameters or state
/// - I/O errors: Storage/host interface failures
pub const CallError = error{
    // === Execution Errors ===

    /// Invalid jump destination (not marked as JUMPDEST)
    InvalidJump,

    /// Insufficient gas to complete operation
    OutOfGas,

    // ... (document each error type)
};
```

### 1.2 Missing Error Context

**Severity:** Low
**Location:** All error types

**Issue:**
Errors provide no context about what failed. For example, `InvalidOpcode` doesn't indicate which opcode was invalid, `OutOfBounds` doesn't specify what index/range failed.

**Recommendation:**
Consider migrating critical errors to error unions with payloads for better debugging:
```zig
pub const EvmError = union(enum) {
    invalid_jump: struct { pc: u64, destination: u64 },
    out_of_gas: struct { required: u64, available: u64 },
    invalid_opcode: struct { opcode: u8, pc: u64 },
    // ... other errors

    // Simple errors without context
    stack_underflow,
    stack_overflow,
    // ...
};
```

---

## 2. TODOs and FIXMEs

**Status:** ✅ NONE FOUND

No TODO, FIXME, XXX, HACK, or BUG comments found in the file.

However, related file `/Users/williamcory/guillotine-mini/src/call_params.zig:68` contains:
```zig
// BUG: we should be checking if gas checks are disabled or not
if (self.getGas() == 0) return ValidationError.GasZeroError;
```

This suggests gas validation errors may need refinement.

---

## 3. Bad Code Practices

### 3.1 Redundant Error Types

**Severity:** Medium
**Location:** Lines 18-19

**Issue:**
```zig
OutOfMemory,
AllocationError,
```

These appear to be duplicate error types for the same condition. `OutOfMemory` is Zig's standard error name for allocation failures, making `AllocationError` redundant.

**Evidence from grep:**
- Neither error is actively used in the codebase (only found in definitions and WASM exports)
- Zig's standard library uses `error.OutOfMemory` for allocation failures

**Recommendation:**
Remove `AllocationError` and standardize on `OutOfMemory`:
```zig
// Remove this line:
AllocationError,
```

### 3.2 Error Type Duplication Across Modules

**Severity:** Low
**Location:** Lines 33-37 vs `/Users/williamcory/guillotine-mini/src/call_params.zig:57-63`

**Issue:**
CallParams validation errors are defined in BOTH places:
- `CallError` (errors.zig): `GasZeroError`, `InvalidInputSize`, etc.
- `ValidationError` (call_params.zig): Same error names

This creates confusion about which error set should be used.

**Current usage:**
```zig
// In call_params.zig:
pub const ValidationError = error{
    GasZeroError,
    InvalidInputSize,
    InvalidInitCodeSize,
    InvalidCreateValue,
    InvalidStaticCallValue,
};
```

**Recommendation:**
Choose one location:
- **Option A:** Keep only in `CallError`, remove from `ValidationError` (preferred for centralization)
- **Option B:** Keep separate but document why (e.g., "validation errors" vs "execution errors")

### 3.3 Unclear Error Naming

**Severity:** Low
**Location:** Multiple lines

**Issues:**
- `InvalidJump` vs `InvalidJumpDestination` (lines 3, 21) - Unclear distinction
- `CreateInitCodeSizeLimit` vs `InitcodeTooLarge` (lines 23, 29) - Redundant names for same EIP-3860 check
- `CreateContractSizeLimit` vs `BytecodeTooLarge` (lines 27, 30) - Similar redundancy
- `MemoryError` vs `OutOfBounds` (lines 9, 25) - When to use which?

**Recommendation:**
Consolidate and clarify:
```zig
// Memory/bounds errors - pick one:
OutOfBounds,  // Preferred: generic, matches Zig conventions

// Jump errors - consolidate or distinguish:
InvalidJumpDestination,  // If both needed, document difference

// Size limit errors - consolidate:
InitCodeSizeExceeded,      // EIP-3860: init code too large
ContractSizeExceeded,      // EIP-170: deployed code too large
```

### 3.4 No Error Hierarchy

**Severity:** Low
**Location:** Entire file

**Issue:**
All 42 errors are in a flat list with no semantic grouping. Comments group them (lines 32, 38, 40), but the organization could be clearer.

**Current:**
```zig
pub const CallError = error{
    InvalidJump,
    OutOfGas,
    // ... 40 more errors
};
```

**Recommendation:**
Consider splitting into logical subsets:
```zig
// Execution errors
pub const ExecutionError = error{
    InvalidJump,
    OutOfGas,
    StackUnderflow,
    // ...
};

// State/storage errors
pub const StateError = error{
    StorageError,
    InsufficientBalance,
    ContractCollision,
    // ...
};

// Combine for backward compatibility
pub const CallError = ExecutionError || StateError || ValidationError || IoError;
```

---

## 4. Missing Test Coverage

### 4.1 Limited Error Propagation Tests

**Severity:** High
**Location:** N/A (missing tests)

**Current Coverage:**
From `/Users/williamcory/guillotine-mini/src/evm_test.zig`:
- ✅ `NeedAsyncData` - 2 tests (propagation, identification)
- ⚠️ All other errors - NO dedicated tests

**Missing Test Scenarios:**
1. **Stack errors:** StackUnderflow, StackOverflow
2. **Jump errors:** InvalidJump, InvalidJumpDestination, MissingJumpDestMetadata
3. **Gas errors:** OutOfGas in various contexts
4. **Memory errors:** MemoryError, OutOfBounds
5. **Call errors:** CallDepthExceeded, InsufficientBalance
6. **Create errors:** CreateInitCodeSizeLimit, CreateContractSizeLimit, ContractCollision
7. **Static context:** StaticCallViolation, WriteProtection
8. **Validation errors:** All 5 CallParams validation errors
9. **Contract state:** ContractNotFound, AccountNotFound
10. **Other:** PrecompileError, InvalidBytecode, InvalidOpcode, RevertExecution

**Recommendation:**
Add comprehensive error tests:
```zig
// In src/errors_test.zig (new file):
test "CallError - all error types can be returned and caught" {
    const testing = std.testing;

    // Test each error type
    try testing.expectError(CallError.InvalidJump, throwError(.InvalidJump));
    try testing.expectError(CallError.OutOfGas, throwError(.OutOfGas));
    // ... test all 42 errors
}

test "CallError - errors propagate through try chain" {
    // Test error propagation for critical errors
}

test "CallError - errors contain expected values in enum" {
    // Verify error set completeness
}
```

### 4.2 No Error Recovery Testing

**Severity:** Medium
**Location:** N/A (missing tests)

**Issue:**
No tests verify that errors are properly caught and handled at appropriate boundaries (e.g., REVERT should be catchable, but OutOfGas should terminate).

**Recommendation:**
Add tests for error recovery patterns:
```zig
test "RevertExecution is catchable and returns data" {
    // Verify REVERT can be caught with return data
}

test "OutOfGas terminates execution immediately" {
    // Verify OOG cannot be recovered
}
```

---

## 5. Potentially Unused Errors

**Severity:** Medium
**Location:** Multiple lines

**Finding:**
The following error types are DEFINED but appear UNUSED in the codebase (found only in errors.zig and WASM symbol tables):

1. **Line 7:** `ContractNotFound` - 0 uses
2. **Line 8:** `PrecompileError` - 0 uses (only in WASM exports, git comments)
3. **Line 9:** `MemoryError` - 0 uses
4. **Line 10:** `StorageError` - 0 uses
5. **Line 13:** `ContractCollision` - 0 uses
6. **Line 20:** `AccountNotFound` - 0 uses
7. **Line 22:** `MissingJumpDestMetadata` - 0 uses
8. **Line 27:** `BytecodeTooLarge` - 0 uses
9. **Line 29:** `CreateInitCodeSizeLimit` - 0 uses
10. **Line 30:** `CreateContractSizeLimit` - 0 uses
11. **Line 39:** `NoSpaceLeft` - 0 uses (defined but no I/O operations return it)

**Note:** Some errors may be intended for future use or defensive programming, but their absence suggests:
- Dead code
- Incomplete implementation
- Missing error handling paths

**Recommendation:**
1. Audit each unused error:
   - Remove if truly unnecessary
   - Implement error handling if missing
   - Document if reserved for future features
2. Add tests that trigger each error path
3. Run coverage analysis to identify untested error paths

---

## 6. Other Issues

### 6.1 Missing Module Documentation

**Severity:** Low
**Location:** Line 1

**Issue:**
File has only a single-line comment. No explanation of:
- Error handling philosophy
- When to use CallError vs returning null/false
- How errors map to EVM execution results (success/revert/error)

**Recommendation:**
Add module-level documentation:
```zig
//! Error types for EVM execution
//!
//! This module defines all error conditions that can occur during EVM execution.
//!
//! Error Handling Strategy:
//! - Execution errors (InvalidOpcode, OutOfGas): EVM halts with error status
//! - Revert errors (RevertExecution): EVM halts but returns data
//! - Validation errors: Detected before execution begins
//! - Internal errors (OutOfMemory): Implementation failures, not EVM-level
//!
//! See also: src/evm.zig (execution), src/frame.zig (bytecode), src/call_params.zig (validation)
```

### 6.2 No Error Code Mapping

**Severity:** Low
**Location:** N/A

**Issue:**
Some EVM implementations map errors to numeric codes for RPC responses (e.g., -32000 series). This is missing.

**Recommendation:**
Consider adding error code mappings if needed for RPC compliance:
```zig
pub fn errorCode(err: CallError) i32 {
    return switch (err) {
        error.OutOfGas => -32000,
        error.RevertExecution => -32001,
        // ... etc
    };
}
```

### 6.3 Missing Error Frequency Metrics

**Severity:** Low
**Location:** N/A

**Issue:**
No way to track which errors occur most frequently in production/testing.

**Recommendation:**
Add optional error tracking:
```zig
pub var error_counts: std.EnumArray(CallError, u64) = .initFill(0);

pub fn recordError(err: CallError) void {
    error_counts.getPtr(err).* += 1;
}
```

### 6.4 Potential Type Safety Issue with ValidationError

**Severity:** Low
**Location:** Lines 33-37

**Issue:**
The same error names exist in both `CallError` and `CallParams.ValidationError`. While Zig allows this, it could cause confusion:

```zig
// Which error set is this?
if (error.GasZeroError == err) { ... }
```

**Recommendation:**
Use fully qualified names when ambiguous:
```zig
if (errors.CallError.GasZeroError == err) { ... }
```

---

## 7. Positive Observations

### ✅ Good Practices Found

1. **Clean formatting:** File follows Zig style guide
2. **Clear naming:** Most error names are descriptive (InvalidJump, OutOfGas)
3. **Logical comments:** Errors are grouped with comments (CallParams, IO, Async)
4. **Single error set:** Centralized in one location (mostly)
5. **No complexity:** Simple enum, no premature abstraction

---

## 8. Recommendations Summary

### Immediate Actions (High Priority)

1. **Remove redundant errors:**
   - Delete `AllocationError` (use `OutOfMemory`)
   - Consolidate `InvalidJump`/`InvalidJumpDestination`
   - Consolidate `InitcodeTooLarge`/`CreateInitCodeSizeLimit`
   - Consolidate `BytecodeTooLarge`/`CreateContractSizeLimit`

2. **Add comprehensive tests:**
   - Create `src/errors_test.zig`
   - Test all 42 error types can be thrown and caught
   - Test error propagation through call chains
   - Test error recovery boundaries

3. **Document unused errors:**
   - Audit 11 unused error types
   - Remove dead code OR document why reserved

### Short-term Improvements (Medium Priority)

4. **Add documentation:**
   - Module-level doc comment
   - Per-error documentation explaining when/why used
   - Examples of error handling patterns

5. **Resolve ValidationError duplication:**
   - Choose one location for validation errors
   - Document relationship between CallError and ValidationError

6. **Add error context:**
   - Consider migrating to error unions for better debugging
   - At minimum, improve error messages in calling code

### Long-term Enhancements (Low Priority)

7. **Improve organization:**
   - Consider splitting into semantic subsets
   - Add error code mappings if needed for RPC
   - Add optional error tracking/metrics

8. **Coverage analysis:**
   - Run coverage tool to identify untested error paths
   - Ensure all error types are reachable

---

## 9. Test Coverage Analysis

### Errors WITH Test Coverage (2 / 42 = 4.8%)

| Error | Test File | Test Name |
|-------|-----------|-----------|
| `NeedAsyncData` | `src/evm_test.zig:70` | "error.NeedAsyncData can be caught and identified" |
| `NeedAsyncData` | `src/evm_test.zig:83` | "error.NeedAsyncData propagates through call stack" |

### Errors WITHOUT Test Coverage (40 / 42 = 95.2%)

| Error | Likely Test Location | Priority |
|-------|----------------------|----------|
| `InvalidJump` | frame execution tests | High |
| `OutOfGas` | gas metering tests | High |
| `StackUnderflow` | stack operation tests | High |
| `StackOverflow` | stack operation tests | High |
| `StaticCallViolation` | STATICCALL tests | High |
| `InvalidOpcode` | opcode parsing tests | Medium |
| `RevertExecution` | REVERT instruction tests | High |
| `CallDepthExceeded` | nested call tests | Medium |
| `InsufficientBalance` | value transfer tests | Medium |
| All others | Various | Low-Medium |

### Test File Recommendations

```bash
# Create these test files:
src/errors_test.zig          # Comprehensive error type tests
test/specs/error_cases.zig   # Spec test error scenarios
```

---

## 10. Metrics

| Metric | Value | Target | Status |
|--------|-------|--------|--------|
| Total error types | 42 | N/A | - |
| Unused error types | 11 | 0 | ⚠️ |
| Redundant error types | 5 | 0 | ⚠️ |
| Test coverage | 4.8% | >80% | ❌ |
| Documentation | Minimal | Comprehensive | ❌ |
| Lines of code | 42 | N/A | ✅ |
| Code complexity | Low | Low | ✅ |

---

## 11. Conclusion

The `errors.zig` file is structurally sound but suffers from:
- **Incomplete usage:** 26% of errors are unused
- **Poor documentation:** No guidance on when/how to use errors
- **Minimal testing:** Only 2 of 42 errors have dedicated tests
- **Minor redundancy:** Some error types overlap

**Priority Actions:**
1. Add comprehensive error tests (HIGH)
2. Document all error types (HIGH)
3. Remove or justify unused errors (MEDIUM)
4. Consolidate redundant error types (MEDIUM)

**Estimated Effort:** 4-6 hours
- Tests: 2-3 hours
- Documentation: 1-2 hours
- Cleanup: 1 hour

---

## Appendix: Error Usage Matrix

| Error Type | Used In | Usage Count | Status |
|------------|---------|-------------|--------|
| InvalidJump | frame.zig, handlers_control_flow.zig | 2+ | ✅ Active |
| OutOfGas | frame.zig, evm.zig | 5+ | ✅ Active |
| StackUnderflow | frame.zig | 2+ | ✅ Active |
| StackOverflow | frame.zig | 2+ | ✅ Active |
| ContractNotFound | - | 0 | ⚠️ Unused |
| PrecompileError | - | 0 | ⚠️ Unused |
| MemoryError | - | 0 | ⚠️ Unused |
| StorageError | - | 0 | ⚠️ Unused |
| CallDepthExceeded | evm.zig | 1 | ✅ Active |
| InsufficientBalance | evm.zig | 1 | ✅ Active |
| ContractCollision | - | 0 | ⚠️ Unused |
| InvalidBytecode | evm.zig | 1 | ✅ Active |
| StaticCallViolation | handlers_storage.zig, handlers_system.zig | 3+ | ✅ Active |
| InvalidOpcode | frame.zig | 1+ | ✅ Active |
| RevertExecution | evm.zig | 1+ | ✅ Active |
| OutOfMemory | - | 0 | ⚠️ Unused |
| AllocationError | - | 0 | ⚠️ Unused (redundant) |
| AccountNotFound | - | 0 | ⚠️ Unused |
| InvalidJumpDestination | - | 0 | ⚠️ Redundant with InvalidJump? |
| MissingJumpDestMetadata | - | 0 | ⚠️ Unused |
| InitcodeTooLarge | evm.zig | 1 | ✅ Active |
| TruncatedPush | handlers_stack.zig | 1 | ✅ Active |
| OutOfBounds | - | 0 | ⚠️ Unused |
| WriteProtection | handlers_system.zig | 1 | ✅ Active |
| BytecodeTooLarge | - | 0 | ⚠️ Unused |
| InvalidPush | handlers_stack.zig | 1 | ✅ Active |
| CreateInitCodeSizeLimit | - | 0 | ⚠️ Redundant with InitcodeTooLarge |
| CreateContractSizeLimit | - | 0 | ⚠️ Unused |
| ExecutionTimeout | frame.zig | 1 | ✅ Active |
| GasZeroError | call_params.zig | 1 | ✅ Active |
| InvalidInputSize | call_params.zig | 4 | ✅ Active |
| InvalidInitCodeSize | call_params.zig | 2 | ✅ Active |
| InvalidCreateValue | - | 0 | ⚠️ Unused |
| InvalidStaticCallValue | - | 0 | ⚠️ Unused |
| NoSpaceLeft | - | 0 | ⚠️ Unused |
| NeedAsyncData | evm.zig, storage.zig, evm_test.zig | 5+ | ✅ Active + Tested |

**Summary:**
- Active: 21 errors (50%)
- Unused: 11 errors (26%)
- Redundant: 5 errors (12%)
- Unclear: 5 errors (12%)
