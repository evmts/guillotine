# Code Review: map-wasm-functions.ts

**File:** `/Users/williamcory/guillotine-mini/scripts/map-wasm-functions.ts`
**Reviewed:** 2025-10-26
**Purpose:** WASM function name mapper that builds comprehensive mappings by analyzing exports, imports, source code, and call patterns

---

## Executive Summary

**Overall Assessment:** The script is functionally complete and well-structured, but has several areas for improvement including error handling, hardcoded values, unused code, and missing validation.

**Risk Level:** LOW (utility script, not production code)

**Key Issues Found:**
- 5 Error Handling Issues
- 3 Hardcoded Values
- 2 Incomplete Features
- 1 Unused Code Path
- 0 Critical Security Issues

---

## 1. Incomplete Features

### 1.1 Source Code Analysis Result Not Used (Line 394)

**Location:** `main()` function, line 394

**Issue:**
```typescript
// Analyze source code for patterns
console.log("🔍 Analyzing source code patterns...");
await analyzeSourceCode();  // ❌ Result is never used!
```

**Impact:** The `analyzeSourceCode()` function is called but its return value (a `Map<string, string>` of function patterns) is discarded. This means the entire source code analysis phase does nothing useful.

**Expected Behavior:** The function patterns should be used to enhance the mapping by matching inferred function names against known source patterns.

**Fix:**
```typescript
console.log("🔍 Analyzing source code patterns...");
const sourcePatterns = await analyzeSourceCode();
// Use sourcePatterns to enhance mapping quality
mapping = await enhanceMappingWithSourcePatterns(mapping, sourcePatterns);
```

**Priority:** HIGH - This is likely a bug, not intentional design.

---

### 1.2 Limited Source File Coverage (Lines 175-182)

**Location:** `analyzeSourceCode()` function

**Issue:**
```typescript
const sourceFiles = [
  "src/evm.zig",
  "src/frame.zig",
  "src/root_c.zig",
  "src/host.zig",
  "src/primitives/root.zig",
  "src/precompiles/precompiles.zig",
];
```

**Impact:** The script only analyzes 6 hardcoded source files, missing other important modules like:
- `src/opcode.zig`
- `src/trace.zig`
- `src/errors.zig`
- `src/hardfork.zig`
- Files in subdirectories beyond primitives/precompiles

**Fix:** Use dynamic file discovery:
```typescript
async function getAllZigFiles(dir: string): Promise<string[]> {
  const files: string[] = [];
  const entries = await readdir(dir, { recursive: true, withFileTypes: true });

  for (const entry of entries) {
    if (entry.isFile() && entry.name.endsWith('.zig')) {
      files.push(join(entry.path, entry.name));
    }
  }

  return files;
}

// Then in analyzeSourceCode:
const sourceFiles = await getAllZigFiles(SRC_DIR);
```

**Priority:** MEDIUM - Would improve mapping quality but not critical.

---

## 2. TODOs and Missing Implementation

### 2.1 No Explicit TODOs Found

**Status:** ✅ GOOD - No TODO comments left in code

However, based on the incomplete features above, implied TODOs are:
1. Wire up source code analysis results to mapping enhancement
2. Implement dynamic source file discovery
3. Add validation for wasm-objdump availability

---

## 3. Bad Code Practices

### 3.1 Hardcoded Magic Number (Line 365)

**Location:** `showTopFunctions()` function

**Issue:**
```typescript
const totalSize = 230721; // WASM total size
```

**Problems:**
- Hardcoded value will become outdated as WASM binary changes
- No dynamic calculation despite having size information available
- Comment doesn't explain where this number comes from

**Fix:**
```typescript
const totalSize = Array.from(sizes.values()).reduce((sum, size) => sum + size, 0);
```

**Priority:** HIGH - This is incorrect by design and will cause inaccurate percentages.

---

### 3.2 Silent Error Suppression (Lines 197-199)

**Location:** `analyzeSourceCode()` function

**Issue:**
```typescript
try {
  const content = await Bun.file(file).text();
  // ... process file
} catch {
  // File doesn't exist or can't be read
}
```

**Problems:**
- Empty catch block silently ignores ALL errors (not just missing files)
- No logging of which files failed
- Could hide permission issues, encoding problems, etc.
- Violates project guidelines: "CRITICAL: Silently ignore errors with `catch {}`"

