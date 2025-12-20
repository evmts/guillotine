# Code Review: analyze-wasm-size.ts

**Date:** 2025-10-26
**File:** `/Users/williamcory/guillotine-mini/scripts/analyze-wasm-size.ts`
**Reviewer:** Claude Code
**Lines of Code:** 596

---

## Executive Summary

This TypeScript script analyzes WebAssembly binary size using `twiggy` and `wasm-objdump` tools. It provides multiple analysis views (top functions, dominators, garbage collection, etc.) and generates comprehensive reports. The code is generally well-structured and documented, but has several areas requiring improvement around error handling, hardcoded values, and missing test coverage.

**Overall Quality Rating:** 7/10

---

## 1. Incomplete Features

### 1.1 Paths Analysis Not Implemented
**Location:** Lines 557-559
**Severity:** Medium

```typescript
// Note: paths command requires specific function names as arguments
// Skipping for now as we don't have function names in stripped WASM
```

**Issue:** The `paths` analysis command is mentioned in documentation and summary but never actually executed. The comment indicates it's skipped because function names aren't available, but the script *does* load function mappings from `map-wasm-functions.ts`.

**Impact:** Users expect paths analysis based on README.md (line 397-398) but it's not generated.

**Recommendation:**
- Either implement the paths analysis using the loaded function mappings
- Or remove references to paths from the documentation/summary
- Add a warning message explaining why it's skipped

### 1.2 Function Mapping Generation Assumes Success
**Location:** Lines 521-534

```typescript
if (nameMapping.size === 0) {
  console.log("⚠️  Function mapping not found, generating now...");
  try {
    await $`bun scripts/map-wasm-functions.ts`.quiet();
    // Reload after generation
    const newMapping = await loadFunctionMapping();
    for (const [idx, func] of newMapping.entries()) {
      nameMapping.set(idx, func);
    }
  } catch {
    console.warn("⚠️  Could not generate function mapping, continuing with basic names");
  }
}
```

**Issue:** After calling `map-wasm-functions.ts`, the script doesn't verify that the mapping was actually created. The generation could fail silently, leaving `nameMapping` still empty.

**Recommendation:**
- Check `newMapping.size > 0` after reloading
- Provide more specific error information about why generation failed

---

## 2. TODOs and Technical Debt

### 2.1 No Explicit TODOs Found
**Status:** Good

The codebase contains no TODO comments, which suggests either:
- The code is considered complete for its current scope
- Technical debt isn't being tracked in comments (possibly tracked elsewhere)

**Recommendation:** Consider adding TODO comments for the incomplete paths analysis feature.

---

## 3. Bad Code Practices

### 3.1 Hardcoded Magic Numbers
**Location:** Line 324

```typescript
const totalSize = 230721; // WASM total size
```

**Severity:** High
**Issue:** The total WASM size is hardcoded rather than being dynamically calculated. This value will become incorrect as the codebase changes.

**Impact:**
- Percentage calculations in the report will be incorrect
- The value (230721 bytes = ~225KB) doesn't match the current actual WASM size
- Developers may not realize this needs updating

**Recommendation:**
```typescript
// Get actual file size dynamically
const wasmFile = await Bun.file(WASM_PATH);
const totalSize = await wasmFile.size;
```

### 3.2 Silent Error Suppression
**Location:** Lines 64-66, 253-255, 364-366, 472-482

Multiple locations use catch blocks that only log warnings without preserving error context:

```typescript
} catch (err) {
  console.warn("⚠️  Could not load function mapping, will generate basic names");
}
```

**Severity:** Medium
**Issue:** Error objects are caught but their details aren't logged, making debugging difficult.

**Recommendation:**
```typescript
} catch (err) {
  console.warn("⚠️  Could not load function mapping, will generate basic names");
  console.debug("Error details:", err instanceof Error ? err.message : String(err));
}
```

### 3.3 Array Index Increment Without Bounds Check
**Location:** Lines 85-86, 88-89

```typescript
case "--output":
  options.outputDir = args[++i];
  break;
case "--limit":
  options.limit = parseInt(args[++i], 10);
  break;
```

**Severity:** Medium
**Issue:** Pre-increment without checking if `i+1` exists in the array. This could cause `undefined` to be assigned if the argument is missing.

**Impact:** User provides `--output` without a value → `options.outputDir = undefined` → potential crashes later

**Recommendation:**
```typescript
case "--output":
  if (i + 1 >= args.length) {
    console.error("Error: --output requires a directory path");
    process.exit(1);
  }
  options.outputDir = args[++i];
  break;
case "--limit":
  if (i + 1 >= args.length) {
    console.error("Error: --limit requires a number");
    process.exit(1);
  }
  const limit = parseInt(args[++i], 10);
  if (isNaN(limit) || limit <= 0) {
    console.error("Error: --limit must be a positive number");
    process.exit(1);
  }
  options.limit = limit;
  break;
```

### 3.4 Regex Matching Without Validation
**Location:** Lines 241-250

