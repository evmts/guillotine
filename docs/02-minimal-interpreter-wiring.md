# Minimal Interpreter Wiring: Direct Bytecode Execution Without Optimization

This document captures concrete, line-numbered references and a precise implementation guide to wire a MinimalInterpreter that executes bytecode directly using PlanMinimal, without advanced planner optimizations.

## Phase 1 — Research Results (with references)

1) PlanMinimal implementation
- File: `src/evm/plan_minimal.zig`
  - Type factory: `pub fn PlanMinimal(comptime cfg: PlanConfig) type` at L18–L28; validates config and returns a struct with fields and methods.
  - Core fields: `bytecode: BytecodeType`, `handlers: [256]*const HandlerFn`, `scratch_u256: u256` at L28–L35; type aliases `PcType`, `InstructionIndexType`, `WordType` at L37–L40.
  - Handler type: `pub const HandlerFn = fn (*anyopaque, *const anyopaque) anyerror!noreturn;` at L7–L8 (matches Plan’s HandlerFn).
  - Jump metadata: `JumpDestMetadata` packed struct at L12–L16.
  - getMetadata: signature at L46–L50; implementation L90–L139. Returns:
    - PUSH1..PUSH8 inline integers via `bytecode.readPushValue` (L103–L111).
    - PUSH9..PUSH32 returns `*const u256` from `scratch_u256` (L112–L129).
    - `.JUMPDEST` returns dummy metadata (L131–L133); `.PC` returns current PC (L134–L136).
  - getNextInstruction: signature at L143–L147; semantics L148–L207. Advances PC by 1 normally; for PUSHx advances by opcode+data length (L183–L196). Returns handler for next opcode (L199–L206). Returns STOP handler if end of bytecode (L200–L203).
  - PC→instruction index: `getInstructionIndexForPc` returns `pc` (PC === instruction_idx) at L209–L215.
  - Jump and opcode-start queries: `isValidJumpDest` (bitmap) L217–L221; `isOpcodeStart` L223–L227.
  - Init/Deinit: `init(allocator, code, handlers) !Self` L229–L237; `deinit()` L239–L242.
  - Bytecode type: constructed via `createBytecode` with `.max_bytecode_size`/`.max_initcode_size` at L22–L26 (see Bytecode below).

- Differences vs Plan (optimized):
  - Plan (`src/evm/plan.zig`) stores an instruction stream of `InstructionElement` with handler pointers and inline metadata; see fields at L91–L110 and `getMetadata/getNextInstruction` at L112–L169 and L303–L369.
  - PlanMinimal stores only validated `BytecodeType` bitmaps + handler table; no instruction stream, no constants array, no pc->idx map by default (only helpers that read raw bytecode at runtime).

- Existing tests using PlanMinimal (all in `src/evm/plan_advanced.zig`):
  - “PlanMinimal basic functionality” at L717–L780.
  - “PlanMinimal getMetadata for all PUSH opcodes” at L782–L840.
  - “PlanMinimal getNextInstruction advances correctly” at L842–L892.
  - “PlanMinimal JUMPDEST detection with PUSH data” at L894–L904 (+ following assertions).
  - “PlanMinimal edge cases” at L925–L964.
  - “PlanMinimal getNextInstruction returns correct handlers” at L985–L1050.
  - “PlanMinimal PC opcode returns correct value” at L1051–L1078.
  - “Plan and PlanMinimal interoperability” at L1604–L1666.
  - “PlanMinimal JUMPDEST metadata” at L1752–L1776.
  - “PlanMinimal simulated execution flow” at L1786–L1862.
  - Note: `src/evm/plan_minimal.zig` also includes self-tests: see tests starting at L253, L275, L312, L346, etc.

