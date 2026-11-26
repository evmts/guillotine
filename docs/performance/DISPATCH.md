# Dispatch System

The dispatch system is the core of Guillotine's performance advantage. It transforms bytecode into an optimized execution schedule that eliminates the traditional interpreter loop.

## Traditional vs Dispatch Execution

### Traditional Interpreter (MinimalEvm)

```zig
// Traditional: Big switch statement, poor branch prediction
while (self.pc < self.bytecode.len) {
    const opcode = self.bytecode[self.pc];
    switch (opcode) {
        0x01 => { // ADD
            const a = self.popStack();
            const b = self.popStack();
            self.pushStack(a + b);
            self.pc += 1;
        },
        0x02 => { /* MUL */ },
        // ... 256 cases
    }
}
```

**Problems:**
- 256-way switch = unpredictable branches
- Bytecode read every instruction
- Runtime validation per operation
- Per-instruction gas checks

### Dispatch-Based (Frame)

```zig
// src/frame/frame.zig - Direct function pointer calls
pub const OpcodeHandler = *const fn (frame: *Self, cursor: [*]const Item) Error!noreturn;

// No loop! Each handler tail-calls the next
pub fn add(self: *Frame, cursor: [*]const Dispatch.Item) Error!noreturn {
    // Pre-validated, use unsafe operations
    self.stack.binary_op_unsafe(addOp);

    // Tail-call to next handler (no return, no stack growth)
    return @call(.always_tail, cursor[1].opcode_handler, .{self, cursor + 2});
}
```

**Advantages:**
- Linear tail-call chain = perfect branch prediction
- No bytecode reads (data in schedule)
- Validation once at preprocessing
- Gas batched per basic block

## Schedule Structure

The dispatch schedule is an array of `Item` unions:

```zig
// src/preprocessor/dispatch.zig:32-40
pub const Item = union(enum) {
    /// Function pointer to opcode handler
    opcode_handler: OpcodeHandler,

    /// JUMPDEST metadata (gas cost for next block, stack requirements)
    jump_dest: JumpDestMetadata,

    /// Push value ≤8 bytes (embedded directly)
    push_inline: PushInlineMetadata,

    /// Push value >8 bytes (pointer to heap allocation)
    push_pointer: PushPointerMetadata,

    /// PC opcode - stores bytecode position
    pc: PcMetadata,

    /// Pre-resolved jump destination (schedule index)
    jump_static: JumpStaticMetadata,

    /// First block metadata (gas, stack requirements)
    first_block_gas: FirstBlockMetadata,
};
```

### Example Schedule

For bytecode: `PUSH1 0x01, PUSH1 0x02, ADD, STOP`

```
Bytecode:  [0x60, 0x01, 0x60, 0x02, 0x01, 0x00]
PC:           0     1     2     3     4     5

Dispatch Schedule:
Index  Item Type           Value
─────  ──────────────────  ─────────────────────────────
[0]    first_block_gas     { gas: 9, min_stack: 0, max_stack: 2 }
[1]    opcode_handler      → PUSH1 handler function pointer
[2]    push_inline         { value: 1 }
[3]    opcode_handler      → PUSH1 handler function pointer
[4]    push_inline         { value: 2 }
[5]    opcode_handler      → ADD handler function pointer
[6]    opcode_handler      → STOP handler function pointer
```

## Cursor vs Program Counter

**Critical Distinction**: The cursor indexes the dispatch schedule, NOT the bytecode!

```
Bytecode Position (PC):     0  1  2  3  4  5
Dispatch Cursor:            0  1  2  3  4  5  6

Schedule[0] = metadata (not an instruction!)
Schedule[1] = first instruction handler
```

### Why This Matters

1. **Synthetic opcodes** in schedule represent multiple bytecode operations
2. **Metadata items** don't correspond to any bytecode
3. **Jump targets** are schedule indices, not PCs
4. **Tracer** must map between cursor and PC for validation

## Handler Pattern

Every opcode handler follows this pattern:

```zig
// src/instructions/handlers_arithmetic.zig
pub fn add(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
    // 1. Optional: Tracer sync (debug/safe builds only)
    self.beforeInstruction(.ADD, cursor);

    // 2. Execute operation (pre-validated, use unsafe)
    self.stack.binary_op_unsafe(struct {
        fn op(top: WordType, second: WordType) WordType {
            return top +% second;
        }
    }.op);

    // 3. Get next handler info
    const next = dispatch.getOpData(.ADD);

    // 4. Tail-call to next handler (NEVER returns)
    return @call(Self.getTailCallModifier(), next.handler, .{self, next.cursor});
}
```

