## PR 3: REVM Tracer Bridge (Rust + Zig FFI)

### Problem

We need side-by-side execution with REVM and capture equivalent struct logs for comparison in the devtool.

### Goals

- Add a REVM-based runner in `src/revm_wrapper/` that executes bytecode with a tracer and streams step data through FFI to Zig.
- Normalize REVM trace into the same `ExecutionTrace`/`StructLog` schema used by Guillotine.

### Scope

- Rust side (`src/revm_wrapper/src/`):
  - Implement a thin binary or library using `revm` crates to execute given bytecode and calldata with configurable env (gas, coinbase, basefee, timestamp, number).
  - Register REVM Inspector/Tracer to emit per-step pc/op/gas/stack/memory/storage/logs.
  - C-ABI functions to run and either return full trace or stream steps via callback.
- Zig side:
  - Extend `src/revm_wrapper/` Zig bindings to call into Rust runner and build `ExecutionTrace`.
  - Provide `run_revm_trace(bytecode, calldata, env) -> ExecutionTrace`.

### Files to Change/Add

- Rust:
  - `src/revm_wrapper/src/lib.rs`: C-ABI, run function, inspector implementation.
  - `src/revm_wrapper/Cargo.toml`: ensure `revm` versions consistent.
- Zig:
  - `src/revm_wrapper/binding.zig` (or new file) to define FFI and data translations.
  - `src/evm/root.zig` export a small `revm` facade only if needed by devtool/tests.

### Trace Normalization

- Map REVM opcodes to strings (REVM already provides names). Ensure PC and gas-before/cost semantics match our `StructLog` expectations.
- Stack: capture as big-endian 256-bit words to match Zig `u256`.
- Memory: capture current memory with optional bounds; apply same truncation policy as Guillotine tracer for apples-to-apples.
- Storage: REVM may expose state diffs; capture only modified slots per step.

### Tests

- Zig integration test under `test/differential/`:
  - Execute small bytecode sequences via both Guillotine and REVM and assert traces align on pc/op/gas/stack lengths and values (within any defined truncation rules).
- Smoke test: simple CALL with return to ensure message phases align.

### Acceptance Criteria

- `zig build && zig build test` passes on macOS CI targets.
- For canonical samples (PUSH/ADD/MSTORE/SLOAD/SSTORE), trace parity holds step-by-step.

### Notes

- Use `cargo doc` for REVM Inspector APIs if needed during implementation.
- Keep FFI stable and minimal; avoid heap ownership transfer across FFI—copy into Zig-owned memory.
