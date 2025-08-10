## Review: frame.zig (minimal execution context)

### High-signal findings

- Data-oriented `Frame` with hot fields first and packed flags; heap-allocates `Stack` and `Memory` to slim the struct. Provides helpers for gas, jumpdest, access list, storage, and refunds. Compile-time layout checks enforce locality and size constraints.

### Opportunities

- Add compile-time guards to disable any debug prints/logs in ReleaseFast paths reaching frame init.
- Factor a tiny inline helper for memory expansion charge+ensure used by multiple handlers via frame to reduce duplication and unify semantics.
- Consider providing a read-only hot view for interpreter (stack ptr, gas pointer, opcode metadata hot arrays) to minimize derefs.

### Action items

- [ ] Add compile-time guard for logs in hot paths.
- [ ] Introduce `charge_and_ensure_memory(frame, new_size)` helper used by memory-heavy ops.
- [ ] Add tests for early-error allocations to ensure `errdefer` correctness (no leaks).


