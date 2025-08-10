## Review: execution/comparison.zig (LT/GT/SLT/SGT/EQ/ISZERO)

### High-signal findings

- Straightforward stack patterns and wrapping semantics. Signed comparisons should use correct bitcasts to i256 for SLT/SGT.

### Opportunities

- Consider inlining ISZERO in hot‑ops set; EQ/ISZERO are common.
- Add randomized property tests that compare signed vs unsigned paths around boundaries (0, 1, max, 2^255−1, 2^255) to harden signed behavior.

### Action items

- [ ] Inline ISZERO (if not already) and consider EQ inlining if traces warrant.
- [ ] Add edge‑focused fuzz tests for signed comparisons.

### Comparison to evmone/revm

- All implementations are near‑identical; minor wins come from inlining and eliminating extra stack traffic.


