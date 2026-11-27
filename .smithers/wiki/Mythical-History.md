---
title: Mythical History of Guillotine
tags: [history, mythical, epochs]
---

# Mythical History of Guillotine

A mythical history is the clean, linear architectural story you would write if you built today's tree from scratch: small atomic concepts, docs and invariants before optimizations, and honest notes on what was tried, measured, and retired along the way. Every epoch below links directly to the committed subsystems and real milestone commits on `main`.

## Epoch 1: Flat Dispatch Over Switch Loops

Most EVMs execute a `while (pc < code.len) switch (code[pc])` loop. Guillotine started from a different premise: separate bytecode analysis from bytecode execution completely.

- **Core insight**: Contract bytecode is immutable once deployed. Analyze it once into a flat array of 8-byte untagged `Dispatch.Item` entries (`src/preprocessor/dispatch.zig`), batch static gas and stack bounds at basic-block boundaries, and pre-resolve jump tables into a dense bitmap (`src/bytecode/bytecode_analyze.zig`).
- **What this unlocked**: Handler bodies skip per-opcode stack overflow/underflow branches via `_unsafe` stack operations whose preconditions are proved at analysis time (`[[Dispatch-Engine]]`).
- **Retired detours**: Earlier prototypes experimented with larger tagged dispatch structs and 13 speculative multi-opcode fusions that added code size without improving median throughput. All 13 dead fusions were removed (`fe945ea7`, `76479f10`) once benchmarks showed cache-line pressure mattered more than exotic fusion count.

## Epoch 2: Stock Zig 0.17.1 `preserve_none` Tailcalls

Moving from a switch loop to indirect tailcalls still hit a ceiling when ABI prologues spilled hot interpreter state to the stack on every opcode transition.

- **Breakthrough**: Stock Zig `0.17.1` exposed LLVM's native `preserve_none` calling convention. Guillotine defined a unified handler ABI in `src/preprocessor/handler_abi.zig` passing `(frame, cursor, sp, gas, t0, t1, t2, t3)` directly in callee registers (`41cc28e0`, `e91abdd8`, `9038aa65`).
- **Register-cached Top of Stack**: Keeping the top 256-bit EVM stack word pinned in four 64-bit registers (`t0..t3`) with `sp[0]` as its spill slot eliminated redundant memory loads across arithmetic, bitwise, comparison, and control-flow chains.
- **Multi-limb arithmetic without spills**: `src/core/wide_arith.zig` replaced LLVM's slow compiler-rt calls with inline Knuth Algorithm D and x86_64 `divq` so `DIV`/`MOD`/`MULMOD` never clobber the tailcall register set.
- **Evidence**: `1.43x` faster than `revm` on the classic 7-workload interpreter suite on Apple M3 Max and `1.25x` faster on `snailtracer` on x86_64 Linux (`edeacbf3`, `76479f10`).

## Epoch 3: O(1) State, Snapshots, and Bounded Memory

A fast interpreter loses its lead if nested calls thrash the allocator or copy storage maps on revert.

- **O(1) undo-log snapshots**: `src/storage/journal.zig` and `src/storage/database.zig` record reversible mutations in an append-only journal so `REVERT` unwinds in O(changed slots) instead of cloning state.
- **Pooled call frames and memory**: `FrameStackPool` fixed a 4.4 GB leak under deep recursion (`859fbcf7`), and mmap-backed pooled buffers plus an 8,192-entry clock/LRU `DispatchCache` stabilized 100-block mainnet replay (`1138255c`, `1130e4f4`).
- **DatabaseProxy**: Legacy `static_wrappers` were retired and replaced by a single comptime `DatabaseProxy` supporting `pass_through`, `static`, and `lru` modes (`57e7d712`).

## Epoch 4: 100% Mainnet Parity (Frontier Through Osaka) and Base L2

Correctness is the hard release gate (`[[TigerStyle-and-Safety]]`).

