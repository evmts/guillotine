## PR 8: QA and Test Plan for Devtool Tracing Stack

### Objectives

- Ensure each PR in the stack has passing unit and integration tests.
- Validate zero-regression on existing tests and devtool functionality.

### Global Test Matrix

- Platforms: macOS 14+, Linux (CI).
- Zig: `zig build`, `zig build test`, `zig build bench` (optional sanity), `zig build devtool`.

### Per-PR Checks

1. Debug Hooks:
   - Unit: pause/abort semantics; message hooks fire around CALL/CREATE.
   - Integration: stepping preserves interpreter semantics.
2. Standard Tracer:
   - Unit: arithmetic/memory/storage/log capture; bounded memory.
   - Perf: ensure near-zero overhead when disabled (compile-time guarded checks).
3. REVM Bridge:
   - Differential: parity on small programs; struct log alignment.
4. Devtool Refactor:
   - Headless: step/pause/resume; breakpoints.
   - UI Smoke: opcode list, stack/memory/storage, gas.
5. Analysis + PC Mapping:
   - Unit: instruction index to original PC is stable across steps.
6. Side-by-Side Execution:
   - Diff rendering and mismatch surfacing.
7. Frame Capture + UI:
   - Nested calls visualization; revert handling.

### Tooling

- Keep using `test/differential` as reference; extend with focused cases for CALL and memory.
- Add optional environment flag to enable verbose `std.log.debug` within tests.

### Acceptance Criteria for the Stack

- All tests green per PR and at top-of-stack.
- Devtool can load bytecode, step interactively, and compare with REVM.
- Memory ownership clear; no leaks under `std.heap.GeneralPurposeAllocator` checks.

## PR 8: QA and Test Plan for Devtool Tracing Stack (Implementation-Ready)

### Goals

- Ensure each PR in the tracing stack (PRs 1–7) is fully covered by unit/integration tests with zero regressions.
- Validate end-to-end behavior of the Devtool (headless and UI) driven by the tracer.
- Lock in deterministic analysis/PC mapping and trace formats for comparison against REVM.
- Establish a clear workflow to diagnose divergences with minimal repros.

### Support Matrix

- Platforms: macOS 14+ (Apple Silicon), Linux (CI).
- Build flavors:
  - Regular: `zig build && zig build test`
  - Tracing-enabled: `zig build -Denable-tracing=true && zig build -Denable-tracing=true test`
  - Devtool: `zig build devtool`
  - Optional sanity: `zig build bench`

### One-time Environment

- Zig: Use the project-standard version (see repository docs and CI); recommended 0.14.x.
- macOS prerequisites for Devtool UI: WebUI is embedded; no `node`/`npm` needed.
- REVM wrapper is vendored under `src/revm_wrapper/`; no external Rust toolchain is required to run Zig tests.

### Ground Truth Anchors (where things happen)

- Interpreter execution and hook point:
  - `src/evm/evm/interpret.zig` → `pre_step(...)` called for every instruction, before dispatch.
  - Emits trace lines when `build_options.enable_tracing` and `Evm.tracer` is set.

```148:173:/Users/polarzero/code/tevm/guillotine/src/evm/evm/interpret.zig
            pre_step(self, frame, instruction, &loop_iterations);
            const exec_inst = analysis.getInstructionParams(.exec, instruction.id);
            const exec_fun = exec_inst.exec_fn;
            const next_instruction = exec_inst.next_inst;
            // Get PC from instruction index
            const base: [*]const Instruction = analysis.instructions.ptr;
            const idx = (@intFromPtr(instruction) - @intFromPtr(base)) / @sizeOf(Instruction);
            var pc: usize = 0;
            if (idx < analysis.inst_to_pc.len) {
                const pc_u16 = analysis.inst_to_pc[idx];
                if (pc_u16 != std.math.maxInt(u16)) pc = pc_u16;
            }
            Log.debug("[EXEC] Executing instruction at idx={}, pc={}, stack_size={}", .{ idx, pc, frame.stack.size() });
            try exec_fun(frame);
            instruction = next_instruction;
            continue :dispatch instruction.tag;
```

