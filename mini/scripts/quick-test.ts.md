# Code Review: quick-test.ts

## Overview

**File:** `/Users/williamcory/guillotine-mini/scripts/quick-test.ts`
**Purpose:** Quick smoke test runner for rapid iteration
**Lines of Code:** 56
**Language:** TypeScript (Bun runtime)

---

## Executive Summary

This is a simple smoke test utility designed for rapid verification during development. While functional, it lacks several features and best practices present in the codebase's other test utilities (particularly `test-subset.ts` and `isolate-test.ts`).

**Overall Assessment:** ⚠️ NEEDS IMPROVEMENT

**Key Issues:**
- Incomplete error handling and output parsing
- Limited user feedback and guidance
- Missing standard features (help text, test listing, flexible configuration)
- Hardcoded test selection without rationale
- No alignment with codebase testing patterns

---

## 1. Incomplete Features

### 1.1 Missing Help Documentation
**Severity:** Medium
**Location:** Lines 1-24

**Issue:**
The script lacks `--help` and `--list` flags present in similar utilities (`test-subset.ts`, `isolate-test.ts`). Users cannot discover:
- Usage patterns
- Available test configurations
- Purpose of hardcoded tests
- How to customize test selection

**Comparison with test-subset.ts:**
```typescript
// test-subset.ts has:
if (filter === '--help' || filter === '-h') {
  showHelp();
  process.exit(0);
}

if (filter === '--list' || filter === '-l') {
  await listTests();
  process.exit(0);
}
```

**Recommendation:**
Add `showHelp()` function with:
- Script purpose and use case
- Why these specific tests were chosen
- How to customize (CLI args or config file)
- Examples of typical workflows

---

### 1.2 Rigid Test Selection
**Severity:** Medium
**Location:** Lines 19-24

**Issue:**
Tests are hardcoded without:
- Justification for selection
- Ability to customize via CLI/env
- Coverage rationale (why these 3 tests?)

**Current code:**
```typescript
const tests = [
  'add',
  'push0',
  'transStorageOK',
];
```

**Questions:**
- Why `add` and not `mul` or `sub`?
- Why `transStorageOK` and not `transStorageReset`?
- Do these tests cover critical hardfork features?
- What percentage of opcodes/EIPs do they exercise?

**Recommendation:**
Either:
1. Document selection criteria in comments
2. Allow customization via CLI args: `bun scripts/quick-test.ts add,push0,custom_test`
3. Support config file: `quick-test.config.json`

---

### 1.3 Limited Output Analysis
**Severity:** Medium
**Location:** Lines 36-42

**Issue:**
Success detection is fragile and incomplete:

```typescript
if (output.includes('All 1 tests passed') || output.includes('tests passed')) {
  console.log(`  ${colors.GREEN}✓ Passed${colors.RESET}`);
  passed++;
} else {
  console.log(`  ${colors.RED}✗ Failed${colors.RESET}`);
  failed++;
}
```

**Problems:**
- No failure type detection (crash vs divergence vs gas error)
- No execution time reporting
- No partial success handling (e.g., 2/3 tests passed)
- Generic failure message without debugging hints

**Compare with isolate-test.ts:**
```typescript
// isolate-test.ts provides:
if (output.includes('segmentation fault')) {
  printWarning('Failure type: CRASH (Segmentation Fault)');
  // ... debugging guidance
} else if (output.match(/Trace divergence/i)) {
  printWarning('Failure type: BEHAVIOR DIVERGENCE');
  // ... divergence details
}
```

**Recommendation:**
Add failure analysis to provide:
- Failure categorization
- Quick debugging hints
- Reference to `isolate-test.ts` for detailed analysis

---

### 1.4 No Timing Information
**Severity:** Low
**Location:** Lines 29-49

**Issue:**
Script doesn't report execution time, making it hard to track performance regressions or optimization improvements.

**Recommendation:**
```typescript
const startTime = Date.now();
// ... run tests
const duration = Date.now() - startTime;
console.log(`Completed in ${duration}ms`);
```

---

### 1.5 Missing Verbose/Quiet Modes
**Severity:** Low
**Location:** Lines 32-46

**Issue:**
Always runs in quiet mode (`.quiet()`) with no option for verbose output when debugging.

**Recommendation:**
Add `--verbose` flag to show full test output:
```typescript
const verbose = args.includes('--verbose') || args.includes('-v');
const result = verbose
  ? await $`zig build specs -- --test-filter ${test}`.text()
  : await $`zig build specs -- --test-filter ${test}`.quiet();
```

---

## 2. TODOs and Comments

### 2.1 Missing Documentation
**Severity:** Low
**Location:** Lines 2-7

