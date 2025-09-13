# Static Jump Optimization — Implementation Plan (Reset)

Goal: Replace deprecated PUSH+JUMP/JUMPI handlers that do a runtime binary search with static jump handlers that tail-call directly to a pre-resolved dispatch pointer.

This is strictly a preprocessor change plus handler wiring. No runtime binary search should occur for fused jumps.

Key invariants
- All static jump destinations must be fully resolved before execution starts.
- The dispatch stream layout must match `dispatch_opcode_data.zig` expectations:
  - For `JUMP_TO_STATIC_LOCATION` / `JUMPI_TO_STATIC_LOCATION`: `cursor[0]` = handler, `cursor[1]` = `.jump_static` metadata, `cursor[2]` = next handler.
- Jump targets are PCs (bytecode offsets), not schedule indices. Always resolve PCs → dispatch pointers during finalize.

What to build
1) Preprocessor emits synthetic static jump opcodes and a fixup placeholder for metadata.
2) Preprocessor records unresolved fixups (metadata index + target PC) in a queue.
3) After building the full schedule and the jump table, preprocessor resolves each fixup by looking up the dispatch pointer with the same mechanism used by dynamic jumps.

Where to change
- `src/preprocessor/dispatch.zig`
  - Add a small “fixup” queue type (e.g., `struct { schedule_index: usize, target_pc: PcType }`).
  - Update the fusion path to append static handlers and push fixups.
  - After schedule construction, create the jump table and resolve all fixups.
- `src/frame/frame_handlers.zig`
  - Map new synthetic opcodes to new handlers (one-liners).
- Eventually remove deprecated handlers once tests pass end-to-end.

Step-by-step
1) Fusion emission (single-pass)
- In the main bytecode loop in `Dispatch.init`:
  - When you see `.push_jump_fusion` or `.push_jumpi_fusion`:
    - Append the handler pointer for the static opcode:
      - `JUMP_TO_STATIC_LOCATION` for JUMP
      - `JUMPI_TO_STATIC_LOCATION` for JUMPI
    - Append a placeholder metadata item at the next slot: `.jump_static = { .dispatch = PLACEHOLDER }`.
      - Use a non-null sentinel value (e.g., `@ptrFromInt(1)`) because `*const anyopaque` cannot be null.
      - DO NOT attempt to resolve here, even for backward jumps. Treat all as fixups for consistency and simplicity.
    - Push a record onto `unresolved` with:
      - `schedule_index` = index where you just wrote the `.jump_static` metadata
      - `target_pc` = the immediate value from the fused PUSH (cast to `PcType` with bounds checks)

2) Track JUMPDESTs
- During the same pass, when encountering `.jumpdest`, record the mapping from `pc → schedule_index_of_that_jumpdest`.
  - We already capture this today (handler + metadata for JUMPDEST). Keep it.
  - This ensures we can build a jump table without re-iterating bytecode if desired.

3) Build jump table
- After converting the `ArrayList` of schedule items to a slice (`final_schedule`), build a `JumpTable`:
  - Either by using the already collected `pc → schedule_index` map (`createJumpTableFromMap` exists), or by scanning bytecode via the provided builder.
  - The result is a `JumpTable` whose entries map each JUMPDEST PC to a `Dispatch` with `cursor = schedule.ptr + schedule_index`.

4) Resolve fixups (two-pass resolution)
- For each entry in `unresolved`:
  - Lookup `jump_table.findJumpTarget(target_pc)`.
  - If found, write `schedule[schedule_index].jump_static.dispatch = @ptrCast(jump_dispatch.cursor)`.
  - If not found, return an error from `Dispatch.init` (invalid fused jump destination observed at preprocessing time).

5) Handler wiring (one-time)
- In `src/frame/frame_handlers.zig` (synthetic section):
  - `JUMP_TO_STATIC_LOCATION` → `JumpSyntheticHandlers.jump_to_static_location`
  - `JUMPI_TO_STATIC_LOCATION` → `JumpSyntheticHandlers.jumpi_to_static_location`

6) Remove deprecated inline handlers (after green tests)
- Delete `push_jump_inline` and `push_jumpi_inline` usage/mapping only after the synthetic static path is passing all tests (`zig build test-opcodes`).

Minimal function shapes (for clarity only)
- Fixup record:
  - `const UnresolvedJump = struct { schedule_index: usize, target_pc: PcType };`
- Fusion emission helper:
  - `handleStaticJumpFusion(schedule_items, unresolved, allocator, imm_value_u256, fusion_kind)`
    - Append handler → append placeholder `.jump_static` → push fixup
    - No jumpdest map parameter is required here (keep the API small and focused).
- Finalize:
  - After `const final_schedule = try schedule_items.toOwnedSlice(allocator);`
  - Build `JumpTable` (using either the map we built during `.jumpdest` handling or the builder).
  - Resolve all `unresolved` fixups via `jump_table.findJumpTarget(pc)` and patch `.jump_static.dispatch`.

Validation and errors
- If `imm_value_u256` does not fit in `PcType`, treat it as invalid static jump (fall back to inline handler during emission).
- If `findJumpTarget(pc)` returns null during fixup resolution, return an error (bytecode contained a fused static jump to a non-JUMPDEST).
- No static jump should reach runtime with a placeholder — resolution is mandatory before execution.

**CRITICAL: DO NOT ASSUME TEST BYTECODE IS INVALID**
- If you get `InvalidStaticJump` errors during tests, YOUR IMPLEMENTATION IS WRONG, not the tests
- The test bytecode DOES have valid jump destinations
- Common bugs to check:
  - PC calculation is wrong (remember: PC is the bytecode offset where the instruction starts)
  - Schedule index tracking is off (did you account for metadata slots correctly?)
  - JUMPDEST map isn't being populated correctly
  - Jump table isn't being built/used correctly
- DO NOT implement workarounds that fall back to inline handlers during resolution
- DO NOT change handler types after they've been emitted
- The resolution phase should ONLY update pointers, never change handler types

Gotchas
- PC vs. schedule index: PCs are bytecode offsets; schedule indices are positions in the dispatch array. Only the jump table knows how to map PCs to schedule indices.
- Metadata placement must match `dispatch_opcode_data.zig` expectations: handler at `[0]`, metadata at `[1]`, next handler at `[2]`.
- Avoid passing unused parameters (e.g., do not thread a jumpdest map into the fusion helper if you won’t read it there).
- Memory safety: use defer/errdefer consistently when allocating push-pointer metadata or auxiliary slices.

Testing checklist
- `zig build && zig build test-opcodes` must pass.
- Differential tests against REVM still pass.
- Inspect schedule dump (pretty print) to confirm static jump sites have handler + `.jump_static` (not inline values).

Definition of done
- No runtime binary search for fused jumps; all static jumps tail-call to the pre-resolved dispatch pointer.
- Deprecated inline jump handlers removed after tests are green.
