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

    // Continue to next (calls afterInstruction, then tail-calls)
    return dispatch_next.nextInstruction(FrameType, self, cursor, .ADD);
}
```

### beforeInstruction()

`Frame.beforeInstruction` compiles to nothing outside Debug and ReleaseSafe. In
those modes it forwards to `Tracer.before_instruction`:

```zig
// src/frame/frame.zig:430
pub inline fn beforeInstruction(self: *Self, comptime opcode: Dispatch.UnifiedOpcode, cursor: [*]const Dispatch.Item) void {
    if (comptime (builtin.mode != .Debug and builtin.mode != .ReleaseSafe)) return;
    (&self.getEvm().tracer).before_instruction(self, opcode, cursor);
    self.validateOpcodeHandler(opcode, cursor);
}

// src/tracer/tracer.zig:238 (condensed)
pub fn before_instruction(self: *Tracer, frame: anytype, comptime opcode: UnifiedOpcode,
    cursor: [*]const @TypeOf(frame.*).Dispatch.Item) void {
    if (!self.config.enabled) return;
    // 1. Record the opcode in the recent-opcodes ring buffer (and steps, if enabled)
    // 2. Panic if cursor[0] is not the expected handler for a regular opcode
    self.instruction_count += 1;
    // 3. Increment the safety counter (panics at 300M)
    self.instruction_safety.inc();
    // 4. Run the reference implementation
    if (self.minimal_evm) |evm| {
        minimal_evm_sync.executeMinimalEvmForOpcode(self, evm, opcode, frame, cursor);
    }
}
```

State validation runs afterwards, in `Tracer.after_instruction` and
`Tracer.after_complete`.

## Synthetic Opcode Handling

Synthetic opcodes represent multiple bytecode operations. The tracer executes the corresponding number of reference steps:

```zig
// src/tracer/minimal_evm_sync.zig
const SyntheticOpcodeSteps = struct {
    // 2-operation fusions
    const PUSH_ADD_INLINE = 2;
    const PUSH_MSTORE_INLINE = 2;
    const PUSH_MLOAD_INLINE = 2;
    // ... every PUSH_*_INLINE / PUSH_*_POINTER pair, MULTI_PUSH_2, MULTI_POP_2

    // 3-operation fusions
    const MULTI_PUSH_3 = 3;
    const MULTI_POP_3 = 3;
    const DUP3_ADD_MSTORE = 3;
    const SWAP1_DUP2_ADD = 3;
    const ISZERO_JUMPI = 3;

    // 4-operation fusions
    const FUNCTION_DISPATCH = 4; // PUSH4 + EQ + PUSH + JUMPI
};

