# Mini EVM

A minimal, correct, and well-tested Ethereum Virtual Machine implementation in Zig, prioritizing specification compliance, clarity, and hardfork support (Frontier through Prague).

## Overview

Mini EVM uses a traditional sequential bytecode interpretation model. It's designed to be:

- **Specification Compliant**: Matches `execution-specs` Python reference exactly
- **Clear**: Simple, readable code with explicit logic flow
- **Well-Tested**: Comprehensive spec test coverage
- **Educational**: Good for learning EVM internals

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         EVM (Orchestrator)                   │
│  - State management (balances, nonces, code, storage)       │
│  - Gas refunds (SSTORE refunds, capped at 1/2 or 1/5)      │
│  - Warm/cold tracking (EIP-2929, Berlin+)                   │
│  - Transient storage (EIP-1153, Cancun+)                    │
│  - Nested call management (CALL, CREATE, etc.)              │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      Frame (Bytecode Interpreter)            │
│  - Stack operations (LIFO, max 1024 items)                  │
│  - Memory management (sparse, word-aligned expansion)        │
│  - Program counter (PC) and gas tracking                     │
│  - Opcode dispatch and execution                            │
└─────────────────────────────────────────────────────────────┘
```

## Execution Model

Mini EVM uses traditional sequential interpretation:

```zig
// mini/src/frame.zig:540
pub fn execute(self: *Self) EvmError!void {
    while (!self.stopped and !self.reverted and self.pc < self.bytecode.len()) {
        try self.step();
    }
}

// Each step reads opcode at PC, dispatches to handler, increments PC
pub fn step(self: *Self) EvmError!void {
    const opcode = self.bytecode.getOpcode(self.pc) orelse return error.InvalidOpcode;
    try self.dispatchOpcode(opcode);
}
```

### Key Data Structures

```zig
// mini/src/frame.zig:50-70
stack: std.ArrayList(u256),           // Bounds-checked stack
memory: std.AutoHashMap(u32, u8),     // Sparse memory map
memory_size: u32,                      // Current memory size
pc: u32,                               // Program counter
gas_remaining: i64,                    // Gas tracking (signed for refunds)
bytecode: Bytecode,                    // Analyzed bytecode with JUMPDEST table
```

### Storage Model

```zig
// mini/src/storage.zig:19-33
pub const Storage = struct {
    /// Persistent storage (current transaction state)
    storage: std.AutoHashMap(StorageSlotKey, u256),
    /// Original storage values (snapshot at transaction start)
    original_storage: std.AutoHashMap(StorageSlotKey, u256),
    /// Transient storage (EIP-1153, cleared at transaction boundaries)
    transient: std.AutoHashMap(StorageSlotKey, u256),
};
```

## Source Structure

```
mini/src/
├── evm.zig (94KB)              # EVM orchestrator - state, calls, storage
├── frame.zig (25KB)            # Bytecode interpreter - stack, memory, PC
├── storage.zig (16KB)          # Storage management (persistent + transient)
├── bytecode.zig (6KB)          # JUMPDEST analysis
├── host.zig (2KB)              # Host interface
├── evm_config.zig (9KB)        # Configuration
├── errors.zig                  # Error types
└── instructions/
    ├── handlers_arithmetic.zig  # ADD, SUB, MUL, DIV, etc.
    ├── handlers_bitwise.zig     # AND, OR, XOR, NOT, SHL, SHR
    ├── handlers_comparison.zig  # LT, GT, EQ, ISZERO
    ├── handlers_stack.zig       # PUSH, POP, DUP, SWAP
    ├── handlers_memory.zig      # MLOAD, MSTORE, MSIZE, MCOPY
    ├── handlers_storage.zig     # SLOAD, SSTORE, TLOAD, TSTORE
    ├── handlers_control_flow.zig # JUMP, JUMPI, JUMPDEST
    ├── handlers_system.zig      # CALL, CREATE, RETURN, REVERT
    ├── handlers_context.zig     # ADDRESS, CALLER, BALANCE, etc.
    ├── handlers_block.zig       # BLOCKHASH, TIMESTAMP, etc.
    ├── handlers_keccak.zig      # KECCAK256
    └── handlers_log.zig         # LOG0-LOG4
```

## Handler Pattern

Each opcode handler follows a simple pattern:

```zig
// mini/src/instructions/handlers_arithmetic.zig
pub fn Handlers(FrameType: type) type {
    return struct {
        pub fn add(frame: *FrameType) FrameType.EvmError!void {
            // 1. Consume gas
            try frame.consumeGas(GasConstants.GasFastestStep);

            // 2. Pop operands (bounds-checked)
            const a = try frame.popStack();
            const b = try frame.popStack();

            // 3. Execute operation
            const result = a +% b;  // Wrapping arithmetic

            // 4. Push result (bounds-checked)
            try frame.pushStack(result);

            // 5. Advance PC
            frame.pc += 1;
        }
    };
}
```

## Quick Start

```bash
# Build mini EVM
cd mini && zig build

# Run tests
zig build test

# Run spec tests
zig build specs

# Run with specific hardfork
zig build specs -Dhardfork=CANCUN
```

## TypeScript Port

A TypeScript implementation is available for environments where Zig/WASM isn't suitable:

- [TypeScript README](./typescript/README.md)
- [TypeScript Architecture](./typescript/ARCHITECTURE.md)
- [Migration Guide](./typescript/MIGRATION.md)

## Testing

```bash
# Run all tests
zig build test

# Filter by test name
zig build specs -Dtest-filter='transientStorage'

# Run specific hardfork tests
zig build specs-cancun-tstore-basic
zig build specs-shanghai-push0

# Isolate a failing test (with debug output)
bun scripts/isolate-test.ts "exact_test_name"
```

## Comparison with Performance EVM

| Aspect | Mini | Performance |
|--------|------|-------------|
| Execution | PC-based loop | Dispatch tail-calls |
| Bytecode | Per-instruction reads | Preprocessed schedule |
| Stack | `ArrayList(u256)` | Cache-aligned array |
| Memory | `AutoHashMap(u32, u8)` | Word-aligned pages |
| Gas | Per-operation checks | Per-block batching |
| Synthetic | None | 30+ fused patterns |
| Complexity | Simple, clear | Optimized, complex |

## Further Reading

- [Developer Architecture](../dev/ARCHITECTURE.md) - Deep dive with code excerpts
- [Execution Models](../dev/EXECUTION-MODELS.md) - Detailed comparison
- [Testing Guide](../dev/TESTING.md) - Test organization and debugging
