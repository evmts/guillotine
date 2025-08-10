## Review: test/evm/gas/dynamic_gas_test.zig

### Coverage assessment

- Validates dynamic gas calculators for CALL/CREATE memory expansion and warm/cold accesses. Good targeted coverage.

### Opportunities

- Add explicit EIP‑150 forwarding expectations for nested calls with varied already‑consumed gas and requested gas.
- Include stipend edge cases (requested gas small/zero with value transfer) to assert stipend addition is correct and not deducted from caller.

### Action items

- [ ] Add nested call 63/64 tests with precise expected gas values.
- [ ] Add stipend edge tests (0 requested, low requested).


