# Opcode Executors Review Summary

## Overview
This document summarizes all the review findings from the opcode executor implementations in Guillotine's EVM. The reviews cover 15 different executor modules and identify key optimization opportunities, missing features, and areas for improvement.

## High-Priority Action Items

### 1. Critical Correctness Bugs

#### Operand Order in Arithmetic/Comparison (CRITICAL)
**Files**: `arithmetic.zig`, `comparison.zig`
- **Issue**: Several handlers compute `top op second_from_top` instead of `second_from_top op top`.
- **Affected**:
  - Arithmetic: `SUB`, `DIV`, `SDIV`, `MOD`, `SMOD`, `ADDMOD`, `MULMOD`, `EXP` (base/exponent swapped and gas uses wrong operand).
  - Comparison: `LT`, `GT`, `SLT`, `SGT`.
- **Fix**: Adopt uniform extraction (`b = pop`, `a = peek`) and apply `a op b`. For `ADDMOD/MULMOD`, map `(a,b,n)` to `(third,second,top)`. For `EXP`, `base=second`, `exponent=top` and charge gas by exponent bytes.
- **Impact**: Fundamental correctness; many tests should assert operand order explicitly.

### 2. Decode-Time Optimizations (HIGH IMPACT)

### 2. Decode-Time Optimizations (HIGH IMPACT)

#### Memory Operation Precomputation
**Files**: `memory.zig`, `crypto.zig`, `log.zig`
- **Opportunity**: Precompute word counts and aligned sizes during analysis phase
- **Benefit**: Eliminate runtime divisions and reduce branches
- **Examples**:
  - MLOAD/MSTORE: Precompute aligned memory size
  - KECCAK256: Precompute word count for gas calculation
  - LOG operations: Precompute data copy sizes

#### Instruction Fusion
**File**: `arithmetic.zig`
- **Opportunity**: Fuse common sequences like PUSH/PUSH/ADD
- **Benefit**: Reduce dispatch overhead in arithmetic-heavy blocks
- **Implementation**: Add fusion detection in analysis phase

### 3. Stack and Control Flow Optimizations

#### Inline Hot Operations
**Files**: `comparison.zig`, `control.zig`
- **Operations**: ISZERO, EQ (very common operations)
- **PC optimization**: Cache current PC in interpreter loop
- **Benefit**: Eliminate function call overhead for frequent ops

## Module-by-Module Summary

### Arithmetic Operations (`arithmetic.zig`)
- ⚠️ Fix operand order in multiple ops (`SUB/DIV/SDIV/MOD/SMOD/ADDMOD/MULMOD/EXP`).
- ✅ Efficient usage of `U256` helpers and early exits in `EXP` (post-fix).
- 🔧 Add micro-fusion for PUSH/PUSH/ALU sequences.
- 🔧 Expand SDIV/SMOD test coverage (MIN_I256/-1 edge case).

### Bitwise Operations (`bitwise.zig`)
- ✅ Correct masking and shift semantics
- ✅ Unsafe stack access for performance
- 🔧 Precompute common masks for BYTE/SAR
- 🔧 Add fuzz tests for shift counts ≥256

### Block Information (`block.zig`)
- ✅ Context/host provided reads
- 🔧 Ensure strict hardfork gating
- 🔧 Add fork-specific tests for each opcode

### Comparison Operations (`comparison.zig`)
- ⚠️ Fix operand order in `LT/GT/SLT/SGT`.
- ✅ `EQ`/`ISZERO` are in good shape.
- 🔧 Inline ISZERO and possibly EQ.
- 🔧 Add boundary-focused fuzz tests.

### Control Flow (`control.zig`)
- ✅ Control flow handled at interpreter level
- ✅ Minimal handler work
- 🔧 Optimize PC reads with cached value

### Cryptographic Operations (`crypto.zig`)
- ✅ Correct memory reading and per-word gas
- 🔧 Precompute word counts for immediate cases
- 🔧 Optimize large input handling

### Environment Operations (`environment.zig`)
- ✅ Proper context reads
- 🔧 Ensure consistent warm/cold cost application
- 🔧 Consider prewarming self where allowed

### Logging Operations (`log.zig`)
- ✅ Static context protection
- ✅ Proper topic and data handling
- 🔧 Precompute memory expansion sizes
- 🔧 Test large payloads

### Memory Operations (`memory.zig`)
- ✅ Correct expansion gas charging
- ✅ MCOPY overlap handling
- 🔧 Factor out charge+ensure helper
- 🔧 Benchmark memmove-style implementation

### Storage Operations (`storage.zig`)
- ✅ TLOAD/TSTORE transient storage
- ✅ SSTORE uses EIP-2200/3529 via `storage_costs.calculateSstoreCost`
- 🔧 Add comprehensive transition/refund tests; audit journaling under reverts
- 🔧 Ensure uniform warm/cold paths

### System Operations (`system.zig`)
- ✅ Correct EIP-150 (63/64 rule)
- ✅ Proper memory expansion sequence
- ✅ EIP-2929 warm/cold costs
- 🔧 Pre-validate args/ret sizes
- 🔧 Add microbenchmark suite

### Supporting Files
- **adapter.zig**: Type-safe wrappers, consider always_inline
- **execution_error.zig**: Error taxonomy, ensure consistent mapping
- **execution_result.zig**: Compact result struct, check alignment
- **null_opcode.zig**: Must remain unreachable for inline paths

## Comparison with evmone/revm

### Where Guillotine Matches
- Block-based gas precomputation
- Minimal per-instruction overhead
- Efficient stack operations
- Proper hardfork gating

### Where Guillotine Can Improve
1. **Correctness fixes**: Operand order in arithmetic/comparison
2. **Decode-time work**: Move more computation to analysis phase
3. **Micro-fusion**: Implement pattern-based optimizations
4. **Inlining strategy**: More aggressive for hot operations

### Expected Performance Gains
- Decode-time optimizations: 10-20% on memory/crypto-heavy
- Instruction fusion: 5-15% on arithmetic-heavy
- Hot operation inlining: 2-5% overall
- SSTORE completion: Correctness requirement, enables storage benchmarks

## Recommended Implementation Order

1. **Phase 1 - Critical Correctness**
   - Complete SSTORE gas/refund implementation
   - Add comprehensive test coverage

2. **Phase 2 - High-Impact Optimizations**
   - Implement decode-time precomputation for memory ops
   - Add instruction fusion for arithmetic sequences
   - Inline ISZERO and EQ operations

3. **Phase 3 - Polish and Benchmarking**
   - Add microbenchmark suites
   - Implement remaining precomputation opportunities
   - Fine-tune based on profiling data

## Testing Priorities

1. **Correctness Tests**
   - Operand order for all arithmetic/comparison ops
   - SSTORE transition matrix
   - Signed arithmetic edge cases
   - Fork-specific behavior

2. **Fuzz Testing**
   - Shift operations with large counts
   - Memory operations with unaligned access
   - Call depth and gas edge cases

3. **Performance Benchmarks**
   - CALL/CREATE microbenchmarks
   - Memory operation patterns
   - Arithmetic-heavy workloads

## Conclusion

Guillotine's opcode executors are well-structured and largely correct, with efficient stack handling and proper gas accounting. The main gaps are:

1. **SSTORE implementation** (critical for correctness)
2. **Decode-time optimizations** (significant performance opportunity)
3. **Instruction fusion** (moderate performance gains)
4. **Test coverage** (especially edge cases and fuzz testing)

Addressing these items will bring Guillotine to parity with evmone and revm in both correctness and performance.
