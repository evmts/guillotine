# Architecture Deep Dive

This document provides a comprehensive understanding of both EVM implementations with actual code excerpts, architectural diagrams, and detailed explanations.

## System Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           GUILLOTINE EVM SYSTEM                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Transaction Input                                                         │
│         │                                                                   │
│         ▼                                                                   │
│   ┌───────────────────────────────────────────────────────────────────┐    │
│   │                        EVM ORCHESTRATOR                           │    │
│   │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐               │    │
│   │  │   State     │  │   Journal   │  │   Access    │               │    │
│   │  │   (DB)      │  │  (Rollback) │  │    List     │               │    │
│   │  └─────────────┘  └─────────────┘  └─────────────┘               │    │
│   │                           │                                       │    │
│   │                           ▼                                       │    │
│   │   ┌───────────────────────────────────────────────────────────┐  │    │
│   │   │                    CALL STACK                              │  │    │
│   │   │  ┌─────────┐  ┌─────────┐  ┌─────────┐                    │  │    │
│   │   │  │ Frame 1 │→ │ Frame 2 │→ │ Frame 3 │  ...               │  │    │
│   │   │  │ (root)  │  │ (CALL)  │  │ (CALL)  │                    │  │    │
│   │   │  └─────────┘  └─────────┘  └─────────┘                    │  │    │
│   │   └───────────────────────────────────────────────────────────┘  │    │
│   └───────────────────────────────────────────────────────────────────┘    │
│         │                                                                   │
│         ▼                                                                   │
│   Transaction Output (success/revert, return data, gas used, logs)         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Two EVM Implementations

Guillotine contains two complete EVM implementations:

| Implementation | Location | Philosophy | Primary Use |
|----------------|----------|------------|-------------|
| **Mini** | `mini/src/` | Clarity over performance | Learning, testing, reference |
| **Performance** | `src/` | Speed via dispatch optimization | Production execution |

Both select a hardfork from Frontier through Osaka; `Hardfork.DEFAULT` is `OSAKA` (lib/voltaire/src/primitives/hardfork.zig). Neither passes the full Ethereum spec suite yet. See [specs/README.md](../../specs/README.md) for the current EEST pass rate of the Performance EVM.

### Why Two Implementations?

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   MINI EVM                              PERFORMANCE EVM                     │
│   ────────                              ───────────────                     │
│                                                                             │
│   ┌─────────────────────────┐           ┌─────────────────────────┐        │
│   │  • Easy to understand   │           │  • Optimized for speed  │        │
│   │  • 46 .zig files        │           │  • 187 .zig files       │        │
│   │  • Sequential execution │           │  • Dispatch execution   │        │
│   │  • Per-op gas checking  │           │  • Per-block gas        │        │
│   │  • No preprocessing     │           │  • Bytecode analysis    │        │
│   └─────────────────────────┘           └─────────────────────────┘        │
│              │                                      │                       │
│              └──────────────┬───────────────────────┘                       │
│                             │                                               │
│                             ▼                                               │
│              ┌─────────────────────────────┐                                │
│              │  Same Ethereum specs         │                                │
│              │  Separate test suites:       │                                │
│              │  test-mini-specs, state-tests│                                │
│              └─────────────────────────────┘                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. EVM Orchestrator

The EVM orchestrator manages high-level execution: call stack, state access, gas refunds.

#### Mini EVM (Traditional)

```zig
// mini/src/evm.zig - Complete state management in one file (excerpt)
pub fn Evm(comptime config: EvmConfig) type {
    return struct {
        pub const AccountState = struct {
            balance: u256 = 0,
            nonce: u64 = 0,
            code: []const u8 = &[_]u8{},
        };

        // Account state: one map lookup returns balance, nonce and code
        frames: std.ArrayList(FrameType),
        storage: Storage,
        accounts: std.AutoHashMap(primitives.Address, AccountState),

        // Transaction state
        access_list_manager: AccessListManager,  // warm addresses and slots
        gas_refund: u64,

        // Execution context
        origin: primitives.Address,
        gas_price: u256,
        block_context: BlockContext,
    };
}
```

#### Performance EVM (Modular)

```zig
// src/evm.zig - Delegates to specialized modules (excerpt)
pub fn Evm(comptime config: EvmConfig) type {
    return struct {
        // Modular state management
        journal: Journal,              // src/storage/journal.zig
        access_list: AccessList,       // src/storage/access_list.zig
        database: *Database,           // src/storage/database.zig

        // Execution support
        call_arena: GrowingArenaAllocator,
        tracer: @import("tracer/tracer.zig").Tracer,
    };
}
```

### 2. Frame (Execution Context)

