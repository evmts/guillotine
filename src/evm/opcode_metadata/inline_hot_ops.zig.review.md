## Review: opcode_metadata/inline_hot_ops.zig (Inline hot opcode execution)

### High-signal findings

- Inlines PUSH1/PUSH2, DUP1/DUP2, ADD, MLOAD/MSTORE, POP, SWAP1, ISZERO with validation and gas charging. This removes function-pointer indirection for common ops and enables better inlining.
- Correctly handles partial push data and memory expansion for MLOAD/MSTORE inlined paths.

### Opportunities

- Factor memory expansion into a tiny helper to unify with non-inlined handlers and reduce duplication/error risk.
- Consider also inlining EQ if traces show it’s hot enough, and potentially DUP3/SWAP2 as a next tier.
- Ensure no logging on hot paths in release builds; add a compile-time guard.

### Action items

- [ ] Introduce `charge_and_ensure_memory(frame, new_size)` inline helper.
- [ ] Evaluate adding EQ/DUP3/SWAP2 to the inlined set based on traces.
- [ ] Add tests to assert identical semantics with regular handlers over randomized inputs.

### Comparison to evmone/revm

- Mirrors evmone’s advanced inline paths; likely to match or exceed when memory helpers are unified and branch patterns are minimized.


