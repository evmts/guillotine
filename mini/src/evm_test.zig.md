# Code Review: evm_test.zig

**Reviewed**: 2025-10-26
**File**: `/Users/williamcory/guillotine-mini/src/evm_test.zig`
**Lines**: 246 total
**Purpose**: Unit tests for evm.zig - specifically testing async data request functionality and callOrContinue API

---

## Executive Summary

This is a focused test file covering async execution patterns for the EVM's storage injection system. The tests are well-structured and cover the critical async data request mechanism. However, the test coverage is **extremely narrow** relative to the complexity of the 1926-line `evm.zig` implementation.

**Key Findings**:
- **Critical**: Test coverage is ~5% of evm.zig functionality
- **Important**: No tests for error conditions, edge cases, or failure modes
- **Moderate**: Tests are tightly coupled to implementation details
- **Low**: Missing documentation of test scenarios

**Overall Assessment**: 4/10 - Minimal viable testing for async features only

**Test Coverage Status**:
```
✅ Async data requests (storage only)
✅ CallOrContinueInput/Output union types
❌ Balance async requests (defined but untested)
❌ Code async requests (defined but untested)
❌ Nonce async requests (defined but untested)
❌ Error propagation and recovery
❌ Call depth limits
❌ Gas accounting
❌ Storage refunds
❌ Nested calls (CALL/DELEGATECALL/STATICCALL)
❌ CREATE/CREATE2 operations
❌ Precompile execution
❌ Access list management
❌ Warm/cold storage tracking
❌ Transient storage (EIP-1153)
❌ SELFDESTRUCT handling
❌ Balance snapshots and rollback
❌ Hardfork-specific behavior
❌ Edge cases and boundary conditions
```

---

## 1. Incomplete Features

### 1.1 Async Data Request - Only Storage Tested (Lines 11-246)

**Issue**: While `AsyncDataRequest` supports 5 variants (`none`, `storage`, `balance`, `code`, `nonce`), only `storage` and `none` are tested.

```zig
// Lines 19-47: Only storage, balance, code, nonce field access tested
// Lines 178-207: Only storage async flow tested
// Lines 209-245: Only storage continuation tested
```

**Missing Test Coverage**:
- `need_balance` → `continue_with_balance` flow
- `need_code` → `continue_with_code` flow
- `need_nonce` → `continue_with_nonce` flow
- Multiple async requests in sequence (storage → balance → code)
- Concurrent async requests
- Async request during nested call

**Impact**: 80% of async data types have zero integration test coverage.

**Recommendation**:
```zig
test "callOrContinue - balance async request and resume" { /* ... */ }
test "callOrContinue - code async request and resume" { /* ... */ }
test "callOrContinue - nonce async request and resume" { /* ... */ }
test "callOrContinue - multiple async requests in sequence" { /* ... */ }
test "callOrContinue - async request during nested call" { /* ... */ }
```

### 1.2 Error Handling - No Failure Tests (Lines 70-102)

**Issue**: Lines 70-102 test that `NeedAsyncData` error can be caught and propagated, but there are no tests for:
- What happens when async data is invalid (e.g., wrong slot number)
- What happens when storage injector fails
- What happens when cache is corrupted
- Recovery from partial execution state

**Missing Test Coverage**:
```zig
// No tests for:
test "callOrContinue - invalid storage continuation data" { /* ... */ }
test "callOrContinue - storage injector allocation failure" { /* ... */ }
test "callOrContinue - corrupt async_data_request state" { /* ... */ }
test "callOrContinue - resume with wrong request type" { /* ... */ }
```

**Impact**: Zero validation that error paths work correctly.

**Recommendation**: Add comprehensive error testing for all failure modes documented in `errors.zig`.

### 1.3 Gas Accounting - No Tests (0 coverage)

**Issue**: `evm.zig` has extensive gas accounting logic (`gas_refund`, `accessAddress`, `accessStorageSlot`, warm/cold tracking), but `evm_test.zig` has zero tests for:
- Gas consumption during async operations
- Gas refunds calculation
- Gas limits enforcement
- Out of gas during async resume
- EIP-2929 warm/cold access tracking

**Impact**: Critical gas metering bugs could go undetected.

