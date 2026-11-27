---
title: Guillotine Overview
tags: [overview, architecture]
---

# Guillotine Engineering Wiki

Guillotine is a formally verified, register-passing Ethereum Virtual Machine written in stock Zig `0.17.1` with a C ABI (`libguillotine_ffi`) and a Bun FFI TypeScript SDK (`@tevm/guillotine`). It runs in public as a Smithers Cloud coding factory at `https://smithers.sh/evmts/guillotine`.

## System Architecture

```text
+-----------------------------------------------------------------------+
|  Public Surfaces                                                      |
|  Zig dep.module("evm")  |  C ABI (guillotine.h)  |  @tevm/guillotine  |
+-----------------------------------------------------------------------+
                                  |
                                  v
+-----------------------------------------------------------------------+
|  Bytecode Preprocessor & Dispatch Cache (src/preprocessor/)           |
|  - Single-pass analysis into 8-byte untagged Dispatch.Item schedule   |
|  - Basic-block static gas & stack bounds batching (BlockAccumulator)  |
|  - O(1) dense JUMPDEST bitmap & synthetic opcode fusion               |
+-----------------------------------------------------------------------+
                                  |
                                  v
+-----------------------------------------------------------------------+
|  Register-Passing Tailcall Engine (src/frame/, src/instructions/)     |
|  - Stock Zig 0.17.1 preserve_none tailcalls (@call(.always_tail))     |
|  - Top-of-stack u256 cached in 4x u64 registers (t0..t3)              |
|  - Zero-cost comptime EvmConfig & Base/OP Stack Layer 2 (src/layer2/) |
+-----------------------------------------------------------------------+
                                  |
                 +----------------+----------------+
                 v                                 v
+---------------------------------+  +----------------------------------+
|  State, Storage & Crypto        |  |  Verification & Backpressure     |
|  - O(1) undo-log snapshots      |  |  - 66,652/66,652 EEST (100%)     |
|  - Pooled stack/memory buffers  |  |  - 55 Zean Lean 4.35 proofs      |
|  - Voltaire native precompiles  |  |  - 116,384 Zig-Lean diff vectors |
|  - Opt-in ARM64 JIT (src/jit/)  |  |  - 32 SMT + 19 LLVM IR proofs    |
+---------------------------------+  +----------------------------------+
```

## Reading Guide

- Start with [[Mythical-History]] for the clean epoch-by-epoch narrative of how Guillotine's design evolved from first principles to `v0.1.0`.
- Read [[Dispatch-Engine]] to understand why `Frame` has no `pc` field and how `preserve_none` tailcalls eliminate interpreter loop overhead.
- Read [[Formal-Verification]] for the dual Zean + Lean 4, Bitwuzla/Z3 SMT, LLVM IR, and EEST verification layers.
- Read [[TigerStyle-and-Safety]] for our zero-crash invariant, `_unsafe` pre-validation contract, and Uphill Lighthouse audit backpressure.
- Read [[Trust-Model-and-Factory]] for how Smithers Cloud runs CI, isolates untrusted contributor runs from the shared `build.smithers.sh` object store, serves public MCP, and automates releases.
- Read [[Decisions]] for architectural decision records and rejected alternatives.
- Read [[SDKs-and-ZEVM]] for how Guillotine integrates with `evmts/zevm`, `evmts/voltaire`, C, and TypeScript.
