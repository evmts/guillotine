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

# Run all self-contained suites (no output = all passed)
zig build test

# Run official EEST state tests (66,652/66,652 Frontier -> Osaka; fetch fixtures first)
./scripts/fetch-eest-fixtures.sh && zig build state-tests -Doptimize=ReleaseSafe

# Run formal verification (Zean direct Zig AIR→Lean 4, hand-authored Lean 4, SMT, LLVM IR) & Lean differential fuzzer
zig build verify
zig build verify-zean
zig build verify-lean
zig build test-lean-diff -Doptimize=ReleaseSafe

# Run benchmarks (in-repo ReleaseFast runner or cross-EVM apples-to-apples suite)
zig build bench
node bench/compare/run.mjs

# Build with specific hardfork (default: OSAKA)
zig build -Devm-hardfork=OSAKA
```

## Documentation Quick Navigation

The public documentation site is live at **[guillotine.tevm.sh](https://guillotine.tevm.sh)** (Vocs 2 sources in `docs/src/pages/`).

| I want to... | Go to |
|--------------|-------|
| Browse the full docs site | [guillotine.tevm.sh](https://guillotine.tevm.sh) (`docs/src/pages/`) |
| Read testing, fuzzing, E2E & formal verification docs | [src/pages/guides/testing-and-verification.mdx](./src/pages/guides/testing-and-verification.mdx) |
| Read in-repo & cross-EVM benchmarks + JIT docs | [src/pages/guides/benchmarks-and-jit.mdx](./src/pages/guides/benchmarks-and-jit.mdx) · [bench/compare/RESULTS.md](../bench/compare/RESULTS.md) |
| Read TigerStyle safety, pooling & build-mode guarantees | [dev/TIGERSTYLE.md](./dev/TIGERSTYLE.md) · [src/pages/guides/tigerstyle.mdx](./src/pages/guides/tigerstyle.mdx) |
| Understand the architecture | [dev/ARCHITECTURE.md](./dev/ARCHITECTURE.md) |
| Compare MinimalEvm vs Performance | [dev/EXECUTION-MODELS.md](./dev/EXECUTION-MODELS.md) |
| Learn about storage/state | [dev/STATE-MANAGEMENT.md](./dev/STATE-MANAGEMENT.md) |
| Understand gas calculation | [dev/GAS-METERING.md](./dev/GAS-METERING.md) |
| Run or write tests (developer deep dive) | [dev/TESTING.md](./dev/TESTING.md) |
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
| `zig build` | Build the project (requires stock Zig `0.17.1`) |
| `zig build test` | Run self-contained suites (unit, opcodes, integration, layer2, precompiles, fusions, modexp, fuzz, jit) |
| `zig build state-tests -Doptimize=ReleaseSafe` | Run official EEST state tests (`66,652 / 66,652` Frontier → Osaka) |
| `zig build verify` | Run formal verification (`verify-ir`, `verify-smt`, `verify-lean`) |
| `zig build verify-zean` | Run Zean direct Zig `0.17.1` AIR → Lean `4.35.0` proofs (`24` kernels / `55` audited theorems) |
| `zig build verify-lean` | Run hand-authored Lean `4.35.0` proofs & executable spec |
| `zig build test-lean-diff -Doptimize=ReleaseSafe` | Run Zig↔Lean `4.35.0` differential fuzzer (`116,384 / 116,384`) |
| `zig build fuzz-campaign -Doptimize=ReleaseSafe -- --seconds=60 --threads=8` | Run multi-threaded structure-aware + havoc fuzzer |
| `zig build bench` | Run in-repo ReleaseFast benchmarks |
| `node bench/compare/run.mjs` | Run cross-EVM apples-to-apples benchmarks (`evm2`, `revm`, `evmone`, `ethrex`, `gevm`, `geth`, JITs) |
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
