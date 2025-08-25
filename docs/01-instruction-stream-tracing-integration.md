# Instruction-Stream Tracing: Clean Injection, Zero-Cost When Disabled

This document specifies a clean, minimal, and fully-implementable design that:

- Uses the existing `trace_before_op_handler` and `trace_after_op_handler` (no per-opcode wrappers)
- Preserves tail-call dispatch
- Provides step-by-step execution via the existing `DebuggingTracer`
- Adds zero overhead when tracing is disabled (compile-time elimination)
- Keeps a consistent PC ↔ instruction-index mapping in the presence of injected trace elements

Everything below is precise enough for a Zig beginner to implement without guessing.


**Scope**
- We do not change opcode semantics or add new per-opcode handlers/wrappers.
- We do inject two generic trace handlers into the instruction stream optionally at plan-build time.
- We preserve the existing planner/plan architecture and handler tables.


## Current State Validation

- `src/evm/frame_interpreter.zig` defines generic trace handlers:
  - `trace_before_op_handler` and `trace_after_op_handler` (around line ~2560)
  - These currently call `self.tracer.beforeOp(Frame, self)` / `self.tracer.afterOp(Frame, self)` which does not match the tracer API; see below for the required fix.
  - They currently compute `next_handler = plan_ptr.instructionStream[interpreter.instruction_idx].handler` without adjusting `instruction_idx`, which will loop on themselves if injected. We will correct this.

- `src/evm/frame.zig` exposes helper methods on `Frame` to call the tracer with the correct signature:
  - `traceBeforeOp(self, pc: u32, opcode: u8)` and `traceAfterOp(self, pc: u32, opcode: u8)`
  - These wrap `self.tracer.beforeOp(pc, opcode, Self, self)` and `self.tracer.afterOp(...)` with the correct types.

- `src/evm/tracer.zig` provides `NoOpTracer` and `DebuggingTracer` with APIs:
  - `beforeOp(pc, opcode, FrameType, *const FrameType)` and `afterOp(...)`
  - `DebuggingTracer` already has `step_mode`, `paused`, breakpoint APIs, and state capture; it lacks a small “resume index” field. We’ll add that so the before-trace can pause cleanly and the interpreter can resume.

- `src/evm/planner.zig` builds the instruction stream (`create_instruction_stream`) and maps `pc_to_instruction_idx` and a dense variant. There is currently no trace injection.

- `src/evm/plan.zig` implements `getNextInstruction`. For clean chaining with injected trace elements, this function must return the NEXT handler pointer (not the current one), after advancing `instruction_idx`. If it returns the current handler pointer, dispatch loops incorrectly. We specify the corrected behavior below.

- `FrameInterpreter.getCurrentPc()` builds a reverse `idx_to_pc` map at init time, but only fills entries for indices that are mapped from `pc_to_instruction_idx`. With injected trace elements, we must guarantee that `getCurrentPc()` resolves the PC reliably at trace indices as well. We specify a robust method below that remains O(1) in the common case and O(1–3) with tiny constant time when needed.


## Design Overview

- Planner optionally injects two generic trace handler entries per opcode: one before and one after.
- When injected, the “entry index” for an opcode becomes the `trace_before_op_handler` index. When not injected, the entry index is the opcode handler index itself. The PC→index mapping always returns the entry index.
- The two generic trace handlers compute the current PC and opcode dynamically using the interpreter’s existing state and the frame’s bytecode. No per-opcode wrappers are generated.
- `getNextInstruction` returns the next handler pointer after advancing the interpreter’s instruction index. This keeps all opcode handlers unchanged while making the chaining logic natural for both injected and non-injected streams.
- Step/pause is implemented by the before-trace handler: when `DebuggingTracer` indicates pause (step mode or breakpoint), it stores a resume instruction index and returns `error.ExecutionPaused`. The interpreter loop catches this and returns `.Paused` to the caller.
- Zero-cost when tracing disabled: trace injection and its code paths are eradicated at compile time (no extra handlers in the stream; no injected calls).


## Invariants

- Instruction stream elements per opcode:
  - No tracing: `[opcode_handler]` or `[opcode_handler, metadata]`.
  - With tracing: `[trace_before, opcode_handler, (metadata?), trace_after]`.

