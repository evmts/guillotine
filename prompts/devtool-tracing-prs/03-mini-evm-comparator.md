## PR 3: Mini EVM Comparator (Shadow Execution via call_mini)

### Problem

We want continuous, in-repo differential validation of the primary EVM against a simpler reference implementation. Instead of integrating REVM, we will run a "Mini EVM" side-by-side that uses `src/evm/evm/call_mini.zig` as the reference. Whenever execution diverges, we should stop (in debug modes), surface an actionable diff (state deltas), and enable fast iteration.

### Goals

- Introduce a shadow execution mode that compares the primary EVM (analysis/jumptable) with the Mini EVM for the same calls.
- Default: per-call comparison (cheap). Debug mode: optional per-step comparison to find first divergent opcode.
- Produce a structured mismatch report with precise state differences.

### Scope

- Expose a lightweight step API in Mini EVM to enable per-step lockstep comparison.
- Add an orchestrator that, for each CALL/CREATE-family operation, runs both engines with identical inputs and compares results.
- Integrate with Debug Hooks so that devtool can pause on the first mismatch and display a detailed diff.

### Integration Points

- `src/evm/evm/call_mini.zig`:

  - Refactor to factor out a single-op execute path: `execute_single_op(frame: *Frame, code: []const u8, pc: usize) !usize` returning next pc or an `ExecutionError` (STOP/RETURN/REVERT mapped like today).
  - Add an entry `call_mini_shadow(params: CallParams, mode: enum{ per_call, per_step }) !CallResult` that:
    - per_call: runs the current loop (as-is), returns `CallResult`.
    - per_step: accepts an initial snapshot and runs one-op-at-a-time via `execute_single_op`, allowing the comparator to drive steps.

- `src/evm/execution/system.zig` (CALL/DELEGATECALL/STATICCALL/CREATE/CREATE2):

  - On `onMessage(before)`, if shadow mode is enabled, spawn a Mini EVM shadow execution for the same `CallParams` (per-call mode by default).
  - On `onMessage(after)`, compare `CallResult` (success flag, gas_left, output bytes, logs emitted count/order, storage writes) and emit `ShadowMismatch` if different.

- `src/evm/evm/interpret.zig`:
  - When debug per-step mode is enabled, for each `onStep` on the primary EVM, drive a single step in the Mini EVM shadow frame and compare after-step state:
    - pc/next_pc
    - gas remaining and gas delta
    - stack depth and top N values
    - memory write region and values (bounded window)
    - storage writes for the step (if any)
  - On mismatch, raise `error.ShadowMismatch` with a compact diff payload.

### Comparator Design

Introduce `src/evm/debug/shadow.zig`:

```zig
pub const ShadowMode = enum { off, per_call, per_step };

pub const ShadowConfig = struct {
    mode: ShadowMode = .per_call,
    stack_compare_limit: usize = 64,
    memory_window: usize = 256, // bytes around touched region per step
};

pub const ShadowMismatch = struct {
    context: enum { per_call, per_step },
    op_pc: usize, // per_step: current pc; per_call: 0
    field: enum { success, gas_left, output, logs, storage, stack, memory, pc },
    lhs_summary: []const u8,
    rhs_summary: []const u8,
    // Optionally include minimized diffs (first index of difference, counts)
};

pub fn compare_call_results(lhs: CallResult, rhs: CallResult) ?ShadowMismatch { /* compare success, gas_left, output, logs */ }

pub fn compare_step(
    lhs: *Frame,
    rhs: *Frame,
    pc_lhs: usize,
    pc_rhs: usize,
    cfg: ShadowConfig,
) ?ShadowMismatch { /* compare pc, gas delta, stack (limited), memory window around writes, storage writes */ }
```

Notes:

- For performance, storage comparison should only consider modified keys (Mini EVM can track per-step stores; primary can expose write-set via journal for the step).
- Memory comparison should focus on write spans (Mini EVM and primary expose last-write range or we compute minimal dirty interval in capture utils).

### Error Surfacing

- Define `error.ShadowMismatch` and carry a `ShadowMismatch` payload via a global debug facility (or store last mismatch in the `Evm` and expose via a getter).
- In devtool, if mismatch occurs, pause execution and render a diff panel using the payload.

### State to Compare

- Per-call (always-on):

  - `success: bool`
  - `gas_left: u64`
  - `output: []u8` (length + first/last 32 bytes preview; full compare off-UI)
  - `logs`: count + topics/data equality per log
  - `storage writes`: number of writes + key/value equality (order-insensitive)

- Per-step (debug-only):
  - `pc` and calculated `next_pc`
  - `gas_before/gas_after` and `gas_cost`
  - `stack`: depth and top K values (configurable)
  - `memory`: write window (offset, len, bytes)
  - `storage`: writes in this step (slot -> new value)

### Tests

- Unit tests comparing `call()` vs `call_mini()` per-call results for:

  - Arithmetic and control flow
  - Memory ops (MSTORE/MLOAD return data)
  - Storage ops (SSTORE/SLOAD side effects)
  - CALL/STATICCALL returning data and gas accounting

- Per-step debug tests:
  - Construct short bytecode where a known bug is injected (e.g., incorrect gas cost), assert that `compare_step` flags the mismatch on the exact opcode.

### Acceptance Criteria

- Shadow mode `.per_call` enabled in debug builds by default, with minimal overhead in release (can be disabled).
- Optional `.per_step` can be toggled via a build or runtime flag; devtool enables it during interactive stepping.
- On mismatch, the system pauses (in debug mode) and surfaces a precise diff; in non-debug builds, we can collect a counter or return a summarized mismatch without aborting.

### Notes

- Memory and storage diffing must obey ownership rules; any allocated summaries must be freed by the caller (documented).
- The comparator must not mutate EVM state; Mini EVM runs on its own `Frame` copies and state snapshots.
