# Step Debugging Integration: Instruction-Level Control + Validation

This document consolidates the previous phases (01–05) into a cohesive, practical step‑debugging system for Guillotine’s EVM. It documents current capabilities, exact integration points, and how stepping coordinates with validation and UI, with zero overhead when disabled.


## 1) Debugging Tracer: Capabilities and Hooks

Source: `src/evm/tracer.zig`

- Fields:
  - step_mode: bool, paused: bool, breakpoints: AutoHashMap(u32, void)
  - steps: ArrayList(ExecutionStep), state_snapshots: ArrayList(StateSnapshot)
  - total_instructions, total_gas_used, max_history
  - prestate_tracer: ?*PrestateTracer, prestate_enabled: bool
  - resume_idx: ?u32 (from doc 01; used by interpreter to resume after a pause)

- Core API used by interpreters:
  - setStepMode(bool), pause(), resumeExecution(), shouldPause(pc: u32) bool
  - add/remove/has/clearBreakpoints, getStepCount()
  - beforeOp(pc: u32, opcode: u8, FrameType: type, frame: *const FrameType)
  - afterOp(pc: u32, opcode: u8, FrameType: type, frame: *const FrameType)
  - onError(pc: u32, err: anyerror, FrameType: type, frame: *const FrameType)
  - captureState(pc, FrameType, frame) and internal captureStateForStep(...)

- Semantics used by stepping:
  - beforeOp sets `paused = true` when `step_mode` is enabled or `pc` matches a breakpoint
  - onError marks the current step, sets `paused = true`
  - resume index: on a pause request in the before-trace handler, the interpreter stores `resume_idx = opcode_handler_index` on the tracer so the next resume starts at the opcode handler, not the trace entry

- State capture:
  - ExecutionStep contains pc, opcode/opname, gas_before/after, stack/memory sizes, depth, error flags
  - StateSnapshot holds a shallow snapshot for UI/state timelines (pc, gas_remaining, stack copy, memory size, depth, timestamp)


## 2) Stepping Semantics in the Optimized Interpreter

Sources: `src/evm/frame_interpreter.zig`, `src/evm/plan.zig`, `src/evm/planner.zig`

- Trace injection (doc 01, considered implemented):
  - Planner optionally injects two generic trace handlers around each opcode: `trace_before_op_handler` and `trace_after_op_handler`
  - The PC→instruction-index map always points to the entry of the sequence (the before‑trace when injected)
  - `Plan.getNextInstruction(&idx, .OP)` advances `idx` beyond the current opcode’s sequence (and metadata) and returns the handler pointer to tail-call next; this preserves tail-call dispatch and prevents self-loops

- Generic trace handlers (doc 01, considered implemented):
  - `trace_before_op_handler`
    - Resolves current PC (O(1) via `idx_to_pc` with a tiny fallback to neighbors when at trace indices)
    - Computes opcode = `frame.bytecode[pc]`
    - Calls `frame.traceBeforeOp(pc, opcode)` which wraps `tracer.beforeOp(pc, opcode, Frame, frame)`
    - If the tracer requests a pause (step mode or breakpoint), sets `tracer.resume_idx = opcode_handler_index` and returns `error.ExecutionPaused`
    - Otherwise advances `instruction_idx` off the trace entry and tail-calls the opcode handler
  - `trace_after_op_handler`
    - Resolves PC/opcode identically
    - Calls `frame.traceAfterOp(pc, opcode)`
    - Advances to, and tail‑calls, the next opcode’s entry index

- Interpreter pause/resume (doc 01, considered implemented):
  - Error set includes `error.ExecutionPaused`
  - A debug entrypoint returns an `ExecutionResult` enum: `.Paused` or `.Completed`
  - On resume, if `tracer.take_resume_idx()` returns an index, execution starts at that index; otherwise from the initial entry

- Tail calls and stepping:
  - Because handlers tail‑call the returned pointer, `error.ExecutionPaused` must be raised in the trace‑before handler to unwind to the debug entrypoint without additional frames


## 3) Breakpoints and Instruction Boundaries

Source: `src/evm/tracer.zig`

- Breakpoints are a set of PCs (`AutoHashMap(u32, void)`) checked in `shouldPause(pc)`
- Breakpoint semantics are “break before execution of instruction at PC” (pause occurs in the before‑trace)
- Instruction boundaries are robust because PC resolution at trace indices uses `idx_to_pc` (O(1)) with a bounded neighbor fallback when needed


## 4) Minimal Interpreter + Block Tracking + Validation

Sources: doc 03, doc 04, doc 05 (considered implemented)

