## Review: test/evm/integration/comprehensive_test.zig

### Coverage assessment

- Broad integration flow coverage across opcodes, memory, system calls, and state interactions. Good end‑to‑end validation.

### Opportunities

- Incorporate scenarios with storage‑heavy interactions once SSTORE semantics are implemented (including refunds) to validate journal/revert and gas correctness under realistic workloads.
- Add traces mimicking ERC20 approve/transfer and a simple DeFi path to validate performance‑critical instruction mixes functionally.

### Action items

- [ ] Add storage‑heavy integration scenarios with refunds.
- [ ] Add ERC20 and DeFi‑like flows as separate integration tests.


