## PR 2: Standard Memory Tracer for Guillotine

### Problem

Devtool needs full, structured per-step state snapshots (pc, opcode, gas before/after, stack, memory, storage diffs, logs) to visualize and scrub execution. The current built-in tracer streams REVM-like JSON lines and cannot provide structured, in-process access or bounded memory capture.

The interpreter uses a block-based execution model with pre-validation and aggregated gas charging, so per-op gas accounting cannot be naïvely derived without understanding the instruction stream produced by analysis. We must integrate at the correct hook points and derive values accurately from the frame and analysis data structures.

### What Exists Today (Key References)

- Minimal JSON tracer type and hook:

```36:82:src/evm/tracer.zig
/// Tracer interface for capturing EVM execution traces
pub const Tracer = struct {
    writer: std.io.AnyWriter,

    pub fn init(writer: std.io.AnyWriter) Tracer {
        return .{ .writer = writer };
    }

    /// Write a trace entry in REVM-compatible JSON format
    pub fn trace(
        self: *Tracer,
        pc: usize,
        opcode: u8,
        stack: []const u256,
        gas: u64,
        gas_cost: u64,
        memory_size: usize,
        depth: u32,
    ) !void { /* ... */ }
};
```

- EVM holds an optional tracer writer and exposes file-based tracing controls:

```111:121:src/evm/evm.zig
/// Optional tracer for capturing execution traces
tracer: ?std.io.AnyWriter = null,
/// Open file handle used by tracer when tracing to file
trace_file: ?std.fs.File = null,
```

```298:328:src/evm/evm.zig
pub fn enable_tracing_to_path(self: *Evm, path: []const u8, append: bool) !void { /* ... */ }
pub fn disable_tracing(self: *Evm) void { /* ... */ }
```

- Interpreter pre-step hook site (guarded by `build_options.enable_tracing`) where we can obtain the current instruction, compute its analysis index, and map it back to a pc and opcode:

```36:73:src/evm/evm/interpret.zig
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

- Execution model: block-based loop with instruction tags `.block_info`, `.exec`, `.dynamic_gas`, `.noop`, and jump variants. Gas is pre-charged for a block in `.block_info` and dynamic gas is charged in `.dynamic_gas`.

```120:173:src/evm/evm/interpret.zig
dispatch: switch (instruction.tag) {
  .block_info => { /* pre-charge gas */ }
  .exec => { /* try exec_fun(frame); */ }
  .dynamic_gas => { /* charge additional gas; try dyn_inst.exec_fn(frame); */ }
  .noop => { /* advance */ }
  // jumps...
}
```

- Core execution state types and accessors you will use:
  - `Frame` fields: `gas_remaining`, `stack`, `memory`, `state`, `contract_address`, `caller`, `depth`, `is_static`.
  - `Frame` API: `consume_gas()`, `valid_jumpdest()`, `get_storage()`, `set_storage()`, `get_original_storage()`, `set_output()`.
  - `Memory` API: `size()`, `get_memory_ptr()`, `get_checkpoint()`, `get_slice`, `set_data_bounded`, `charge_and_ensure()`.
  - `CallJournal` and `EvmState.logs` to detect per-step storage changes and logs appended.

```40:66:src/evm/frame.zig
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

```167:175:src/evm/memory/memory.zig
pub inline fn get_memory_ptr(self: *const Memory) [*]u8 { return self.shared_buffer_ref.items.ptr; }
pub inline fn get_checkpoint(self: *const Memory) usize { return self.my_checkpoint; }
```

```116:139:src/evm/call_frame_stack.zig
pub const CallJournal = struct {
    entries: ArrayList(JournalEntry),
    next_snapshot_id: u32,
    original_storage: AutoHashMap(Address, AutoHashMap(u256, u256)),
    pub fn record_storage_change(self: *CallJournal, snapshot_id: u32, address: Address, key: u256, original_value: u256) !void { /* ... */ }
    pub fn get_original_storage(self: *const CallJournal, address: Address, key: u256) ?u256 { /* ... */ }
};
```

### Goals

- Implement a structured, in-process tracer that consumes interpreter hooks and records full step data for the UI.
- Provide retrieval APIs: get full trace or incremental steps for live streaming.
- Maintain strict memory ownership; allow configurable, bounded memory capture.
- Preserve zero overhead in release builds or when tracing is disabled, using existing compile-time guards.

### Scope and Architecture

Introduce `src/evm/tracing/` with three files:

- `tracer.zig`: interface (vtable-like) and shared data structs.
- `standard_tracer.zig`: default in-process tracer implementation (collects and stores steps with bounded snapshots; can stream).
- `capture_utils.zig`: helpers to efficiently snapshot stack/memory/storage/logs with minimal copies and safe ownership.

Do not remove the existing `src/evm/tracer.zig` JSON streaming tracer; keep it for file-based tracing. The new in-process tracer is additive and pluggable.

### Files to Add

- `src/evm/tracing/tracer.zig`
- `src/evm/tracing/standard_tracer.zig`
- `src/evm/tracing/capture_utils.zig`

### Integration

- `src/evm/root.zig`: export tracer types.
- `src/evm/evm.zig`: add `set_tracer(tracer: ?TracerHandle)` and call tracer via hooks.
- `src/evm/evm/interpret.zig`: insert post-step capture calls next to existing `pre_step()` sites.

### Data Model (summarized)

- StepInfo: pc, opcode, op_name, gas_before, depth, address, caller, is_static, stack_size, memory_size.
- StepResult: gas_after, gas_cost, stack_snapshot, memory_snapshot (+ window), storage_changes, logs_emitted, error.
- StructLog: pc, op string, gas before, gas_cost, depth, stack snapshot, memory snapshot (bounded).
- ExecutionTrace: gas_used, failed, return_value, struct_logs[].

