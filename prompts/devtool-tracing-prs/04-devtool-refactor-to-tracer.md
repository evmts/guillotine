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

---

## Implementation Guide (Deep Dive)

### What already exists (anchors in repo)

- Tracer interface and JSON output
  - `src/evm/tracer.zig` defines `Tracer` and `trace(...)` which writes one REVM‑compatible JSON object per step (ended with a newline).
- Where trace events are produced
  - `src/evm/evm/interpret.zig` → `pre_step(...)` emits a trace when `build_options.enable_tracing` is true and `self.tracer` is non‑null. It derives `pc`, reads `opcode` from `analysis.code[pc]`, snapshots `stack`, uses `frame.gas_remaining`, `memory.size()`, and `frame.depth`.
- How to enable a tracer on the VM
  - `src/evm/evm.zig` exposes `enable_tracing_to_path(path, append)` and `disable_tracing()`. It also stores an optional `tracer: ?std.io.AnyWriter` used by `interpret.zig`.
- Devtool’s duplicated interpreter (to be removed)
  - `src/devtool/evm.zig` implements `resetExecution()` and `stepExecute()` doing its own analysis‑driven stepping and gas attribution. Replace this with a tracer‑driven runner.

### Build flag

- Tracing is behind `-Denable-tracing` build option (see `build.zig`: adds `build_options.enable_tracing`). Always build and test with:
  - `zig build -Denable-tracing=true && zig build test -Denable-tracing=true`

### High‑level design after refactor

- A small `DevtoolRunner` configures the EVM with an in‑memory tracer writer and exposes `step/continue/pause/reset/breakpoints` using debug hooks (PR 1) for flow control. The tracer feeds a ring buffer adapter (`MemoryTracerAdapter`) that parses/stores steps and maintains small derived state for the UI.
- The Solid UI switches to read from the runner’s exported trace instead of live `Frame` serialization.

### Key constraints and patterns (Zig)

- Pass a custom writer using `std.io.AnyWriter` with a static `writeFn(ctx: *anyopaque, bytes: []const u8) !usize`. Store `ctx` as a pointer to your adapter and cast back inside `writeFn`.
- Avoid heap allocation per step. Preallocate ring storage and a parse buffer; keep the `write` hot path allocation‑free.
- Don’t attempt to control the interpreter via the tracer: `interpret.zig` ignores errors from `trace(...)`. Use debug hooks to pause/step.