**Fix:**
```typescript
try {
  const content = await Bun.file(file).text();
  // ... process file
} catch (err) {
  if ((err as any).code === 'ENOENT') {
    console.warn(`⚠️  Source file not found: ${file}`);
  } else {
    console.error(`❌ Failed to read ${file}:`, err);
    throw err; // Re-throw unexpected errors
  }
}
```

**Priority:** HIGH - Violates project anti-patterns.

---

### 3.3 Type Safety Issues with `any` (Lines 289, 293, 310)

**Location:** `saveMappingDatabase()` function

**Issue:**
```typescript
const database: any = {  // ❌ Should have proper type
  generated: new Date().toISOString(),
  total_functions: mapping.size,
  categories: {} as Record<string, number>,
  functions: [] as any[],  // ❌ Should be FunctionMapping[]
};

// ...

database.functions.push({  // No type checking on object shape
  index: func.index,
  name: func.name,
  size: sizes.get(func.index) || 0,
  source: func.source,
  category: func.category,
});
```

**Problems:**
- Loss of type safety
- Could push malformed objects without detection
- Makes refactoring risky

**Fix:**
```typescript
interface FunctionDatabaseEntry {
  index: number;
  name: string;
  size: number;
  source: string;
  category?: string;
}

interface FunctionDatabase {
  generated: string;
  total_functions: number;
  categories: Record<string, number>;
  functions: FunctionDatabaseEntry[];
}

const database: FunctionDatabase = {
  generated: new Date().toISOString(),
  total_functions: mapping.size,
  categories: {},
  functions: [],
};
```

**Priority:** MEDIUM - Good practice but not urgent for a utility script.

---

### 3.4 Inefficient Pattern Matching (Lines 130-153)

**Location:** `inferFromDisassembly()` function

**Issue:**
```typescript
const hasExecute = calledNames.some(n => n?.includes("execute"));
const hasStorage = calledNames.some(n => n?.includes("storage"));
const hasGet = calledNames.some(n => n?.includes("get"));
const hasSet = calledNames.some(n => n?.includes("set"));
```

**Problems:**
- Four separate iterations over `calledNames` array
- Optional chaining on every check despite filtering for `Boolean`
- Nested if-else ladder is hard to maintain

**Fix:**
```typescript
const patterns = {
  execute: calledNames.some(n => n.includes("execute")),
  storage: calledNames.some(n => n.includes("storage")),
  get: calledNames.some(n => n.includes("get")),
  set: calledNames.some(n => n.includes("set")),
};

let category = "Helper";
let nameHint = "";

if (patterns.execute) {
  category = "Execution";
  nameHint = "execution_helper";
} else if (patterns.storage && patterns.set) {
  category = "Storage";
  nameHint = "storage_setter";
} else if (patterns.storage && patterns.get) {
  category = "Storage";
  nameHint = "storage_getter";
} else if (patterns.set) {
  category = "State";
  nameHint = "state_setter";
} else if (patterns.get) {
  category = "State";
  nameHint = "state_getter";
}
```

**Priority:** LOW - Optimization, not correctness issue.

---

### 3.5 Duplicate Shell Command Execution (Lines 31, 54, 79, 251)

**Location:** Multiple functions

**Issue:**
```typescript
// extractExports() - line 31
const output = await $`wasm-objdump -x ${WASM_PATH}`.text();

// extractImports() - line 54
const output = await $`wasm-objdump -x ${WASM_PATH}`.text();

// inferFromDisassembly() - line 79
const output = await $`wasm-objdump -d ${WASM_PATH}`.text();

// buildFunctionSizeMap() - line 251
const output = await $`wasm-objdump -d ${WASM_PATH}`.text();
```

**Problems:**
- Same commands executed multiple times (wasm-objdump -x twice, -d twice)
- Each execution takes ~100-500ms
- Wasteful for large WASM files
- Poor caching strategy

**Fix:**
```typescript
interface WasmDump {
  headers: string;
  disassembly: string;
}

async function getWasmDump(): Promise<WasmDump> {
  const [headers, disassembly] = await Promise.all([
    $`wasm-objdump -x ${WASM_PATH}`.text(),
    $`wasm-objdump -d ${WASM_PATH}`.text(),
  ]);

  return { headers, disassembly };
}

// Then pass these as parameters to functions that need them
```

