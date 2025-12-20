# Code Review: debug-test.ts

**Review Date:** 2025-10-26
**File:** `/Users/williamcory/guillotine-mini/scripts/debug-test.ts`
**Purpose:** Debug script for running specific tests with trace output

---

## Executive Summary

The `debug-test.ts` script is a functional utility for debugging specific EVM tests, but it has several areas that need improvement. The script lacks proper error handling, has limited functionality compared to its sister script `isolate-test.ts`, and contains some inconsistencies in design. While it works for basic use cases, it could be significantly enhanced to provide better developer experience and more robust operation.

**Overall Rating:** 6/10 (Functional but needs improvement)

---

## 1. Incomplete Features

### 1.1 Limited Analysis Capabilities
**Severity:** Medium

The script runs tests but provides minimal analysis compared to `isolate-test.ts`:

```typescript
// debug-test.ts (lines 144-147)
if (exitCode !== 0) {
  console.log('\n💡 Tip: For detailed trace analysis, use:');
  console.log(`   bun scripts/isolate-test.ts "${testName}"`);
}
```

**Issues:**
- No failure type detection (crash/gas/behavior)
- No trace divergence analysis
- No automatic extraction of test file location
- Simply redirects users to another script instead of providing value

**Recommendation:** Either enhance this script to provide meaningful analysis or clarify its specific use case that differs from `isolate-test.ts`. The two scripts have significant overlap in purpose.

### 1.2 No Test Discovery
**Severity:** Low

Unlike `isolate-test.ts` which searches for test files (lines 107-117), `debug-test.ts` doesn't help users find tests before running them.

**Recommendation:** Add a search feature similar to `isolate-test.ts`:
```typescript
// Example enhancement
if (existsSync('ethereum-tests/GeneralStateTests')) {
  console.log(`Tests matching '${testName}':`);
  const result = await $`find ethereum-tests/GeneralStateTests -name "*.json" -exec grep -l ${testName} {} \\;`.quiet();
  // Display results
}
```

### 1.3 No Output Capture for Post-Processing
**Severity:** Medium

The script uses `inherit` for stdout/stderr which means it can't analyze the output:

```typescript
// Lines 130-137
const proc = Bun.spawn(command, {
  stdout: 'inherit',  // Can't capture for analysis
  stderr: 'inherit',  // Can't capture for analysis
  env: {
    ...process.env,
    TEST_FILTER: testName,
  },
});
```

This prevents any post-test analysis or reporting.

**Recommendation:** Capture output to enable analysis (see `isolate-test.ts` lines 130-155 for example).

---

## 2. TODOs and Missing Documentation

### 2.1 No Inline TODOs
**Status:** ✓ Good

No TODO comments found in the code, which is positive.

### 2.2 Documentation Gaps
**Severity:** Low

The header documentation is comprehensive (lines 2-39), but some aspects could be clearer:

1. **Purpose differentiation:** The doc doesn't explain why someone would use this script vs `isolate-test.ts`
2. **Suite listing completeness:** The `--list` output (lines 78-115) is extensive but hardcoded and may drift from actual available suites
3. **Environment variables:** No mention that other environment variables might affect test execution

**Recommendation:**
- Add a "When to use this script vs isolate-test.ts" section
- Generate suite list dynamically from build.zig or source of truth
- Document all relevant environment variables (TEST_FILTER, etc.)

---

## 3. Bad Code Practices

### 3.1 Hardcoded Suite Information
**Severity:** Medium
**Location:** Lines 78-115

```typescript
if (showList) {
  console.log('Available test suites (use with --suite flag):\n');
  console.log('Berlin:');
  console.log('  - berlin-acl, berlin-intrinsic-gas-cost, ...');
  // ... 35+ lines of hardcoded suite names
}
```

**Issues:**
- Maintenance burden: Must be manually updated when suites change
- Source of truth drift: May not match actual build.zig targets
- Copy-paste errors: Easy to miss updates