- Tracer and JSON line format:
  - `src/evm/tracer.zig` → `Tracer.trace(...)` writes one REVM‑compatible JSON object per step.
  - Fields: `pc`, `op`, `gas`/`gasCost` (hex strings), `stack` (hex strings), `depth`, `memSize`, `opName`, `returnData` (placeholder), `refund` (placeholder).

```1:23:/Users/polarzero/code/tevm/guillotine/src/evm/tracer.zig
pub const Tracer = struct {
    writer: std.io.AnyWriter,
    pub fn trace(self: *Tracer, pc: usize, opcode: u8, stack: []const u256, gas: u64, gas_cost: u64, memory_size: usize, depth: u32) !void {
        // ... writes JSON line with pc/op/gas/stack/depth/memSize/opName ...
    }
};
```

- Analysis and PC mapping (instruction stream and mappings):
  - `src/evm/instruction_generation.zig` produces:
    - `instructions: []Instruction`
    - `inst_to_pc: []u16` (analysis instruction index → original PC)
    - `pc_to_block_start: []u16` (original PC → BEGINBLOCK instruction index)

```657:676:/Users/polarzero/code/tevm/guillotine/src/evm/instruction_generation.zig
    // Build inst_to_pc mapping
    var inst_to_pc = try allocator.alloc(u16, instruction_count);
    @memset(inst_to_pc, std.math.maxInt(u16));
    var map_pc: usize = 0;
    while (map_pc < code.len) : (map_pc += 1) {
        const idx = pc_to_instruction[map_pc];
        if (idx != std.math.maxInt(u16) and idx < instruction_count) {
            inst_to_pc[idx] = @intCast(map_pc);
        }
    }
```

- Devtool current model (to be refactored in earlier PRs but used for QA):
  - `src/devtool/evm.zig` implements analysis‑first stepping and JSON serialization for the UI.
  - It already derives instruction index from the frame’s `instruction` pointer and best‑effort PC for display.

```333:365:/Users/polarzero/code/tevm/guillotine/src/devtool/evm.zig
    const mapped_u16: u16 = if (j < a.inst_to_pc.len) a.inst_to_pc[j] else std.math.maxInt(u16);
    var pc: usize = 0;
    if (mapped_u16 != std.math.maxInt(u16)) { pc = mapped_u16; last_pc_opt = pc; }
    else if (last_pc_opt) |prev_pc| {
        const prev_op: u8 = if (prev_pc < a.code_len) a.code[prev_pc] else 0;
        const imm_len: usize = if (prev_op == 0x5f) 0 else if (prev_op >= 0x60 and prev_op <= 0x7f) @intCast(prev_op - 0x5f) else 0;
        pc = prev_pc + 1 + imm_len;
        last_pc_opt = pc;
    }
```

- REVM bridge and differential comparison:
  - `src/revm_wrapper/` Zig/C/Rust bridge and helpers.
  - `test/differential/system_differential_test.zig` runs both REVM and Zig EVM, writes traces (when enabled), and compares line‑by‑line JSON.

```121:134:/Users/polarzero/code/tevm/guillotine/test/differential/system_differential_test.zig
    // Execute
    _ = evm_instance.call(call_params) catch |err| { std.debug.print("Zig EVM execution failed: {}\n", .{err}); return err; };
    // Read both trace files and compare line by line (pc/op/stack length/values)
```

### How to Run All Tests (exact commands)

- Fast check (no tracing):

  - `zig build && zig build test`

- Tracing-dependent tests (trace JSON generation and diff):

  - `zig build -Denable-tracing=true && zig build -Denable-tracing=true test`

- Devtool UI build:

  - `zig build devtool`

- Optional sanity benches:
  - `zig build bench`

### Mandatory Policies (enforced during QA)

- Always run `zig build && zig build test` after every code edit. Do not proceed with any further change if red.
- Treat any failing test as a regression you introduced. Stop and fix immediately.
- Use evidence-based debugging: add targeted `std.log.debug` and trace files; do not speculate.
- Memory ownership must be explicit: every allocation has a corresponding deallocation. Prefer `defer/errdefer` and colocated `deinit()` calls.

