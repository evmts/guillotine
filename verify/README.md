# Guillotine Formal Verification Suite

Guillotine uses a **3-layer formal verification stack** designed specifically to unlock aggressive, zero-overhead EVM optimizations in Zig (`-OReleaseFast`, eliminated runtime checks, branchless 256-bit arithmetic, direct-threaded O(1) jump dispatch, and verified superinstructions) without risking consensus bugs or undefined behavior.

## Quick Start

From the repository root:

```sh
# Run the entire formal verification suite (unit tests + LLVM 20 IR + SMT-LIB2 + Lean 4)
zig build verify

# Run individual layers:
zig build verify-ir     # Layer 1: Direct compiled Zig ReleaseFast LLVM 20 IR -> Bitwuzla/Z3
zig build verify-smt    # Layer 2: Replayable SMT-LIB2 proofs (Bitwuzla/Z3) + opcode table audit
zig build verify-lean   # Layer 3: Machine-checked Lean 4 proofs (54 theorems, zero sorry)
```

## Architecture

### Layer 1 — Direct Compiled Zig LLVM 20 IR Verification (`verify/llvm/`, `verify/zig/`)
- **What it verifies:** The **actual optimized LLVM 20 IR** emitted by `zig build-obj -fllvm -OReleaseFast` from [verify_exports.zig](zig/verify_exports.zig), which directly imports Guillotine's production pure cores in [src/verified_ops.zig](../src/verified_ops.zig).
- **Zero translation gap:** No manual re-encoding of Zig code — [llvm_ir_verify.py](llvm/llvm_ir_verify.py) parses Zig's emitted LLVM 20 SSA IR directly, models Alive2 value-level `poison`/`UB` semantics (`nuw`, `nsw`, `exact`, `disjoint`, `nneg`, `samesign`, `select` poison masking, out-of-range shifts, div-by-zero, `unreachable`), and proves **bit-exact functional equivalence** and **UB/poison freedom** for all inputs using **Bitwuzla** (primary) and/or **Z3**.
- **23 compiled Zig IR pairs verified:** `abs_two_comp_{lo,hi}`, `align_up_32`, `block_stack_guard`, `byte_{lo,hi}`, `check_memory_bounds_{dyn,word32,byte1}`, `clz_{lo,hi}`, `dense_jump_bounds_{u16,u32}`, `exp_gas_byte_len`, `memory_word_count`, `sar_{lo,hi}`, `sdiv_sign_{lo,hi}`, `signextend_{lo,hi}`, `smod_sign_{lo,hi}`.

### Layer 2 — Standalone SMT-LIB2 Proof Suite (`verify/smt/`)
- [run_smt_suite.py](smt/run_smt_suite.py) generates self-contained, human-readable `.smt2` proof artifacts under `verify/smt/proofs/` and discharges them via **Bitwuzla** and **Z3**.
- Covers all 256-bit arithmetic/bitwise optimizations (including fully branchless `SDIV`/`SMOD` under `QF_UFBV`), memory bounds/word-rounding/quadratic gas monotonicity, basic-block stack guard equivalence, dense jump bounds, all synthetic fusion stack equivalences, and a direct parser audit of `src/opcodes/opcode_data.zig` against the Ethereum specification.

### Layer 3 — Machine-Checked Lean 4 Proof Suite (`verify/lean/`)
- Self-contained Lean 4 (`v4.32.0`) package (`GuillotineVerify`) with **zero external dependencies**, **zero `sorry`**, and **only Lean's standard axioms** (`propext`, `Classical.choice`, `Quot.sound`).
- **54 machine-checked public theorems** across 6 modules:
  - `GuillotineVerify.BasicBlock`: Unbounded inductive `block_sound` theorem for arbitrary-length basic blocks, `block_sound_of_zig_metadata`, `saturated_gas_counterexample`, `blockStackGuardFast_eq_ref`, `clampedMinMax_sound`.
  - `GuillotineVerify.Arithmetic`: Bit-exact `BitVec 256` proofs (`expGasByteLenFast_eq_ref`, `signextendFast_eq_ref`, `sarFast_eq_ref`, `byteFast_eq_ref`, `clzFast_eq_ref`, `absTwoComp_eq_abs`, `sdivFast_eq_ref`, `smodFast_eq_ref`, and zero / `MIN_SIGNED / -1` edge cases).
  - `GuillotineVerify.Memory`: `checkMemoryBoundsFast_eq_ref` (dynamic, 32-byte, 1-byte), `alignUp32_eq_ceil_mult32`, `alignUp32_no_overflow`, `memoryWordCountFast_eq_ref`, `memoryGasCost_mono`, `memoryGasCost_no_overflow`.
  - `GuillotineVerify.JumpTable`: `denseLookup_eq_bsearch` (proving O(1) dense lookup equals binary search for every PC) and `denseJumpInBoundsFast_eq_ref`.
  - `GuillotineVerify.Fusions`: Small-step weak bisimulation (`execFused_eq_execSeq`, including exact first stack error preservation) for `PUSH+{ADD,SUB,MUL,AND,OR,XOR}`, `ISZERO+PUSH+JUMPI`, `PUSH+ADD+DUP1`, `SWAP1+DUP2+ADD`, and `PUSH1+PUSH1+{ADD,SUB,MUL}` constant folding.
  - `GuillotineVerify.Stack`: Downward-growing pointer stack invariant preservation (`push`, `pop`, `binary_op`, `dup_n`, `swap_n`, `stack_block_preserves`).

## Forward Path: Zig 0.17 & `okcontract/zean`

`src/verified_ops.zig` is intentionally written in a pure, direct-call, `*anyopaque`-free, allocator-free Zig subset that passes `zig ast-check` under both **Zig 0.15.2** and **Zig 0.17.1**. Once Guillotine upgrades its toolchain to Zig 0.17.x, `src/verified_ops.zig` can be captured directly via `okcontract/zean` (Zig AIR -> Lean 4) to bridge source-level AIR models straight into `GuillotineVerify` and Lean 4 EVM reference semantics (`EVMYulLean` / `Blanc`).
