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

    // Three-opcode fusions
    ISZERO_JUMPI = 0xC3,           // ISZERO + PUSH + JUMPI, target resolved at build time
    PUSH_ADD_DUP1_INLINE = 0xCB,   // PUSH + ADD + DUP1, operand fits 64 bits
    PUSH_ADD_DUP1_POINTER = 0xCC,  // PUSH + ADD + DUP1, wider operand

    // Schedule-only items (no bytecode instruction)
    BLOCK_BEGIN = 0xCE,            // Charges a fall-through basic block's gas, checks its stack
    INVALID_JUMP_TARGET = 0xCF,    // Where a static jump to a non-JUMPDEST lands
};
```

Every opcode in this list is emitted by the schedule builder. A fusion that the
builder never emits has no handler: an unreachable handler is unverified code.

## Inline vs Pointer

A fused `PUSH + op` handler comes in two variants, chosen by the width of the pushed
value. The handler knows its variant at compile time, so it never checks at run time.

### Inline (value fits 64 bits)
Value embedded directly in the schedule:

```zig
push_inline: PushInlineMetadata { .value: u64 }

const value = cursor[1].push_inline.value;
```

### Pointer (wider value)
Value stored in the schedule's arena; the metadata item points at it:

```zig
push_pointer: PushPointerMetadata { .value_ptr: *const u256 }

const value = cursor[1].push_pointer.value_ptr.*;
```

### Plain PUSH9-PUSH32: inline limbs

A PUSH that is not fused never uses a pointer. Its value is stored in the schedule as
64-bit limbs, least significant first:

| Opcodes | Items after the handler |
|---------|-------------------------|
| PUSH1-PUSH8 | 1 limb |
| PUSH9-PUSH16 | 2 limbs |
| PUSH17-PUSH24 | 3 limbs |
| PUSH25-PUSH32 | 4 limbs |

```zig
// PUSH20: cursor[1..4] hold the value
var value: u256 = cursor[1].push_inline.value;
value |= @as(u256, cursor[2].push_inline.value) << 64;
value |= @as(u256, cursor[3].push_inline.value) << 128;
```

## Schedule item size

A schedule item is an untagged 8-byte `extern union` in untraced ReleaseFast and
ReleaseSmall builds. Debug and ReleaseSafe builds, and builds with the tracer enabled,
use a tagged union instead, so `validateOpcodeHandler`, `DispatchSchedule.validate`
and the tracer can check each item's kind. `Dispatch.item_tagged` tells which is in use.

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

### Three-opcode fusion: ISZERO_JUMPI

```zig
// src/instructions/handlers_advanced_synthetic.zig
// ISZERO + PUSH target + JUMPI. cursor[1] holds the statically resolved target.
pub fn iszero_jumpi(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: GasType) callconv(handler_cc) ExitCode {
    N.before(self, .ISZERO_JUMPI, cursor, sp, gas);
    var s = N.StackView{ .sp = sp };
    const value = s.pop_unsafe();
    if (value != 0) return N.next(self, .ISZERO_JUMPI, cursor, s.sp, gas);
    const target: [*]const Dispatch.Item = @ptrCast(@alignCast(cursor[1].jump_static.dispatch));
    return N.jump(self, .ISZERO_JUMPI, target, s.sp, gas);
}
```

## Pattern Detection

Bytecode analysis (`src/bytecode/bytecode.zig`) marks fusion candidates in its packed
bitmap: a PUSH followed by ADD, MUL, SUB, DIV, AND, OR, XOR, MLOAD, MSTORE, MSTORE8,
JUMP or JUMPI, and an ISZERO followed by PUSH and JUMPI. `getFusionData` then picks the
fusion for a candidate, three-opcode patterns first:

1. `ISZERO; PUSH; JUMPI` becomes ISZERO_JUMPI.
2. `PUSH; ADD; DUP1` becomes PUSH_ADD_DUP1.
3. `PUSH; op` becomes the matching PUSH+op fusion.

## Gas Accounting

Synthetic opcodes maintain exact gas semantics:

```zig
// Gas cost = sum of fused operations
// PUSH_ADD_INLINE: 3 (PUSH) + 3 (ADD) = 6 gas
// ISZERO_JUMPI: 3 (ISZERO) + 3 (PUSH) + 10 (JUMPI) = 16 gas
```

## Tracer Synchronization

The tracer must execute multiple reference steps for synthetic opcodes:

```zig
// src/tracer/tracer.zig
fn executeMinimalEvmForOpcode(opcode: UnifiedOpcode) void {
    const steps = switch (opcode) {
        .PUSH_ADD_INLINE, .PUSH_ADD_POINTER => 2,      // PUSH + ADD
        .PUSH_MSTORE_INLINE => 2,                       // PUSH + MSTORE
        .ISZERO_JUMPI => 3,                             // ISZERO + PUSH + JUMPI
        .PUSH_ADD_DUP1_INLINE, .PUSH_ADD_DUP1_POINTER => 3, // PUSH + ADD + DUP1
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
| ISZERO + PUSH + JUMPI | Common (`require`, loops) | 3 handlers become 1 |
| PUSH + ADD + DUP1 | Common in loops | 3 handlers become 1 |

*Based on analysis of typical Solidity contracts

## Descriptions for Debugging

```zig
// src/opcodes/opcode_synthetic.zig:63-91
pub fn describe(self: OpcodeSynthetic) []const u8 {
    return switch (self) {
        .PUSH_ADD_INLINE, .PUSH_ADD_POINTER => "PUSH+ADD fusion",
        .PUSH_MSTORE_INLINE, .PUSH_MSTORE_POINTER => "PUSH+MSTORE fusion",
        .ISZERO_JUMPI => "ISZERO+JUMPI pattern",
        .PUSH_ADD_DUP1_INLINE, .PUSH_ADD_DUP1_POINTER => "PUSH+ADD+DUP1 pattern",
        // ...
    };
}
```

## Related Documentation

- [Dispatch System](./DISPATCH.md) - Schedule structure
- [Tracer System](./TRACER.md) - Synchronization handling
- [Bytecode Analysis](../dev/ARCHITECTURE.md#bytecode-analysis) - Pattern detection
