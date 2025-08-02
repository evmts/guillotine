# Work In Progress: Threaded Interpreter Implementation

## Overview

This document captures the current state of implementing an evmone-style threaded interpreter for the Guillotine EVM. The work is part of PR #330 and aims to eliminate interpreter loop overhead by using indirect call threading.

## What is Threaded Code Execution?

Traditional interpreters use a central dispatch loop:
```
while (pc < code.len) {
    opcode = code[pc]
    switch (opcode) {
        case ADD: ...
        case SUB: ...
    }
    pc++
}
```

Threaded interpreters eliminate this loop by having each operation directly call the next:
```
ADD -> SUB -> PUSH1 -> RETURN
```

This improves performance by:
- Eliminating branch mispredictions from the central switch
- Better instruction cache utilization
- Reduced overhead per operation

## Current State (as of commit)

### Test Results
- **Overall**: 760/768 tests passing (98.96% pass rate)
- **Up from**: 737/754 tests initially
- **Remaining failures**: 8 tests across various modules

### What's Been Implemented

1. **Core Threaded Infrastructure**
   - `ThreadedInstruction` structure with function pointers
   - `ThreadedAnalysis` for bytecode preprocessing
   - Block-based gas and stack validation
   - Pre-extracted PUSH values for performance

2. **Opcode Implementations**
   - ✅ Arithmetic operations (ADD, SUB, MUL, DIV, etc.)
   - ✅ Stack operations (PUSH, POP, DUP, SWAP)
   - ✅ Memory operations (MLOAD, MSTORE, MSIZE)
   - ✅ Storage operations (SLOAD, SSTORE)
   - ✅ Control flow (JUMP, JUMPI, PC, STOP)
   - ✅ Environmental ops (ADDRESS, BALANCE, CALLER, etc.)
   - ✅ CODECOPY (just implemented - fixed constructor tests)
   - ✅ RETURN, REVERT, STOP
   - ❌ System operations (CALL, CREATE, etc.) - NOT implemented
   - ❌ LOG operations - NOT implemented

3. **Key Files Modified/Created**

   **Core Implementation Files:**
   - `/src/evm/execution/threaded_ops.zig` - All threaded operation implementations
   - `/src/evm/frame/threaded_instruction.zig` - Instruction and analysis structures
   - `/src/evm/frame/threaded_analysis.zig` - Bytecode analysis and block creation
   - `/src/evm/evm/interpret.zig` - Modified to support threaded execution

   **Test Files:**
   - `/test/evm/threaded_block_validation_test.zig` - Block validation tests
   - `/test/evm/threaded_block_analysis_test.zig` - Analysis tests
   - `/test/evm/test_codecopy_minimal.zig` - CODECOPY specific test

## Recent Fixes

### 1. CODECOPY Implementation (Most Recent)
**Problem**: Constructor tests were failing with Invalid status after 8 instructions.
**Root Cause**: CODECOPY opcode (0x39) was not implemented in threaded_ops.
**Solution**: 
- Added `op_codecopy_threaded` implementation
- Properly handles memory expansion
- Copies code bytes to memory with correct bounds checking
- This fixed the constructor tests!

### 2. Jump Table Initialization
**Problem**: All blocks had gas_cost=0, causing immediate OutOfGas.
**Root Cause**: Using `JumpTable.init()` created empty table with NULL operations.
**Solution**: Use `JumpTable.init_from_hardfork(.CANCUN)` to properly populate operations.

### 3. Block Splitting Logic
**Problem**: Stack validation failures - blocks had incorrect stack requirements.
**Root Cause**: Block boundaries were being inserted at wrong positions.
**Solution**: Track `current_block_start` and insert block begin instructions at correct position.

### 4. Stack Order Issues
**Problem**: Operations were popping values in wrong order.
**Solution**: Fixed stack order for MSTORE, RETURN, and other operations to match EVM spec.

### 5. Memory Management
**Problem**: Multiple memory leaks detected.
**Solution**: Added proper deallocation in threaded analysis, using defer patterns.

## Architecture Details

### ThreadedInstruction Structure
```zig
pub const ThreadedInstruction = struct {
    exec_fn: ThreadedExecFunc,  // Function pointer to operation
    arg: InstructionArg,        // Pre-extracted arguments
    meta: InstructionMeta,      // Size and block info
};
```