**Recommendation**:
```zig
test "callOrContinue - gas tracking across async boundary" { /* ... */ }
test "callOrContinue - out of gas during storage resume" { /* ... */ }
test "warm/cold storage access with async injection" { /* ... */ }
test "gas refunds with async storage operations" { /* ... */ }
```

### 1.4 Nested Call Execution - No Tests (0 coverage)

**Issue**: `evm.zig` implements complex nested call logic (`inner_call`, `inner_create`, max depth 1024), but there are no tests for:
- Async requests during CALL operations
- Async requests during CREATE operations
- Call depth tracking with async suspension/resume
- Storage state isolation between nested calls
- Rollback behavior on failed nested calls

**Impact**: Nested call bugs are high-probability, high-severity issues.

**Recommendation**:
```zig
test "callOrContinue - async storage during nested CALL" { /* ... */ }
test "callOrContinue - async during CREATE with storage writes" { /* ... */ }
test "callOrContinue - call depth exceeded with async" { /* ... */ }
test "callOrContinue - nested call rollback with async state" { /* ... */ }
```

### 1.5 Hardfork-Specific Behavior - No Tests (0 coverage)

**Issue**: `evm.zig` has extensive hardfork support (Berlin through Prague), but no tests verify:
- Async operations under different hardforks
- EIP-2929 cold access costs with async injection
- EIP-1153 transient storage with async
- Hardfork transitions during async execution

**Impact**: Hardfork-specific regressions could break spec compliance.

**Recommendation**:
```zig
test "callOrContinue - Berlin warm/cold tracking with async" { /* ... */ }
test "callOrContinue - Cancun transient storage not cleared on async" { /* ... */ }
test "callOrContinue - hardfork transition during async execution" { /* ... */ }
```

---

## 2. TODOs and Incomplete Work

### 2.1 No TODOs Found ✅

**Analysis**: Grep for `TODO|FIXME|XXX|HACK` returned no matches.

**Status**: PASS - No outstanding TODO items.

---

## 3. Bad Code Practices

### 3.1 Magic Values - Hardcoded Test Data (Throughout)

**Issue**: Repeated use of hardcoded hex addresses without constants:

```zig
// Lines 19, 56, 119, 142, 188, 218
const addr = primitives.Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
const addr = primitives.Address.fromHex("0xabcdef0123456789abcdef0123456789abcdef01") catch unreachable;
const addr = primitives.Address.fromHex("0x1111111111111111111111111111111111111111") catch unreachable;
```

**Impact**: Readability and maintainability issues.

**Recommendation**:
```zig
const TEST_ADDRESS_1 = primitives.Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
const TEST_ADDRESS_2 = primitives.Address.fromHex("0xabcdef0123456789abcdef0123456789abcdef01") catch unreachable;
const ZERO_ADDRESS = primitives.Address.fromHex("0x1111111111111111111111111111111111111111") catch unreachable;
```

### 3.2 Catch Unreachable - Silent Error Suppression (8 instances)

**Issue**: All `catch unreachable` usages assume address parsing never fails:

```zig
// Lines 19, 56, 119, 142, 188, 218
const addr = primitives.Address.fromHex("0x...") catch unreachable;
```

**Problem**: If address parsing logic changes or test data is invalid, tests will panic instead of failing gracefully.

**Impact**: Debugging difficulty when address format changes.

**Recommendation**: Use constants (see 3.1) or handle errors properly:
```zig
const addr = primitives.Address.fromHex("0x...") catch |err| {
    return testing.unexpectedError(err, "Invalid test address");
};
```

### 3.3 Inconsistent Test Naming (Lines 11-246)

**Issue**: Test names follow multiple patterns:
- `test "AsyncDataRequest - union size and field access"` (Component - description)
- `test "error.NeedAsyncData can be caught and identified"` (error.Type description)
- `test "Evm.async_data_request field initialized to .none"` (Type.field description)
- `test "callOrContinue - returns .need_storage on cache miss"` (method - behavior)

**Impact**: Inconsistent test discovery and organization.

**Recommendation**: Standardize on pattern:
```zig
test "AsyncDataRequest: union size and field access" { /* ... */ }
test "AsyncDataRequest: can write and read each variant" { /* ... */ }
test "CallError.NeedAsyncData: can be caught and identified" { /* ... */ }
test "Evm.async_data_request: initialized to .none" { /* ... */ }
test "Evm.callOrContinue: returns need_storage on cache miss" { /* ... */ }
```

