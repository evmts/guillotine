# Test + Agent Scripts

This directory contains helper scripts for running and debugging execution-spec tests, plus TypeScript agents to assist with automated fixing and auditing.

## Available Scripts

### 🎯 `test-subset.sh` - Main Test Runner

Run filtered subsets of execution-spec tests with nice formatting.

```bash
# Run by test name/pattern
./scripts/test-subset.sh push0
./scripts/test-subset.sh transientStorage
./scripts/test-subset.sh Cancun

# Using environment variable
TEST_FILTER=Shanghai ./scripts/test-subset.sh

# List available test categories
./scripts/test-subset.sh --list

# Show help
./scripts/test-subset.sh --help
```

**Features:**
- Colored output with progress indicators
- Automatic trace divergence on failures
- Support for both CLI args and env vars
- Built-in test category listing

### 🔬 `isolate-test.ts` - Test Isolation Helper ⭐ RECOMMENDED ⭐

Run a single test with maximum debugging output and intelligent failure analysis.

```bash
bun scripts/isolate-test.ts "transientStorageReset"
bun scripts/isolate-test.ts "push0" specs-shanghai-push0
bun scripts/isolate-test.ts "MCOPY" specs-cancun-mcopy
```

**Features:**
- Automatic test filtering and isolation
- Verbose trace output with divergence analysis
- Intelligent failure type detection (crash vs gas vs behavior)
- Extracts and displays divergence details (PC, opcode, gas, stack)
- Provides next-step debugging guidance
- Shows useful commands for follow-up investigation

**Use this when:**
- Any test fails and you need to debug it (FIRST CHOICE)
- Before making code changes (pre-analysis phase)
- After making fixes to verify they work
- You need detailed trace comparison

### 🔍 `debug-test.ts` - Single Test Debugger

Debug a specific test with full trace output.

```bash
bun scripts/debug-test.ts transStorageOK
bun scripts/debug-test.ts push0Gas
```

**Use this when:**
- You know the exact test name
- You want detailed execution traces
- Simpler alternative to isolate-test.ts

### ⚡ `quick-test.ts` - Smoke Tests

Run a quick smoke test suite for rapid iteration.

```bash
bun scripts/quick-test.ts
```

**Features:**
- Runs 3-5 representative tests
- Fast feedback (< 30 seconds)
- Good for checking basic functionality

### 📋 `run-filtered-tests.ts` - Simple Filter Runner

Basic wrapper around `zig build specs` with filtering.

```bash
bun scripts/run-filtered-tests.ts push0
bun scripts/run-filtered-tests.ts Cancun
```

**Simpler alternative to `test-subset.ts`** with minimal formatting.

## Common Workflows

### During Development

```bash
# 1. Make changes to src/evm.zig or src/frame.zig

# 2. Run quick smoke tests
bun scripts/quick-test.ts

# 3. Run tests for the feature you're working on
bun scripts/test-subset.ts transientStorage

# 4. If a test fails, debug it with the isolation helper
bun scripts/isolate-test.ts "specific_failing_test"

# 5. Review trace divergence, fix the issue

# 6. Verify fix
bun scripts/isolate-test.ts "specific_failing_test"
```

### Before Committing

```bash
# Run all tests for affected hardfork
./scripts/test-subset.sh Cancun
./scripts/test-subset.sh Shanghai

# Or run full suite
zig build specs
```

### Exploring Tests

```bash
# See what's available
./scripts/test-subset.sh --list

# Try different categories
./scripts/test-subset.sh vmArithmeticTest
./scripts/test-subset.sh vmBitwiseLogicOperation
```

## Direct `zig build` Usage

You can also use `zig build` directly:

```bash
# Basic filter
zig build specs -- --test-filter "push0"

# With summary
zig build specs -- --test-filter "Cancun" --summary all

# Multiple filters
zig build specs -- --test-filter "add" --test-filter "sub"
```

## Environment Variables

All scripts support the `TEST_FILTER` environment variable:

