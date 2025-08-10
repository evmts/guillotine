## Review: execution/storage.zig (SLOAD/SSTORE/TLOAD/TSTORE)

### High-signal findings

- TLOAD/TSTORE (transient storage) should be cheap and always warm; confirm current implementation routes through the transient map with constant costs.
- SLOAD likely integrates EIP‑2929 warm/cold pricing via access list—ensure this is consistent across all call contexts.

### Critical gap: SSTORE semantics

- Implement EIP‑2200/3529 in full:
  - Distinguish (original, current, new) value transitions.
  - Warm vs cold cost (EIP‑2929).
  - Net‑new vs reset‑to‑zero, and refund calculations (bounded, with EIP‑3529 adjustments).
  - Journal previous values for precise revert behavior and refund unwinding.

### Tests

- Add a comprehensive transition matrix and refund accounting tests; parity with official vectors.
- Randomized sequences mixing SLOAD/SSTORE/TLOAD/TSTORE to assert invariants and refunds remain within bounds.

### Action items

- [ ] Complete SSTORE gas/refund implementation and tests.
- [ ] Ensure SLOAD warm/cold cost paths are uniform and measured.

### Comparison to evmone/revm

- Both have mature SSTORE semantics. Achieving feature parity is essential for correctness and for matching storage‑heavy workload performance.


