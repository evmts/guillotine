# Advanced Interpreter Implementation Prompts

## Overview

This directory contains detailed implementation prompts for transforming Guillotine's EVM interpreter into a high-performance advanced interpreter following evmone's proven architecture. The implementation is broken into 7 sequential phases, each building upon the previous ones.

## Quick Reference

| Phase | File | Description | Dependencies | Expected Impact |
|-------|------|-------------|--------------|-----------------|
| 0 | `0_critical_fixes.md` | Fix CALL/CREATE operations | None | Enables real benchmarks |
| 1 | `1_stack_pointer_refactor.md` | Convert stack to pointer-based | Phase 0 | 10-20% improvement |
| 2 | `2_block_metadata_analysis.md` | Pre-compute block gas/stack | Phase 1 | Foundation for Phase 3 |
| 3 | `3_beginblock_intrinsic.md` | Bulk validation per block | Phase 2 | 30-40% improvement |
| 4 | `4_jump_analysis_optimization.md` | Binary search for jumps | Phase 2 | Better jump performance |
| 5 | `5_instruction_stream_generation.md` | Generate instruction stream | Phases 2-4 | Enables Phase 6 |
| 6 | `6_advanced_execution_loop.md` | Main execution loop | All previous | 2x improvement |
| 7 | `7_performance_benchmarking.md` | Benchmark and optimize | Phase 6 | Final tuning |

## Implementation Order

The phases MUST be implemented in numerical order due to dependencies:

```
0. Critical Fixes (CALL/CREATE operations)
   ↓
1. Stack Pointer Refactor
   ↓
2. Block Metadata Analysis
   ↓
3. BEGINBLOCK Intrinsic ← 4. Jump Optimization
   ↓                        ↓
5. Instruction Stream Generation
   ↓
6. Advanced Execution Loop
   ↓
7. Performance Benchmarking
```

## Key Concepts

### What is an Advanced Interpreter?

Unlike traditional bytecode interpreters that decode and validate on every instruction, an advanced interpreter:
1. **Pre-analyzes** bytecode into blocks
2. **Pre-computes** gas costs and stack requirements per block
3. **Generates** an instruction stream with embedded arguments
4. **Validates** once per block instead of per instruction
5. **Dispatches** through function pointers without decoding

### Why These Specific Phases?

1. **Stack pointer** optimization removes method call overhead in the hottest path
2. **Block analysis** identifies sequences of instructions that can be validated together
3. **BEGINBLOCK** performs bulk validation, eliminating 90% of checks
4. **Jump optimization** with binary search scales better than bit vectors
5. **Instruction stream** eliminates bytecode decoding during execution
6. **Advanced loop** ties everything together with minimal dispatch overhead
7. **Benchmarking** ensures we meet performance targets

## Current State (from Status Report)

- **Performance**: Currently 50-70% of evmone
- **Critical Issues**: CALL/CREATE operations broken
- **Advanced Interpreter**: 40% complete (structures exist, not integrated)

## Expected Outcomes

### Performance Improvements
- **Baseline**: 50-70% of evmone (current state)
- **Phase 0**: Enables real benchmarking (fixes critical ops)
- **Phase 1**: 10-20% faster (60-85% of evmone)
- **Phase 3**: 30-40% faster (65-100% of evmone)
- **Phase 6**: 2x improvement (100-140% of evmone)
- **Phase 7**: Match/exceed evmone (100-150% of evmone)

### Memory Overhead
- Instruction stream: ~2x bytecode size
- Push value storage: ~10% of bytecode
- Block metadata: ~5% of bytecode
- Total: ~3-4x bytecode size (acceptable tradeoff)

## Current PR State

PR #396 attempted multiple optimizations simultaneously but lacks:
- Proper stack pointer implementation
- Actual instruction stream generation
- BEGINBLOCK intrinsic
- Advanced execution loop
- Comprehensive benchmarking

These prompts extract the good parts (SoA, branch hints, precompile opts) and properly implement the missing core components.

## Success Criteria

Each phase has specific success criteria defined in its prompt:
- All tests must pass
- No memory leaks
- Measurable performance improvement
- Clean integration with existing code

## How to Use These Prompts

1. **Start with Phase 0** - Fix critical broken operations first
2. **Complete each phase fully** before moving to next
3. **Run tests after each phase** - No regressions allowed
4. **Benchmark at each phase** - Track improvements
5. **Document changes** - Update CLAUDE.md as needed

## Important Notes

- The implementation follows evmone's architecture closely but improves where possible
- We maintain a fallback to traditional interpreter mode
- Memory overhead is acceptable for the performance gains
- Each phase is independently valuable even if later phases aren't completed

## Questions to Consider

Before starting implementation:
1. Should we cache instruction streams between calls? (Yes, with LRU)
2. Should we maintain traditional mode? (Yes, as fallback)
3. What's the minimum contract size for advanced mode? (100 bytes)
4. How do we handle hostile bytecode? (Fallback to traditional)

## Additional Resources

- See `PLAN.md` in parent directory for overall strategy
- Check evmone source in `evmone/lib/evmone/advanced_*.{hpp,cpp}`
- Review existing Guillotine code in `src/evm/`
- Benchmark with official tests in `bench/official/`

---

Ready to transform Guillotine into a high-performance EVM? Start with Phase 1!