- BytecodeType and validation (PlanMinimal relies on this):
  - File: `src/evm/bytecode.zig`
  - Factory: `pub fn Bytecode(comptime cfg: BytecodeConfig) type` at L71–L75; exported as `createBytecode` at L821–L822.
  - Validation on init: `init(allocator, code)` at L101–L131; enforces EIP-170 size limit (L109–L112), builds bitmaps and validates opcodes/push bounds in `buildBitmapsAndValidate` (Phase A at L325–L339; Phase B allocation+population at L341–L404). Also validates immediate JUMP/JUMPI targets at L406–L437.
  - Accessors used by PlanMinimal: `len()` L171–L176; `raw()` L178–L181; `readPushValue`/`readPushValueN` tested at L877–L893; `isValidJumpDest` implementation paths at L722–L741 and L742–L812 (scalar/SIMD marking); `is_op_start`/`is_jumpdest` bitmaps are populated in L361–L397 and updated in L399–L404.

2) FrameInterpreter architecture
- File: `src/evm/frame_interpreter.zig`
  - Handler table initialization: compile-time table at L55–L206, including real opcodes and synthetic fusions (L179–L205). Handler type alias: `const HandlerFn = plan_mod.HandlerFn;` at L41.
  - Init flow: `init(...)` at L208–L239. Creates `Frame` (L209), initializes `Planner` (L211), builds/gets optimized `Plan` with `planner.getOrAnalyze(bytecode, handlers, host.get_hardfork())` (L214). Optionally builds a reverse `idx_to_pc` table from plan’s `pc_to_instruction_idx` (L216–L229).
  - Interpret/tail-call dispatch: `interpret()` at L263–L293 fetches first handler from `plan.instructionStream[0]` (L275) and calls it. Tail-call style dispatch via `dispatchNext(next_handler, frame, plan)` at L350–L362; handlers retrieve the next handler from `plan.getNextInstruction` and re-dispatch.
  - Plan assumptions (advanced Plan only): handlers cast `plan` to `*const Plan` (L370 in PUSH generator; throughout) and frequently reference `plan.instructionStream` and `plan.getNextInstruction` (e.g., ADD at L683–L685). Jump handlers depend on `plan.getInstructionIndexForPc` and `instructionStream[...]` (L1455–L1463, L1484–L1493). This means the current handlers are specialized to the advanced `Plan` type, not `PlanMinimal`.
  - Current PC exposure: `getCurrentPc()` uses a reverse mapping if present (L241–L254). Without it, PC is unavailable from the interpreter.

3) Planner’s minimal plan entry point
- File: `src/evm/planner.zig`
  - Minimal planning function: `pub fn create_minimal_plan(self: *Self, allocator: std.mem.Allocator, handlers: [256]*const HandlerFn) !void` at L611–L662. It builds bitmaps (`is_push_data`, `is_op_start`, `is_jumpdest`) (L617–L651) and then frees them (L658–L661). Comment explicitly states it currently doesn’t return a plan object and shows intended usage for PlanMinimal (L653–L656):
    - “Full minimal plan implementation would create a PlanMinimal struct” and call `PlanMinimal.init(allocator, self.bytecode.raw(), handlers);`
  - Planner configuration: `src/evm/planner_config.zig` defines `PlannerConfig` with `WordType`, `maxBytecodeSize`, `enableLruCache`, `vector_length`, `stack_size`, and computed `PcType/StackIndexType/StackHeightType` helpers (L14–L55). Factory alias: `pub const createPlanner = Planner;` at `src/evm/planner.zig:L1971`.

