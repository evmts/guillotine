## PR 7: Frame Capture and UI

### Problem

The UI currently shows only per-step execution. For effective debugging and comprehension, we need a collapsible call tree of message frames (CALL/CALLCODE/DELEGATECALL/STATICCALL/CREATE/CREATE2). Each frame must capture lifecycle and summary: caller, callee/created address, value, gas forwarded, input/output sizes, status (success/revert), and the step range [start_step, end_step] it spans in the execution trace.

This PR implements frame capture at core tracing hooks and adds a sidebar UI to browse the call tree. Selection must filter the step list to the selected frame’s step range.

### Preconditions and context

- This PR builds on PR 1 (onStep/onMessage hooks) and PR 2 (standard in-process tracer). It uses those hooks to construct a frame timeline.
- The core already exposes: Frame state during interpretation, Host/CallParams for CALL/CREATE-family, and a minimal JSON tracer gated by `build_options.enable_tracing`.
- Key references:
  - Frame structure and fields you will access for context:

```40:63:src/evm/frame.zig
pub const Frame = struct {
    gas_remaining: u64,
    stack: Stack,
    analysis: *const CodeAnalysis,
    host: Host,
    memory: Memory,
    state: DatabaseInterface,
    contract_address: primitives.Address.Address,
    depth: u16,
    is_static: bool,
    caller: primitives.Address.Address,
    value: u256,
    input_buffer: []const u8 = &.{},
    output_buffer: []const u8 = &.{},
};
```

- Interpreter pre-step with PC/opcode mapping (where step index can be derived from `inst`):

```120:173:src/evm/evm/interpret.zig
dispatch: switch (instruction.tag) {
    .block_info => {
        pre_step(self, frame, instruction, &loop_iterations);
        const block_inst = analysis.getInstructionParams(.block_info, instruction.id);
        // ... charge gas, validate stack ...
        instruction = block_inst.next_inst;
        continue :dispatch instruction.tag;
    },
    .exec => {
        @branchHint(.likely);
        pre_step(self, frame, instruction, &loop_iterations);
        const exec_inst = analysis.getInstructionParams(.exec, instruction.id);
        const exec_fun = exec_inst.exec_fn;
        const next_instruction = exec_inst.next_inst;
        // Map instruction to pc (idx -> pc)
        const base: [*]const Instruction = analysis.instructions.ptr;
        const idx = (@intFromPtr(instruction) - @intFromPtr(base)) / @sizeOf(Instruction);
        var pc: usize = 0;
        if (idx < analysis.inst_to_pc.len) {
            const pc_u16 = analysis.inst_to_pc[idx];
            if (pc_u16 != std.math.maxInt(u16)) pc = pc_u16;
        }
        try exec_fun(frame);
        instruction = next_instruction;
        continue :dispatch instruction.tag;
    },
    // ... other tags ...
}
```

- Minimal JSON tracer already called inside `pre_step` when `enable_tracing` is on:

```36:69:src/evm/evm/interpret.zig
inline fn pre_step(self: *Evm, frame: *Frame, inst: *const Instruction, loop_iterations: *usize) void {
    if (comptime build_options.enable_tracing) {
        const analysis = frame.analysis;
        if (self.tracer) |writer| {
            const base: [*]const @TypeOf(inst.*) = analysis.instructions.ptr;
            const idx = (@intFromPtr(inst) - @intFromPtr(base)) / @sizeOf(@TypeOf(inst.*));
            if (idx < analysis.inst_to_pc.len) {
                const pc_u16 = analysis.inst_to_pc[idx];
                if (pc_u16 != std.math.maxInt(u16)) {
                    const pc: usize = pc_u16;
                    const opcode: u8 = if (pc < analysis.code_len) frame.analysis.code[pc] else 0x00;
                    const stack_len: usize = frame.stack.size();
                    const stack_view: []const u256 = frame.stack.data[0..stack_len];
                    const mem_size: usize = frame.memory.size();
                    var tr = Tracer.init(writer);
                    _ = tr.trace(pc, opcode, stack_view, frame.gas_remaining, 0, mem_size, @intCast(frame.depth)) catch {};
                }
            }
        }
    }
}
```