### Tail-Call Modifier

```zig
// src/preprocessor/dispatch.zig:20-26
pub inline fn getTailCallModifier() std.builtin.CallModifier {
    const builtin = @import("builtin");
    // WASM doesn't support tail calls by default
    return if (comptime builtin.target.cpu.arch == .wasm32 or
                        builtin.target.cpu.arch == .wasm64)
        .auto
    else
        .always_tail;
}
```

## Building the Schedule

### 1. Bytecode Analysis

```zig
// src/bytecode/bytecode_analyze.zig
// Single-pass analysis:
// - Validate opcodes
// - Identify JUMPDESTs
// - Detect fusion patterns
// - Calculate basic block gas
```

### 2. Schedule Generation

```zig
// src/preprocessor/dispatch.zig:42-62
fn processPushOpcode(
    schedule_items: anytype,
    allocator: std.mem.Allocator,
    opcode_handlers: *const [256]OpcodeHandler,
    data: anytype,
) !void {
    const push_opcode = 0x60 + data.size - 1;

    // Add handler
    try schedule_items.append(allocator, .{
        .opcode_handler = opcode_handlers.*[push_opcode]
    });

    // Add value (inline for small, pointer for large)
    if (data.size <= 8 and data.value <= std.math.maxInt(u64)) {
        try schedule_items.append(allocator, .{
            .push_inline = .{ .value = @intCast(data.value) }
        });
    } else {
        const value_ptr = try allocator.create(FrameType.WordType);
        value_ptr.* = data.value;
        try schedule_items.append(allocator, .{
            .push_pointer = .{ .value_ptr = value_ptr }
        });
    }
}
```

### 3. Jump Table Construction

```zig
// src/preprocessor/dispatch_jump_table.zig
// Sorted array of (bytecode_pc, schedule_index) pairs
// Binary search for dynamic jumps
// Static jumps resolved to direct schedule indices
```

## Metadata Types

### FirstBlockMetadata

```zig
pub const FirstBlockMetadata = struct {
    /// Total gas cost for this basic block
    gas: u64,
    /// Minimum stack items required at block entry
    min_stack: u8,
    /// Maximum stack size after block execution
    max_stack: u8,
};
```

### JumpDestMetadata

```zig
pub const JumpDestMetadata = struct {
    /// Gas cost for the block starting at this JUMPDEST
    gas: u64,
    /// Stack requirements
    min_stack: u8,
    max_stack: u8,
};
```

### PushInlineMetadata

```zig
pub const PushInlineMetadata = struct {
    /// Value fits in u64 (PUSH1-PUSH8)
    value: u64,
};
```

### PushPointerMetadata

```zig
pub const PushPointerMetadata = struct {
    /// Pointer to heap-allocated u256 (PUSH9-PUSH32)
    value_ptr: *const WordType,
};
```

## Performance Benefits

| Aspect | Traditional | Dispatch |
|--------|-------------|----------|
| Branch prediction | ~50% miss rate | ~0% miss rate |
| Bytecode reads | Per instruction | None |
| Gas checks | Per instruction | Per basic block |
| Validation | Runtime | Preprocessing |
| Memory pattern | Random | Sequential |

## Debugging

### Dispatch Validation

In Debug and ReleaseSafe builds, handlers validate the schedule:

```zig
// src/preprocessor/dispatch.zig:83-106
pub inline fn validateOpcodeHandler(
    self: Self,
    comptime opcode: UnifiedOpcode,
    frame: *FrameType,
) void {
    // Verify handler pointer matches expected
    const expected_handler = ...;
    tracerAssert(frame, self.cursor[0].opcode_handler == expected_handler,
                 "Opcode handler mismatch");

    // Verify metadata type matches opcode
    switch (opcode) {
        .PUSH1, .PUSH2, ... => tracerAssert(frame,
            self.cursor[1] == .push_inline,
            "PUSH opcode: expected .push_inline metadata"),
        // ...
    }
}
```

### Pretty Printing

```zig
// src/preprocessor/dispatch_pretty_print.zig
// Format schedule for debugging output
```

## Related Documentation

- [Synthetic Opcodes](./SYNTHETIC-OPCODES.md) - Fusion patterns
- [Tracer System](./TRACER.md) - Dispatch ↔ PC synchronization
- [Architecture](../dev/ARCHITECTURE.md) - Full system overview
