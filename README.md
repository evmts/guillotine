# ⚔️ Guillotine (Alpha)

<p align="center">
  <a href="https://github.com/evmts/Guillotine/actions/workflows/ci.yml">
    <img src="https://github.com/evmts/Guillotine/actions/workflows/ci.yml/badge.svg" alt="CI Status" />
  </a>
  <a href="https://t.me/+ANThR9bHDLAwMjUx">
    <img alt="Telegram" src="https://img.shields.io/badge/chat-telegram-blue.svg">
  </a>
  <a href="https://deepwiki.com/evmts/Guillotine">
    <img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki">
  </a>
</p>

<a href="https://guillotine.tevm.sh"><img width="833" height="444" alt="Guillotine Logo" src="https://github.com/user-attachments/assets/1effa677-d931-4453-8e98-2a70372efd91" /></a>

**The ultrafast EVM for every language and platform**

---

> **🔄 Repository in Flux**: This repo is currently undergoing significant refactoring as we prepare to release a new Zig library that will be like ethers.js or alloy for Zig. More updates coming soon!

---

## 🚧 Development Status (Early Alpha)

**Current Status**: DO NOT USE IN PRODUCTION

Guillotine is not suitable for production use at this time. Any use of Guillotine should be considered purely experimental.

### 📊 Ethereum Specification Test Results

Two spec suites run from the repository root:

- `zig build specs` runs the execution-spec filler tests from the `specs/execution-specs` submodule. Commit `7501b986` (2026-11-23) cut its failures from 1,031 to 581 with no regressions.
- `zig build state-tests` runs the official pre-filled EEST state tests. The 2026-11-22 baseline in [specs/README.md](specs/README.md) passed 12,500 of 66,652 cases (`tests@v21.0.3`).

See [specs/README.md](specs/README.md) for how to fetch fixtures, filter by fork, and read the failure report.

**Current Development Focus**: Our primary goal is achieving 100% Ethereum specification compliance while ensuring complete safety, debuggability, and observability through our tracer system ([`src/tracer/tracer.zig`](src/tracer/tracer.zig)). The tracer provides comprehensive execution monitoring, differential testing against a reference implementation, and detailed error reporting for every opcode.

For an in-depth understanding of Guillotine's design and implementation, see the [documentation site](https://guillotine.tevm.sh) ([architecture](docs/src/pages/concepts/architecture.mdx)) and the [developer deep dive](docs/dev/README.md). Follow the [issue tracker](https://github.com/evmts/guillotine/issues) for features planned for Beta.

**Network Support**: The EVM executes **Ethereum Mainnet** rules. [`src/layer2`](src/layer2) (exported as `layer2` from `src/root.zig`, tested by `zig build test-layer2`) implements OP Stack and Base fee, deposit and precompile rules as standalone helpers; `EvmConfig` does not select them yet. Planned for Beta:

- **OP Stack** execution (Optimism, Base, etc.)
- **Arbitrum Nitro** support

---

## ✨ Features

🚧 = Coming soon. Consider opening a discussion if you have any API recommendations or requested features.

