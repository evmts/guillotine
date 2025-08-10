## Component Review: Memory and Stack

### Scope (key files)

- Memory: `src/evm/memory/*.zig` (context, read, write, slice, constants)
- Stack: `src/evm/stack/stack.zig`, `src/evm/stack/stack_validation.zig`

### What’s working well

- Memory shared‑buffer with per‑context checkpoints is efficient for calls; expansion cost uses LUT and caching.
- Stack uses pointer arithmetic; safe/unsafe split enables minimal overhead in hot paths; extensive tests for invariants and boundaries.

### Opportunities

1) Memory expansion micro‑opts
- Cache last word count along with last size; make helper for charge+ensure to eliminate repeated patterns and mistakes.

2) Copy paths
- For MCOPY and *COPY ops, unify on a branch‑light memmove strategy if it benchmarks better than current overlap checks. Keep current logic if it’s faster.

3) Stack utility helpers
- Add `peek2_unsafe()`/`peek3_unsafe()` and an inline manual swap to avoid `std.mem.swap` overhead.

4) Logging
- Remove/guard any logs in memory init paths in release builds to preserve inlining.

### Tests/benches

- Microbench: alternating push/pop/dup/swap sequences; large unaligned MCOPY; many small expansions.
- Fuzz tests already strong; add randomized overlap cases for MCOPY and long COPY loops.

### Actionable checklist

- [ ] Memory charge+ensure helper and last‑words cache.
- [ ] Stack small helpers for common multi‑peek patterns.
- [ ] Benchmark memmove‑style copy vs branchy overlap handling.

### Comparison to evmone and revm

- evmone: Heavy emphasis on removing divisions/branches in copy/memory ops; precompute word counts where possible.
- revm: Efficient slice handling via Rust; our pointer‑based stack can be on par if helpers are tuned and logs are stripped from hot paths.


