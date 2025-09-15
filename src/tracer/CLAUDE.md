# CLAUDE.md - Tracer Module

## MISSION CRITICAL: Execution Monitoring
**Tracer bugs hide critical issues.** Tracing must be accurate without affecting execution.

## Understanding Frame vs MinimalEvm Execution Models

### Frame: Dispatch-Based Execution
```
Dispatch Schedule: [handler_ptr, metadata, handler_ptr, ...]
Execution: cursor[0].opcode_handler(frame, cursor) → tail calls
No PC, no switch statement, preprocessed schedule
```

### MinimalEvm: Traditional Interpreter
```
Bytecode: [0x60, 0x01, 0x01, 0x56, ...]
Execution: while(pc < len) { switch(bytecode[pc]) {...} }
PC-based, giant switch statement, runtime validation
```

## Synchronizing Two Different Execution Models

The tracer **synchronizes** these fundamentally different execution models:

### The Challenge
- **Frame**: Executes dispatch schedule (function pointers + metadata)
- **MinimalEvm**: Executes bytecode (opcodes + immediates)
- **Frame cursor ≠ MinimalEvm PC**: They track different things!

### The Solution: beforeInstruction()

**Execution Flow**:
1. `beforeInstruction(opcode, cursor)` - Called by Frame handler
2. `executeMinimalEvmForOpcode(opcode)` - Executes N MinimalEvm steps
3. `validateMinimalEvmState()` - Verifies identical state

**Key Insight**: Frame's synthetic opcodes = Multiple MinimalEvm steps

**Opcode Mapping**:
- **Regular opcodes** (ADD, MUL, etc.): 1 Frame op = 1 MinimalEvm step
- **PUSH opcodes**: 1 Frame op (handler + metadata) = 1 MinimalEvm step
- **Synthetic opcodes**: 1 Frame op = N MinimalEvm steps

**Synthetic Examples**:
```zig
// Frame: Single synthetic opcode
.PUSH_ADD_INLINE => {
    // MinimalEvm: Two sequential operations
    for (0..2) evm.step();  // Step 1: PUSH1, Step 2: ADD
}

// Frame: Complex fusion
.FUNCTION_DISPATCH => {
    // MinimalEvm: Four operations
    for (0..4) evm.step();  // PUSH4 + EQ + PUSH + JUMPI
}
```

### Critical Synchronization Points

1. **Schedule vs Bytecode Index**:
   - Frame: Schedule[0] might be `first_block_gas` metadata
   - MinimalEvm: Bytecode[0] is always first opcode
   - **Solution**: Tracer tracks mapping separately

2. **Jump Destinations**:
   - Frame: Pre-resolved dispatch pointers
   - MinimalEvm: Runtime PC validation
   - **Solution**: Both must reach same logical destination

3. **Gas Calculation**:
   - Frame: Batched per basic block (at JUMPDEST)
   - MinimalEvm: Per instruction
   - **Solution**: Compare total gas consumed, not per-op

## Core Files
- `tracer.zig` - Main DefaultTracer
- `MinimalEvm.zig` - Standalone EVM (65KB)
- `MinimalEvm_c.zig` - C FFI for WASM
- `pc_tracker.zig` - Program counter tracking

## Key Features

**Architecture**: EIP-2929 access tracking, opcode tracing, stack/memory monitoring
**Types**: DefaultTracer (production), MinimalEvm (differential), Custom
**WASM**: Opaque handle pattern, complete lifecycle, state inspection

## Critical Stack Semantics
```zig
// CORRECT LIFO - first pop = top
pub fn add(self: *MinimalEvm) !void {
    const a = try self.popStack(); // Top
    const b = try self.popStack(); // Second
    try self.pushStack(a +% b);
}
```

## Safety Requirements
- NEVER modify execution state during tracing
- Perfect EVM isolation
- Handle failures gracefully
- No gas calculation overhead
- Descriptive assertion messages

## Event Categories

**Critical Events** (REQUIRED):
- `before_instruction(opcode, cursor)` - Before every handler
- `after_instruction(opcode, next_handler, next_cursor)` - After success
- `after_complete(opcode)` - Terminal states

**System Events**: Frame lifecycle, bytecode analysis, dispatch, calls, memory
**Implementation Rules**: No side effects, fail gracefully, conditional compilation

```zig
// Required pattern
pub fn opcode_handler(self: *Frame, cursor: [*]const Dispatch.Item) Error!noreturn {
    self.beforeInstruction(.OPCODE, cursor);  // REQUIRED
    // ... implementation ...
    const op_data = dispatch.getOpData(.OPCODE);
    self.afterInstruction(.OPCODE, op_data.next_handler, op_data.next_cursor.cursor);
    return @call(getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
}
```

**Principle**: Tracers observe, never participate. MinimalEvm serves as tracer and reference implementation.