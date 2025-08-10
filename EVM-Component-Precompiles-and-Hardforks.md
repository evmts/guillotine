## Component Review: Precompiles and Hardfork Configuration

### Scope (key files)

- Precompiles: `src/evm/precompiles/*.zig`
- Hardforks: `src/evm/hardforks/*.zig`
- Constants: `src/evm/constants/*.zig`

### What’s working well

- Wide set of precompiles with specialized implementations (e.g., sha, ripemd, bn254); wrappers for uniform gas/entry.
- Hardfork feature flags and jump table generation based on the target hardfork ensure correct opcode availability.

### Opportunities

1) SIMD and constant‑time
- For hash precompiles, ensure constant‑time behavior and consider SIMD paths (with CPU feature gating) for throughput.

2) Gas models
- Re‑verify gas per precompile vs latest spec and common client implementations; add parity tests.

3) Feature flags audit
- Ensure all Cancun/Shanghai features (e.g., PUSH0, MCOPY, TLOAD/TSTORE) are consistently gated and tested across components.

### Tests/benches

- Add per‑precompile microbench and compare throughput vs evmone/revm baselines when possible.
- Include failure/edge tests (invalid input sizes, zero‑length, maximum length) per precompile.

### Actionable checklist

- [ ] Review constant‑time guarantees and SIMD opportunities for precompiles.
- [ ] Add/update gas parity tests for each precompile.
- [ ] Ensure hardfork gating tests cover opcode availability and behavior changes.

### Comparison to evmone and revm

- evmone/revm: Mature precompile suites; SIMD and fast‑path hashing often present. With constant‑time and SIMD where appropriate, Guillotine can match or exceed throughput.


