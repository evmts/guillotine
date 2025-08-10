## Review: state/state.zig (world state)

### High-signal findings

- Wraps DB interface for balances, nonce, code, storage, and transient storage. Emits logs via `emit_log` capturing topics/data.

### Opportunities

- Ensure storage getters/setters are zero-alloc on hot paths; avoid copying large code/data slices unnecessarily. Favor references/keys into DB when possible.
- Integrate warm/cold access management via `AccessList` at call sites consistently.


