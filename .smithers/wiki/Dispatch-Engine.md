---
title: Dispatch Engine and Tailcall Execution
tags: [architecture, dispatch, performance]
---

# Dispatch Engine and Tailcall Execution

Guillotine does not run a bytecode interpreter loop. Instead, bytecode is preprocessed once into an executable schedule of 8-byte dispatch items and driven via register-passing tailcalls.

## Schedule Layout

`src/preprocessor/dispatch.zig` compiles raw EVM bytecode into a contiguous array of `Dispatch.Item` values:

1. **Function pointers** to opcode handlers (regular or synthetic fused ops).
2. **Inline metadata** embedded directly after handlers (`first_block_gas`, `push_inline`, `jump_dest`, `jump_static`), eliminating runtime bytecode indexing and branch mispredictions.
3. **Dense JUMPDEST bitmap** (`src/bytecode/bytecode_analyze.zig`) plus sorted jump-target lookup (`src/core/verified_ops.zig`) for O(1) dynamic jump validation.

Because metadata items share the schedule array, **a Frame cursor is a schedule pointer, never a bytecode PC**. Translating back to canonical EVM PCs for tracing or `PC` opcode execution happens through `src/tracer/pc_tracker.zig`.

## Basic-Block Pre-Validation

At every basic-block entry (frame start, `JUMPDEST`, and untaken `JUMPI` fallthrough), `BlockAccumulator` (`src/core/verified_ops.zig`) computes:

- `gas`: saturating static gas sum for the block.
- `min_stack`: minimum signed prefix stack depth (required incoming items).
- `max_stack`: maximum signed prefix stack growth (required spare headroom).

Checking `[min_stack, capacity - max_stack]` and subtracting block `gas` once per block guarantees that every `_unsafe` stack operation inside the block is memory-safe by construction (`[[TigerStyle-and-Safety]]`).

## `preserve_none` Register-Passing ABI

`src/preprocessor/handler_abi.zig` defines the handler signature:

```zig
fn (
    frame: *FrameType,
    cursor: [*]const Dispatch.Item,
    sp: [*]WordType,
    gas: FrameType.GasType,
    t0: u64,
    t1: u64,
    t2: u64,
    t3: u64,
) callconv(handler_abi.handler_cc) ExitCode
```

- `t0..t3` hold the top-of-stack `u256` word in four 64-bit registers (`sp[0]` is its backing spill slot).
- Every handler exits via `@call(.always_tail, ...)` to the next handler, keeping the hot state pinned in registers with zero prologue/epilogue spills.
- On LLVM x86_64 and aarch64, `preserve_none` cannot return a Zig error union directly, so handlers return a compact `ExitCode` mapped back by `errorFromExit`.

## Synthetic Opcode Fusion and Differential Sync

Common sequences (`PUSH+ADD`, `PUSH+SUB`, `PUSH+MUL`, `PUSH+MSTORE`, `ISZERO+PUSH+JUMPI`, `DUP+MSTORE`, inline multi-limb `PUSH9` through `PUSH32`) collapse into single handlers in `src/instructions/handlers_*_synthetic.zig`.

When the debug tracer is active, every handler calls `beforeInstruction(opcode, cursor)`. `src/tracer/minimal_evm_sync.zig` steps the sequential `MinimalEvm` oracle by the exact number of primitive opcodes represented by a synthetic handler (e.g., 2 steps for `PUSH_MSTORE_INLINE`, 3 steps for `ISZERO_PUSH_JUMPI`) and verifies identical stack, memory, and gas state.

## Related Pages

- [[Overview]]
- [[Formal-Verification]]
- [[TigerStyle-and-Safety]]
- [[Decisions]]