**Issue:**
Header comment is minimal. Should explain:
- Purpose: "Verify core functionality quickly before running full test suite"
- When to use: "Run after making changes to critical paths (opcodes, gas, storage)"
- What it doesn't do: "Not a replacement for full spec tests"
- Expected runtime: "~5-10 seconds"

---

### 2.2 No Inline Comments
**Severity:** Low
**Location:** Throughout

**Issue:**
Zero inline comments explaining logic. While the code is simple, key decisions should be documented:
- Why these 3 tests? (line 20-24)
- Why use `.quiet()` by default? (line 33)
- What does "tests passed" string match? (line 36)

---

## 3. Bad Code Practices

### 3.1 Error Swallowing
**Severity:** High
**Location:** Lines 43-46

**Critical Issue:**
```typescript
} catch (e) {
  console.log(`  ${colors.RED}✗ Failed${colors.RESET}`);
  failed++;
}
```

This violates the project's anti-pattern: **"❌ CRITICAL: Silently ignore errors with `catch {}`"** (from CLAUDE.md).

**Problems:**
- Exception details are lost
- No way to debug why the test command failed
- User gets generic "Failed" with zero context
- Could hide serious issues (missing Zig binary, corrupt test files, etc.)

**Correct approach:**
```typescript
} catch (e) {
  console.log(`  ${colors.RED}✗ Failed (command error)${colors.RESET}`);
  console.error('Error details:', e);
  failed++;
}
```

---

### 3.2 Inconsistent Error Handling
**Severity:** Medium
**Location:** Lines 32-46

**Issue:**
Test execution errors are caught but not differentiated from test failures. This conflates:
1. **Infrastructure errors** (Zig not found, build system failure)
2. **Test failures** (assertions failed, spec divergence)

**Recommendation:**
Check exit code explicitly:
```typescript
try {
  const result = await $`zig build specs -- --test-filter ${test}`.quiet();
  if (result.exitCode === 0) {
    // passed
  } else {
    // failed test (not infrastructure error)
  }
} catch (e) {
  // infrastructure/command error
  console.error('Command failed to execute:', e);
}
```

---

### 3.3 Magic String Matching
**Severity:** Medium
**Location:** Line 36

**Issue:**
```typescript
if (output.includes('All 1 tests passed') || output.includes('tests passed'))
```

Fragile string matching without:
- Regex for precise matching
- Handling of edge cases (0 tests, multiple tests with same name)
- Validation that exactly 1 test ran per iteration

**Better approach:**
```typescript
const passedMatch = output.match(/All (\d+) tests passed/);
const numPassed = passedMatch ? parseInt(passedMatch[1]) : 0;
if (numPassed === 1) {
  // success
}
```

---

### 3.4 Lack of Input Validation
**Severity:** Low
**Location:** Lines 19-24

**Issue:**
No validation that hardcoded test names:
- Actually exist in test suite
- Are properly formatted
- Will execute successfully

**Recommendation:**
Add startup validation or allow user to specify tests via args with validation.

---

## 4. Missing Test Coverage

### 4.1 No Unit Tests for Script
**Severity:** Low
**Context:** This is a utility script

**Issue:**
While not critical for a simple script, key functions could be tested:
- Output parsing logic
- Success/failure detection
- Color formatting

**Recommendation:**
If script complexity grows, extract testable functions:
```typescript
// quick-test.lib.ts
export function parseTestOutput(output: string): { passed: number, failed: number }
export function isTestPassed(output: string): boolean

// quick-test.test.ts
import { test, expect } from "bun:test";
import { isTestPassed } from "./quick-test.lib.ts";

test("detects test success", () => {
  expect(isTestPassed("All 1 tests passed")).toBe(true);
});
```

---

### 4.2 No Integration Testing
**Severity:** Low
**Location:** Overall script behavior

**Observation:**
Script isn't tested as part of CI/CD. Consider:
- Adding to `.github/workflows/` as pre-commit smoke test
- Verifying script exits with correct codes
- Ensuring output format is stable

---

## 5. Other Issues

### 5.1 Inconsistent Style with Codebase
**Severity:** Medium
**Location:** Overall structure

**Issue:**
Doesn't follow patterns from `test-subset.ts` and `isolate-test.ts`:

| Feature | test-subset.ts | isolate-test.ts | quick-test.ts |
|---------|---------------|-----------------|---------------|
| Help text | ✅ | ✅ | ❌ |
| Colored output | ✅ | ✅ | ✅ (partial) |
| Error categorization | ⚠️ | ✅ | ❌ |
| User guidance | ✅ | ✅ | ❌ |
| Header/banner | ✅ | ✅ | ❌ |
| Next steps section | ⚠️ | ✅ | ❌ |