4) Frame and execution context
- File: `src/evm/frame.zig`
  - Responsibilities and boundaries documented at the top (L3–L7): Frame does not handle PC tracking and jumps; those are managed by the Plan/Interpreter.
  - Key fields: `stack`, `bytecode`, `gas_remaining`, `gas_refund`, `initial_gas`, tracer, memory, optional database, logs/output, etc. (L86–L104).
  - Init/Deinit: `init(...)` L104–L140, `deinit(...)` L141–L152. Tracing hooks are compile-time gated via `config.TracerType` (L153–L170).
  - Jump validation helper used by handlers: `is_valid_jump_dest` (simple JUMPDEST check) at L731–L735. Advanced Plan then validates instruction-start via `getInstructionIndexForPc` at the interpreter layer.
  - Gas handling: Handlers use `opcode_data.OPCODE_INFO[op].gas_cost` and call `self.consumeGasUnchecked(...)` throughout the interpreter (see many occurrences in `frame_interpreter.zig`; e.g., ADD at L676). No precomputed static gas is required for minimal execution.

## Implementation Specification

### MinimalInterpreter — type and fields
Target: mirror `FrameInterpreter` but use `PlanMinimal(cfg)` instead of `Plan(cfg)` and track PC directly.

- Type signature (proposed): `pub fn MinimalInterpreter(comptime config: FrameConfig) type { ... }`
- Internals (fields):
  - `frame: Frame(config)` — same as advanced interpreter.
  - `plan: PlanMinimalType` — where `const PlanMinimalType = @import("plan_minimal.zig").PlanMinimal(.{ .WordType = config.WordType, .maxBytecodeSize = config.max_bytecode_size });`
  - `instruction_idx: PlanMinimalType.InstructionIndexType` — equals PC; initialize to 0 (PlanMinimal proof at `plan_minimal.zig:L209–L215`).
  - `allocator: std.mem.Allocator`.
  - No `idx_to_pc` mapping (unnecessary; PC is `instruction_idx`).

- Init (proposed flow, mirroring `frame_interpreter.zig:L208–L239`):
  1) Create `frame = try Frame.init(...)` (same args as advanced).
  2) Build handler table identically to advanced (reuse the compile-time table body at `frame_interpreter.zig:L55–L206`), but handlers must be specialized to the minimal plan type (see “Handler table sharing” below).
  3) `plan = try PlanMinimalType.init(allocator, bytecode, handlers);` (reference: `plan_minimal.zig:L229–L237`).
  4) Initialize `instruction_idx = 0`.

- Interpret (proposed):
  - If `plan.bytecode.len() == 0`, return.
  - Dispatch loop is tail-call via handlers just like advanced, but handlers must operate on PC and call `plan.getNextInstruction(&instruction_idx, opcode)` to advance. The first dispatch uses the handler for opcode at `pc=0`: `plan.handlers[plan.bytecode.raw()[0]](&self.frame, &self.plan)`.

### Key Differences to Enforce
- PC mapping: PC === instruction_idx, proven by `getInstructionIndexForPc` returning `pc` directly (`plan_minimal.zig:L209–L215`).
- No instruction stream: handlers cannot rely on `plan.instructionStream` nor synthetic opcodes.
- Runtime PUSH extraction: for PUSH9..PUSH32, `getMetadata` returns `*const u256` via `scratch_u256` (`plan_minimal.zig:L112–L129`). For PUSH1..PUSH8, returns inline integer types via `bytecode.readPushValue(...)` (`L103–L111`).
- Jump validation: use `plan.isValidJumpDest(pc)` (`L217–L221`) and `plan.isOpcodeStart(pc)` (`L223–L227`) to reject PUSH-data positions. Bytecode validation also rejects invalid immediate jump targets (`bytecode.zig:L406–L437`).

### Zero-Cost Abstractions
- Tracer elimination: Frame tracing calls are compiled out when `FrameConfig.TracerType == null` (see `frame.zig:L153–L170`). MinimalInterpreter must not add runtime conditionals on tracing; it should call `frame.traceBeforeOp/traceAfterOp` identically to advanced, letting comptime remove them.
- No extra allocations: PlanMinimal stores validated bitmaps inside `BytecodeType`; MinimalInterpreter does not need PC maps or instruction streams.
- Mode selection at comptime: Introduce a comptime strategy switch via `PlannerStrategy` (`src/evm/planner_strategy.zig:L3–L9`). Example pattern inside higher-level factory:
  - `const PlanLike = if (strategy == .minimal) PlanMinimalType else PlanType;`
  - `const InterpreterLike = if (strategy == .minimal) MinimalInterpreter(config) else FrameInterpreter(config);`
  This avoids runtime branches and lets dead code be eliminated.

