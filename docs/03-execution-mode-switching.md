# Execution Mode Switching: Runtime Selection Between Optimized and Minimal

This document provides concrete, line-numbered research and a precise implementation plan to support switching between the optimized Plan-based interpreter and the direct PlanMinimal-based interpreter. It builds on the MinimalInterpreter wiring and PlanMinimal analysis documented in 02-minimal-interpreter-wiring.md.

## Phase 2 — Research Results (with references)

1) Configuration patterns and where to hook execution mode
- Frame config: `src/evm/frame.zig`
  - Factory: `pub fn Frame(comptime config: FrameConfig) type` at L20–L23 creates a typed Frame with compile-time config.
  - Tracing gates: `traceBeforeOp/traceAfterOp/traceOnError` are compile-time eliminated when `config.TracerType == null` at L159–L170 (call sites: L171–L187).
  - Error type: `pub const Error = error{ ... }` at L60–L77 used by handlers across interpreters.
  - PcType: derived from `FrameConfig.PcType()` at L24–L29 and defined in `src/evm/frame_config.zig` (see below).

- Frame interpreter (optimized): `src/evm/frame_interpreter.zig`
  - Factory: `pub fn FrameInterpreter(comptime config: frame_mod.FrameConfig) type` at L16–L31 returns the optimized interpreter type specialized by `FrameConfig`.
  - Planner/Plan types bound to config: `const Planner = planner_mod.Planner(.{ ... })` at L21–L27; `const Plan = plan_mod.Plan(.{ ... })` at L28–L31.
  - Handler table (comptime init): large `handlers` table at L55–L206 including synthetic fusions; PUSH/DUP/SWAP handlers generated at comptime via `generatePushHandler/generateDupHandler/generateSwapHandler` (e.g., L206, L232–L258, L267–L285).
  - Init flow: `pub fn init(...)` at L208–L239 creates `Frame`, builds `Planner`, obtains cached `Plan` keyed by hardfork via `planner.getOrAnalyze(bytecode, handlers, host.get_hardfork())` at L214, and materializes reverse `idx_to_pc` map at L216–L229.
  - Current PC: `getCurrentPc()` returns `?Plan.PcType` using `idx_to_pc` at L241–L254.
  - Execute: `interpret()` at L263–L293 starts from `plan.instructionStream[0].handler` and tail-calls through handlers; returns `error.STOP` for normal termination.

- Plan (optimized): `src/evm/plan.zig`
  - Handler type: `pub const HandlerFn = fn (frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn;` at L35 (shared across strategies).
  - Instruction element unions: `InstructionElement32/64` at L44–L57; platform `InstructionElement` alias at L60–L65 with verification at L67–L81.
  - Plan factory: `pub fn Plan(comptime cfg: PlanConfig) type` at L88–L96; `PcType`/`InstructionIndexType` at L92–L94.
  - Metadata access: `getMetadata` at L112–L140 (header) and L240–L268 (extractors by opcode cases).
  - Next dispatch: `getNextInstruction` at L270–L319 returns handler and advances index based on opcode having metadata; guards with end-of-stream handler at L305–L311.
  - PC→index: `getInstructionIndexForPc` at L321–L338 with dense and hashmap fast/slow paths.
  - Debug printing: `debugPrint` at L340–L389.

- PlanMinimal (direct): `src/evm/plan_minimal.zig`
  - Handler type: identical to optimized at L8.
  - Factory: `pub fn PlanMinimal(comptime cfg: PlanConfig) type` at L19–L26; fields at L28–L36; `PcType/InstructionIndexType/WordType` at L38–L40.
  - Metadata from bytecode: `getMetadata` at L46–L89 (header) with opcode cases at L102–L121; PUSH9..PUSH32 build `scratch_u256` and return `*const u256` at L112–L121.
  - Next dispatch: `getNextInstruction` at L143–L178 advances PC directly, then returns handler for `bytecode[pc]`; returns STOP handler when beyond end at L170–L176.
  - PC→index: identity mapping at L211–L216.
  - Jump/op-start bitmaps: `isValidJumpDest` at L218–L223 and `isOpcodeStart` at L224–L229 (read from `Bytecode` bitmaps).
  - Init/Deinit: `init(...)` at L230–L239 constructs typed `BytecodeType` and returns `Self`; `deinit()` at L240–L244.