**Recommendation:**
Adopt consistent structure:
1. Imports and types
2. Helper functions (colors, printing)
3. Argument parsing
4. Help/usage functions
5. Main execution
6. Results summary
7. Exit handling

---

### 5.2 No Progress Indication
**Severity:** Low
**Location:** Lines 29-49

**Issue:**
During execution, no progress indication. If tests hang or are slow, user has no feedback.

**Recommendation:**
Add progress:
```typescript
console.log(`[${i+1}/${tests.length}] Testing: ${test}`);
```

---

### 5.3 Missing Summary Statistics
**Severity:** Low
**Location:** Lines 51-53

**Issue:**
Summary is minimal:
```typescript
console.log(`Quick test summary: ${passed} passed, ${failed} failed`);
```

**Enhancement:**
Add:
- Success rate percentage
- Execution time
- Which tests failed (by name)
- Suggestion to run full suite if any failed

---

### 5.4 No Parallel Execution
**Severity:** Low
**Location:** Lines 29-49 (serial loop)

**Observation:**
Tests run sequentially. For 3 tests this is fine, but if list grows, parallel execution would help:

```typescript
const results = await Promise.all(
  tests.map(async (test) => {
    // run test
    return { test, passed: boolean };
  })
);
```

**Trade-off:** Parallel execution makes output harder to read but is faster.

---

### 5.5 Hardcoded Paths
**Severity:** Low
**Location:** Line 33

**Issue:**
Assumes `zig build specs` is correct command. Doesn't handle:
- Custom build directories
- Different Zig versions
- Build system variations

**Recommendation:**
Make configurable via environment:
```typescript
const buildCmd = process.env.BUILD_COMMAND || 'zig build specs';
```

---

## 6. Security Considerations

### 6.1 Command Injection Risk
**Severity:** Medium
**Location:** Line 33

**Issue:**
If test names were user-provided (future enhancement), this would be vulnerable:
```typescript
await $`zig build specs -- --test-filter ${test}`.quiet();
```

**Current Status:** Safe because tests are hardcoded.

**Future-proofing:**
If allowing user input:
```typescript
// Validate test name format
if (!/^[a-zA-Z0-9_-]+$/.test(test)) {
  throw new Error('Invalid test name format');
}
```

---

## 7. Performance Considerations

### 7.1 Startup Overhead
**Severity:** Low
**Location:** Overall script

**Observation:**
Script starts Zig build system 3 times sequentially. For quick iteration, this is fine, but could be optimized by:
1. Running all tests in single Zig invocation
2. Using Zig's built-in filtering: `--test-filter "add|push0|transStorageOK"`

**Trade-off:** Single invocation is faster but provides less granular pass/fail info.

---

## Recommendations Summary

### Critical (Fix Immediately)
1. **Fix error swallowing** - Never silently catch exceptions (violates project anti-pattern)
2. **Add help text** - Users need to understand purpose and usage

### High Priority
3. **Add failure analysis** - Categorize failures like `isolate-test.ts` does
4. **Document test selection** - Explain why these 3 tests were chosen
5. **Allow customization** - Support CLI args for test selection

### Medium Priority
6. **Improve error handling** - Distinguish infrastructure errors from test failures
7. **Add timing information** - Track execution duration
8. **Consistent style** - Match patterns from `test-subset.ts` and `isolate-test.ts`

### Low Priority (Nice to Have)
9. **Add verbose mode** - Option for detailed output
10. **Progress indication** - Show which test is running
11. **Enhanced summary** - Include success rate, failed test names
12. **Input validation** - Verify test names exist

---

## Suggested Improvements (Code Snippets)

### Improvement 1: Add Help Text
```typescript
function showHelp() {
  console.log(`Quick Test Runner - Fast smoke tests for rapid iteration

PURPOSE:
    Runs a minimal set of representative tests to verify core functionality
    before running the full test suite. Designed for fast feedback during
    active development.

USAGE:
    bun scripts/quick-test.ts [options]

OPTIONS:
    --help, -h          Show this help message
    --verbose, -v       Show full test output
    --tests <list>      Comma-separated test names (default: add,push0,transStorageOK)

EXAMPLES:
    # Run default smoke tests
    bun scripts/quick-test.ts

    # Run with custom tests
    bun scripts/quick-test.ts --tests "add,mul,sstore"

    # Run with verbose output
    bun scripts/quick-test.ts --verbose

TEST SELECTION:
    Default tests were chosen to cover:
    - Arithmetic operations (add): Frontier-era baseline
    - Stack operations (push0): Shanghai hardfork feature (EIP-3855)
    - Transient storage (transStorageOK): Cancun hardfork feature (EIP-1153)

    These 3 tests exercise critical paths across multiple hardforks.