**Recommendation:** Parse suite information from `build.zig` or maintain a shared configuration file:
```typescript
// Better approach
async function listSuites() {
  const buildZig = await readFile('build.zig', 'utf-8');
  const suites = extractTestSuites(buildZig); // Parse "specs-*" targets
  displaySuites(suites);
}
```

### 3.2 Inconsistent Error Handling
**Severity:** Medium

The script has minimal error handling:

```typescript
// Line 139: No error handling for process spawn
const exitCode = await proc.exited;

// Lines 49-59: Basic arg parsing with no validation
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--suite' && i + 1 < args.length) {
    suite = args[++i];  // No validation that suite exists
  }
  // ...
}
```

**Issues:**
- No validation that the specified suite actually exists
- No handling of malformed arguments
- No catch blocks for spawn failures

**Recommendation:** Add validation and proper error handling:
```typescript
if (suite) {
  const availableSuites = await getAvailableSuites();
  if (!availableSuites.includes(`specs-${suite}`)) {
    console.error(`Error: Suite '${suite}' not found`);
    console.error(`Use --list to see available suites`);
    process.exit(1);
  }
}
```

### 3.3 Magic Numbers and Strings
**Severity:** Low
**Location:** Lines 122, 144

```typescript
console.log('='.repeat(60));  // Magic number
```

**Recommendation:** Define constants:
```typescript
const SEPARATOR_WIDTH = 60;
const SEPARATOR = '='.repeat(SEPARATOR_WIDTH);
```

### 3.4 Unnecessary Variable Mutation
**Severity:** Low
**Location:** Lines 44-59

The argument parsing uses mutable variables where it could use immutable patterns:

```typescript
let testName: string | undefined;
let suite: string | undefined;
let showList = false;
let showHelp = false;

for (let i = 0; i < args.length; i++) {
  // Mutation throughout
}
```

**Recommendation:** Use a more functional approach or at least use `const` where possible after parsing.

### 3.5 Console.log for User-Facing Output
**Severity:** Low

While `console.log` is acceptable for scripts, a more structured approach with severity levels would be better (like `isolate-test.ts` uses colored helper functions).

**Recommendation:** Define helper functions like `printInfo`, `printError`, `printWarning` for consistency with `isolate-test.ts`.

---

## 4. Missing Test Coverage

### 4.1 No Tests for This Script
**Severity:** Medium

The script has no associated test file. While test scripts are often untested, this one has enough complexity (argument parsing, suite listing) to warrant tests.

**Missing test cases:**
- Argument parsing (various combinations)
- Help/list flag handling
- Suite name validation
- Error conditions
- Exit code handling

**Recommendation:** Create `debug-test.test.ts`:
```typescript
import { test, expect } from "bun:test";

test("parses --suite flag correctly", () => {
  // Test argument parsing logic
});

test("validates suite names", () => {
  // Test suite validation
});

test("handles missing test name", () => {
  // Test error conditions
});
```

---

## 5. Other Issues

### 5.1 Unclear Purpose vs isolate-test.ts
**Severity:** High
**Impact:** Developer confusion, maintenance burden

Both scripts have overlapping functionality:

| Feature | debug-test.ts | isolate-test.ts |
|---------|---------------|-----------------|
| Run single test | ✓ | ✓ |
| Verbose output | ✓ | ✓ |
| Trace analysis | ✗ | ✓ |
| Failure detection | ✗ | ✓ |
| Test discovery | ✗ | ✓ |
| Suite targeting | ✓ | ✓ (via build_target) |
| Pretty output | ✗ | ✓ |
| Next steps guide | Basic | Comprehensive |

**Problem:** Developers must choose between two similar tools, and `debug-test.ts` provides less value.

**Recommendation:**
1. **Option A (Deprecate):** Remove `debug-test.ts` and enhance `isolate-test.ts` to support suite selection via `--suite` flag
2. **Option B (Differentiate):** Make `debug-test.ts` the "quick and dirty" test runner with minimal output, and `isolate-test.ts` the full analysis tool
3. **Option C (Merge):** Combine both into a single script with `--quick` and `--analyze` modes

