# `src/jit`

Opt-in, zero-dependency native JIT compiler targeting AArch64 (and x86_64 emitter primitives) for pure, side-effect-free EVM bytecode.

## Modules

- **`root.zig`** — Public API (`Program`, `Options`, `compile`, `JitCache`, `ExitCode`, `JitContext`) and runtime limits (`stack_capacity = 1024`, `instruction_limit = 300_000_000`).
- **`compiler.zig`** — Lowers supported pure computation, memory, calldata, control-flow, and `RETURN`/`REVERT` opcodes into native machine code.
- **`arm64_emitter.zig`** / **`x86_64_emitter.zig`** — Direct machine-code instruction emitters.
- **`jit_mem.zig`** — Executable memory allocation with W^X protection (`MAP_JIT` / `mprotect`).
- **`jit_cache.zig`** — Bounded LRU cache for compiled native programs.

## Invariants

- Depends only on Zig `std` and `builtin`.
- Side-effect-free scope: no storage, logs, external calls, or contract creation. On `ExitCode.fallback` or `null` compilation, the host re-executes the call in the dispatch interpreter with identical state and gas results.
- Gated behind `EvmConfig.enable_native_jit`. Run `zig build test-jit` on macOS arm64 to verify.
