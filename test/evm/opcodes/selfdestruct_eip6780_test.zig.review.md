## Review: test/evm/opcodes/selfdestruct_eip6780_test.zig

### Coverage assessment

- Confirms EIP‑6780 behavior (restrict destruction to contracts created in same tx). Good fork‑specific behavior.

### Opportunities

- Add tests verifying beneficiary warm/cold cost is charged and static‑context protection is enforced.
- Include a case where contract is pre‑existing: ensure only balance transfer is recorded and no code/storage deletion occurs.

### Action items

- [ ] Add warm/cold and static‑context cases.
- [ ] Add pre‑existing contract case with checks.


