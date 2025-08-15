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

---

## Comprehensive Implementation Guide

### Why this PR exists

The current devtool re-implements stepping logic outside of the core EVM. This adds maintenance cost and can drift from real semantics. We want:

- A per-opcode step hook to observe or pause execution
- A message lifecycle hook around CALL/CREATE-family operations

Both must be zero-overhead when unset and preserve STOP/RETURN/REVERT semantics.

---

## High-level design

- Add `DebugHooks` with optional callbacks:
  - `on_step(user_ctx, frame, pc, opcode) -> StepControl { cont, pause, abort }`
  - `on_message(user_ctx, params, phase)` where `phase ∈ { before, after }`, `params = CallParams`
- Store on `Evm` as `debug_hooks: ?DebugHooks`
- Expose `Evm.set_debug_hooks(hooks: ?DebugHooks)`
- In interpreter, compute `(pc, opcode)` via existing analysis and call `on_step` just before executing the opcode
- In `execution/system.zig`, call `on_message(.before)` before host call, `on_message(.after)` after result
- Pausing returns a dedicated debug pause; resumption continues from same `Frame.instruction`
- Aborting returns a dedicated debug abort

Zero overhead:

- Guarded by nullable function pointer branches
- No allocations

---

## Where to inject hooks (precise locations)

### 1) Interpreter loop: `src/evm/evm/interpret.zig`

Use the same PC/opcode computation as tracing and invoke `on_step` before `op_fn`.

```52:73:src/evm/evm/interpret.zig
            if (comptime build_options.enable_tracing) {
                if (self.tracer) |writer| {
                    // Derive index of current instruction for tracing
                    const base: [*]const @TypeOf((frame.instruction).*) = instructions.ptr;
                    const idx = (@intFromPtr(frame.instruction) - @intFromPtr(base)) / @sizeOf(@TypeOf((frame.instruction).*));
                    if (idx < analysis.inst_to_pc.len) {
                        const pc_u16 = analysis.inst_to_pc[idx];
                        if (pc_u16 != std.math.maxInt(u16)) {
                            const pc: usize = pc_u16;
                            const opcode: u8 = if (pc < analysis.code_len) analysis.code[pc] else 0x00;
                            const stack_len: usize = frame.stack.size();
                            const stack_view: []const u256 = frame.stack.data[0..stack_len];
                            const gas_cost: u64 = 0; // Block-based validation; per-op gas not tracked here
                            const mem_size: usize = frame.memory.size();
                            var tr = Tracer.init(writer);
                            _ = tr.trace(pc, opcode, stack_view, frame.gas_remaining, gas_cost, mem_size, @intCast(frame.depth)) catch {};
                        }
                    }
                }
            }
```

Advance is here (pause must return before this):

```176:178:src/evm/evm/interpret.zig
        try op_fn(frame_opaque);
        frame.instruction = next_instruction;
```

Insert `on_step` where `(pc, opcode)` is available, just before `op_fn`.

### 2) Message hooks around CALL-family

`src/evm/execution/system.zig` has handlers for CALL/CALLCODE/DELEGATECALL/STATICCALL. Inject hooks before and after host calls.

Representative CALL site:

```932:951:src/evm/execution/system.zig
    const call_params = CallParams{ .call = .{
        .caller = frame.contract_address,
        .to = to_address,
        .value = value,
        .input = args,
        .gas = gas_limit,
    } };

    const call_result = host.call(call_params) catch {
        frame.host.revert_to_snapshot(snapshot);
        try frame.stack.append(0);
        return;
    };
```

Add `.before` right after `call_params` is built, `.after` right after `call_result`.

Do the same in `op_callcode`, `op_delegatecall`, `op_staticcall`.

### 3) Message hooks around CREATE-family

CREATE params:

```598:607:src/evm/execution/system.zig
    const call_params = CallParams{
        .create = .{ .caller = frame.contract_address, .value = value, .init_code = init_code, .gas = gas_for_create },
    };
```

