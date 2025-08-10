## Review: stack/stack.zig (u256 pointer-based stack)

### High-signal findings

- Pointer arithmetic design with base/current/limit is ideal for speed; safe/unsafe variants are used correctly by opcode handlers post validation.
- CLEAR_ON_POP in debug/safe modes prevents leakage without affecting release performance.
- Rich test suite covers overflow/underflow, dup/swap, multi-pop operations, and invariants.

### Opportunities

1) Micro-helpers
- Add `peek2_unsafe()`/`peek3_unsafe()` returning a tiny struct of refs/values to avoid extra arithmetic in handlers.
- Replace `std.mem.swap` in `swap_unsafe` with a manual 3‑move swap to avoid function call overhead.

2) Inline guidance
- Consider `@call(.always_inline, ...)` on very small helpers (`append_unsafe`, `pop_unsafe`, `set_top_unsafe`) if benchmarks show benefit.

3) Validation utilities
- Provide a single inline `validate_requirements(min_in, max_out)` helper used by analysis/tests to compute preconditions uniformly.

### Action items

- [ ] Implement `peek2_unsafe()`/`peek3_unsafe()`.
- [ ] Manual swap implementation in `swap_unsafe`.
- [ ] Benchmark always_inline hints for the smallest helpers.

### Comparison to evmone/revm

- evmone: Similar low-level primitives, often inlined aggressively by the compiler; our pointer design is equivalent.
- revm: Borrow-checked Rust slices; performance is comparable when our unsafe helpers are minimal and branch-free.


