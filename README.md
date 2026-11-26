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

<a href="docs/src/pages"><img width="833" height="444" alt="Guillotine Logo" src="https://github.com/user-attachments/assets/1effa677-d931-4453-8e98-2a70372efd91" /></a>

**The ultrafast EVM for every language and platform**

---

> **v0.1.0**: the first tagged release. It builds with stock Zig 0.17.1 using native `preserve_none` tail-call dispatch; no compiler fork is required. See [CHANGELOG.md](CHANGELOG.md).

---

## 🚧 Development Status (Early Alpha)

**Current Status**: DO NOT USE IN PRODUCTION

Guillotine is not suitable for production use at this time. Any use of Guillotine should be considered purely experimental.

### 📊 Verification Results (v0.1.0)

| Check | Result |
| --- | --- |
| Official EEST state tests (`tests@v21.0.3`), all 14 mainnet hardforks, Frontier through Osaka | **66,652 / 66,652 (100.00%)** with fusions on and with fusions off |
| Zig-to-Lean 4.32.0 differential fuzz vectors (`verify/lean`) | **116,384 / 116,384 (100.00%)** |
| SMT theorems (`verify/smt`) | **32 / 32 proved** |

The pinned EEST release also contains 16,907 Amsterdam cases. They are skipped
because Amsterdam is not implemented yet.

Fetch the pinned fixtures with `scripts/fetch-eest-fixtures.sh`, then run
`zig build state-tests -Doptimize=ReleaseSafe` (add `-Devm-enable-fusion=false`
for the unfused dispatch). CI asserts both counts on every push. Run the Lean
differential fuzzer with `zig build test-lean-diff` and the full formal
verification suite with `zig build verify`.

A full spec pass is not production readiness: see the status above.
See [specs/README.md](specs/README.md) for detailed instructions on running the test suites.

For an in-depth understanding of Guillotine's design and implementation, see the [Architecture Documentation](docs/src/pages/concepts/architecture.mdx). Follow the [issue tracker](https://github.com/evmts/Guillotine/issues) for planned features.

**Network Support**: Ethereum Mainnet (Frontier through Osaka) and Base L2 / OP Stack (Bedrock through Jovian, pre-Azul) on the real EVM engine (the `Evm` type behind `DefaultEvm`, `src/layer2/evm_host.zig`). Run the Layer 2 tests with `zig build test-layer2`. Arbitrum Nitro is not supported.

---

## ✨ Features

🚧 = Coming soon. Consider opening a discussion if you have any API recommendations or requested features.

- ⚡ **Extreme speed**
- 🌐 **Universal** - Shipped SDKs, plus a skill for building more
  - **Zig** - Zig package (`dep.module("evm")`)
  - **C** - `libguillotine_ffi` + `guillotine.h`
  - **TypeScript** - `@tevm/guillotine`, Bun FFI
  - **Other languages** (Go, Rust, Python, Swift, Kotlin) - generate bindings over the C FFI with the [Custom SDK Builder skill](.agents/skills/guillotine-sdk-builder/SKILL.md)
- 📦 **Minimal bundle size**
  - Zig `comptime` configuration means you only pay for features you actually use
  - Skip precompiles or use specific hard forks without bundle size or runtime overhead
