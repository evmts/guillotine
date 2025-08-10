## Component Review: Opcode Metadata and Configuration (Comptime)

### Scope (key files)

- `src/evm/jump_table/jump_table.zig` (renamed conceptually to `OpcodeMetadata` in comptimeconfigs), `src/evm/jump_table/operation_config.zig`
- `src/evm/opcodes/operation.zig`, `src/evm/opcodes/opcode.zig`
- Hardfork gating in `jump_table.init_from_hardfork`

### What’s working well (post‑comptimeconfigs)

- Struct‑of‑arrays design with cache‑line alignment for hot fields (execute func, constant gas, min/max stack) and cold fields (dynamic gas, memory size, undefined flags).
- Centralized `EvmConfig`/`EipFlags` drive hardfork features and L2 overrides; `OpcodeMetadata.init_from_hardfork` produces a single, optimal table with compile‑time validation of metadata consistency. [pr488]
- Metadata entries for PUSHn handled correctly (unreachable handlers with inline execution at interpreter level).

### Opportunities

1) Table generation diagnostics
- Emit (debug‑only) a report of opcode traits per hardfork to catch config regressions.

2) Inline hot‑ops selection
- Make the set of inlined hot ops in `inline_hot_ops.zig` configurable per build/target; consider including DUP2/SWAP1 if traces justify.

3) Trait compression
- Consider packing min/max stack deltas into small integers and compute absolute limits at decode time; reduces table footprint.

4) PUSH fusion hinting
- During table generation, tag PUSH opcodes with a “fusable” bit to simplify analysis peepholes.

### Actionable checklist

- [ ] Add a debug report for opcode traits per hardfork.
- [ ] Parameterize inlined hot ops; back by trace data.
- [ ] Evaluate trait packing to reduce cache footprint.

### Comparison to evmone and revm

- evmone: Small, constexpr‑like descriptors with heavy decode‑time use; with the new compile‑time config and validation, we’re aligned. Adding a few generation‑time hints will further ease analysis.
- revm: Leans less on table generation, more on per‑handler code. Our approach is competitive and cache‑friendly.

\

[pr488]: https://github.com/evmts/guillotine/pull/488


