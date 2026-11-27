# `src/core`

Pure, zero-cost (`inline`) verifiable cores and multi-limb arithmetic routines for Guillotine EVM hot paths.

## Modules

- **`verified_ops.zig`** — Pure scalar, 256-bit word, stack, memory-bounds, jump-table binary search, bytecode JUMPDEST scan, and basic-block stack/gas accumulator kernels (`BlockAccumulator`, `BlockStackResult`). Contains no allocators, `*anyopaque`, indirect function pointers, or tracer side effects so Zig's emitted `-OReleaseFast` LLVM IR and Zig 0.17.1 AIR can be formally verified directly via `verify/llvm/`, `verify/smt/`, `verify/lean/`, and `verify/zean/`.
- **`wide_arith.zig`** — Exact multi-limb division (Knuth TAOCP Vol. 2 Algorithm D + x86_64 `divq` / Hacker's Delight `divlu`) for `DIV`, `SDIV`, `MOD`, `SMOD`, `ADDMOD`, and `MULMOD` with zero runtime calls so `preserve_none` opcode handlers never spill pinned registers.

## Invariants

- Every optimized `Fast` routine pairs with a clear `Ref` specification verified across Bitwuzla/Z3 SMT, LLVM IR equivalence, and Lean 4 (`GuillotineZean`).
- Division by zero yields `0` per the Ethereum Yellow Paper.
- Changes to exported kernels require running `zig build verify` (`verify-ir`, `verify-smt`, `verify-lean`, `verify-zean`) and `zig build test-unit`.
