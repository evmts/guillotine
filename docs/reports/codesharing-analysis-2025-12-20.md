# Codesharing Refactor Analysis Report
**Date**: 2025-12-20

## Executive Summary

This report documents findings from the code sharing investigation across Guillotine's EVM implementations. Key discoveries have changed the originally planned approach.

## Pre-flight Check Results

| Check | Status | Notes |
|-------|--------|-------|
| Main build (`zig build`) | ✅ PASS | |
| Opcode tests (`zig build test-opcodes`) | ✅ PASS | 623/623 tests pass |
| Unit tests (`zig build test-unit`) | ✅ PASS | 7/7 tests pass |
| Mini build (`cd mini && zig build`) | ❌ FAIL | WASM crypto dependency missing |
| Mini tests (`cd mini && zig build test`) | ⚠️ PARTIAL | 469/513 pass (was 452/513) |

## Key Findings

### 1. Tracer's `minimal_frame.zig` is NOT Redundant

**Original Assumption**: `src/tracer/minimal_frame.zig` (2,447 lines) is a stale copy of `mini/src/frame.zig` that should be deleted.

**Reality**: The tracer's MinimalFrame serves a **critical architectural purpose**:
- Used for **execution synchronization** between optimized Frame and reference MinimalEvm
- Called via `beforeInstruction()` in every opcode handler
- Enables **differential testing** between dispatch-based Frame and PC-based interpreter
- Required by 276/281 opcode differential tests

**Architecture**:
```
Performance EVM (Frame)       ←→  Tracer  ←→  MinimalFrame (Reference)
- Dispatch-based                   |           - PC-based
- Tail-call optimized              |           - Simple switch interpreter
- Synthetic opcodes                |           - Sequential execution
```

**Recommendation**: Phase 1 (eliminate stale tracer copy) is **NOT SAFE** to execute without major architectural refactoring.

### 2. Mini EVM Has Pre-existing Bugs (Partially Fixed)

**Root Cause**: Stack operand ordering bug in non-commutative operations.

**Fixed Operations** (5 opcodes):
- SUB: Was `top - second`, fixed to `second - top`
- DIV: Was `top / second`, fixed to `second / top`
- SDIV: Same fix
- MOD: Was `top % second`, fixed to `second % top`
- SMOD: Same fix

**Impact**: 17 additional tests now pass (452→469 out of 513)

**Remaining Issues** (44 failing tests):
- MCOPY gas calculation bugs
- JUMPI bytecode access crashes
- RETURN/REVERT memory allocation issues
- SLOAD memory corruption (segfault)

### 3. Opcode Enum Consolidation is Safe

**Duplication Found**:
- `src/opcodes/opcode.zig`: 1000 lines
- `lib/voltaire/src/primitives/opcode.zig`: 578 lines
- **419 lines are identical**