```typescript
const exportsMatch = fullDump.match(/Export\[\d+\]:.*?(?=\n\w+\[|$)/s);
if (exportsMatch) {
  await Bun.write(join(outputDir, "wasm-exports.txt"), exportsMatch[0]);
}

const importsMatch = fullDump.match(/Import\[\d+\]:.*?(?=\nFunction\[|$)/s);
if (importsMatch) {
  await Bun.write(join(outputDir, "wasm-imports.txt"), importsMatch[0]);
}
```

**Severity:** Low
**Issue:** Regex patterns are fragile and may break with different `wasm-objdump` versions. No validation that the extracted content is meaningful.

**Recommendation:**
- Add logging when matches fail to help debug format changes
- Consider more robust parsing (line-by-line processing)

### 3.5 Inconsistent Error Handling Pattern
**Location:** Throughout file

```typescript
// Pattern 1: Try-catch with warn
try { ... } catch { console.warn(...); }

// Pattern 2: Try-catch with err parameter
try { ... } catch (err) { console.warn(...); }

// Pattern 3: Tool check with early return
if (!tools.twiggy && !tools.wabt) {
  process.exit(1);
}

// Pattern 4: Main catch-all
main().catch((err) => {
  console.error("❌ Error:", err.message);
  process.exit(1);
});
```

**Severity:** Low
**Issue:** Mixing multiple error handling patterns makes the code harder to maintain.

**Recommendation:** Standardize on one pattern, preferably capturing and logging error details consistently.

---

## 4. Missing Test Coverage

### 4.1 No Unit Tests
**Severity:** High
**Status:** No test files found for this script

**Missing Test Cases:**
1. **Argument Parsing Tests**
   - Valid arguments parsing
   - Invalid arguments handling
   - Missing argument values
   - Help flag display
   - Edge cases (empty strings, special characters)

2. **Prerequisites Check Tests**
   - Both tools available
   - Only twiggy available
   - Only wabt available
   - Neither tool available
   - Mock `which` command failures

3. **File Operations Tests**
   - WASM file exists
   - WASM file missing
   - Output directory creation
   - Write permissions issues

4. **Function Mapping Tests**
   - Loading existing mapping
   - Empty mapping file
   - Corrupted mapping file
   - Auto-generation fallback
   - Mapping reload after generation

5. **Analysis Functions Tests**
   - Twiggy command execution
   - JSON output generation
   - WASM info extraction
   - Code section parsing
   - Summary generation

6. **Error Scenarios Tests**
   - Tool execution failures
   - File system errors
   - Parse errors in WASM output
   - Invalid function mappings

**Recommendation:** Create `analyze-wasm-size.test.ts` with comprehensive test coverage using Bun's test framework:

```typescript
import { test, expect, mock } from "bun:test";
import { $ } from "bun";

test("parseArgs handles --limit correctly", async () => {
  // Test implementation
});

test("parseArgs rejects missing --limit value", async () => {
  // Test implementation
});

test("checkPrerequisites detects missing tools", async () => {
  // Test implementation
});
```

---

## 5. Other Issues

### 5.1 Type Safety Issues

#### 5.1.1 Loose Type on Error Objects
**Location:** Lines 592-593

```typescript
main().catch((err) => {
  console.error("❌ Error:", err.message);
  process.exit(1);
});
```

**Issue:** `err` is typed as `any`. If it's not an Error object, accessing `.message` could fail.

**Recommendation:**
```typescript
main().catch((err) => {
  const message = err instanceof Error ? err.message : String(err);
  console.error("❌ Error:", message);
  process.exit(1);
});
```

### 5.2 Performance Issues

#### 5.2.1 Inefficient String Building
**Location:** Lines 326-340

```typescript
let report = `Function Size Analysis...`;

for (let i = 0; i < Math.min(100, functions.length); i++) {
  const func = functions[i];
  // ...
  report += `${func.index.toString().padEnd(8)} | ...`; // String concatenation in loop
}
```

**Severity:** Low
**Issue:** String concatenation in a loop is inefficient. For large function lists, this creates many intermediate strings.

**Recommendation:**
```typescript
const lines = [
  `Function Size Analysis...`,
  // headers...
];

for (let i = 0; i < Math.min(100, functions.length); i++) {
  const func = functions[i];
  lines.push(`${func.index.toString().padEnd(8)} | ...`);
}

const report = lines.join('\n');
```

### 5.3 Documentation Issues

#### 5.3.1 Outdated File Size Comment
**Location:** Line 34

```typescript
const WASM_PATH = "zig-out/bin/guillotine_mini.wasm";
```

**Issue:** The hardcoded `totalSize` value (230721) doesn't match typical WASM builds, suggesting the comment/documentation is outdated.

#### 5.3.2 Missing JSDoc Comments
**Severity:** Medium
**Issue:** Public functions lack JSDoc comments explaining parameters, return values, and potential errors.

**Example of what's missing:**
```typescript
/**
 * Parses command-line arguments into structured options
 * @returns {Promise<AnalysisOptions>} Parsed options with defaults applied
 * @throws {never} Exits process on invalid arguments via process.exit()
 */
async function parseArgs(): Promise<AnalysisOptions> { ... }
```

