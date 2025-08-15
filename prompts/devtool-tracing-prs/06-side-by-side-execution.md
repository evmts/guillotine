## PR 6: Side-by-Side Execution (Primary EVM vs Mini EVM)

### Problem

We want the devtool to execute bytecode in both engines (primary and mini) and compare results live.

### Goals

- Execute the same bytecode+calldata in the primary EVM and the Mini EVM.
- Show step-by-step comparison: op, pc/original_pc, gas before/cost, stack depth, and diffs.
- Provide mismatch highlighting and minimal diff rendering for stack/memory.

### Scope

- Devtool runner: add `run_both()` mode that executes primary and mini and produces comparison results per-step in debug mode, per-call otherwise.
- Use `src/evm/debug/shadow.zig` comparator from PR 3 to compute diffs.
- UI: side-by-side panes with synchronized stepping and mismatch badges.

### Files

- `src/devtool/evm.zig`: orchestrate running primary and mini, feed data to comparator, and surface mismatches.
- `src/devtool/solid/components/ComparisonView.tsx`: new component rendering side-by-side.

### Tests

- Differential tests (Zig) for simple programs to ensure equality; reuse `test/differential/*` where applicable and add UI-facing smoke tests in headless mode.

### Acceptance Criteria

- For canonical samples, steps align exactly; mismatches are highlighted with meaningful details.
- Works with pause/resume and breakpoints; both engines stay in sync by step index.

### Notes

- When step counts differ, show alignment up to min length and surface divergence reason.
