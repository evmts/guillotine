## Review: host.zig (Host interface and block context)

### High-signal findings

- Clean Host API exposing balance/code/block info and call parameters. BlockInfo struct underpins block opcodes.

### Opportunities

- Ensure Host methods are zero-cost wrappers over state where possible; avoid logging in hot paths. Consider caching block fields on frame creation only.


