## Review: jump_table/jump_table.zig (OpcodeMetadata SoA dispatch table)

### High-signal findings (post‑comptimeconfigs)

- Struct‑of‑arrays with 64‑byte alignment for hot arrays (execute, constant_gas, min/max_stack) is ideal for cache locality. Cold arrays (dynamic_gas, memory_size, undefined) are separated.
- Now generated via centralized `EvmConfig`/`EipFlags` with compile‑time validation for metadata consistency; `OpcodeMetadata.init_from_hardfork` is the primary API. [pr488]
- Validate step marks inconsistent entries undefined (e.g., memory_size without dynamic_gas), preventing runtime hazards.

### Opportunities

1) Generation diagnostics
- In debug, produce a compact report of opcode traits per hardfork to detect regressions in compile‑time configuration.

2) Trait packing
- Consider packing min/max stack deltas as small integers (e.g., i8/u8) and compute absolute bounds at decode time to shrink table and improve I‑cache.

3) Inline hot ops parameterization
- Make the inlined hot‑op set configurable by build flag (trace‑driven), e.g., enabling DUP2/SWAP1 if profitable.

### Action items

- [ ] Add debug dump of opcode traits per hardfork.
- [ ] Explore trait packing to reduce footprint.
- [ ] Parameterize hot‑op inlining set.

### Comparison to evmone/revm

- evmone: Similar compact trait descriptors used heavily at decode time; we can match by adding generation‑time hints for fusion/precompute.
- revm: Less reliance on tables; our SoA approach is arguably more cache‑friendly and should perform very well.


