## PR 2: Standard Memory Tracer for Guillotine

### Problem

Devtool needs full per-step state snapshots (pc, opcode, gas before/after, stack, memory, storage diffs, logs) to visualize and scrub execution. Current tracer writes JSON lines and cannot pause or provide structured access.

### Goals

- Implement a structured, in-process tracer that consumes Debug Hooks and records full step data needed by the UI.
- Provide retrieval APIs: get full trace, or incremental steps for live streaming.
- Maintain strict memory ownership and allow bounded memory via configurable limits.

### Scope

- Introduce `src/evm/tracing/` with:
  - `tracer.zig`: vtable interface and data structs (StepInfo, StepResult, FinalResult, StructLog, ExecutionTrace, StackChanges, MemoryChanges, StorageChange, LogEntry) modeled on the plan.
  - `standard_tracer.zig`: default implementation collecting all details.
  - `capture_utils.zig`: helpers to snapshot stack/memory/storage/logs with minimal copies.
- Wire tracer with newly added Debug Hooks from PR 1.

### Files to Add

- `src/evm/tracing/tracer.zig`
- `src/evm/tracing/standard_tracer.zig`
- `src/evm/tracing/capture_utils.zig`

### Integration

- `src/evm/root.zig`: export tracer types.
- `src/evm/evm.zig`: add `set_tracer(tracer: ?Tracer)` and call tracer via hooks.
- `src/evm/evm/interpret.zig`: ensure after-step capture uses deltas for stack/memory when available.

### Data Model (summarized)

- StepInfo: pc, opcode, gas_remaining, depth, address, stack_size, memory_size.
- StepResult: gas_cost, gas_remaining, stack_changes, memory_changes, storage_changes, logs_emitted, error_occurred.
- StructLog: pc, op string, gas before, gas_cost, depth, stack snapshot, memory snapshot (bounded), storage map.
- ExecutionTrace: gas_used, failed, return_value, struct_logs[].

### Memory Strategy

- Bounded memory capture: configurable max bytes; when exceeded, capture window around accessed region plus summary sizes.
- Stack captured as copy of current stack; for very deep stacks, allow truncation with tail note.
- Storage captured as per-step modified slots only.

### Tests

- Unit tests under `test/evm/`:
  - Trace simple arithmetic and verify struct logs sequence.
  - Trace memory ops (MSTORE/MLOAD) and verify memory window.
  - Trace storage ops (SSTORE/SLOAD) and verify changed slots.
  - Zero-overhead when no tracer set (compile-time guard + sanity perf guard).

### Acceptance Criteria

- Tracer compiles, integrates, and produces deterministic struct logs for known bytecode samples.
- Tests cover arithmetic, memory, storage, logs, and error steps.
- No allocations on hot path except when tracing is enabled.

### Notes

- Opcode-to-string mapping should reuse existing opcode metadata where possible.
- Consider mapping `analysis` instruction index back to original PC for UI (PR 5).
