## Review: opcode_metadata/operation_config.zig (OpSpec and ALL_OPERATIONS)

### High-signal findings

- Single-source spec `ALL_OPERATIONS` with hardfork variants drives comptime generation of `OpcodeMetadata`. Wrappers (`wrap_any`, `wrap_ctx`) standardize handler signatures and anyopaque adapter calls.
- Gas constants and min/max stack encoded per variant allow compile-time selection per hardfork/EIP flags. Clear mapping to execution modules.

### Opportunities

- Add a tiny compile-time validator asserting monotonic hardfork progression per opcode, and that only one variant is selected for a target fork.
- Generate a compact doc or table in debug builds listing selected variant per opcode for the chosen fork/flags to aid review and regression detection.
- Consider adding a “fusable” flag to spec for future peephole fusion guidance in analysis.

### Action items

- [ ] Add comptime assertions for variant uniqueness/ordering.
- [ ] Emit debug doc of selected variants by fork.
- [ ] Optional: add fusion hint flag.

### Comparison to evmone/revm

- Comparable to evmone’s traits tables. Centralizing spec reduces drift and improves maintainability; this is a strong foundation for correctness and performance.


