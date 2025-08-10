## Review: execution/arithmetic.zig (ADD/MUL/SUB/DIV/SDIV/MOD/SMOD/ADDMOD/MULMOD/EXP/SIGNEXTEND)

### High-signal findings

- Uses wrapping arithmetic and `U256` helpers for mul/div/mod variants; stack access patterns are efficient (pop_unsafe + set_top_unsafe).
- EXP dynamic gas charging based on exponent byte length is implemented inline; early exits for common cases reduce work.

### Opportunities

1) Micro-fusion paths
- Analysis can fuse short sequences (e.g., PUSH/PUSH/ADD) into a single instruction to cut dispatch overhead in arithmetic‑heavy blocks.

2) SDIV/SMOD corner cases
- Ensure tests cover MIN_I256 / -1 and sign rules thoroughly (some tests exist; expand randomized coverage).

3) U256 conversions
- Where `U256` helpers are used, validate they inline well; consider specialized minimal helpers for hot combinations (e.g., wrapping_mul to u256 directly) if compile output shows overhead.

### Action items

- [ ] Add fusion for simple PUSH/PUSH/ALU sequences in analysis.
- [ ] Expand signed arithmetic fuzz coverage (edge cases enumerated in comments).

### Comparison to evmone/revm

- evmone: ALU ops are very tight, often with decode‑time fusion in hot blocks; proposed fusion closes gap.
- revm: Rust inlining typically produces tight code; with fused micro‑ops and pointer stack, parity is expected.