**Priority:** MEDIUM - Performance improvement for slow systems.

---

## 4. Error Handling Issues

### 4.1 No Validation of wasm-objdump Availability (Lines 31, 54, 79, 251)

**Location:** All shell command executions

**Issue:**
```typescript
const output = await $`wasm-objdump -x ${WASM_PATH}`.text();
```

**Problems:**
- No check if `wasm-objdump` is installed
- No handling of command not found errors
- Generic error message doesn't guide user to install WABT

**Fix:**
```typescript
async function checkWasmObjdump(): Promise<void> {
  try {
    await $`which wasm-objdump`.quiet();
  } catch {
    console.error(`
❌ Error: wasm-objdump not found

This script requires WABT (WebAssembly Binary Toolkit).

Install via:
  • macOS:   brew install wabt
  • Ubuntu:  apt install wabt
  • Arch:    pacman -S wabt
  • Build:   https://github.com/WebAssembly/wabt
`);
    process.exit(1);
  }
}

// Call in main():
await checkWasmObjdump();
```

**Priority:** HIGH - Common failure mode for new users.

---

### 4.2 No Validation of WASM File Existence (Line 18)

**Location:** Global constant

**Issue:**
```typescript
const WASM_PATH = "zig-out/bin/guillotine_mini.wasm";
```

**Problems:**
- No check if file exists before processing
- Error messages from wasm-objdump are cryptic
- User doesn't know to run `zig build wasm` first

**Fix:**
```typescript
async function validateWasmFile(path: string): Promise<void> {
  const file = Bun.file(path);

  if (!(await file.exists())) {
    console.error(`
❌ Error: WASM file not found: ${path}

Build the WASM binary first:
  zig build wasm

Then run this script again.
`);
    process.exit(1);
  }

  // Validate it's actually a WASM file
  const magic = await file.slice(0, 4).arrayBuffer();
  const magicBytes = new Uint8Array(magic);

  if (magicBytes[0] !== 0x00 || magicBytes[1] !== 0x61 ||
      magicBytes[2] !== 0x73 || magicBytes[3] !== 0x6d) {
    console.error(`❌ Error: ${path} is not a valid WASM file`);
    process.exit(1);
  }
}

// Call in main():
await validateWasmFile(WASM_PATH);
```

**Priority:** HIGH - Improves user experience significantly.

---

### 4.3 Unhandled Directory Creation Failure (Lines 405-409)

**Location:** `saveMappingDatabase()` call in `main()`

**Issue:**
```typescript
await saveMappingDatabase(
  mapping,
  sizes,
  "reports/wasm-size/function-mapping.json"
);
```

**Problems:**
- No guarantee `reports/wasm-size/` directory exists
- `Bun.write()` might fail silently or throw unclear error
- No graceful degradation

**Fix:**
```typescript
import { mkdir } from "node:fs/promises";

async function ensureDir(filePath: string): Promise<void> {
  const dir = filePath.substring(0, filePath.lastIndexOf('/'));
  try {
    await mkdir(dir, { recursive: true });
  } catch (err: any) {
    if (err.code !== 'EEXIST') {
      throw err;
    }
  }
}

// In saveMappingDatabase():
await ensureDir(outputFile);
await Bun.write(outputFile, JSON.stringify(database, null, 2));
```

**Priority:** MEDIUM - Likely fails on first run in new checkout.

---

### 4.4 Generic Error Handling in Main (Lines 418-421)

**Location:** `main()` catch block

**Issue:**
```typescript
main().catch((err) => {
  console.error("❌ Error:", err.message);
  process.exit(1);
});
```

**Problems:**
- Only logs `err.message`, losing stack trace
- No distinction between different error types
- Makes debugging difficult

**Fix:**
```typescript
main().catch((err) => {
  console.error("❌ Fatal error:");
  console.error(err);

  if (err.stack) {
    console.error("\nStack trace:");
    console.error(err.stack);
  }

  process.exit(1);
});
```

**Priority:** LOW - Developer convenience improvement.

---

### 4.5 No Validation of Regex Matches (Lines 34, 57, 93, 107, 257, 271)

**Location:** Multiple regex match processing loops

