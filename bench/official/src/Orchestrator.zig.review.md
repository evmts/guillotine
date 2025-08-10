## Review: bench/official/src/Orchestrator.zig (benchmark orchestration)

### High-signal findings

- Discovers cases, selects runs/internal runs per EVM and case, and normalizes hyperfine output per internal run. Exports JSON/Markdown.

### Opportunities

- Avoid hardcoded absolute paths; resolve from repo root or executable location robustly. Add CSV export. Consider parallelizing independent hyperfine runs where it won’t distort CPU caches (optional).


