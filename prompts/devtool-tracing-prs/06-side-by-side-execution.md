## PR 6: Side-by-Side Execution (Primary EVM vs Mini EVM)

Execute bytecode simultaneously in the primary EVM and the Mini EVM, render a live, step-by-step comparison, and highlight divergences with precise diffs. This PR builds on:

- PR 1 (Interpreter Debug Hooks) for pausable stepping
- PR 2 (Standard Memory Tracer)
- PR 3 (Mini EVM Comparator and `debug/shadow.zig`)
- PR 4 (Devtool refactor to tracer-driven execution)

This document provides everything needed to implement PR 6 end-to-end: exact code touch points, APIs, data structures, memory ownership rules, UI contracts, tests, and Zig patterns.

### Why side-by-side?

- Faster debugging: immediately see where and how primary diverges from Mini
- Deterministic reproduction: lockstep execution driven by debug hooks ensures consistent step indices
- Minimal overhead mode: per-call comparison when step-by-step isn’t needed

## Scope

- Add a dual-execution mode in the devtool runner: `run_both()`
  - per-call: run both engines once and compare final `CallResult`
  - per-step: drive both engines step-by-step using Debug Hooks; at each step, collect state and compare
- Integrate `src/evm/debug/shadow.zig` (from PR 3) for comparisons
- Build a UI view to render side-by-side states and mismatches

## Primary integration points (exact paths)

- Primary call entrypoints (analysis-based):
  - `src/evm/evm/call.zig` → `pub inline fn call(self: *Evm, params: CallParams) !CallResult`
  - In nested CALL-family, the interpreter dispatch is in `interpret.zig` (called from `call.zig`)
- Mini EVM call entrypoint (PC-based):
  - `src/evm/evm/call_mini.zig` → `pub inline fn call_mini(self: *Evm, params: CallParams) !CallResult`
  - PR 3: add `execute_single_op(...)` and a per-step driver for shadow mode
- CALL-family opcode sites (for per-call shadow compare hooks):
  - `src/evm/execution/system.zig` → `op_call`, `op_delegatecall`, `op_staticcall`, `op_callcode`, `op_create`, `op_create2`
- Devtool orchestration:
  - `src/devtool/evm.zig` currently implements a custom analysis-first stepping loop (`stepExecute`). PR 4 moves this to tracer-driven; PR 6 uses that tracer-driven runner but adds dual-engine execution.
- Debug/trace state helpers:
  - `src/devtool/debug_state.zig` → formatting, JSON shapes for UI

## Comparator (`src/evm/debug/shadow.zig`) from PR 3

Implement this file if not present (see PR 3 for full details). Minimal API needed by PR 6:

```zig
pub const ShadowMode = enum { off, per_call, per_step };

pub const ShadowConfig = struct {
    mode: ShadowMode = .per_call,
    stack_compare_limit: usize = 64,
    memory_window: usize = 256,
};

pub const ShadowMismatch = struct {
    context: enum { per_call, per_step },
    op_pc: usize = 0, // only for per_step
    field: enum { success, gas_left, output, logs, storage, stack, memory, pc },
    lhs_summary: []const u8, // primary summary (owned by caller)
    rhs_summary: []const u8, // mini summary (owned by caller)
};

pub fn compare_call_results(lhs: @import("../evm/call_result.zig").CallResult,
                            rhs: @import("../evm/call_result.zig").CallResult,
                            allocator: std.mem.Allocator) !?ShadowMismatch { /* ... */ }

pub fn compare_step(lhs: *@import("../frame.zig").Frame,
                    rhs: *@import("../frame.zig").Frame,
                    pc_lhs: usize,
                    pc_rhs: usize,
                    cfg: ShadowConfig,
                    allocator: std.mem.Allocator) !?ShadowMismatch { /* ... */ }
```

Ownership: any strings/summaries allocated inside `compare_*` must be freed by the caller. Keep internal comparisons allocation-light; prefer direct equality and compact previews.

Expose a debug slot on `Evm` to store the last mismatch:

```zig
// in src/evm/evm.zig (PR 3)
pub const DebugShadow = @import("debug/shadow.zig");
shadow_mode: DebugShadow.ShadowMode = .off,
shadow_cfg: DebugShadow.ShadowConfig = .{},
last_shadow_mismatch: ?DebugShadow.ShadowMismatch = null,
```

## Debug hooks from PR 1 (required for per-step)

Add debug hooks so the interpreter can pause each step and let the devtool drive lockstep comparisons:

