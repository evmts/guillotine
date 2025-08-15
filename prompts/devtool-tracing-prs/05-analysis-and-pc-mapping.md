## PR 5: Analysis and PC Mapping in the UI

### Problem

We need to render a synchronized view of:

- the optimized instruction stream produced by analysis (with fused ops, BEGINBLOCK, etc.), and
- the original bytecode stream (PC-indexed bytes)

…such that on every step we can highlight both the current analysis instruction and the exact original bytecode PC(s) it maps to. We also want to annotate valid/invalid jump destinations using analysis results.

The codebase already exposes all required data. This PR wires it through to the Devtool runtime and UI with strong guarantees and tests.

### High-level design

- Analysis provides a compact instruction stream and mapping tables:
  - `inst_to_pc`: map from analysis instruction index → original bytecode PC (if known; else sentinel)
  - `pc_to_block_start`: map from original bytecode PC → analysis BEGINBLOCK instruction index
  - `jumpdest_array`: packed set of valid JUMPDEST PCs
- Interpreter (and Devtool’s analysis-first stepper) can determine the current instruction pointer (`Instruction*`) and derive:
  - instruction index: pointer arithmetic against `analysis.instructions.ptr`
  - current PC: `analysis.inst_to_pc[idx]` (with sentinel fallback)
- Devtool runtime serializes analysis artifacts in JSON for the UI. We will add:
  - `currentPc`: the best-known original PC for the current instruction
  - `jumpdests`: packed positions array to mark valid jump destinations in the bytecode view
  - keep existing per-block `pcs`, `opcodes`, `hex`, and `data` already derived from analysis/code
- UI highlights:
  - current instruction row in the instruction list (existing)
  - current byte in the bytecode grid using `currentPc`
  - overlays jumpdest validity using `jumpdests`

### Ground truth APIs and structures

Key types the PR relies on:

```69:101:/Users/polarzero/code/tevm/guillotine/src/evm/code_analysis.zig
    /// Mapping from bytecode PC to the BEGINBLOCK instruction index that contains that PC.
    /// Size = code_len. Value = maxInt(u16) if unmapped.
    pc_to_block_start: []u16, // 16 bytes - accessed on EVERY jump

    /// Packed array of valid JUMPDEST positions in the bytecode.
    /// Required for JUMP/JUMPI validation during execution.
    /// Uses cache-efficient linear search on packed u15 array.
    jumpdest_array: JumpdestArray, // 24 bytes - accessed on jump validation

    /// Original contract bytecode for this analysis (used by CODECOPY).
    code: []const u8, // 16 bytes - accessed by CODECOPY/CODESIZE

    /// Original code length (used for bounds checks)
    code_len: usize, // 8 bytes - accessed with code operations

    /// For each instruction index, indicates if it is a JUMP or JUMPI (or other).
    /// Size = instructions.len
    inst_jump_type: []JumpType, // 16 bytes - accessed during control flow

    /// Mapping from instruction index to original bytecode PC (for debugging/tracing)
    inst_to_pc: []u16, // 16 bytes - only for debugging/tracing
```

```60:88:/Users/polarzero/code/tevm/guillotine/src/evm/jumpdest_array.zig
    /// Validates if a program counter is a valid JUMPDEST using cache-friendly linear search.
    pub fn is_valid_jumpdest(self: *const JumpdestArray, pc: usize) bool {
        if (self.positions.len == 0 or pc >= self.code_len) return false;
        const start_idx = (pc * self.positions.len) / self.code_len;
        // ... forward/backward search over packed positions
```

Interpreter tracing shows how to derive `idx` and map to a PC (we’ll mirror this in Devtool):

```50:67:/Users/polarzero/code/tevm/guillotine/src/evm/evm/interpret.zig
            const base: [*]const @TypeOf(inst.*) = analysis.instructions.ptr;
            const idx = (@intFromPtr(inst) - @intFromPtr(base)) / @sizeOf(@TypeOf(inst.*));
            if (idx < analysis.inst_to_pc.len) {
                const pc_u16 = analysis.inst_to_pc[idx];
                if (pc_u16 != std.math.maxInt(u16)) {
                    const pc: usize = pc_u16;
                    const opcode: u8 = if (pc < analysis.code_len) frame.analysis.code[pc] else 0x00;
                    // ...
```

