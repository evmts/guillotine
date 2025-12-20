<div align="center">
  <h1>
    Minimal, spec-compliant EVM in Zig.
    <br/>
    <br/>
  </h1>
  <sup>
    <a href="https://github.com/evmts/guillotine-mini">
       <img src="https://img.shields.io/badge/zig-0.15.1+-orange.svg" alt="zig version" />
    </a>
    <a href="https://github.com/evmts/guillotine-mini/actions">
      <img src="https://img.shields.io/badge/build-passing-brightgreen.svg" alt="build status" />
    </a>
    <a href="https://github.com/evmts/guillotine-mini">
      <img src="https://img.shields.io/badge/tests-all%20hardforks%20passing-brightgreen.svg" alt="tests" />
    </a>
  </sup>
</div>

## Requirements

**Both Zig and Cargo are required to build this project:**

- [Zig 0.15.1+](https://ziglang.org/download/) — Core build system and language
- [Cargo](https://doc.rust-lang.org/cargo/getting-started/installation.html) — **Required** for building Rust-based cryptographic dependencies (BN254/ARK)
- [Python 3.8+](https://www.python.org/) — For test generation and spec fixtures (optional for using as library)

## Installation

**Option 1:** Use as a Zig dependency (recommended)

```bash
zig fetch --save https://github.com/evmts/guillotine-mini/archive/main.tar.gz
```

Then in your `build.zig`:

```zig
const guillotine_dep = b.dependency("guillotine_mini", .{
    .target = target,
    .optimize = optimize,
});
const guillotine_mod = guillotine_dep.module("guillotine_mini");

// Add to your executable/library
exe.root_module.addImport("guillotine_mini", guillotine_mod);

// IMPORTANT: Link cryptographic library artifacts from primitives
const primitives_dep = b.dependency("guillotine_primitives", .{
    .target = target,
    .optimize = optimize,
});
exe.linkLibrary(primitives_dep.artifact("blst"));
exe.linkLibrary(primitives_dep.artifact("keccak-asm"));
exe.linkLibrary(primitives_dep.artifact("sha3-asm"));
exe.linkLibrary(primitives_dep.artifact("crypto_wrappers"));
```

**Option 2:** Build from source

```bash
git clone https://github.com/evmts/guillotine-mini.git --recurse-submodules
cd guillotine-mini
zig build  # Automatically fetches primitives dependency
```

> **Note**: The primitives library is fetched automatically via `zig fetch` during build. It is no longer included as a git submodule.
>
> **For downstream consumers**: When using guillotine-mini as a dependency, you must explicitly link the cryptographic library artifacts from the primitives package (blst, keccak-asm, sha3-asm, crypto_wrappers). See the build.zig example above.

<br />

## Quick Start

```bash
zig build           # Build all modules
zig build test      # Run unit + spec tests
zig build specs     # Run ethereum/tests validation
zig build wasm      # Build WebAssembly library
```

Use `TEST_FILTER` to run specific test suites:

```bash
TEST_FILTER="push0" zig build specs
TEST_FILTER="Cancun" zig build specs
TEST_FILTER="transientStorage" zig build specs
```

<br />

## Documentation

[`CLAUDE.md`](./CLAUDE.md) &mdash; Comprehensive project documentation for AI assistants and developers

[`TESTING.md`](./TESTING.md) &mdash; Testing strategies and targets

[`CONTRIBUTING.md`](./CONTRIBUTING.md) &mdash; Contributing guide, environment setup, and debugging

[`src/precompiles/CLAUDE.md`](./src/precompiles/CLAUDE.md) &mdash; Precompiled contracts documentation

<br />

## Test Status

| Hardfork | Status | Notes |
|----------|--------|-------|
| Frontier | ✅ **PASSING** | All tests pass |
| Homestead | ✅ **PASSING** | All tests pass |
| Byzantium | ✅ **PASSING** | All tests pass |
| Constantinople | ✅ **PASSING** | All tests pass |
| Istanbul | ✅ **PASSING** | All tests pass |
| Berlin | ✅ **PASSING** | All tests pass |
| Paris | ✅ **PASSING** | All tests pass |
| London | ✅ **PASSING** | All tests pass |
| Shanghai | ✅ **PASSING** | All tests pass |
| Cancun | ✅ **PASSING** | All tests pass |
| Prague | ✅ **PASSING** | All tests pass |
| Osaka | ✅ **PASSING** | All tests pass |

**All hardfork tests passing!** Recent fixes include BLAKE2F precompile (EIP-152), MODEXP edge cases, CREATE2 return data handling, EIP-3860 initcode limits, and EIP-6780 SELFDESTRUCT behavior.

<br />

## Architecture

Minimal, correct, and well-tested Ethereum Virtual Machine (EVM) implementation in Zig, prioritizing specification compliance, clarity, and hardfork support (Frontier through Osaka).

- [**Core EVM Components**](#core-components)
  - [`Evm`](./src/evm.zig) &mdash; EVM orchestrator: state management, storage, gas refunds, nested calls, warm/cold tracking
    - [`call`](./src/evm.zig) &mdash; main entry point for EVM execution
    - [`innerCall`](./src/evm.zig) &mdash; handle CALL, STATICCALL, DELEGATECALL, CALLCODE
    - [`innerCreate`](./src/evm.zig) &mdash; handle CREATE and CREATE2 operations
    - [`accessAddress`](./src/evm.zig) &mdash; EIP-2929 address access tracking (warm/cold)
    - [`accessStorageSlot`](./src/evm.zig) &mdash; EIP-2929 storage access tracking
    - [`getStorage`](./src/evm.zig) &mdash; read persistent storage
    - [`setStorage`](./src/evm.zig) &mdash; write persistent storage with refund accounting
    - [`getTransientStorage`](./src/evm.zig) &mdash; read transient storage (EIP-1153)
    - [`setTransientStorage`](./src/evm.zig) &mdash; write transient storage (EIP-1153)
  - [`Frame`](./src/frame.zig) &mdash; bytecode interpreter: stack, memory, program counter, per-opcode execution
    - [`execute`](./src/frame.zig) &mdash; main execution loop
    - [`step`](./src/frame.zig) &mdash; single instruction execution (for tracing)
    - [`pushStack`](./src/frame.zig) &mdash; push value to stack with overflow check
    - [`popStack`](./src/frame.zig) &mdash; pop value from stack with underflow check
    - [`expandMemory`](./src/frame.zig) &mdash; expand memory with quadratic gas cost
  - [`Host`](./src/host.zig) &mdash; abstract state backend interface for external world interaction
    - [`HostInterface`](./src/host.zig) &mdash; pluggable interface for state access (balances, code, storage, logs)
    - [`CallResult`](./src/host.zig) &mdash; execution result with gas, output, and state changes
    - [`CallType`](./src/host.zig) &mdash; call type enumeration (CALL, STATICCALL, DELEGATECALL, etc.)
  - [`Hardfork`](./src/hardfork.zig) &mdash; hardfork detection and feature flags
    - [`isAtLeast`](./src/hardfork.zig) &mdash; check if current fork is at or after specified version
    - [`isBefore`](./src/hardfork.zig) &mdash; check if current fork is before specified version
    - [`fromString`](./src/hardfork.zig) &mdash; parse hardfork from string name
  - [`Opcode`](./src/opcode.zig) &mdash; opcode definitions and utilities
    - [`getOpName`](./src/opcode.zig) &mdash; get human-readable opcode name
  - [`Tracer`](./src/trace.zig) &mdash; EIP-3155 execution trace generation
    - [`TraceEntry`](./src/trace.zig) &mdash; single execution step with PC, opcode, gas, stack, memory
  - [`Errors`](./src/errors.zig) &mdash; EVM error types
    - [`CallError`](./src/errors.zig) &mdash; execution error enumeration
    <br/>
    <br/>
- [**Supported EIPs**](#eip-support)
  - **EIP-2929** &mdash; State access gas costs (Berlin)
  - **EIP-2930** &mdash; Access lists (Berlin)
  - **EIP-1559** &mdash; Fee market change (London)
  - **EIP-3198** &mdash; BASEFEE opcode (London)
  - **EIP-3529** &mdash; Reduced gas refunds (London)
  - **EIP-3541** &mdash; Reject code starting with 0xEF (London)
  - **EIP-3651** &mdash; Warm coinbase (Shanghai)
  - **EIP-3855** &mdash; PUSH0 instruction (Shanghai)
  - **EIP-3860** &mdash; Limit and meter initcode (Shanghai)
  - **EIP-1153** &mdash; Transient storage opcodes (Cancun)
  - **EIP-4844** &mdash; Shard blob transactions (Cancun)
  - **EIP-5656** &mdash; MCOPY instruction (Cancun)
  - **EIP-6780** &mdash; SELFDESTRUCT only in same transaction (Cancun)
  - **EIP-7516** &mdash; BLOBBASEFEE opcode (Cancun)
  - **EIP-7702** &mdash; Set EOA account code (Prague)
  - **EIP-2537** &mdash; BLS12-381 precompiles (Prague)
  - **EIP-7692** &mdash; EVM Object Format (EOF) v1 (Prague)
    <br/>
    <br/>
- [**Testing & Debugging**](#testing)
  - [`test/specs/runner.zig`](./test/specs/runner.zig) &mdash; ethereum/tests spec test runner
  - [`scripts/isolate-test.ts`](./scripts/isolate-test.ts) &mdash; single test isolation with trace analysis
  - [`scripts/test-subset.ts`](./scripts/test-subset.ts) &mdash; filtered test execution
  - [`scripts/fix-specs.ts`](./scripts/fix-specs.ts) &mdash; AI-powered systematic test fixing
    <br/>
    <br/>

## Key Features

- **Specification Compliance**: Validated against [ethereum/tests](https://github.com/ethereum/tests) GeneralStateTests
- **Hardfork Support**: All hardforks from Frontier through Osaka
- **EIP Compliance**: 20+ EIPs implemented and tested
- **Tracing**: Full EIP-3155 trace support for debugging and analysis
- **WASM Target**: Compiles to WebAssembly (~193 KB optimized)
- **Zero Dependencies**: No external EVM libraries, direct Zig implementation
- **Test Coverage**: 100% of ethereum/tests passing across all hardforks

<br />

## More

[**Primitives Library**](https://github.com/evmts/primitives) &mdash; Ethereum primitives and cryptography (Address, Uint, RLP, ABI, keccak256, secp256k1, BLS12-381) - now available via zig fetch

[**Development Guide**](./CLAUDE.md) &mdash; Architecture deep-dive, debugging workflow, and coding standards

[**Contributing**](./CONTRIBUTING.md) &mdash; How to contribute to the project

[**Guillotine**](https://github.com/evmts/guillotine) &mdash; Full-featured EVM execution engine built on guillotine-mini

<br />

## License

See LICENSE file for details.
