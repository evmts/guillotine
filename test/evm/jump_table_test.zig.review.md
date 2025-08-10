## Review: test/evm/jump_table_test.zig

### Coverage assessment

- Tests jump table dispatch and metadata access; includes simple perf sanity via timer.

### Opportunities

- Add assertions around undefined opcodes returning marked `undefined` and safe metadata defaults.
- Validate PUSHn entries are metadata‑only and never executed in runtime paths.

### Action items

- [ ] Add undefined opcode checks and PUSHn non‑execution assertions.


