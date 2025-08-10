## Component Review: Opcode Handlers

### Scope (key files)

- `src/evm/execution/*.zig` — arithmetic, bitwise, comparison, control, environment, memory, log, storage, system, block
- `src/evm/opcodes/operation.zig`, `src/evm/jump_table/operation_config.zig` — function signatures/metadata and config

### What’s working well

- Handlers use unsafe stack operations post validation; avoid redundant checks.
- Arithmetic operations leverage wrapping arithmetic and `U256` helpers where needed (e.g., mulmod/addmod).
- Memory ops perform expansion charging before writes/reads and handle overlap in MCOPY.
- System ops encapsulate complex gas and state interactions cleanly.

### Opportunities

1) SSTORE semantics (critical)
- Implement EIP‑2200/3529 gas/refund logic: warm/cold read, original vs current, net‑new and clear‑to‑zero paths, refund accumulation.

2) Hot‑op inlining expansion
- DUP/SWAP families can be inlined where profitable (some already are through jump table). Consider inlining a few more frequent variants (e.g., DUP2/SWAP1) based on trace data.

3) Micro‑specializations
- For ALU ops that immediately feed into MSTORE, consider a fused handler emitted by analysis (see analysis review).

4) Error uniformity
- Ensure memory/offset errors use a uniform error set (`InvalidOffset` vs `OutOfOffset`) for predictable handling by the interpreter.

### Testing additions

- Add comprehensive SSTORE test matrix (all value transitions vs original/current) and refund accounting parity.
- Add randomized MCOPY overlap tests and CALL*COPY/RETURNDATA*COPY large/unaligned copies.

### Actionable checklist

- [ ] Implement SSTORE dynamic gas/refund; add tests.
- [ ] Audit error types for uniformity across memory‑touching ops.
- [ ] Trace‑driven decision on expanding inline hot‑ops beyond current set.

### Comparison to evmone and revm

- evmone: Rich set of micro‑specialized handlers and decode‑time prepared parameters; we should match by attaching precomputed sizes and offering a few fused ops.
- revm: Very complete SSTORE implementation and refund handling; matching this is required for parity on storage‑heavy workloads.


