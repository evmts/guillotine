---
title: Formal Verification Stack
tags: [verification, lean4, zean, smt]
---

# Formal Verification Stack

Guillotine pairs exhaustive Ethereum spec testing with four complementary formal verification layers, all wired under `zig build verify` and tracked continuously by Uphill (`[[TigerStyle-and-Safety]]`).

## Verification Matrix

| Layer | Scope | Current Result | Command |
| --- | --- | --- | --- |
| Official EEST (`tests@v21.0.3`) | All 14 mainnet forks, Frontier through Osaka, fusions ON and OFF | `66,652 / 66,652` (100%) | `zig build state-tests -Doptimize=ReleaseSafe` |
| Zean Direct Zig AIR -> Lean 4.35.0 | 24 real Zig `0.17.1` kernels in `src/core/verified_ops.zig` | `55` `#audit_proof` theorems, 0 `sorry` | `zig build verify-zean` |
| Hand-Authored Lean 4 Spec | Executable EVM + Layer 2 semantics + differential fuzzer | `116,384 / 116,384` vectors, 0 mismatches | `zig build verify-lean` and `zig build test-lean-diff` |
| Bitwuzla + Z3 SMT-LIB2 | Arithmetic, memory bounds, jump bounds, fusion equivalences | `32 / 32` theorems proved (`unsat`) | `zig build verify-smt` |
| LLVM IR Equivalence | `-OReleaseFast` LLVM IR `Fast` vs `Ref` pairs + poison/UB | `19 / 19` pairs proved | `zig build verify-ir` |

## Dual Zean and Lean 4 Stack

1. **Direct Zig AIR capture (`verify/zean/`, `verify/lean/GuillotineZean/`)**: `okcontract/zean` extracts Zig `0.17.1` AIR directly from `src/core/verified_ops.zig` into Lean `4.35.0` modules (`ScalarOps`, `Word256Ops`, `StackOps`, `JumpBsearch`, `BytecodeJumpdest`, `MemoryCopy`). Every proof is audited with `#audit_proof` to guarantee zero `sorry` and only standard Lean logical axioms.
2. **Executable reference spec (`verify/lean/`)**: Models full EVM state transitions and Base/OP Layer 2 rules independently, then fuzzes the compiled Zig engine against the Lean reference across `116,384` randomized vectors.

## SMT and Compiler IR Pinning

- `verify/smt/model_pins.json` pins every SMT model to exact source digests so any edit to a verified Zig kernel forces re-verification rather than silently drifting.
- `verify/llvm/llvm_ir_verify.py` verifies the actual `-OReleaseFast` LLVM IR emitted by Zig `0.17.1`, catching optimizer UB or poison-value regressions that source-level proofs alone might miss.

## Related Pages

- [[Overview]]
- [[Dispatch-Engine]]
- [[Mythical-History]]
- [[TigerStyle-and-Safety]]
