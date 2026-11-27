# `src/tracer`

Execution tracing, JSON-RPC step capture, ring-buffer failure diagnostics, and lockstep differential synchronization against the `MinimalEvm` reference interpreter.

## Modules

- **`tracer.zig`** — Core `Tracer` recording execution steps, gas, schedule progress, ring-buffer opcode history, and `Tracer.assert()` checks.
- **`minimal_evm.zig`** / **`minimal_frame.zig`** / **`minimal_host.zig`** — Sequential bytecode reference interpreter used as the differential oracle for dispatch and opcode-fusion verification.
- **`minimal_evm_sync.zig`** — Maps each dispatch handler (including multi-opcode synthetic fusions) to the exact sequence of `MinimalEvm` steps on `beforeInstruction()`.
- **`pc_tracker.zig`** — Translates dispatch schedule cursors back to canonical EVM bytecode program counters.
- **`ring_buffer.zig`** — Fixed-size ring buffer of recent operations dumped on invariant failures.
- **`lifecycle_events.zig`** / **`events/`** — Structured lifecycle and bytecode-analysis event records.
- **`tracer_config.zig`** — Comptime/runtime tracer configuration.

## Invariants

- Frame cursors index the preprocessed dispatch schedule, never raw bytecode PCs.
- Embedded library builds (`guillotine_embedded = true`, e.g., `libguillotine_ffi`) and `ReleaseFast`/`ReleaseSmall` builds never abort on tracer checks; failures log and increment `Tracer.failed_checks`.
- Every opcode handler calls `beforeInstruction()` so synthetic fusions stay lockstep-verified against `MinimalEvm`.