### 3.4 Tight Coupling to Implementation Details (Lines 178-207)

**Issue**: Test constructs raw bytecode instead of using higher-level abstractions:

```zig
// Line 191-192
const bytecode = [_]u8{ 0x60, 0x00, 0x54 }; // PUSH1 0, SLOAD
```

**Problem**: Test breaks if opcode encodings change or new opcodes are added.

**Impact**: Brittle tests requiring updates for unrelated changes.

**Recommendation**: Use bytecode builder or opcode constants:
```zig
const opcodes = @import("opcode.zig");
const bytecode = [_]u8{
    opcodes.PUSH1, 0x00,
    opcodes.SLOAD,
};
// Or use a bytecode builder:
var builder = BytecodeBuilder.init(testing.allocator);
try builder.push1(0x00);
try builder.op(.SLOAD);
const bytecode = try builder.build();
```

### 3.5 Incomplete Test Cleanup (Lines 107-133, 182-245)

**Issue**: Tests initialize EVM but don't fully clean up state:

```zig
// Lines 107-111
var evm_instance = try Evm.init(testing.allocator, null, null, null, null);
defer evm_instance.deinit();
```

**Problem**: If test panics before `defer`, allocator may leak.

**Impact**: Test suite memory leaks accumulate.

**Recommendation**: Use `errdefer` for cleanup:
```zig
var evm_instance = try Evm.init(testing.allocator, null, null, null, null);
defer evm_instance.deinit();
errdefer evm_instance.deinit(); // Redundant but explicit
```
Or use test.allocDetector to catch leaks.

### 3.6 No Test Documentation (Lines 11-246)

**Issue**: Zero documentation comments explaining:
- Test purpose and scope
- Expected behavior being verified
- Relationship to specifications (EIPs)
- Why certain values are chosen

**Example from line 178**:
```zig
test "callOrContinue - returns .need_storage on cache miss" {
    // No documentation explaining:
    // - What scenario this represents
    // - Why this behavior matters
    // - What EIP or spec requires this
```

**Impact**: Future maintainers cannot understand test intent.

**Recommendation**:
```zig
/// Test that EVM correctly yields with .need_storage when storage injector
/// cache misses during SLOAD execution. This is part of the async execution
/// model where EVM yields control to host for data fetching.
///
/// Scenario: Execute SLOAD on slot 0 with empty cache
/// Expected: callOrContinue returns .need_storage with correct slot
test "callOrContinue - returns .need_storage on cache miss" {
```

---

## 4. Missing Test Coverage

### 4.1 Core EVM Operations (0% coverage)

**Missing Tests**:
```zig
test "Evm.init - proper initialization of all fields" { /* ... */ }
test "Evm.deinit - no memory leaks" { /* ... */ }
test "Evm.initTransactionState - clears transient storage" { /* ... */ }
test "Evm.accessAddress - warm tracking" { /* ... */ }
test "Evm.accessStorageSlot - cold access costs" { /* ... */ }
test "Evm.setBalanceWithSnapshot - snapshot creation" { /* ... */ }
test "Evm.computeCreateAddress - nonce-based addressing" { /* ... */ }
test "Evm.computeCreate2Address - salt-based addressing" { /* ... */ }
test "Evm.preWarmTransaction - access list processing" { /* ... */ }
```

### 4.2 Call Operations (0% coverage)

**Missing Tests**:
```zig
test "Evm.call - basic execution" { /* ... */ }
test "Evm.inner_call - CALL opcode" { /* ... */ }
test "Evm.inner_call - DELEGATECALL preserves caller" { /* ... */ }
test "Evm.inner_call - STATICCALL prevents state changes" { /* ... */ }
test "Evm.inner_call - value transfer with insufficient balance" { /* ... */ }
test "Evm.inner_call - call depth exceeded" { /* ... */ }
test "Evm.inner_call - precompile execution" { /* ... */ }
```

### 4.3 CREATE Operations (0% coverage)

**Missing Tests**:
```zig
test "Evm.inner_create - CREATE opcode" { /* ... */ }
test "Evm.inner_create - CREATE2 with salt" { /* ... */ }
test "Evm.inner_create - init code size limit (EIP-3860)" { /* ... */ }
test "Evm.inner_create - contract size limit" { /* ... */ }
test "Evm.inner_create - address collision" { /* ... */ }
test "Evm.inner_create - 0xEF prefix rejection (EIP-3541)" { /* ... */ }
```

