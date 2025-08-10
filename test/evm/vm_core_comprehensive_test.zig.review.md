## Review: test/evm/vm_core_comprehensive_test.zig

### Coverage assessment

- Validates context init defaults, VM init across hardforks, control flow (JUMP/JUMPDEST), execution loop gas tracking, depth tracking, static context handling, and invalid opcode behavior. Strong baseline.

### Opportunities to strengthen

- Add tests asserting no logging occurs in release builds (guarded by a compile‑time flag) to prevent regressions in hot paths.
- Add coverage for block interpreter path if/when re‑enabled (commented as known hang). Either: fix and re‑enable, or remove dead code/tests to keep suite clean per repo policy.

### Action items

- [ ] Resolve commented/disabled tests: re‑enable with fixes, or remove.
- [ ] Add a simple performance sanity test (non‑benchmark) to catch egregious slowdowns (e.g., max steps limit ensures termination in debug).

### Validity

- Assertions align with EVM semantics for the cases present; gas used/left checks are sensible.