- “Entry index” for a PC is always the first element of that opcode’s sequence:
  - No tracing: `entry = opcode_handler index`.
  - With tracing: `entry = trace_before index`.

- `plan.getNextInstruction(&idx, OPCODE)` advances `idx` beyond the current opcode’s sequence (including metadata if present) and returns the handler pointer to call next (trace_after when injected, or the next opcode’s entry handler otherwise). Handlers tail-call the returned pointer via `dispatchNext`.


## Step-by-Step Implementation

The following changes are surgical and minimal. Implement in the listed order.


### 1) Implement `Plan.getNextInstruction` to return the next handler pointer

File: `src/evm/plan.zig`

- Current behavior returns the current handler pointer, then advances the index, which breaks chaining when used with tail calls.
- Fix: Advance the index first, then return the handler pointer at the advanced index.

Pseudo-diff (conceptual):

```
pub fn getNextInstruction(self: *const Self, idx: *InstructionIndexType, comptime opcode: anytype) *const HandlerFn {
    const has_metadata = comptime /* existing switch */;

    // Advance past current instruction and its metadata
    idx.* += 1;
    if (has_metadata) idx.* += 1;

    // Now return the NEXT handler pointer (or end-of-stream if at end)
    if (idx.* >= self.instructionStream.len) return &end_of_stream_handler;
    return self.instructionStream[idx.*].handler;
}
```

No other code needs changing in opcode handlers; they already do:

```
const next = plan.getNextInstruction(&interpreter.instruction_idx, .OPCODE);
return dispatchNext(next, self, plan);
```

With the corrected semantics, this now chains naturally.


### 2) Implement the two generic trace handlers

File: `src/evm/frame_interpreter.zig`

- Update the two existing handlers to:
  - Compute PC robustly at trace indices.
  - Compute opcode as `frame.bytecode[pc]`.
  - Call `frame.traceBeforeOp(pc, opcode)` / `frame.traceAfterOp(pc, opcode)` (not `self.tracer.beforeOp(Frame, self)`).
  - Adjust `instruction_idx` to move off the trace entry onto the correct next element.
  - Handle pause/step before executing the opcode (in before-trace only):
    - If paused, store `resume_idx = interpreter.instruction_idx + 1` (the opcode handler index) and return `error.ExecutionPaused`.

Concrete logic:

- `trace_before_op_handler`:
  - Resolve PC:
    - Try `interpreter.getCurrentPc()`.
    - If null, use neighbor indices: if `idx_to_pc[instruction_idx + 1]` is valid use that; else if `instruction_idx > 0`, try `idx_to_pc[instruction_idx - 1]`.
  - `const opcode = frame.bytecode[pc]`.
  - `frame.traceBeforeOp(pc, opcode)`.
  - If tracer is `DebuggingTracer` and `shouldPause(pc)` (or `paused` flag is set by `beforeOp`), set tracer’s `resume_idx = instruction_idx + 1` and return `error.ExecutionPaused`.
  - Else: `instruction_idx += 1;` then `dispatchNext(plan.instructionStream[instruction_idx].handler, ...)`.

- `trace_after_op_handler`:
  - Resolve PC in the same way as above (for reporting the “after” event):
  - `frame.traceAfterOp(pc, opcode)`.
  - Then advance: `instruction_idx += 1;` and `dispatchNext(plan.instructionStream[instruction_idx].handler, ...)` (this lands on the next opcode’s entry index, i.e., the next `trace_before` if injected, or the next opcode handler if not).


### 3) Add a small resume index to `DebuggingTracer`

File: `src/evm/tracer.zig`

- In `DebuggingTracer` struct, add:

```
resume_idx: ?u32 = null,

pub fn set_resume_idx(self: *Self, idx: u32) void {
    self.resume_idx = idx;
}

pub fn take_resume_idx(self: *Self) ?u32 {
    const i = self.resume_idx;
    self.resume_idx = null;
    return i;
}
```

- No changes to `NoOpTracer`.


### 4) Add pause/error glue in the interpreter

File: `src/evm/frame_interpreter.zig`

- Extend `pub const Error = ... || error{ ExecutionPaused }` in the interpreter type.
- Add a lightweight result enum:

```
pub const ExecutionResult = enum { Completed, Paused };
```