Devtool already builds rich block/PC/opcode tables for the UI:

```323:381:/Users/polarzero/code/tevm/guillotine/src/devtool/evm.zig
                while (j < instrs.len and instrs[j].arg != .block_info) : (j += 1) {
                    const mapped_u16: u16 = if (j < a.inst_to_pc.len) a.inst_to_pc[j] else std.math.maxInt(u16);
                    var pc: usize = 0;
                    if (mapped_u16 != std.math.maxInt(u16)) {
                        pc = mapped_u16;
                        last_pc_opt = pc;
                    } else if (last_pc_opt) |prev_pc| {
                        // derive best-effort PC from previous PC + opcode immediate size
                        // ...
                    }
                    // populate pcs/opcodes/hex/data lists for the block rows
```

### Implementation plan (precise edits)

#### 1) Devtool runtime: add currentPc and jumpdests to serialized state

File: `src/devtool/evm.zig`

Edits:

- Compute current instruction index from the frame’s `instruction` pointer (already done) and derive the best-known original PC:
  - If `inst_to_pc[idx] != maxInt(u16)`, use that value
  - Else, fall back to our existing derived PC logic used in `serializeEvmState` for table rows (use `last_pc_opt` then `prev_op` immediate length)
- Serialize two new fields in the returned JSON object:
  - `currentPc: usize`
  - `jumpdests: []usize` extracted from `analysis.jumpdest_array.positions` (cast u15→usize)

Where to add:

- Right before constructing `state` in `serializeEvmState()`, compute `current_pc` using `self.instr_index` and `a.inst_to_pc`.
- Build a `jumpdests` `std.ArrayList(usize)` from `a.jumpdest_array.positions`.
- Extend `debug_state.EvmStateJson` object literal to include `.currentPc` and `.jumpdests`.

Edge cases and fallbacks:

- If index is out of range or sentinel, fall back to 0.
- Guard `current_pc < a.code_len` before UI uses it; UI treats out-of-range as “no highlight”.

Complexity: O(positions.len) once per serialization to copy packed jumpdests; typical contracts have sparse jumpdests so this is cheap for dev tooling. If needed, we can cache the slice in `DevtoolEvm` after load.

#### 2) Devtool step result: expose PC for immediate consumers (optional)

If you intend to stream per-step info (e.g., incremental UI without re-serializing full state), extend `DebugStepResult` with:

- `pc: usize` (current PC after the step), computed the same way as above.

This is optional because the current UI already calls `serializeEvmState()` after each step.

#### 3) TypeScript types and UI wiring

File: `src/devtool/solid/lib/types.ts`

Edits:

- Extend `EvmState` with:
  - `currentPc: number`
  - `jumpdests: number[]`

File: `src/devtool/solid/components/evm-debugger/BytecodeBlocksMap.tsx`

Edits:

- Accept two new props (thread them from parent):
  - `currentPc: number`
  - `jumpdests: number[]`
- Highlight the single cell at `currentPc` in addition to the block-coloring you already do:
  - If `pc() === props.currentPc`, apply a stronger highlight (e.g., amber-600/90 + ring)
- Optionally mark valid jumpdests with a subtle dot/underline:
  - Build a `Set` from `jumpdests` for O(1) checks; if `pc()` in set, add a small indicator (e.g., a corner dot or border) and a title tooltip “valid JUMPDEST”.

File: `src/devtool/solid/components/evm-debugger/ExecutionStepsView.tsx`

Edits:

- No functional change required; it already highlights the active instruction by index. Keep as-is.

Parent component (where state is fetched): ensure you pass `currentPc` and `jumpdests` down to `BytecodeBlocksMap` along with existing `codeHex`, `blocks`, and `currentBlockStartIndex`.

#### 4) Optional dual-pane “CodePane”

You can keep the current split (ExecutionStepsView + BytecodeBlocksMap) which already implements a dual-pane experience. If you prefer a single compositional wrapper, create `CodePane.tsx` that just composes these two with synchronized props; no additional logic required.

