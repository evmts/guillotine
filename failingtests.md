# Baseline Failing Tests

This document lists all failing tests before starting the memory pre-allocation refactoring.

## Compilation Errors

### 1. newevm-test
- **Error**: `failed to check cache: 'src/evm/newevm_test.zig' file_hash FileNotFound`
- **Type**: Missing file

### 2. memory-test
- **Error**: `incompatible types: 'u64' and 'void'` at test/evm/memory_test.zig:134
- **Type**: Type mismatch in test expectation

### 3. interpret2-test
- **Errors**: Multiple compilation errors
  - `no field named 'inst_count' in struct 'evm.analysis2.SimpleAnalysis'` (8 occurrences)
  - `no field or member function named 'inner_call' in 'host.MockHost'`
- **Type**: Struct field removed/renamed

### 4. stack_validation_test
- **Error**: `root source file struct 'stack.stack_validation' has no member named 'ValidationPatterns'`
- **Type**: Missing type/module

### 5. evm.zig compilation
- **Errors**: 
  - `no field named 'flags' in struct 'evm'` (2 occurrences)
  - `no field named 'kind' in union 'host.CallParams'`
  - `expected type 'error{...}', found 'error{...}!noreturn'` in interpret2.zig:43
- **Type**: Struct field changes and type mismatch

### 6. system.zig compilation
- **Errors**: 
  - `expected 8 argument(s), found 11` (5 occurrences in different call sites)
- **Type**: Function signature changed

### 7. comparison.zig compilation
- **Error**: `no field named 'inst_count' in struct 'evm.analysis2.SimpleAnalysis'`
- **Type**: Struct field removed

### 8. block test compilation
- **Error**: `no field or member function named 'inner_call' in 'execution.block.TestBlockHost'`
- **Type**: Method removed/renamed

## Runtime Failures

### 1. staticcall-debug-test
- **Error**: `panic: incorrect alignment` at src/evm/evm/tailcalls.zig:17
- **Type**: Alignment issue with function pointers

### 2. jumpi-bug-test
- **Error**: `test.WORKING dynamic JUMPI to valid JUMPDEST returns 0x01' failed`
- **Details**: success=false when expected true
- **Type**: Logic error

### 3. differential-test (11 failures)
- **panic**: `integer overflow` at src/evm/stack/stack.zig:222 (peek_n_unsafe)
- **ADD opcode failures** (3 tests):
  - `0 + 0 = 0`: expected 0, found large value
  - `1 + 1 = 2`: expected 2, found large value
  - `max_u256 + 1 = 0`: expected 0, found large value
- **MUL opcode failure**: `7 * 6 = 42`: expected 42, found large value
- **DIV opcode failures** (3 tests):
  - `6 / 42 = 0`: expected 0, found large value
  - Division by zero tests returning wrong values
- **LT opcode failure**: `5 < 10 = 1`: expected 1, found 0
- **GT opcode failure**: `10 > 5 = 1`: expected 1, found 0
- **KECCAK256 failures** (2 tests):
  - Wrong output bytes
- **BALANCE opcode**: Causes signal 6 (abort)

## Summary

- **Total compilation error groups**: 8
- **Total runtime test failures**: 14
- **Main issues**:
  1. Missing `inst_count` field in SimpleAnalysis
  2. Missing `inner_call` method in hosts
  3. Function signature changes (8 args vs 11)
  4. Alignment issues in tailcalls
  5. Stack overflow/underflow issues
  6. Wrong arithmetic results (possibly stack corruption)

These failures appear to be from incomplete refactoring where:
- SimpleAnalysis struct was changed (inst_count removed)
- Host interface changed (inner_call removed)
- Function signatures updated but not all call sites
- Stack or memory corruption causing wrong arithmetic results