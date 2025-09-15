# Dispatch System Architecture

## Overview
Guillotine's performance advantage: **preprocess bytecode into dispatch schedule** - linear array of function pointers and inline metadata executing via tail calls.

## Traditional vs Dispatch Execution

**Traditional Interpreter (MinimalEvm)**:
```zig
while (self.pc < self.bytecode.len) {
    const opcode = self.bytecode[self.pc];
    switch (opcode) { // Giant switch, poor branch prediction
        0x01 => { const a = self.popStack(); const b = self.popStack(); self.pushStack(a + b); }
        // 256+ cases, runtime validation, per-instruction gas
    }
}
```

**Dispatch-Based (Frame)**:
```zig
// Direct function call - no switch!
return cursor[0].opcode_handler(frame, cursor);

// Tail calls between handlers
pub fn add(self: *Frame, cursor: [*]const Dispatch.Item) !noreturn {
    const a = self.stack.pop_unsafe();  // Pre-validated
    const b = self.stack.peek_unsafe();
    self.stack.set_top_unsafe(a +% b);
    return @call(.always_tail, next[0].opcode_handler, .{self, next});
}
```

## Dispatch Schedule Structure
```zig
pub const Item = union(enum) {
    opcode_handler: *const fn(*Frame, [*]const Item) Error!noreturn,
    jump_dest: JumpDestMetadata,      // Gas cost, stack requirements
    push_inline: PushInlineMetadata,  // Values ≤8 bytes
    push_pointer: PushPointerMetadata,// Values >8 bytes
    pc: PcMetadata,
    jump_static: JumpStaticMetadata,  // Pre-resolved jumps
    first_block_gas: FirstBlockMetadata, // Gas per basic block
};
```

## Key Optimizations

**Jump Handling**: Pre-validated jump table, binary search, direct tail calls
**Opcode Fusion**: Common patterns (PUSH+ADD, PUSH+MSTORE) → single synthetic opcodes
**Gas Batching**: Per-basic-block instead of per-instruction (10-100x fewer checks)
**Data Inlining**: Push values embedded in schedule, no bytecode reads

## Performance Benefits
- **Branch Prediction**: Perfect (linear tail calls) vs unpredictable (256+ switch cases)
- **Cache Efficiency**: Sequential schedule access vs random bytecode reads
- **Validation**: One-time preprocessing vs runtime per operation
- **Memory Access**: Inline metadata vs bytecode reads

## Building Schedule
1. **Analyze**: Calculate basic block gas, identify JUMPDESTs, detect fusion patterns
2. **Generate**: Convert opcodes to handlers, inline small values, add metadata
3. **Resolve**: Build sorted jump table, resolve static jumps

## Key Points
1. **Dispatch ≠ interpretation** - compiled execution via function pointers
2. **Preprocessing cost** - one-time analysis for repeated execution benefit
3. **Tail calls critical** - linear execution without call stack growth
4. **Metadata inlining** - no bytecode reads during execution
5. **Pre-validation** - safety checks once, not every execution

**Frame cursor ≠ PC**: Cursor indexes dispatch schedule, not bytecode position. Schedule may contain metadata items, synthetic opcodes represent multiple bytecode operations.