### Mapping details and edge cases

- Instruction index derivation:
  - Use the exact pointer arithmetic from interpreter (see citation above): `idx = (ptr - base) / sizeof(Instruction)`
- Mapping to original PCs:
  - Prefer `inst_to_pc[idx]` when not sentinel (`!= maxInt(u16)`). This is the authoritative mapping from analysis
  - For fused/meta instructions with sentinel PC, derive a best-effort PC:
    - Keep `last_pc_opt` as you traverse the current block; if the previous opcode was at `prev_pc` and is a PUSH with N bytes, the next opcode’s PC is `prev_pc + 1 + N`
    - PUSH immediate length: `N = op == 0x5f ? 0 : (0x60..0x7f ? op - 0x5f : 0)`
- BEGINBLOCK rows:
  - BEGINBLOCK (`.block_info`) is meta; it precedes visible instructions in the block. UI highlights instructions (`idx > beginIndex`) while BEGINBLOCK stays in the header columns (gas, stack)
- Dynamic jumps:
  - When executing `.jump_unresolved`/`.conditional_jump_unresolved`, the target resolution uses `pc_to_block_start[dest]` guarded by `jumpdest_array.is_valid_jumpdest(dest)`
  - The UI doesn’t need to simulate jumps; it only visualizes state. We surface `jumpdests` for tooltips/overlays and keep highlighting by `currentInstructionIndex` and `currentPc`
- Invalid jump detection:
  - For convenience you can also expose a helper in the runtime like `isValidJumpdest(pc)` using `jumpdest_array.is_valid_jumpdest(pc)`. The UI can show different styling if `currentPc` is not a JUMPDEST while the instruction is a JUMPDEST (shouldn’t happen) or if the upcoming target (peeked from stack) is invalid (requires simulator; out of scope for now)

### File-by-file diffs (sketch)

These are the exact places to add code. Names are precise to speed implementation.

1. `src/devtool/evm.zig`

   - In `serializeEvmState(self: *DevtoolEvm) ![]u8`:
     - After computing `self.instr_index`, derive `current_pc`:
       - If `self.analysis) |a|` then:
         - If `self.instr_index < a.inst_to_pc.len` and `a.inst_to_pc[self.instr_index] != maxInt(u16)` then `current_pc = a.inst_to_pc[self.instr_index]`
         - Else reuse the local “derive PC” logic you already have for per-row fallback using `last_pc_opt`
     - Build `jumpdests`: iterate `a.jumpdest_array.positions` and push into a `std.ArrayList(usize)`
     - Extend `state` with `.currentPc = current_pc` and `.jumpdests = try jumpdests_list.toOwnedSlice()`
   - Optionally in `DebugStepResult` (struct at top), add `pc: usize` and set it in `stepExecute()` right before returning

2. `src/devtool/solid/lib/types.ts`

   - Extend `export interface EvmState`:
     - `currentPc: number`
     - `jumpdests: number[]`

3. `src/devtool/solid/components/evm-debugger/BytecodeBlocksMap.tsx`

   - Props: add `currentPc: number`, `jumpdests: number[]`
   - In the cell renderer:
     - If `pc() === props.currentPc`, apply a strong highlight class (e.g., `bg-amber-600/90 text-black ring-2 ring-amber-500`)
     - Create a `jumpSet = new Set(props.jumpdests)` (memoized) and show a small indicator for `jumpSet.has(pc())`

4. Parent wiring (where you already fetch/hold `EvmState` from the Rust/Zig bridge): pass `state.currentPc` and `state.jumpdests` to `BytecodeBlocksMap`.

### Tests

All tests live in-source per project conventions.

1. Zig unit tests (Devtool runtime)

- Add to `src/devtool/evm.zig` alongside existing tests:
  - Test: mapping consistency for a small program with PUSH/JUMPDEST/JUMP
    - Load `0x6003565b00` (PUSH1 3; JUMP; JUMPDEST; STOP)
    - After `resetExecution()`, assert that `serializeEvmState()` includes:
      - `blocks[?].pcs` containing 3 for the block starting at the JUMPDEST
      - `jumpdests` contains `[3]`
    - Step once; assert `currentPc` equals the mapped PC for the executed instruction

