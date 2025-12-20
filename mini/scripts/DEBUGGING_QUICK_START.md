# Debugging Quick Start Guide

Quick reference for debugging failing spec tests.

## Quick Commands

```bash
# List all available test suites
bun scripts/debug-test.ts --list

# Run a focused test suite (recommended for debugging)
zig build specs-<suite-name>

# Run a single test within a suite
bun scripts/debug-test.ts --suite <suite-name> "<test_pattern>"

# Get detailed trace analysis for a failing test
bun scripts/isolate-test.ts "<exact_test_name>"
```

## Recommended Debugging Workflow

### 1. Identify Failing Suite
```bash
# If you know the hardfork/EIP
bun scripts/debug-test.ts --list

# Or check build targets
zig build --help | grep specs-
```

### 2. Run Focused Test Suite
```bash
# Example: Debug Cancun transient storage execution contexts
zig build specs-cancun-tstore-contexts-execution

# Example: Debug Byzantium modexp precompile
zig build specs-byzantium-modexp

# Example: Debug Constantinople CREATE2
zig build specs-constantinople-create2
```

### 3. Isolate Specific Failure
```bash
# Use isolate-test.ts for detailed trace divergence analysis
bun scripts/isolate-test.ts "test_transient_storage_unset_values"

# This will show:
# - Exact point of divergence (PC, opcode, gas, stack)
# - Step-by-step comparison with reference
# - Debugging guidance
```

### 4. Find Test Names

#### Method 1: From Test Output
When a test fails, the full test name is shown in the output:
```
FAIL generated.state_tests...tests_eest_cancun_..._test_transient_storage_unset_values_fork_Cancun_...
```

#### Method 2: Search Generated Files
```bash
grep "^test \"" test/specs/generated -r | grep "transient_storage"
```

#### Method 3: Use isolate-test.ts
It will find and show the exact test name for you.

## Test Suite Categories

### Small Suites (4-60 tests) - Best for Focused Debugging
- `cancun-tstore-contexts-clear` (4 tests)
- `cancun-tstore-contexts-selfdestruct` (12 tests)
- `cancun-selfdestruct-revert` (12 tests)
- `cancun-tstore-contexts-create` (20 tests)
- `cancun-tstore-contexts-reentrancy` (20 tests)
- `cancun-blob-opcodes-contexts` (23 tests)
- `shanghai-initcode-eof` (24 tests)
- `cancun-selfdestruct-reentrancy` (36 tests)
- `cancun-blob-precompile-gas` (48 tests)
- `cancun-tstore-contexts-tload-reentrancy` (48 tests)
- `cancun-selfdestruct-collision` (52 tests)
- `cancun-tstore-contexts-execution` (60 tests)

### Medium Suites (70-180 tests) - Good for Category Testing
- `cancun-blob-opcodes-basic` (75 tests)
- `shanghai-initcode-basic` (162 tests)

### Large Suites (250-350 tests) - Use for Comprehensive Validation
- `constantinople-bitshift` (~250 tests)
- `constantinople-create2` (~250 tests)
- `cancun-selfdestruct-basic` (306 tests)
- `cancun-blob-precompile-basic` (310 tests)
- `byzantium-modexp` (352 tests)

## Common Debugging Patterns

### Pattern 1: Gas Discrepancy
```bash
# 1. Run the failing suite
zig build specs-cancun-tstore-contexts-execution

# 2. Isolate the specific test
bun scripts/isolate-test.ts "test_name"

# 3. Look for trace divergence - check:
#    - Gas charging order (must match Python exactly)
#    - Missing gas charges (e.g., warm/cold access)
#    - Incorrect gas constants
```

### Pattern 2: State Mismatch
```bash
# 1. Run focused suite
zig build specs-constantinople-create2

# 2. Check if it's CREATE2-specific or general
bun scripts/debug-test.ts --suite constantinople-create2 "create2_return_data"

# 3. Isolate and analyze
bun scripts/isolate-test.ts "test_create2_return_data"

# 4. Look for:
#    - Incorrect address calculation
#    - Storage not persisting
#    - Balance mismatches
```

### Pattern 3: Precompile Failures
```bash
# 1. Run precompile suite
zig build specs-byzantium-modexp

# 2. Check if timeout or actual failure
#    - If timeout: May need to optimize implementation
#    - If failure: Check input parsing and output format

# 3. Isolate specific case
bun scripts/isolate-test.ts "test_modexp_EIP_198_case1"

# 4. Compare with execution-specs Python implementation
```