- Provide two execution entrypoints (compile-time selected):
  - `fn executeNormal(self: *Self) !void` (existing behavior, returns on STOP)
  - `fn executeDebug(self: *Self) !ExecutionResult`:
    - If `self.frame.tracer.take_resume_idx()` returns an index, set `self.instruction_idx = it` and let `start_handler = plan.instructionStream[it].handler`.
    - Else `start_handler = plan.instructionStream[0].handler`.
    - Call `start_handler(&self.frame, self.plan)` and catch errors:
      - `error.STOP` → return `.Completed`
      - `error.ExecutionPaused` → return `.Paused`
      - any other → return the error

- A convenience `pub fn execute(self: *Self) !void` for production builds can continue to call the normal path. For debugging builds, expose `pub fn run_until_pause_or_stop(self: *Self) !ExecutionResult` and `pub fn stepSingle(self: *Self) !ExecutionResult` that set tracer mode appropriately:
  - `stepSingle`: set `step_mode = true`, clear `paused`, call `executeDebug`, restore `step_mode = false`.

These APIs provide stepping using injected generic trace handlers rather than per-opcode wrappers.


### 5) Planner: inject trace handlers conditionally at compile-time

File: `src/evm/planner.zig`

- Add a comptime boolean flag and two handler pointers to the instruction stream builder call path. The planner does not “know” about frames; callers pass the two generic trace handlers:

```
pub fn getOrAnalyze(
    self: *Self,
    bytecode: []const u8,
    handlers: [256]*const HandlerFn,
    hardfork: Hardfork,
    comptime inject_tracing: bool,
    trace_before: if (inject_tracing) *const HandlerFn else void,
    trace_after:  if (inject_tracing) *const HandlerFn else void,
) !*const PlanType {
    // include inject_tracing in cache key
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(bytecode);
    hasher.update(std.mem.asBytes(&hardfork));
    const inject_flag: u8 = if (inject_tracing) 1 else 0;
    hasher.update(&[_]u8{inject_flag});
    const key = hasher.final();
    // cache lookup as today...
    // call create_instruction_stream(self.allocator, handlers, inject_tracing, trace_before, trace_after)
}
```

- Update `create_instruction_stream` signature accordingly:

```
pub fn create_instruction_stream(
    self: *Self,
    allocator: std.mem.Allocator,
    handlers: [256]*const HandlerFn,
    comptime inject_tracing: bool,
    trace_before: if (inject_tracing) *const HandlerFn else void,
    trace_after:  if (inject_tracing) *const HandlerFn else void,
) !PlanType
```

- Injection points while building the stream (Pass 2):
  - Before emitting the actual opcode handler, if `inject_tracing`, append `.handler = trace_before`.
  - Record `pc_to_instruction_idx.put(pc, current_stream_len)` AFTER appending `trace_before` (so the entry index maps to the trace_before element when injected, or to the opcode handler when not injected).
  - Append the opcode handler and (if needed) its metadata as today.
  - After the opcode handler (+metadata), if `inject_tracing`, append `.handler = trace_after`.
  - Maintain the dense array `pc_to_instruction_idx_dense` with the same “entry index” behavior.

This guarantees that jumps land on `trace_before` when tracing is enabled, so every opcode still triggers both before/after traces consistently even across control-flow transfers.


### 6) FrameInterpreter: pass trace handlers to the planner

File: `src/evm/frame_interpreter.zig`

- When initializing the interpreter and requesting a plan, pass the two generic trace handlers conditionally at comptime from the same `FrameInterpreter` type:

```
const plan_ptr = if (comptime config.TracerType != null)
    try planner.getOrAnalyze(bytecode, handlers, host.get_hardfork(), true, &trace_before_op_handler, &trace_after_op_handler)
else
    try planner.getOrAnalyze(bytecode, handlers, host.get_hardfork(), false, {}, {});
```

Note: Using `{}` placeholders for the else-branch types is a Zig trick to satisfy the comptime `if` type requirements; you can also define two overloads if preferred.


### 7) Robust PC resolution at trace indices

File: `src/evm/frame_interpreter.zig`

