## Review: opcode_metadata/opcode_metadata.zig (OpcodeMetadata SoA dispatch)

### High-signal findings (post-comptimeconfigs)

- Centralized struct-of-arrays `OpcodeMetadata` with cache-line alignment for hot fields (`execute_funcs`, `constant_gas`) is ideal for I/D-cache locality. Validation reduced at runtime; generation is compile-time via `operation_config.ALL_OPERATIONS`.
- Hardfork/EIP-flag derived initializers: `init_from_hardfork` and `init_from_eip_flags` produce optimal tables without runtime branching. Good separation of PUSHn inline-executed entries while still supplying metadata.
- `OperationView` provides a compact accessor, avoiding AoS penalties while maintaining a stable API.

### Opportunities

- Consider packing `min_stack`/`max_stack` to u16 if provably sufficient to shrink footprint; or split stack arrays into a cold block loaded during validation only.
- In debug builds, emit a compact metadata audit (opcode → execute ptr hash, gas, min/max, undefined) to catch accidental config regressions.
- For invalid/unavailable opcodes per fork, ensure `undefined_flags` aligns with interpreter behavior and tests cover fork gating.

### Action items

- [ ] Add optional debug audit dump of metadata by hardfork and by EIP flags.
- [ ] Evaluate stack field width and cold-split feasibility.
- [ ] Add tests asserting PUSHn entries are metadata-only (unreachable execute funcs) across forks.

### Comparison to evmone/revm

- Matches evmone advanced’s philosophy: predecoded tables, SoA, minimal branches. revm uses Rust enums/tables; this design should be equally competitive on dispatch throughput.


