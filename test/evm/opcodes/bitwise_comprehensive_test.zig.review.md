## Review: test/evm/opcodes/bitwise_comprehensive_test.zig

### Coverage assessment

- Broad coverage across AND/OR/XOR/NOT/SHL/SHR/SAR/BYTE.

### Opportunities

- Add extreme shift counts (≥256) and boundary mask tests; include negative‑looking high‑bit patterns for SAR.

### Action items

- [ ] Add boundary/overflowing shift count cases and assertions.