```bash
export TEST_FILTER="transientStorage"
./scripts/test-subset.sh

# Or inline
TEST_FILTER="MCOPY" ./scripts/test-subset.sh
```

## Test Naming Patterns

Tests follow these naming patterns:

**By Hardfork:**
- `Cancun` - All Cancun tests
- `Shanghai` - All Shanghai tests

**By EIP:**
- `stEIP1153` - EIP-1153 (Transient Storage)
- `stEIP3855` - EIP-3855 (PUSH0)
- `stEIP5656` - EIP-5656 (MCOPY)

**By Category:**
- `vmArithmeticTest` - Arithmetic operations
- `vmBitwiseLogicOperation` - Bitwise operations
- `vmIOandFlowOperations` - Control flow

**By Opcode:**
- `add`, `sub`, `mul`, `div` - Specific opcodes
- `sstore`, `sload` - Storage operations
- `call`, `delegatecall` - Call operations

## Debugging Tips

1. **Use filters to narrow down failures**
   ```bash
   ./scripts/test-subset.sh Cancun  # Too broad
   ./scripts/test-subset.sh stEIP1153  # Better
   ./scripts/test-subset.sh transStorageOK  # Specific
   ```

2. **Read trace divergence output carefully**
   - Shows exact step where execution differs
   - Compares gas, PC, opcode, stack depth
   - Points to the root cause

3. **Run tests incrementally**
   - Fix one test at a time
   - Re-run after each fix
   - Don't try to fix everything at once

4. **Use quick-test.sh for fast feedback**
   - Run after every change
   - Catches basic regressions
   - Much faster than full suite

## See Also

- [../docs/TESTING.md](../docs/TESTING.md) - Comprehensive testing guide
- [../test/specs/runner.zig](../test/specs/runner.zig) - Test execution logic
- [../test/specs/root.zig](../test/specs/root.zig) - Test imports

---

## Automation Scripts

### 🤖 `fix-specs.ts` - Automated Spec Test Fixer

AI-powered pipeline for systematically fixing spec test failures.

```bash
# Run all test suites
bun run scripts/fix-specs.ts

# Run specific test suite
bun run scripts/fix-specs.ts suite cancun-tstore-basic
bun run scripts/fix-specs.ts suite shanghai-push0
```

**What it does:**
- Runs test suites sequentially
- For each failing suite:
  1. Captures test failures
  2. Launches AI agent with detailed debugging instructions
  3. **Enforces pre-analysis phase** (required before any code changes)
  4. Agent fixes issues based on trace comparison and Python reference
  5. Verifies fixes by re-running tests
  6. Creates git commits for successful fixes
  7. Retries up to 5 times per suite
- Generates comprehensive reports in `reports/spec-fixes/`

**Pre-Analysis Phase (mandatory):**
The agent MUST complete these steps before any code changes:
1. Run test and capture failure
2. Generate and analyze trace divergence using `isolate-test.sh`
3. Read Python reference implementation
4. Locate corresponding Zig implementation
5. Write formal analysis report with root cause hypothesis

**Use this when:**
- Systematic fixing of multiple test suites
- Automated compliance improvement
- Large-scale debugging campaigns
- Overnight/long-running fix sessions

**Reports generated:**
- `reports/spec-fixes/<suite>-attempt<N>.md` - Per-attempt agent reports
- `reports/spec-fixes/pipeline-summary.md` - Overall pipeline results
- `reports/spec-fixes/pipeline-summary-ai.md` - AI-generated narrative summary

---

## TypeScript/Bun Scripts

### 📊 `compare-traces.ts` - Trace Comparison Tool ⭐ MOST POWERFUL DEBUGGING TOOL ⭐

Captures and compares EIP-3155 execution traces to identify the EXACT point where your implementation diverges from the Python reference.