The Frame manages a single call's execution: stack, memory, gas, bytecode.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              FRAME ANATOMY                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │  STACK (1024 slots max)                                             │  │
│   │  ┌────┬────┬────┬────┬────┬────┬─────────────────────────────────┐  │  │
│   │  │ S0 │ S1 │ S2 │ S3 │ S4 │ S5 │  ...                            │  │  │
│   │  │TOP │    │    │    │    │    │                                 │  │  │
│   │  └────┴────┴────┴────┴────┴────┴─────────────────────────────────┘  │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │  MEMORY (expandable, word-aligned)                                  │  │
│   │  ┌────────┬────────┬────────┬────────┬─────────────────────────┐   │  │
│   │  │ 0x00   │ 0x20   │ 0x40   │ 0x60   │  ...                    │   │  │
│   │  │ 32B    │ 32B    │ 32B    │ 32B    │                         │   │  │
│   │  └────────┴────────┴────────┴────────┴─────────────────────────┘   │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│   ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐   │
│   │  PC / Cursor    │  │  Gas Remaining  │  │  Return Data Buffer     │   │
│   │  (where am I?)  │  │  (fuel left)    │  │  (from last CALL)       │   │
│   └─────────────────┘  └─────────────────┘  └─────────────────────────┘   │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │  CONTEXT: caller, address, value, calldata, bytecode                │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Mini Frame

```zig
// mini/src/frame.zig (Frame fields, excerpt)
stack: std.ArrayList(u256),           // Bounds-checked every operation
memory: std.ArrayList(u8),            // Contiguous byte buffer
memory_size: u32,
pc: u32,                               // Program counter into bytecode
gas_remaining: i64,
bytecode: Bytecode,                    // With JUMPDEST analysis
caller: Address,
address: Address,
value: u256,
calldata: []const u8,
```

#### Performance Frame

```zig
// src/frame/frame.zig (Frame fields, excerpt)
// CACHE LINE 1 (hot data - 64 bytes aligned)
stack: Stack,                          // Cache-aligned, pre-validated ops
gas_remaining: GasType,
evm_ptr: *anyopaque,
database: *anyopaque,
memory: Memory,
contract_address: Address,
caller: Address,

// Less frequently accessed
value: WordType,
calldata_slice: []const u8,
code: []const u8,
jump_table: *const Dispatch.JumpTable,
dispatch: Dispatch,                    // Schedule cursor (NOT PC!)
instruction_counter: config.createLoopSafetyCounter(),
```

### 3. Stack Implementation

```
Stack Growth Direction
──────────────────────

MINI EVM: Upward growth (ArrayList)    PERFORMANCE: Downward growth (Array)
──────────────────────────────────     ─────────────────────────────────────

    Index 1023 ─┐                           Index 0 ─┐
                │ ← Empty                            │ ← Empty
    Index 1022 ─┤                           Index 1 ─┤
                │ ← Empty                            │ ← Empty
       ...      │                              ...   │
                │                                    │
    Index 2  ───┤                          Index N ──┤
                │ ← items[2]                         │ ← stack_ptr points here
    Index 1  ───┤                          Index N+1─┤
                │ ← items[1]                         │ ← data[N+1]
    Index 0  ───┘                          Index N+2─┘
                  ← items[0] (bottom)                  ← data[N+2] (bottom)

push: items.append(value)              push: stack_ptr -= 1; data[stack_ptr] = value
pop:  items.len -= 1                   pop:  stack_ptr += 1; return data[stack_ptr-1]
```

#### Mini Stack (ArrayList)

```zig
// mini/src/frame.zig:161-176
pub fn pushStack(self: *Self, value: u256) EvmError!void {
    if (self.stack.items.len >= 1024) {
        return error.StackOverflow;  // Check every push
    }
    try self.stack.append(self.allocator, value);
}

pub fn popStack(self: *Self) EvmError!u256 {
    if (self.stack.items.len == 0) {
        return error.StackUnderflow;  // Check every pop
    }
    const value = self.stack.items[self.stack.items.len - 1];
    self.stack.items.len -= 1;
    return value;
}
```

#### Performance Stack (Cache-Aligned Array)

```zig
// src/stack/stack.zig - Pointer-based, downward growth
// (Debug/ReleaseSafe tracer asserts omitted)
pub fn Stack(config: StackConfig) type {
    return struct {
        // Heap buffer of stack_capacity words, 64-byte cache line aligned
        buf_ptr: [*]align(64) WordType,
        // Points to the top item, or one past the buffer when empty
        stack_ptr: [*]align(ptr_align) WordType,

        // Unsafe operations (caller validates first via preprocessing)
        pub inline fn pop_unsafe(self: *Self) WordType {
            const value = self.stack_ptr[0];
            self.stack_ptr += 1;
            return value;
        }

        pub inline fn push_unsafe(self: *Self, value: WordType) void {
            self.stack_ptr -= 1;
            self.stack_ptr[0] = value;
        }

        // Binary operation in place: result overwrites the second item
        pub inline fn binary_op_unsafe(
            self: *Self,
            comptime op: fn (a: WordType, b: WordType) WordType,
        ) void {
            const top = self.stack_ptr[0];
            const second = self.stack_ptr[1];
            self.stack_ptr[1] = op(top, second);
            self.stack_ptr += 1;
        }
    };
}
```

