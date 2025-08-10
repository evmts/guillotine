## Review: execution/null_opcode.zig (unreachable/invalid handlers)

### Notes

- Must remain unreachable in normal flow for PUSHn/JUMP/JUMPI inline paths; tests should assert they are never called in those cases.


