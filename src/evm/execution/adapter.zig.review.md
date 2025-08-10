## Review: execution/adapter.zig (anyopaque adapters)

### High-signal findings

- Provides adapter thunks converting `*anyopaque` to typed contexts for handlers; isolates call ABI.

### Opportunities

- Mark tiny wrappers as always_inline if that improves codegen; benchmark.
- Ensure no logging or branches inside adapters; keep strictly forwarding.


