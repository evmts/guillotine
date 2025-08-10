## Review: test/evm/opcodes/crypto_comprehensive_test.zig

### Coverage assessment

- Validates KECCAK256 and related crypto op behaviors across input sizes.

### Opportunities

- Add large input boundaries and unaligned sizes; verify gas per word is correct.
- Compare precompile vs opcode paths where applicable (e.g., keccak vs SHA precompiles are different ops but ensure suite spans both areas).

### Action items

- [ ] Add large/unaligned input tests and gas assertions.