### Per‑PR QA Checklist (what to test, how to test, and exact anchors)

1. Interpreter Debug Hooks (PR 1)

- Purpose: deterministic stepping control (pause/continue/abort) and lifecycle hooks around CALL/CREATE.
- Hook point: `pre_step(...)` in `src/evm/evm/interpret.zig` runs before each instruction; add hook calls here and before/after CALL/CREATE handlers.
- Unit tests (new): `test/evm/debug_hooks_test.zig`
  - Arrange: minimal bytecode (e.g., `PUSH1,PUSH1,ADD,STOP`).
  - Configure: install a hook that pauses after N steps; assert interpreter halts and resumes correctly.
  - CALL/CREATE hook assertions: deploy a tiny callee; assert `on_enter_call`/`on_exit_call` fire exactly once and with correct depth.
- Integration: ensure hook presence does not change semantics. Run a small program twice: with hooks (no pauses) and without; compare `Host` output and gas usage.

2. Standard Tracer (PR 2)

- File: `src/evm/tracer.zig`
- Enable tracing at runtime: set `Evm.tracer = AnyWriter` (use `Evm.enable_tracing_to_path()` or builder-style API if available).
- Unit tests: `test/evm/tracer_test.zig` already verifies JSON lines exist; extend with:
  - Verify required fields exist (`pc`, `op`, `gas`, `gasCost`, `stack`, `depth`, `memSize`, `opName`).
  - Verify stack formatting (hex, minimal form, `0x0` for zero).
  - Verify bounded memory metadata: `memSize` equals `frame.memory.size()` snapshot.
- Perf guard: ensure tracer calls are behind `comptime build_options.enable_tracing`. Add a test that builds without `-Denable-tracing` and asserts tracing cannot be enabled (`error.FeatureDisabled`).

3. REVM Bridge (PR 3)

- Files: `src/revm_wrapper/revm.zig`, `src/revm_wrapper/src/lib.rs`.
- Differential tests: in `test/differential/system_differential_test.zig`:
  - Arithmetic/memory/control flow samples: parity on success flag, return data, gas, and stack.
  - Trace parity when `-Denable-tracing=true`: same `pc`, `op`, stack length/values per step.
- Add small focused cases: `CREATE`, `CREATE2`, `CALL`, `STATICCALL`, `DELEGATECALL`, storage read/write, and memory growth.

4. Devtool Refactor to Tracer-Driven (PR 4)

- Replace analysis-first stepping in `src/devtool/evm.zig` with tracer-driven execution using debug hooks from PR 1.
- Headless tests (new): `test/devtool/devtool_runner_test.zig` to verify:
  - `step()` executes exactly one opcode; `continue()` respects pause/breakpoints; `reset()` clears state.
  - Errors surface to the UI layer (expose last error string/code in the serialized state).
- UI smoke tests (manual): run `zig build devtool`, then verify the following via the WebUI bindings (`src/devtool/app.zig`):
  - Opcode list renders; bytecode grid highlights current PC.
  - Stack/memory/storage/logs panels update per step.
  - Gas remaining and cumulative gas update.

5. Analysis + PC Mapping (PR 5)

- Guaranteed APIs: `inst_to_pc` and `pc_to_block_start` on the analysis result.
- Determining current instruction index: pointer arithmetic on `frame.instruction` against `analysis.instructions.ptr`.
- Tests (new): `test/evm/analysis_pc_mapping_test.zig`:
  - Build analysis for hand-written bytecode with PUSH immediates and JUMP/JUMPI.
  - For each step, assert: `inst_to_pc[idx]` is either a valid PC pointing to the current opcode byte or sentinel (`maxInt(u16)`), and derived PC fallback equals previous PC + `1 + imm_len(prev_op)`.
  - Validate that `pc_to_block_start[pc]` indexes a `.block_info` instruction and that stepping across blocks keeps the begin index stable for contained instructions.

6. Side‑by‑Side Execution (PR 6)

