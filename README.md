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

<img width="833" height="444" alt="Guillotine Logo" src="https://github.com/user-attachments/assets/1effa677-d931-4453-8e98-2a70372efd91" />

**The ultrafast EVM for every language and platform**

---

## 🚧 Development Status (Early Alpha)

**Current Status**: DO NOT USE IN PRODUCTION

Guillotine is not suitable for production use at this time. Any use of Guillotine should be considered purely experimental. There are known bugs and TODOs. Follow the [issue tracker](https://github.com/evmts/Guillotine/issues) for features planned for Beta.

---

## ✨ Features

🚧 = Coming soon. Consider opening a discussion if you have any API recommendations or requested features.

- ⚡ **Extreme speed** 
- 🌐 **Universal** - Planned and experimental support for many languages and platforms
  - **🚧 Golang** 
  - **🚧 Zig** 
  - **🚧 C** 
  - **🚧 TypeScript** - Via Tevm including [Hono-like adapters](https://hono.dev/docs/getting-started/basic) for all platforms
  - **🚧 Python** 
  - **🚧 Rust** 
  - **🚧 Swift** 
  - **🚧 Kotlin** 
  - **🚧 Wasm** 
- 📦 **Minimal bundle size** 
  - Zig `comptime` configuration means you only pay for features you actually use
  - Skip precompiles or use specific hard forks without bundle size or runtime overhead
- 📚 **Well documented** 
- 🎨 **Fun** - Guillotine is a fun way to dive into Zig and fun/easy to [contribute](./CONTRIBUTING.md) to
- 🤖 **LLM-friendly** 
- 🧪 **Robust** - Guillotine takes testing and architecture very seriously with [full unit tests](./src) for all files, a robust [E2E test suite](./test/e2e), [fuzz testing](./test/fuzz), [differential testing vs REVM](./test/differential), and [benchmark testing](./test/benchmark)
- ✨ **Useful** - 🚧 Coming soon 🚧 Guillotine is building a powerful [CLI](https://github.com/evmts/Guillotine/issues) and [native app](https://github.com/evmts/Guillotine/issues) that you can think of as a local-first, Tenderly-like tool

---

## 🧰 SDKs (Experimental)

All SDKs in this repo are vibecoded proof-of-concepts. APIs are unstable and may change without notice. We're actively seeking early users to try things out and tell us what APIs you want. Please open an issue or ping us on Telegram with feedback.

- Bun: [`sdks/bun`](./sdks/bun) — Native Bun bindings around the Zig EVM
- C: [`sdks/c`](./sdks/c) — C/C++ FFI surface for embedding
- Go: [`sdks/go`](./sdks/go) — Go bindings for embedding the EVM
- Python: [`sdks/python`](./sdks/python) — Python bindings and primitives
- Rust: [`sdks/rust`](./sdks/rust) — Idiomatic Rust wrapper over FFI
- Swift: [`sdks/swift`](./sdks/swift) — Swift bindings for Apple platforms
- TypeScript: [`sdks/ts`](./sdks/ts) — WASM/TS APIs for Node, Bun, Browser

See each SDK’s README for install, quick start, and current API.

---

## 📊 Benchmarks & Bundle Size 🚧

Guillotine is fast.

Benchmarks so far look very promising.

- Guillotine shows measurable performance gains over [REVM](https://github.com/bluealloy/revm) and performance on par with [evmone](https://github.com/ethereum/evmone). 
- More major optimizations planned for Beta release

### Overall Performance Summary (Per Run)

These benchmarks were taken using the [evm-bench](https://github.com/ziyadedher/evm-bench) test cases with `hyperfine`. 

- Benchmarking infra can be seen in previous commits but is currently being moved to its own dedicated repo: https://github.com/evmts/evm-bench (WIP). 
- Looking for contributors to help set up easily reproducible benchmarks

| Test Case               | Guillotine | REVM     | Geth     | evmone   |
| ----------------------- | ---------- | -------- | -------- | -------- |
| erc20-approval-transfer | 1.59 ms    | 1.67 ms  | 3.65 ms  | 1.56 ms  |
| erc20-mint              | 4.28 ms    | 5.76 ms  | 12.84 ms | 4.26 ms  |
| erc20-transfer          | 6.65 ms    | 8.30 ms  | 17.50 ms | 6.01 ms  |
| ten-thousand-hashes     | 2.46 ms    | 3.31 ms  | 9.36 ms  | 2.90 ms  |
| snailtracer             | 26.41 ms   | 39.01 ms | 86.02 ms | 27.15 ms |

---

### Bundle size 🚧

In past commits we reduced the EVM to ~110 KB, with further improvements expected. 

- We’re currently focused on `ReleaseFast`; `ReleaseSmall` support returns soon

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

Guillotine is not yet “safe”; it’s in early alpha. But we do have features that help improve safety:

- Guillotine can be built in `Debug`, `ReleaseFast`, `ReleaseSmall`, and `ReleaseSafe`. 
- We recommend `ReleaseSafe` while in alpha.
- `ReleaseSafe` preserves debug‑mode‑only defensive checks, memory safety features, and other safeguards in the final binary.
- Guillotine also features extensive unit, E2E, fuzz, benchmark, and differential test suites.

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
- **[REVM](https://github.com/bluealloy/revm)** – A beautifully architected, highly customizable Rust EVM implementation. Used internally for differential tests.

---

### 🙏 Additional Acknowledgments

- 🏛️ **Ethereum Foundation** — for funding support
- 💬 [Tevm Telegram](https://t.me/+ANThR9bHDLAwMjUx) — for community feedback and direction and helping brainstorm the name
- 🧠 [@SamBacha](https://github.com/sambacha) — Winner of the brainstorm who came up with the name **Guillotine**

---

## 📜 License

MIT License. Free for all use. 🌍
