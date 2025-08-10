## Review: test/evm/opcodes/memory_test.zig

### Coverage assessment

- Validates MLOAD/MSTORE/MSTORE8/MSIZE basics. Good baseline.

### Opportunities

- Add tests for large offsets requiring expansion and verify gas consumption matches expected growth.
- Add MCOPY overlap specific tests (forward and backward overlap windows) and unaligned sizes.

### Action items

- [ ] Create overlap/unaligned MCOPY cases and assert memory content post copy.
- [ ] Add gas assertions for multiple expansion steps.