- Planner: `src/evm/planner.zig`
  - Planner factory: `pub fn Planner(comptime Cfg: PlannerConfig) type` at L33–L41; binds `Plan` type at L58 and `BytecodeType` at L59–L62.
  - Cache-aware plan retrieval: `getOrAnalyze(...)` at L136–L171; includes `hardfork` in Wyhash key at L139–L141; owns cached `Plan` and deinits transient `Bytecode` at L162–L170.
  - Minimal path: `create_minimal_plan(...)` (scans/bitmaps only) at L611–L662 with explicit note at L653–L656 to construct `PlanMinimal` in a full minimal flow.

- FrameConfig: `src/evm/frame_config.zig`
  - Struct definition at L12–L57 with `TracerType: ?type = null` (L25), memory settings (L27–L32), database toggle (L34), SIMD vector length (L37–L41), and derived `PcType/StackIndexType/GasType` functions (L42–L71). Validation at L86–L92.

- Hardfork integration
  - Enum: `src/evm/hardfork.zig` at L1–L66 with helper methods `toInt/isAtLeast/isBefore` at L69–L90.
  - Host API exposes current hardfork: `src/evm/host.zig` vtable includes `get_hardfork` at L37–L59 (declared) and generator binds at L114–L168 (see `vtable_get_hardfork`).
  - Used by FrameInterpreter init to key plan cache via `host.get_hardfork()` at `src/evm/frame_interpreter.zig:L214`.

2) Type union patterns and error unions in the codebase
- Packed unions in hot paths:
  - Optimized plan instruction element unions at `src/evm/plan.zig:L44–L57` (32/64-bit) with a platform alias at L60–L65.
- Tagged unions for runtime variants:
  - Call parameters: `src/evm/call_params.zig:L6` defines `pub const CallParams = union(enum) { ... }`, with methods switching on tags at L54–L116.
  - Journal entries: `src/evm/journal_entry.zig:L23` defines `Data = union(enum) { ... }` (reference for ergonomics and size trade-offs).
- Error unions:
  - Frame errors: `src/evm/frame.zig:L60–L77`.
  - Interpreter error set (optimized): `src/evm/frame_interpreter.zig:L37` composes `Frame.Error` plus additional errors (OutOfMemory, TruncatedPush, InvalidJumpDestination, MissingJumpDestMetadata, InitcodeTooLarge).
- Takeaway for mode switching: Zig `union(enum)` provides efficient runtime variant selection; packed unions are used for ABI-exact storage (instruction stream). For an execution-mode wrapper, a tagged union over the interpreter variants is appropriate when selection happens at runtime, while compile-time selection yields zero overhead.

3) Allocator usage, ownership, and cleanup
- FrameInterpreter.init ownership: `src/evm/frame_interpreter.zig:L208–L239`
  - Creates `Frame` (owned by interpreter) and `Planner` (owned by interpreter) — both deinitialized in `deinit()` at L256–L260.
  - Obtains `*const Plan` from planner cache; plan is owned by the cache (comment at L257–L259). Do NOT free in interpreter.
  - Optionally allocates reverse `idx_to_pc` table with `allocator.alloc` (L219), freed on `deinit()` (L260).
- PlanMinimal.init ownership: `src/evm/plan_minimal.zig:L230–L239`
  - Constructs `BytecodeType` that owns bitmaps/buffers and must be `deinit()`-ed at L240–L244.
  - `handlers` table is caller-provided by value.
