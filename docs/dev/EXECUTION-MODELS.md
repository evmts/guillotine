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
// mini/src/frame.zig:540-553
pub fn execute(self: *Self) EvmError!void {
    // Simple while loop - easy to understand
    while (!self.stopped and !self.reverted and self.pc < self.bytecode.len()) {
        try self.step();
    }
}

pub fn step(self: *Self) EvmError!void {
    // Read opcode from bytecode
    const opcode = self.bytecode.getOpcode(self.pc) orelse {
        return error.InvalidOpcode;
    };

    // Dispatch via switch statement (256 cases)
    switch (opcode) {
        0x00 => try SystemHandlers.stop(self),
        0x01 => try ArithmeticHandlers.add(self),
        0x02 => try ArithmeticHandlers.mul(self),
        // ... all 256 opcodes
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
// src/frame/frame.zig:200-220
pub fn interpret(
    self: *Self,
    schedule: [*]const Dispatch.Item,
    jump_table: *const Dispatch.JumpTable,
    bytecode_raw: []const u8,
) Error!void {
    // Store context
    self.code = bytecode_raw;
    self.jump_table = jump_table;

    // Validate first block gas (once for entire block)
    const first_block = schedule[0].first_block_gas;
    if (self.gas_remaining < first_block.gas) {
        return Error.OutOfGas;
    }
    self.gas_remaining -= first_block.gas;

    // Start tail-call chain - NEVER returns normally
    // Each handler tail-calls the next
    return @call(.always_tail, schedule[1].opcode_handler, .{self, schedule + 1});
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
│   │ 1. TRACER SYNC (debug builds only)                                  │  │
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
│   │    next = dispatch.getOpData(.ADD)                                  │  │
│   │    • Contains function pointer + cursor offset                      │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│   │                                                                         │
│   ▼                                                                         │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ 4. TAIL-CALL NEXT (NEVER returns)                                   │  │
│   │    return @call(.always_tail, next.handler, {self, next.cursor})    │  │
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
    // 1. Tracer sync (debug builds only)
    self.beforeInstruction(.ADD, cursor);

    // 2. Execute (pre-validated, use unsafe operations)
    self.stack.binary_op_unsafe(struct {
        fn op(top: WordType, second: WordType) WordType {
            return top +% second;
        }
    }.op);

    // 3. Get next handler from dispatch metadata
    const next = dispatch.getOpData(.ADD);

    // 4. Tail-call next handler (NEVER returns)
    return @call(.always_tail, next.handler, .{self, next.cursor});
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
│   Schedule built:                                                           │
│   [0] first_block_gas { gas: 9, min_stack: 0, max_stack: 2 }               │
│   [1] &push_handler                                                         │
│   [2] push_inline { value: 5 }                                             │
│   [3] &push_handler                                                         │
│   [4] push_inline { value: 3 }                                             │
│   [5] &add_handler                                                          │
│   [6] &implicit_stop_handler                                                │
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
│   └─ tail-call schedule[1].handler(frame, &schedule[1])                    │
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
│   │   ├─ Read data[stack_ptr] = 3                                          │
│   │   ├─ stack_ptr += 1                                                    │
│   │   ├─ data[stack_ptr] = 5 + 3 = 8                                       │
│   │   └─ Stack: [3, 5] → [8]                                               │
│   └─ tail-call cursor[1].handler(frame, cursor+1)  // schedule[6]          │
│                                                                             │
│   ─────────────────────────────────────────────────────────────────────────│
│   implicit_stop_handler (cursor @ schedule[6]):                             │
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
│   │ items: []u256  (dynamic array)                                      │  │
│   │ len: usize                                                          │  │
│   │ allocator: Allocator                                                │  │
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
│   Structure (64-byte aligned for cache line):                               │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ data: [1024]u256 align(64)   (fixed array, preallocated)            │  │
│   │ stack_ptr: usize             (points to next free slot)             │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│   Memory Layout (downward growth):                                          │
│                                                                             │
│   Index 0    ─┐                                                            │
│               │ ← Empty slots                                              │
│   ...         │                                                            │
│               │                                                            │
│   Index N  ───┤ ← stack_ptr (next free)                                    │
│               │                                                            │
│   Index N+1 ──┤ ← Top of stack (most recent push)                          │
│               │                                                            │
│   Index N+2 ──┤ ← Second item                                              │
│               │                                                            │
│   ...         │                                                            │
│               │                                                            │
│   Index 1023 ─┘ ← Bottom of stack                                          │
│                                                                             │
│   Push: stack_ptr -= 1; data[stack_ptr] = value  (NO check)                │
│   Pop:  value = data[stack_ptr]; stack_ptr += 1  (NO check)                │
│                                                                             │
│   Why safe? Preprocessing validated stack bounds for entire basic block.   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// src/stack/stack.zig

// Unsafe operations - caller must validate first
pub inline fn pop_unsafe(self: *Self) WordType {
    self.stack_ptr += 1;  // Downward growth
    return self.data[self.stack_ptr - 1];
}

pub inline fn push_unsafe(self: *Self, value: WordType) void {
    self.stack_ptr -= 1;
    self.data[self.stack_ptr] = value;
}

// Optimized binary operation (ADD, SUB, MUL, etc.)
pub inline fn binary_op_unsafe(
    self: *Self,
    comptime op: fn (WordType, WordType) WordType,
) void {
    // No intermediate storage - in-place modification
    const a = self.data[self.stack_ptr];
    self.stack_ptr += 1;
    self.data[self.stack_ptr] = op(self.data[self.stack_ptr], a);
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

### Mini: Sparse HashMap

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      MINI MEMORY: SPARSE HASHMAP                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Structure: HashMap(u32 → u8)                                              │
│                                                                             │
│   MSTORE(offset=0x40, value=0x1234...5678)                                 │
│                                                                             │
│   Stores 32 individual entries:                                             │
│   ┌───────────┬───────────┐                                                │
│   │ Key       │ Value     │                                                │
│   ├───────────┼───────────┤                                                │
│   │ 0x40      │ 0x00      │                                                │
│   │ 0x41      │ 0x00      │                                                │
│   │ ...       │ ...       │                                                │
│   │ 0x5E      │ 0x56      │                                                │
│   │ 0x5F      │ 0x78      │                                                │
│   └───────────┴───────────┘                                                │
│                                                                             │
│   Pros: Only stores non-zero bytes (sparse)                                 │
│   Cons: 32 hash lookups per word read/write                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// mini/src/frame.zig
memory: std.AutoHashMap(u32, u8),  // Only non-zero bytes stored

pub fn readMemory(self: *Self, offset: u32) u8 {
    return self.memory.get(offset) orelse 0;  // Default to 0
}

pub fn writeMemory(self: *Self, offset: u32, value: u8) !void {
    try self.memory.put(offset, value);
    // Update memory_size for expansion tracking
    if (offset >= self.memory_size) {
        self.memory_size = wordAlignedSize(offset + 1);
    }
}
```

### Performance: Word-Aligned Pages

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                   PERFORMANCE MEMORY: WORD-ALIGNED PAGES                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Structure: Array of 4KB pages, each containing 128 words (32 bytes each) │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ Page 0 (0x0000-0x0FFF)                                              │  │
│   │ ┌────────┬────────┬────────┬────────┬─────────────────────────────┐│  │
│   │ │Word 0  │Word 1  │Word 2  │Word 3  │ ...                         ││  │
│   │ │32 bytes│32 bytes│32 bytes│32 bytes│                             ││  │
│   │ └────────┴────────┴────────┴────────┴─────────────────────────────┘│  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ Page 1 (0x1000-0x1FFF)                                              │  │
│   │ ┌────────┬────────┬────────┬────────┬─────────────────────────────┐│  │
│   │ │Word 0  │Word 1  │Word 2  │Word 3  │ ...                         ││  │
│   │ └────────┴────────┴────────┴────────┴─────────────────────────────┘│  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│   MLOAD(offset=0x40):                                                       │
│   page_idx = 0x40 / 4096 = 0                                               │
│   word_idx = (0x40 % 4096) / 32 = 2                                        │
│   return pages[0].words[2]  // Single array access!                        │
│                                                                             │
│   Pros: O(1) word access, cache-friendly                                   │
│   Cons: Allocates full pages even for sparse access                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// src/memory/memory.zig
pub fn Memory(comptime config: MemoryConfig) type {
    return struct {
        pages: []Page,  // Pre-allocated pages
        size: usize,

        pub fn load(self: *Self, offset: usize) WordType {
            // Direct page lookup, word-aligned access
            const page_idx = offset / PAGE_SIZE;
            const page_offset = offset % PAGE_SIZE;
            return self.pages[page_idx].words[page_offset / 32];
        }

        pub fn store(self: *Self, offset: usize, value: WordType) void {
            const page_idx = offset / PAGE_SIZE;
            const page_offset = offset % PAGE_SIZE;
            self.pages[page_idx].words[page_offset / 32] = value;
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

| Component | Mini | Performance |
|-----------|------|-------------|
| EVM orchestrator | 94KB | 270KB |
| Frame | 25KB | 50KB |
| Handlers | ~18K lines | ~18K lines |
| Storage | 16KB | 88KB + 34KB |
| Preprocessor | N/A | ~50KB |
| Total files | ~46 | ~158 |
