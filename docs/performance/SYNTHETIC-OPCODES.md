# Synthetic Opcodes

Synthetic opcodes are fused operations that combine common bytecode patterns into single dispatch items, reducing schedule length and improving performance while maintaining exact EVM semantics.

## Overview

During bytecode analysis, Guillotine detects common patterns and replaces them with synthetic handlers:

```
Original:    PUSH1 0x20, MSTORE    (2 opcodes, 2 schedule items each)
Fused:       PUSH_MSTORE_INLINE    (1 synthetic handler + 1 metadata)

Result: Fewer dispatch items, same gas cost, identical behavior
```

## Synthetic Opcode Definitions

All synthetic opcodes are defined in `src/opcodes/opcode_synthetic.zig`:

```zig
// src/opcodes/opcode_synthetic.zig:17-60
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
push_pointer: PushPointerMetadata { .value_ptr: *u256 }

// Handler dereferences pointer
const value = cursor[1].push_pointer.value_ptr.*;
```

## Handler Implementation

### Simple Fusion: PUSH_ADD_INLINE

```zig
// src/instructions/handlers_arithmetic_synthetic.zig
pub fn push_add_inline(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
    // Tracer sync (executes PUSH + ADD in reference impl)
    self.beforeInstruction(.PUSH_ADD_INLINE, cursor);

    // Get push value from inline metadata
    const push_value = cursor[1].push_inline.value;

    // Perform ADD: stack[top] = stack[top] + push_value
    const top = self.stack.peek_unsafe();
    self.stack.set_top_unsafe(top +% @as(WordType, push_value));

    // Tail-call next (skip past handler + metadata)
    return @call(.always_tail, cursor[2].opcode_handler, .{self, cursor + 2});
}
```

### Complex Fusion: FUNCTION_DISPATCH

```zig
// PUSH4 selector + EQ + PUSH target + JUMPI
// Common Solidity function dispatch pattern
pub fn function_dispatch(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
    self.beforeInstruction(.FUNCTION_DISPATCH, cursor);

    // Get metadata
    const metadata = cursor[1].function_dispatch;

    // Pop calldata selector from stack
    const calldata_selector = self.stack.pop_unsafe();

    // Compare with expected selector
    const matches = calldata_selector == metadata.selector;

    if (matches) {
        // Jump to function body
        return @call(.always_tail, metadata.target_handler, .{self, metadata.target_cursor});
    } else {
        // Continue to next dispatch check
        return @call(.always_tail, cursor[2].opcode_handler, .{self, cursor + 2});
    }
}
```

## Pattern Detection

Patterns are detected during bytecode analysis:

```zig
// src/bytecode/bytecode_analyze.zig
fn detectFusionPatterns(bytecode: []const u8, pc: usize) ?FusionPattern {
    // Check for PUSH + ADD pattern
    if (isPushOpcode(bytecode[pc]) and
        pc + pushSize(bytecode[pc]) + 1 < bytecode.len and
        bytecode[pc + pushSize(bytecode[pc]) + 1] == 0x01) { // ADD
        return .push_add;
    }

    // Check for function dispatch pattern
    if (bytecode[pc] == 0x63 and  // PUSH4
        pc + 6 < bytecode.len and
        bytecode[pc + 5] == 0x14 and  // EQ
        isPushOpcode(bytecode[pc + 6])) {
        // Verify JUMPI follows
        // ...
        return .function_dispatch;
    }

    return null;
}
```

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
// src/tracer/tracer.zig
fn executeMinimalEvmForOpcode(opcode: UnifiedOpcode) void {
    const steps = switch (opcode) {
        .PUSH_ADD_INLINE, .PUSH_ADD_POINTER => 2,      // PUSH + ADD
        .PUSH_MSTORE_INLINE => 2,                       // PUSH + MSTORE
        .FUNCTION_DISPATCH => 4,                        // PUSH4 + EQ + PUSH + JUMPI
        .MULTI_PUSH_3 => 3,                             // 3 PUSHes
        else => 1,                                      // Regular opcodes
    };

    for (0..steps) |_| {
        minimal_evm.step();
    }
}
```

## Compile-Time Validation

Synthetic opcodes must not conflict with standard EVM opcodes:

```zig
// src/opcodes/opcode_synthetic.zig:96-100
comptime {
    for (@typeInfo(OpcodeSynthetic).@"enum".fields) |syn_field| {
        if (std.meta.intToEnum(Opcode, syn_field.value) catch null) |conflicting| {
            @compileError("Synthetic opcode conflicts with: " ++ @tagName(conflicting));
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
// src/opcodes/opcode_synthetic.zig:63-91
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
