## Review: execution/memory.zig (MLOAD/MSTORE/MSTORE8/MSIZE/MCOPY)

### High-signal findings

- Handlers correctly charge expansion gas before touching memory and align expansions to 32 bytes for consistency with gas accounting.
- MCOPY implements overlap‑aware copying (backwards/forwards) and charges both expansion and per‑word copy gas.
- MSIZE returns aligned size, consistent with EVM semantics.

### Opportunities

1) Precompute sizes
- For common patterns where offsets/lengths are immediate or from recent PUSH, analysis can attach word counts and aligned new_size, removing runtime divisions and some branches.

2) Unified charge+ensure
- Factor memory expansion into a small inline helper shared by all memory handlers to ensure identical error mapping and branch patterns.

3) Copy path benchmark
- Benchmark a `memmove`‑style unified implementation against current branchy approach; keep whichever wins on representative traces.

### Action items

- [ ] Add decode‑time word count and aligned sizes where predictable.
- [ ] Add charge+ensure helper and refactor handlers to use it.
- [ ] Benchmark MCOPY overlap strategies.

### Comparison to evmone/revm

- evmone: Removes divisions/branches by leaning on decode‑time; matching that here will likely yield measurable gains.
- revm: Efficient Rust slice operations; we can remain competitive with careful helper design and decode‑time assists.


