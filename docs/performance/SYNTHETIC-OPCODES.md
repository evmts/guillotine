# Synthetic Opcodes

Synthetic opcodes are fused operations that combine common bytecode patterns into single dispatch items, reducing schedule length and improving performance while maintaining exact EVM semantics.

## Overview

During bytecode analysis, Guillotine detects common patterns and replaces them with synthetic handlers:

```
Original:    PUSH1 0x20, MSTORE    (2 opcodes, 3 schedule items: PUSH1 handler, push_inline, MSTORE handler)
Fused:       PUSH_MSTORE_INLINE    (1 synthetic handler + 1 metadata)

Result: Fewer dispatch items, same gas cost, identical behavior
```

## Synthetic Opcode Definitions

All synthetic opcodes are defined in `src/opcodes/opcode_synthetic.zig`:

```zig
// src/opcodes/opcode_synthetic.zig:17-64
pub const OpcodeSynthetic = enum(u8) {
    // Arithmetic fusions (PUSH + operation)
    PUSH_ADD_INLINE = 0xA5,      // PUSH small + ADD
    PUSH_ADD_POINTER = 0xA6,     // PUSH large + ADD
    PUSH_SUB_INLINE = 0xAF,      // PUSH small + SUB
    PUSH_SUB_POINTER = 0xB0,     // PUSH large + SUB
    PUSH_MUL_INLINE = 0xA7,      // PUSH small + MUL
    PUSH_MUL_POINTER = 0xA8,     // PUSH large + MUL
    PUSH_DIV_INLINE = 0xA9,      // PUSH small + DIV
    PUSH_DIV_POINTER = 0xAA,     // PUSH large + DIV

    // Bitwise fusions
    PUSH_AND_INLINE = 0xB5,      // PUSH small + AND
    PUSH_AND_POINTER = 0xB6,     // PUSH large + AND
    PUSH_OR_INLINE = 0xB7,       // PUSH small + OR
    PUSH_OR_POINTER = 0xB8,      // PUSH large + OR
    PUSH_XOR_INLINE = 0xB9,      // PUSH small + XOR
    PUSH_XOR_POINTER = 0xBA,     // PUSH large + XOR

    // Memory fusions
    PUSH_MLOAD_INLINE = 0xB1,    // PUSH offset + MLOAD
    PUSH_MLOAD_POINTER = 0xB2,
    PUSH_MSTORE_INLINE = 0xB3,   // PUSH offset + MSTORE
    PUSH_MSTORE_POINTER = 0xB4,
    PUSH_MSTORE8_INLINE = 0xBB,  // PUSH offset + MSTORE8
    PUSH_MSTORE8_POINTER = 0xBC,

    // Static jump optimizations
    JUMP_TO_STATIC_LOCATION = 0xBD,   // Pre-resolved JUMP
    JUMPI_TO_STATIC_LOCATION = 0xBE,  // Pre-resolved JUMPI

    // Multi-operation fusions
    MULTI_PUSH_2 = 0xBF,         // Two consecutive PUSHes
    MULTI_PUSH_3 = 0xC0,         // Three consecutive PUSHes
    MULTI_POP_2 = 0xC1,          // Two consecutive POPs
    MULTI_POP_3 = 0xC2,          // Three consecutive POPs

    // Pattern fusions (3+ opcodes)
    ISZERO_JUMPI = 0xC3,         // ISZERO + PUSH + JUMPI
    DUP2_MSTORE_PUSH = 0xC4,     // DUP2 + MSTORE + PUSH
    DUP3_ADD_MSTORE = 0xC5,      // DUP3 + ADD + MSTORE
    SWAP1_DUP2_ADD = 0xC6,       // SWAP1 + DUP2 + ADD
    PUSH_DUP3_ADD = 0xC7,        // PUSH + DUP3 + ADD

    // High-level pattern fusions
    FUNCTION_DISPATCH = 0xC8,    // PUSH4 + EQ + PUSH + JUMPI (selector routing)
    CALLVALUE_CHECK = 0xC9,      // CALLVALUE + DUP1 + ISZERO (payable check)
    PUSH0_REVERT = 0xCA,         // PUSH0 + PUSH0 + REVERT (error pattern)
    PUSH_ADD_DUP1 = 0xCB,        // PUSH + ADD + DUP1 (loop pattern)
    MLOAD_SWAP1_DUP2 = 0xCC,     // MLOAD + SWAP1 + DUP2 (memory pattern)

    // Control-flow helpers
    BACKWARD_LOOP_JUMPI = 0xCD,  // PUSH+JUMPI (exit) + [body] + PUSH+JUMP (loop)
    BLOCK_BEGIN = 0xCE,          // Block entered by falling through a non-taken JUMPI
    INVALID_JUMP_TARGET = 0xCF,  // Taken static jump to a non-JUMPDEST
};
```