### 5.4 Security Issues

#### 5.4.1 Command Injection Risk
**Severity:** Low (mitigated by limited input sources)
**Location:** Lines 197, 223

```typescript
const result = await $`twiggy ${args}`.text();
```

**Issue:** While `args` is constructed internally (not from user input), the pattern could be dangerous if extended to accept user-provided function names or paths.

**Current Risk:** Low - arguments are controlled
**Future Risk:** Medium - if extended to accept external input

**Recommendation:**
- Document that user input must never be passed directly to these commands
- Consider using explicit argument passing rather than template literals
- Add input validation if external input is ever added

### 5.5 Maintainability Issues

#### 5.5.1 Duplicate Command Building Logic
**Location:** Lines 188-195, 212-221

The command argument building logic is duplicated between `runTwiggy` and `runTwiggyJson`.

**Recommendation:** Extract to a shared helper:
```typescript
function buildTwiggyArgs(command: string, limit: number, format?: "json"): string[] {
  let args: string[];

  if (command === "top" || command === "garbage" || command === "paths") {
    args = [command, WASM_PATH, "-n", limit.toString()];
  } else if (command === "dominators") {
    args = [command, WASM_PATH, "-r", limit.toString()];
  } else {
    args = [command, WASM_PATH];
  }

  if (format === "json") {
    args.push("--format", "json");
  }

  return args;
}
```

#### 5.5.2 Large Function Complexity
**Location:** Lines 258-367 (`analyzeCodeSections`)

**Issue:** This function does too many things:
1. Runs wasm-objdump
2. Parses disassembly output
3. Tracks function boundaries
4. Sorts and formats results
5. Generates statistics
6. Writes output file

**Recommendation:** Break into smaller functions:
- `parseDisassembly(text: string): FunctionInfo[]`
- `calculateCategoryStats(functions: FunctionInfo[]): Map<string, Stats>`
- `formatFunctionReport(functions: FunctionInfo[], stats: Map<string, Stats>): string`

---

## 6. Positive Aspects

### 6.1 Good Practices
1. **Comprehensive CLI Help**: Well-documented `--help` output
2. **Progressive Enhancement**: Gracefully handles missing tools
3. **Clear User Feedback**: Extensive use of emoji and clear messages
4. **Structured Output**: Generates multiple complementary reports
5. **Interface Definitions**: Well-defined TypeScript interfaces

### 6.2 Code Quality Highlights
1. **Separation of Concerns**: Each function has a clear, single responsibility
2. **Configuration Centralized**: Options interface groups related settings
3. **User Experience**: Automatic fallbacks and helpful error messages
4. **Documentation**: Generated README.md provides excellent user guidance

---

## 7. Priority Recommendations

### Critical (Fix Immediately)
1. **Remove hardcoded WASM size** (Line 324) - Replace with dynamic calculation
2. **Add bounds checking** for CLI argument parsing (Lines 85-89)
3. **Add unit test suite** - At minimum, test argument parsing and error handling

### High Priority (Fix Soon)
1. **Implement or remove paths analysis** - Don't advertise unavailable features
2. **Improve error logging** - Capture and log error details throughout
3. **Add JSDoc comments** to all public functions

### Medium Priority (Technical Debt)
1. **Refactor `analyzeCodeSections`** - Break into smaller functions
2. **Extract duplicate command building logic**
3. **Standardize error handling patterns**
4. **Improve type safety** for error handling

### Low Priority (Nice to Have)
1. **Optimize string building** in report generation
2. **Add debug logging mode** for troubleshooting
3. **Support custom twiggy commands** via config file

---

## 8. Testing Strategy

### Recommended Test Structure

```
scripts/
├── analyze-wasm-size.ts
├── analyze-wasm-size.test.ts       (unit tests)
├── analyze-wasm-size.integration.test.ts  (integration tests)
└── fixtures/
    ├── sample.wasm                  (test WASM file)
    ├── sample-mapping.json          (test mapping)
    └── expected-outputs/            (expected report outputs)
```

### Test Coverage Goals
- **Unit Tests**: 80%+ coverage
- **Integration Tests**: End-to-end workflow validation
- **Edge Cases**: All error paths tested

---

## 9. Conclusion

The `analyze-wasm-size.ts` script is well-designed and provides valuable WASM analysis capabilities. However, it requires attention in several areas:

**Strengths:**
- Clear structure and good user experience
- Comprehensive analysis capabilities
- Graceful degradation when tools are missing

**Weaknesses:**
- Lack of test coverage is the biggest concern
- Hardcoded values create maintenance burden
- Some error handling could be more robust

**Overall Assessment:** This is production-quality code that would benefit from a testing suite and addressing the hardcoded size value. The incomplete paths analysis feature should either be implemented or removed from documentation.

**Estimated Effort to Address Issues:**
- Critical fixes: 2-4 hours
- High priority: 4-6 hours
- Test suite creation: 8-12 hours
- Medium/Low priority: 4-6 hours

**Total Estimated Effort:** 18-28 hours for comprehensive improvements
