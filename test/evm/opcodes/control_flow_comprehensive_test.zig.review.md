## Review: test/evm/opcodes/control_flow_comprehensive_test.zig

### Coverage assessment

- Validates various control‑flow sequences; good interaction with analysis data (jumpdest, block boundaries).

### Opportunities

- Add regression tests for invalid jump to non‑dest, jump into middle of PUSH data, and large jump tables to exercise `pc_to_block_start` bounds.

### Action items

- [ ] Add invalid and edge control flow cases per above.


