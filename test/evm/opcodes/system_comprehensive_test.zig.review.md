## Review: test/evm/opcodes/system_comprehensive_test.zig

### Coverage assessment

- Exercises CALL/CREATE/DELEGATECALL/STATICCALL/RETURN/REVERT/SELFDESTRUCT across many scenarios. Strong breadth.

### Opportunities

- Add matrixed tests covering: args/ret sizes (0, 32, 1024), warm vs cold addresses, value vs no‑value, and low‑gas edge cases; assert gas deltas.
- CREATE/CREATE2: include cases with large initcode, boundary sizes (49,152+1), and salt variations.

### Dead/commented code policy

- If any tests are disabled/commented, either re‑enable with fixes or remove to comply with repository cleanliness rules.

### Action items

- [ ] Expand the matrix for CALL and CREATE families; assert gas expectations.
- [ ] Resolve disabled/commented tests.


