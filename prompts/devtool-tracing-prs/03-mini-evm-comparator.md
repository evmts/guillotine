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

---

## Comprehensive implementation guide (grounded in current code)

This section expands the spec into a step-by-step, code-anchored guide, with exact types, ownership rules, and safe Zig patterns to implement the PR.

### Codebase anchors you will use

- Mini EVM reference executor loop:

```196:423:src/evm/evm/call_mini.zig
pub inline fn call_mini(self: *Evm, params: CallParams) ExecutionError.Error!CallResult {
    // ... simplified interpreter using table.get_operation(op), inline STOP/RETURN/REVERT/PUSH/JUMP/JUMPI/PC/JUMPDEST
}
```

- Primary interpreter and pc derivation (already present for tracing):

```85:1762:src/evm/evm/interpret.zig
pub fn interpret(self: *Evm, frame: *Frame) ExecutionError.Error!void {
    // block-based dispatcher; computing pc via inst_to_pc for tracing
}
```

```150:171:src/evm/evm/interpret.zig
const base: [*]const Instruction = analysis.instructions.ptr;
const idx = (@intFromPtr(instruction) - @intFromPtr(base)) / @sizeOf(Instruction);
var pc: usize = 0;
if (idx < analysis.inst_to_pc.len) {
    const pc_u16 = analysis.inst_to_pc[idx];
    if (pc_u16 != std.math.maxInt(u16)) pc = pc_u16;
}
```

- CALL-family op implementations (inject compare right after or around host.call):

```831:972:src/evm/execution/system.zig
pub fn op_call(context: *anyopaque) ExecutionError.Error!void {
    // ... build CallParams ...
    const call_result = host.call(call_params) catch { /* revert snapshot, push 0 */ };
    // <insert per-call shadow comparison here>
}
```

- `CallParams` union and `Host` API:

```1:124:src/evm/host.zig
pub const CallParams = union(enum) { call, callcode, delegatecall, staticcall, create, create2 };
pub const Host = struct { /* vtable includes call, emit_log, snapshots, set_output/get_output, access_* */ };
```

### Shadow modes and configuration

- Add `src/evm/debug/shadow.zig` with:

```zig
pub const ShadowMode = enum { off, per_call, per_step };

pub const ShadowConfig = struct {
    mode: ShadowMode = .per_call,
    stack_compare_limit: usize = 64,
    memory_window: usize = 256,
};

pub const ShadowMismatch = struct {
    context: enum { per_call, per_step },
    op_pc: usize = 0,
    field: enum { success, gas_left, output, logs, storage, stack, memory, pc },
    lhs_summary: []const u8,
    rhs_summary: []const u8,
};

pub fn compare_call_results(lhs: @import("../evm/call_result.zig").CallResult, rhs: @import("../evm/call_result.zig").CallResult, allocator: std.mem.Allocator) !?ShadowMismatch {
    if (lhs.success != rhs.success) return try diff(.{ .context = .per_call, .field = .success }, allocator);
    if (lhs.gas_left != rhs.gas_left) return try diff(.{ .context = .per_call, .field = .gas_left }, allocator);
    const lo = lhs.output orelse &.{};
    const ro = rhs.output orelse &.{};
    if (lo.len != ro.len or !std.mem.eql(u8, lo, ro)) return try diff(.{ .context = .per_call, .field = .output }, allocator);
    return null;
}

pub fn compare_step(lhs: *@import("../frame.zig").Frame, rhs: *@import("../frame.zig").Frame, pc_lhs: usize, pc_rhs: usize, cfg: ShadowConfig, allocator: std.mem.Allocator) !?ShadowMismatch {
    if (pc_lhs != pc_rhs) return try diff(.{ .context = .per_step, .op_pc = pc_lhs, .field = .pc }, allocator);
    if (lhs.gas_remaining != rhs.gas_remaining) return try diff(.{ .context = .per_step, .op_pc = pc_lhs, .field = .gas_left }, allocator);
    const sz_l = lhs.stack.size();
    const sz_r = rhs.stack.size();
    if (sz_l != sz_r) return try diff(.{ .context = .per_step, .op_pc = pc_lhs, .field = .stack }, allocator);
    const n = @min(cfg.stack_compare_limit, sz_l);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const l = (lhs.stack.current - 1 - i)[0];
        const r = (rhs.stack.current - 1 - i)[0];
        if (l != r) return try diff(.{ .context = .per_step, .op_pc = pc_lhs, .field = .stack }, allocator);
    }
    return null;
}
```