- Use `compareTracesForBytecode(...)` in `test/differential/system_differential_test.zig` as a harness to diff JSON lines.
- Add cases for:
  - Keccak over various sizes and offsets (including `size=0` fast path).
  - Memory expansion scenarios with `MLOAD/MSTORE/MCOPY/CODECOPY` and extremely large offsets to trigger `OutOfOffset`.
  - Warm/cold `SLOAD/SSTORE` (when available in opcode metadata) and dynamic gas attributions.
  - CALL matrix: value/no‑value × warm/cold × args/ret sizes.
- On divergence, the harness prints a minimal reproduction via `createMinimalReproduction(...)`. Store the repro under `test/differential/repro/` for investigation.

7. Frame Capture + UI (PR 7)

- Headless tests: simulate nested calls and reverts to ensure captured frames (depth, return data, errors) are serialized correctly for the UI.
- UI manual:
  - Verify nested call visualization (stacked frames) and revert presentation.
  - Ensure that on REVERT the UI shows non‑success state without crashing; gas bookkeeping remains consistent.

### Devtool Serialization and Expectations

- Source: `src/devtool/evm.zig` → `serializeEvmState()`
- Must include:
  - `gasLeft`, `depth`, `stack`, `memory`, `storage`, `logs`, `returnData`, `codeHex`, `completed`.
  - `currentInstructionIndex`, `currentBlockStartIndex`, and per‑block lists: `pcs`, `opcodes`, `opcodeBytes`, `hex`, `data`, `dynamicGas`, `dynCandidate`, and debug lists (`instIndices`, `instMappedPcs`).
- Additions for PR 5: `currentPc` and `jumpdests` (packed positions array) derived from analysis.
- Validate with JSON parsing in tests (see existing tests at bottom of `src/devtool/evm.zig`).

### Logging and Diagnostics

- Enable logs inside tests when needed:

```zig
test {
    std.testing.log_level = .warn; // or .debug when triaging
}
```

- Tracing: Only available when compiled with `-Denable-tracing=true`. At runtime, set a tracer via `Evm.enable_tracing_to_path(path, append)`.

### Memory Ownership and Allocators

- Use `std.testing.allocator` in tests; Zig’s test runner uses a GPA variant with leak detection.
- Every `init(...)` must be paired with `deinit(...)`. Patterns to follow (already used across the codebase):
  - VM/state/analysis/frame lifetimes are explicit; immediately `defer` or `errdefer` after creation.
  - When allocating buffers (like trace buffers) with `alloc/dupe`, always `free`.
  - Example lifetimes: `Evm.init(...)` → `vm.deinit()`, `Frame.init(...)` → `frame.deinit(allocator)` or `frame.deinit()` depending on variant, `CodeAnalysis.from_code(...)` → `analysis.deinit()`.

### Failure Triage Workflow

- For opcode/trace mismatches:
  - Re-run with `-Denable-tracing=true` and capture both traces.
  - Use `test/differential/system_differential_test.zig`’s minimal repro printer to isolate the failing PC.
  - Add a unit test with the minimal bytecode under `test/evm/opcodes/` or `test/differential/` as appropriate.
  - Add targeted `std.log.debug` near the failing opcode implementation (`src/evm/execution/*.zig`).

### Exact Commands to Use During QA

- Regular runs:

  - `zig build && zig build test`

- With tracing (required for trace tests):

  - `zig build -Denable-tracing=true && zig build -Denable-tracing=true test`

- Devtool (UI smoke):
  - `zig build devtool` and run the produced app; use the embedded WebUI handlers from `src/devtool/app.zig` (`load_bytecode`, `reset_evm`, `step_evm`, `get_evm_state`).

### What “Green” Means for This Stack

- All unit and integration tests pass in both regular and tracing-enabled builds.
- Differential comparisons show no divergences for the curated matrix (arithmetic, memory, control flow, CALL family, CREATE/CREATE2, storage ops).
- Devtool builds, loads bytecode, steps interactively, and renders synchronized instruction/PC mapping.
- No memory leaks or use-after-free under `std.testing.allocator` (GPA leak checks).

### Appendix: Reference Snippets

