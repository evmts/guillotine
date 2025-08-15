## PR 8: QA and Test Plan for Devtool Tracing Stack

### Objectives

- Ensure each PR in the stack has passing unit and integration tests.
- Validate zero-regression on existing tests and devtool functionality.

### Global Test Matrix

- Platforms: macOS 14+, Linux (CI).
- Zig: `zig build`, `zig build test`, `zig build bench` (optional sanity), `zig build devtool`.

### Per-PR Checks

1. Debug Hooks:
   - Unit: pause/abort semantics; message hooks fire around CALL/CREATE.
   - Integration: stepping preserves interpreter semantics.
2. Standard Tracer:
   - Unit: arithmetic/memory/storage/log capture; bounded memory.
   - Perf: ensure near-zero overhead when disabled (compile-time guarded checks).
3. REVM Bridge:
   - Differential: parity on small programs; struct log alignment.
4. Devtool Refactor:
   - Headless: step/pause/resume; breakpoints.
   - UI Smoke: opcode list, stack/memory/storage, gas.
5. Analysis + PC Mapping:
   - Unit: instruction index to original PC is stable across steps.
6. Side-by-Side Execution:
   - Diff rendering and mismatch surfacing.
7. Frame Capture + UI:
   - Nested calls visualization; revert handling.

### Tooling

- Keep using `test/differential` as reference; extend with focused cases for CALL and memory.
- Add optional environment flag to enable verbose `std.log.debug` within tests.

### Acceptance Criteria for the Stack

- All tests green per PR and at top-of-stack.
- Devtool can load bytecode, step interactively, and compare with REVM.
- Memory ownership clear; no leaks under `std.heap.GeneralPurposeAllocator` checks.