2. Zig unit tests (JSON shape)

- Extend `DevtoolEvm.serializeEvmState returns valid JSON` to parse and assert presence and types of `currentPc` and `jumpdests`

3. Visual smoke test (manual)

- Load sample contracts (e.g., “Jump and Control Flow”) from `sampleContracts`
- Verify:
  - Current instruction row highlights in the steps table
  - Current PC byte highlights in the bytecode grid
  - JUMPDEST bytes have visible markers

### Performance and safety notes

- Analysis artifacts are computed once on load via `CodeAnalysis.from_code` and retained on `DevtoolEvm`
- Packed jumpdest array is tiny (u15 per dest). Copying to JSON per refresh is fine for devtool; cache if needed
- Always guard indexes; treat `maxInt(u16)` as a sentinel “unknown PC”
- Memory ownership:
  - `serializeEvmState` currently allocates slices for JSON, then frees via `debug_state.freeEvmStateJson`. Keep additions consistent (use allocator, then include in state so they are freed alongside)

### Acceptance criteria

- UI highlights the current instruction row and the exact byte at `currentPc` in the byte grid
- Valid jumpdest positions are visually marked in the byte grid
- The state JSON contains `currentPc` and `jumpdests`
- Mapping remains correct across steps, including through fused instructions and meta BEGINBLOCK boundaries

### FAQ / gotchas

- Why can `inst_to_pc[idx]` be unknown? Fused/meta instructions (e.g., BEGINBLOCK, certain optimized patterns) may not have a 1:1 original PC. Use the fallback derivation based on the previous known PC and opcode immediate size
- Are `currentPc` and “originalPc” different? No. `inst_to_pc` maps to original bytecode; we expose it directly
- Can we highlight the entire span for PUSH (opcode + immediates)? You can, but it’s optional. Start with highlighting the opcode byte at `currentPc`
- Do we need to modify the interpreter? No. Devtool uses the analysis-stepper path; the interpreter already traces PCs in `build_options.enable_tracing` mode for external tracers

### Reference snippets (for quick copy/paste during implementation)

Derive instruction index from pointer:

```118:126:/Users/polarzero/code/tevm/guillotine/src/evm/evm/interpret.zig
    var instruction: *const Instruction = &frame.analysis.instructions[0];
    // ...
    const analysis = frame.analysis;
    // ...
    const base: [*]const Instruction = analysis.instructions.ptr;
    const idx = (@intFromPtr(instruction) - @intFromPtr(base)) / @sizeOf(Instruction);
```

Jumpdest validation:

```60:88:/Users/polarzero/code/tevm/guillotine/src/evm/jumpdest_array.zig
pub fn is_valid_jumpdest(self: *const JumpdestArray, pc: usize) bool { /* … */ }
```

Access to mapping arrays:

```268:281:/Users/polarzero/code/tevm/guillotine/src/evm/code_analysis.zig
    .pc_to_block_start = gen.pc_to_block_start,
    .jumpdest_array = jumpdest_array,
    .code = code,
    .code_len = code.len,
    .inst_jump_type = gen.inst_jump_type,
    .inst_to_pc = gen.inst_to_pc,
```

UI active row logic (already present):

```111:121:/Users/polarzero/code/tevm/guillotine/src/devtool/solid/components/evm-debugger/ExecutionStepsView.tsx
const isActive =
  blk.beginIndex === props.currentBlockStartIndex &&
  idx() === Math.max(0, props.currentInstructionIndex - blk.beginIndex - 1)
```

### Rollout checklist

- Implement runtime fields (`currentPc`, `jumpdests`) and run:
  - `zig build && zig build test`
- Update TS types and UI props; run web UI with sample programs
- Verify mapping on dispatcher-y bytecode (PUSH..JUMPI..JUMPDEST) and a longer runtime (ERC20)

This should give you a complete, precise path to implement PC mapping in the UI with confidence, using the existing analysis data and without touching hot execution paths.
