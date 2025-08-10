## Review: test/evm/opcodes/storage_test.zig

### Coverage assessment

- Basic SLOAD/SSTORE correctness likely covered; ensure warm/cold distinctions are present.

### Critical additions needed

- Add SSTORE transition/refund matrix after EIP‑2200/3529 implementation: original/current/new value combinations, net‑new vs reset‑to‑zero, warm/cold costs, refund bounding.
- Ensure journaling + revert restores storage correctly across nested snapshots.

### Action items

- [ ] Implement exhaustive SSTORE tests and refund accounting assertions.
- [ ] Add warm/cold SLOAD cost assertions using access list behavior.


