# Execution Models Comparison

This document provides a detailed side-by-side comparison of the Mini and Performance EVM execution models.

## Overview

| Aspect | Mini EVM | Performance EVM |
|--------|----------|-----------------|
| Model | Sequential PC-based | Dispatch schedule with tail calls |
| Philosophy | Clarity & correctness | Speed via preprocessing |
| Location | `mini/src/` | `src/` |
| Core files | `evm.zig`, `frame.zig` | `evm.zig`, `frame/frame.zig`, `preprocessor/` |

## Execution Loop

### Mini: Traditional While Loop

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

    // Validate first block gas
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

## Stack Operations

### Mini: Bounds-Checked ArrayList

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

// Optimized binary operation
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

```zig
// mini/src/frame.zig
pub fn consumeGas(self: *Self, amount: u64) EvmError!void {
    if (self.gas_remaining < @intCast(amount)) {
        return error.OutOfGas;
    }
    self.gas_remaining -= @intCast(amount);
}

// Each handler charges gas
pub fn add(frame: *FrameType) EvmError!void {
    try frame.consumeGas(3);  // Every ADD costs 3
    // ...
}
```

### Performance: Per-Basic-Block

```zig
// Gas calculated once per basic block
// First schedule item contains total block gas
first_block_gas: FirstBlockMetadata {
    .gas: 15,        // Total for block (e.g., PUSH+PUSH+ADD = 3+3+3+3+3)
    .min_stack: 0,   // Stack items needed
    .max_stack: 2,   // Stack items produced
}

// Charged at block entry, not per instruction
if (self.gas_remaining < first_block.gas) {
    return Error.OutOfGas;
}
self.gas_remaining -= first_block.gas;
```

## Memory Access

### Mini: Sparse HashMap

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

## Jump Handling

### Mini: Binary Search

```zig
// mini/src/frame.zig
pub fn jump(frame: *FrameType) EvmError!void {
    const target = try frame.popStack();
    const target_pc: u32 = @intCast(target);

    // Validate jump destination
    if (!frame.bytecode.isValidJumpDest(target_pc)) {
        return error.InvalidJump;
    }

    frame.pc = target_pc;
}
```

### Performance: Pre-Resolved Table

```zig
// src/preprocessor/dispatch_jump_table.zig
pub const JumpTable = struct {
    entries: []const JumpTableEntry,  // Sorted by PC

    pub fn lookup(self: *JumpTable, target_pc: u32) ?usize {
        // Binary search for schedule index
        var left: usize = 0;
        var right = self.entries.len;
        while (left < right) {
            const mid = (left + right) / 2;
            if (self.entries[mid].pc == target_pc) {
                return self.entries[mid].schedule_index;
            }
            if (self.entries[mid].pc < target_pc) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        return null;
    }
};

// Static jumps resolved at compile time - no search needed
JUMP_TO_STATIC_LOCATION: jump_static { .target_cursor: [*]const Item }
```

## Synthetic Opcodes

### Mini: None

Every bytecode opcode maps to one handler.

### Performance: 30+ Fusion Patterns

```zig
// src/opcodes/opcode_synthetic.zig
pub const OpcodeSynthetic = enum(u8) {
    PUSH_ADD_INLINE = 0xA5,     // PUSH + ADD
    PUSH_MSTORE_INLINE = 0xB3,  // PUSH + MSTORE
    FUNCTION_DISPATCH = 0xC8,   // PUSH4 + EQ + PUSH + JUMPI
    // ... 30+ patterns
};

// Example fusion: PUSH_ADD_INLINE
pub fn push_add_inline(self: *FrameType, cursor: [*]const Item) Error!noreturn {
    const push_value = cursor[1].push_inline.value;
    const top = self.stack.peek_unsafe();
    self.stack.set_top_unsafe(top +% @as(WordType, push_value));
    return @call(.always_tail, cursor[2].opcode_handler, .{self, cursor + 2});
}
```

## Branch Prediction

### Mini: Poor

```
switch (opcode) {      // 256-way branch
    0x00 => stop(),    // CPU can't predict which case
    0x01 => add(),
    // ...
}
```

- ~50% branch misprediction rate
- Each misprediction: ~15-20 cycle penalty

### Performance: Perfect

```
cursor[0].opcode_handler(frame, cursor);  // Always the same pattern
return @call(.always_tail, next, ...);    // Linear execution
```

- 0% branch misprediction
- Predictable linear execution

## Performance Comparison

| Metric | Mini | Performance | Ratio |
|--------|------|-------------|-------|
| Simple arithmetic | 1.0x | 2-3x faster | 2-3x |
| Storage operations | 1.0x | 3-5x faster | 3-5x |
| Contract calls | 1.0x | 5-10x faster | 5-10x |
| Memory usage | Higher | Lower | ~0.7x |

## When to Use Each

### Use Mini When:
- Learning EVM internals
- Debugging execution issues
- Need clear, auditable code
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