## Inline vs Pointer

Synthetic opcodes come in two variants based on push value size:

### Inline (≤8 bytes)
Value embedded directly in metadata - no indirection:

```zig
// For PUSH1-PUSH8 values
push_inline: PushInlineMetadata { .value: u64 }

// Handler reads value directly
const value = cursor[1].push_inline.value;
```

### Pointer (>8 bytes)
Value heap-allocated, metadata contains pointer:

```zig
// For PUSH9-PUSH32 values
push_pointer: PushPointerMetadata { .value_ptr: *const WordType }

// Handler dereferences pointer
const value = cursor[1].push_pointer.value_ptr.*;
```

## Handler Implementation

### Simple Fusion: PUSH_ADD_INLINE

```zig
// src/instructions/handlers_arithmetic_synthetic.zig:26
pub fn push_add_inline(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
    @branchHint(.likely);
    // Tracer sync (executes PUSH + ADD in reference impl)
    self.beforeInstruction(.PUSH_ADD_INLINE, cursor);
    validate_stack(self);

    // Push value from inline metadata (cursor[1].push_inline)
    const op_data = dispatch_opcode_data.getOpData(.PUSH_ADD_INLINE, Dispatch, Dispatch.Item, cursor);

    // Perform ADD: stack[top] = push_value + stack[top]
    self.stack.set_top_unsafe(op_data.metadata.value +% self.stack.peek_unsafe());

    // Tail-call next (cursor[2], past handler + metadata)
    return dispatch_next.nextInstruction(FrameType, self, cursor, .PUSH_ADD_INLINE);
}
```

### Complex Fusion: FUNCTION_DISPATCH

```zig
// src/instructions/handlers_advanced_synthetic.zig:285 (condensed)
// PUSH4 selector + EQ + PUSH target + JUMPI
// Common Solidity function dispatch pattern
pub fn function_dispatch(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
    self.beforeInstruction(.FUNCTION_DISPATCH, cursor);
    const op_data = dispatch_opcode_data.getOpData(.FUNCTION_DISPATCH, Dispatch, Dispatch.Item, cursor);

    // Metadata: cursor[1] holds the selector, cursor[2] the jump target
    const selector = @as(u32, @intCast(op_data.items[0].push_inline.value));
    const target = op_data.items[1].push_pointer.value_ptr.*;

    // PUSH4 selector, EQ against the calldata selector, PUSH target, JUMPI
    // (the handler runs each step on the stack)
    ...

    if (condition != 0) {
        // Jump to function body through the jump table
        const dest_pc: FrameType.PcType = @intCast(dest);
        if (self.jump_table.findJumpTarget(dest_pc)) |jump_dispatch| {
            self.afterInstruction(.FUNCTION_DISPATCH, jump_dispatch.cursor[0].opcode_handler, jump_dispatch.cursor);
            return @call(FrameType.Dispatch.getTailCallModifier(), jump_dispatch.cursor[0].opcode_handler, .{ self, jump_dispatch.cursor });
        }
        self.afterComplete(.FUNCTION_DISPATCH);
        return Error.InvalidJump;
    }

    // Continue to next dispatch check (cursor[3])
    self.afterInstruction(.FUNCTION_DISPATCH, op_data.next_handler, op_data.next_cursor.cursor);
    return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
}
```

## Pattern Detection

The bytecode iterator detects patterns while the schedule is built. For each
fusion candidate it calls `Bytecode.getFusionData`, which tries the longest
patterns first (FUNCTION_DISPATCH, ISZERO_JUMPI, the 3-opcode patterns,
MULTI_PUSH/MULTI_POP) and falls back to the 2-opcode PUSH + op fusions:

