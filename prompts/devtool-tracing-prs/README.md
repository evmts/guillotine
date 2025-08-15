## Devtool Tracing PR Stack

This folder contains a stack of self-contained PR specifications to add interactive step-by-step execution, tracers, and side-by-side comparison to Guillotine and its Devtool. Each file is intended to be the full, standalone specification for one PR, including design, file touch-list, tests, and acceptance criteria.

### PR Order (top to bottom)

- 01-interpreter-debug-hooks.md
- 02-standard-memory-tracer-guillotine.md
- 03-mini-evm-comparator.md
- 04-devtool-refactor-to-tracer.md
- 05-analysis-and-pc-mapping.md
- 06-side-by-side-execution.md
- 07-frame-capture-and-ui.md
- 08-qa-and-test-plan.md

### Principles

- Follow `CLAUDE.md` strictly: build+tests must pass after every edit; single-responsibility PRs; no abstractions in tests; memory ownership clear with defer/errdefer.
- Do not regress performance when tracing is disabled; hooks must be zero-cost when unset.

### Quick Links

- EVM core files referenced here: `src/evm/evm/interpret.zig`, `src/evm/evm.zig`, `src/evm/execution/system.zig`, `src/evm/instruction.zig`, `src/evm/analysis.zig`
- Tests referenced: `test/evm/opcodes/system_test.zig`, `test/evm/instruction_test.zig`, `test/differential/*`
- Devtool references: `src/devtool/evm.zig`, `src/devtool/webui/*`, `src/devtool/solid/*`
