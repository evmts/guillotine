## PR 4: Devtool Refactor to Tracer-Driven Execution

### Problem

The devtool currently reproduces interpreter logic to step instructions, making it hard to maintain. With Debug Hooks and the Standard Tracer, we can eliminate duplication and drive the UI from trace data.

### Goals

- Replace duplicated stepping logic in `src/devtool/evm.zig` with calls to EVM `set_debug_hooks` and `set_tracer`.
- Implement a `MemoryTracerAdapter` that accumulates steps and exposes the exact data the UI needs.
- Provide pause/resume/step/break functionality via hooks.

### Existing Devtool Behaviors to Preserve

- Opcode listing and current PC highlight.
- Stack visualization (top-first), memory view with hex dump, storage and logs views.
- Gas tracking per step and cumulative gas used.
- Error surfacing (e.g., stack underflow, invalid jump) to the UI.

### Scope

- `src/devtool/evm.zig`:
  - Create a wrapper around `Evm` that:
    - initializes with `set_debug_hooks` and `set_tracer`.
    - exposes `start(bytecode, calldata, env)`, `step()`, `continue()`, `pause()`, `reset()`.
  - Implement internal ring buffer for steps to support back/forward scrubbing without recomputation; cap size and allow replay.
- UI wiring (`src/devtool/solid/*`):
  - Switch data source from custom interpreter model to tracer stream.
  - Maintain derived selectors for current step, gas, stack/memory/storage.

### APIs

- `DevtoolRunner` (Zig):
  - `init(allocator)` / `deinit()`
  - `load(bytecode, calldata, env)`
  - `step() bool` -> executes one opcode and appends a step; returns false if halted/paused.
  - `continue(max_steps?: usize)` -> runs until halt/pause/breakpoint or step cap.
  - `set_breakpoints(pcs: []usize)` and honor in `onStep`.
  - `get_trace()` -> `ExecutionTrace` for export.

### Tests

- Add headless tests under `test/devtool/` (new dir) that:
  - Run bytecode through `DevtoolRunner` and assert sequence of ops matches analysis mapping.
  - Verify pause on breakpoint and resume continues correctly.
  - Ensure error propagation is visible to UI layer (expose last error string/code).

### Acceptance Criteria

- Devtool builds and runs with tracer-driven execution; stepping works with pause/resume.
- No interpreter code duplication remains in devtool; only uses EVM public APIs and tracer data.
- All existing devtool UI affordances remain functional.

### Notes

- Pausing relies on PR 1 `StepControl.pause`.
- Memory/stack representations must match UI expectations (endianness, formatting).
