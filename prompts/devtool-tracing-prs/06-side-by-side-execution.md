## PR 6: Side-by-Side Execution (Guillotine vs REVM)

### Problem

We want the devtool to execute bytecode in both engines and compare traces and results live.

### Goals

- Execute the same bytecode+calldata in Guillotine and REVM.
- Show step-by-step comparison: op, pc/original_pc, gas before/cost, stack depth, and diffs.
- Provide mismatch highlighting and minimal diff rendering for stack/memory.

### Scope

- Devtool runner: add `run_both()` mode that produces two traces and a comparison result per step.
- Add a comparator module to align steps (by index) and compute diffs.
- UI: side-by-side panes with synchronized stepping and mismatch badges.

### Files

- `src/devtool/evm.zig`: integrate `revm_wrapper` call to fetch REVM trace; orchestrate comparison.
- `src/devtool/solid/components/ComparisonView.tsx`: new component rendering side-by-side.

### Tests

- Differential tests (Zig) for simple programs to ensure equality; reuse `test/differential/*` where applicable and add UI-facing smoke tests in headless mode.

### Acceptance Criteria

- For canonical samples, steps align exactly; mismatches are highlighted with meaningful details.
- Works with pause/resume and breakpoints; both engines stay in sync by step index.

### Notes

- When step counts differ, show alignment up to min length and surface divergence reason.