- CallParams union used by CALL/CREATE-family and concrete creation of params at opcode sites:

```7:15:src/evm/host.zig
pub const CallParams = union(enum) {
    call: struct { caller: Address, to: Address, value: u256, input: []const u8, gas: u64 },
    callcode: struct { caller: Address, to: Address, value: u256, input: []const u8, gas: u64 },
    delegatecall: struct { caller: Address, to: Address, input: []const u8, gas: u64 },
    staticcall: struct { caller: Address, to: Address, input: []const u8, gas: u64 },
    create: struct { caller: Address, value: u256, init_code: []const u8, gas: u64 },
    create2: struct { caller: Address, value: u256, init_code: []const u8, salt: u256, gas: u64 },
};
```

```918:926:src/evm/execution/system.zig
// Create call parameters
const call_params = CallParams{ .call = .{
    .caller = frame.contract_address,
    .to = to_address,
    .value = value,
    .input = args,
    .gas = gas_limit,
} };
```

```603:611:src/evm/execution/system.zig
// CREATE uses sender address + nonce for address calculation
const call_params = CallParams{
    .create = .{
        .caller = frame.contract_address,
        .value = value,
        .init_code = init_code,
        .gas = gas_for_create,
    },
};
```

```756:764:src/evm/execution/system.zig
// CREATE2 uses salt for deterministic address calculation
const call_params = CallParams{
    .create2 = .{
        .caller = frame.contract_address,
        .value = value,
        .init_code = init_code,
        .salt = salt,
        .gas = gas_for_create,
    },
};
```

### Goals

- Capture frame open/close anchored to message hooks; produce a hierarchical call tree.
- Record per-frame: caller, callee (or created address placeholder), value, forwarded gas, input size, output size preview (first N bytes), status (success/revert), and step range.
- Zero cost when tracer is disabled; no allocations on hot paths in release builds.
- UI: Sidebar `FrameTree` that filters the step view by selected frame range.

### High-level design

1. Extend onMessage hook to expose result for `.after` phase

- From PR 1, `on_message(user_ctx, params, phase)` is invoked around host calls. To capture output size and status at `.after`, add an optional `CallResultView` argument for the after-phase only:

```zig
pub const CallResultView = struct { success: bool, gas_left: u64, output: ?[]const u8 };

pub const OnMessageFn = *const fn (
    user_ctx: ?*anyopaque,
    params: *const CallParams,
    phase: MessagePhase,
    result: ?CallResultView, // null in .before; set in .after before buffers are freed
) anyerror!void;
```

- Invoke `.before` immediately after building `call_params` and before host call; invoke `.after` immediately after receiving `call_result` and before freeing any returned buffers.

2. StandardTracer: add Frame Timeline capture

- In `src/evm/tracing/standard_tracer.zig`, maintain:

  - `step_index: usize` incremented on every `on_pre_step`
  - `open_stack: ArrayList(usize)` holding indices of open frames (points into `frames`)
  - `frames: ArrayList(FrameNode)` flat list; each node carries `parent_index: ?usize` to reconstruct tree

- FrameNode definition (Zig):

```zig
const FrameNode = struct {
    id: usize, // index in frames
    parent: ?usize,
    depth: u16,
    // identity
    caller: [20]u8,
    callee: [20]u8, // for create, fill with computed address once known; else zero
    call_kind: enum { call, callcode, delegatecall, staticcall, create, create2 },
    // economics and IO
    value: u256,
    gas_forwarded: u64,
    input_size: usize,
    output_size: usize,
    output_preview: []u8, // owned truncated copy (<= config.preview_max_bytes)
    // lifecycle
    start_step: usize,
    end_step: usize, // filled on close
    status: enum { pending, success, revert },
};
```

- Config:

```zig
const FrameConfig = struct { preview_max_bytes: usize = 64 };
```

