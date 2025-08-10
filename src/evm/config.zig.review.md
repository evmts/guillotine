## Review: config.zig (Central EvmConfig and OpcodeMetadata integration)

### High-signal findings

- Centralizes all execution/runtime limits and hardfork/EIP feature derivation with compile-time evaluation. Integrates `OpcodeMetadata` directly into `EvmConfig` for zero-cost access to dispatch tables. Compile-time validation (`validate`) prevents misconfiguration.
- `init_from_eip_flags` path enables L2/custom chains by deriving opcode metadata directly from flags. Predefined configs (DEFAULT/DEBUG/PERFORMANCE/TESTING) clarify intended presets.

### Opportunities

- Consider exposing a computed, comptime-constant SoA view for interpreter hot path to avoid AoS-to-SoA conversion.
- Provide a tiny debug helper to dump selected opcode variants per hardfork/EIP flags, to audit configuration.
- Optional: compress `min_stack`/`max_stack` to u16 if safe, or move to cold section.

### Action items

- [ ] Add debug audit/dump of selected variants and metadata.
- [ ] Evaluate exposing `SoaOpcodeMetadata` as part of the config for hot paths.

### Comparison to evmone/revm

- This mirrors evmone’s table-driven, comptime approach and offers flexible EIP gating akin to feature flags. Good base for best-in-class performance.