### Block-Based Validation
The threaded interpreter pre-validates gas and stack requirements at block level:
- Blocks are created at JUMPDEST boundaries and every ~32 instructions
- Each block tracks: gas_cost, stack_req, stack_max_growth
- Gas is consumed for entire block upfront
- Stack requirements are validated before block execution

### Pre-Extraction Optimization
PUSH operations have their values pre-extracted during analysis:
- Small pushes (≤8 bytes): stored directly in instruction
- Large pushes: stored in separate array with index reference

## Remaining Work

### High Priority Issues

1. **System Operations Not Implemented** (Blocking)
   - CALL, DELEGATECALL, STATICCALL, CREATE, CREATE2
   - These are complex operations requiring state management
   - Currently mapped to `op_invalid_threaded`

2. **Test Failures to Fix** (8 remaining)
   - Contract call tests failing (1/10)
   - Delegatecall tests failing (3/3)
   - Return output test failures (2)
   - Likely related to missing system operations

3. **LOG Operations Not Implemented**
   - LOG0, LOG1, LOG2, LOG3, LOG4
   - Currently stubbed out but not functional

### Medium Priority

1. **Memory Leak in test_codecopy_minimal**
   - Test passes but leaks memory
   - Likely related to threaded analysis allocation

2. **Add Build Flag for Interpreter Selection**
   - Allow switching between standard and threaded interpreter
   - Useful for performance comparison and debugging

### Low Priority

1. **Performance Optimizations**
   - Implement remaining pre-extracted operations
   - Optimize hot paths based on benchmarks
   - Consider cache-line alignment for instructions

## How to Continue This Work

### Running Tests
```bash
# Run all tests
zig build test

# Run specific test
zig build test-codecopy-minimal
zig build test-constructor-bug
zig build test-threaded-block-validation

# Check test results
zig build test 2>&1 | grep "passed.*failed"
```

### Debugging Tips

1. **Enable Debug Logging**
   Add to test files:
   ```zig
   test {
       std.testing.log_level = .debug;
   }
   ```

2. **Key Debug Points**
   - `[EVM] Starting threaded execution:` - Shows instruction count
   - `[EVM] Block begin:` - Shows block validation
   - `[THREADED] Operation failed with error:` - Shows operation failures
   - `[EVM] Execution stopped after N instructions` - Shows termination

3. **Common Issues**
   - "Invalid" status usually means an operation threw an error
   - Stack underflow/overflow caught by block validation
   - Gas issues show as OutOfGas, not Invalid

### Next Steps for New Agent

1. **Implement System Operations** (Critical)
   - Start with CALL as it's most common
   - Study the non-threaded implementation in `/src/evm/execution/system.zig`
   - These operations need to:
     - Create new execution contexts
     - Handle value transfers
     - Manage return data
     - Update state properly

2. **Fix Remaining Test Failures**
   - Run `zig build test` and investigate failures
   - Most are likely due to missing system operations
   - Use debug logging to trace execution

3. **Implement LOG Operations**
   - Simpler than system operations
   - See `/src/evm/execution/log.zig` for reference
   - Need to append to frame's log array

## Testing Approach

The project follows a "no abstractions in tests" philosophy:
- Each test is completely self-contained
- No test helpers or utilities
- Copy-paste setup code directly
- This makes tests verbose but clear

Example test pattern:
```zig
test "operation test" {
    const allocator = testing.allocator;
    
    // Setup
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    // ... complete setup ...
    
    // Execute
    const result = try vm.interpret(&contract, &.{}, false);
    defer if (result.output) |output| allocator.free(output);
    
    // Verify
    try testing.expectEqual(expected, actual);
}
```

## Important Context

- The standard interpreter still exists and works
- Threaded interpreter is activated when `interpret()` is called
- Both interpreters share the same state management
- Gas consumption happens at block level, not per instruction
- Stack validation is done upfront for performance

## Resources

- PR #330 - Original threaded interpreter PR
- evmone project - Reference implementation
- CLAUDE.md - Project conventions and requirements
- `/src/evm/execution/` - Standard interpreter implementations for reference

---

*This document represents ~8 hours of implementation work on the threaded interpreter. The CODECOPY implementation was the final piece that got constructor tests working.*