- Arena allocator precedent (for temporary per-call allocations) exists in the EVM core, not interpreters:
  - EVM arena: `src/evm/evm.zig` fields at L152–L159 and init at L196–L201; reset between root calls at L268–L269. Not directly used by interpreters.

4) Precedents for runtime vs compile-time selection
- Compile-time generics dominate performance-critical components:
  - `Frame(FrameConfig)` (src/evm/frame.zig:L20–L23), `Plan(PlanConfig)` (src/evm/plan.zig:L88–L96), `Planner(PlannerConfig)` (src/evm/planner.zig:L33–L41), `PlanMinimal(PlanConfig)` (src/evm/plan_minimal.zig:L19–L26).
- Runtime polymorphism via vtable/tagged-union used at subsystem boundaries:
  - Host vtable (`src/evm/host.zig`) and DatabaseInterface vtable (`src/evm/database_interface.zig`) enable runtime backends.
- Implication: Execution mode can be compile-time selected for zero cost, or selected at runtime via a thin union wrapper that delegates to one of two fully-typed interpreters without per-instruction branches.

## Implementation Specification

### ExecutionMode and config surface

```zig
pub const ExecutionMode = enum { optimized, minimal };

/// Optional wrapper-level config for mode switching.
/// FrameConfig remains the single source for word/stack/memory/tracing.
pub const InterpreterConfig = struct {
    // When known at compile-time (preferred), enables zero-cost specialization.
    comptime_mode: ?ExecutionMode = null,
    // When runtime selection is needed, set this field on instances.
    // Ignored if comptime_mode is non-null.
    runtime_mode: ExecutionMode = .optimized,
    // Optional: planner cache size for optimized mode init; ignored for minimal.
    planner_cache_capacity: usize = 32,
};
```

Rationale:
- `FrameConfig` continues to own ABI, stack/memory limits, and `TracerType`. Mode switching is orthogonal to these concerns.
- `comptime_mode` provides zero-overhead builds when the mode is fixed per binary (e.g., ReleaseSmall using minimal mode).
- `runtime_mode` enables per-call decisions at the application layer (CLI flag, test harness). The overhead is one outer switch per `execute()` — no per-instruction branching.

### Wrapper type: zero-cost when comptime-known, union when runtime-selected

```zig
pub fn InterpreterWrapper(
    comptime frame_cfg: @import("frame.zig").FrameConfig,
    comptime icfg: InterpreterConfig,
) type {
    const Optimized = @import("frame_interpreter.zig").FrameInterpreter(frame_cfg);
    const PlanMin = @import("plan_minimal.zig").PlanMinimal(.{
        .WordType = frame_cfg.WordType,
        .maxBytecodeSize = frame_cfg.max_bytecode_size,
    });
    // Minimal interpreter assumed implemented per 02-doc; named here
    const Minimal = @import("minimal_interpreter.zig").MinimalInterpreter(frame_cfg);

    // Comptime-fixed: alias directly to the concrete interpreter type
    if (icfg.comptime_mode) |m| switch (m) {
        .optimized => return Optimized,
        .minimal => return Minimal,
    };

    // Runtime-selected: tagged union delegating to one of the interpreters
    return struct {
        pub const Error = Optimized.Error || Minimal.Error;
        const Self = @This();
        const Mode = ExecutionMode;

        mode: Mode = icfg.runtime_mode,
        // Hold exactly one active variant at a time
        inner: union(enum) {
            optimized: Optimized,
            minimal:   Minimal,
        },

        pub fn initOptimized(allocator: std.mem.Allocator, bytecode: []const u8, gas: @TypeOf(Optimized).Frame.GasType, db: if (frame_cfg.has_database) ?@import("database_interface.zig").DatabaseInterface else void, host: @import("host.zig").Host) Error!Self {
            var opt = try Optimized.init(allocator, bytecode, gas, db, host);
            return .{ .mode = .optimized, .inner = .{ .optimized = opt } };
        }

        pub fn initMinimal(allocator: std.mem.Allocator, bytecode: []const u8, gas: @TypeOf(Minimal).Frame.GasType, db: if (frame_cfg.has_database) ?@import("database_interface.zig").DatabaseInterface else void, host: @import("host.zig").Host) Error!Self {
            var min = try Minimal.init(allocator, bytecode, gas, db, host);
            return .{ .mode = .minimal, .inner = .{ .minimal = min } };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            switch (self.mode) {
                .optimized => self.inner.optimized.deinit(allocator),
                .minimal => self.inner.minimal.deinit(allocator),
            }
        }

        pub fn execute(self: *Self) Error!void {
            return switch (self.mode) {
                .optimized => self.inner.optimized.interpret(),
                .minimal => self.inner.minimal.interpret(),
            };
        }

        pub fn getCurrentPc(self: *const Self) ?frame_cfg.PcType() {
            return switch (self.mode) {
                .optimized => self.inner.optimized.getCurrentPc(), // null if PC mapping disabled
                .minimal => @intCast(self.inner.minimal.instruction_idx),
            };
        }
    };
}
```