- Deriving current index and PC in interpreter:

```70:79:/Users/polarzero/code/tevm/guillotine/prompts/devtool-tracing-prs/05-analysis-and-pc-mapping.md
const base: [*]const @TypeOf(inst.*) = analysis.instructions.ptr;
const idx = (@intFromPtr(inst) - @intFromPtr(base)) / @sizeOf(@TypeOf(inst.*));
const pc_u16 = analysis.inst_to_pc[idx];
const pc: usize = if (pc_u16 != std.math.maxInt(u16)) pc_u16 else 0;
```

- Enabling tracer at runtime:

```254:318:/Users/polarzero/code/tevm/guillotine/src/evm/evm.zig
pub fn enable_tracing_to_path(self: *Evm, path: []const u8, append: bool) !void {
    if (!comptime build_options.enable_tracing) return error.FeatureDisabled;
    if (self.trace_file) |f| { f.close(); self.trace_file = null; }
    var file = try std.fs.cwd().createFile(path, .{ .truncate = !append, .read = false });
    if (append) try file.seekFromEnd(0);
    self.trace_file = file;
    self.tracer = file.writer().any();
}
```

- Devtool headless stepping assertions (existing tests to emulate and extend):

```861:879:/Users/polarzero/code/tevm/guillotine/src/devtool/evm.zig
// One visible-instruction step should NOT complete the program
const step1 = try devtool_evm.stepExecute();
try testing.expectEqual(false, step1.completed);
try testing.expectEqual(false, step1.error_occurred);
```

This plan, together with the cited anchors and commands, is sufficient to implement, test, and validate the entire tracing stack end-to-end.

### Zig Quick Reference (focused on this stack)

- Error unions and try/catch:
  - Use `!T` for fallible functions; propagate with `try`, handle with `catch`.
  - Example: `const f = try std.fs.cwd().createFile(path, .{});` and `writer.writeAll(data) catch |err| { return err; }`.
- Defer and errdefer:
  - Free resources in the same scope with `defer`; ensure cleanup on error before ownership transfer with `errdefer`.
  - Example:
    - `var list = std.ArrayList(u8).init(allocator); defer list.deinit();`
    - `const ptr = try allocator.create(T); errdefer allocator.destroy(ptr);`
- AnyWriter and JSON:
  - Get an `AnyWriter` from buffers/files: `arraylist.writer().any()`, `file.writer().any()`.
  - Write JSON incrementally with `std.json.stringify(value, .{}, writer)` or format strings with `writer.writeAll()`.
- ArrayList and owned slices:
  - Build dynamic arrays then take ownership: `const items = try list.toOwnedSlice(); defer allocator.free(items);` (or attach into a struct that later frees).
- Pointer arithmetic to derive instruction index:
  - `const base: [*]const @TypeOf(inst.*) = analysis.instructions.ptr;`
  - `const idx = (@intFromPtr(inst) - @intFromPtr(base)) / @sizeOf(@TypeOf(inst.*));`
- u256 hex formatting:
  - Minimal hex (no leading zeros): `std.fmt.bufPrint(&buf, "0x{x}", .{value})`.
- Build options gating:
  - Guard tracing with `if (comptime build_options.enable_tracing) { ... }` and return `error.FeatureDisabled` when disabled.
- Tests colocated with source:
  - Use `test "name" { ... }` blocks in source files or under `test/...`; always `defer`/`deinit()` allocations.

### Public APIs to (add|use) across PRs

- EVM debug hooks (to add in PR 1):
  - `pub const StepControl = enum { continue, pause, abort };`
  - `pub const MessagePhase = enum { before, after };`
  - `pub const OnStepFn = *const fn (user_ctx: ?*anyopaque, frame: *Frame, pc: usize, opcode: u8) anyerror!StepControl;`
  - `pub const OnMessageFn = *const fn (user_ctx: ?*anyopaque, params: *const CallParams, phase: MessagePhase) anyerror!void;`
  - `pub const DebugHooks = struct { user_ctx: ?*anyopaque = null, on_step: ?OnStepFn = null, on_message: ?OnMessageFn = null };`
  - `pub fn set_debug_hooks(self: *Evm, hooks: ?DebugHooks) void { self.debug_hooks = hooks; }`
  - Wire calls in `interpret.zig` before exec and around CALL/CREATE in system op handlers.