### 5.2 Suite Name Inconsistency
**Severity:** Low
**Location:** Lines 120, 127

```typescript
if (suite) {
  console.log(`Using test suite: specs-${suite}`);
}
// ...
const command = suite
  ? ['zig', 'build', `specs-${suite}`]
  : ['zig', 'build', 'specs'];
```

The `specs-` prefix is automatically added, but the `--list` output doesn't make this clear. Users might try `--suite specs-cancun-tstore-basic` when they should use `--suite cancun-tstore-basic`.

**Recommendation:** Make this explicit in documentation and error messages.

### 5.3 No Exit Code Explanation
**Severity:** Low

The script exits with the test's exit code but doesn't explain what it means:

```typescript
process.exit(exitCode);
```

**Recommendation:** Add explanation:
```typescript
if (exitCode !== 0) {
  console.log(`\nTest failed with exit code: ${exitCode}`);
  console.log('  0 = success');
  console.log('  1 = test failure');
  console.log('  N = other errors');
}
process.exit(exitCode);
```

### 5.4 Missing Emoji Anti-Pattern Check
**Severity:** Low
**Location:** Line 145

```typescript
console.log('\n💡 Tip: For detailed trace analysis, use:');
```

According to CLAUDE.md: "Only use emojis if the user explicitly requests it. Avoid adding emojis to files unless asked."

While this is a script output (not code), consistency with the project's style guide is recommended.

### 5.5 No Integration with Known Issues Database
**Severity:** Low

`isolate-test.ts` could reference `scripts/known-issues.json` for historical context. This script doesn't leverage that either.

**Recommendation:** Both scripts should check if the test has known issues and display relevant context.

### 5.6 Absolute vs Relative Path Assumptions
**Severity:** Low

The script assumes certain paths exist (ethereum-tests/, test/specs/) but doesn't verify or handle missing directories gracefully.

**Recommendation:** Add existence checks:
```typescript
function validateEnvironment() {
  const requiredPaths = ['build.zig', 'test/specs'];
  for (const path of requiredPaths) {
    if (!existsSync(path)) {
      console.error(`Error: Required path not found: ${path}`);
      console.error('Are you running from the repository root?');
      process.exit(1);
    }
  }
}
```

---

## 6. Security Considerations

### 6.1 Command Injection Risk
**Severity:** Low (mitigated by Bun.spawn)

The script passes user input to `Bun.spawn`:

```typescript
const proc = Bun.spawn(command, {
  env: {
    ...process.env,
    TEST_FILTER: testName,  // User-controlled input
  },
});
```

**Analysis:** This is safe because:
1. `Bun.spawn` takes arguments as an array, not a shell string
2. `TEST_FILTER` is passed as an environment variable, not a command argument

**Recommendation:** No immediate action needed, but document this safety property.

---

## 7. Performance Considerations

### 7.1 Synchronous Suite List Generation
**Severity:** Low
**Location:** Lines 78-115

The `--list` output is synchronous and hardcoded, which is fine for current scale but could be slow if generated dynamically.

**Recommendation:** If implementing dynamic suite listing, use async file I/O.

---

## 8. Maintainability Issues

### 8.1 Duplicate Color Definitions
**Severity:** Low

Multiple scripts define their own color constants (`isolate-test.ts`, `test-subset.ts`, etc.). This should be in a shared module.

**Recommendation:** Create `scripts/lib/colors.ts`:
```typescript
export const colors = {
  RED: '\x1b[0;31m',
  GREEN: '\x1b[0;32m',
  YELLOW: '\x1b[1;33m',
  BLUE: '\x1b[0;34m',
  CYAN: '\x1b[0;36m',
  MAGENTA: '\x1b[0;35m',
  BOLD: '\x1b[1m',
  RESET: '\x1b[0m',
};
```