```zig
// src/evm/debug_hooks.zig
pub const StepControl = enum { cont, pause, abort };
pub const MessagePhase = enum { before, after };
pub const OnStepFn = *const fn (user_ctx: ?*anyopaque, frame: *Frame, pc: usize, opcode: u8) anyerror!StepControl;
pub const OnMessageFn = *const fn (user_ctx: ?*anyopaque, params: *const CallParams, phase: MessagePhase) anyerror!void;
pub const DebugHooks = struct { user_ctx: ?*anyopaque = null, on_step: ?OnStepFn = null, on_message: ?OnMessageFn = null };
```

Wire them in:

- `src/evm/evm/interpret.zig`: before dispatch, call `on_step`; map errors to `DebugAbort`/`DebugPaused`
- `src/evm/execution/system.zig`: call `on_message(.before)` and `.after)` around host `call`
- `src/evm/execution/execution_error.zig`: add `DebugAbort`, `DebugPaused`
- `src/evm/evm.zig`: `debug_hooks: ?DebugHooks` and `set_debug_hooks()`

These are zero-overhead when unset (nullable checks only).

## Mini EVM per-step API (from PR 3)

Extend `src/evm/evm/call_mini.zig` with:

- `execute_single_op(self: *Evm, frame: *Frame, code: []const u8, pc: usize) !usize`
  - Executes one opcode at `pc`, returns the next `pc`
  - Reuses jump table for non-PUSH/JUMP and handles special cases (PUSHn, JUMP, JUMPI, RETURN, REVERT)
- `call_mini_shadow(params: CallParams, mode: enum { per_call, per_step }) !CallResult`
  - per_call: current `call_mini`
  - per_step: initialize a frame and let caller drive via `execute_single_op`

This lets the devtool advance Mini by exactly one step to align with primary.

## Devtool runner changes (`src/devtool/evm.zig`)

Current state: devtool has its own analysis-first stepping loop (`stepExecute`) and JSON serialization. For PR 6 we introduce a dual-engine mode and—after PR 4—ensure the primary engine is driven by debug hooks/tracer rather than duplicating interpreter logic.

Add a new mode and data structures:

```zig
const ComparisonMode = enum { off, per_call, per_step };

pub const SideBySideStep = struct {
    // primary
    pc_primary: usize,
    gas_before_primary: u64,
    gas_after_primary: u64,
    stack_size_primary: usize,
    // mini
    pc_mini: usize,
    gas_before_mini: u64,
    gas_after_mini: u64,
    stack_size_mini: usize,
    // optional diff
    mismatch: ?Evm.DebugShadow.ShadowMismatch = null,
};

pub const SideBySideRun = struct {
    steps: []SideBySideStep,
    final_call_primary: @import("evm").CallResult,
    final_call_mini: @import("evm").CallResult,
    diverged_at: ?usize, // step index
};
```

Add fields to the devtool state:

- `comparison_mode: ComparisonMode`
- `mini_snapshot_state`: internal to manage per-step Mini frame/code pointers

Add APIs:

- `set_comparison_mode(mode: ComparisonMode)`
- `run_both_per_call(params: CallParams) !SideBySideRun`
- `run_both_per_step(params: CallParams, max_steps: usize) !SideBySideRun`

Implementation details:

### Per-call path

1. Build `CallParams` (typically `.call` or `.staticcall`) from the devtool’s loaded bytecode/context
2. Primary: `const res_primary = try evm.call(params);`
3. Mini: `const res_mini = try evm.call_mini(params);`
4. Compare: `const mismatch = try DebugShadow.compare_call_results(res_primary, res_mini, allocator);`
5. Populate `SideBySideRun{ steps = &.{}, final_call_* = ..., diverged_at = if (mismatch != null) 0 else null }`
6. Free any allocations in the mismatch summaries when done

Notes:

- Precompiles are handled by both
- For nested calls via opcodes, step comparison is preferred; per-call compare can be done at `onMessage(.after)` in PR 1 hooks

### Per-step path

Prerequisites: PR 1 hooks integrated; PR 3 Mini per-step API added.

Driver outline:

1. Enable `evm.shadow_mode = .per_step` and set `evm.last_shadow_mismatch = null`
2. Install `DebugHooks` with an `on_step` that returns `.pause` every step
3. Initialize primary call via `evm.call(params)` in a loop that resumes on `DebugPaused`
4. Maintain a Mini frame and program counter
5. On each primary pause:
   - Capture primary state: `pc_primary`, `gas_before/after`, stack depth (from `Frame`)
   - Drive exactly one Mini step: `pc_mini = try execute_single_op(mini_frame, code, pc_mini)`
   - Compare via `DebugShadow.compare_step(primary_frame, mini_frame, pc_primary, pc_mini, cfg, allocator)`
   - If mismatch, set `diverged_at = step_index`, store `last_shadow_mismatch`, and stop unless UI requests continue
