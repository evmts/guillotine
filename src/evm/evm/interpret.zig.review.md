## Review: evm/interpret.zig (Interpreter over translated instruction stream)

### High-signal findings

- BEGINBLOCK validation (gas, min stack, max growth) is correctly frontloaded. This is the biggest win for branch prediction and should be preserved through refactors.
- Dynamic JUMP/JUMPI uses precomputed `pc_to_block_start` and `valid_jumpdest`; error paths (InvalidJump/OutOfGas) are clean and use `@branchHint(.cold)` appropriately in several places.
- `.none`/`.gas_cost`/`.dynamic_gas` variants keep the main loop simple. The `.dynamic_gas` branch charges static first, then dynamic (with error mapping for OutOfOffset vs OutOfGas) which aligns with expected semantics.

### Opportunities

1) Decode-time enrichment
- Precompute per-op small integers (e.g., memory word counts, aligned sizes) for memory/copy ops when operands are immediate or derived from previous PUSH. Attach via `Instruction.arg` immediates. This removes divisions/casts inside the loop.

2) Metadata locality
- Ensure `instructions`, `inst_jump_type`, and `pc_to_block_start` are allocated from the same slab/arena to improve D‑cache locality during JUMP heavy workloads.

3) Loop micro-structure
- Hoist frequently used analysis references to local `const` aliases (e.g., `const ana = frame.analysis;`) to help Zig’s inliner; keep the loop body branch‑light on the likely path.
- For `.push_value`, consider fusing consecutive PUSHn in analysis into a single instruction to reduce loop overhead in PUSH‑heavy code.

4) Observability
- Current `Log.debug` messages inside the loop (e.g., PUSH and error cases) should be compiled out in release. Wrap behind `if (comptime SAFE)` or a build flag to avoid inhibiting inlining.

### Correctness

- MAX_ITERATIONS guard: useful for debug; consider counting blocks executed instead of raw iterations to better detect stalling.
- When dynamic gas calculator fails with `OutOfOffset`, the mapping to that error is correct; any other error coerced to OutOfGas is reasonable.

### Action items

- [ ] Add decode‑time per‑op memory word counts where predictable; attach as immediates.
- [ ] Co‑allocate instruction array and per‑pc metadata.
- [ ] Strip or guard all hot‑loop logging in release.

### Comparison to evmone/revm

- evmone advanced: Similar block interpreter; performs more decode‑time trait computation and micro‑fusion. Implementing the above will close most gaps.
- revm: Leans on Rust inlining rather than an instruction stream. With decode‑time enrichment, this interpreter will be competitive on branch predictability and cache locality.