## Test Filtering Tips

### Use Substring Matching
Test filters use simple substring matching (not regex):
- ✅ `"transient_storage"` - matches all tests containing this substring
- ✅ `"test_subcall_fork_Cancun"` - matches specific fork tests
- ❌ `"transient.*storage"` - regex doesn't work, will match nothing

### Be Specific for Single Tests
```bash
# Too broad - will match many tests
bun scripts/debug-test.ts "subcall"

# Better - matches fewer tests
bun scripts/debug-test.ts "test_subcall_fork_Cancun_blockchain_test"

# Best - exact match
bun scripts/debug-test.ts "tests_eest_cancun_eip1153_tstore_test_tstorage_execution_contexts_py__test_subcall_fork_Cancun_blockchain_test_engine_from_state_test_call_"
```

## Integration with AI Debugging Agent

### Agent-Friendly Workflow
1. **Start with smallest relevant suite**: e.g., `specs-cancun-tstore-contexts-clear` (4 tests)
2. **Use isolate-test.ts for failures**: Get trace divergence automatically
3. **Read Python reference**: execution-specs/.../instructions/*.py
4. **Make minimal fix**: Focus on exact discrepancy
5. **Verify with debug-test.ts**: Quick check before moving on

### Avoid Agent Timeouts
- ❌ Don't run: `zig build specs-cancun` (too many tests)
- ✅ Do run: `zig build specs-cancun-tstore-contexts-clear` (focused)
- ✅ Use sub-suites for all debugging
- ✅ Keep individual test runs under 60 seconds

### Rate Limit Management
- Run smallest applicable sub-suite
- Use debug-test.ts for quick verification
- Only use isolate-test.ts when you need trace divergence
- Batch multiple small fixes before full suite validation

## Helpful File Locations

### Test Files
- Generated tests: `test/specs/generated/`
- Test runner: `test/specs/runner.zig`
- Root test file: `test/specs/root.zig`

### Implementation
- EVM orchestrator: `src/evm.zig`
- Bytecode interpreter: `src/frame.zig`
- Precompiles: `src/precompiles/precompiles.zig`
- Gas constants: `src/primitives/gas_constants.zig`

### Reference
- Python specs: `execution-specs/src/ethereum/forks/`
- Test fixtures: `execution-specs/tests/eest/static/state_tests/`

## Pro Tips

1. **Always start with the smallest failing suite** - Faster iteration, clearer failures
2. **Use isolate-test.ts sparingly** - It's powerful but verbose; use after you've narrowed down the issue
3. **Check Python reference first** - Don't guess gas costs or operation order
4. **Test incrementally** - Fix one issue, verify, then move to next
5. **Read the trace divergence carefully** - The exact PC/opcode/gas where it diverges tells you what's wrong
6. **Use --suite flag** - Running a specific suite is 10-100x faster than filtering all tests

## Getting Help

- **CLAUDE.md**: Project-level instructions and architecture
- **DEBUGGING_IMPROVEMENTS.md**: Detailed documentation of all improvements
- **scripts/CLAUDE.md**: Bun-specific instructions
- **isolate-test.ts**: Source code shows what analysis is performed

## Example Session

```bash
# 1. What's failing?
bun scripts/debug-test.ts --list
# Output shows: cancun-tstore-contexts-execution (60 tests)

# 2. Run the suite
zig build specs-cancun-tstore-contexts-execution
# Output: 2 tests failing

# 3. Isolate first failure
bun scripts/isolate-test.ts "test_subcall_fork_Cancun_blockchain_test_engine_with_invalid"
# Output shows: Divergence at PC=47, INVALID opcode, 3 gas overage

# 4. Check Python reference
cat execution-specs/src/ethereum/forks/cancun/vm/instructions/system.py
# Find INVALID opcode handling and gas charging

# 5. Fix in src/frame.zig
# Make minimal change to match Python

# 6. Verify fix
bun scripts/debug-test.ts --suite cancun-tstore-contexts-execution "with_invalid"
# Output: Test passes!

# 7. Run full suite to ensure no regressions
zig build specs-cancun-tstore-contexts-execution
# Output: All 60 tests pass!
```
