## Review: test/evm/opcodes/arithmetic_test.zig

### Coverage assessment

- Covers basic arithmetic correctness (ADD/MUL/SUB/DIV/MOD etc.). Good sanity checks.

### Opportunities

- Add boundary tests: operations with 0, 1, max u256, powers of two, and random pairs to strengthen overflow/underflow handling confidence.
- Signed ops: ensure cases like MIN_I256 / -1 and sign behavior around 2^255 boundaries are present.

### Action items

- [ ] Expand with a small randomized property section (bounded loops) for ALU invariants.


