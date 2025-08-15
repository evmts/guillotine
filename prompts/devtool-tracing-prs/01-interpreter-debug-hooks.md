## PR 1: Interpreter Debug Hooks (onStep/onMessage) in Core EVM

### Problem

The devtool currently duplicates interpreter logic to step opcodes. We want core-driven stepping with optional callbacks that can pause/inspect execution, and lifecycle hooks for message calls (CALL/CREATE and variants). The tracer today is write-only and cannot pause control flow.

### Goals

- Add optional debug hooks in the interpreter to support stepping and message lifecycle observation without duplicating interpreter logic.
- Zero overhead when hooks are unset.
- Preserve existing semantics for STOP/RETURN/REVERT and error propagation.

### Scope

- Add a `DebugHooks` interface with optional callbacks:
  - `onStep(user_ctx, frame, pc, opcode) -> StepControl` where `StepControl = { continue, pause, abort }`.
  - `onMessage(user_ctx, params, phase)` where `phase = { before, after }` and `params` covers CALL/CREATE metadata.
- Wire hooks in `interpret.zig` before and after opcode dispatch; and in message send/return sites in `execution/system.zig` (CALL-family) and any create paths.
- Hooks must not allocate on hot paths; passing pointers/slices borrowed from current frame is allowed but must be documented as ephemeral.

### Files to Change

- `src/evm/evm/interpret.zig`: inject onStep callbacks at each iteration, respecting `StepControl` (pause/abort). Ensure no extra cost when hooks are null.
- `src/evm/execution/system.zig`: wrap CALL/DELEGATECALL/STATICCALL/CREATE/CREATE2 with `onMessage(before)` and `onMessage(after)`.
- `src/evm/evm.zig`: expose `set_debug_hooks(hooks: ?DebugHooks)` on `Evm`.
- `src/evm/root.zig`: export `DebugHooks`, `StepControl`, `MessagePhase`.

### Proposed API (Zig)

```zig
pub const StepControl = enum { continue, pause, abort };

pub const MessagePhase = enum { before, after };

pub const OnStepFn = *const fn (user_ctx: ?*anyopaque, frame: *Frame, pc: usize, opcode: u8) anyerror!StepControl;
pub const OnMessageFn = *const fn (user_ctx: ?*anyopaque, params: *const CallParams, phase: MessagePhase) anyerror!void;

pub const DebugHooks = struct {
    user_ctx: ?*anyopaque = null,
    on_step: ?OnStepFn = null,
    on_message: ?OnMessageFn = null,
};
```

### Execution Semantics

- If `on_step` returns `pause`, `interpret` should yield control by returning a distinct status (e.g., `ExecutionStatus.Paused`) containing current PC and frame references for resumption. If returning `abort`, unwind with a controlled error `error.DebugAbort`.
- When paused, resumption API should continue from the same PC. This can be implemented by keeping the `Frame` alive and exposing `resume()` on `Evm` that restarts the loop without reinitialization.
- If hooks error, treat as `abort` and propagate `error.DebugAbort`.

### Performance

- Branch on a nullable function pointer only; no allocations.
- Mark hook invocations `inline` guarded by `if (hooks.on_step) |cb|` patterns.

### Tests

- `test/evm/instruction_test.zig`:
  - Step through `PUSH1 PUSH1 ADD STOP` and validate `on_step` receives PCs/opcodes in order and that `pause` pauses execution precisely between steps.
  - Validate `abort` aborts with `error.DebugAbort`.
- `test/evm/opcodes/system_test.zig`:
  - Validate `on_message(before)` and `on_message(after)` fire around CALL and record depth/params.

### Acceptance Criteria

- New APIs compile and are exported via `src/evm/root.zig`.
- All existing tests pass; new tests added for pause/abort/message hooks.
- Zero-overhead when hooks are unset (verified by code inspection; microbench optional).

### Notes

- STOP/RETURN/REVERT semantics unchanged—these still exit via current mechanism; hooks are additive.
- Devtool will consume these hooks in later PRs to drive single-step.