## Integration Points

### Handler table sharing
- Signature compatibility: both Plan and PlanMinimal use `fn (*anyopaque, *const anyopaque) anyerror!noreturn` for handlers (`plan.zig:L35`, `plan_minimal.zig:L7–L8`).
- Plan-specific assumptions in current handlers:
  - Handlers cast `plan` to `*const Plan` and use `plan.getNextInstruction`/`plan.getMetadata` and `plan.instructionStream[...]` (e.g., ADD L672–L685; PUSH generator L370–L413; JUMP L1455–L1461). These cannot be reused verbatim for minimal, because of the cast and `instructionStream` dependency.
- Options:
  1) Generate a parallel set of handlers specialized to `PlanMinimal` with identical semantics (preferable for now).
  2) Refactor handlers to be generic over a `PlanLike` interface that exposes `getMetadata`, `getNextInstruction`, and (optionally) `getInstructionIndexForPc`. This requires adjusting all casts (`@ptrCast`) and removing direct `instructionStream` access.

### Tracer compatibility
- Tracer API is invoked from Frame via `traceBeforeOp/traceAfterOp/onError` (`frame.zig:L153–L170`). MinimalInterpreter should call these exactly as advanced does when entering/exiting a handler. No API differences are required.

## Test Requirements (grounded by existing tests)

Use and extend the existing PlanMinimal tests to validate the interpreter:
- Bytecode correctness and PC motion: reuse cases from `plan_advanced.zig:L717–L892`.
- PUSH metadata: reuse coverage at `plan_advanced.zig:L782–L840` and large PUSH pointer semantics proven in PlanMinimal `getMetadata` (L112–L129).
- Jump validation: reuse `plan_advanced.zig:L894–L904` (JUMPDEST vs PUSH-data) and PC start checks.
- Interop parity: leverage “Plan and PlanMinimal interoperability” (`L1604–L1666`) to compare behavior.
- Gas consumption: assert per-op gas via `opcode_data.OPCODE_INFO[op].gas_cost` exactly as advanced handlers do (see example in ADD at `frame_interpreter.zig:L672–L681`).

Example test skeleton (to be added near PlanMinimal tests if/when MinimalInterpreter is implemented):
```zig
test "MinimalInterpreter executes bytecode correctly" {
    const allocator = std.testing.allocator;
    // Handlers must be the minimal-specialized table
    var handlers: [256]*const @import("plan_minimal.zig").HandlerFn = undefined;
    // ...fill handlers with minimal versions of opcode handlers...

    const bytecode = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01, 0x00 }; // PUSH1 5; PUSH1 3; ADD; STOP
    const Frame = @import("frame.zig").Frame(.{});
    var interp = try MinimalInterpreter(.{}).init(allocator, &bytecode, 100000, {}, @import("host.zig").Host.init());
    defer interp.deinit(allocator);
    try interp.interpret();
    try std.testing.expectEqual(@as(u256, 8), interp.frame.stack.peek_unsafe());
}
```

## Answers to Key Questions

- JUMPDEST validation: PlanMinimal uses bitmaps built by `BytecodeType` to validate jump destinations and opcode starts. See `isValidJumpDest` (`plan_minimal.zig:L217–L221`) and bitmap construction in `bytecode.zig:L361–L404` and L399–L404 (SIMD/scalar marking at L722–L812).
- Memory layout differences:
  - Plan (optimized): instruction stream slice `[]InstructionElement`, constants array, optional `pc_to_instruction_idx{,_dense}`, and (on 32-bit) external JumpDest metadata backing (see `plan.zig:L91–L110`).
  - PlanMinimal: only validated `BytecodeType` (runtime code slice + three bitmaps) and a handler table (see `plan_minimal.zig:L28–L35`).