- Block tracking (doc 04): block entries at PC=0 and every JUMPDEST; optimized stream carries metadata; minimal mode validates via bitmap
- Dual execution (doc 05): a `DualExecutionController` advances both interpreters to synchronization points (block boundaries), captures `StateSnapshot`s, and compares gas/stack/memory/storage; divergences are recorded and surfaced to the UI
- Step+validate flow:
  - Instruction step runs in the optimized interpreter
  - When `step_granularity = Block` or when a breakpoint/condition triggers validation, controller runs the minimal interpreter to the matching boundary and compares states


## 5) WASM/FFI Debugging Controls

Source: `src/evm/frame_c.zig`, `src/guillotine-ts/src/wasm/loader.ts`

- Exported C/WASM debug API (maps 1:1 to DebuggingTracer semantics):
  - `evm_debug_frame_create(bytecode, len, gas)` → debug interpreter with DebuggingTracer
  - `evm_debug_set_step_mode(frame, enabled)` / `evm_debug_is_paused(frame)` / `evm_debug_resume(frame)`
  - `evm_debug_step(frame)` → sets step mode, resumes until the next pause (before‑trace), returns STOP on completion
  - `evm_debug_add_breakpoint(frame, pc)` / `remove` / `has` / `clear`
  - `evm_debug_get_step_count(frame)`

- TypeScript loader (`GuillotineWasm` in `wasm/loader.ts`) exposes a clean interface for debugger UIs to call the above


## 6) Devtool UI Integration Points

Sources: `src/devtool/evm.zig`, `src/devtool/debug_state.zig`

- Current UI exposes an analysis‑first stepping model with:
  - Instruction index (`currentInstructionIndex`) and block boundaries (`currentBlockStartIndex`)
  - Stack, memory, storage, return data, and per‑block opcode views (`EvmStateJson`)

- Integration plan:
  - For optimized single‑interpreter stepping, keep the current `DevtoolEvm.stepExecute()` semantics
  - For tracer‑driven stepping (WASM/remote), use the `evm_debug_*` FFI; serialize state with the existing `serializeEvmState`, augmenting with tracer snapshots when available
  - Add optional validation toggles: `.None | .Sampling | .Full`, triggering dual‑execution comparisons at block boundaries and on user commands

- User controls (mapping to CLI and WASM):
  - Step: single instruction (before‑trace pause)
  - Continue: run until next breakpoint or completion
  - RunToBlock: run until next block boundary
  - ValidateNow: force dual-exec validation at current point
  - SwitchMode: toggle optimized/minimal or enable dual‑execution


## 7) Zero‑Overhead When Disabled

Sources: `src/evm/frame_config.zig`, doc 01

- Compile‑time elimination via `FrameConfig.TracerType = null` removes the tracer field and all calls
- Planner’s trace injection is gated at comptime and not emitted when disabled
- No allocations, no validation checks, direct opcode handler dispatch when tracing/validation are off


## 8) Performance Profiling Hooks

- Lightweight per‑opcode timing can be recorded in `trace_before_op_handler`/`trace_after_op_handler` using `std.time.nanoTimestamp()`
- Suggested structure:

```zig
const PerformanceProfile = struct {
    instruction_timings: std.AutoHashMap(u8, TimingStats),
    block_timings: std.AutoHashMap(u32, TimingStats),
    optimization_benefit: f32,
    const TimingStats = struct { count: u64, total_ns: u64, min_ns: u64, max_ns: u64 };
};
```

- Disabled by default; enabled only in debug/dev builds to avoid overhead


## 9) Concrete Answers to Key Questions

1) Minimize stepping overhead
   - Pause in before‑trace only; store `resume_idx`; use tail‑call chaining; eliminate tracing at comptime when disabled

2) Trigger automatic validation
   - At block boundaries; optionally on specific breakpoints (flagged breakpoints) or user command

3) Handle validation failures during step
   - Record divergence with detailed diffs; pause; let user choose Continue/Abort/Switch; surface via UI/CLI

4) What state to capture at each step
   - For instruction steps: gas, stack snapshot, memory size, depth, pc/opcode, error flag
   - For validation: full stack, memory, storage deltas, gas, pc for both interpreters

5) Visualize execution differences
   - Highlight current instruction/block; show dual state side‑by‑side; annotate divergences (gas/stack/memory/storage); link recent ExecutionSteps


## 10) Implementation Sketches (finalized interfaces)

Unified controller surface (hosted by devtool/CLI; calls into interpreters/FFI):

