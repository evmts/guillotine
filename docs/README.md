# Guillotine Documentation

Guillotine is a high-performance Ethereum Virtual Machine (EVM) implementation in Zig. The repository contains two execution engines: the dispatch-based performance EVM in `src/`, and MinimalEvm, a sequential reference interpreter in `src/tracer/` that differential tests compare against.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              GUILLOTINE EVM                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Input: Bytecode + State + Gas                                             │
│   │                                                                         │
│   ▼                                                                         │
│   ┌───────────────────────────────────────────────────────────────────┐    │
│   │                                                                   │    │
│   │      MINIMALEVM                  PERFORMANCE EVM                  │    │
│   │      ──────────                  ───────────────                  │    │
│   │                                                                   │    │
│   │      Sequential         OR       Dispatch-based                   │    │
│   │      Interpreter                 Tail-call Chain                  │    │
│   │                                                                   │    │
│   │      Clarity-first              Speed-first                       │    │
│   │      Reference oracle           Production engine                 │    │
│   │                                                                   │    │
│   └───────────────────────────────────────────────────────────────────┘    │
│   │                                                                         │
│   ▼                                                                         │
│   Output: Result + Updated State + Gas Used + Logs                          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# Clone and build
git clone https://github.com/evmts/guillotine
cd guillotine
zig build

# Run all tests (no output = all passed)
zig build test

# Run Ethereum spec tests
zig build specs

