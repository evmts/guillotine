## Review: test/evm/memory_leak_test.zig

### Coverage assessment

- Ensures no leaks across operations/transactions; valuable guard.

### Opportunities

- Include stress with many journal entries and large logs to verify cleanup paths.
- Add multiple transaction loops to simulate lifecycle (state clear, transient clear, logs cleared each tx).

### Action items

- [ ] Add stress variants and multi‑tx loops.