Implementation note: `diff` is a small helper that formats summaries; ensure any allocations from `allocator` are documented and freed by the caller of `compare_*`.

Add to `src/evm/evm.zig` fields (default off in release builds):

```zig
pub const DebugShadow = @import("debug/shadow.zig");
shadow_mode: DebugShadow.ShadowMode = .off,
shadow_cfg: DebugShadow.ShadowConfig = .{},
last_shadow_mismatch: ?DebugShadow.ShadowMismatch = null,
```

### Mini EVM step API (extract from loop)

Add to `src/evm/evm/call_mini.zig`:

```zig
pub fn execute_single_op(self: *Evm, frame: *Frame, code: []const u8, pc: usize) ExecutionError.Error!usize {
    const opcode = code[pc];
    const opmeta = self.table.get_operation(opcode);
    if (opmeta.undefined) return ExecutionError.Error.InvalidOpcode;
    if (frame.gas_remaining < opmeta.constant_gas) return ExecutionError.Error.OutOfGas;
    frame.gas_remaining -= opmeta.constant_gas;
    if (frame.stack.size() < opmeta.min_stack) return ExecutionError.Error.StackUnderflow;
    if (frame.stack.size() > opmeta.max_stack) return ExecutionError.Error.StackOverflow;
    // Inline the special cases identical to the existing loop (STOP/RETURN/REVERT/PC/JUMP/JUMPI/JUMPDEST/PUSH*)
    // Otherwise dispatch:
    const context: *anyopaque = @ptrCast(&frame);
    try opmeta.execute(context);
    return pc + 1;
}

pub fn call_mini_shadow(self: *Evm, params: CallParams, mode: enum { per_call, per_step }) ExecutionError.Error!CallResult {
    if (mode == .per_call) return try self.call_mini(params);
    // For per_step, initialize the same frame and return success immediately; the comparator will drive steps via execute_single_op.
    return try self.call_mini(params);
}
```

Use the existing Mini loop as the source of truth for each special case and keep behavior identical (e.g., RETURN copies memory to host output, JUMP/JUMPI validate JUMPDEST in bytecode, PUSH assembles big-endian `u256`).

### Wire per-call comparator in system ops

In each of `op_call`, `op_callcode`, `op_delegatecall`, `op_staticcall`, `op_create`, `op_create2` (in `src/evm/execution/system.zig`):

1. Obtain `evm_ptr` from `frame.host.ptr` when needed:

```zig
const evm_ptr = @as(*Evm, @ptrCast(@alignCast(frame.host.ptr)));
```

2. Build `CallParams` (already done). If `evm_ptr.shadow_mode == .per_call`:

```zig
const mini_res = evm_ptr.call_mini_shadow(call_params, .per_call) catch |err| blk: {
    // Treat Mini internal error as a mismatch event; store and continue/fail in debug as desired
    break :blk CallResult{ .success = false, .gas_left = 0, .output = &.{} };
};
```

3. After `host.call`, compare results:

```zig
if (evm_ptr.shadow_mode == .per_call) {
    if (try DebugShadow.compare_call_results(call_result, mini_res, evm_ptr.allocator)) |mm| {
        evm_ptr.last_shadow_mismatch = mm;
        if (comptime (@import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe)) {
            return ExecutionError.Error.DebugAbort; // or a dedicated ShadowMismatch error
        }
    }
}
```