**Issue:**
```typescript
const exportMatches = output.matchAll(/- func\[(\d+)\] <([^>]+)> -> "([^"]+)"/g);

for (const match of exportMatches) {
  const index = parseInt(match[1]);  // ❌ No null check on capture group
  const name = match[2];              // ❌ Could be undefined
  // ...
}
```

**Problems:**
- No validation that capture groups exist
- Could cause runtime errors if wasm-objdump output format changes
- Silent bugs if parsing fails

**Fix:**
```typescript
for (const match of exportMatches) {
  if (!match[1] || !match[2] || !match[3]) {
    console.warn(`⚠️  Malformed export entry: ${match[0]}`);
    continue;
  }

  const index = parseInt(match[1], 10);
  if (isNaN(index)) {
    console.warn(`⚠️  Invalid function index: ${match[1]}`);
    continue;
  }

  const name = match[2];
  // ...
}
```

**Priority:** MEDIUM - Defensive programming for robustness.

---

## 5. Missing Test Coverage

### 5.1 No Test Suite

**Status:** ❌ **CRITICAL** - Zero test coverage

**Impact:**
- No validation that parsing logic works correctly
- Refactoring is risky
- Regression bugs can slip in
- No way to test against known-good WASM samples

**Recommended Tests:**

```typescript
// test/map-wasm-functions.test.ts
import { test, expect, describe } from "bun:test";
import { extractExports, extractImports, buildFunctionSizeMap } from "../scripts/map-wasm-functions.ts";

describe("extractExports", () => {
  test("parses standard export format", () => {
    const mockOutput = ` - func[13] <evm_create> -> "evm_create"`;
    // Test parsing logic
  });

  test("handles malformed exports gracefully", () => {
    const mockOutput = ` - func[invalid] <bad>`;
    // Should not throw
  });

  test("skips entries with missing capture groups", () => {
    const mockOutput = ` - func[]`;
    // Should skip and log warning
  });
});

describe("buildFunctionSizeMap", () => {
  test("correctly calculates function sizes", () => {
    const mockDisassembly = `
000100 func[1] <test_func>:
  000101: 41 00                | i32.const 0
  000103: 0b                   | end
000104 func[2] <other_func>:
    `;
    // Should map func[1] to size 4 (0x104 - 0x100)
  });
});

describe("inferFromDisassembly", () => {
  test("infers storage setters from call patterns", () => {
    // Test heuristic logic
  });

  test("does not override explicitly named functions", () => {
    // Should preserve export/import names
  });
});

describe("analyzeSourceCode", () => {
  test("extracts pub fn declarations", () => {
    const mockContent = `
pub fn createEvm() void {}
pub fn destroyEvm() void {}
fn privateFunc() void {}
    `;
    // Should find createEvm and destroyEvm, not privateFunc
  });
});
```

**Priority:** HIGH - Essential for maintainability.

---

### 5.2 No Integration Test with Real WASM

**Issue:** Script assumes wasm-objdump output format never changes.

**Recommended Test:**
```typescript
test("end-to-end mapping with real WASM file", async () => {
  // Build test WASM or use checked-in sample
  const mapping = await buildFullMapping("test/fixtures/sample.wasm");

  expect(mapping.size).toBeGreaterThan(0);
  expect(mapping.get(0)?.source).toBe("export");
});
```

**Priority:** MEDIUM - Catches format changes.

---

## 6. Documentation Issues

### 6.1 Missing JSDoc Comments

**Issue:** No documentation on function parameters, return types, or expected behavior.

**Fix:** Add JSDoc to all exported functions:
```typescript
/**
 * Extracts explicit function names from WASM exports.
 * Parses wasm-objdump -x output to identify exported functions.
 *
 * @returns Map of function index to mapping metadata
 * @throws Error if wasm-objdump fails or WASM file not found
 */
async function extractExports(): Promise<Map<number, FunctionMapping>> {
  // ...
}
```

**Priority:** LOW - Nice to have for utility script.

---

### 6.2 No Usage Examples in Header Comment

**Issue:** Script header describes what it does but not how to use it.

