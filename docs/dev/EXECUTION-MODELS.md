# Execution Models Comparison

This document provides a detailed side-by-side comparison of the Mini and Performance EVM execution models with visual diagrams and state traces.

## Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         EXECUTION MODEL COMPARISON                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   MINI EVM                                 PERFORMANCE EVM                  │
│   ────────                                 ───────────────                  │
│                                                                             │
│   ┌─────────────────────┐                  ┌─────────────────────┐         │
│   │     Bytecode        │                  │     Bytecode        │         │
│   │  [60 05 60 03 01]   │                  │  [60 05 60 03 01]   │         │
│   └──────────┬──────────┘                  └──────────┬──────────┘         │
│              │                                        │                     │
│              │ Direct                                 │ Preprocess          │
│              │                                        ▼                     │
│              │                             ┌─────────────────────┐         │
│              │                             │  Dispatch Schedule  │         │
│              │                             │  [gas][push][5]     │         │
│              │                             │  [push][3][add]     │         │
│              │                             └──────────┬──────────┘         │
│              │                                        │                     │
│              ▼                                        ▼                     │
│   ┌─────────────────────┐                  ┌─────────────────────┐         │
│   │   While Loop        │                  │   Tail-Call Chain   │         │
│   │   + Switch(256)     │                  │   (No loop/switch)  │         │
│   └─────────────────────┘                  └─────────────────────┘         │
│                                                                             │
│   Branch prediction: ~50%                  Branch prediction: ~100%         │
│   Gas check: Per operation                 Gas check: Per block             │
│   Validation: Every operation              Validation: Once (preprocess)    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

| Aspect | Mini EVM | Performance EVM |
|--------|----------|-----------------|
| Model | Sequential PC-based | Dispatch schedule with tail calls |
| Philosophy | Clarity & correctness | Speed via preprocessing |
| Location | `mini/src/` | `src/` |
| Core files | `evm.zig`, `frame.zig` | `evm.zig`, `frame/frame.zig`, `preprocessor/` |

## Execution Loop

