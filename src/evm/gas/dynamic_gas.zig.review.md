## Review: gas/dynamic_gas.zig (dynamic gas calculators)

### High-signal findings

- CALL/DELEGATECALL/STATICCALL/CREATE/CREATE2 calculators compute memory expansion and warm/cold costs; return a consolidated u64 for the interpreter to charge.
- Bounds checks map to `OutOfOffset` as needed, while other errors are coerced at higher layers (consistent with interpreter usage).

### Opportunities

1) SSTORE calculator
- Implement SSTORE dynamic gas in a dedicated function with the EIP‑2200/3529 transitions (original/current/new) and refund signaling.

2) Decode‑time hints
- Where arguments are immediate/predictable, store precomputed ends (args_end/ret_end) to reduce duplicate arithmetic in calculators.

3) Consolidation
- Provide a single helper to compute memory expansion cost for two regions and return the max (args vs ret) to reduce repeated code.

### Action items

- [ ] Implement SSTORE dynamic gas with full transition/refund semantics.
- [ ] Add helpers for two‑region expansion max and reuse across call calculators.
- [ ] Precompute predictable ends during analysis and attach to instruction.

### Comparison to evmone/revm

- evmone: Leans on decode‑time prepared sizes; adding that will reduce calculator overhead.
- revm: Precise SSTORE semantics; achieving parity here is essential for storage‑heavy scenarios.


