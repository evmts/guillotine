## Review: test/evm/instruction_test.zig

### Coverage assessment

- Tests instruction struct behavior and likely translation invariants.

### Opportunities

- Add cases validating `.dynamic_gas` and `.memory_size` presence consistency for ops that require them; ensure validation step catches misconfigurations.

### Action items

- [ ] Add trait consistency tests for operation entries.


