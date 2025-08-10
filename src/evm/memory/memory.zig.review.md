## Review: memory/memory.zig (contexted linear memory)

### High-signal findings

- Shared buffer with per‑context checkpoints gives cheap child contexts and avoids copies on calls.
- Memory expansion cost implements quadratic pricing with a LUT for small sizes and cached last calculation for larger sizes.
- API exposes `ensure_context_capacity`, `set_u256`, `get_u256`, and bounded setters that are used prudently by handlers.

### Opportunities

1) Cache word count
- Cache last word count in addition to size to eliminate repeated divisions in sequential expansions.

2) Charge+ensure helper
- Introduce a tiny inline helper: `charge_and_ensure(frame, new_size_u64)` that computes expansion cost, charges gas, and ensures capacity in one branch‑light path to unify usage across handlers.

3) Logging in constructors
- Strip or guard debug logs in `init`/`init_default` in release to keep these paths inlineable and fast.

4) Copy overlap path
- Benchmark a `memmove`‑style unified path for MCOPY vs current forward/backward split; keep the fastest.

### Action items

- [ ] Add last‑words cache and helper for charge+ensure.
- [ ] Remove debug logs from hot constructors in release.
- [ ] Benchmark copy overlap strategies.

### Comparison to evmone/revm

- evmone: Minimizes runtime divisions/branches for memory; we can match with the above.
- revm: Rust slice manipulations are efficient; our pointer model can be just as fast with the right helpers.


