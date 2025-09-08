# CLI (Go)

Terminal UI experiments and examples for interacting with Guillotine.

## Overview

This directory is a standalone Go module that uses Bubble Tea to prototype interactive views. It does not participate in the Zig build; build it with Go.

## Layout

- `main.go` — tiny program that boots the internal TUI model
- `internal/app` — application model/state used by the TUI
- `internal/ui` — presentation and layout components
- `internal/config` — theming and config strings/keys

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
