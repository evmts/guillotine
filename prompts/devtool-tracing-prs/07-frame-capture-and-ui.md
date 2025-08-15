## PR 7: Frame Capture and UI

### Problem

The UI should visualize call frames (depth, addresses, value, input/output), not just the current frame. We need a clean design to capture frame lifecycle and render it.

### Goals

- Capture frame open/close along message phases; display a collapsible call tree.
- Show per-frame: address, caller, value, gas, input size, output size, status (ok/revert), and step range.

### Scope

- Extend hooks: when `onMessage(before)` create a new frame node; when `onMessage(after)` finalize it with status and return data summary.
- Tracer stores a lightweight frame timeline with references to step indices.
- UI adds a sidebar tree to navigate frames; selecting a frame filters the step list to that range.

### Files

- `src/evm/tracing/standard_tracer.zig`: record frame entries with indices and metadata.
- Devtool: new model `FrameTimeline` with derived selectors for active frame and children.
- UI: `FrameTree.tsx` to render depth-aware list; click selects and highlights corresponding steps.

### Tests

- Execute nested CALLs and verify frame nesting order and ranges.
- Revert path: ensure status recorded as revert and range ends at the right step.

### Acceptance Criteria

- UI shows a frame tree; selection syncs with step view.
- Frame metadata accurate for simple and nested calls.

### Notes

- Keep storage of large return data out of timeline nodes; store sizes and first N bytes preview.