- **Official EEST compliance**: `specs/eest_runner.zig` runs the pinned `tests@v21.0.3` official Ethereum Execution Spec Tests (SHA-256 verified by `scripts/fetch-eest-fixtures.sh`). All `66,652 / 66,652` cases pass across all 14 mainnet hardforks (Frontier through Osaka) with bytecode fusions both ON and OFF (`76479f10`).
- **100-block mainnet parity**: Offline replay of 100 contiguous Ethereum mainnet blocks (`26,498,000` to `26,498,099`, `29,560` transactions, `2.97` billion gas) achieved `29,560 / 29,560` (`100.00%`) receipt parity against `revm` (`4bf6a260`, `1130e4f4`).
- **Base and OP Stack Layer 2**: `src/layer2/` brought full Bedrock through Jovian execution (deposits, EIP-2930 access lists, EIP-7702 authorizations, L1 data fees, operator fees, and precompile overrides) onto real fork-configured Guillotine `Evm` instances (`8f55ded2`, `7cec9954`).
- **Native cryptography**: Pure-Zig secp256k1 `ECRECOVER` (`0.171 ms`), SIMD calldata token counting, adaptive Montgomery `MODEXP`, BN254 GLV, BLS12-381 via `blst`, and KZG 4844 via `c-kzg-4844` landed through vendored `lib/voltaire` (`c9eec19a`, `d27d1a33`).

## Epoch 5: Separating `guillotine-mini` and Hardening the Reference Oracle

- **What was retired**: A duplicated `mini/` sub-tree once lived inside this repository, creating drift and double maintenance. In `v0.1.0` (`9637eb56`, `d29ab542`), `mini/` was cleanly separated into its own standalone repository (`evmts/guillotine-mini`), while the lean in-repo differential oracle (`src/tracer/minimal_evm.zig`) stayed locked to `Frame` via `beforeInstruction()` synchronization.
- **Zero-crash hardening**: Every crash surfaced by EEST, multi-threaded havoc fuzzing (`zig build fuzz-campaign`), and Lean differential runs was converted into boundary validation returning typed errors (`7cec9954`, `1138255c`).

## Epoch 6: Dual Formal Verification (SMT + LLVM IR + Lean 4 + Zean)

Testing finds bugs. Formal proofs eliminate entire classes of bugs (`[[Formal-Verification]]`).

- **Layer 1 & 2 (SMT + LLVM IR)**: `32 / 32` Bitwuzla/Z3 SMT-LIB2 bitvector theorems and `19 / 19` LLVM IR equivalence + poison/UB pairs verify arithmetic, memory bounds, and fusion rewrites directly against compiler output (`verify/smt/`, `verify/llvm/`).
- **Layer 3 (Hand-authored Lean 4)**: An executable Lean 4 reference EVM and Layer 2 specification checks `116,384 / 116,384` Zig-to-Lean differential fuzz vectors with zero mismatches (`verify/lean/`).
- **Layer 4 (Zean direct Zig AIR to Lean 4.35.0)**: Commit `f51d0b73` integrated `okcontract/zean`, capturing 24 real Zig `0.17.1` kernels directly from `src/core/verified_ops.zig` into Lean `4.35.0` and closing `55` `#audit_proof`-verified theorems with zero `sorry` and only standard Lean logical axioms.

## Epoch 7: Public Smithers Cloud Coding Factory and `v0.1.0`

- **First beta release (`v0.1.0`, 2026-11-25)**: Shipped native Zig package exports (`evm`, `voltaire`, `layer2`), stripped `ReleaseFast` C FFI libraries for macOS arm64 and Linux x86_64 (`glibc >= 2.28`), `@tevm/guillotine` Bun FFI SDK, and `guillotine.tevm.sh` Vocs documentation (`d37ddba6`, `76479f10`).
- **Uphill Lighthouse backpressure & Smithers Cloud switchover**: Continuous Uphill metrics (`e932a6ca`), granular incremental `smthrs` targets connected to the shared `build.smithers.sh` object store with untrusted-read isolation, personalized Maintainer / Contributor / Viewer home views on `smithers.sh/evmts/guillotine`, public MCP with one-time PKCE auth, this Wiki, and automated merge-to-GitHub releases and docs publishing (`[[Trust-Model-and-Factory]]`).

## Related Pages

- [[Overview]]
- [[Dispatch-Engine]]
- [[Formal-Verification]]
- [[Decisions]]
- [[Trust-Model-and-Factory]]
