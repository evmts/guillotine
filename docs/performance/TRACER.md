# Tracer System

The tracer system provides execution synchronization between the optimized Frame (dispatch-based) and a reference MinimalEvm (traditional interpreter), enabling validation of execution correctness.

## Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Frame (Optimized)                         │
│  - Dispatch-based execution                                 │
│  - Synthetic opcodes (fused operations)                     │
│  - Pre-validated unsafe operations                          │
└─────────────────────────────────────────────────────────────┘
                    │ beforeInstruction()
                    ▼
┌─────────────────────────────────────────────────────────────┐
│                    Tracer                                    │
│  - Execution monitoring                                     │
│  - Safety counter (300M instruction limit)                  │
│  - State comparison                                         │
└─────────────────────────────────────────────────────────────┘
                    │ step()
                    ▼
┌─────────────────────────────────────────────────────────────┐
│                    MinimalEvm (Reference)                    │
│  - Traditional PC-based interpretation                      │
│  - Sequential bytecode execution                            │
│  - Ground truth for validation                              │
└─────────────────────────────────────────────────────────────┘
```

## How Synchronization Works

### Handler Pattern

Every Frame handler calls `beforeInstruction()`:

```zig
// src/instructions/handlers_arithmetic.zig
pub fn add(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
    // REQUIRED: Sync with reference implementation
    self.beforeInstruction(.ADD, cursor);

    // Execute operation
    self.stack.binary_op_unsafe(addOp);

    // Continue to next
    return @call(.always_tail, next_handler, .{self, next_cursor});
}
```

### beforeInstruction()

```zig
// src/tracer/tracer.zig
pub fn beforeInstruction(
    self: *Tracer,
    opcode: UnifiedOpcode,
    cursor: [*]const Dispatch.Item,
) void {
    // 1. Increment safety counter
    self.instruction_counter += 1;
    if (self.instruction_counter > LOOP_QUOTA) {
        return error.InfiniteLoop;
    }

    // 2. Execute reference implementation
    self.executeMinimalEvmForOpcode(opcode);

    // 3. Validate state matches (debug builds only)
    self.validateState();
}
```

## Synthetic Opcode Handling

Synthetic opcodes represent multiple bytecode operations. The tracer executes the corresponding number of reference steps:

```zig
// src/tracer/tracer.zig
fn executeMinimalEvmForOpcode(self: *Tracer, opcode: UnifiedOpcode) void {
    const steps: usize = switch (opcode.toSynthetic()) {
        // 2-operation fusions
        .PUSH_ADD_INLINE, .PUSH_ADD_POINTER,
        .PUSH_SUB_INLINE, .PUSH_SUB_POINTER,
        .PUSH_MUL_INLINE, .PUSH_MUL_POINTER,
        .PUSH_DIV_INLINE, .PUSH_DIV_POINTER,
        .PUSH_MSTORE_INLINE, .PUSH_MSTORE_POINTER,
        .PUSH_MLOAD_INLINE, .PUSH_MLOAD_POINTER => 2,

        // 3-operation fusions
        .MULTI_PUSH_3, .MULTI_POP_3,
        .DUP3_ADD_MSTORE, .SWAP1_DUP2_ADD,
        .ISZERO_JUMPI => 3,

        // 4-operation fusions
        .FUNCTION_DISPATCH => 4,  // PUSH4 + EQ + PUSH + JUMPI

        // Regular opcodes
        else => 1,
    };

    for (0..steps) |_| {
        self.minimal_evm.step();
    }
}
```

## State Validation

In Debug and ReleaseSafe builds, the tracer validates Frame and MinimalEvm match:

```zig
// src/tracer/tracer.zig
fn validateState(self: *Tracer) void {
    const frame = self.frame;
    const minimal = self.minimal_evm;

    // Validate stack
    if (frame.stack.size() != minimal.stack.len) {
        self.reportDivergence("Stack size mismatch");
    }

    for (0..frame.stack.size()) |i| {
        if (frame.stack.peek(i) != minimal.stack.items[minimal.stack.len - 1 - i]) {
            self.reportDivergence("Stack value mismatch at index {}", .{i});
        }
    }

    // Validate gas
    if (frame.gas_remaining != minimal.gas_remaining) {
        self.reportDivergence("Gas mismatch: {} vs {}", .{
            frame.gas_remaining, minimal.gas_remaining
        });
    }

    // Validate memory (sampling for performance)
    // ...
}
```

## PC Tracking

The tracer maps between dispatch cursor and bytecode PC:

```zig
// src/tracer/pc_tracker.zig
pub const PcTracker = struct {
    /// Maps schedule index → bytecode PC
    cursor_to_pc: []const u32,

    pub fn getPc(self: *PcTracker, cursor_index: usize) u32 {
        return self.cursor_to_pc[cursor_index];
    }
};
```

### Why PC Tracking Matters

```
Schedule Index:  0    1    2    3    4    5    6
                 ↓    ↓    ↓    ↓    ↓    ↓    ↓
               meta PUSH  val PUSH  val  ADD STOP
                 ↓    ↓         ↓         ↓    ↓