Notes:
- No per-instruction branches: when `comptime_mode` is set, the wrapper becomes a type alias to the selected interpreter. When runtime mode is used, the branch occurs only at `execute()`/`getCurrentPc()` and not inside opcode handlers.
- The minimal/optimized interpreters keep their own handler tables because each casts `plan: *const anyopaque` to its respective plan type (`Plan` vs `PlanMinimal`). The common handler signature (`HandlerFn`) enables dispatch without ABI changes.

### Shared interface and differences to reconcile

- Common methods and fields
  - `interpret() !void` — both interpreters run to `error.STOP` or bubble errors.
  - `getCurrentPc() ?PcType` — optimized returns null if reverse map disabled; minimal returns `instruction_idx` (PC) directly. Use `frame_cfg.PcType()` for a unified return type.
  - `frame: Frame(frame_cfg)` — identical execution context; tracer and memory/database semantics are unchanged.

- Return types and errors
  - Errors unify as `Optimized.Error || Minimal.Error`. In practice, both include `Frame.Error` and a small set of planning-related errors; unioning is safe and specific.

- Gas calculation
  - Both interpreters consult `opcode_data.OPCODE_INFO[...]` in handlers (see examples in `src/evm/frame_interpreter.zig` handlers, e.g., ADD at L606–L618 in the broader file). No precomputed gas is required for minimal mode; jump block metadata in optimized mode is advisory/debugging and not required for correctness.

### Integration Points

- Frame sharing
  - The `Frame` is identical across modes (`src/evm/frame.zig`), and PC type must be consistent. Ensure `Plan(PlanConfig{ .maxBytecodeSize = frame_cfg.max_bytecode_size })` and `PlanMinimal` are parameterized to match `frame_cfg.PcType()` (Plan: L92–L94; PlanMinimal: L38–L40).

- Tracer integration
  - Tracer calls are compile-time gated inside `Frame` (`traceBeforeOp/traceAfterOp/traceOnError`, L159–L170). Neither wrapper nor mode adds runtime tracer branches. Both interpreters should call these hooks with a PC value; optimized mode already maintains `idx_to_pc` at init (L216–L229), minimal mode computes PC as `instruction_idx`.

- Database/Host interface
  - Both interpreters access external state exclusively through `frame.host` (runtime vtable in `src/evm/host.zig`) and optionally `frame.database` when `FrameConfig.has_database == true`. No plan-specific database usage exists; all state operations route through the host vtable methods (`get_balance`, `get_storage`, `access_*`, etc.).

### Method Forwarding Pattern (runtime wrapper)

