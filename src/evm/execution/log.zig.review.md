## Review: execution/log.zig (LOG0..LOG4)

### High-signal findings

- Topics and data are copied into state logs; gas includes per-topic and data costs; static context protection enforced.

### Opportunities

- Precompute memory expansion sizes for data copies when offsets/sizes are immediate.
- Ensure zeroing of unused tail bytes in return slice when output < requested is mirrored in LOG data copies if applicable (not required by spec, but consistency helps testing).

### Action items

- [ ] Add decode‑time memory sizing where predictable.
- [ ] Expand tests for large data payloads and multiple topics.

### Comparison to evmone/revm

- On par; minor throughput gains from decode‑time precompute.