- Frame reuse: Yes. `Frame` is plan-agnostic; interpreter owns plan/pc management. Frame explicitly does not track PC (`frame.zig:L3–L7`).
- noreturn handler constraint: identical for both plans via `HandlerFn` type. Dispatch remains tail-call style via `return next_handler(frame, plan);` (advanced at `frame_interpreter.zig:L360–L362`). Minimal should mirror this.
- Performance expectations: Minimal avoids plan construction and instruction stream memory, but pays incremental runtime reads for metadata (notably PUSH values) and jump checks. Advanced plan benefits from fused opcodes and inline metadata; minimal is simpler and likely smaller in code size, valuable for `.ReleaseSmall` or WASM builds.

## Required Code References (quick index)

- PlanMinimal type/fields/methods: `src/evm/plan_minimal.zig` L18–L42, L46–L50, L90–L139, L141–L207, L209–L227, L229–L242.
- Bytecode validation and bitmaps: `src/evm/bytecode.zig` L101–L131, L325–L404, L406–L437, L722–L812.
- Advanced Plan APIs for comparison: `src/evm/plan.zig` L91–L110, L112–L169, L303–L369.
- FrameInterpreter init/dispatch: `src/evm/frame_interpreter.zig` L208–L239, L263–L293, L350–L362, handler examples around L672–L705, jump handlers L1455–L1461 and L1484–L1493.
- Planner minimal function: `src/evm/planner.zig` L611–L662; Planner config: `src/evm/planner_config.zig` L14–L55.
- Strategy enum: `src/evm/planner_strategy.zig` L3–L9.

## Implementation Checklist

- Define `MinimalInterpreter(config)` with fields: `frame`, `plan` (PlanMinimal), `instruction_idx` (Pc), `allocator`.
- Build minimal-specialized handler table (copy of advanced table but casting `plan` to `*const PlanMinimalType` and removing `instructionStream` assumptions).
- Implement `init`/`deinit` and `interpret` (first handler = handler for opcode at PC 0; no instruction stream).
- PUSH metadata reads must use PlanMinimal semantics (inline for 1..8 bytes, `scratch_u256` pointer for 9..32 bytes).
- JUMP/JUMPI must validate `isValidJumpDest(pc)` and `isOpcodeStart(pc)` and set `instruction_idx` directly to destination PC.
- Ensure tracing calls follow Frame’s hooks and are compiled out when tracing is disabled.
- Keep zero allocations beyond PlanMinimal and Frame; no `idx_to_pc` reverse map.
- Extend tests by mirroring PlanMinimal tests and asserting identical results on stack/memory/gas for simple programs.

## Notes on Planner Integration

Planner is not required to build minimal plans: `PlanMinimal.init(allocator, bytecode, handlers)` suffices. If `Planner.create_minimal_plan` is pursued, change its return type to the configured `PlanMinimal(Cfg)` and return `try PlanMinimal.init(allocator, self.bytecode.raw(), handlers);` (see `src/evm/planner.zig:L653–L656`).

## Appendix — Evidence of PC=idx and metadata behavior

- PC equality: `getInstructionIndexForPc` returns the input PC (L209–L215 in `plan_minimal.zig`).
- PUSH handling: `getMetadata` inline types for 1..8 bytes; `scratch_u256` pointer for 9..32 (L103–L111, L112–L129).
- Next-instruction advancement: `getNextInstruction` computes next PC by inspecting the opcode byte at current PC (L183–L196) and returns the handler for that PC (L199–L206).

This research-backed spec removes ambiguity and provides the exact lines and APIs required to implement a MinimalInterpreter that uses PlanMinimal safely and efficiently.