### 4.4 Storage Operations (Limited coverage)

**Existing**: Only async cache miss/hit (lines 178-245)

**Missing Tests**:
```zig
test "Storage.get - persistent storage" { /* ... */ }
test "Storage.set - original value tracking" { /* ... */ }
test "Storage.get_transient - EIP-1153" { /* ... */ }
test "Storage.set_transient - cleared at transaction end" { /* ... */ }
test "Storage - dirty flag tracking for injector" { /* ... */ }
```

### 4.5 Gas Refunds (0% coverage)

**Missing Tests**:
```zig
test "Evm.add_refund - accumulation" { /* ... */ }
test "Evm.sub_refund - subtraction below zero" { /* ... */ }
test "gas refunds - SSTORE clear refund" { /* ... */ }
test "gas refunds - capped at 1/5 (London+)" { /* ... */ }
test "gas refunds - capped at 1/2 (pre-London)" { /* ... */ }
```

### 4.6 Access List Management (0% coverage)

**Missing Tests**:
```zig
test "AccessListManager.snapshot - create snapshot" { /* ... */ }
test "AccessListManager.restore - rollback state" { /* ... */ }
test "AccessListManager - address warm tracking" { /* ... */ }
test "AccessListManager - storage slot warm tracking" { /* ... */ }
```

### 4.7 SELFDESTRUCT Handling (0% coverage)

**Missing Tests**:
```zig
test "SELFDESTRUCT - EIP-6780 same transaction only" { /* ... */ }
test "SELFDESTRUCT - balance transfer" { /* ... */ }
test "SELFDESTRUCT - account tracking" { /* ... */ }
test "SELFDESTRUCT - rollback on revert" { /* ... */ }
```

### 4.8 Hardfork Behavior (0% coverage)

**Missing Tests**:
```zig
test "Evm.getActiveFork - static fork" { /* ... */ }
test "Evm.getActiveFork - fork transition" { /* ... */ }
test "hardfork - Berlin warm/cold gas costs" { /* ... */ }
test "hardfork - London gas refund cap" { /* ... */ }
test "hardfork - Shanghai PUSH0" { /* ... */ }
test "hardfork - Cancun transient storage" { /* ... */ }
test "hardfork - Prague BLS precompiles" { /* ... */ }
```

### 4.9 Tracing (0% coverage)

**Missing Tests**:
```zig
test "Evm.setTracer - trace capture" { /* ... */ }
test "tracing - EIP-3155 format" { /* ... */ }
test "tracing - step-by-step execution" { /* ... */ }
```

### 4.10 Edge Cases and Boundary Conditions (0% coverage)

**Missing Tests**:
```zig
test "empty bytecode execution" { /* ... */ }
test "bytecode ending with PUSH (truncated)" { /* ... */ }
test "maximum call depth (1024)" { /* ... */ }
test "maximum stack size (1024)" { /* ... */ }
test "maximum memory expansion" { /* ... */ }
test "zero gas limit" { /* ... */ }
test "integer overflow in gas calculations" { /* ... */ }
test "storage key collision" { /* ... */ }
test "concurrent state modifications" { /* ... */ }
```

---

## 5. Other Issues

### 5.1 Test Organization - No Test Suites

**Issue**: All tests are flat in a single file with no grouping or hierarchy.

**Impact**: Difficult to run specific categories of tests.

**Recommendation**: Organize tests by feature area:
```zig
// Async Data Request Tests
test "AsyncDataRequest: ..." { /* ... */ }
// ... more async tests

// CallOrContinue API Tests
test "Evm.callOrContinue: ..." { /* ... */ }
// ... more API tests

// Integration Tests
test "Integration: storage async with nested calls" { /* ... */ }
```

Or use separate test files:
- `evm_test_async.zig` - Async execution tests
- `evm_test_calls.zig` - Call/create tests
- `evm_test_storage.zig` - Storage tests
- `evm_test_gas.zig` - Gas metering tests
- `evm_test_hardfork.zig` - Hardfork-specific tests

### 5.2 No Performance Tests

**Issue**: Zero tests measuring:
- Execution speed
- Memory usage
- Cache hit rates
- Async overhead

