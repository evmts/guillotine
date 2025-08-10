## Review: execution/control.zig (JUMP/JUMPI/PC/STOP/JUMPDEST)

### High-signal findings

- Control flow is largely handled at interpreter level via analysis (valid jumpdest and block mapping), minimizing handler work.
- STOP is a terminal signal mapped via error/return path from execute call—consistent with interpreter handling.

### Opportunities

- Ensure PC reads are cheap: if PC is a frequent op, consider carrying current PC through a local in the interpreter loop and exposing it via a tiny getter to avoid recomputing per call.

### Action items

- [ ] Verify PC path uses minimal arithmetic; consider interpreter‑provided cached PC when hot.

### Comparison to evmone/revm

- Similar: both push JUMP complexity to decode/validate stage.