### Memory Strategy

- Bounded memory capture: configurable max bytes; when exceeded, capture window around accessed region plus summary sizes.
- Stack captured as copy of current stack; for very deep stacks, allow truncation with tail note.
- Storage captured as per-step modified slots only.

### Tests

- Unit tests under `test/evm/`:
  - Trace simple arithmetic and verify struct logs sequence.
  - Trace memory ops (MSTORE/MLOAD/MCOPY) and verify memory window.
  - Trace storage ops (SSTORE/SLOAD) and verify changed slots.
  - Control flow (JUMP/JUMPI) including invalids; verify pc mapping and error reporting.
  - Logs (LOG0-LOG4) and bounded data capture.
  - Zero-overhead when no tracer set (compile-time guard + sanity perf guard).

### Acceptance Criteria

- Tracer compiles, integrates, and produces deterministic struct logs for known bytecode samples.
- Tests cover arithmetic, memory, storage, logs, control flow, and error steps.
- No allocations on hot path when tracing is disabled.
- Bounded capture obeys configuration limits.

### Notes

- Opcode-to-string mapping should reuse existing opcode metadata where possible.
- Consider mapping `analysis` instruction index back to original PC for UI (PR 5).

### Gas Semantics and Limitations

- The interpreter pre-charges aggregated gas per block in `.block_info`. As a result, per-op `gas_cost = gas_before - gas_after` at `.exec` boundaries may not align perfectly with spec per-op costs. This is acceptable for PR 2 (UI tracing). We can later apportion block base costs across ops once we expose block boundaries to the tracer (PR 5).

### Detailed Implementation Notes (Step-by-step)

1. Add `src/evm/tracing/tracer.zig`:

   - Define `StepInfo`, `StepResult`, `StructLog`, `ExecutionTrace` types.
   - Define `TracerVTable` and `TracerHandle` for a zero-alloc optional callback interface.

2. Add `src/evm/tracing/standard_tracer.zig`:

   - Implement `StandardTracer` with config `{ memory_max_bytes, stack_max_items, log_data_max_bytes }`.
   - Provide `init(allocator, config)`, `deinit()`, `handle()`, `get_trace()`.
   - Implement `on_pre_step` (record minimal info) and `on_post_step` (compute deltas, bounded snapshots), `on_finish`.

3. Add `src/evm/tracing/capture_utils.zig`:

   - `copy_stack_bounded(stack_view: []const u256, max_items: usize) []u256`
   - `copy_memory_bounded(mem: *const Memory, max_bytes: usize, accessed: ?struct{start:usize,len:usize}) []u8`
   - `collect_storage_changes_since(journal: *CallJournal, from: usize) []StorageChange`
   - `copy_logs_bounded(state: *EvmState, from: usize, log_data_max_bytes: usize) []LogEntry`

4. EVM integration (`src/evm/evm.zig`, `src/evm/evm/interpret.zig`):

   - Add optional `inproc_tracer: ?TracerHandle` and `set_tracer()` method.
   - In `pre_step()`, if `inproc_tracer` exists, build `StepInfo` (using `analysis.inst_to_pc`, `analysis.code[pc]`, `frame.gas_remaining`, `frame.depth`, sizes) and call `on_pre_step`.
   - After each executed instruction (in `.exec`, `.dynamic_gas`, `.noop`, jump tags), compute `gas_after`, journal/log deltas, bounded captures, then call `on_post_step`.
   - On interpreter exit (STOP/RETURN/REVERT), call `on_finish` with `return_value` and final status.

5. Export tracer types in `src/evm/root.zig`.

### Example Test Skeleton (no helpers)

```zig
test "trace: add+pop sequence" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("evm/opcode_metadata/opcode_metadata.zig");
    const Analysis = @import("evm/analysis.zig").CodeAnalysis;
    const MemoryDatabase = @import("evm/state/memory_database.zig").MemoryDatabase;
    const Evm = @import("evm/evm.zig");
    const Host = @import("evm/host.zig").Host;
    const Address = @import("primitives").Address.Address;
    const tracing = @import("evm/tracing/standard_tracer.zig");

    const code = &[_]u8{ 0x60, 0x02, 0x60, 0x03, 0x01, 0x50, 0x00 };
    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var db = MemoryDatabase.init(allocator);
    defer db.deinit();
    const dbi = db.to_database_interface();

    var evm = try Evm.init(allocator, dbi, null, null, null, 0, false, null);
    defer evm.deinit();

    const host = Host.init(&evm);
    var frame = try @import("evm/frame.zig").Frame.init(100000, false, 0, Address.ZERO, Address.ZERO, 0, &analysis, host, dbi, allocator);
    defer frame.deinit(allocator);

    var std_tracer = try tracing.StandardTracer.init(allocator, .{ .memory_max_bytes = 256, .stack_max_items = 16, .log_data_max_bytes = 256 });
    defer std_tracer.deinit();
    evm.set_tracer(std_tracer.handle());

    _ = @import("evm/evm/interpret.zig").interpret(&evm, &frame) catch |err| {
        if (err != @import("evm/execution/execution_error.zig").ExecutionError.Error.STOP) return err;
    };

    const trace = std_tracer.get_trace();
    try std.testing.expect(trace.struct_logs.len >= 3);
}
```

### Build/Run

- Always run: `zig build && zig build test` after each edit.
- Tracing code is guarded by `build_options.enable_tracing`; keep it off in perf-critical builds.
