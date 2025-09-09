# CLI (Go)

Terminal UI experiments and examples for interacting with Guillotine.

## Overview

This directory is a standalone Go module that uses Bubble Tea to prototype interactive views. It does not participate in the Zig build; build it with Go.

## Layout

- `main.go` — entry point that initializes the Bubble Tea program
- `internal/app/` — MVU pattern implementation (model, update, view, handlers)
- `internal/core/` — business logic domains:
  - `evm/` — EVM call execution and validation
  - `bytecode/` — bytecode analysis using Go SDK bindings
  - `history/` — call history and contract tracking
  - `state/` — persistence and state management
- `internal/ui/` — pure rendering components (no state)
- `internal/types/` — shared type definitions
- `internal/config/` — theming, keys, and UI strings

## Build

```bash
cd apps/cli
go build -o guillotine-cli
./guillotine-cli
```

This produces a minimal demo executable. There is no `zig build` entry for the CLI.

## Notes

- The Go CLI is intentionally lightweight and decoupled from the Zig EVM runtime; it serves as a UX sandbox.
- Dependencies are pinned in `go.mod`/`go.sum`.
- Internal packages expose no public API—external consumers should not import them directly.