### Mini: Traditional While Loop

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          MINI EVM: WHILE LOOP                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   PC = 0                                                                    │
│   │                                                                         │
│   ▼                                                                         │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ while (!stopped && !reverted && pc < bytecode.len) {                │  │
│   │     │                                                               │  │
│   │     ▼                                                               │  │
│   │     ┌───────────────────────────────────────────────────────────┐  │  │
│   │     │ opcode = bytecode[pc]                                     │  │  │
│   │     └───────────────────────────────────────────────────────────┘  │  │
│   │     │                                                               │  │
│   │     ▼                                                               │  │
│   │     ┌───────────────────────────────────────────────────────────┐  │  │
│   │     │ switch (opcode) {                                         │  │  │
│   │     │     0x00 => stop(),          // 256 cases                 │  │  │
│   │     │     0x01 => add(),           // CPU can't predict         │  │  │
│   │     │     0x02 => mul(),           // which branch              │  │  │
│   │     │     ...                                                   │  │  │
│   │     │     0xFF => selfdestruct(),                               │  │  │
│   │     │ }                                                         │  │  │
│   │     └───────────────────────────────────────────────────────────┘  │  │
│   │     │                                                               │  │
│   │     ▼                                                               │  │
│   │     handler returns, pc incremented                                 │  │
│   │     │                                                               │  │
│   │     └──────────────────────────────────────────────────────────────┘│  │
│   │                              │                                       │  │
│   │                              │ loop back                             │  │
│   └──────────────────────────────┘                                      │  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// mini/src/frame.zig (simplified)
pub fn execute(self: *Self) EvmError!void {
    // Simple while loop - easy to understand
    while (!self.stopped and !self.reverted and self.pc < self.bytecode.len()) {
        // (optional config.loop_quota check omitted)
        try self.step();
    }
}

pub fn step(self: *Self) EvmError!void {
    // Read opcode from bytecode
    const opcode = self.getCurrentOpcode() orelse return;
    // (tracer capture omitted)
    try self.executeOpcode(opcode);
}

pub fn executeOpcode(self: *Self, opcode: u8) EvmError!void {
    // (JavaScript and EvmConfig opcode overrides are checked first; omitted)
    // Dispatch via switch statement
    switch (opcode) {
        0x00 => try ControlFlowHandlers.stop(self),
        0x01 => try ArithmeticHandlers.add(self),
        0x02 => try ArithmeticHandlers.mul(self),
        // ... every defined opcode
        else => return error.InvalidOpcode,
    }
}
```

**Characteristics:**
- One bytecode read per instruction
- 256-way switch statement
- PC incremented in each handler
- Returns normally, loop continues

### Performance: Tail-Call Chain

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     PERFORMANCE EVM: TAIL-CALL CHAIN                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   PHASE 1: PREPROCESSING (once)                                             │
│   ─────────────────────────────                                             │
│                                                                             │
│   Bytecode → Analyze → Build Schedule                                       │
│                                                                             │
│   PHASE 2: EXECUTION (each invocation)                                      │
│   ────────────────────────────────────                                      │
│                                                                             │
│   schedule[1].handler(frame, cursor)                                        │
│        │                                                                    │
│        │  ┌──────────────────────────────────────────────────────────────┐ │
│        └─▶│ push_handler:                                                │ │
│           │   value = cursor[1].push_inline.value                        │ │
│           │   stack.push_unsafe(value)                                   │ │
│           │   @call(.always_tail, cursor[2].handler, {frame, cursor+2})  │ │
│           └──────────────────────────────────────────────────────────────┘ │
│                │                                                            │
│                │ TAIL CALL (no return, no stack frame)                     │
│                ▼                                                            │
│           ┌──────────────────────────────────────────────────────────────┐ │
│           │ push_handler:                                                │ │
│           │   value = cursor[1].push_inline.value                        │ │
│           │   stack.push_unsafe(value)                                   │ │
│           │   @call(.always_tail, cursor[2].handler, {frame, cursor+2})  │ │
│           └──────────────────────────────────────────────────────────────┘ │
│                │                                                            │
│                │ TAIL CALL                                                  │
│                ▼                                                            │
│           ┌──────────────────────────────────────────────────────────────┐ │
│           │ add_handler:                                                 │ │
│           │   stack.binary_op_unsafe(add_fn)                             │ │
│           │   @call(.always_tail, cursor[1].handler, {frame, cursor+1})  │ │
│           └──────────────────────────────────────────────────────────────┘ │
│                │                                                            │
│                │ TAIL CALL                                                  │
│                ▼                                                            │
│           ┌──────────────────────────────────────────────────────────────┐ │
│           │ stop_handler:                                                │ │
│           │   return Error.Stop  ← Exit point (via error)                │ │
│           └──────────────────────────────────────────────────────────────┘ │
│                                                                             │
│   NO LOOP! NO SWITCH! Linear function pointer chain.                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// src/frame/frame.zig (simplified: tracer hooks and debug validation omitted)
pub fn interpret(
    self: *Self,
    dispatch_schedule: *const Dispatch.DispatchSchedule,
    jump_table: *const Dispatch.JumpTable,
    bytecode_raw: []const u8,
) Error!void {
    // Store context
    self.code = bytecode_raw;
    self.jump_table = jump_table;
    const schedule = dispatch_schedule.items;
    const start_index: usize = @intFromBool(dispatch_schedule.has_first_block_gas);

    // Charge the first basic block's gas once and check its stack bounds
    if (dispatch_schedule.has_first_block_gas) {
        const meta = schedule[0].first_block_gas;
        if (meta.gas > 0) try self.consumeGasChecked(meta.gas);
        // ... min_stack / max_stack check against the current stack size
    }

    // Start the handler chain. Each handler tail-calls the next, so this
    // call returns only through an error (Stop, Return, Revert, OutOfGas, ...)
    self.dispatch = Dispatch{ .cursor = schedule.ptr + start_index };
    try self.dispatch.cursor[0].opcode_handler(self, self.dispatch.cursor);
}
```

**Characteristics:**
- No bytecode reads during execution
- No switch statement
- Cursor advances through schedule
- Never returns (tail-call or error)

## Handler Implementation

### Mini: Simple Returns

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         MINI HANDLER: ADD                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ENTRY                                                                     │
│   │                                                                         │
│   ▼                                                                         │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ 1. GAS CHECK                                                        │  │
│   │    if (gas_remaining < 3) return OutOfGas                           │  │
│   │    gas_remaining -= 3                                               │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│   │                                                                         │
│   ▼                                                                         │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ 2. POP A (with bounds check)                                        │  │
│   │    if (stack.len == 0) return StackUnderflow                        │  │
│   │    a = stack.pop()                                                  │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│   │                                                                         │
│   ▼                                                                         │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ 3. POP B (with bounds check)                                        │  │
│   │    if (stack.len == 0) return StackUnderflow                        │  │
│   │    b = stack.pop()                                                  │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│   │                                                                         │
│   ▼                                                                         │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ 4. COMPUTE                                                          │  │
│   │    result = a +% b (wrapping add)                                   │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│   │                                                                         │
│   ▼                                                                         │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ 5. PUSH RESULT (with bounds check)                                  │  │
│   │    if (stack.len >= 1024) return StackOverflow                      │  │
│   │    stack.push(result)                                               │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│   │                                                                         │
│   ▼                                                                         │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ 6. ADVANCE PC                                                       │  │
│   │    pc += 1                                                          │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│   │                                                                         │
│   ▼                                                                         │
│   RETURN (back to execute loop)                                             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// mini/src/instructions/handlers_arithmetic.zig
pub fn add(frame: *FrameType) FrameType.EvmError!void {
    // 1. Gas check
    try frame.consumeGas(GasConstants.GasFastestStep);  // 3 gas

    // 2. Stack operations (bounds checked)
    const a = try frame.popStack();
    const b = try frame.popStack();

    // 3. Compute result
    const result = a +% b;  // Wrapping add

    // 4. Push result (bounds checked)
    try frame.pushStack(result);

    // 5. Advance PC
    frame.pc += 1;

    // 6. Return to execute loop
}
```

### Performance: Tail-Call Pattern

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      PERFORMANCE HANDLER: ADD                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ENTRY (from previous handler's tail call)                                 │
│   │                                                                         │
│   ▼                                                                         │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ 1. TRACER SYNC (Debug and ReleaseSafe builds only)                  │  │
│   │    self.beforeInstruction(.ADD, cursor)                             │  │
│   │    • Validates state matches reference implementation               │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│   │                                                                         │
│   ▼                                                                         │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ 2. EXECUTE (pre-validated, no checks needed)                        │  │
│   │    stack.binary_op_unsafe(add_fn)                                   │  │
│   │    • No bounds check (validated in preprocessing)                   │  │
│   │    • No gas check (charged at block entry)                          │  │
│   │    • In-place modification (no intermediate storage)                │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│   │                                                                         │
│   ▼                                                                         │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ 3. GET NEXT HANDLER                                                 │  │
│   │    nextInstruction(): getOpData(.ADD, ...) from dispatch metadata   │  │
│   │    • Contains function pointer + cursor offset                      │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│   │                                                                         │
│   ▼                                                                         │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ 4. TAIL-CALL NEXT (NEVER returns)                                   │  │
│   │    return @call(.always_tail, op_data.next_handler, ...)            │  │
│   │    • Reuses stack frame                                             │  │
│   │    • No function call overhead                                      │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│   No return! Control transfers directly to next handler.                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// src/instructions/handlers_arithmetic.zig
pub fn add(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
    // 1. Tracer sync (Debug and ReleaseSafe builds only)
    self.beforeInstruction(.ADD, cursor);

    // 2. Execute (pre-validated, use unsafe operations)
    self.stack.binary_op_unsafe(struct {
        fn op(top: WordType, second: WordType) WordType {
            return top +% second;
        }
    }.op);

    // 3-4. Look up the next handler and tail-call it (NEVER returns)
    return dispatch_next.nextInstruction(FrameType, self, cursor, .ADD);
}

// src/instructions/dispatch_next.zig
pub inline fn nextInstruction(
    comptime FrameType: type,
    self: *FrameType,
    cursor: [*]const FrameType.Dispatch.Item,
    comptime opcode: FrameType.Dispatch.UnifiedOpcode,
) FrameType.Error!noreturn {
    const op_data = dispatch_opcode_data.getOpData(opcode, FrameType.Dispatch, FrameType.Dispatch.Item, cursor);
    self.afterInstruction(opcode, op_data.next_handler, op_data.next_cursor.cursor);
    // .always_tail on native targets, .auto on wasm32/wasm64
    return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
}
```

## Execution Trace: PUSH1 5, PUSH1 3, ADD

### Mini EVM Trace

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        MINI EVM EXECUTION TRACE                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Bytecode: [0x60, 0x05, 0x60, 0x03, 0x01]                                  │
│   Initial:  PC=0, Gas=100, Stack=[]                                         │
│                                                                             │
│   ─────────────────────────────────────────────────────────────────────────│
│   STEP 1: PC=0, Opcode=0x60 (PUSH1)                                        │
│   ─────────────────────────────────────────────────────────────────────────│
│                                                                             │
│   execute() loop iteration:                                                 │
│   │                                                                         │
│   ├─ Read bytecode[0] = 0x60 (PUSH1)                                       │
│   ├─ switch(0x60) → push1 handler                                          │
│   ├─ Gas: 100 - 3 = 97                                                     │
│   ├─ Read bytecode[1] = 0x05                                               │
│   ├─ Stack: [] → [5]                                                       │
│   ├─ PC: 0 → 2                                                             │
│   └─ Return to loop                                                         │
│                                                                             │
│   State: PC=2, Gas=97, Stack=[5]                                           │
│                                                                             │
│   ─────────────────────────────────────────────────────────────────────────│
│   STEP 2: PC=2, Opcode=0x60 (PUSH1)                                        │
│   ─────────────────────────────────────────────────────────────────────────│
│                                                                             │
│   execute() loop iteration:                                                 │
│   │                                                                         │
│   ├─ Read bytecode[2] = 0x60 (PUSH1)                                       │
│   ├─ switch(0x60) → push1 handler                                          │
│   ├─ Gas: 97 - 3 = 94                                                      │
│   ├─ Read bytecode[3] = 0x03                                               │
│   ├─ Stack: [5] → [3, 5]  (3 is top)                                       │
│   ├─ PC: 2 → 4                                                             │
│   └─ Return to loop                                                         │
│                                                                             │
│   State: PC=4, Gas=94, Stack=[3, 5]                                        │
│                                                                             │
│   ─────────────────────────────────────────────────────────────────────────│
│   STEP 3: PC=4, Opcode=0x01 (ADD)                                          │
│   ─────────────────────────────────────────────────────────────────────────│
│                                                                             │
│   execute() loop iteration:                                                 │
│   │                                                                         │
│   ├─ Read bytecode[4] = 0x01 (ADD)                                         │
│   ├─ switch(0x01) → add handler                                            │
│   ├─ Gas: 94 - 3 = 91                                                      │
│   ├─ Pop: 3 (top)                                                          │
│   ├─ Pop: 5 (second)                                                       │
│   ├─ Compute: 3 + 5 = 8                                                    │
│   ├─ Push: 8                                                               │
│   ├─ Stack: [3, 5] → [8]                                                   │
│   ├─ PC: 4 → 5                                                             │
│   └─ Return to loop                                                         │
│                                                                             │
│   State: PC=5, Gas=91, Stack=[8]                                           │
│                                                                             │
│   ─────────────────────────────────────────────────────────────────────────│
│   Loop exits: PC=5 >= bytecode.len=5                                       │
│   ─────────────────────────────────────────────────────────────────────────│
│                                                                             │
│   Total: 3 loop iterations, 3 switch dispatches, 3 gas checks              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Performance EVM Trace

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     PERFORMANCE EVM EXECUTION TRACE                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Bytecode: [0x60, 0x05, 0x60, 0x03, 0x01]                                  │
│                                                                             │
│   PREPROCESSING (once):                                                     │
│   ─────────────────────────────────────────────────────────────────────────│
│                                                                             │
│   Schedule built (with EvmConfig.enable_fusion = false; the default         │
│   enable_fusion = true fuses these pushes into synthetic opcodes):          │
│   [0] first_block_gas { gas: 9, min_stack: 0, max_stack: 2 }               │
│   [1] &push_handler                                                         │
│   [2] push_inline { value: 5 }                                             │
│   [3] &push_handler                                                         │
│   [4] push_inline { value: 3 }                                             │
│   [5] &add_handler                                                          │
│   [6] &stop_handler  (implicit STOP appended after the last opcode)         │
│                                                                             │
│   EXECUTION:                                                                │
│   ─────────────────────────────────────────────────────────────────────────│
│                                                                             │
│   Initial: Gas=100, Stack=[]                                               │
│                                                                             │
│   ─────────────────────────────────────────────────────────────────────────│
│   interpret() entry:                                                        │
│   ─────────────────────────────────────────────────────────────────────────│
│   │                                                                         │
│   ├─ Read schedule[0] = first_block_gas { gas: 9 }                         │
│   ├─ Gas: 100 - 9 = 91  (ALL gas charged upfront!)                         │
│   └─ call schedule[1].handler(frame, &schedule[1])  (starts the chain)      │
│                                                                             │
│   ─────────────────────────────────────────────────────────────────────────│
│   push_handler (cursor @ schedule[1]):                                      │
│   ─────────────────────────────────────────────────────────────────────────│
│   │                                                                         │
│   ├─ Read cursor[1] = push_inline { value: 5 }                             │
│   ├─ stack.push_unsafe(5)                                                  │
│   ├─ Stack: [] → [5]                                                       │
│   └─ tail-call cursor[2].handler(frame, cursor+2)  // schedule[3]          │
│                                                                             │
│   ─────────────────────────────────────────────────────────────────────────│
│   push_handler (cursor @ schedule[3]):                                      │
│   ─────────────────────────────────────────────────────────────────────────│
│   │                                                                         │
│   ├─ Read cursor[1] = push_inline { value: 3 }                             │
│   ├─ stack.push_unsafe(3)                                                  │
│   ├─ Stack: [5] → [3, 5]                                                   │
│   └─ tail-call cursor[2].handler(frame, cursor+2)  // schedule[5]          │
│                                                                             │
│   ─────────────────────────────────────────────────────────────────────────│
│   add_handler (cursor @ schedule[5]):                                       │
│   ─────────────────────────────────────────────────────────────────────────│
│   │                                                                         │
│   ├─ stack.binary_op_unsafe(add)                                           │
│   │   ├─ top = stack_ptr[0] = 3, second = stack_ptr[1] = 5                  │
│   │   ├─ stack_ptr[1] = 3 + 5 = 8                                           │
│   │   ├─ stack_ptr += 1                                                     │
│   │   └─ Stack: [3, 5] → [8]                                               │
│   └─ tail-call cursor[1].handler(frame, cursor+1)  // schedule[6]          │
│                                                                             │
│   ─────────────────────────────────────────────────────────────────────────│
│   stop_handler (cursor @ schedule[6]):                                      │
│   ─────────────────────────────────────────────────────────────────────────│
│   │                                                                         │
│   └─ return Error.Stop  (exit via error)                                   │
│                                                                             │
│   Final: Gas=91, Stack=[8]                                                 │
│                                                                             │
│   Total: 0 loop iterations, 0 switch dispatches, 1 gas check               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Stack Operations

### Mini: Bounds-Checked ArrayList

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      MINI STACK: ARRAYLIST                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Structure:                                                                │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ std.ArrayList(u256):                                                │  │
│   │   items: []u256      (len = items.len)                              │  │
│   │   capacity: usize    (allocator is passed in: frame.allocator)      │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│   Push Operation:                                                           │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ if (len >= 1024) return StackOverflow;  // Check every time         │  │
│   │ items[len] = value;                                                 │  │
│   │ len += 1;                                                           │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│   Pop Operation:                                                            │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ if (len == 0) return StackUnderflow;    // Check every time         │  │
│   │ len -= 1;                                                           │  │
│   │ return items[len];                                                  │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│   Cost: 2 branches per operation                                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// mini/src/frame.zig:161-176

// Every push checks overflow
pub fn pushStack(self: *Self, value: u256) EvmError!void {
    if (self.stack.items.len >= 1024) {
        return error.StackOverflow;
    }
    try self.stack.append(self.allocator, value);
}

// Every pop checks underflow
pub fn popStack(self: *Self) EvmError!u256 {
    if (self.stack.items.len == 0) {
        return error.StackUnderflow;
    }
    const value = self.stack.items[self.stack.items.len - 1];
    self.stack.items.len -= 1;
    return value;
}
```

### Performance: Pre-Validated Unsafe Operations

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                   PERFORMANCE STACK: CACHE-ALIGNED ARRAY                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Structure (buffer 64-byte aligned for cache line):                        │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ buf_ptr: [*]align(64) u256   (stack_size words, default 1024)       │  │
│   │ stack_ptr: [*]u256           (points at the top item)               │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│   Memory Layout (downward growth):                                          │
│                                                                             │
│   Index 0    ─┐ ← buf_ptr (stack limit)                                     │
│               │ ← Empty slots                                               │
│   ...         │                                                             │
│               │                                                             │
│   Index N  ───┤ ← stack_ptr: top of stack (most recent push)                │
│               │                                                             │
│   Index N+1 ──┤ ← Second item                                               │
│               │                                                             │
│   ...         │                                                             │
│               │                                                             │
│   Index 1023 ─┘ ← Bottom of stack                                           │
│                                                                             │
│   Empty stack: stack_ptr = buf_ptr + 1024 (one past the buffer)             │
│                                                                             │
│   Push: stack_ptr -= 1; stack_ptr[0] = value  (asserted in Debug/ReleaseSafe)│
│   Pop:  value = stack_ptr[0]; stack_ptr += 1  (asserted in Debug/ReleaseSafe)│
│                                                                             │
│   Why safe? Preprocessing validated stack bounds for entire basic block.   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// src/stack/stack.zig (Debug/ReleaseSafe tracer asserts omitted)
buf_ptr: [*]align(64) WordType,
// Points to the top item, or one past the buffer when empty.
stack_ptr: [*]align(ptr_align) WordType,

// Unsafe operations - caller must validate first
pub inline fn push_unsafe(self: *Self, value: WordType) void {
    self.stack_ptr -= 1;  // Downward growth
    self.stack_ptr[0] = value;
}

pub inline fn pop_unsafe(self: *Self) WordType {
    const value = self.stack_ptr[0];
    self.stack_ptr += 1;
    return value;
}

// Optimized binary operation (ADD, SUB, MUL, etc.)
pub inline fn binary_op_unsafe(self: *Self, comptime op: fn (a: WordType, b: WordType) WordType) void {
    // In-place: the result overwrites the second item, then the top is dropped
    const top = self.stack_ptr[0];
    const second = self.stack_ptr[1];
    self.stack_ptr[1] = op(top, second);
    self.stack_ptr += 1;
}
```

## Gas Metering

### Mini: Per-Operation

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       MINI GAS: PER-OPERATION                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Bytecode: PUSH1 5, PUSH1 3, ADD                                          │
│                                                                             │
│   ┌──────────────┬──────────────┬──────────────┬──────────────┐            │
│   │   PUSH1 5    │   PUSH1 3    │     ADD      │    Total     │            │
│   ├──────────────┼──────────────┼──────────────┼──────────────┤            │
│   │ Check: 100>3 │ Check: 97>3  │ Check: 94>3  │  3 checks    │            │
│   │ Gas: 100→97  │ Gas: 97→94   │ Gas: 94→91   │              │            │
│   └──────────────┴──────────────┴──────────────┴──────────────┘            │
│                                                                             │
│   Code:                                                                     │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ pub fn consumeGas(self: *Self, amount: u64) EvmError!void {         │  │
│   │     if (self.gas_remaining < amount) {  // Check every time         │  │
│   │         return error.OutOfGas;                                      │  │
│   │     }                                                               │  │
│   │     self.gas_remaining -= amount;                                   │  │
│   │ }                                                                   │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Performance: Per-Basic-Block

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PERFORMANCE GAS: PER-BASIC-BLOCK                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Basic Block: PUSH1 5, PUSH1 3, ADD (no jumps = one block)                │
│                                                                             │
│   Preprocessing calculates: 3 + 3 + 3 = 9 gas for entire block             │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │   Block Entry                                                       │  │
│   ├─────────────────────────────────────────────────────────────────────┤  │
│   │ Check: 100 > 9? YES                                                 │  │
│   │ Gas: 100 → 91  (single deduction)                                   │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│   ┌──────────────┬──────────────┬──────────────┬──────────────┐            │
│   │   PUSH1 5    │   PUSH1 3    │     ADD      │    Total     │            │
│   ├──────────────┼──────────────┼──────────────┼──────────────┤            │
│   │ No check     │ No check     │ No check     │  1 check     │            │
│   │ (prepaid)    │ (prepaid)    │ (prepaid)    │  (at entry)  │            │
│   └──────────────┴──────────────┴──────────────┴──────────────┘            │
│                                                                             │
│   Schedule:                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ [0] first_block_gas { gas: 9, min_stack: 0, max_stack: 2 }          │  │
│   │     └─ 9 = PUSH1(3) + PUSH1(3) + ADD(3)                             │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Memory Access

### Mini: Contiguous Byte Array

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      MINI MEMORY: CONTIGUOUS BYTE ARRAY                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Structure: std.ArrayList(u8) + memory_size (word-aligned EVM size)        │
│                                                                             │
│   MSTORE(offset=0x40, value=0x1234...5678)                                  │
│                                                                             │
│   1. Charge expansion: memoryExpansionCost(0x60)                            │
│   2. writeMemory() each of the 32 bytes at 0x40..0x5F                       │
│      (grows items and zero-fills new bytes on first write past the end)     │
│   3. memory_size = 0x60 (rounded up to a 32-byte word)                      │
│                                                                             │
│   Reads past items.len return 0 without allocating.                         │
│                                                                             │
│   Pros: Simple, obviously correct                                           │
│   Cons: Byte-at-a-time access for word operations                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// mini/src/frame.zig
memory: std.ArrayList(u8),
memory_size: u32,  // word-aligned size reported by MSIZE

pub fn readMemory(self: *Self, offset: u32) u8 {
    if (offset >= self.memory.items.len) return 0;
    return self.memory.items[offset];
}

pub fn writeMemory(self: *Self, offset: u32, value: u8) EvmError!void {
    // Grow and zero-fill when writing past the end
    if (offset >= self.memory.items.len) {
        const old_len = self.memory.items.len;
        const new_len = offset + 1;
        self.memory.ensureTotalCapacity(self.allocator, new_len) catch return error.OutOfMemory;
        self.memory.items.len = new_len;
        @memset(self.memory.items[old_len..new_len], 0);
    }
    self.memory.items[offset] = value;
    // EVM memory expands to word-aligned (32-byte) boundaries
    const word_aligned_size = wordAlignedSize(@as(u64, offset) + 1);
    if (word_aligned_size > self.memory_size) self.memory_size = word_aligned_size;
}
```

### Performance: Pooled Byte Buffer

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PERFORMANCE MEMORY: POOLED BYTE BUFFER                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Structure: a contiguous std.ArrayList(u8) reached through buffer_ptr.     │
│   Evm keeps one buffer per call depth (memory_pool[depth - 1]) and          │
│   reuses it; Frame.initPooled() borrows it and deinitPooled() empties       │
│   it, keeping its capacity.                                                 │
│                                                                             │
│   memory_pool: [ depth 1 buffer ] [ depth 2 buffer ] [ depth 3 ... ]        │
│                                                                             │
│   MLOAD(offset=0x40):                                                       │
│   ensure_capacity(0x60)   grow in whole 32-byte words, zero-fill,           │
│                           cache the 3n + n²/512 cost for n words            │
│   readInt(u256, buffer[0x40..][0..32], .big)                                │
│                                                                             │
│   Pros: One big-endian word load, no allocation after warm-up               │
│   Cons: Pooled buffers keep their peak capacity between calls               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// src/memory/memory.zig
pub fn Memory(config: MemoryConfig) type {
    return struct {
        checkpoint: u32,                  // start offset; 0 for frames the Evm creates
        buffer_ptr: *std.ArrayList(u8),   // owned, or borrowed from the Evm's per-depth pool
        cached_words: usize = 0,          // word count whose cost is cached
        cached_cost: u64 = 0,             // 3 * words + words^2 / 512
        // ...

        /// Caller must guarantee `offset + 32 <= self.size()`.
        pub inline fn get_u256_unchecked(self: *const Self, offset: usize) u256 {
            return std.mem.readInt(u256, (self.buffer_ptr.items.ptr + self.checkpoint + offset)[0..32], .big);
        }

        pub inline fn set_u256_unchecked(self: *Self, offset: usize, value: u256) void {
            std.mem.writeInt(u256, (self.buffer_ptr.items.ptr + self.checkpoint + offset)[0..32], value, .big);
        }
    };
}
```

## Branch Prediction Impact

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      BRANCH PREDICTION COMPARISON                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   MINI EVM: 256-way switch                                                  │
│   ──────────────────────────                                                │
│                                                                             │
│   switch (opcode) {          ← CPU: "Which of 256 branches?"               │
│       0x00 => stop(),        ← Misprediction penalty: 15-20 cycles         │
│       0x01 => add(),         ← ~50% misprediction rate typical             │
│       ...                                                                   │
│   }                                                                         │
│                                                                             │
│   For 1000 opcodes: ~500 mispredictions × 15 cycles = 7500 wasted cycles   │
│                                                                             │
│   ─────────────────────────────────────────────────────────────────────────│
│                                                                             │
│   PERFORMANCE EVM: Direct function calls                                    │
│   ──────────────────────────────────────                                    │
│                                                                             │
│   handler = cursor.opcode_handler  ← CPU: "Always load from same offset"   │
│   @call(.always_tail, handler, ..) ← Misprediction rate: ~0%               │
│                                                                             │
│   For 1000 opcodes: ~0 mispredictions × 15 cycles = 0 wasted cycles        │
│                                                                             │
│   ─────────────────────────────────────────────────────────────────────────│
│                                                                             │
│   Summary:                                                                  │
│   ┌─────────────────────────┬───────────┬───────────────────────────────┐  │
│   │ Model                   │ Branches  │ Prediction Success           │  │
│   ├─────────────────────────┼───────────┼───────────────────────────────┤  │
│   │ Mini (switch)           │ 256       │ ~50% (random)                 │  │
│   │ Performance (dispatch)  │ 1         │ ~100% (always same pattern)   │  │
│   └─────────────────────────┴───────────┴───────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Performance Comparison

The ratios below are design estimates. No benchmark in `bench/` runs the Mini EVM, so the repo does not measure them.

| Metric | Mini | Performance | Ratio |
|--------|------|-------------|-------|
| Simple arithmetic | 1.0x | 2-3x faster | 2-3x |
| Storage operations | 1.0x | 3-5x faster | 3-5x |
| Contract calls | 1.0x | 5-10x faster | 5-10x |
| Memory usage | Higher | Lower | ~0.7x |
| Branch mispredictions | ~50% | ~0% | - |
| Gas checks per block | N | 1 | Nx |

## When to Use Each

### Use Mini When:
- Learning EVM internals (code is self-documenting)
- Debugging execution issues (clear step-by-step flow)
- Need clear, auditable code (no magic)
- Reference implementation for testing
- Performance is not critical

### Use Performance When:
- Production execution
- High throughput required
- Running many transactions
- Benchmarking
- Gas simulation at scale

## Code Size Comparison

Measured with `wc -c`, `wc -l` and `find -name '*.zig' | wc -l`; sizes drift as the code changes.

| Component | Mini (`mini/src/`) | Performance (`src/`) |
|-----------|------|-------------|
| EVM orchestrator (`evm.zig`) | ~97KB | ~340KB |
| Frame (`frame.zig`, `frame/frame.zig`) | ~26KB | ~31KB |
| Handlers (`instructions/handlers_*.zig`) | ~2.6K lines (~16.6K with `*_test.zig`) | ~18.1K lines (tests inline) |
| Storage | ~16KB (`storage.zig`) | ~120KB `storage/database.zig` + ~53KB `storage/journal.zig` |
| Preprocessor (`preprocessor/*.zig`) | N/A | ~179KB |
| `.zig` files | 46 | 187 |