```zig
pub fn execute(self: *Self) !void {
    switch (self.mode) {
        .optimized => try self.inner.optimized.interpret(),
        .minimal => try self.inner.minimal.interpret(),
    }
}

pub fn getCurrentPc(self: *const Self) ?frame_cfg.PcType() {
    return switch (self.mode) {
        .optimized => self.inner.optimized.getCurrentPc(),
        .minimal => @intCast(self.inner.minimal.instruction_idx),
    };
}
```

This forwarding keeps the inner interpreters untouched and eliminates any inner-loop branches. When `comptime_mode` is set, the whole wrapper collapses to a concrete interpreter type and the forwarding code does not exist in the binary.

### Critical Design Decisions and trade-offs

1) Comptime vs runtime selection
- Comptime mode (preferred for production flavors):
  - Zero binary and runtime overhead. Unused interpreter is never compiled. No union, no branch.
  - Use cases: size-optimized builds (ReleaseSmall with minimal), performance builds (ReleaseFast with optimized).
- Runtime mode (for tooling, tests, or toggles):
  - One outer branch per `execute()` (negligible compared to per-instruction work). No per-instruction branches.
  - Code size increases as both interpreters and their handler tables compile into the binary.
  - Branch prediction impact confined to a single switch at entry points; inner dispatch remains identical.

2) Interface unification
- Methods to standardize: `init(...)`, `interpret()`, `getCurrentPc()`, `deinit(...)`, and optionally `pretty_print()`.
- PC reporting: optimized mode uses reverse mapping (L216–L229); minimal uses `instruction_idx`. Both return `?PcType` for consistency.
- Error type: define wrapper `Error` as a union of both error sets.

3) Zero-cost guarantees (when comptime-known)
- Pattern used above: `if (icfg.comptime_mode) |m| switch (m) { ... }` to alias the wrapper type to the concrete interpreter.
- All unused code paths (the other interpreter and wrapper layer) are eliminated by the compiler.
- Tracer disabled via `FrameConfig.TracerType = null` leads to no tracer branches in either mode.

### Handling Plan vs PlanMinimal pointer types in handlers

- Handler ABI is identical (`HandlerFn` is `fn (*anyopaque, *const anyopaque) anyerror!noreturn` in both `plan.zig:L35` and `plan_minimal.zig:L8`).
- Optimized handlers cast `plan` to `*const Plan` and use `instructionStream`/synthetic opcodes heavily (`src/evm/frame_interpreter.zig`, see PUSH handler generator around L232–L258 and arithmetic ops like ADD/MUL at L606+ in the full file).
- Minimal handlers must cast to `*const PlanMinimal` and may not use synthetic opcodes (PlanMinimal explicitly `@compileError` for synthetic opcodes at `src/evm/plan_minimal.zig:L52–L55`).
- Conclusion: keep two handler tables specialized to each plan; share naming and structure, but not the plan casts. The wrapper selects the correct interpreter so handlers remain zero-cost.

## Test Strategy

1) Equivalence tests (logic and gas)
- Reuse existing integration tests for FrameInterpreter as a baseline: `src/evm/frame_interpreter_integration_test.zig` (e.g., type constructed at L296/L387) and `src/evm/eip_integration_test.zig` harnesses.
- Add parallel runs through MinimalInterpreter for the same bytecode and host context, then assert:
  - Same halting reason (STOP/REVERT/error).
  - Same gas used (`frame.initial_gas - frame.gas_remaining`).
  - Same stack top and size; same memory size; same logs (addresses/topics/data).

2) PC reporting consistency
- For programs with interleaved PUSH data and JUMPDEST, assert that `getCurrentPc()` values match at corresponding execution points. Optimized mode requires `idx_to_pc` mapping (constructed at init L216–L229); minimal mode uses `instruction_idx` identity.

3) Hardfork-sensitive behavior
- Execute test vectors across hardforks (see `src/evm/eip_3651_test.zig:L219–L231` loop) in both modes to verify warm/cold behavior and opcode availability align.