- ⚡ **Extreme speed**
- 🌐 **Universal** - Planned and experimental support for many languages and platforms (see [SDKs](#-sdks-experimental))
  - **Zig** - native API
  - **C** - FFI library (`zig build shared` / `zig build static`)
  - **TypeScript** - Bun FFI package over the native library
  - **🚧 Go, Rust, Python, Swift, Kotlin** - build your own on the C ABI with the [custom SDK guide](docs/building-custom-sdks.md)
- 📦 **Minimal bundle size**
  - Zig `comptime` configuration means you only pay for features you actually use
  - Skip precompiles or use specific hard forks without bundle size or runtime overhead
- 📚 **Well documented**
- 🎨 **Fun** - Guillotine is a fun way to dive into Zig and fun/easy to [contribute](./CONTRIBUTING.md) to
- 🤖 **LLM-friendly**
- 🧪 **Robust** - Guillotine takes testing and architecture very seriously with [unit tests](./src) in source files, [integration tests](./test), [fuzz testing](./test/fuzz), [differential testing](./test/differential) using MinimalEvm, [formal verification](./verify), and [benchmarks](./bench)
- ✨ **Useful** - 🚧 Coming soon 🚧 Guillotine is building a powerful [CLI](https://github.com/evmts/guillotine/issues) and [native app](https://github.com/evmts/guillotine/issues) that you can think of as a local-first, Tenderly-like tool

---

## 🔨 Building from Source

CI builds and tests on macOS (arm64) and Linux (x86_64).

### Prerequisites

- **Zig 0.15.x**: CI uses 0.15.2; `build.zig.zon` requires at least 0.15.1. Zig 0.16 and later are not supported. Use [zvm](https://github.com/tristanisham/zvm) to manage versions.
- **Rust toolchain** (stable, with Cargo): `zig build` runs Cargo for the cryptographic and Foundry dependencies.
- **Git** (with submodule support)

### Build Steps

```bash
# 1. Clone with submodules
git clone --recursive https://github.com/evmts/guillotine.git
cd guillotine

# Or if already cloned:
git submodule update --init --recursive

# 2. Build the project
zig build

# 3. Verify the build
zig build test-opcodes
```

---

## 🧰 SDKs (Experimental)

Guillotine officially ships three integration surfaces:

- **Zig native bindings** — the repository's native EVM API in `src/root.zig`.
- **[C FFI](sdks/c)** — native embedding and custom language bindings.
- **[`@tevm/guillotine` TypeScript](sdks/typescript)** — Bun FFI bindings to the native `libguillotine_ffi` library (Bun ≥ 1.1; Node.js and browsers are not supported).

The C and TypeScript APIs are experimental and may change. For Python, Go,
Rust, Swift, or Kotlin/JNI, use the
[custom SDK guide](docs/building-custom-sdks.md) and
[SDK builder skill](.agents/skills/guillotine-sdk-builder/SKILL.md).
See [sdks/README.md](sdks/README.md) for the maintained SDK scope and build commands.

---

## 📊 Benchmarks & Bundle Size 🚧

Guillotine is fast.

Benchmarks so far look very promising.

- Guillotine shows measurable performance gains over [REVM](https://github.com/bluealloy/revm) and performance on par with [evmone](https://github.com/ethereum/evmone).
- More major optimizations planned for Beta release

### Overall Performance Summary (Per Run)

These benchmarks were taken using the [evm-bench](https://github.com/ziyadedher/evm-bench) test cases with `hyperfine`.

- Benchmarking infra can be seen in previous commits but is currently being moved to its [own dedicated repo](https://github.com/evmts/evm-benchmarks).
- Looking for contributors to help set up easily reproducible benchmarks

| Test Case               | evmone   | Guillotine | REVM     | Geth     |
| ----------------------- | -------- | ---------- | -------- | -------- |
| erc20-approval-transfer | 1.56 ms  | 1.59 ms    | 1.67 ms  | 3.65 ms  |
| erc20-mint              | 4.26 ms  | 4.28 ms    | 5.76 ms  | 12.84 ms |
| erc20-transfer          | 6.01 ms  | 6.65 ms    | 8.30 ms  | 17.50 ms |
| ten-thousand-hashes     | 2.90 ms  | 2.46 ms    | 3.31 ms  | 9.36 ms  |
| snailtracer             | 27.15 ms | 26.41 ms   | 39.01 ms | 86.02 ms |

---

### Bundle size 🚧

```
WASM Bundle Sizes
┌───────────────────────────────────────────────────────────────────────────────────────────┐
│ Package         │ Size                                      │ Mode         │ Precompiles   │
├───────────────────────────────────────────────────────────────────────────────────────────┤
│ MinimalEvm     │ ▓▓▓ 56KB                                   │ ReleaseSmall │ ✗ Not included│
│ Guillotine EVM │ ▓▓▓▓▓▓ 119KB                              │ ReleaseSmall │ ✗ Not included│
│ Primitives     │ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ 687KB │ ReleaseSmall │ ✗ Not included│
│ Full Package   │ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ 1.1MB │ ReleaseFast  │ ✓ Included    │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

- **MinimalEvm**: Minimal implementation focused on tracing (57,641 bytes)
- **Guillotine EVM**: Core EVM implementation
- **Primitives**: Complete primitives library
- **Full Package**: All features including precompiles

Note: Smaller packages use `ReleaseSmall` optimization for size, while the full package uses `ReleaseFast` for performance.
**ReleaseSafe** builds (recommended for alpha) are larger due to additional safety features and validation overhead.

---

### How is Guillotine so fast?

Guillotine was built using [data-oriented design](https://www.youtube.com/watch?v=rX0ItVEVjHc) with an emphasis on [minimizing branch-prediction misses](https://www.youtube.com/watch?v=nczJ58WvtYo) in the CPU. We studied every EVM implementation as well as [Wasm](https://webassembly.org/), [Lua](https://www.lua.org/), and [Python](https://www.python.org/) interpreter implementations for the state of the art. Optimizations include, from most impactful to least impactful:

- An extremely optimized StackFrame and opcode dispatch data structure
- [Indirect threading via tailcall recursion](https://news.ycombinator.com/item?id=43317592) (for excellent CPU branch prediction)
- Highly microoptimized opcode instruction handlers
- Highly microoptimized EVM stack implementation
- Opcode fusions turning common opcode patterns into a single dispatch
- **Assembly-optimized Keccak** via [keccak-asm](https://crates.io/crates/keccak-asm)
- Batching calculation of static gas costs and stack analysis
- Simple code that minimizes unnecessary abstractions, inline directives, and interfaces allowing the Zig compiler maximum freedom to optimize for performance or size
- Additional micro-optimizations not listed

**Balanced tradeoffs**

We focus on maintainable code and targeted optimizations where they matter. We do our best to write simple code the Zig compiler can optimize.

There are many more optimizations that have not been implemented yet. The biggest of which will be translating our stack-based EVM into a register-based EVM—a common technique used by interpreters like Lua and PyPy, and Cranelift-style designs—to achieve up to ~30% performance increases.

---

### How is Guillotine so small?

- Zig avoids hidden control flow.
- This makes it really easy to write the most minimal simple code needed to get the job done.
- By minimizing unnecessary abstractions the compiler is able to do a great job optimizing for size.
- Zig `comptime` allows us to easily and surgically only include the minimum necessary code given the specific EVM and hard fork configuration. Code you don't use isn't included.

### How is Guillotine so safe?

Guillotine is in early alpha, but we prioritize safety through multiple build modes and extensive testing:

#### Build Modes

- **Debug**: Full debugging symbols and runtime checks
- **ReleaseFast**: Optimized for maximum performance
- **ReleaseSmall**: Optimized for minimal bundle size
- **ReleaseSafe** (⭐ **RECOMMENDED FOR ALPHA**): Our most defensive build mode

#### ReleaseSafe Features

**ReleaseSafe** includes a comprehensive safety system that runs a simplified EVM as a sidecar to validate execution:

- ✅ **Parallel Validation**: Runs a minimal EVM implementation alongside to cross-check results
- ✅ **Safety Checks**: Validates execution at every step to ensure correctness
- ✅ **Infinite Loop Protection**: Prevents runaway execution with instruction limits
- ✅ **Advanced Tracing**: Full event system for monitoring EVM execution
- ✅ **Debugging Support**: Can run as a debugger with step-by-step execution
- ✅ **Memory Safety**: Preserves all debug-mode defensive checks
- ✅ **Comprehensive Logging**: Detailed logging of all EVM operations

While ReleaseSafe has performance overhead compared to ReleaseFast, it provides critical safety guarantees during alpha development.

#### Additional Safety Measures

- Extensive unit, E2E, fuzz, benchmark, and differential test suites
- Continuous validation against reference implementations
- Memory safety checks and bounds validation

---

## 🚧 Full Client

Guillotine is a VM implementation (like [REVM](https://github.com/bluealloy/revm)) not a full node (like [reth](https://github.com/paradigmxyz/reth)).
However, [Tevm](https://github.com/evmts/tevm-monorepo) (the team behind Guillotine) plans to begin work on a highly performant Zig-based full client soon. This client will leverage parts of Guillotine's architecture to execute transactions in parallel and architect around I/O bottlenecks.

---

## Additional features

### Zero Config

Guillotine ships with opinionated defaults and is mainnet‑ready with zero configuration.

---

### Customizability

Guillotine is built from the ground up to be a highly customizable EVM SDK.

**With Guillotine you can easily create your own EVM!**

Using [Zig](https://ziglang.org/) `comptime`, you configure features with regular Zig code, and the compiler includes only what you use. [REVM](https://github.com/bluealloy/revm) offers similar customizability but requires more onboarding into complex generics and feature flags compared to Zig `comptime`.

Customizability features include

- Configure any hard fork or EIP
- Add or override opcodes and precompiles in the EVM
- Simple, powerful tracer interface for introspection
- Comprehensive options to configure the EVM (including niche settings like changing the word size from `u256`)
- `comptime` validation to ensure configurations are sound

All customizations are zero‑cost, compile‑time abstractions using [Zig](https://ziglang.org/) `comptime`, so customizations never sacrifice runtime performance and your bundle includes only the features you choose to use.

For most users who don't need customizations, we offer default options for all major hard forks.

🚧 This feature is considered experimental and the API could change.

---

## 🔁 Relationship to Tevm

Once stable, **Guillotine’s Wasm build** will replace the current JavaScript EVM in [Tevm](https://node.tevm.sh).
Upgrades include:

- 🚀 **Up to 1000x performance boost**
- 📉 **300 KB (75%) bundle size reduction**
- 🧱 **Fast Ethereum library** An ultrafast utility and client library wrapping the Guillotine primitives package

---

## 🤝 Contributing

We welcome contributions of all kinds, including AI-assisted contributions (with proper disclosure)!

See our [Contributing Guide](./CONTRIBUTING.md) to get started.

---

## 🙏 Dependencies & Acknowledgments

### Contributors

Be an early contributor and get listed here forever!

- [Will Cory (fucory)](https://github.com/roninjin10) - Project Lead of Guillotine/[Tevm](https://github.com/evmts/tevm-monorepo)
- [polarzero](https://github.com/0xpolarzero) - Core Developer Guillotine/Tevm, CLI/App Lead
- [Vlad](https://github.com/vladfdp) - Core Developer Guillotine, Cryptography Lead

---

### Runtime Dependencies

Guillotine values minimal runtime dependencies but utilizes the following powerful crypto dependencies

- **[arkworks](https://github.com/arkworks-rs)** – Rust lib for elliptic curve operations
- **[c-kzg-4844](https://github.com/ethereum/c-kzg-4844)** – Simple C KZG commitment library for EIP-4844
- **[keccak-asm](https://crates.io/crates/keccak-asm)** – Assembly-optimized Keccak-256
- **[crypto from Zig std library](https://ziglang.org/documentation/master/std/#std.crypto)**

We have plans to make all crypto `comptime` configurable with opinionated defaults for Beta.

---

### Tooling dependencies

- **[Zig](https://ziglang.org)** – The best tool for building a highly customizable ultrafast EVM
- **[zbench](https://github.com/hendriknielaender/zBench)** – Zig‑specific benchmarking framework for performance regression testing
- **[foundry-compilers](https://github.com/foundry-rs/compilers)** – Rust `solc` wrapper exposed in Zig and used internally as a Zig library for building contracts.

---

### Inspirations

We deeply appreciate these excellent EVM implementations that served as inspiration:

- **[EthereumJS](https://github.com/ethereumjs/ethereumjs-monorepo)** – A simple pure JavaScript/TypeScript EVM implementation used by Tevm featuring zero Wasm dependencies
- **[evmone](https://github.com/ethereum/evmone)** – A hyperoptimized C++ EVM implementation known for its exceptional performance
- **[Geth](https://github.com/ethereum/go-ethereum)** – The canonical Go Ethereum client. An EVM implementation that perfectly balances performance with simplicity
- **[REVM](https://github.com/bluealloy/revm)** – A beautifully architected, highly customizable Rust EVM implementation.

---

### 🙏 Additional Acknowledgments

- 🏛️ **Ethereum Foundation** — for funding support
- 💬 [Tevm Telegram](https://t.me/+ANThR9bHDLAwMjUx) — for community feedback and direction and helping brainstorm the name
- 🧠 [@SamBacha](https://github.com/sambacha) — Winner of the brainstorm who came up with the name **Guillotine**

---

## 📜 License

MIT License. Free for all use. 🌍

<a href="https://shazow.net/posts/permissive-vs-copyleft/"><img width="256" height="256" alt="image" src="https://github.com/user-attachments/assets/644c2d29-8e7f-44f4-a17f-285a1f4c20e7" /></a>


## Osaka ModExp

Configure `Evm(.{ .eips = .{ .hardfork = .OSAKA } })` to activate EIP-7823's
1,024-byte per-operand limit and EIP-7883 pricing for ModExp (`0x05`). The minimum
is 500 gas. Prague retains its prior pricing and operand acceptance. The full
engine and reference interpreter share the synchronized vendored precompile.
See [the precompile contract](lib/voltaire/src/precompiles/modexp.zig.md).

Run `zig build test-modexp` for the vendored arithmetic and precompile tests,
`zig build test-opcodes-0xfa` for ModExp STATICCALL regression checks, and
`zig build test-opcodes` for the complete gate (including `test-modexp`).