- Tracing (already present):
  - `pub fn enable_tracing_to_path(self: *Evm, path: []const u8, append: bool) !void` (gated by `build_options.enable_tracing`).
  - When enabled and `self.tracer` is set, `interpret.zig` emits REVM‑compatible JSON lines via `Tracer.trace(...)`.
- Devtool runner (PR 4):
  - Headless control methods: `load(bytecode, calldata, env)`, `step()`, `continue(max_steps?)`, `pause()`, `reset()`, `set_breakpoints(pcs: []usize)`.
  - Use debug hooks for pause/break; use tracer output to build UI state.

### Differential tests and commands

- Run all tests (no tracing):
  - `zig build && zig build test`
- Run tracing-dependent tests and comparisons:
  - `zig build -Denable-tracing=true && zig build -Denable-tracing=true test`
- Run dedicated differential test step (if defined in `build.zig`):
  - `zig build test-differential`
- Build devtool UI app:
  - `zig build devtool`

### Adding tests (patterns to copy)

- Use `std.testing.allocator` and clean up:
  - VM/state: `var vm = try Evm.init(...); defer vm.deinit();`
  - Analysis: `var analysis = try Analysis.from_code(...); defer analysis.deinit();`
  - Files/buffers: `var file = try std.fs.cwd().createFile(...); defer file.close();`
- Keep tests self-contained; do not add shared helpers. Inline all setup and assertions in each test.
- Enable logs when triaging: place at top of file:
  - `test { std.testing.log_level = .warn; }`
- Trace JSON parsing in tests:
  - Collect `std.ArrayList(u8)` writes from tracer; split by `\n` using `std.mem.tokenizeScalar(u8, buf, '\n')` and `std.json.parseFromSlice` per line.

### Common pitfalls and how to avoid them

- Tracing overhead:
  - Always guard tracing with `comptime build_options.enable_tracing` and `if (self.tracer) |w| { ... }` inside the guard. Do not allocate on the hot path.
- Pausing semantics:
  - When `on_step` returns `.pause`, surface a distinct pause error or state to the caller and do not advance `frame.instruction`. Resumption should continue from the same instruction.
- CALL/CREATE hooks:
  - For `.before`, compute and pass params but don’t allocate. For `.after`, include success flag and returned gas/output if available. Do not retain borrowed slices outside the scope.
- PC mapping edge cases:
  - For fused/derived instructions without a direct PC mapping, `inst_to_pc[idx] == maxInt(u16)`. Use the fallback derivation `(prev_pc + 1 + imm_len(prev_op))` only for UI hints, not for correctness.
- Memory and stack ownership:
  - The `Frame` owns memory/stack; never free them outside `frame.deinit(...)`. Any slices from memory/stack are ephemeral.
- JSON lines format stability:
  - Keep fields and types stable to avoid breaking diff harnesses. If you add fields, append them (don’t change existing names/types).

### Step-by-step smoke runbook

- Minimal tracer run:
  - Build with tracing: `zig build -Denable-tracing=true`
  - Write a tiny program test that enables tracing via `vm.enable_tracing_to_path("/tmp/trace.json", false)` then executes `call(...)`.
  - Inspect `/tmp/trace.json` lines for `{ "pc": ..., "op": ..., "stack": [...], "memSize": ..., "opName": "ADD" }`.
- Devtool headless check:
  - `zig build devtool`
  - Use WebUI controls bound in `src/devtool/app.zig` (`load_bytecode`, `step_evm`, `get_evm_state`) to confirm step advances and state JSON updates.

### Commit policy and verification gates

- After every edit: `zig build && zig build test` (stop and fix on any failure).
- For tracing changes: also run `zig build -Denable-tracing=true && zig build -Denable-tracing=true test`.
- For differential: `zig build test-differential` where available.
- Use emoji conventional commits (see repository rules).
