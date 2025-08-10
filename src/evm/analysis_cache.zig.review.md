## Review: analysis_cache.zig (analysis result caching)

### High-signal findings

- Caches translation artifacts per code to avoid repeated analysis; good for hot contracts and repeated calls.

### Opportunities

- Add an eviction policy (LRU or size‑based) if memory pressure is a concern in long‑running processes.
- Track cache hit/miss metrics (debug) to guide tuning.

### Action items

- [ ] Add optional bounded cache with eviction; expose stats.


