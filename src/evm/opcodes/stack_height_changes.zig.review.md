## Review: opcodes/stack_height_changes.zig (stack deltas)

### High-signal findings

- Encodes min/max stack effects per opcode; vital for analysis and block validation.

### Opportunities

- Add compile-time assertions that deltas align with `operation_config.ALL_OPERATIONS` min/max for consistency.


