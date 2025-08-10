## Review: execution/bitwise.zig (AND/OR/XOR/NOT/SHL/SHR/SAR/BYTE)

### High-signal findings

- Uses wrapping semantics and correct masking for BYTE/shift ops; unsafe stack access keeps handlers tight.

### Opportunities

- Precompute common masks for BYTE and sign propagation for SAR if traces show hotspots.
- Add randomized tests focusing on shift counts ≥256 and edge masks.

### Action items

- [ ] Introduce small precomputed masks for BYTE/SAR inlined constants.
- [ ] Expand fuzz tests for shift edge cases.

### Comparison to evmone/revm

- Similar; tiny wins from constants and inlining.