**Impact**: Performance regressions go undetected.

**Recommendation**:
```zig
test "performance - 1000 storage operations" {
    const start = std.time.nanoTimestamp();
    // ... execute operations
    const end = std.time.nanoTimestamp();
    const duration_ms = @divTrunc(end - start, 1_000_000);
    try testing.expect(duration_ms < 100); // Max 100ms
}
```

### 5.3 No Property-Based Tests

**Issue**: All tests use fixed inputs, no randomized/fuzz testing.

**Impact**: Edge cases not explored systematically.

**Recommendation**: Add property-based tests:
```zig
test "property - storage round trip preserves value" {
    var prng = std.Random.DefaultPrng.init(12345);
    const rand = prng.random();

    for (0..1000) |_| {
        const addr = generateRandomAddress(rand);
        const slot = rand.int(u256);
        const value = rand.int(u256);

        try storage.set(addr, slot, value);
        const retrieved = try storage.get(addr, slot);
        try testing.expectEqual(value, retrieved);
    }
}
```

### 5.4 No Integration with ethereum/tests

**Issue**: Tests are unit-only, not validating against official Ethereum test fixtures.

**Impact**: Spec compliance not verified at unit test level.

**Recommendation**: Reference `test/specs/runner.zig` patterns for integration tests:
```zig
test "Integration: ethereum/tests GeneralStateTest sample" {
    // Load a simple state test fixture
    // Execute with EVM
    // Verify post-state matches expected
}
```

### 5.5 Test Data Management - No Fixtures

**Issue**: Test data is inline in test functions, duplicated across tests.

**Impact**: Changes to test scenarios require updating multiple locations.

**Recommendation**: Create test fixtures:
```zig
const TestFixtures = struct {
    const simple_storage_read = [_]u8{ 0x60, 0x00, 0x54 }; // PUSH1 0, SLOAD
    const simple_storage_write = [_]u8{ 0x60, 0x2A, 0x60, 0x00, 0x55 }; // PUSH1 42, PUSH1 0, SSTORE
    const nested_call = [_]u8{ /* ... */ };
};
```

### 5.6 Async Test Reliability

**Issue**: Lines 209-245 test async continuation, but there's no verification of:
- Execution state preservation across yield points
- Stack integrity after resume
- Memory integrity after resume
- PC (program counter) correctness after resume

**Impact**: Silent state corruption during async operations.

**Recommendation**:
```zig
test "callOrContinue - state preservation across async boundary" {
    // 1. Execute until yield, capture state
    const state_before = captureEvmState(&evm_instance);

    // 2. Yield for storage
    const output1 = try evm_instance.callOrContinue(...);
    try testing.expect(output1 == .need_storage);

    // 3. Resume and verify state consistency
    const output2 = try evm_instance.callOrContinue(...);
    const state_after = captureEvmState(&evm_instance);

    try verifyStatePreservation(state_before, state_after);
}
```

---

## 6. Specific Line-by-Line Issues

### Line 16, 24, 26, 32, 33, 39, 40, 46, 47: Testing Enum Equality

```zig
try testing.expect(req_none == .none);
try testing.expect(req_storage == .storage);
```

**Issue**: These tests verify tagged union discrimination, which is already guaranteed by Zig's type system.

**Value**: Minimal - these tests don't add meaningful coverage.

**Recommendation**: Keep but add comment explaining this tests the public API stability, not type safety.

### Lines 191, 221: Raw Bytecode in Tests

```zig
const bytecode = [_]u8{ 0x60, 0x00, 0x54 }; // PUSH1 0, SLOAD
const bytecode = [_]u8{ 0x60, 0x00, 0x54, 0x00 }; // PUSH1 0, SLOAD, STOP
```

**Issue**: Magic numbers with comments describing opcodes.

**Recommendation**: Use named constants (see 3.4).

### Line 244: Ambiguous Test Assertion

```zig
try testing.expect(output2 == .ready_to_commit or output2 == .result);
```

**Problem**: Test passes for two different outcomes without validating which is correct.

**Impact**: Test doesn't verify expected behavior precisely.

**Recommendation**: Determine which outcome is correct and test for it:
```zig
// If storage injector is present, should be ready_to_commit
if (evm_instance.storage.storage_injector != null) {
    try testing.expect(output2 == .ready_to_commit);
} else {
    try testing.expect(output2 == .result);
}
```