- Algorithm:
  - on_pre_step: `self.step_index += 1`.
  - on_message(before, params):
    - Determine `call_kind`, extract `caller`, `to`/created placeholder, `value`, `input_size`, `gas_forwarded` from the union.
    - Create node with `start_step = self.step_index`, `depth = frame.depth + 1` (callee depth), `status = .pending`.
    - Append to `frames`, push its index to `open_stack`.
  - on_message(after, params, result):
    - Peek last open frame (or scan back to the most recent matching `call_kind` if needed) and finalize:
      - `end_step = self.step_index`
      - `status = if (result.?.success) .success else .revert`
      - `output_size = result.?.output orelse &.{}` length
      - `output_preview = allocator.dupe(u8, result.?.output[0..min(N,len)])` guarded by config; if null, make empty slice.
    - For CREATE/CREATE2: if host returns created address bytes in output, store into `callee` and mark known address.
    - Pop from `open_stack`.

3. Map frame nodes to UI and step filtering

- Each frame holds a half-open step range `[start_step, end_step]` referring to the tracer’s step counter. The UI will filter the displayed lines to this range.
- Selection propagates to highlight currently visible steps.

### Exact core hook sites to wire onMessage(before/after)

- CALL:

```919:934:src/evm/execution/system.zig
// Before host call
// on_message(.before, &call_params)
const call_result = host.call(call_params) catch {
    frame.host.revert_to_snapshot(snapshot);
    try frame.stack.append(0);
    return;
};
// After result, before any buffer is freed
// on_message(.after, &call_params, .{ .success = call_result.success, .gas_left = call_result.gas_left, .output = call_result.output })
```

- CALLCODE:

```1048:1060:src/evm/execution/system.zig
// on_message(.before, &call_params)
const call_result = frame.host.call(call_params) catch {
    frame.host.revert_to_snapshot(snapshot);
    frame.stack.append_unsafe(0);
    return;
};
// on_message(.after, &call_params, .{ .success = call_result.success, .gas_left = call_result.gas_left, .output = call_result.output })
```

- DELEGATECALL:

```1155:1172:src/evm/execution/system.zig
const call_params = CallParams{ .delegatecall = .{ /* ... */ } };
// on_message(.before, &call_params)
const call_result = frame.host.call(call_params) catch {
    frame.host.revert_to_snapshot(snapshot);
    frame.stack.append_unsafe(0);
    return;
};
// on_message(.after, &call_params, .{ .success = call_result.success, .gas_left = call_result.gas_left, .output = call_result.output })
```

- STATICCALL:

```1300:1313:src/evm/execution/system.zig
const call_params = CallParams{ .staticcall = .{ /* ... */ } };
// on_message(.before, &call_params)
const call_result = frame.host.call(call_params) catch {
    frame.host.revert_to_snapshot(snapshot);
    frame.stack.append_unsafe(0);
    return;
};
// on_message(.after, &call_params, .{ .success = call_result.success, .gas_left = call_result.gas_left, .output = call_result.output })
```

- CREATE:

```603:618:src/evm/execution/system.zig
const call_params = CallParams{ .create = .{ /* ... */ } };
const snapshot = frame.host.create_snapshot();
// on_message(.before, &call_params)
const call_result = frame.host.call(call_params) catch {
    frame.host.revert_to_snapshot(snapshot);
    frame.stack.append_unsafe(0);
    return;
};
// on_message(.after, &call_params, .{ .success = call_result.success, .gas_left = call_result.gas_left, .output = call_result.output })
```

- CREATE2:

```756:776:src/evm/execution/system.zig
const call_params = CallParams{ .create2 = .{ /* ... */ } };
const snapshot = frame.host.create_snapshot();
// on_message(.before, &call_params)
const call_result = frame.host.call(call_params) catch {
    frame.host.revert_to_snapshot(snapshot);
    frame.stack.append_unsafe(0);
    return;
};
// on_message(.after, &call_params, .{ .success = call_result.success, .gas_left = call_result.gas_left, .output = call_result.output })
```

Implementation notes:

- The `.after` hook must be invoked before freeing any `call_result.output` buffer so tracers can safely copy a preview.
- For DELEGATECALL/STATICCALL, `value = 0` semantically; for DELEGATECALL caller/value are inherited from parent (we capture that in tracer from `CallParams` variant semantics).

### StandardTracer: implementation details

File: `src/evm/tracing/standard_tracer.zig`

