## Review: config/config.zig (EVM configuration exports)

### Notes

- Clean re-export surface for `EvmConfig`, `EipFlags`, overrides, and helpers. Keeps call sites tidy and centralizes config access.

### Suggestions

- Add a brief module-level comment documenting intended usage patterns (e.g., recommended configs for testing vs perf).


