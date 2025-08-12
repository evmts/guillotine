## Review: analysis.zig (instruction stream generation, block metadata, and jump resolution)

### High-signal findings

- Generates an instruction stream with injected BEGINBLOCKs, accumulating per-block static gas and stack requirements; front-loads validation cost for interpreter.
- Builds per-PC mappings: `pc_to_instruction`, `pc_to_block_start`, and `inst_to_pc`; provides `inst_jump_type` to signal dynamic jump checks at runtime.
- Converts a JUMPDEST bitmap into a packed `JumpdestArray` (u15 positions) for cache-friendly validation and implements proportional-start linear search for good locality.
- Resolves static jump targets post-translation using PC→BEGINBLOCK mapping; leaves unresolved for dynamic/runtime handling when required.
- Includes light peephole fusions (PUSH+{ADD,SUB,MUL,DIV}) and inlines hot ops (ISZERO, EQ) in debug path with statistics output.

### Gaps and risks

- Some debug logging is present throughout analysis; ensure it is compiled out in ReleaseFast (or behind a flag) to keep decode-time cost low.
- Fusion coverage is limited to a few arithmetic cases; more can be added safely with clear rules.
- `pc_to_block_start` construction searches backward per mapped PC; acceptable for 24KB code but could be accelerated with a forward pass bookkeeping.

### Opportunities

- Extend peephole fusion: DUP/SWAP micro-patterns, PUSH0+ALU, trivial MUL/DIV by power-of-two via shifts where valid, and NOOP elimination.
- Precompute memory word counts and aligned sizes for memory/copy ops when operands are immediate or directly follow PUSH; attach via `Instruction.arg` to remove divisions at runtime.
- Co-allocate hot arrays (`instructions`, `inst_jump_type`, `inst_to_pc`) from a single arena/slab to improve cache locality.
- Emit a minimal debug summary of fusion/optimization counts and instruction sizes; already partly implemented—ensure gated in non-debug builds.

### Action items

- [ ] Gate debug logs and stats under a build flag or `SAFE` so ReleaseFast has zero logging overhead.
- [ ] Add decode-time precompute for memory sizing and expose `.keccak_immediate_size`/`.keccak_precomputed` paths consistently.
- [ ] Expand safe fusion set and include tests with golden traces to confirm functional equivalence and gas invariants.
- [ ] Consider a forward bookkeeping pass to set `pc_to_block_start` in O(n) without backward scans.
- [ ] Co-allocate hot metadata arrays for better D-cache locality.

### Correctness notes

- BEGINBLOCK encapsulates static gas and stack bounds; interpreter consumes this up-front which aligns with spec and reduces per-op checks.
- JUMPDEST validation via packed array is bounded and avoids bitmap scans at runtime.
- Unresolved jumps remain safe, validated dynamically in the interpreter path.

### Comparison to evmone/revm

- Very close to evmone’s advanced analysis model. Implementing broader decode-time enrichment and fusion will close remaining perf gaps; revm relies more on inlining than an instruction stream.


