# CLAUDE.md - Ethereum Specs Testing Guide

## Overview

The specs directory contains Ethereum execution specification tests to validate Guillotine EVM against the official test suite.

## Running Specs

### Basic Commands

```bash
# Run all spec tests (Zig implementation - default)
zig build specs

# Run with Bun/TypeScript runner (alternative)
zig build specs-bun

# Limit number of spec files
zig build specs -Dspec-max-files=100

# Filter tests by pattern
zig build specs -Dtest-filter='add'

# Legacy options still supported
zig build specs -- -Dspec-isolated=true
zig build specs -- -Dspec-pattern='add*.json'
```

### Optimization Modes

**IMPORTANT**: Tests should be run in multiple optimization modes as different code paths may be taken:

```bash
# Debug mode (default) - Best for debugging, includes assertions and stack traces
zig build specs -Doptimize=Debug

# ReleaseFast mode - Optimized for speed, some code paths differ
zig build specs -Doptimize=ReleaseFast

# ReleaseSmall mode - Optimized for size, may have different behavior
zig build specs -Doptimize=ReleaseSmall

# ReleaseSafe mode - Safety checks enabled with optimizations
zig build specs -Doptimize=ReleaseSafe
```

**CI/CD Note**: All optimization modes should be tested in CI/CD pipelines since:
- Debug mode catches assertion failures and provides better diagnostics
- ReleaseFast/ReleaseSmall modes may take different code paths (e.g., fusion optimizations)
- Some bugs only manifest in specific optimization levels

**Combining with other options:**
```bash
# Fast mode with limited tests for quick iteration
zig build specs -Doptimize=ReleaseFast -Dspec-max-files=10

# Debug mode with specific pattern for detailed debugging
zig build specs -Doptimize=Debug -Dspec-pattern='*add*.json'

# Native Zig runner in different modes
zig build test-execution-spec-guillotine -Doptimize=ReleaseFast
zig build test-execution-spec-minimal-evm -Doptimize=Debug
```

## Current Status

- **2124 tests passing**
- **1043 tests failing**
- **3167 total expect() calls**

## Test Organization

The specs tests are the **highest priority** in the test hierarchy:
1. **Specs** - Ethereum protocol compliance (run first)
2. **Integration** - Cross-module testing  
3. **Unit** - Module-specific tests

Run all tests in order: `zig build test`

## Working with Specs

### When Debugging Failures

1. Use isolated mode to prevent crashes:
   ```bash
   zig build specs -- -Dspec-isolated=true -Dspec-pattern='failing_test*.json'
   ```

2. Check `specs/test_report.md` for detailed failure information

3. Test files are in `specs/execution-specs/tests/` organized by category

### Key Files

- `specs/bun-runner/ethereum-specs.test.ts` - Main test runner (fast, in-process)
- `specs/bun-runner/ethereum-specs-safe.test.ts` - Isolated test runner (safer, uses workers)
- `specs/bun-runner/test-worker.js` - Worker script for isolated execution

### Implementation Notes

The test runner:
1. Loads JSON test files from `execution-specs/tests/`
2. Sets up EVM with specified pre-state
3. Executes transactions
4. Currently validates execution doesn't crash (post-state validation TODO)

### Known Issues

- Assembly code tests are skipped (`:asm` format not supported)
- Post-state validation not implemented yet
- Some tests may crash the runner (use isolated mode)

## Best Practices

1. **Always run specs after EVM changes** to catch regressions
2. **Use isolated mode** when debugging crashes
3. **Start with small batches** when investigating failures:
   ```bash
   zig build specs -- -Dspec-max-files=10 -Dspec-pattern='specific*.json'
   ```
4. **Check test categories** - failures often cluster by feature area

## Improving Test Coverage

Priority areas for improvement:
1. Implement post-state validation
2. Add support for assembly code tests
3. Improve error reporting for failures
4. Add differential testing against revm