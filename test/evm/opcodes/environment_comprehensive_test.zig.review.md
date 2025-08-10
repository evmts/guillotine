## Review: test/evm/opcodes/environment_comprehensive_test.zig

### Coverage assessment

- Broad checks for env opcodes (ADDRESS, BALANCE, ORIGIN, CHAINID, BASEFEE, etc.). Solid.

### Opportunities

- Add fork‑gating tests ensuring PREVRANDAO and BASEFEE availability match the configured hardfork.
- Add warm/cold cost checks for BALANCE and EXTCODE* family.

### Action items

- [ ] Fork gating assertions per opcode.
- [ ] Warm/cold cost assertions with access list control.