---

## 7. Recommendations Summary

### Priority 1 (Critical) - Must Fix
1. **Expand test coverage to minimum 20%** of evm.zig functionality
   - Add tests for call operations (inner_call, inner_create)
   - Add tests for gas accounting and refunds
   - Add tests for error conditions and recovery
   - Add tests for all async data request types

2. **Add integration tests** with ethereum/tests fixtures
   - Select 10-20 simple GeneralStateTests
   - Verify end-to-end execution correctness

3. **Fix ambiguous test assertions** (line 244)
   - Make test expectations deterministic

### Priority 2 (Important) - Should Fix
4. **Add test documentation** explaining test purpose and scope
   - Document what behavior is being verified
   - Link to relevant EIPs where applicable

5. **Add error handling tests** for all failure modes
   - Invalid async data
   - Storage injector failures
   - Out of gas conditions
   - Call depth exceeded

6. **Organize tests into logical groups** or separate files
   - Async tests
   - Call tests
   - Storage tests
   - Gas tests

### Priority 3 (Nice to Have) - Consider Fixing
7. **Extract test constants** for addresses and bytecode
   - Replace hardcoded hex values
   - Use named constants for opcodes

8. **Add property-based tests** for storage operations
   - Fuzz test with random addresses/slots/values

9. **Add performance benchmarks**
   - Track execution time
   - Track memory usage
   - Track cache hit rates

10. **Add state preservation tests** across async boundaries
    - Verify stack/memory/PC integrity

---

## 8. Test Coverage Metrics

**Current Coverage** (estimated):
- Lines covered: ~50 / 1926 (2.6%)
- Functions tested: 3 / 43 (7.0%)
  - ✅ `Evm.init` (partial)
  - ✅ `callOrContinue` (partial - storage only)
  - ✅ `executeUntilYieldOrComplete` (indirect)
  - ❌ All other 40+ public methods

**Recommended Minimum Coverage**:
- Lines: 40% (770 lines)
- Functions: 60% (26 functions)
- Branches: 50%

**Critical Untested Areas** (by risk):
1. **High Risk**: Call operations (inner_call, inner_create) - 0% coverage
2. **High Risk**: Gas accounting and refunds - 0% coverage
3. **High Risk**: Error handling and recovery - 0% coverage
4. **Medium Risk**: Storage operations (non-async) - 0% coverage
5. **Medium Risk**: Access list management - 0% coverage
6. **Medium Risk**: Hardfork-specific behavior - 0% coverage

---

## 9. Positive Aspects

### What This File Does Well ✅

1. **Clear test structure** - Tests are readable and follow consistent patterns within each section

2. **Proper resource cleanup** - Uses `defer evm_instance.deinit()` consistently

3. **Tagged union testing** - Thoroughly tests `AsyncDataRequest` union field access

4. **Error propagation verification** - Tests that `NeedAsyncData` error propagates correctly through call stack (lines 83-102)

5. **Focused scope** - Tests are focused on specific async execution functionality without sprawl

6. **Real-world async pattern** - Tests a realistic async storage injection scenario (lines 178-245)

---

## 10. Conclusion

The `evm_test.zig` file provides a **minimal foundation** for testing async execution features but is **critically incomplete** for a production EVM implementation. With only ~3% coverage of the parent module, most EVM functionality remains untested at the unit level.

**Key Actions Required**:
1. Immediately add tests for high-risk areas (calls, creates, gas, errors)
2. Expand async tests to cover balance/code/nonce requests
3. Add comprehensive error handling tests
4. Establish test coverage metrics and track them
5. Add integration tests with ethereum/tests

**Estimated Effort**:
- Priority 1 fixes: 20-30 hours
- Priority 2 fixes: 10-15 hours
- Priority 3 fixes: 5-10 hours
- Total: 35-55 hours to reach adequate test coverage

**Risk Assessment**:
Current risk level: **HIGH** - Critical EVM functionality has zero unit test coverage. Spec test suite may catch some issues, but unit tests are essential for:
- Fast feedback during development
- Isolating bugs to specific functions
- Regression prevention
- Documentation of expected behavior

---

**Document Version**: 1.0
**Next Review**: After expanding test coverage to 20%+ of evm.zig
