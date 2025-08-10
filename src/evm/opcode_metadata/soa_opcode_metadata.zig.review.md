## Review: opcode_metadata/soa_opcode_metadata.zig (SoA converter and hot accessors)

### High-signal findings

- Provides SoA representation and hot accessors (`get_hot_fields`, `get_stack_requirements`) enabling tighter loops where only subsets are needed. Good step toward maximizing locality.
- `init_from_aos` bridges AoS `OpcodeMetadata` view to pure SoA arrays efficiently.

### Opportunities

- If SoA becomes the canonical runtime path, consider generating SoA directly at comptime to avoid conversion, and keep AoS view purely as an accessor facade.
- Benchmark benefit of using `get_hot_fields` in interpreter fast path (if not already) to reduce loads.

### Action items

- [ ] Add microbenchmarks comparing AoS view vs SoA direct arrays in tight dispatch loops.
- [ ] Consider moving interpreter to rely on `get_hot_fields` for dispatch where only execute+gas are needed.

### Comparison to evmone/revm

- Aligns with evmone’s emphasis on hot-path field locality. Rust revm relies on compiler optimizations around enums; explicit SoA can outperform in stable patterns.