- Public API additions:

  - `pub fn init(allocator: std.mem.Allocator, cfg: FrameConfig) !StandardTracer`
  - `pub fn deinit(self: *StandardTracer) void`
  - `pub fn handle(self: *StandardTracer) TracerHandle` (for EVM to store)
  - `pub fn get_frames(self: *StandardTracer) []const FrameNode` (borrowed; copy on serialize)

- Hook methods (called from EVM):

  - `pub fn on_pre_step(self: *StandardTracer, frame: *Frame, inst_idx: usize, pc: usize, opcode: u8) void { self.step_index += 1; }`
  - `pub fn on_message(self: *StandardTracer, frame: *Frame, params: *const CallParams, phase: MessagePhase, result: ?CallResultView) void { /* open/close as above */ }`

- Memory safety:
  - Duplicate at most `cfg.preview_max_bytes` from `result.output` into an owned buffer; free in `deinit`.
  - Do not store borrowed `[]const u8` slices; only store copies or compact summaries.
  - Use `defer` for freeing temporaries; `errdefer` for partially constructed nodes before appending.

### Devtool integration (JSON and UI)

1. Extend devtool JSON state with frames

- In `src/devtool/debug_state.zig`, add at end of `EvmStateJson`:

```zig
frames: []FrameJson,

pub const FrameJson = struct {
    id: usize,
    parent: ?usize,
    depth: u32,
    kind: []const u8, // "call"|"callcode"|"delegatecall"|"staticcall"|"create"|"create2"
    caller: []const u8, // 0x-hex address
    callee: []const u8, // 0x-hex address (or 0x for unknown during create-before-after)
    value: []const u8,  // 0x-hex u256
    gasForwarded: u64,
    inputSize: usize,
    outputSize: usize,
    outputPreview: []const u8, // 0x-hex, truncated
    startStep: usize,
    endStep: usize,
    status: []const u8, // "pending"|"success"|"revert"
};
```

- In `src/devtool/evm.zig::serializeEvmState`, populate `frames` from the in-process tracer if available. If PR 2 already added `Evm.set_tracer(...)`, you can retrieve and serialize the tracer’s frame list here. Keep the data bounded and hex-encode byte arrays.

2. Solid UI additions

- Update `src/devtool/solid/lib/types.ts`:

```ts
export interface FrameJson {
  id: number;
  parent: number | null;
  depth: number;
  kind:
    | 'call'
    | 'callcode'
    | 'delegatecall'
    | 'staticcall'
    | 'create'
    | 'create2';
  caller: string;
  callee: string;
  value: string;
  gasForwarded: number;
  inputSize: number;
  outputSize: number;
  outputPreview: string;
  startStep: number;
  endStep: number;
  status: 'pending' | 'success' | 'revert';
}

export interface EvmState {
  /* ...existing fields... */ frames: FrameJson[];
}
```

- Add `src/devtool/solid/components/evm-debugger/FrameTree.tsx`:

  - Render frames as a nested tree using `parent` and `id`.
  - On click, emit selected frame id and call a supplied callback to set step filters: `[state.currentInstructionIndex in [startStep, endStep]]`.
  - Show rows: depth-indented address (callee), value (short hex), gas, input/output sizes, status pill.

- Wire into `EvmDebugger.tsx`:
  - Maintain `selectedFrameId` and derived `[start,end]` from `state.frames`.
  - Pass filter range to `ExecutionStepsView` to only show steps within the selected frame.

### Zig API and coding standards (repo-specific)

- Follow CLAUDE.md:
  - Functions: snake_case; Types: PascalCase; Variables: snake_case.
  - Avoid `else` when possible; early returns for errors.
  - Single word variables are acceptable (e.g., `n`, `i`). Keep readability by extracting conditions into named variables.
  - Use `defer` immediately after allocation; use `errdefer` if ownership transfers later.
  - All allocations must be paired with deallocations; tracer must free any `output_preview` buffers in `deinit`.
  - No test helpers; tests inline and explicit.

### Tests

Add `test/evm/tracing/frame_timeline_test.zig` with explicit, self-contained tests (no helpers):

- nested CALLs

  - Bytecode A calls B, B calls C (can mock via Host implementation or use minimal call shims if available). Verify `frames.len == 3`, parent/child relations, depth increments, and monotonically increasing `[startStep,endStep]` nested ranges.