6. Repeat until STOP/RETURN/REVERT (primary call completes) or max_steps reached

Primary PC and instruction mapping:

- Primary uses analysis with an instruction pointer (`frame.instruction`) into `analysis.instructions`
- Compute PC from instruction index using `analysis.inst_to_pc[idx]` with fallback logic already present in `src/devtool/evm.zig` serialization code (see mapping in `serializeEvmState`)

Mini PC is the current `pc` used by `execute_single_op`

Gas before/after: capture from `frame.gas_remaining` before/after invoking the opcode (the hook can capture `gas_before` and the step return can expose `gas_after`)

Memory window: optional; if implementing windowed diffs, capture last write span or compute a minimal dirty region.

Storage per-step: optional; if Mini tracks a per-step write set and primary can expose a journal slice for the step, compare keys and new values.

### Exact primary structures you’ll use

- `Frame` (hot fields), see around these fields for reference:

```44:80:src/evm/frame.zig
pub const Frame = struct {
    instruction: *const @import("instruction.zig").Instruction,
    gas_remaining: u64,
    stack: Stack,
    memory: Memory,
    analysis: *const CodeAnalysis,
    depth: u10,
    is_static: bool,
    contract_address: primitives.Address.Address,
    state: DatabaseInterface,
    host: Host,
    caller: primitives.Address.Address,
    value: u256,
    // ...
};
```

- PC mapping hint (already used in devtool): walk `analysis.inst_to_pc` and derive PC when not directly mapped. See `serializeEvmState` in `src/devtool/evm.zig` for the derivation logic.

### JSON for UI (side-by-side)

Add a new endpoint similar to `stepEvmHandler` that returns a JSON payload for the latest step pair and an array buffer when running continuously. Suggested shape:

```json
{
  "mode": "per_step",
  "stepIndex": 12,
  "primary": {
    "pc": 42,
    "gasBefore": 50000,
    "gasAfter": 49970,
    "stackSize": 3
  },
  "mini": { "pc": 42, "gasBefore": 50000, "gasAfter": 49970, "stackSize": 3 },
  "mismatch": {
    "field": "stack",
    "lhs": "top: 0x01, 0x02, ...",
    "rhs": "top: 0x01, 0x03, ..."
  }
}
```

On divergence, keep returning the same index with an attached mismatch until user requests continue/step.

## UI: `ComparisonView.tsx`

Add a new Solid/React-equivalent component that:

- Renders two columns: Primary and Mini
- Header row: opcode name, PC, gas used (delta), stack depth
- Body: minimal hex dumps (stack top N, memory window), color-diffed when mismatch
- Badge row: mismatch field, clickable to expand diff
- Timeline scrubber uses step index; stepping is driven by devtool endpoints

Data flows:

- Fetch state via new devtool endpoints
- Existing `serializeEvmState` remains for the single-engine view
- For dual mode, either extend the existing state or provide a separate endpoint/JSON

## Tests

### Unit/differential tests (Zig)

Add tests under `test/differential/` that compare primary `call()` vs `call_mini()` on simple programs. You can adapt from existing tests; relevant imports and patterns are present in `src/evm/evm/call.zig` test blocks and other files. Suggested cases:

- Arithmetic/control flow: `PUSH1 1; PUSH1 2; ADD; STOP`
- Memory ops: `MSTORE/MLOAD`, ensure return data parity
- Storage ops: `SSTORE/SLOAD` where Mini tracks writes and primary handles journal correctly
- CALL/STATICCALL returning data and gas accounting (may require loading simple runtime code into the `MemoryDatabase`)

Per-step tests:

- Construct tiny bytecode where a known difference can be toggled (e.g., force a different gas delta). Assert `compare_step` returns a mismatch at the exact opcode.

### Devtool headless tests

Add `test/devtool/` for headless runner tests (no UI). Smoke-test `run_both_per_call` and `run_both_per_step` against simple bytecode; assert no mismatch for canonical paths and proper mismatch surface for contrived differences.

## Memory management and Zig patterns

