## Review: hardforks/chain_rules.zig (chain rules to flags)

### High-signal findings

- Provides mapping from hardfork to runtime-checked flags; complements `EvmConfig`/EIP flags.

### Opportunities

- Add tests asserting each fork’s flags map to expected availability of opcodes (PUSH0, MCOPY, BLOBHASH, BASEFEE, etc.).