- revert path

  - Callee executes `REVERT`. Ensure the innermost frame records `status = .revert` and that parent frame still records `.success` for the CALL (with result 0 pushed). End step aligns after the call returns.

- create path
  - `CREATE` with empty initcode succeeds. Verify `callee` filled from returned 20-byte address and sizes captured.

Guidelines:

- After any code edits, run:
  - `zig build && zig build test`
- Fix any failures immediately (zero tolerance for broken builds/tests).

### Memory and performance guidelines

- Hooks must be zero-cost when unset: onMessage checks are nullable and compiled branches should be minimal.
- Do not allocate on hot paths when tracer is disabled. Guard tracer calls with compile-time `enable_tracing` and runtime null checks, as done in `pre_step`.
- Bounded copies only: `output_preview` and any other bytes must be limited by config.
- Never store borrowed slices from `frame` or `host`; copy then free in tracer’s `deinit`.

### Step index derivation (robustness)

- Use interpreter-provided `inst` pointer to derive instruction index and PC (see `pre_step`). Increment a tracer-local `step_index` on each `on_pre_step` call to produce a linear step space. This avoids relying on byte-level PCs directly.

### End-to-end acceptance criteria

- Frame timeline:
  - Captures every CALL/CALLCODE/DELEGATECALL/STATICCALL/CREATE/CREATE2 with accurate metadata
  - Has correct nesting and `[start_step,end_step]` ranges
  - Records correct status and output sizes
- UI:
  - Sidebar tree appears
  - Clicking a frame filters steps to that frame’s range and highlights it
- No overhead when tracer disabled; build passes with `zig build && zig build test`

### Migration plan if PR 1/2 are pending

If `DebugHooks` are not yet merged:

1. Add `src/evm/debug_hooks.zig` with `DebugHooks`, `MessagePhase`, `CallResultView`, `OnMessageFn`, `OnStepFn`.
2. Extend `src/evm/root.zig` to export them; add `debug_hooks` field and `set_debug_hooks` to `Evm`.
3. Insert onStep in `interpret.zig` and onMessage at the call sites above.
4. Implement `standard_tracer.zig` as the default consumer of these hooks.

Keep `.after` invocation strictly before any `call_result.output` free to allow preview capture.

### Practical tips and examples

- Converting addresses to/from bytes for timeline:

  - Use `std.fmt.fmtSliceHexLower(&addr)` for UI serialization.
  - For CALL outputs (not address), keep `callee` as provided `to`.
  - For CREATE/CREATE2, if return buffer is 20 bytes, memcpy into `[20]u8` and hex.

- Value formatting for UI: use `0x`-prefixed minimal hex (see `debug_state.formatU256Hex`).

- Example CALL `.before/.after` wiring (pseudocode):

```zig
if (evm_ptr.debug_hooks) |hooks| if (hooks.on_message) |on_msg| {
    on_msg(hooks.user_ctx, &call_params, .before, null) catch return ExecutionError.Error.DebugAbort;
}
const call_result = host.call(call_params) catch { /* ... */ };
if (evm_ptr.debug_hooks) |hooks| if (hooks.on_message) |on_msg| {
    const view = CallResultView{ .success = call_result.success, .gas_left = call_result.gas_left, .output = call_result.output };
    on_msg(hooks.user_ctx, &call_params, .after, view) catch return ExecutionError.Error.DebugAbort;
}
```

### Deliverables checklist

- Tracer:

  - Frame timeline data structures and capture logic
  - Configurable preview size; safe allocation/deallocation
  - Public getter for frames for devtool serialization

- Core:

  - onMessage `.before/.after` wired at the six opcode sites
  - `.after` passes `CallResultView` prior to buffer free

- Devtool:

  - Extend `EvmStateJson` with `frames: []FrameJson`
  - Serialize frames from tracer into JSON
  - Add `FrameTree.tsx`; wire selection to filter `ExecutionStepsView`

- Tests:
  - Nested calls, revert, create
  - Build and unit tests green

With the above, you can implement PR 7 end-to-end with precise integration points, safe memory ownership, and a minimal-yet-informative UI.