- Ownership:
  - `compare_*` returns optional `ShadowMismatch` with allocated `lhs_summary`/`rhs_summary` → caller frees
  - In Mini per-call, `call_mini` duplicates `current_output` into `mini_output` and resets VM `current_output`; be careful to free on VM deinit
  - In primary per-call, `CallResult.output` is a VM-owned view in `call.zig` (do not free), whereas in CALL-family opcode sites in `system.zig` buffers are freed explicitly after copying to memory
- Use `defer` for in-scope allocations and `errdefer` when transferring ownership
- Casting patterns for hooks and host access:
  - `const evm_ptr = @as(*Evm, @ptrCast(@alignCast(frame.host.ptr)));`
- Nullable function pointers:
  - `if (hooks.on_step) |cb| { ... }`
- Error mapping:
  - Hook errors → `DebugAbort`; pause → `DebugPaused`
- Don’t store frame pointers beyond callback scope; borrows are ephemeral

## Performance considerations

- Guard all debug/hook code with nullable checks and build flags (PR 3 suggests a `build_options.enable_shadow_compare` defaulting on in Debug and off in Release)
- Per-step comparisons should be allocation-light; compare integers directly and only format summaries on mismatch
- For memory diffs, prefer preview windows instead of full dumps

## Common pitfalls

- PC mapping: primary uses analysis; ensure you derive PC correctly from `frame.instruction` + `analysis.inst_to_pc`. See the mapping logic in `src/devtool/evm.zig` (`serializeEvmState`).
- Ownership of `CallResult.output`: in primary `call()`, output is a view into frame buffer; do not free. In `system.zig` handlers, buffers returned from host are freed after copying.
- Don’t modify VM state in comparator; only read and compare
- Ensure snapshots are handled correctly during nested calls in Mini and primary paths

## Step-by-step implementation checklist

1. Ensure PR 1 hooks exist and are wired (on_step/on_message), export types in `src/evm/root.zig`; add `set_debug_hooks()` on `Evm`
2. Land PR 3 comparator with `debug/shadow.zig` and Mini per-step API
3. Devtool:
   - Add `ComparisonMode` and `run_both_per_call`, `run_both_per_step`
   - Add new endpoint in `src/devtool/app.zig` analogous to `stepEvmHandler` returning side-by-side JSON
   - Wire UI to new endpoint (`ComparisonView.tsx`)
4. Tests:
   - Add differential tests for per-call and per-step
   - Add headless devtool smoke tests
5. Build flags:
   - Introduce `build_options.enable_shadow_compare` as in PR 3
6. Run and keep green after every edit:
   - `zig build && zig build test`

## Code references (for quick navigation)

```20:63:src/evm/evm/call_mini.zig
pub inline fn call_mini(self: *Evm, params: CallParams) ExecutionError.Error!CallResult {
    // Simplified execution with PC-based loop; extend with execute_single_op for per-step
}
```

```31:116:src/evm/evm/call.zig
pub inline fn call(self: *Evm, params: CallParams) ExecutionError.Error!CallResult {
    // Analysis-based execution via interpret(); VM-owned output view semantics
}
```

```831:972:src/evm/execution/system.zig
pub fn op_call(context: *anyopaque) ExecutionError.Error!void {
    // Host call, snapshot handling, output copy to memory, buffer free
}
```

```480:761:src/devtool/evm.zig
pub fn stepExecute(self: *DevtoolEvm) !DebugStepResult {
    // Current analysis-first stepping; PR 4 replaces this with tracer-driven hooks
}
```

```1:74:src/devtool/debug_state.zig
pub const DebugState = struct { /* UI capture helpers (opcode name, gas, stack size, etc.) */ };
```

## Example usage (devtool, per-call)

```zig
var run = try self.run_both_per_call(params);
if (run.diverged_at) |idx| {
    // surface mismatch to UI; summaries owned by caller → free after rendering
} else {
    // results equal; show final outputs and gas
}
```

## Acceptance criteria

- per-call mode: identical results for canonical samples (success flag, gas_left, output bytes)
- per-step mode: step indices align; PC, gas deltas, top-of-stack match; mismatches highlighted with compact summaries
- Works with pause/resume and breakpoints; both engines stay in sync by step index
- No allocations or noticeable overhead when comparison mode is off

## Build & test protocol (mandatory)

After every edit, run:

```bash
zig build && zig build test
```

Never proceed with a broken build or failing test.

---

If anything behaves unexpectedly, add logging at the exact execution point and verify assumptions with evidence rather than guessing. Prefer step-by-step tracing through the first divergent opcode.