4. Respect ownership: the primary frees `call_result.output` after copying (already implemented). Do not free `mini_res.output` — Mini owns its copy (`self.mini_output`).

### Optional per-step driver

- Add a light hook in `interpret.zig` right after pc/opcode is known and before executing the opcode. If `shadow_mode == .per_step`, step Mini once via `execute_single_op`, then `compare_step` using the primary `pc` and Mini’s `next_pc`. On mismatch, set `last_shadow_mismatch` and return a debug-only error.
- Gate all of this behind a build option to avoid overhead in release.

### Ownership and gas correctness

- Output buffers: system ops free VM-owned buffers returned from `Host.call` after copying into caller memory:

```965:969:src/evm/execution/system.zig
if (call_result.output) |out_buf| { const evm_ptr = @as(*Evm, @ptrCast(@alignCast(frame.host.ptr))); evm_ptr.allocator.free(out_buf); }
```

- Mini keeps its own duplicate in `self.mini_output` and frees previous copy before storing new one:

```394:413:src/evm/evm/call_mini.zig
if (self.mini_output) |buf| { self.allocator.free(buf); self.mini_output = null; }
const copy = try self.allocator.dupe(u8, self.current_output);
self.mini_output = copy;
```

- Memory expansion must use `frame.memory.charge_and_ensure(frame, new_size)` when charging and `ensure_context_capacity` when charging already accounted (system ops already do this; do not duplicate charges).

- Storage write tracking is exposed via `Host.record_storage_change`, called inside `Frame.set_storage(...)`:

```206:213:src/evm/frame.zig
const original_value = self.state.get_storage(self.contract_address, slot) catch 0;
if (original_value != value) { try self.host.record_storage_change(self.contract_address, slot, original_value); }
try self.state.set_storage(self.contract_address, slot, value);
```

Use these to reconstruct per-call write sets for comparison.

### Zig language patterns you’ll use

- Union enums (as in `CallParams`) and `switch` binding:

```zig
switch (params) {
    .call => |p| { /* p.caller, p.to, p.value, p.input, p.gas */ },
    .staticcall => |p| { /* ... */ },
    else => { /* unsupported in Mini */ },
}
```

- Error unions and propagation:

```zig
const slice = try frame.memory.get_slice(off, len);
const res = self.execute_precompile_call_by_id(...) catch |err| { return CallResult{ .success = false, .gas_left = 0, .output = &.{} }; };
```

- `*anyopaque` context dispatch (jump table):

```zig
const ctx: *anyopaque = @ptrCast(&frame);
try operation.execute(ctx);
```

- `defer`/`errdefer` for allocations (see analysis creation in Mini).

### Tests to add (colocated)

- Per-call comparison tests: create small bytecode snippets and assert `compare_call_results` returns null (match) for arithmetic/memory/storage and for host calls with mocked outputs.
- Intentional mismatch tests: tweak Mini behavior under a test feature flag to trigger a known gas delta or output diff and assert comparator reports `field` and, for per-step, the exact `pc`.
- Ensure freeing: validate that outputs are freed exactly once in system ops after copy; Mini keeps its copy.

### Build flags and toggles

- Add a `build_options.enable_shadow_compare` bool. In debug builds default to true with `.per_call`; in release build default to false.
- Expose `Evm.set_shadow_mode(mode: DebugShadow.ShadowMode)` if you need runtime toggling from devtool.

### Practical rollout plan

1. Land `.per_call` comparisons for CALL and STATICCALL first (lowest risk, immediate value).
2. Expand to DELEGATECALL, CALLCODE, CREATE/CREATE2.
3. Add per-step driver behind debug-only flag.
4. Optional: log comparison via a Host shim that mirrors `emit_log` calls into a side buffer for equality checks.

All steps are self-contained; after each, run:

```bash
zig build && zig build test
```

to satisfy the repo’s zero-tolerance build policy and catch regressions immediately.
