# Block Interpreter Bugs

This file tracks bugs found when adding parallel testing for `interpret_block` alongside the traditional `interpret` method.

## Summary

**Task**: Add parallel testing for both `interpret` and `interpret_block` methods across all test files.

**Progress**: 
- Updated 5 test files with parallel testing infrastructure
- All interpret_block calls are currently commented out due to Bug #3
- Once Bug #3 is fixed, all interpret_block calls can be uncommented

**Files Updated**:
1. `test/evm/e2e_simple_test.zig` - Basic EVM operations
2. `test/evm/e2e_data_structures_test.zig` - Arrays and mappings
3. `test/evm/e2e_error_handling_test.zig` - Error conditions and reverts
4. `test/evm/vm_core_comprehensive_test.zig` - VM core components
5. `test/evm/vm_opcode_test.zig` - Individual opcode tests

**Files Not Yet Updated** (due to Bug #3 blocking):
- `test/evm/block_execution_erc20_test.zig` (already disabled)
- `test/evm/inline_ops_test.zig`
- `test/evm/opcodes/delegatecall_test.zig`
- `test/evm/opcodes/return_output_test.zig`
- `test/evm/e2e_inheritance_test.zig`
- `test/evm/compare_execution.zig`
- `test/evm/sub_opcode_bug_test.zig`
- `test/evm/constructor_bug_test.zig`

## Bug Tracking

Each bug entry includes:
- **Test File**: Where the bug was discovered
- **Test Name**: Specific test that fails
- **Description**: What the bug is
- **Error**: The actual error message or behavior difference
- **Status**: Whether it's been skipped or fixed

---

## Discovered Bugs

### Bug #1: Build Error - BitVec64 to StaticBitSet Migration
- **Test File**: N/A - Build error
- **Test Name**: N/A - Compilation failure
- **Description**: Code was partially migrated from BitVec64 to StaticBitSet but not completed
- **Error**: 
  ```
  src/evm/frame/code_analysis.zig:384: error: use of undeclared identifier 'BitVec64'
  src/evm/frame/code_analysis.zig:385: error: use of undeclared identifier 'BitVec64'
  src/evm/frame/code_analysis.zig:386: error: use of undeclared identifier 'BitVec64'
  src/evm/frame/code_analysis.zig:614: error: use of undeclared identifier 'BitVec64'
  src/evm/frame/code_analysis.zig:615: error: use of undeclared identifier 'BitVec64'
  src/evm/frame/code_analysis.zig:616: error: use of undeclared identifier 'BitVec64'
  src/evm/frame/contract.zig:480: error: no field or member function named 'isSetUnchecked' in 'bit_set.ArrayBitSet'
  src/evm/frame/contract.zig:816: error: expected type 'bit_set.ArrayBitSet', found 'frame.bitvec.BitVec'
  ```
- **Status**: FIXED - Build now compiles
- **Notes**: The analyze_bytecode_blocks function still references BitVec64.codeBitmap and BitVec64.init which need to be replaced with StaticBitSet equivalents

### Bug #2: ALL Test Suites Hanging 
- **Test File**: ALL test files (including unmodified ones)
- **Test Name**: All test suites
- **Description**: Every test suite hangs indefinitely, including tests we did not modified
- **Error**: 
  ```
  Command timeout - all tests hang after build completes
  Tested suites that hang:
  - test-e2e-simple (modified with interpret_block)
  - test-e2e-simple (even with interpret_block commented out)
  - test-memory (unmodified test)
  ```
- **Status**: PARTIALLY FIXED - Some tests now run, but interpret_block still causes hangs
- **Notes**: 
  - Initial issue affected ALL tests, now only interpret_block causes hangs
  - test-memory now runs successfully
  - test-e2e-simple runs when interpret_block is commented out
  - test-e2e-simple hangs when interpret_block is enabled

### Bug #3: interpret_block Causes Test Hang
- **Test File**: test/evm/e2e_simple_test.zig (and likely others)
- **Test Name**: E2E: Basic EVM operations (and others)
- **Description**: When interpret_block_write is called, test execution hangs indefinitely
- **Error**: 
  ```
  Test execution hangs when calling evm.interpret_block_write()
  No error message - process hangs
  Multiple hanging evm-runner processes found
  ```
- **Status**: ACTIVE - Blocking all parallel testing
- **Notes**: 
  - Tests pass when interpret_block calls are commented out
  - Tests hang when interpret_block is enabled
  - The hanging appears to be in the interpret_block implementation itself
  - Debug logging shows the hang occurs during or after Frame creation
  - Multiple hanging evm-runner processes found suggesting infinite loop or deadlock
  - All test files have been updated with commented-out interpret_block calls
  - Once this bug is fixed, uncomment the interpret_block calls in all test files