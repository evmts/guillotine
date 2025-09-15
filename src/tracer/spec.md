# Tracer Specification

## Overview

The tracer validates that the optimized Frame execution with instruction fusion produces semantically equivalent results to linear bytecode execution. It uses MinimalEvm as a reference implementation that executes bytecode step-by-step without optimizations.

## Design Principles

1. **Validation Before Execution**: Before the Frame executes an opcode (regular or fused), the tracer verifies that MinimalEvm sees the expected bytecode sequence.

2. **Step-by-Step Execution**: MinimalEvm executes one base opcode at a time, allowing precise validation of fusion sequences.

3. **Opcode Verification**: For each step, verify that the bytecode at the current PC matches the expected opcode.

## Implementation Strategy

### For Regular Opcodes (0x00-0xFF)

1. Verify the bytecode at MinimalEvm's PC matches the expected opcode
2. Execute exactly one step in MinimalEvm
3. The Frame and MinimalEvm should remain synchronized

### For Fusion Opcodes (0x100+)

1. Verify the bytecode sequence matches the fusion pattern
2. Execute N steps in MinimalEvm (where N depends on the fusion type)
3. After N steps, both EVMs should have executed the equivalent operations

## Fusion Patterns

### Two-Operation Fusions

#### PUSH + Arithmetic/Logic Operations
- **PUSH_ADD_INLINE/POINTER**: PUSH[N] (0x60-0x7F) + ADD (0x01)
- **PUSH_MUL_INLINE/POINTER**: PUSH[N] (0x60-0x7F) + MUL (0x02)
- **PUSH_SUB_INLINE/POINTER**: PUSH[N] (0x60-0x7F) + SUB (0x03)
- **PUSH_DIV_INLINE/POINTER**: PUSH[N] (0x60-0x7F) + DIV (0x04)
- **PUSH_AND_INLINE/POINTER**: PUSH[N] (0x60-0x7F) + AND (0x16)
- **PUSH_OR_INLINE/POINTER**: PUSH[N] (0x60-0x7F) + OR (0x17)
- **PUSH_XOR_INLINE/POINTER**: PUSH[N] (0x60-0x7F) + XOR (0x18)

#### PUSH + Memory Operations
- **PUSH_MLOAD_INLINE/POINTER**: PUSH[N] (0x60-0x7F) + MLOAD (0x51)
- **PUSH_MSTORE_INLINE/POINTER**: PUSH[N] (0x60-0x7F) + MSTORE (0x52)
- **PUSH_MSTORE8_INLINE/POINTER**: PUSH[N] (0x60-0x7F) + MSTORE8 (0x53)

#### PUSH + Control Flow
- **JUMP_TO_STATIC_LOCATION**: PUSH[N] (0x60-0x7F) + JUMP (0x56)
- **JUMPI_TO_STATIC_LOCATION**: PUSH[N] (0x60-0x7F) + JUMPI (0x57)

#### Multi-Operations
- **MULTI_PUSH_2**: PUSH[N] + PUSH[M]
- **MULTI_PUSH_3**: PUSH[N] + PUSH[M] + PUSH[O]
- **MULTI_POP_2**: POP (0x50) + POP (0x50)
- **MULTI_POP_3**: POP (0x50) + POP (0x50) + POP (0x50)

### Three-Operation Fusions

- **DUP2_MSTORE_PUSH**: DUP2 (0x81) + MSTORE (0x52) + PUSH[N]
- **DUP3_ADD_MSTORE**: DUP3 (0x82) + ADD (0x01) + MSTORE (0x52)
- **SWAP1_DUP2_ADD**: SWAP1 (0x90) + DUP2 (0x81) + ADD (0x01)
- **PUSH_DUP3_ADD**: PUSH[N] + DUP3 (0x82) + ADD (0x01)
- **MLOAD_SWAP1_DUP2**: MLOAD (0x51) + SWAP1 (0x90) + DUP2 (0x81)
- **ISZERO_JUMPI**: ISZERO (0x15) + PUSH[N] + JUMPI (0x57)
- **EQ_JUMPI**: EQ (0x14) + PUSH[N] + JUMPI (0x57)
- **CALLVALUE_CHECK**: CALLVALUE (0x34) + DUP1 (0x80) + ISZERO (0x15)
- **PUSH0_REVERT**: PUSH0 (0x5F) + PUSH0 (0x5F) + REVERT (0xFD)
- **PUSH_ADD_DUP1**: PUSH[N] + ADD (0x01) + DUP1 (0x80)

### Four-Operation Fusions

- **FUNCTION_DISPATCH**: PUSH4 (0x63) + EQ (0x14) + PUSH[N] + JUMPI (0x57)

## Validation Algorithm

```
function beforeOp(opcode: UnifiedOpcode):
    if MinimalEvm is stopped or reverted:
        return

    if opcode <= 0xFF:
        // Regular opcode
        assert(bytecode[pc] == opcode)
        MinimalEvm.step()
    else:
        // Fusion opcode
        opcodes = getFusionSequence(opcode)
        for each expected_opcode in opcodes:
            assert(bytecode[pc] == expected_opcode)
            MinimalEvm.step()
```

## Error Handling

- If bytecode doesn't match expected pattern: Log error with details
- If MinimalEvm.step() fails: Log error but continue (MinimalEvm may have different gas/memory limits)
- Validation errors should not stop Frame execution (tracer is observational only)

## Performance Considerations

- Validation only runs in Debug and ReleaseSafe modes
- ReleaseFast and ReleaseSmall skip all validation for maximum performance
- Opcode verification is done before each step to catch mismatches early