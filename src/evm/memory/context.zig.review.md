## Review: memory/context.zig (memory context management)

### High-signal findings

- Encapsulates per-frame memory with checkpoints; good for calls and reverts.

### Opportunities

- Provide unified charge+ensure helper; cache last word count; micro-opt for common 32-byte writes/reads.


