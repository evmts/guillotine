## Review: analysis.zig (translation and metadata generation)

### High-signal findings

- Produces instruction stream and per‑pc metadata necessary for safe and fast interpretation; block construction amortizes validation costs.

### Opportunities

- Precompute memory word counts and aligned sizes for memory/copy ops when operands are immediate or from recent PUSH.
- Peephole fusion for common sequences (PUSH/PUSH/ALU, DUP/SWAP patterns, MLOAD/MSTORE roundtrips).
- Attach fusion and memory sizing hints into `Instruction.arg` to eliminate runtime divisions/branches.

### Action items

- [ ] Implement memory sizing precompute and fusion passes (lightweight).
- [ ] Emit simple stats in debug builds to observe fusion rates and analysis cost.

### Comparison to evmone/revm

- evmone does exactly this class of decode‑time work; matching it will close runtime overhead gaps. revm relies more on inlining; our approach will excel on predictable streams.