Bytecode PC:    N/A   0         2         4    5
```

- Schedule[0] is metadata (no PC)
- Schedule[1] corresponds to PC=0
- Schedule[2] is push value (no separate PC)
- etc.

## Safety Counter

Prevents infinite loops:

```zig
// src/tracer/tracer.zig
const LOOP_QUOTA: u64 = 300_000_000;  // 300M instructions

pub fn beforeInstruction(self: *Tracer, opcode: UnifiedOpcode, cursor: anytype) Error!void {
    self.instruction_counter += 1;
    if (self.instruction_counter > LOOP_QUOTA) {
        return Error.InfiniteLoop;
    }
    // ...
}
```

## MinimalEvm Reference Implementation

The MinimalEvm is a traditional interpreter used for validation:

```zig
// src/tracer/minimal_evm.zig
pub const MinimalEvm = struct {
    stack: ArrayList(u256),
    memory: AutoHashMap(u32, u8),
    pc: u32,
    gas_remaining: i64,
    bytecode: []const u8,
    // ...

    pub fn step(self: *MinimalEvm) !void {
        const opcode = self.bytecode[self.pc];
        switch (opcode) {
            0x01 => { // ADD
                const a = self.popStack();
                const b = self.popStack();
                self.pushStack(a +% b);
                self.pc += 1;
            },
            // ... 256 cases
        }
    }
};
```

## Tracer Assertions

Custom assertions that use the tracer's reporting:

```zig
// Usage in handlers
self.getTracer().assert(
    self.stack.size() >= 2,
    "ADD requires 2 stack items"
);

// Implementation
pub fn assert(self: *Tracer, condition: bool, message: []const u8) void {
    if (!condition) {
        self.reportError(message);
        // In debug: trigger debugger breakpoint
        // In release: return error
    }
}
```

## Divergence Reporting

When Frame and MinimalEvm diverge:

```zig
fn reportDivergence(self: *Tracer, comptime fmt: []const u8, args: anytype) void {
    std.log.err("Execution divergence at step {}: " ++ fmt, .{
        self.instruction_counter
    } ++ args);

    // Dump state for debugging
    self.dumpFrameState();
    self.dumpMinimalEvmState();

    // In debug builds, trigger breakpoint
    if (@import("builtin").mode == .Debug) {
        @breakpoint();
    }
}
```

## Build Mode Behavior

| Mode | Tracer Active | Validation | Performance |
|------|---------------|------------|-------------|
| Debug | Yes | Full state | Slowest |
| ReleaseSafe | Yes | Sampling | Medium |
| ReleaseFast | No | None | Fastest |
| ReleaseSmall | No | None | Fast |

```zig
// Conditional compilation
const builtin = @import("builtin");
if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
    self.validateState();
}
```

## Common Divergence Causes

1. **Missing beforeInstruction()** - Handler doesn't sync tracer
2. **Wrong synthetic step count** - Fusion maps to wrong number of operations
3. **Stack order mismatch** - LIFO semantics violated
4. **Gas calculation error** - Different gas costs
5. **Context mismatch** - Block/transaction context differs

## Debugging Workflow

```bash
# 1. Run with tracer enabled (Debug build)
zig build test -Doptimize=Debug

# 2. Find divergence point
# Output: "Execution divergence at step 1234: Stack size mismatch"

# 3. Identify opcode
# Output shows cursor position → map to bytecode

# 4. Compare implementations
# Check handler vs MinimalEvm switch case

# 5. Fix and verify
zig build test
```

## Related Documentation

- [Dispatch System](./DISPATCH.md) - Schedule structure
- [Synthetic Opcodes](./SYNTHETIC-OPCODES.md) - Fusion handling
- [Testing](../dev/TESTING.md) - Test organization
