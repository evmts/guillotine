## PR 5: Analysis and PC Mapping in the UI

### Problem

We need to show both optimized analysis instructions and original bytecode with accurate PC mapping per step. Analysis already provides a mapping back to original PCs.

### Goals

- Surface analysis results and original bytecode together, synced by step.
- Highlight current instruction in both views; show jump destinations and invalid jump detection.

### Scope

- Use `src/evm/analysis.zig` API to obtain:
  - instruction list (optimized/decoded)
  - mapping `inst_index -> original_pc`
- Extend tracer step to carry `original_pc` (by joining with analysis result or by looking up when producing StructLog).
- Devtool UI: dual-pane code view showing bytecode and decoded instruction list, both with highlight.

### Files

- `src/devtool/evm.zig`: attach analysis output to loaded program; include mapping in step records.
- UI components in `src/devtool/solid/components/*`: new `CodePane` that accepts `bytecode`, `instructions`, and `current_index`.

### Tests

- Unit test: for known bytecode with PUSH/JUMPDEST/JUMP, ensure mapping remains consistent through steps.
- Visual smoke test: load sample bytecode and verify both panes update together on step.

### Acceptance Criteria

- For each step, UI can display `pc` and `original_pc` and highlight both correctly.
- Jump-related UI affordances (valid/invalid) derive from analysis bitvec.

### Notes

- Keep mapping computation off hot path; compute once at load and store on runner.
