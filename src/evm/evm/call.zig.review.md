## Review: evm/call.zig (top-level call entry and frame wiring)

### High-signal findings

- Sets up frames, snapshots, access list warming, and invokes interpreter; clean separation of static vs non-static.

### Opportunities

- Ensure all early-error paths revert to snapshot and free frame; add tests for OOG during memory expansion and for static violations.
- Prewarm caller/recipient addresses when permitted to reduce cold costs in common paths.

### Action items

- [ ] Add edge-case tests for snapshot/revert correctness across nested calls.
- [ ] Prewarm common addresses (self, caller) per fork rules.

### Comparison to evmone/revm

- Similar orchestration; ensure no unnecessary logging or branching in hot call setup for parity.


