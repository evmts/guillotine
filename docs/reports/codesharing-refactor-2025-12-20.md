# Codesharing Refactor Report - 2025-12-20

## Summary

Implemented **Phase 3** of the codesharing refactor plan. Phase 2 (Opcode Consolidation) was analyzed but determined to be BLOCKED due to architectural coupling.

## Phase 3: Extract next_instruction Helper - COMPLETED

### Problem
Identical 5-line `next_instruction` function was duplicated in 11 handler files:
- handlers_arithmetic.zig
- handlers_arithmetic_synthetic.zig
- handlers_bitwise.zig
- handlers_comparison.zig
- handlers_context.zig
- handlers_jump.zig
- handlers_keccak.zig
- handlers_log.zig
- handlers_memory.zig
- handlers_stack.zig
- handlers_storage.zig

### Solution
Created `src/instructions/dispatch_next.zig` with shared `nextInstruction` helper:

```zig
pub inline fn nextInstruction(
    comptime FrameType: type,
    self: *FrameType,
    cursor: [*]const FrameType.Dispatch.Item,
    comptime opcode: FrameType.Dispatch.UnifiedOpcode,
) FrameType.Error!noreturn {
    const op_data = dispatch_opcode_data.getOpData(opcode, FrameType.Dispatch, FrameType.Dispatch.Item, cursor);
    self.afterInstruction(opcode, op_data.next_handler, op_data.next_cursor.cursor);
    return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
}
```

### Changes
- Created: `src/instructions/dispatch_next.zig` (19 lines)
- Modified: 11 handler files (removed duplicate function, updated calls)
- Net reduction: ~55 lines of duplicate code removed
- Commit: `c215c757`

### Validation
- Build: PASS
- test-opcodes: 623/623 PASS
- test-unit: 7/7 PASS

## Phase 2: Consolidate Opcode Enum - BLOCKED

### Analysis
Two opcode files exist:
- `src/opcodes/opcode.zig` (1000 lines)
- `lib/voltaire/src/primitives/opcode.zig` (578 lines)

### Findings

1. **Base `Opcode` enum is identical** in both files (~170 lines of enum values)

2. **`UnifiedOpcode` is unique to src/opcodes/opcode.zig**:
   - Extends to u16 (vs u8 for regular opcodes)
   - Includes synthetic opcode values (0x100+)
   - Depends on `OpcodeSynthetic` from `opcode_synthetic.zig`
   - Essential for dispatch-based execution model

3. **25 files import from src/opcodes/opcode.zig**:
   - Many depend on `UnifiedOpcode` for dispatch system
   - Tight coupling with tracer, preprocessor, frame, bytecode modules

### Blocking Factors

1. **Architectural coupling**: `UnifiedOpcode` bridges standard EVM opcodes with synthetic opcodes for performance optimization. This is Performance EVM-specific and shouldn't be in voltaire.

2. **Risk assessment**: Consolidating would require:
   - Splitting `UnifiedOpcode` into separate file
   - Updating 25+ import statements
   - Potential breakage in dispatch system
   - Risk of introducing consensus-critical bugs

3. **Limited value**: The duplication is the base `Opcode` enum. The methods (isPush, isDup, etc.) are also duplicated but changing them risks subtle behavioral differences.

### Recommendation
**DEFER Phase 2** - The risk/reward ratio is unfavorable:
- Risk: High (25 files, dispatch system critical path)
- Reward: Moderate (~250-400 lines of enum dedup)
- Alternative: Document the intentional duplication and ensure both enums stay synchronized

## Phase 1: Eliminate Stale Tracer Copy - PREVIOUSLY BLOCKED

From prior analysis: `src/tracer/minimal_frame.zig` is NOT a stale copy. It's architecturally required for execution synchronization between Performance EVM (dispatch-based) and MinimalFrame (PC-based reference). The tracer uses `beforeInstruction()` hooks to validate both implementations produce identical results.

## Metrics

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| Duplicate `next_instruction` functions | 11 | 0 | -11 |
| Lines in handlers (net) | ~160 | ~105 | -55 |
| Files modified | 0 | 12 | +12 |
| New files | 0 | 1 | +1 |
| Test results | 630/630 | 630/630 | No change |

## Remaining Duplication (Documented)

1. **Opcode enum** (`src/opcodes/opcode.zig` vs `lib/voltaire/src/primitives/opcode.zig`):
   - Status: Intentional (Performance EVM needs UnifiedOpcode extension)
   - Mitigation: Keep synchronized manually

2. **MinimalFrame** (`src/tracer/minimal_frame.zig` vs `mini/src/`):
   - Status: Architecturally required for execution synchronization
   - Mitigation: This is a validation mechanism, not duplication

3. **Address conversions** (`to_u256`/`from_u256` in handlers_context.zig and handlers_system.zig):
   - Status: Could be extracted but very low impact (~10 lines)
   - Recommendation: Extract in future if touching those files

## Conclusion

Phase 3 successfully eliminated 55 lines of duplicate code across 11 handler files. Phases 1 and 2 are blocked due to architectural requirements of the tracer system and dispatch-based execution model. The remaining duplication is either intentional or carries unacceptable risk for consolidation.