**Fix:**
```typescript
/**
 * WASM Function Name Mapper
 *
 * Builds a comprehensive mapping of WASM function indices to actual function names
 * by analyzing multiple sources:
 * 1. WASM exports (explicit names)
 * 2. WASM imports (external functions)
 * 3. Source code analysis (Zig functions)
 * 4. Heuristics based on function patterns
 *
 * USAGE:
 *   # Build WASM first
 *   zig build wasm
 *
 *   # Run mapper
 *   bun scripts/map-wasm-functions.ts
 *
 *   # Output files:
 *   - reports/wasm-size/function-mapping.json
 *   - reports/wasm-size/function-mapping.txt
 *
 * REQUIREMENTS:
 *   - wasm-objdump (install WABT: brew install wabt)
 *   - Built WASM binary at zig-out/bin/guillotine_mini.wasm
 */
```

**Priority:** MEDIUM - Helps new contributors.

---

## 7. Performance Issues

### 7.1 No Progress Indicators for Long Operations

**Issue:** Large disassembly parsing (lines 79-116) has no progress feedback.

**Fix:**
```typescript
console.log("🔍 Analyzing disassembly (this may take 30-60 seconds)...");

// Add periodic progress updates
let functionsProcessed = 0;
const progressInterval = setInterval(() => {
  console.log(`   Processed ${functionsProcessed} functions...`);
}, 2000);

// ... processing loop

clearInterval(progressInterval);
console.log(`✅ Analyzed ${functionsProcessed} functions`);
```

**Priority:** LOW - Quality of life improvement.

---

### 7.2 Memory Inefficiency in Large String Operations (Line 80)

**Issue:**
```typescript
const output = await $`wasm-objdump -d ${WASM_PATH}`.text();
const lines = output.split("\n");  // Loads entire disassembly into memory
```

**Problem:** For large WASM files (>10MB), disassembly output can be 50-100MB+ in memory.

**Fix:** Use streaming approach:
```typescript
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

async function streamDisassembly(callback: (line: string) => void): Promise<void> {
  const proc = spawn("wasm-objdump", ["-d", WASM_PATH]);
  const rl = createInterface({ input: proc.stdout });

  for await (const line of rl) {
    callback(line);
  }
}
```

**Priority:** LOW - Only matters for very large WASM files.

---

## 8. Security Issues

### 8.1 No Command Injection Protection (Low Risk)

**Location:** Line 31, 54, 79, 251

**Issue:**
```typescript
const output = await $`wasm-objdump -x ${WASM_PATH}`.text();
```

**Analysis:** `WASM_PATH` is hardcoded constant, not user input, so risk is LOW. However, if script is ever modified to accept command-line arguments, this becomes a vulnerability.

**Recommendation:** Document that `WASM_PATH` must not be user-controlled, or add validation:
```typescript
const WASM_PATH_PATTERN = /^[a-zA-Z0-9_\-\/\.]+$/;
if (!WASM_PATH_PATTERN.test(WASM_PATH)) {
  throw new Error("Invalid WASM path");
}
```

**Priority:** LOW - Theoretical risk only.

---

## 9. Maintainability Issues

### 9.1 Large Main Function (Lines 374-416)

**Issue:** `main()` function has 40+ lines with multiple responsibilities.

**Fix:** Extract into smaller functions:
```typescript
async function buildMapping(): Promise<Map<number, FunctionMapping>> {
  let mapping = await extractExports();
  const imports = await extractImports();

  for (const [idx, func] of imports.entries()) {
    mapping.set(idx, func);
  }

  mapping = await inferFromDisassembly(mapping);
  return mapping;
}

async function main() {
  console.log("🔍 Building WASM Function Name Mapping\n");

  const sizes = await buildFunctionSizeMap();
  let mapping = await buildMapping();
  mapping = await categorizeBySize(mapping, sizes);

  await saveMappingDatabase(mapping, sizes, "reports/wasm-size/function-mapping.json");
  await showTopFunctions(mapping, sizes, 25);

  console.log(`\n✅ Function mapping complete!`);
}
```

**Priority:** LOW - Code organization improvement.

---

## 10. Recommendations Summary

### High Priority (Fix Soon)
1. ✅ **Wire up source code analysis results** (Section 1.1)
2. ✅ **Remove empty catch blocks** (Section 3.2)
3. ✅ **Fix hardcoded totalSize** (Section 3.1)
4. ✅ **Add wasm-objdump availability check** (Section 4.1)
5. ✅ **Add WASM file existence validation** (Section 4.2)
6. ✅ **Add basic test coverage** (Section 5.1)