**Unique to src/opcodes/**:
- `UnifiedOpcode` enum (~354 lines) - bridges regular (0x00-0xFF) and synthetic (0x100+) opcodes
- 21 synthetic opcode variants for fusion optimization

**Recommended Approach**:
```zig
// src/opcodes/opcode.zig (new approach)
const voltaire = @import("voltaire");
pub const Opcode = voltaire.Opcode;  // Re-export standard opcodes

pub const UnifiedOpcode = enum(u16) {
    // Keep unique UnifiedOpcode for synthetic support
};
```

**Files Affected**: ~37 files need import updates
**Risk**: LOW (EVM opcodes are immutable by consensus)

### 4. Helper Extraction Opportunities

**Identified Duplications**:
- `next_instruction()`: Identical 5-line function in 11 handler files
- Address conversions: `to_u256()`/`from_u256()` in handlers_context.zig AND handlers_system.zig

**Files with `next_instruction` duplication**:
1. `handlers_arithmetic.zig`
2. `handlers_arithmetic_synthetic.zig`
3. `handlers_bitwise.zig`
4. `handlers_comparison.zig`
5. `handlers_context.zig`
6. `handlers_jump.zig`
7. `handlers_keccak.zig`
8. `handlers_log.zig`
9. `handlers_memory.zig`
10. `handlers_storage.zig`
11. `handlers_stack.zig`

**Implementation (identical across all files)**:
```zig
pub inline fn next_instruction(
    self: *FrameType,
    cursor: [*]const Dispatch.Item,
    comptime opcode: Dispatch.UnifiedOpcode
) Error!noreturn {
    const op_data = dispatch_opcode_data.getOpData(opcode, Dispatch, Dispatch.Item, cursor);
    self.afterInstruction(opcode, op_data.next_handler, op_data.next_cursor.cursor);
    return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
}
```

**Recommended Extraction**:
- Create `src/instructions/dispatch_next.zig` for shared dispatch helpers
- Reduces 55 lines to 16 lines (71% reduction)
- Zero risk: exact same implementation, marked `inline`

## Revised Phase Plan

### ❌ Phase 1: Eliminate Stale Tracer (BLOCKED)
**Status**: Not safe to execute
**Reason**: MinimalFrame is architecturally required for tracer synchronization
**Alternative**: Document purpose, consider future abstraction layer

### ✅ Phase 2: Consolidate Opcode Enum (RECOMMENDED)
**Status**: Safe to execute
**Effort**: ~4 hours
**Steps**:
1. Make `src/opcodes/opcode.zig` re-export `voltaire.Opcode`
2. Keep `UnifiedOpcode` for synthetic support
3. Update ~37 import statements
4. Run full test suite

### ✅ Phase 3: Extract Common Helpers (RECOMMENDED)
**Status**: Safe to execute
**Effort**: ~2 hours
**Steps**:
1. Create `src/instructions/dispatch_next.zig`
2. Extract `next_instruction()` from 11 handler files
3. Extract address conversion helpers
4. Run differential tests

### ⚠️ Phase 4: Shared Opcode Logic (DEFERRED)
**Status**: Higher risk, requires careful design
**Reason**: Different architectural constraints between Performance EVM and Mini EVM

## Metrics Summary

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| Mini tests passing | 452/513 | 469/513 | +17 |
| Duplicate opcode lines | 419 | 419 | 0 (not yet consolidated) |
| Duplicate next_instruction | 11 copies | 11 copies | 0 (not yet extracted) |

## Files Changed

- `mini/src/instructions/handlers_arithmetic.zig`: Fixed SUB, DIV, SDIV, MOD, SMOD operand ordering

## Recommendations

1. **Immediate**: Execute Phase 2 (opcode consolidation) and Phase 3 (helper extraction)
2. **Short-term**: Fix remaining mini EVM bugs (MCOPY, JUMPI, RETURN, SLOAD)
3. **Long-term**: Consider shared handler abstraction layer between Performance EVM and Mini EVM
4. **Document**: Add architecture documentation explaining tracer's purpose

## Test Commands

```bash
# Verify main project health
zig build test-opcodes    # 623/623 should pass
zig build test-unit       # 7/7 should pass

# Check mini improvements
cd mini && zig build test  # 469/513 should pass
```

## Implementation Priority

| Phase | Priority | Effort | Risk | Value |
|-------|----------|--------|------|-------|
| Phase 3: Helper extraction | HIGH | 2h | LOW | Immediate dedup |
| Phase 2: Opcode consolidation | MEDIUM | 4h | LOW | Cleaner architecture |
| Phase 1: Tracer elimination | BLOCKED | N/A | HIGH | Requires redesign |
| Mini bug fixes | LOW | 8h+ | MEDIUM | Separate project |

## Subagent Investigation Summary

This analysis was conducted using 6 parallel subagents:

1. **Performance EVM Explorer**: Analyzed dispatch-based architecture
2. **Mini EVM Explorer**: Analyzed PC-based interpreter structure
3. **Voltaire Explorer**: Analyzed shared primitives library
4. **Duplicate Finder**: Identified ~1,100+ duplicate lines
5. **Tracer Analyzer**: Discovered MinimalFrame's critical role
6. **Opcode Comparator**: Recommended consolidation approach
7. **Helper Analyzer**: Identified `next_instruction` extraction opportunity

## Conclusion

The original codesharing plan requires significant revision:

1. **Phase 1 is architecturally blocked** - The tracer's MinimalFrame is not redundant; it's a critical component for execution validation
2. **Phase 2 and 3 are safe to execute** - Opcode consolidation and helper extraction can proceed
3. **Mini EVM has pre-existing bugs** - Fixed 5 arithmetic operations, but 44 tests still fail

The investigation revealed that what appeared to be simple "stale copy" removal actually hides complex architectural decisions around tracer synchronization. Any future work to consolidate mini/ with the tracer must preserve the execution synchronization contract.