- Keep building `idx_to_pc` as today using `pc_to_instruction_idx`.
- Improve `getCurrentPc()` so it also resolves PCs at trace indices in constant time:
  - If `idx_to_pc[instruction_idx]` is valid, return it.
  - Else, if `instruction_idx + 1 < len`, return `idx_to_pc[instruction_idx + 1]` if valid.
  - Else, if `instruction_idx > 0`, return `idx_to_pc[instruction_idx - 1]` if valid.
  - Else, return null.

This covers both before-trace (pc at `idx+1`) and after-trace (pc at `idx-1` or `idx-2` when metadata exists). The window is ≤2 slots; overhead is negligible and only exists with tracing enabled.


## Zero-Cost When Disabled

- The `inject_tracing` flag is a comptime decision derived from `FrameConfig.TracerType != null` in the caller. When false:
  - No trace handlers are appended to the stream (identical stream footprint as today).
  - The before/after handlers and their code paths are not referenced in the plan and can be eliminated by the compiler.
  - The interpreter executes without any trace checks.


## PC ↔ Index Mapping Guarantees

- `Plan.getInstructionIndexForPc(pc)` returns the “entry index” of the opcode sequence for that PC:
  - With tracing: the index of `trace_before_op_handler`.
  - Without tracing: the index of the opcode handler.

- `FrameInterpreter.getCurrentPc()` correctly reports the PC at any index within an opcode sequence (trace_before, opcode, metadata, trace_after).


## Pause/Resume Semantics

- Pausing (step mode or breakpoint) occurs in `trace_before_op_handler` after `beforeOp`:
  - Set `tracer.paused = true` (already done by tracer based on mode/breakpoints).
  - Set `tracer.resume_idx = interpreter.instruction_idx + 1` (the opcode handler index).
  - Return `error.ExecutionPaused`.

- Resuming:
  - `executeDebug()` checks `tracer.take_resume_idx()`. If present, it starts from that index; otherwise from `0`.
  - The handler at `resume_idx` is the opcode handler itself (so resuming executes the opcode body next).


## Testing Plan

Add tests under `src/evm` covering both modes.

1) No tracing (TracerType = null):
   - Plan contains no trace handlers (stream size equals sum of opcode handlers plus metadata entries only).
   - `pc_to_instruction_idx` and `getInstructionIndexForPc` map to opcode handler indices.
   - A short bytecode (PUSH1 5, PUSH1 3, ADD, STOP) executes to completion and stack top is 8.

2) With tracing (TracerType = DebuggingTracer):
   - Plan contains before/after trace handlers around each opcode (3× elements per non-PUSH, 4× including metadata for PUSH, etc.).
   - `pc_to_instruction_idx` maps each PC to the trace_before index.
   - `getCurrentPc()` returns the correct PC at any of the four indices of an opcode sequence.
   - `stepSingle()` returns `.Paused` between steps and `.Completed` at STOP.

3) Jump correctness:
   - Build bytecode with a jump to a JUMPDEST and assert that after the jump the next handler invoked is the trace_before of the target opcode (in tracing mode), and the opcode handler itself in non-tracing mode.


## Practical Integration Notes

- Pass the trace handler pointers from the same `FrameInterpreter` type that defines them to ensure the `HandlerFn` types match (they are specialized by `PlanConfig`).
- Use the existing `dispatchNext(next_handler, frame, plan)` helper for all tail calls.
- Avoid `std.debug.print` in modules; use `log.zig` per project standards.
- Maintain cache correctness by including the `inject_tracing` flag in the planner cache key.


## Build & Test

- After making the changes, run `zig build && zig build test`.
- Note: In restricted environments, external downloads (e.g., blst via curl) may fail; run builds in a network-enabled environment when needed.


## Summary

This design injects two generic trace handlers into the instruction stream at plan time, controlled by a compile-time flag derived from `FrameConfig.TracerType`. It requires only small, contained changes:

- Fix `Plan.getNextInstruction` chaining semantics
- Correct and complete the two existing generic trace handlers
- Add a resume index to `DebuggingTracer` and interpreter pause glue
- Teach the planner to optionally inject trace handlers and map PCs to entry indices
- Pass handler pointers from `FrameInterpreter` to `Planner`
- Make `getCurrentPc()` robust at trace indices

It achieves zero overhead when tracing is disabled, consistent PC/index mapping, and clean step-by-step execution using the tracer that already exists.