// getMaxStepsForOpcode() maps each synthetic opcode to its constant
// (regular opcodes => 1). executeMinimalEvmForOpcode() runs that many
// MinimalEvm steps.
```

## State Validation

When a MinimalEvm sidecar exists, `after_instruction` and `after_complete`
call `validateMinimalEvmState` to compare it with the Frame:

```zig
// src/tracer/tracer.zig:570 (condensed)
fn validateMinimalEvmState(self: *Tracer, frame: anytype, comptime opcode: UnifiedOpcode) void {
    if (self.minimal_evm) |evm| {
        if (self.nested_depth > 0) return; // Skip nested calls

        // Stack size: mismatch logs "[EVM2] [DIVERGENCE] Stack size mismatch after <op>"
        // and panics ("Stack divergence"); CALL-like opcodes only log
        // Stack contents: mismatch logs both stacks and panics ("Stack content divergence")
        // Memory size: mismatch is a debug log only
        // Gas: compared only after JUMP, JUMPI, STOP, RETURN, REVERT, SELFDESTRUCT,
        //      because Frame charges gas per block; mismatch is a debug log only
    }
}
```

## PC Tracking

The tracer keeps `current_pc` in step with the bytecode. With a MinimalEvm
sidecar it copies the sidecar's PC after each instruction; otherwise, with
`enable_pc_tracking`, it advances the PC by each opcode's size.
`src/tracer/pc_tracker.zig` holds an independent tracker:

```zig
// src/tracer/pc_tracker.zig
pub const PcTracker = struct {
    pc: u32,                 // Current program counter
    bytecode: []const u8,    // The bytecode being executed
    valid: bool,             // Track if we're in a valid state
    last_opcode: ?u8,        // Track last opcode for validation

    pub fn getPc(self: *const PcTracker) u32 { ... }
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
instruction_safety: SafetyCounter(u64, .enabled),
// Tracer.init: .instruction_safety = SafetyCounter(u64, .enabled).init(300_000_000)

// before_instruction
self.instruction_safety.inc();

// src/internal/safety_counter.zig: inc() logs and panics at the limit
// ("EVM instruction limit exceeded - possible infinite loop ...")
```

## MinimalEvm Reference Implementation

The MinimalEvm is a traditional interpreter used for validation. `MinimalEvm`
(`src/tracer/minimal_evm.zig`) holds a stack of `MinimalFrame`s, and
`MinimalEvm.step()` steps the current frame:

```zig
// src/tracer/minimal_frame.zig
pub const MinimalFrame = struct {
    stack: std.ArrayList(u256),
    memory: std.AutoHashMap(u32, u8),
    memory_size: u32,
    pc: u32,
    gas_remaining: i64,
    bytecode: []const u8,
    // ...

    pub fn step(self: *Self) MinimalEvmError!void {
        if (self.stopped or self.reverted or self.pc >= self.bytecode.len) return;
        const opcode = self.getCurrentOpcode() orelse return;
        try self.executeOpcode(opcode); // switch (opcode) { ... 256 cases }
    }
};
```

## Tracer Assertions

Custom assertions that use the tracer's reporting:

```zig
// Usage in handlers (src/instructions/handlers_advanced_synthetic.zig)
(&self.getEvm().tracer).assert(self.stack.size() >= 1, "FUNCTION_DISPATCH: Stack underflow (need 1 item for EQ)");

// Implementation (src/tracer/tracer.zig:714)
pub fn assert(self: *Tracer, condition: bool, comptime message: []const u8) void {
    if (!condition) {
        log.err("ASSERTION FAILED: {s}", .{message});
        // Print the recent-opcodes ring buffer when the tracer is enabled,
        // then @panic(message) (unreachable on wasm32-freestanding)
    }
}
```

## Divergence Reporting

When Frame and MinimalEvm diverge, `validateMinimalEvmState` logs the
mismatch with an `[EVM2] [DIVERGENCE]` prefix, prints up to 10 top stack items
from each side for content mismatches, and panics. `Tracer.panic` logs its
message and prints the recent-opcodes ring buffer before stopping:

```zig
// src/tracer/tracer.zig:681
pub fn panic(self: *Tracer, comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    // Pretty print the ring buffer on error for debugging
    if (self.config.enabled) { ... self.recent_opcodes.prettyPrint(self.allocator) ... }
    // @panic on wasm32-freestanding, unreachable elsewhere
}
```

## Build Mode Behavior

Build mode decides whether the hooks exist; `EvmConfig.tracer_config`
decides whether they do anything. The default is `TracerConfig.disabled`
(`src/evm_config.zig`).

| Mode | Hooks compiled in | Tracer runs | MinimalEvm validation |
|------|-------------------|-------------|-----------------------|
| Debug | Yes | When `tracer_config.enabled` | When `enable_validation` is also set |
| ReleaseSafe | Yes | When `tracer_config.enabled` | When `enable_validation` is also set |
| ReleaseFast | No | No | No |
| ReleaseSmall | No | No | No |

```zig
// src/frame/frame.zig: every hook starts with
if (comptime (builtin.mode != .Debug and builtin.mode != .ReleaseSafe)) return;

// src/tracer/tracer_config.zig presets
TracerConfig.disabled // default
TracerConfig.debug    // enabled + validation + PC/gas tracking + debug logging
TracerConfig.full     // debug + step capture + advanced trace
```

`src/root.zig` defines `MainnetEvmWithTracer` and `TestEvm`, both with
validation enabled.

## Common Divergence Causes

1. **Missing beforeInstruction()** - Handler doesn't sync tracer
2. **Wrong synthetic step count** - Fusion maps to wrong number of operations
3. **Stack order mismatch** - LIFO semantics violated
4. **Gas calculation error** - Different gas costs
5. **Context mismatch** - Block/transaction context differs

## Debugging Workflow

```bash
# 1. Use an EVM type with tracer_config = TracerConfig.debug (or another
#    config with enabled and enable_validation), then run a Debug build
zig build test -Doptimize=Debug

# 2. Find divergence point
# Output: "[EVM2] [DIVERGENCE] Stack size mismatch after ADD:"

# 3. Identify opcode
# Output names the opcode; content mismatches also print the MinimalEvm PC

# 4. Compare implementations
# Check handler vs MinimalEvm switch case

# 5. Fix and verify
zig build test
```

## Related Documentation

- [Dispatch System](./DISPATCH.md) - Schedule structure
- [Synthetic Opcodes](./SYNTHETIC-OPCODES.md) - Fusion handling
- [Testing](../dev/TESTING.md) - Test organization
