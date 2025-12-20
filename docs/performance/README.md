# Performance EVM

A high-performance Ethereum Virtual Machine implementation using dispatch-based execution with bytecode preprocessing, opcode fusion, and tail-call optimization.

## Overview

The Performance EVM transforms bytecode into an optimized dispatch schedule before execution, enabling:

- **Zero Branch Misprediction**: Linear tail-call execution instead of 256-way switch
- **Cache Efficiency**: Sequential schedule access instead of random bytecode reads
- **Opcode Fusion**: Common patterns combined into single operations
- **Gas Batching**: Per-basic-block gas checks instead of per-instruction

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Bytecode Analysis                         │
│  - Single-pass bytecode validation                          │
│  - JUMPDEST identification                                  │
│  - Fusion pattern detection                                 │
│  - Basic block gas calculation                              │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Dispatch Schedule                         │
│  - Array of function pointers + metadata                    │
│  - Inline push values (no bytecode reads)                   │
│  - Pre-resolved jump destinations                           │
│  - Synthetic handlers for fused operations                  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Tail-Call Execution                       │
│  - Each handler calls next directly                         │
│  - No loop, no switch statement                             │
│  - Linear stack frame reuse                                 │
│  - Pre-validated unsafe operations                          │
└─────────────────────────────────────────────────────────────┘
```

## Execution Model

Unlike traditional interpreters, the Performance EVM uses dispatch-based execution:

```zig
// src/frame/frame.zig:62
pub const OpcodeHandler = *const fn (frame: *Self, cursor: [*]const Dispatch.Item) Error!noreturn;

// Handler pattern: tail-call to next instruction
pub fn add(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
    // Pre-validated: use unsafe operations
    self.stack.binary_op_unsafe(struct {
        fn op(top: WordType, second: WordType) WordType {
            return top +% second;
        }
    }.op);

    // Tail-call next handler (no return)
    return @call(.always_tail, next_handler, .{self, next_cursor});
}
```

### Dispatch Schedule Structure

```zig
// src/preprocessor/dispatch.zig:32-40
pub const Item = union(enum) {
    opcode_handler: OpcodeHandler,          // Function pointer
    jump_dest: JumpDestMetadata,            // Gas cost, stack requirements
    push_inline: PushInlineMetadata,        // Values ≤8 bytes (embedded)
    push_pointer: PushPointerMetadata,      // Values >8 bytes (heap pointer)
    pc: PcMetadata,                         // PC opcode metadata
    jump_static: JumpStaticMetadata,        // Pre-resolved jump destination
    first_block_gas: FirstBlockMetadata,    // Basic block gas requirement
};
```

### Key Difference: Cursor vs PC

**Critical**: The dispatch cursor is NOT the program counter!

```
Bytecode:  [PUSH1, 0x01, PUSH1, 0x02, ADD, JUMP]
PC:           0     1     2     3    4     5

Dispatch Schedule:
[0] first_block_gas { gas: 15 }     ← Metadata, not an instruction
[1] PUSH1_handler                   ← Cursor starts here
[2] push_inline { value: 1 }        ← Metadata for PUSH1
[3] PUSH1_handler
[4] push_inline { value: 2 }
[5] ADD_handler
[6] JUMP_handler
```

## Source Structure

```
src/
├── evm.zig (270KB)                 # EVM orchestrator
├── frame/
│   ├── frame.zig                   # Dispatch-based executor
│   ├── frame_config.zig            # Configuration
│   └── frame_handlers.zig          # Handler registration
├── preprocessor/
│   ├── dispatch.zig                # Schedule builder
│   ├── dispatch_metadata.zig       # Metadata types
│   └── dispatch_jump_table.zig     # Jump resolution
├── bytecode/
│   ├── bytecode.zig (115KB)        # Complete analysis
│   ├── bytecode_analyze.zig        # Pattern detection
│   └── bytecode_stats.zig          # Optimization stats
├── instructions/
│   ├── handlers_*.zig              # Standard handlers
│   └── handlers_*_synthetic.zig    # Fusion handlers
├── storage/
│   ├── database.zig (88KB)         # World state
│   ├── journal.zig (34KB)          # Snapshot system
│   └── access_list.zig             # EIP-2929 tracking
└── tracer/
    ├── tracer.zig                  # Execution monitoring
    └── minimal_evm.zig             # Reference implementation
```

## Key Optimizations

### 1. Opcode Fusion

Common patterns detected and combined:

```zig
// src/opcodes/opcode_synthetic.zig:17-60
pub const OpcodeSynthetic = enum(u8) {
    PUSH_ADD_INLINE = 0xA5,           // PUSH + ADD
    PUSH_MUL_INLINE = 0xA7,           // PUSH + MUL
    PUSH_MSTORE_INLINE = 0xB3,        // PUSH + MSTORE
    FUNCTION_DISPATCH = 0xC8,         // PUSH4 + EQ + PUSH + JUMPI
    CALLVALUE_CHECK = 0xC9,           // CALLVALUE + DUP1 + ISZERO
    // ... 30+ fusion patterns
};
```

### 2. Tail-Call Execution

```zig
// Every handler ends with tail-call, no loop needed
pub inline fn getTailCallModifier() std.builtin.CallModifier {
    return if (comptime is_wasm) .auto else .always_tail;
}

return @call(Self.getTailCallModifier(), next_handler, .{self, cursor});
```

### 3. Inline Metadata

Push values embedded directly in schedule:

```zig
// Small values (≤8 bytes) inline
push_inline: PushInlineMetadata { .value: u64 }

// Large values (>8 bytes) heap-allocated
push_pointer: PushPointerMetadata { .value_ptr: *u256 }
```

### 4. Gas Batching

Gas calculated per basic block, not per instruction:

```zig
// First schedule item contains block gas
first_block_gas: FirstBlockMetadata {
    .gas: u64,          // Total gas for basic block
    .min_stack: u8,     // Minimum stack items required
    .max_stack: u8,     // Maximum stack growth
}
```

## Quick Start

```bash
# Build
zig build

# Run tests
zig build test

# Build with optimizations
zig build --release=fast

# Run benchmarks
zig build bench
```

## Detailed Documentation

- [Dispatch System](./DISPATCH.md) - Deep dive into dispatch execution
- [Synthetic Opcodes](./SYNTHETIC-OPCODES.md) - Opcode fusion patterns
- [Tracer System](./TRACER.md) - Synchronization with reference implementation

## Comparison with Mini EVM

| Aspect | Mini | Performance |
|--------|------|-------------|
| Model | Sequential PC | Dispatch schedule |
| Switch | 256-way per step | None (tail-calls) |
| Bytecode reads | Per instruction | None (preprocessed) |
| Stack ops | Bounds-checked | Pre-validated unsafe |
| Gas checks | Per instruction | Per basic block |
| Complexity | ~46 files | ~158 files |
| Speed | Baseline | 2-10x faster |

## Further Reading

- [Developer Architecture](../dev/ARCHITECTURE.md)
- [Execution Models](../dev/EXECUTION-MODELS.md)
- [State Management](../dev/STATE-MANAGEMENT.md)
