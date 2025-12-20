# Guillotine Documentation

Guillotine is a high-performance Ethereum Virtual Machine (EVM) implementation in Zig, featuring two distinct execution engines optimized for different use cases.

## Quick Navigation

| Section | Description |
|---------|-------------|
| [Mini EVM](./mini/) | Traditional interpreter - clarity-focused, spec-compliant |
| [Performance EVM](./performance/) | Dispatch-based execution - speed-optimized with opcode fusion |
| [Developer Docs](./dev/) | Deep dive architecture documentation with code excerpts |

## Two EVM Implementations

### Mini EVM (`mini/`)
A minimal, correct implementation using traditional sequential bytecode interpretation:
- **Execution**: PC-based, reads bytecode per instruction
- **Use Cases**: Testing, validation, learning EVM internals
- **Trade-off**: Clarity over raw performance

```zig
// mini/src/frame.zig - Traditional execution loop
pub fn execute(self: *Self) EvmError!void {
    while (!self.stopped and !self.reverted and self.pc < self.bytecode.len()) {
        try self.step();
    }
}
```

### Performance EVM (`src/`)
An optimized implementation using dispatch-based execution with preprocessing:
- **Execution**: Cursor-based, preprocessed dispatch schedule
- **Use Cases**: Production, high-throughput scenarios
- **Trade-off**: Performance over simplicity

```zig
// src/frame/frame.zig - Dispatch-based execution via tail calls
pub const OpcodeHandler = *const fn (frame: *Self, cursor: [*]const Dispatch.Item) Error!noreturn;

// Each handler tail-calls the next - no loop, no switch
return @call(.always_tail, next_handler, .{self, next_cursor});
```

## Hardfork Support

Both implementations support Frontier through Prague:

| Hardfork | Key EIPs | Status |
|----------|----------|--------|
| Frontier | Base EVM | Complete |
| Berlin | EIP-2929 (warm/cold access) | Complete |
| London | EIP-3529 (reduced refunds), EIP-1559 | Complete |
| Shanghai | EIP-3855 (PUSH0), EIP-3651 (warm coinbase) | Complete |
| Cancun | EIP-1153 (transient storage), EIP-4844 (blobs), EIP-5656 (MCOPY) | Complete |
| Prague | EIP-7702 (set code), EIP-2537 (BLS12-381) | Complete |

## Getting Started

```bash
# Build
zig build

# Run all tests
zig build test

# Run spec tests
zig build specs

# Build with specific hardfork
zig build -Devm-hardfork=CANCUN
```

## Documentation Structure

```
docs/
├── README.md              # This file
├── mini/                  # Mini EVM documentation
│   ├── README.md          # Mini overview
│   ├── typescript/        # TypeScript port documentation
│   └── bytecode-port-report.md
├── performance/           # Performance EVM documentation
│   ├── README.md          # Performance overview
│   ├── DISPATCH.md        # Dispatch execution model
│   ├── SYNTHETIC-OPCODES.md # Opcode fusion
│   └── TRACER.md          # Tracer synchronization
└── dev/                   # Developer deep dive
    ├── README.md          # Dev docs index
    ├── ARCHITECTURE.md    # Unified architecture
    ├── EXECUTION-MODELS.md # Model comparison
    ├── STATE-MANAGEMENT.md # Storage & journal
    ├── GAS-METERING.md    # Gas calculation
    ├── TESTING.md         # Test organization
    ├── HARDFORKS.md       # EIP support matrix
    └── CONTRIBUTING.md    # Dev workflow
```

## Key Architectural Differences

| Aspect | Mini | Performance |
|--------|------|-------------|
| Execution model | Sequential PC-based | Dispatch schedule with tail calls |
| Bytecode handling | Per-instruction reads | Single preprocessing pass |
| Stack operations | Bounds-checked every op | Unsafe ops after validation |
| Gas checking | Per-operation | Per-basic-block batching |
| Synthetic opcodes | None | 30+ fused patterns |
| Code complexity | ~46 source files | ~158 source files |

## Links

- [CLAUDE.md](../CLAUDE.md) - Project instructions and conventions
- [mini/CLAUDE.md](../mini/CLAUDE.md) - Mini EVM specific instructions
- [GitHub Repository](https://github.com/evmts/guillotine)