```zig
// src/bytecode/bytecode.zig:695 (condensed)
pub fn getFusionData(self: *const Self, pc: PcType) OpcodeData {
    // Check function dispatch pattern first (can be 8+ bytes)
    if (self.checkFunctionDispatchPattern(pc)) |fusion| return fusion;
    if (self.checkIszeroJumpiPattern(pc)) |fusion| return fusion;
    // ... other 3-opcode, MULTI_PUSH and MULTI_POP checks ...

    // Existing 2-opcode fusions (PUSH + op): the second opcode follows the push data
    const first_op = self.get_unsafe(pc);
    if (first_op >= 0x60 and first_op <= 0x7F) {
        const second_op_pc = pc + 1 + (first_op - 0x5F);
        switch (self.get_unsafe(second_op_pc)) {
            0x01 => return OpcodeData{ .push_add_fusion = .{ .value = value } },
            // ... MUL, SUB, DIV, AND, OR, XOR, MLOAD, MSTORE, MSTORE8, JUMP, JUMPI
        }
    }
    // ...
}
```

`src/bytecode/bytecode_analyze.zig` holds a separate analyzer used only by
the C bytecode API (`evm_bytecode_analyze`).

## Gas Accounting

Synthetic opcodes maintain exact gas semantics:

```zig
// Gas cost = sum of fused operations
// PUSH_ADD_INLINE: 3 (PUSH) + 3 (ADD) = 6 gas
// FUNCTION_DISPATCH: 3 (PUSH4) + 3 (EQ) + 3 (PUSH) + 10 (JUMPI) = 19 gas
```

## Tracer Synchronization

The tracer must execute multiple reference steps for synthetic opcodes:

```zig
// src/tracer/minimal_evm_sync.zig
const SyntheticOpcodeSteps = struct {
    const PUSH_ADD_INLINE = 2;      // PUSH + ADD
    const PUSH_MSTORE_INLINE = 2;   // PUSH + MSTORE
    const FUNCTION_DISPATCH = 4;    // PUSH4 + EQ + PUSH + JUMPI
    const MULTI_PUSH_3 = 3;         // 3 PUSHes
    // ...
};

// getMaxStepsForOpcode maps each synthetic opcode to its step count
// (regular opcodes => 1); executeMinimalEvmForOpcode runs that many
// MinimalEvm steps.
pub fn executeMinimalEvmForOpcode(tracer: anytype, evm: *MinimalEvm,
    comptime opcode: UnifiedOpcode, frame: anytype, cursor: ...) void
```

## Compile-Time Validation

Synthetic opcodes must not conflict with standard EVM opcodes:

```zig
// src/opcodes/opcode_synthetic.zig:101-112
comptime {
    @setEvalBranchQuota(20000);
    for (@typeInfo(OpcodeSynthetic).@"enum".fields) |syn_field| {
        if (std.meta.intToEnum(Opcode, syn_field.value) catch null) |conflicting_opcode| {
            @compileError(std.fmt.comptimePrint(
                "Synthetic opcode {s} (0x{X}) conflicts with normal opcode {s}",
                .{ syn_field.name, syn_field.value, @tagName(conflicting_opcode) }
            ));
        }
    }
}
```

## Performance Impact

| Pattern | Occurrences* | Benefit |
|---------|--------------|---------|
| PUSH + ADD | Very common | 50% fewer dispatch items |
| PUSH + MSTORE | Very common | 50% fewer dispatch items |
| FUNCTION_DISPATCH | 1 per function | 75% fewer dispatch items |
| MULTI_PUSH_3 | Common | 67% fewer dispatch items |

*Based on analysis of typical Solidity contracts

## Descriptions for Debugging

```zig
// src/opcodes/opcode_synthetic.zig:66-97
pub fn describe(self: OpcodeSynthetic) []const u8 {
    return switch (self) {
        .PUSH_ADD_INLINE, .PUSH_ADD_POINTER => "PUSH+ADD fusion",
        .PUSH_MSTORE_INLINE, .PUSH_MSTORE_POINTER => "PUSH+MSTORE fusion",
        .FUNCTION_DISPATCH => "Function selector dispatch (PUSH4+EQ+PUSH+JUMPI)",
        .CALLVALUE_CHECK => "Payable check (CALLVALUE+DUP1+ISZERO)",
        // ...
    };
}
```

## Related Documentation

- [Dispatch System](./DISPATCH.md) - Schedule structure
- [Tracer System](./TRACER.md) - Synchronization handling
- [Bytecode Analysis](../dev/ARCHITECTURE.md#bytecode-analysis) - Pattern detection
