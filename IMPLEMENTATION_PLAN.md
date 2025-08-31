# Implementation Plan: Advanced Fusion Patterns

## Architecture Overview

Based on the codebase analysis, the current fusion system has:
1. **Opcodes**: Defined in `src/opcodes/` with synthetic opcodes for 2-opcode fusions
2. **Bytecode Analysis**: In `src/bytecode/bytecode.zig` with fusion detection
3. **Dispatch System**: In `src/preprocessor/dispatch.zig` for execution scheduling
4. **Handlers**: In `src/instructions/handlers_*_synthetic.zig` for fusion execution

## Implementation Strategy

### Phase 1: Extend Synthetic Opcodes
Add new synthetic opcodes to `src/opcodes/opcode_synthetic.zig`:
- `CONSTANT_FOLD` (0xBD) - For pre-computed arithmetic
- `MULTI_PUSH_2` (0xBE), `MULTI_PUSH_3` (0xBF) - Batch PUSH operations
- `MULTI_POP_2` (0xC0), `MULTI_POP_3` (0xC1) - Batch POP operations
- `ISZERO_JUMPI` (0xC2) - Combined zero-check and jump
- `DUP2_MSTORE_PUSH` (0xC3) - Memory pattern optimization

### Phase 2: Pattern Detection in Bytecode
Extend `src/bytecode/bytecode.zig`:
1. Add `AdvancedFusionType` enum for new patterns
2. Implement pattern detection functions:
   - `checkConstantFoldingPattern()`
   - `checkMultiPushPattern()`
   - `checkMultiPopPattern()`
   - `checkIszeroJumpiPattern()`
   - `checkDup2MstorePushPattern()`
3. Update `getFusionData()` to return advanced fusion info

### Phase 3: Dispatch Integration
Update `src/preprocessor/dispatch.zig`:
1. Add new Item types for advanced fusion metadata:
   - `constant_fold_value: u256`
   - `multi_op_count: u8`
2. Update `processRegularOpcode()` to detect and handle advanced patterns
3. Add fusion priority ordering (longest patterns first)

### Phase 4: Handler Implementation
Create new handler files:
- `src/instructions/handlers_constant_fold.zig`
- `src/instructions/handlers_multi_op.zig`
- `src/instructions/handlers_advanced_synthetic.zig`

Each handler must:
1. Read fusion metadata from dispatch cursor
2. Execute the fused operation atomically
3. Update stack correctly
4. Account for proper gas costs
5. Advance cursor past all fused opcodes

### Phase 5: Testing Strategy (TDD)
For each fusion pattern:
1. **Unit Tests**: Test pattern detection in isolation
2. **Integration Tests**: Test dispatch scheduling with patterns
3. **Execution Tests**: Test handler execution correctness
4. **Differential Tests**: Compare against non-fused execution
5. **Gas Tests**: Verify correct gas accounting
6. **Edge Case Tests**: Patterns at bytecode boundaries

## File Structure

```
src/
├── opcodes/
│   ├── opcode_synthetic.zig (extend with new opcodes)
│   └── opcode_advanced.zig (NEW: advanced fusion definitions)
├── bytecode/
│   ├── bytecode.zig (extend fusion detection)
│   └── bytecode_fusion.zig (NEW: advanced pattern detection)
├── preprocessor/
│   ├── dispatch.zig (update for advanced patterns)
│   └── dispatch_fusion.zig (NEW: fusion scheduling logic)
└── instructions/
    ├── handlers_constant_fold.zig (NEW)
    ├── handlers_multi_op.zig (NEW)
    └── handlers_advanced_synthetic.zig (NEW)
```

## Test Plan

### Test Execution Order (TDD):
1. **Constant Folding**
   - Test: `PUSH1 5, PUSH1 3, ADD` → Single PUSH 8
   - Test: `PUSH1 10, PUSH1 2, SUB` → Single PUSH 8
   - Test: `PUSH1 4, PUSH1 2, PUSH1 3, SHL, SUB` → Single PUSH -12

2. **Multi-PUSH**
   - Test: Two consecutive PUSH operations
   - Test: Three consecutive PUSH operations
   - Test: Mixed PUSH sizes (PUSH1, PUSH2, etc.)

3. **Multi-POP**
   - Test: `POP, POP` → Single 2-POP
   - Test: `POP, POP, POP` → Single 3-POP

4. **ISZERO-JUMPI**
   - Test: `ISZERO, PUSH2 target, JUMPI`
   - Test: With valid jump destination
   - Test: With invalid jump destination

5. **DUP2-MSTORE-PUSH**
   - Test: `DUP2, MSTORE, PUSH1 value`
   - Test: Memory bounds checking
   - Test: Stack underflow handling

## Implementation Steps

### Step 1: Set up test infrastructure
```zig
// test/fusion/advanced_fusion_test.zig
test "constant folding: PUSH1 a, PUSH1 b, ADD" {
    // Test will initially fail (RED)
}
```

### Step 2: Implement minimal code to pass test
```zig
// src/opcodes/opcode_synthetic.zig
pub const OpcodeSynthetic = enum(u8) {
    // ... existing opcodes ...
    CONSTANT_FOLD = 0xBD,
}
```

### Step 3: Refactor and optimize
- Clean up code
- Add documentation
- Optimize performance

### Step 4: Repeat for each pattern

## Success Criteria

1. All advanced fusion patterns detected correctly
2. All handlers execute with correct semantics
3. Gas accounting matches expected values
4. No performance regression on existing code
5. All tests pass including differential tests
6. Memory safety maintained throughout

## Risk Mitigation

1. **Pattern Conflicts**: Use priority ordering (longest first)
2. **Gas Accounting**: Carefully track gas for entire fused sequence
3. **Stack Safety**: Validate stack requirements before fusion
4. **Jump Validation**: Ensure jump targets remain valid
5. **Memory Safety**: Use bounds checking in all handlers

## Performance Expectations

- **Constant Folding**: 50-70% reduction in execution time for folded sequences
- **Multi-PUSH/POP**: 30-40% reduction in dispatch overhead
- **ISZERO-JUMPI**: 20-30% improvement in conditional branches
- **DUP2-MSTORE-PUSH**: 25-35% improvement in memory operations

## Next Steps

1. Begin with constant folding pattern (simplest, highest impact)
2. Write failing tests first (TDD red phase)
3. Implement minimal code to pass tests (green phase)
4. Refactor for clarity and performance (refactor phase)
5. Move to next pattern and repeat