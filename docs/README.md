# Guillotine Documentation

Guillotine is a high-performance Ethereum Virtual Machine (EVM) implementation in Zig, featuring two distinct execution engines optimized for different use cases.

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
│   │      MINI EVM                    PERFORMANCE EVM                  │    │
│   │      ─────────                   ───────────────                  │    │
│   │                                                                   │    │
│   │      Sequential         OR       Dispatch-based                   │    │
│   │      Interpreter                 Tail-call Chain                  │    │
│   │                                                                   │    │
│   │      Clarity-first              Speed-first                       │    │
│   │      ~25KB core                 ~270KB core                       │    │
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

# Run the legacy filler spec tests
zig build specs

# Run the official EEST state tests (fetch fixtures first)
scripts/fetch-eest-fixtures.sh
zig build state-tests
```

Select the hardfork, fusion, and limits in Zig through `EvmConfig`. The
`-Devm-*` build flags are declared in `build.zig`, but the `src/` engine does not
read them.

## Documentation Quick Navigation

| I want to... | Go to |
|--------------|-------|
| Understand the architecture | [dev/ARCHITECTURE.md](./dev/ARCHITECTURE.md) |
| Compare Mini vs Performance | [dev/EXECUTION-MODELS.md](./dev/EXECUTION-MODELS.md) |
| Learn about storage/state | [dev/STATE-MANAGEMENT.md](./dev/STATE-MANAGEMENT.md) |
| Understand gas calculation | [dev/GAS-METERING.md](./dev/GAS-METERING.md) |
| Run or write tests | [dev/TESTING.md](./dev/TESTING.md) |
| Check hardfork/opcode support | [dev/HARDFORKS.md](./dev/HARDFORKS.md) |
| Build a custom language SDK | [building-custom-sdks.md](./building-custom-sdks.md) |
| Contribute code | [dev/CONTRIBUTING.md](./dev/CONTRIBUTING.md) |
| Deep dive into dispatch | [performance/DISPATCH.md](./performance/DISPATCH.md) |
| Understand opcode fusion | [performance/SYNTHETIC-OPCODES.md](./performance/SYNTHETIC-OPCODES.md) |

## Two EVM Implementations

### Reference Interpreter (`src/tracer/minimal_evm.zig` & `evmts/guillotine-mini`)

A minimal, correct implementation using traditional sequential bytecode interpretation (the standalone version lives in [evmts/guillotine-mini](https://github.com/evmts/guillotine-mini); Guillotine embeds `MinimalEvm` under `src/tracer/` for differential validation).

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          MINI EVM EXECUTION                                 │
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
- **Use Cases**: Testing, validation, learning EVM internals
- **Trade-off**: Clarity over raw performance
- **Start here**: `src/tracer/minimal_evm.zig`

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

| Aspect | Mini | Performance |
|--------|------|-------------|
| Execution model | Sequential PC-based | Dispatch schedule + tail calls |
| Bytecode handling | Per-instruction reads | Single preprocessing pass |
| Stack operations | Bounds-checked every op | Unsafe ops after validation |
| Gas checking | Per-operation | Per-basic-block batching |
| Synthetic opcodes | None | 30+ fused patterns |
| Branch prediction | ~50% (switch) | ~100% (direct calls) |
| Code complexity | ~46 source files | ~158 source files |

## Hardfork Support

The performance EVM defines rules for Frontier through Osaka, and Osaka is the
default (`Hardfork.DEFAULT`). The EEST pass rates below are the performance EVM's
2026-11-22 baseline from `specs/README.md` (`zig build state-tests`,
`tests@v21.0.3`):

| Hardfork | Key Features | EEST pass % |
|----------|--------------|------------:|
| Frontier | Base EVM opcodes | 23.86 |
| Homestead | DELEGATECALL | 22.42 |
| Byzantium | RETURNDATASIZE, STATICCALL, REVERT | 10.76 |
| Constantinople (Fix) | SHL/SHR/SAR, CREATE2, EXTCODEHASH | 10.38 |
| Istanbul | CHAINID, SELFBALANCE | 9.95 |
| Berlin | EIP-2929 (warm/cold access) | 15.53 |
| London | BASEFEE, EIP-3529 (reduced refunds) | 21.42 |
| Shanghai | PUSH0, EIP-3651 (warm coinbase) | 21.14 |
| Cancun | TLOAD/TSTORE, MCOPY, BLOBHASH | 19.02 |
| Prague | EIP-7702 (set code), BLS12-381 | 20.17 |
| Osaka | CLZ, P256VERIFY, EIP-7825 gas cap | 19.15 |

## Documentation Structure

```
docs/
├── README.md              ← You are here
├── src/pages/             ← Vocs site (guillotine.tevm.sh); sidebar in vocs.config.ts
├── building-custom-sdks.md   Custom language SDKs over the C ABI
│
├── dev/                   ← Developer deep dive documentation
│   ├── README.md          Index with learning path
│   ├── ARCHITECTURE.md    Unified architecture with diagrams
│   ├── EXECUTION-MODELS.md   Side-by-side Mini vs Performance
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
| `zig build test` | Run specs, integration, unit, and lib tests |
| `zig build specs` | Run the legacy filler spec tests |
| `zig build state-tests` | Run the official EEST state tests |
| `zig build test-unit` | Run unit tests |
| `zig build test-opcodes` | Run opcode differential tests |
| `zig build shared` / `zig build static` | Build the C FFI library (`libguillotine_ffi`) |

## Project Conventions

- **No output = success**: Zig tests produce no output when passing
- **Use log module**: Never `std.debug.print`, use `log.debug`
- **Use tracer.assert**: Never `std.debug.assert`
- **Never swallow errors**: No `catch {}`
- **Fix tests immediately**: No skipping or commenting out

See [CLAUDE.md](../CLAUDE.md) for complete project instructions.

## Links

- [CLAUDE.md](../CLAUDE.md) - Project instructions and conventions
- [GitHub Repository](https://github.com/evmts/guillotine)
- [Guillotine Mini Repository](https://github.com/evmts/guillotine-mini)
- [Ethereum Yellow Paper](https://ethereum.github.io/yellowpaper/paper.pdf)
- [EVM.codes](https://www.evm.codes/)
