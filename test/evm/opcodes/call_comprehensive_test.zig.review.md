## Review: test/evm/opcodes/call_comprehensive_test.zig

### Coverage assessment

- Exercises CALL behavior; good foundation.

### Opportunities

- Add a matrix for args/ret sizes (0, 32, 1024), warm vs cold address, value/no‑value, and low‑gas constraints. Assert forwarded gas according to 63/64 rule and stipend additions.

### Action items

- [ ] Add parametric tests covering matrix and precise gas expectations.