```bash
# Basic usage (runs test and captures traces)
bun run scripts/compare-traces.ts "test_name"

# Use existing traces (for testing/analysis)
bun run scripts/compare-traces.ts "test_name" --skip-capture

# Examples
bun run scripts/compare-traces.ts "transientStorageReset"
bun run scripts/compare-traces.ts "push0_basic"
bun run scripts/compare-traces.ts "warmCoinbaseGasUsage"
```

**What it shows:**
- **Exact divergence step** - Precise step number where behavior differs
- **Opcode at divergence** - Which operation is failing
- **Gas difference** - Sign and magnitude
  - Positive: You're using less gas (missing charges)
  - Negative: You're using more gas (extra charges)
- **Stack comparison** - Value differences at divergence
- **Context** - 5 steps before divergence for context
- **Next steps** - Guidance on how to fix

**Output:**
- Console: Side-by-side comparison with highlighting
- Report: `traces/<test_name>_analysis.md` with detailed guidance

**Example output:**
```
████████████████████████████████████████████████████████████████████████████████
🚨 TRACE DIVERGENCE DETECTED
████████████████████████████████████████████████████████████████████████████████

Step: 42
Reason: Gas remaining divergence

Details:
  Our gas: 977894
  Reference gas: 979994
  Difference: -2100 (we have less gas)
  Opcode: 0x55 (SSTORE)

--------------------------------------------------------------------------------
SIDE-BY-SIDE COMPARISON
--------------------------------------------------------------------------------

OUR IMPLEMENTATION:                      │ REFERENCE:
  PC: 128                                │   PC: 128
  Opcode: 0x55 (SSTORE)                  │   Opcode: 0x55 (SSTORE)
  Gas: 977894                            │   Gas: 979994
  Gas Cost: 22100                        │   Gas Cost: 20000
  Stack (top 5):                         │   Stack (top 5):
    [0] 0x60                             │     [0] 0x60
    [1] 0x01                             │     [1] 0x01
```

**When to use:**
- ANY failing test (use this FIRST)
- Before making changes (see exact problem)
- After making changes (verify fix)
- When gas calculations are wrong
- When behavior diverges
- When stack/memory/storage differs

**Why it's better than manual debugging:**
- Eliminates guesswork - shows EXACT divergence
- Saves hours compared to reading code
- Shows context for understanding root cause
- Provides actionable next steps
- Creates detailed report for reference

**Requirements:**
- Bun runtime
- Test runner configured for EIP-3155 traces (already configured in this project)

For TypeScript utilities:

```bash
# Install dependencies
cd scripts && bun install

# Run individual scripts
bun run scripts/fix-specs.ts
bun run scripts/compare-traces.ts "test_name"
```
### 🧠 `fix-specs.ts` - Spec Fixer Pipeline (AI-assisted)

Runs hardfork/EIP-specific test suites and, on failure, launches an agent to propose and apply fixes. Saves per-attempt reports to `reports/spec-fixes/` and a final pipeline summary.

Prerequisites:
- `bun` installed (`brew install bun`)
- Dependencies installed in `scripts/` (`cd scripts && bun install`)
- Anthropic API key in env: `export ANTHROPIC_API_KEY=sk-ant-...`

Usage:
```bash
# Run all suites (can be long)
bun run scripts/fix-specs.ts

# Run one suite
bun run scripts/fix-specs.ts suite shanghai-push0

# List of suite names (see output if you pass an unknown suite)
```

Notes:
- If `ANTHROPIC_API_KEY` is not set, the script still runs tests but skips auto-fix attempts and exits quickly with a clear message.
- The EVM may legitimately fail a small number of tests; focus is on runner stability, trace/diff quality, and actionable reports.


Agent pipeline (auditors):
```bash
# Run all agents across phases
bun run scripts/index.ts

# Run a specific phase
bun run scripts/index.ts phase 2

# Run a single agent
bun run scripts/index.ts agent agent12
```

Environment:
- Set `ANTHROPIC_API_KEY` in your shell or a `.env` file at repo root (Bun loads it automatically).
- See `CLAUDE.md` for more details and safe usage notes.