## Execution Flow

### Mini EVM: Sequential Interpretation

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         MINI EVM EXECUTION LOOP                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Bytecode: [60 05 60 03 01 00]  (PUSH1 5, PUSH1 3, ADD, STOP)             │
│              ▲                                                              │
│              │ PC=0                                                         │
│              │                                                              │
│   ┌──────────┴──────────┐                                                  │
│   │                     │                                                  │
│   │  ┌───────────────┐  │                                                  │
│   │  │ Read opcode   │  │  opcode = bytecode[PC] = 0x60                    │
│   │  │ at PC         │  │                                                  │
│   │  └───────┬───────┘  │                                                  │
│   │          │          │                                                  │
│   │  ┌───────▼───────┐  │                                                  │
│   │  │ Switch on     │  │  switch(0x60) → case PUSH1                       │
│   │  │ opcode        │  │                                                  │
│   │  └───────┬───────┘  │                                                  │
│   │          │          │                                                  │
│   │  ┌───────▼───────┐  │                                                  │
│   │  │ Execute       │  │  push(bytecode[PC+1])  // push 5                 │
│   │  │ handler       │  │  PC += 2                                         │
│   │  └───────┬───────┘  │                                                  │
│   │          │          │                                                  │
│   │  ┌───────▼───────┐  │                                                  │
│   │  │ Check flags   │  │  stopped? reverted? PC >= len?                   │
│   │  └───────┬───────┘  │                                                  │
│   │          │ NO       │                                                  │
│   │          │          │                                                  │
│   └──────────┴──────────┘  Loop continues...                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// mini/src/frame.zig (tracing and loop_quota checks omitted)
pub fn execute(self: *Self) EvmError!void {
    while (!self.stopped and !self.reverted and self.pc < self.bytecode.len()) {
        try self.step();
    }
}

pub fn step(self: *Self) EvmError!void {
    if (self.stopped or self.reverted or self.pc >= self.bytecode.len()) return;
    const opcode = self.getCurrentOpcode() orelse return;
    try self.executeOpcode(opcode);
}