```zig
pub const StepGranularity = enum { instruction, block, transaction };
pub const ValidationMode = enum { none, sampling, full };

pub const StepResult = struct {
    state: enum { running, paused, completed, error },
    pc: ?u32,
    block_pc: ?u32,
    validation: ?ValidationResult,
    snapshot: DebuggingTracer.StateSnapshot,
};

pub const ValidationResult = struct {
    matched: bool,
    divergences: []const Divergence,
};

pub const UnifiedDebugController = struct {
    tracer: *DebuggingTracer,
    optimized: *FrameInterpreter,
    minimal: ?*MinimalInterpreter,
    mode: ValidationMode,
    granularity: StepGranularity,
    pub fn step_single(self: *UnifiedDebugController) !StepResult { /* orchestrates the steps as described */ }
};
```

Enhanced breakpoint (optional features layered over base PC set):

```zig
const EnhancedBreakpoint = struct {
    pc: u32,
    validate_here: bool = false,
    capture_full_state: bool = false,
};
```


## 11) Code References Collected

- Tracer implementations and API: `src/evm/tracer.zig`
- Optimized interpreter and trace handlers: `src/evm/frame_interpreter.zig` (trace_before_op_handler, trace_after_op_handler)
- Frame configuration and tracer comptime wiring: `src/evm/frame_config.zig`
- Planner/Plan (trace injection and next‑handler semantics): `src/evm/planner.zig`, `src/evm/plan.zig`
- C/WASM debug API: `src/evm/frame_c.zig`; TS loader: `src/guillotine-ts/src/wasm/loader.ts`
- Devtool state and JSON serialization: `src/devtool/evm.zig`, `src/devtool/debug_state.zig`


## 12) Test Plan (stepping + validation)

```zig
test "step debugging integrates with validation" {
    // 1) Create optimized + minimal interpreters over the same bytecode
    // 2) Enable trace injection and DebuggingTracer
    // 3) Step a few instructions; expect before-trace pauses (Paused state)
    // 4) Set breakpoint and Continue; expect pause at that PC
    // 5) Enable validation=full and RunToBlock; compare states at boundary
    // 6) Simulate divergence; verify it’s reported and execution pauses
}
```


## 13) UI Data Requirements (recap)

- Current position: instruction index and resolved PC
- Block boundaries with metadata (gas cost, stack req, max growth)
- Stack, memory, storage changes; return data
- Tracer snapshots and recent ExecutionSteps
- Validation results and divergence details
- Optional performance metrics (instruction and block timings)


## 14) Notes and Gaps

- The interpreter-level support (trace injection, `getNextInstruction` semantics, `ExecutionPaused`, and `resume_idx`) is assumed implemented per doc 01 and verified by the C/WASM debug APIs calling into DebuggingTracer
- Devtool currently runs an analysis‑first local stepper; wiring it to the WASM debug APIs remains straightforward and can be option‑gated
- All tracing/validation code paths remain fully eliminated when `FrameConfig.TracerType = null`

This completes the integration research: stepping, breakpoints, validation, and UI tie in cleanly with zero‑overhead when disabled.

### Implementation Checklist

- [ ] Create UnifiedDebugController
- [ ] Integrate with trace injection (doc 01)
- [ ] Add step granularity control
- [ ] Implement validation triggers
- [ ] Create enhanced breakpoints
- [ ] Add state capture optimization
- [ ] Implement performance profiling
- [ ] Create visualization data export
- [ ] Add debug command processing
- [ ] Comprehensive integration tests

## Debugging Workflows

### Workflow 1: Performance Analysis
1. Run optimized with profiling
2. Identify slow blocks
3. Compare with minimal execution
4. Analyze optimization impact

### Workflow 2: Correctness Validation
1. Enable dual execution
2. Set validation points
3. Step through execution
4. Investigate divergences

### Workflow 3: Educational Mode
1. Run minimal for clarity
2. Show each instruction
3. Explain state changes
4. Compare with optimized

Document implementation for each workflow.

## UI Integration Specification

### Required APIs
```zig
// TODO: Define after research:
pub fn getDebugState() !DebugState
pub fn setBreakpoint(bp: EnhancedBreakpoint) !void
pub fn clearBreakpoint(pc: u32) !void
pub fn getExecutionTrace() ![]const TraceEntry
pub fn getStateComparison() !ComparisonView
```

## Performance Targets

Research and set targets:
- Step latency: < 10ms
- Validation overhead: < 20%
- State capture: < 1MB/step
- UI update rate: 60fps

## Next Steps

Complete research to provide:
1. Full integration architecture
2. Performance optimization strategies
3. UI communication protocol
4. Testing methodology
5. Complete implementation guide