4) Performance sanity
- Optional microbenchmarks using the existing runner (`zig build build-evm-runner`) to compare:
  - Minimal vs optimized dispatch throughput on arithmetic-heavy bytecode.
  - Branch misprediction counters remain dominated by handler-level control flow (outer mode switch should be amortized to zero in inner loops).

## Performance Considerations

- Branch prediction: runtime mode switch executes once per `execute()` and is trivially predictable for sustained runs. Inner handler dispatch uses table lookups and tail calls identical to the selected interpreter.
- Cache behavior: optimized mode’s instruction stream improves i-cache locality by pairing handler pointers and immediate metadata; minimal mode favors smaller working sets (no instruction stream). Wrapper does not alter either profile.
- Code size: runtime wrapper includes both interpreters. For size-constrained builds, set `comptime_mode=.minimal` (or `.optimized`) to compile only one.
- Inlining: keep forwarding methods `inline`-eligible; compiler eliminates when aliasing to a concrete type via `comptime_mode`.

## Implementation Checklist (scoped to this repo)

- Define `ExecutionMode` and `InterpreterConfig` (doc above).
- Ensure MinimalInterpreter mirrors FrameInterpreter’s surface (init/interpret/getCurrentPc/deinit) and handler coverage without synthetic opcodes.
- Implement `InterpreterWrapper(FrameConfig, InterpreterConfig)` as specified with comptime aliasing and runtime union variant.
- Initialize optimized mode with planner cache capacity from config; minimal mode ignores it.
- Keep `FrameConfig` unchanged; tracer/database/word/stack remain compile-time selections.
- Add tests that run both modes on identical inputs and assert equivalence (gas/state/logs/pc).
- Provide a CLI or test toggle to select runtime mode for experimentation.

## Developer Notes and pitfalls

- Keep `frame` layout identical in both interpreters so `@fieldParentPtr("frame", self)` patterns used by handlers remain valid and cache-friendly.
- Do not attempt to share a single handler table across modes; plan pointer casts differ by design.
- PlanMinimal disallows synthetic opcodes and fusions; ensure MinimalInterpreter handler table maps only real opcodes and uses PlanMinimal’s `getMetadata`/`getNextInstruction`.
- Optimized mode requires the hardfork to be included in the planner cache key (already implemented at `src/evm/planner.zig:L139–L141`). Always pass `host.get_hardfork()` at init.

## Appendix: Key references (files and lines)

- Frame core and config
  - `src/evm/frame.zig` — Frame factory at L20–L23; Error at L60–L77; tracer gates at L159–L170; pretty printer and utilities follow.
  - `src/evm/frame_config.zig` — fields at L12–L41; `PcType/StackIndexType/GasType` at L42–L71; validation at L86–L92.

- Optimized interpreter
  - `src/evm/frame_interpreter.zig` — handler table at L55–L206; init at L208–L239; `getCurrentPc` at L241–L254; `interpret` at L263–L293.
  - `src/evm/plan.zig` — HandlerFn at L35; Plan factory at L88–L96; metadata at L112–L140 and L240–L268; next-instruction at L270–L319; PC mapping at L321–L338.

- Minimal plan
  - `src/evm/plan_minimal.zig` — HandlerFn at L8; PlanMinimal factory at L19–L26; metadata at L46–L89 and L102–L121; next-instruction at L143–L178; PC identity at L211–L216; init/deinit at L230–L244.

- Planner and hardfork
  - `src/evm/planner.zig` — Planner factory at L33–L41; plan cache at L136–L171; minimal analysis path at L611–L662.
  - `src/evm/hardfork.zig` — enum and helpers at L1–L90.
  - `src/evm/host.zig` — `get_hardfork` exposure in vtable and glue at L114–L168.

This design enables safe, explicit runtime selection when needed and preserves zero-cost abstractions when the execution mode is known at compile time.