pub fn executeOpcode(self: *Self, opcode: u8) EvmError!void {
    // (JavaScript and config opcode overrides are checked first)
    // Giant switch statement - one case per opcode
    switch (opcode) {
        0x00 => try ControlFlowHandlers.stop(self),
        0x01 => try ArithmeticHandlers.add(self),
        0x02 => try ArithmeticHandlers.mul(self),
        // ... every other opcode
    }
}
```

### Performance EVM: Dispatch Execution

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      PERFORMANCE EVM DISPATCH EXECUTION                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   PREPROCESSING (once per bytecode)                                         │
│   ─────────────────────────────────                                         │
│                                                                             │
│   Bytecode: [60 05 60 03 01 00]   (schedule shown with fusion disabled)    │
│                  │                                                          │
│                  ▼                                                          │
│   Schedule: [                                                               │
│     [0] first_block_gas { gas: 9, min_stack: 0, max_stack: 2 }             │
│     [1] &push_handler                                                       │
│     [2] push_inline { value: 5 }                                           │
│     [3] &push_handler                                                       │
│     [4] push_inline { value: 3 }                                           │
│     [5] &add_handler                                                        │
│     [6] &stop_handler                                                       │
│   ]                                                                         │
│                                                                             │
│   EXECUTION (tail-call chain)                                               │
│   ───────────────────────────                                               │
│                                                                             │
│   schedule[1].handler(frame, &schedule[1])                                  │
│        │                                                                    │
│        ▼                                                                    │
│   push_handler:                                                             │
│     value = cursor[1].push_inline.value  // 5                              │
│     stack.push_unsafe(value)                                                │
│     @call(.always_tail, cursor[2].handler, ...)                            │
│        │                                                                    │
│        ▼  (tail call - no return)                                          │
│   push_handler:                                                             │
│     value = cursor[1].push_inline.value  // 3                              │
│     stack.push_unsafe(value)                                                │
│     @call(.always_tail, cursor[2].handler, ...)                            │
│        │                                                                    │
│        ▼  (tail call - no return)                                          │
│   add_handler:                                                              │
│     stack.binary_op_unsafe(add)                                             │
│     @call(.always_tail, cursor[1].handler, ...)                            │
│        │                                                                    │
│        ▼  (tail call - no return)                                          │
│   stop_handler:                                                             │
│     return Error.Stop  // Exit via error, not return                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

With the default `enable_fusion = true` (src/evm_config.zig), the preprocessor
fuses `PUSH1 3` + `ADD` into one `PUSH_ADD_INLINE` item.

```zig
// src/frame/frame.zig - Entry point (tracer calls and stack-bound checks omitted)
pub fn interpret(
    self: *Self,
    dispatch_schedule: *const Dispatch.DispatchSchedule,
    jump_table: *const Dispatch.JumpTable,
    bytecode_raw: []const u8,
) Error!void {
    self.code = bytecode_raw;
    self.jump_table = jump_table;
    const schedule = dispatch_schedule.items;
    const start_index: usize = @intFromBool(dispatch_schedule.has_first_block_gas);

    // Charge the first basic block's gas once
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

## Dispatch System

### Schedule Structure

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          DISPATCH SCHEDULE STRUCTURE                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Item Union Types:                                                         │
│   ─────────────────                                                         │
│                                                                             │
│   ┌─────────────────┐   Function pointer to handler                         │
│   │ opcode_handler  │   *const fn(*Frame, [*]Item) Error!noreturn           │
│   └─────────────────┘                                                       │
│                                                                             │
│   ┌─────────────────┐   First basic block metadata                          │
│   │ first_block_gas │   { gas: u32, min_stack: i16, max_stack: i16 }        │
│   └─────────────────┘                                                       │
│                                                                             │
│   ┌─────────────────┐   JUMPDEST basic block metadata                       │
│   │ jump_dest       │   { gas: u32, min_stack: i16, max_stack: i16 }        │
│   └─────────────────┘                                                       │
│                                                                             │
│   ┌─────────────────┐   Small PUSH values (≤8 bytes)                        │
│   │ push_inline     │   { value: u64 }                                      │
│   └─────────────────┘                                                       │
│                                                                             │
│   ┌─────────────────┐   Large PUSH values (>8 bytes)                        │
│   │ push_pointer    │   { value_ptr: *const WordType }                      │
│   └─────────────────┘                                                       │
│                                                                             │
│   ┌─────────────────┐   Pre-resolved static jump                            │
│   │ jump_static     │   { dispatch: *const anyopaque }                      │
│   └─────────────────┘                                                       │
│                                                                             │
│   ┌─────────────────┐   Maps cursor position to bytecode PC                 │
│   │ pc              │   { value: uN }  (uN sized to PcType)                 │
│   └─────────────────┘                                                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// src/preprocessor/dispatch.zig
// Untagged union: exactly 8 bytes in ReleaseFast/ReleaseSmall.
// Debug/ReleaseSafe add a hidden safety tag.
pub const Item = union {
    opcode_handler: OpcodeHandler,               // Function pointer
    jump_dest: Metadata.JumpDestMetadata,        // Block gas/stack info
    push_inline: Metadata.PushInlineMetadata,    // Small values (≤8 bytes)
    push_pointer: Metadata.PushPointerMetadata,  // Large values (>8 bytes)
    pc: Metadata.PcMetadata,
    jump_static: Metadata.JumpStaticMetadata,    // Pre-resolved jumps
    first_block_gas: Metadata.FirstBlockMetadata,
};
```

### Handler Pattern

```zig
// src/instructions/handlers_arithmetic.zig - every handler follows this pattern
pub fn add(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
    // 1. Tracer sync (Debug and ReleaseSafe builds only)
    self.beforeInstruction(.ADD, cursor);

    // 2. Execute (pre-validated, use unsafe)
    self.stack.binary_op_unsafe(struct {
        fn op(top: WordType, second: WordType) WordType {
            return top +% second;
        }
    }.op);

    // 3. Look up the next handler and tail-call it (NEVER returns)
    return dispatch_next.nextInstruction(FrameType, self, cursor, .ADD);
}
```

### CRITICAL: Cursor vs Program Counter

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       CURSOR ≠ PROGRAM COUNTER                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Bytecode (PC-indexed):         Dispatch Schedule (cursor-indexed):        │
│   ──────────────────────         ───────────────────────────────────        │
│                                                                             │
│   PC=0: PUSH1                    [0]: first_block_gas { gas: 9 }           │
│   PC=1: 0x05  (data)             [1]: &push_handler                         │
│   PC=2: PUSH1                    [2]: push_inline { value: 5 }             │
│   PC=3: 0x03  (data)             [3]: &push_handler                         │
│   PC=4: ADD                      [4]: push_inline { value: 3 }             │
│   PC=5: STOP                     [5]: &add_handler                          │
│                                  [6]: &stop_handler                         │
│                                                                             │
│   NOTE: Schedule[0] is metadata, not PC=0!                                  │
│         Schedule indices do NOT correspond to bytecode PCs!                 │
│         Synthetic opcodes in schedule represent multiple bytecode ops!      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## CALL/CREATE Execution Flow

### CALL Opcode Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            CALL EXECUTION FLOW                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Caller Frame (Contract A)                                                 │
│   ─────────────────────────                                                 │
│                                                                             │
│   1. CALL opcode executed                                                   │
│      ├── Pop 7 values: gas, addr, value, argsOff, argsLen, retOff, retLen  │
│      ├── Calculate gas to forward (63/64 rule)                             │
│      └── Create snapshot for potential rollback                            │
│                                                                             │
│   2. Pre-call checks                                                        │
│      ├── Check balance >= value                                            │
│      ├── Check call depth < 1024                                           │
│      └── Access list: warm address? (charge cold cost if not)              │
│                                                                             │
│   3. Create new Frame for callee                                           │
│      │                                                                      │
│      ▼                                                                      │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │  Callee Frame (Contract B)                                          │  │
│   │  ─────────────────────────                                          │  │
│   │                                                                     │  │
│   │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                 │  │
│   │  │ Fresh stack │  │ Fresh memory│  │ Subset gas  │                 │  │
│   │  │ []          │  │ []          │  │ (forwarded) │                 │  │
│   │  └─────────────┘  └─────────────┘  └─────────────┘                 │  │
│   │                                                                     │  │
│   │  Execute callee bytecode...                                         │  │
│   │                                                                     │  │
│   │  ┌─────────────────────────────────────────────────────────────┐   │  │
│   │  │ RETURN: Copy output to caller's memory[retOff:retOff+retLen]│   │  │
│   │  │ REVERT: Rollback state, copy output, return 0               │   │  │
│   │  │ STOP:   Success with no output                               │   │  │
│   │  │ ERROR:  Rollback state, consume all gas, return 0            │   │  │
│   │  └─────────────────────────────────────────────────────────────┘   │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│      │                                                                      │
│      ▼                                                                      │
│   4. Back in Caller Frame                                                   │
│      ├── Push success (1) or failure (0) to stack                          │
│      ├── Unused callee gas returned to caller                              │
│      └── Return data available via RETURNDATASIZE/RETURNDATACOPY           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### CREATE/CREATE2 Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          CREATE EXECUTION FLOW                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   1. Compute new contract address                                           │
│      │                                                                      │
│      ├── CREATE:  keccak256(rlp([sender, nonce]))[12:]                     │
│      │                                                                      │
│      └── CREATE2: keccak256(0xff ++ sender ++ salt ++ keccak256(init))[12:] │
│                                                                             │
│   2. Pre-create checks                                                      │
│      ├── Address collision? (nonce != 0 OR code exists)                    │
│      ├── Value transfer possible?                                           │
│      ├── Initcode size limit (EIP-3860: max 49152 bytes)                   │
│      └── Call depth < 1024                                                  │
│                                                                             │
│   3. Initialize new account                                                 │
│      ├── Set nonce = 1                                                     │
│      ├── Transfer value                                                     │
│      └── Mark as "created this transaction"                                 │
│                                                                             │
│   4. Execute initcode                                                       │
│      │                                                                      │
│      ▼                                                                      │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │  Constructor Frame                                                  │  │
│   │                                                                     │  │
│   │  • Bytecode = initcode from memory                                  │  │
│   │  • address = newly computed address                                 │  │
│   │  • value = creation value                                           │  │
│   │  • calldata = empty                                                 │  │
│   │                                                                     │  │
│   │  Execute until RETURN or error...                                   │  │
│   │                                                                     │  │
│   │  RETURN data = deployed runtime bytecode                            │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│      │                                                                      │
│      ▼                                                                      │
│   5. Deploy returned bytecode                                               │
│      ├── Check code size limit (24576 bytes)                               │
│      ├── Check no 0xEF prefix (EIP-3541)                                   │
│      ├── Charge gas: 200 * code_length                                     │
│      └── Store code at new address                                          │
│                                                                             │
│   6. Push result to caller stack                                            │
│      ├── Success: new contract address                                      │
│      └── Failure: 0                                                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## State Management

### Storage Model

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          STORAGE ARCHITECTURE                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   THREE STORAGE TYPES:                                                      │
│                                                                             │
│   ┌───────────────────────────────────────────────────────────────────┐    │
│   │ 1. PERSISTENT STORAGE                                             │    │
│   │    • Modified by SSTORE                                           │    │
│   │    • Read by SLOAD                                                │    │
│   │    • Committed to state at transaction end                        │    │
│   │    • Key: (address, slot) → Value: u256                           │    │
│   └───────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│   ┌───────────────────────────────────────────────────────────────────┐    │
│   │ 2. ORIGINAL STORAGE                                               │    │
│   │    • Snapshot at transaction start                                │    │
│   │    • NEVER modified during transaction                            │    │
│   │    • Used for gas refund calculations (EIP-2200)                  │    │
│   │    • Comparison: original vs current vs new                       │    │
│   └───────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│   ┌───────────────────────────────────────────────────────────────────┐    │
│   │ 3. TRANSIENT STORAGE (EIP-1153, Cancun+)                          │    │
│   │    • TLOAD/TSTORE opcodes                                         │    │
│   │    • Cleared at transaction boundary                              │    │
│   │    • Writes roll back when their call frame reverts               │    │
│   │    • Always warm access (100 gas)                                 │    │
│   └───────────────────────────────────────────────────────────────────┘    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Journal System (Performance Only)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            JOURNAL SYSTEM                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Purpose: Enable rollback on REVERT or failed CALL                         │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                         Journal Entries                             │  │
│   ├─────────────────────────────────────────────────────────────────────┤  │
│   │ [0] snapshot_id=0, storage_change(0xAAA, slot=1, orig=0)           │  │
│   │ [1] snapshot_id=0, balance_change(0xAAA, orig=1000)                │  │
│   │ [2] snapshot_id=1, storage_change(0xBBB, slot=0, orig=42)          │  │
│   │ [3] snapshot_id=1, nonce_change(0xAAA, orig=5)                     │  │
│   │ [4] snapshot_id=2, storage_change(0xCCC, slot=7, orig=0)           │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│   REVERT to snapshot_id=1:                                                  │
│   • Remove entries with snapshot_id >= 1                                    │
│   • Entries [2], [3], [4] removed                                           │
│   • Entries [0], [1] remain                                                 │
│   • Database.revert_to_snapshot restores account and storage state;         │
│     the journal itself writes nothing back                                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// src/storage/journal.zig (excerpt; original_storage index upkeep omitted)
pub fn Journal(comptime config: JournalConfig) type {
    return struct {
        entries: std.ArrayList(Entry),
        next_snapshot_id: SnapshotIdType,
        allocator: std.mem.Allocator,

        pub fn create_snapshot(self: *Self) Error!SnapshotIdType {
            if (self.next_snapshot_id == std.math.maxInt(SnapshotIdType)) {
                return error.SnapshotIdExhausted;
            }
            const id = self.next_snapshot_id;
            self.next_snapshot_id += 1;
            return id;
        }

        pub fn revert_to_snapshot(self: *Self, snapshot_id: SnapshotIdType) void {
            var write_idx: usize = 0;
            for (self.entries.items) |entry| {
                if (entry.snapshot_id < snapshot_id) {
                    self.entries.items[write_idx] = entry;
                    write_idx += 1;
                    continue;
                }
                // ... drop this entry's original_storage index row
            }
            self.entries.shrinkRetainingCapacity(write_idx);
        }
    };
}
```

A failed frame reverts through `Evm.revertFrame` (src/evm.zig). It truncates
logs, restores the refund counter, the access list, SELFDESTRUCT marks and
created contracts from a frame checkpoint, then calls
`journal.revert_to_snapshot` and `database.revert_to_snapshot`.

### Access List (EIP-2929)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         WARM/COLD ACCESS TRACKING                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   FIRST ACCESS = COLD (expensive)        SUBSEQUENT = WARM (cheap)          │
│   ──────────────────────────────         ─────────────────────────          │
│                                                                             │
│   Account access:                        Storage access:                    │
│   Cold: 2600 gas                         Cold: 2100 gas                     │
│   Warm: 100 gas                          Warm: 100 gas                      │
│                                                                             │
│   Example Transaction:                                                      │
│   ────────────────────                                                      │
│                                                                             │
│   SLOAD(0xAAA, slot=1)  → Cold: 2100 gas, mark warm                        │
│   SLOAD(0xAAA, slot=1)  → Warm: 100 gas                                    │
│   SLOAD(0xAAA, slot=2)  → Cold: 2100 gas, mark warm                        │
│   BALANCE(0xBBB)        → Cold: 2600 gas, mark warm                        │
│   BALANCE(0xBBB)        → Warm: 100 gas                                    │
│                                                                             │
│   Pre-warming via Access List (EIP-2930):                                   │
│   ───────────────────────────────────────                                   │
│   Transaction includes: { address: 0xAAA, slots: [1, 2, 3] }               │
│   Pay upfront: 2400 + 3*1900 = 8100 gas                                    │
│   All listed become warm before execution                                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Bytecode Analysis

### JUMPDEST Tracking

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        JUMPDEST VALIDATION                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Bytecode: [60 5B 5B 00]                                                   │
│              │  │  │  │                                                     │
│              │  │  │  └── STOP (0x00)                                       │
│              │  │  └───── JUMPDEST (0x5B) at PC=2 ✓ VALID                   │
│              │  └──────── 0x5B is PUSH data, NOT instruction ✗ INVALID      │
│              └─────────── PUSH1 (0x60)                                      │
│                                                                             │
│   Analysis walks bytecode, skipping PUSH data:                              │
│                                                                             │
│   PC=0: PUSH1 → skip 1 byte → PC=2                                         │
│   PC=2: JUMPDEST → add to valid set                                        │
│   PC=3: STOP → done                                                        │
│                                                                             │
│   Valid JUMPDESTs: { 2 }                                                   │
│   Invalid (but contains 0x5B): { 1 }                                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// mini/src/bytecode.zig (src/bytecode/bytecode.zig has its own analyzeJumpDests)
fn analyzeJumpDests(code: []const u8, valid_jumpdests: *std.AutoArrayHashMap(u32, void)) !void {
    var pc: u32 = 0;
    while (pc < code.len) {
        const opcode = code[pc];
        if (opcode == 0x5b) {  // JUMPDEST
            try valid_jumpdests.put(pc, {});
            pc += 1;
        } else if (opcode >= 0x60 and opcode <= 0x7f) {  // PUSH1-PUSH32
            pc += 1 + (opcode - 0x5f);  // Skip push data
        } else {
            pc += 1;
        }
    }
}
```

### Fusion Detection (Performance Only)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          OPCODE FUSION                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Common patterns fused into single dispatch items:                         │
│                                                                             │
│   ┌─────────────────┬──────────────────────┬─────────────────────────────┐ │
│   │ Bytecode        │ Standard (4 ops)     │ Fused (1 op)                │ │
│   ├─────────────────┼──────────────────────┼─────────────────────────────┤ │
│   │ PUSH1 5         │ push_handler         │                             │ │
│   │ ADD             │ push_inline {5}      │ PUSH_ADD_INLINE             │ │
│   │                 │ add_handler          │ { value: 5 }                │ │
│   │                 │ (next)               │                             │ │
│   └─────────────────┴──────────────────────┴─────────────────────────────┘ │
│                                                                             │
│   Function dispatch pattern (Solidity ABI):                                 │
│   ┌─────────────────┬──────────────────────┬─────────────────────────────┐ │
│   │ PUSH4 selector  │ 8 ops                │ FUNCTION_DISPATCH           │ │
│   │ EQ              │                      │ { selector, jump_target }   │ │
│   │ PUSH2 target    │                      │                             │ │
│   │ JUMPI           │                      │                             │ │
│   └─────────────────┴──────────────────────┴─────────────────────────────┘ │
│                                                                             │
│   39 synthetic opcodes (src/opcodes/opcode_synthetic.zig,                   │
│   docs/performance/SYNTHETIC-OPCODES.md)                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Handler Categories

### Instruction Handlers

Performance handlers live in `src/instructions/`; Mini handlers live in `mini/src/instructions/`. Where the two differ, the table names both.

| Category | Opcodes | Performance file | Mini file |
|----------|---------|------------------|-----------|
| Arithmetic | ADD, SUB, MUL, DIV, MOD, EXP, ADDMOD, MULMOD, etc. | `handlers_arithmetic.zig` | `handlers_arithmetic.zig` |
| Bitwise | AND, OR, XOR, NOT, SHL, SHR, SAR, BYTE (CLZ: Performance only) | `handlers_bitwise.zig` | `handlers_bitwise.zig` |
| Comparison | LT, GT, EQ, ISZERO, SLT, SGT | `handlers_comparison.zig` | `handlers_comparison.zig` |
| Stack | PUSH0-32, POP, DUP1-16, SWAP1-16 | `handlers_stack.zig` | `handlers_stack.zig` |
| Memory | MLOAD, MSTORE, MSTORE8, MSIZE, MCOPY | `handlers_memory.zig` | `handlers_memory.zig` |
| Storage | SLOAD, SSTORE, TLOAD, TSTORE | `handlers_storage.zig` | `handlers_storage.zig` |
| Control | JUMP, JUMPI, JUMPDEST | `handlers_jump.zig` | `handlers_control_flow.zig` |
| Control | PC | `handlers_context.zig` | `handlers_control_flow.zig` |
| Control | STOP, RETURN, REVERT | `handlers_system.zig` | `handlers_control_flow.zig` |
| Context | ADDRESS, CALLER, ORIGIN, CALLVALUE, CALLDATALOAD, etc. | `handlers_context.zig` | `handlers_context.zig` |
| Block | BLOCKHASH, COINBASE, TIMESTAMP, NUMBER, etc. | `handlers_context.zig` | `handlers_block.zig` |
| System | CALL, CALLCODE, STATICCALL, DELEGATECALL, CREATE, CREATE2, SELFDESTRUCT | `handlers_system.zig` | `handlers_system.zig` |
| Log | LOG0-LOG4 | `handlers_log.zig` | `handlers_log.zig` |
| Keccak | KECCAK256 | `handlers_keccak.zig` | `handlers_keccak.zig` |

### Synthetic Handlers (Performance Only)

```zig
// src/instructions/handlers_*_synthetic.zig
// Fused operations for common patterns

handlers_arithmetic_synthetic.zig  // PUSH+ADD, PUSH+MUL, etc.
handlers_bitwise_synthetic.zig     // PUSH+AND, PUSH+OR, etc.
handlers_memory_synthetic.zig      // PUSH+MSTORE, PUSH+MLOAD, etc.
handlers_jump_synthetic.zig        // Static jump resolution
handlers_advanced_synthetic.zig    // 3+ opcode patterns: constant folding, ISZERO+JUMPI, etc.
```

## Memory Allocation

### Mini: Arena for State, Allocator for Frames

```zig
// mini/src/evm.zig
arena: std.heap.ArenaAllocator,   // state maps (accounts, storage, ...)
allocator: std.mem.Allocator,

// mini/src/frame.zig: stack and memory grow through frame.allocator
stack: std.ArrayList(u256),
memory: std.ArrayList(u8),
```

### Performance: Call Arena plus Per-Depth Pools

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        PERFORMANCE ALLOCATION                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   call_arena (GrowingArenaAllocator, src/evm_arena_allocator.zig)           │
│   ───────────────────────────────────────────────────────────────           │
│   • Dispatch schedule and jump table for bytecode not in analysis_cache     │
│   • RETURN/REVERT output copies                                             │
│   • Log topics and data                                                     │
│   Reset after each root call: call_arena.resetRetainCapacity()              │
│   (frees everything at once, keeps grown capacity up to                     │
│   arena_capacity_limit)                                                     │
│                                                                             │
│   stack_pool / memory_pool (one buffer per call depth)                      │
│   ───────────────────────────────────────────────────────────────           │
│   • Allocated from Evm.allocator on first use at that depth                 │
│   • Reused by every later frame at the same depth                           │
│                                                                             │
│   Evm.allocator (passed to Evm.init)                                        │
│   ───────────────────────────────────────────────────────────────           │
│   • Journal entries, access list, logs list, other long-lived state         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// src/evm.zig (excerpt)
call_arena: GrowingArenaAllocator,
stack_pool: [config.max_call_depth + 1]?[*]align(64) Frame.WordType,
memory_pool: [config.max_call_depth + 1]?*std.ArrayList(u8),

// Each call borrows the pooled buffers for its depth
var frame = try Frame.initPooled(stack_buf, mem_buf, self.allocator, gas_cast,
    caller, value, input, @as(*anyopaque, @ptrCast(self)));
defer frame.deinitPooled();
```

## Configuration

Both implementations use compile-time configuration:

```zig
// Mini: mini/src/evm_config.zig
pub const EvmConfig = struct {
    hardfork: Hardfork = Hardfork.DEFAULT,  // OSAKA
    stack_size: u12 = 1024,
    max_bytecode_size: u32 = 24576,
    memory_limit: u64 = 0xFFFFFF,
    max_call_depth: u16 = 1024,
    loop_quota: ?u32 = if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) 1_000_000 else null,
    // ...
};

// Performance: src/evm_config.zig (frame_config() derives the FrameConfig)
pub const EvmConfig = struct {
    eips: Eips = Eips{ .hardfork = Hardfork.DEFAULT },  // OSAKA
    max_call_depth: u11 = 1024,
    enable_fusion: bool = true,
    enable_native_jit: bool = false,
    stack_size: u12 = 1024,
    WordType: type = u256,
    max_bytecode_size: u32 = 24576,
    memory_limit: u64 = 0xFFFFFF,
    arena_capacity_limit: usize = 64 * 1024 * 1024,
    loop_quota: ?u32 = if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) 1_000_000 else null,
    // ...
};
```

These are Zig comptime structs; set the fields to change behavior. build.zig
declares `-D` options with matching names (`-Devm-hardfork`,
`-Devm-enable-fusion`, `-Dstack-size`, ...), but only `-Denable-tracing` takes
effect. Mini's `EvmConfig.fromBuildOptions()` would read the others, and
nothing calls it.

## Key Architectural Differences Summary

| Aspect | Mini | Performance |
|--------|------|-------------|
| Execution | PC-based loop | Dispatch tail-calls |
| Stack | `ArrayList` with checks | Cache-aligned array, unsafe ops |
| Memory | `ArrayList(u8)` per frame | `ArrayList(u8)` pooled per call depth |
| State | Direct maps | Journal + Database |
| Handlers | Return after execution | Tail-call to next |
| Fusion | None | 39 synthetic opcodes |
| Validation | Per-operation | Preprocessing |
| Gas checking | Per-operation | Per-basic-block |
| `.zig` files | 46 (`mini/src/`) | 187 (`src/`) |
| `evm.zig` size | 97 KB | 340 KB |