NOTES:
    - Expected runtime: ~5-10 seconds
    - Not a replacement for 'zig build test' or 'zig build specs'
    - For detailed debugging, use 'bun scripts/isolate-test.ts <test_name>'
`);
}
```

### Improvement 2: Enhanced Error Handling
```typescript
try {
  const result = await $`zig build specs -- --test-filter ${test}`.quiet();
  const output = result.text();

  // Check explicit success patterns
  const passedMatch = output.match(/All (\d+) tests passed/);
  const numPassed = passedMatch ? parseInt(passedMatch[1]) : 0;

  if (numPassed >= 1) {
    console.log(`  ${colors.GREEN}✓ Passed${colors.RESET}`);
    passed++;
  } else {
    console.log(`  ${colors.RED}✗ Failed${colors.RESET}`);

    // Categorize failure type
    if (output.includes('segmentation fault')) {
      console.log(`    Crash detected - run: bun scripts/isolate-test.ts "${test}"`);
    } else if (output.match(/Trace divergence/i)) {
      console.log(`    Behavior divergence - check trace output`);
    } else if (output.match(/gas.*mismatch/i)) {
      console.log(`    Gas calculation error`);
    }

    failed++;
  }
} catch (e) {
  console.log(`  ${colors.RED}✗ Command Error${colors.RESET}`);
  console.error(`    Failed to execute test command: ${e}`);
  console.error(`    Check that 'zig build specs' works correctly`);
  failed++;
}
```

### Improvement 3: CLI Argument Support
```typescript
const args = process.argv.slice(2);

// Parse flags
const showHelp = args.includes('--help') || args.includes('-h');
const verbose = args.includes('--verbose') || args.includes('-v');

// Parse custom test list
const testsIdx = args.indexOf('--tests');
const tests = testsIdx >= 0 && args[testsIdx + 1]
  ? args[testsIdx + 1].split(',')
  : ['add', 'push0', 'transStorageOK'];

if (showHelp) {
  showHelp();
  process.exit(0);
}

console.log(`Running tests: ${tests.join(', ')}\n`);
```

---

## Comparison with Similar Tools

### vs. test-subset.ts
| Aspect | test-subset.ts | quick-test.ts | Winner |
|--------|---------------|---------------|--------|
| Purpose | Filter and run test categories | Run hardcoded smoke tests | Different use cases |
| Flexibility | High (any filter) | Low (3 hardcoded tests) | test-subset.ts |
| User guidance | Excellent | Minimal | test-subset.ts |
| Output detail | Full test output | Quiet mode only | test-subset.ts |
| Speed | Slower (more tests) | Faster (3 tests) | quick-test.ts |

**Recommendation:** These tools should be complementary. `quick-test.ts` should focus on speed, but adopt UX patterns from `test-subset.ts`.

### vs. isolate-test.ts
| Aspect | isolate-test.ts | quick-test.ts | Winner |
|--------|-----------------|---------------|--------|
| Purpose | Deep dive single test | Quick smoke test | Different use cases |
| Analysis | Extensive (7 steps) | Minimal | isolate-test.ts |
| Debugging | Trace comparison, guidance | Pass/fail only | isolate-test.ts |
| Batch testing | No | Yes (3 tests) | quick-test.ts |

**Recommendation:** `quick-test.ts` should refer users to `isolate-test.ts` when failures occur.

---

## Suggested Workflow Integration

```
Developer workflow:
1. Make code change
2. Run `bun scripts/quick-test.ts` (5-10 sec)
   └─ If fails → Run `bun scripts/isolate-test.ts <test_name>` for analysis
3. Run `bun scripts/test-subset.ts <relevant_category>` (30-60 sec)
4. Run `zig build test` (full suite)
5. Commit
```

`quick-test.ts` should be positioned as the first line of defense with clear escalation paths.

---

## Conclusion

**Current State:** Functional but basic utility that does one thing well (fast smoke tests) but lacks polish and features present in similar tools.

**Effort to Improve:** Low-to-medium. Most issues are additive (add help, add error analysis) rather than requiring refactoring.

**Priority:** Medium. Not critical (script works), but improvements would significantly enhance developer experience and consistency with codebase standards.

**Key Action Items:**
1. Fix error swallowing (critical anti-pattern violation)
2. Add help documentation (user discoverability)
3. Enhance failure reporting (debugging efficiency)
4. Document test selection rationale (maintainability)

**Estimated Improvement Time:** 2-3 hours for high-priority fixes, 4-6 hours for complete overhaul matching `isolate-test.ts` quality.
