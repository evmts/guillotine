## Review: test/evm/precompiles/sha256_test.zig

### Coverage assessment

- Functional correctness for SHA256 precompile.

### Opportunities

- Add boundary sizes (0, 1, 32, 33, 1024, large) and assert gas pricing matches per‑word model.
- Include invalid/empty inputs and compare against expected behavior.

### Action items

- [ ] Add boundary size cases with gas assertions.