CREATE2 params:

```746:754:src/evm/execution/system.zig
    const call_params = CallParams{
        .create2 = .{ .caller = frame.contract_address, .value = value, .init_code = init_code, .salt = salt, .gas = gas_for_create },
    };
```

Add `.before`/`.after` around host calls for both.

### Parameter type for `on_message`

Use `CallParams` from `src/evm/host.zig`, exported via `src/evm/root.zig`.

```147:151:src/evm/root.zig
pub const CallParams = @import("host.zig").CallParams;
```

```6:54:src/evm/host.zig
pub const CallParams = union(enum) { call, callcode, delegatecall, staticcall, create, create2 };
```

---

## API to add

Create `src/evm/debug_hooks.zig` and export in `src/evm/root.zig`.

```zig
pub const StepControl = enum { cont, pause, abort };
pub const MessagePhase = enum { before, after };

pub const OnStepFn = *const fn (
    user_ctx: ?*anyopaque,
    frame: *@import("frame.zig").Frame,
    pc: usize,
    opcode: u8,
) anyerror!StepControl;

pub const OnMessageFn = *const fn (
    user_ctx: ?*anyopaque,
    params: *const @import("host.zig").CallParams,
    phase: MessagePhase,
) anyerror!void;

pub const DebugHooks = struct {
    user_ctx: ?*anyopaque = null,
    on_step: ?OnStepFn = null,
    on_message: ?OnMessageFn = null,
};
```

Export:

```zig
pub const DebugHooks = @import("debug_hooks.zig");
pub const StepControl = DebugHooks.StepControl;
pub const MessagePhase = DebugHooks.MessagePhase;
```

Add to `src/evm/evm.zig`:

```zig
debug_hooks: ?@import("debug_hooks.zig").DebugHooks = null,

pub fn set_debug_hooks(self: *Evm, hooks: ?@import("debug_hooks.zig").DebugHooks) void {
    self.debug_hooks = hooks;
}
```

---

## Interpreter integration details

Inside `interpret.zig`, after computing `(pc, opcode)` and before calling `op_fn`, add:

```zig
if (self.debug_hooks) |hooks| {
    if (hooks.on_step) |cb| {
        const decision = cb(hooks.user_ctx, frame, pc, opcode) catch return ExecutionError.Error.DebugAbort;
        switch (decision) {
            .cont => {},
            .pause => return ExecutionError.Error.DebugPaused,
            .abort => return ExecutionError.Error.DebugAbort,
        }
    }
}
```

Add to `ExecutionError.Error` two debug-only errors in `src/evm/execution/execution_error.zig`:

- `DebugAbort`
- `DebugPaused`

Pause leaves `frame.instruction` unchanged and returns `DebugPaused`. Resumption simply re-enters `interpret(self, frame)`.

---

## Message integration details

For each of `op_call`, `op_callcode`, `op_delegatecall`, `op_staticcall`, `op_create`, `op_create2` in `src/evm/execution/system.zig`:

Before host call:

```zig
const evm_ptr = @as(*Evm, @ptrCast(@alignCast(frame.host.ptr)));
if (evm_ptr.debug_hooks) |hooks| {
    if (hooks.on_message) |on_msg| {
        on_msg(hooks.user_ctx, &call_params, .before) catch return ExecutionError.Error.DebugAbort;
    }
}
```

After receiving `call_result`:

```zig
if (evm_ptr.debug_hooks) |hooks| {
    if (hooks.on_message) |on_msg| {
        on_msg(hooks.user_ctx, &call_params, .after) catch return ExecutionError.Error.DebugAbort;
    }
}
```

Invoke hooks before freeing any `output` buffers when applicable.

---

## Types you’ll interact with

### Frame (hot fields)

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

### Instruction and PC mapping

```55:61:src/evm/instruction.zig
pub const Instruction = struct {
    opcode_fn: ExecutionFunc,
    arg: AnalysisArg,
    next_instruction: *const Instruction = undefined,
    pub const STOP: Instruction = .{ .opcode_fn = StopHandler, .arg = .none };
};
```