### Medium Priority (Improve Gradually)
7. ⚠️ **Dynamic source file discovery** (Section 1.2)
8. ⚠️ **Cache wasm-objdump output** (Section 3.5)
9. ⚠️ **Ensure output directory exists** (Section 4.3)
10. ⚠️ **Add regex match validation** (Section 4.5)
11. ⚠️ **Add usage documentation** (Section 6.2)

### Low Priority (Nice to Have)
12. ℹ️ **Improve type safety with interfaces** (Section 3.3)
13. ℹ️ **Optimize pattern matching** (Section 3.4)
14. ℹ️ **Add JSDoc comments** (Section 6.1)
15. ℹ️ **Add progress indicators** (Section 7.1)
16. ℹ️ **Refactor large main function** (Section 9.1)

---

## 11. Positive Aspects (What's Done Well)

✅ **Clear separation of concerns** - Each function has single responsibility
✅ **Good logging** - User can follow execution progress
✅ **Multiple mapping strategies** - Combines exports, imports, inference, and heuristics
✅ **Dual output formats** - JSON for machines, TXT for humans
✅ **Sorted output** - Functions ordered by size for easy analysis
✅ **No external dependencies** - Uses only Bun built-ins
✅ **Descriptive variable names** - Code is self-documenting
✅ **Consistent error handling pattern** - All errors propagate to main

---

## 12. Overall Score

| Category | Score | Notes |
|----------|-------|-------|
| Correctness | 7/10 | Main logic works but unused code path and hardcoded values |
| Error Handling | 4/10 | Missing validation, silent failures, generic catches |
| Performance | 7/10 | Redundant shell calls but otherwise efficient |
| Maintainability | 8/10 | Clean structure but large main function |
| Test Coverage | 0/10 | No tests |
| Documentation | 5/10 | Good comments but missing usage examples and JSDoc |
| Security | 9/10 | No significant risks for utility script |
| **OVERALL** | **5.7/10** | **Functional but needs hardening and testing** |

---

## 13. Action Plan

**Immediate (Before Next Release):**
1. Fix the unused `analyzeSourceCode()` result
2. Remove hardcoded `totalSize = 230721`
3. Add wasm-objdump and WASM file validation
4. Replace empty catch block with proper error handling

**Short Term (Next Sprint):**
5. Add basic unit tests for parsing logic
6. Implement dynamic source file discovery
7. Cache wasm-objdump output to avoid redundant calls
8. Add output directory creation

**Long Term (Technical Debt):**
9. Add comprehensive test suite with fixtures
10. Extract type definitions to separate module
11. Add streaming support for large WASM files
12. Create integration test with CI

---

## Appendix A: Related Files to Review

- `/Users/williamcory/guillotine-mini/scripts/analyze-wasm-size.ts` - Likely uses function mapping output
- `/Users/williamcory/guillotine-mini/build.zig` - WASM build configuration
- `/Users/williamcory/guillotine-mini/src/root_c.zig` - C API exports that appear in WASM

---

## Appendix B: Example Test Fixture

```typescript
// test/fixtures/mock-wasm-objdump-output.ts
export const mockExportOutput = `
Section Details:

Export[10]:
 - func[13] <evm_create> -> "evm_create"
 - func[14] <evm_destroy> -> "evm_destroy"
 - func[15] <evm_execute> -> "evm_execute"
 - memory[0] -> "memory"
`;

export const mockImportOutput = `
Section Details:

Import[5]:
 - func[0] sig=0 <wasi_snapshot_preview1.fd_write> <- wasi_snapshot_preview1.fd_write
 - func[1] sig=1 <wasi_snapshot_preview1.fd_read> <- wasi_snapshot_preview1.fd_read
`;

export const mockDisassemblyOutput = `
000100 func[13] <evm_create>:
  000101: 23 00                | global.get 0
  000103: 41 10                | i32.const 16
  000105: 6b                   | i32.sub
  000106: 0b                   | end
000107 func[14] <evm_destroy>:
  000108: 41 00                | i32.const 0
  00010a: 0b                   | end
`;
```

---

**End of Review**