# Build with specific hardfork
zig build -Devm-hardfork=CANCUN
```

## Documentation Quick Navigation

| I want to... | Go to |
|--------------|-------|
| Understand the architecture | [dev/ARCHITECTURE.md](./dev/ARCHITECTURE.md) |
| Compare MinimalEvm vs Performance | [dev/EXECUTION-MODELS.md](./dev/EXECUTION-MODELS.md) |
| Learn about storage/state | [dev/STATE-MANAGEMENT.md](./dev/STATE-MANAGEMENT.md) |
| Understand gas calculation | [dev/GAS-METERING.md](./dev/GAS-METERING.md) |
| Run or write tests | [dev/TESTING.md](./dev/TESTING.md) |
| Check hardfork/opcode support | [dev/HARDFORKS.md](./dev/HARDFORKS.md) |
| Build a custom language SDK | [building-custom-sdks.md](./building-custom-sdks.md) |
| Contribute code | [dev/CONTRIBUTING.md](./dev/CONTRIBUTING.md) |
| Deep dive into dispatch | [performance/DISPATCH.md](./performance/DISPATCH.md) |
| Understand opcode fusion | [performance/SYNTHETIC-OPCODES.md](./performance/SYNTHETIC-OPCODES.md) |
| Read the standalone reference EVM | [evmts/guillotine-mini](https://github.com/evmts/guillotine-mini) (separate repository) |

## Two EVM Implementations

### MinimalEvm (`src/tracer/minimal_evm.zig`)

A minimal, correct implementation using traditional sequential bytecode interpretation. The tracer and the differential tests in `test/differential` run it beside the performance EVM and compare results. The standalone, readable reference EVM lives in its own repository, [evmts/guillotine-mini](https://github.com/evmts/guillotine-mini).

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          MINIMALEVM EXECUTION                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   while (!stopped && pc < bytecode.len) {                                   │
│       opcode = bytecode[pc]                                                 │
│       switch (opcode) {                                                     │
│           ADD => { stack.push(stack.pop() + stack.pop()); pc += 1; }       │
│           ...                                                               │
│       }                                                                     │
│   }                                                                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

- **Execution**: PC-based, reads bytecode per instruction
- **Use Cases**: Differential testing, validation, learning EVM internals
- **Trade-off**: Clarity over raw performance
- **Start here**: `src/tracer/minimal_frame.zig` (`MinimalFrame.executeOpcode`)

### Performance EVM (`src/`)

An optimized implementation using dispatch-based execution with preprocessing.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      PERFORMANCE EVM EXECUTION                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   PREPROCESS:  Bytecode → Dispatch Schedule                                 │
│                                                                             │
│   EXECUTE:     handler_1(frame, cursor)                                     │
│                    ↓ tail-call                                              │
│                handler_2(frame, cursor)                                     │
│                    ↓ tail-call                                              │
│                handler_3(frame, cursor)                                     │
│                    ↓ ...                                                    │
│                stop_handler → return                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

- **Execution**: Cursor-based, preprocessed dispatch schedule
- **Use Cases**: Production, high-throughput scenarios
- **Trade-off**: Performance over simplicity
- **Start here**: `src/frame/frame.zig`

## Key Architectural Differences

| Aspect | MinimalEvm | Performance |
|--------|------------|-------------|
| Execution model | Sequential PC-based | Dispatch schedule + tail calls |
| Bytecode handling | Per-instruction reads | Single preprocessing pass |
| Stack operations | Bounds-checked every op | Unsafe ops after validation |
| Gas checking | Per-operation | Per-basic-block batching |
| Synthetic opcodes | None | 30+ fused patterns |
| Branch prediction | ~50% (switch) | ~100% (direct calls) |
| Code size | 3 files (`minimal_evm.zig`, `minimal_frame.zig`, `minimal_host.zig`) | Whole `src/` tree |

## Hardfork Support

Both implementations support Frontier through Prague:

| Hardfork | Key Features | Status |
|----------|--------------|--------|
| Frontier | Base EVM opcodes | Complete |
| Homestead | DELEGATECALL | Complete |
| Byzantium | RETURNDATASIZE, STATICCALL, REVERT | Complete |
| Constantinople | SHL/SHR/SAR, CREATE2, EXTCODEHASH | Complete |
| Istanbul | CHAINID, SELFBALANCE | Complete |
| Berlin | EIP-2929 (warm/cold access) | Complete |
| London | BASEFEE, EIP-3529 (reduced refunds) | Complete |
| Shanghai | PUSH0, EIP-3651 (warm coinbase) | Complete |
| Cancun | TLOAD/TSTORE, MCOPY, BLOBHASH | Complete |
| Prague | EIP-7702 (set code), BLS12-381 | Complete |

## Documentation Structure

```
docs/
├── README.md              ← You are here
│
├── dev/                   ← Developer deep dive documentation
│   ├── README.md          Index with learning path
│   ├── ARCHITECTURE.md    Unified architecture with diagrams
│   ├── EXECUTION-MODELS.md   Side-by-side MinimalEvm vs Performance
│   ├── STATE-MANAGEMENT.md   Storage, journal, warm/cold
│   ├── GAS-METERING.md    Gas calculation with decision trees
│   ├── TESTING.md         Test organization and debugging
│   ├── HARDFORKS.md       Complete opcode reference
│   └── CONTRIBUTING.md    Development workflow
│
└── performance/           ← Performance EVM specifics
    ├── README.md          Performance overview
    ├── DISPATCH.md        Dispatch execution model
    ├── SYNTHETIC-OPCODES.md   Opcode fusion patterns
    └── TRACER.md          Execution synchronization
```

## Build Commands

| Command | Description |
|---------|-------------|
| `zig build` | Build the project |
| `zig build test` | Run all tests |
| `zig build specs` | Run Ethereum spec tests |
| `zig build test-unit` | Run unit tests |
| `zig build test-opcodes` | Run opcode differential tests |

## Project Conventions

- **No output = success**: Zig tests produce no output when passing
- **Use log module**: Never `std.debug.print`, use `log.debug`
- **Use tracer.assert**: Never `std.debug.assert`
- **Never swallow errors**: No `catch {}`
- **Fix tests immediately**: No skipping or commenting out

See [CLAUDE.md](../CLAUDE.md) for complete project instructions.

## Links

- [CLAUDE.md](../CLAUDE.md) - Project instructions and conventions
- [evmts/guillotine-mini](https://github.com/evmts/guillotine-mini) - Standalone reference EVM (separate repository)
- [GitHub Repository](https://github.com/evmts/guillotine)
- [Ethereum Yellow Paper](https://ethereum.github.io/yellowpaper/paper.pdf)
- [EVM.codes](https://www.evm.codes/)
