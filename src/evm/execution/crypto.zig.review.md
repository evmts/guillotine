## Review: execution/crypto.zig (KECCAK256 and related)

### High-signal findings

- Correct stack behavior and memory reading for hashing; per‑word gas adds on top of base.

### Opportunities

- Precompute word counts and aligned sizes at decode time for common immediate cases to avoid divisions per call.
- Ensure large input handling is branch‑light and uses slice reads efficiently.

### Action items

- [ ] Attach precomputed word count for hashing when operands are immediate.
- [ ] Add tests for large/unaligned inputs and gas assertions.

### Comparison to evmone/revm

- Minor runtime overhead can be eliminated with decode‑time preparation; otherwise parity.