PC mapping uses `analysis.inst_to_pc[idx]` where `idx` is computed from the instruction pointer distance (see tracing block).

### CallParams

```6:54:src/evm/host.zig
pub const CallParams = union(enum) {
    call:       struct { caller: Address, to: Address, value: u256, input: []const u8, gas: u64 },
    callcode:   struct { caller: Address, to: Address, value: u256, input: []const u8, gas: u64 },
    delegatecall: struct { caller: Address, to: Address, input: []const u8, gas: u64 },
    staticcall: struct { caller: Address, to: Address, input: []const u8, gas: u64 },
    create:     struct { caller: Address, value: u256, init_code: []const u8, gas: u64 },
    create2:    struct { caller: Address, value: u256, init_code: []const u8, salt: u256, gas: u64 },
};
```

---

## Performance and safety constraints

- Guard invocations with `if (self.debug_hooks) |hooks| { ... }`
- Guard individual callbacks: `if (hooks.on_step) |cb| { ... }`
- No allocations in hot paths
- Preserve STOP/RETURN/REVERT semantics
- Do not advance `frame.instruction` when pausing
- Hooks receive ephemeral borrows; do not store pointers beyond callback

---

## Exact edits checklist

1. Create `src/evm/debug_hooks.zig` with `StepControl`, `MessagePhase`, `OnStepFn`, `OnMessageFn`, `DebugHooks`
2. Export types in `src/evm/root.zig`
3. Add `debug_hooks` field and `set_debug_hooks` to `src/evm/evm.zig`
4. Add `DebugAbort` and `DebugPaused` in `src/evm/execution/execution_error.zig`
5. Wire `on_step` in `src/evm/evm/interpret.zig`
6. Wire `on_message` in `src/evm/execution/system.zig` for CALL/CALLCODE/DELEGATECALL/STATICCALL/CREATE/CREATE2

---

## Testing plan

### on_step sequencing and pause

- Program: `PUSH1 0x01; PUSH1 0x02; ADD; STOP`
- Verify `on_step` receives `[PUSH1, PUSH1, ADD, STOP]` with correct PCs
- Pause on `ADD`: expect `error.DebugPaused`; resume and finish
- Abort on `ADD`: expect `error.DebugAbort`

### on_message before/after

- CALL: verify `.before` and `.after` phases with expected params
- CREATE/CREATE2: verify phases around creation
- STATICCALL: verify phases and no state changes

Hooks unset: no behavior change. Hook error: map to `DebugAbort`.

---

## Zig patterns (quick reference)

- Nullable function pointers

  ```zig
  if (hooks.on_step) |cb| {
      const res = cb(hooks.user_ctx, frame, pc, opcode) catch return ExecutionError.Error.DebugAbort;
  }
  ```

- anyopaque

  - Use `*anyopaque` for opaque contexts; cast back with `@ptrCast(@alignCast(...))` only when you own the pointer

- Error handling

  - Map hook errors to `DebugAbort`

- Keep hot paths lean; no allocations or formatting

---

## Example usage (consumer)

```zig
const evm_mod = @import("evm");
const DebugHooks = evm_mod.DebugHooks;
const StepControl = evm_mod.StepControl;

fn on_step(_: ?*anyopaque, _: *evm_mod.Frame, _: usize, _: u8) anyerror!StepControl { return .cont; }
fn on_message(_: ?*anyopaque, _: *const evm_mod.CallParams, _: evm_mod.MessagePhase) anyerror!void {}

var hooks = DebugHooks{ .on_step = on_step, .on_message = on_message };
vm.set_debug_hooks(hooks);
```

---

## Acceptance criteria

- APIs exported
- Hooks invoked at correct sites
- Zero-overhead when unset
- Tests cover sequence, pause, abort, and message phases
- All existing tests remain green