- 📚 **Well documented**
- 🎨 **Fun** - Guillotine is a fun way to dive into Zig and fun/easy to [contribute](./CONTRIBUTING.md) to
- 🤖 **LLM-friendly**
- 🧪 **Robust** - Guillotine takes testing and architecture very seriously with [full unit tests](./src) for all files, [fuzz testing](./test/fuzz), [differential testing](./test/differential) using MinimalEvm, and [benchmarks](./bench)
- ✨ **Useful** - 🚧 Coming soon 🚧 Guillotine is building a powerful [CLI](https://github.com/evmts/Guillotine/issues) and [native app](https://github.com/evmts/Guillotine/issues) that you can think of as a local-first, Tenderly-like tool

---

## 🔨 Building from Source

**Currently Supported**: macOS arm64 and Linux x86_64 (built and tested in CI; release prebuilds for both)

### Prerequisites

- **Zig 0.17.1** (the stock release; no compiler fork. Use [zvm](https://github.com/marler182/zvm) to manage versions)
- **Rust toolchain** 1.75+ (for cryptographic dependencies)
- **Git** (with submodule support)

### Build Steps

```bash
# 1. Clone with submodules
git clone --recursive https://github.com/evmts/Guillotine.git
cd Guillotine

# Or if already cloned:
git submodule update --init --recursive

# 2. Build the project
zig build

# 3. Verify the build
zig build test-opcodes
```

---

## 🧰 SDKs (Experimental)

Guillotine v0.1.0 ships three integration surfaces:

- **Zig package**: the public modules `evm`, `voltaire` and `layer2`, consumed with `dep.module("evm")`.
- **[C FFI](sdks/c)**: `libguillotine_ffi` (built from `src/evm_c_api.zig`) and the header [`sdks/c/include/guillotine.h`](sdks/c/include/guillotine.h).
- **[`@tevm/guillotine` TypeScript](sdks/typescript)**: Bun native FFI (`bun:ffi`) bindings to `libguillotine_ffi`; 340 / 340 tests pass.

The C and TypeScript APIs are experimental and may change. For Python, Go,
Rust, Swift, Kotlin/JNI, or other languages, use the
[custom SDK guide](docs/building-custom-sdks.md) and the
[Custom SDK Builder skill](.agents/skills/guillotine-sdk-builder/SKILL.md).
See [sdks/README.md](sdks/README.md) for the maintained SDK scope and build commands.

### Zig package

Add the dependency. The `=guillotine` suffix names the dependency key; without
it, `zig fetch` uses the package name `Guillotine`.

```bash
zig fetch --save=guillotine https://github.com/evmts/guillotine/archive/refs/tags/v0.1.0.tar.gz
```

`zig fetch` writes the entry and its hash into your `build.zig.zon`:

```zig
.dependencies = .{
    .guillotine = .{
        .url = "https://github.com/evmts/guillotine/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "...", // filled in by zig fetch --save
    },
},
```

Import the `evm` module in `build.zig`:

```zig
const guillotine = b.dependency("guillotine", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("evm", guillotine.module("evm"));
```

### Release assets

Each GitHub Release attaches:

| Asset | Contents |
| --- | --- |
| `libguillotine_ffi.so` | C FFI shared library, Linux x86_64, glibc >= 2.28 |
| `libguillotine_ffi.dylib` | C FFI shared library, macOS arm64 |
| `guillotine.h` | C header for both libraries |
| `SHA256SUMS.txt` | SHA-256 checksums of the three files above |

Verify downloads with `sha256sum -c SHA256SUMS.txt --ignore-missing` (Linux) or
`shasum -a 256 -c SHA256SUMS.txt --ignore-missing` (macOS).

---

## 📊 Benchmarks

Measured with the in-repo runner (`zig build bench`, ReleaseFast) on x86_64 Linux:

| Workload | Guillotine | Comparison |
| --- | --- | --- |
| `contract/snailtracer` | **37.86 ms** (6.21 GGas/s) | 1.25x faster than revm (47.21 ms) |
| `precompile/ECRECOVER` | **0.171 ms** | 182x faster than the previous implementation |
| `precompile/MODEXP-256` | **2.82 µs** | |
| `precompile/BN254-mul` | **8.16 µs** | |

The revm figure comes from `revme bench snailtracer`, a different harness on the
same host, so treat the ratio as indicative. See [bench/README.md](bench/README.md)
and [Benchmarks and native JIT](docs/src/pages/guides/benchmarks-and-jit.mdx).

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

**ReleaseSafe** keeps Zig's runtime safety checks (bounds, overflow, unreachable) in an optimized build. The tracer adds opt-in checks on top:

- ✅ **Differential validation**: with `TracerConfig.enabled` and `enable_validation` set (both default to `false`), the tracer runs MinimalEvm (`src/tracer/minimal_evm.zig`) beside the dispatch engine and compares state after every instruction
- ✅ **Infinite loop protection**: `EvmConfig.loop_quota` caps loops in Debug and ReleaseSafe, and the tracer caps execution at 300M instructions
- ✅ **Tracing and debugging**: an event system for step-by-step execution monitoring

While ReleaseSafe has performance overhead compared to ReleaseFast, it is the recommended mode during alpha.

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

Once stable, Guillotine will replace the current JavaScript EVM in [Tevm](https://node.tevm.sh).
The `src/` engine has no WASM build today; `@tevm/guillotine` runs it through Bun FFI.

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
