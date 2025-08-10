## Component Review: Testing and Benchmarks

### Scope (key areas)

- Unit tests: `test/evm/**/*.zig` covering opcodes, system calls, memory, gas, journal, integration flows
- Benchmarks: `bench/` and official harness integrations

### What’s working well

- Very broad test coverage with explicit, no‑abstraction style matching project rules. Many fuzz/differential style tests for state/memory.
- CALL/CREATE gas forwarding, warm/cold behavior, and memory expansion are all tested with thoughtful edge cases.

### Opportunities

1) SSTORE test suite
- Add an exhaustive matrix for SSTORE transitions and refunds, and parity with official vectors (post implementation).

2) Microbench coverage
- Add focused microbenches for:
  - Inline vs function‑pointer dispatch per hot opcode
  - Memory expansion cache hit rate and cost
  - COPY/MCOPY variants (aligned/unaligned, overlap patterns)
  - CALL matrix (value/no‑value × warm/cold × args/ret sizes)

3) Trace‑based benches
- Use canonical traces (ERC20 hot functions, DeFi inner loops, keccak loops) to measure end‑to‑end throughput and variance.

### Actionable checklist

- [ ] Build SSTORE test matrix parity.
- [ ] Add microbench suite for interpreter and memory paths.
- [ ] Integrate trace‑based benches and record baselines.

### Comparison to evmone and revm

- evmone/revm: Both maintain strong benchmark suites; evmone’s advanced interpreter shines on block‑validated streams. With microbenches and trace tests added, Guillotine can tune to parity and document improvements.


