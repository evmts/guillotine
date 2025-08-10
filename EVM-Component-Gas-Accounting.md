## Component Review: Gas Accounting and Dynamic Costs

### Scope (key files)

- `src/evm/gas/dynamic_gas.zig` — dynamic gas calculators for CALL/CREATE/etc.
- `src/evm/constants/*` — gas constants and limits
- Gas applications within handlers: `execution/system.zig`, memory ops, etc.

### What’s working well

- EIP‑150 forwarding rule and stipend math implemented with unit tests (including nested call behavior and edge conditions).
- Memory expansion gas matches the quadratic formula; caching/LUT reduces repeat computation.
- EIP‑2929 warm/cold charges applied for account accesses in CALL family and selfdestruct beneficiary.

### Opportunities

1) SSTORE gas/refund
- Implement full EIP‑2200/3529 accounting. Track refunds (if refunds tracked elsewhere, still compute and expose as needed).

2) Decode‑time gas rollups
- When operands are immediate (e.g., PUSH‑driven COPY sizes), precompute static/deterministic dynamic components at analysis time and store them in `BlockInfo` or instruction immediates.

3) Memory gas caching
- Cache by last “word count” as well as size to eliminate two divisions in successive expansions.

4) Uniform interfaces
- Centralize “charge memory expansion” into a tiny inline helper to ensure consistent order (charge → ensure capacity) and error mapping across ops.

### Tests/benches

- Add SSTORE transition/refund parity tests; integrate official vectors.
- Microbench: memory expansion cost hit rate; CALL gas matrix (value/no‑value × warm/cold × args/ret sizes).

### Actionable checklist

- [ ] Implement SSTORE gas/refund.
- [ ] Add helper for expansion charge+ensure; apply across all memory‑touching handlers.
- [ ] Precompute gas components in analysis where possible.

### Comparison to evmone and revm

- evmone: Aggressively precomputes gas components where possible; we can match by rolling deterministic parts into decode time.
- revm: Precise SSTORE semantics and refunds; parity here is required for both correctness and performance perceptions.