### 8.2 Argument Parsing Pattern
**Severity:** Low

The argument parsing is manual and could benefit from a library or shared utility, especially if adding more flags.

**Recommendation:** Consider using a library like `commander` or create a shared argument parser for all scripts.

---

## 9. Recommendations Summary

### High Priority
1. **Clarify purpose vs isolate-test.ts** - Decide whether to merge, differentiate, or deprecate
2. **Add output capture and basic analysis** - Don't just pass through, provide value
3. **Validate suite names** - Fail fast with helpful error messages

### Medium Priority
4. **Generate suite list dynamically** - Parse from build.zig or shared config
5. **Add proper error handling** - Catch spawn failures and invalid input
6. **Create helper functions** - Match isolate-test.ts's colored output style
7. **Add test coverage** - At least for argument parsing logic

### Low Priority
8. **Extract shared utilities** - Colors, formatting, common patterns
9. **Improve documentation** - Clarify use cases and relationship to other scripts
10. **Add environment validation** - Check required paths exist
11. **Consider emoji consistency** - Match project style guide

---

## 10. Comparison with Related Scripts

### vs isolate-test.ts
- **Advantage:** Simpler, lighter weight
- **Disadvantage:** Lacks analysis, trace divergence, structured output
- **Verdict:** Consider merging or clearly differentiating

### vs test-subset.ts
- **Difference:** test-subset.ts runs multiple tests with filtering, debug-test.ts targets single test
- **Overlap:** Both can run filtered tests
- **Verdict:** Clear differentiation exists

### vs quick-test.ts
- **Difference:** quick-test.ts runs hardcoded smoke tests, debug-test.ts is parameterized
- **Overlap:** Both are "quick" test runners
- **Verdict:** Serve different purposes

---

## 11. Code Quality Metrics

| Metric | Score | Notes |
|--------|-------|-------|
| Readability | 7/10 | Clear but could use more structure |
| Maintainability | 5/10 | Hardcoded lists, no shared utilities |
| Robustness | 5/10 | Minimal error handling |
| Documentation | 8/10 | Good header docs, needs inline comments |
| Testability | 4/10 | No tests, difficult to test as-is |
| Reusability | 4/10 | Lots of duplicate code across scripts |

---

## 12. Suggested Refactoring

Here's a high-level refactoring structure:

```typescript
#!/usr/bin/env bun
import { colors, printInfo, printError, printWarning } from './lib/output';
import { parseArgs } from './lib/args';
import { validateEnvironment, getAvailableSuites } from './lib/test-utils';
import { runTest, analyzeResults } from './lib/test-runner';

// Main function
async function main() {
  const { testName, suite, showList, showHelp } = parseArgs();

  if (showHelp) return showUsage();
  if (showList) return await listSuites();

  validateEnvironment();

  if (suite && !isValidSuite(suite)) {
    printError(`Unknown suite: ${suite}`);
    process.exit(1);
  }

  const result = await runTest(testName, suite);
  const analysis = analyzeResults(result);

  displayResults(analysis);
  suggestNextSteps(analysis);

  process.exit(result.exitCode);
}

main().catch(console.error);
```

---

## Conclusion

The `debug-test.ts` script is a functional utility that serves its basic purpose, but it falls short of its potential. The main concerns are:

1. **Unclear value proposition** compared to `isolate-test.ts`
2. **Maintenance burden** from hardcoded suite lists
3. **Missed opportunities** for analysis and developer assistance
4. **Code duplication** across similar scripts

**Recommended Action:** Either significantly enhance this script to match `isolate-test.ts` capabilities with a focus on quick debugging, or deprecate it in favor of a unified testing interface. The middle ground of "working but not great" is the worst option for developer experience.

**Estimated Effort to Fix:**
- Quick fixes (validation, error handling): 2-3 hours
- Full refactoring with shared utilities: 1-2 days
- Merge with isolate-test.ts: 3-4 hours
