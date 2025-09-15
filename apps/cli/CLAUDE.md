# Guillotine CLI

TUI for Guillotine EVM. Go + Bubbletea MVU pattern.

## Structure

```
apps/cli/
├── main.go                    # Entry point
├── go.mod/go.sum             # Dependencies
├── poc_test.go               # Integration tests
└── internal/
    ├── types/call_types.go   # Types, states, structures
    ├── config/               # Configuration hub
    │   ├── keys.go          # Key bindings
    │   ├── messages.go      # UI text strings
    │   ├── theme.go         # Colors, styles
    │   ├── call_defaults.go # EVM defaults
    │   └── errors.go        # Error types
    ├── app/                  # Logic & state
    │   ├── model.go         # Model, Init(), Update(), View()
    │   ├── call_executor.go # EVM execution
    │   └── validation_test.go
    └── ui/                   # Pure UI components
        ├── header/menu/help/layout.go
        └── call_input/call_list.go
```

## MVU Pattern

**Model**: State container (cursor, params, results)
**Update**: Events → state changes, async commands
**View**: State → UI string

## States

```
MainMenu → CallParameterList → CallParameterEdit
                ↓
         CallExecuting → CallResult → MainMenu
```

## EVM Integration

**Call Types**: CALL, STATICCALL, DELEGATECALL, CREATE, CREATE2
**FFI**: Go → C → Zig via CGo
**Validation**: Address (40 hex), Gas (uint64), Value (Wei), Data (0x...)

## Quick Ref

| File | Purpose |
|------|---------|
| `types/call_types.go` | Type definitions |
| `config/messages.go` | ALL UI text |
| `config/theme.go` | ALL colors/styles |
| `config/keys.go` | ALL key bindings |
| `app/model.go` | State & logic |
| `ui/*.go` | Pure render functions |

## Adding Features

1. Constants → `config/`
2. State → Model struct
3. Events → Update()
4. Render → View() or ui/
5. Test

## LLM Rules

**CRITICAL**: Follow ALL patterns. No exceptions.

### File Placement
- Types: `types/call_types.go` ONLY
- Text: `config/messages.go` ONLY
- Styles: `config/theme.go` ONLY
- Keys: `config/keys.go` ONLY
- State: `app/model.go` ONLY
- UI: `ui/*.go` (pure functions)

### Patterns
- UI: Pure functions, no state
- State: ALL in Update()
- Async: Use tea.Cmd
- FFI: Validate first, defer cleanup
- Errors: User-friendly via UIError()

### NEVER
- Create helper packages
- Add state to UI
- Hardcode strings/colors
- Mix Update/View logic
- Block Update()
- Skip defer vm.Close()
- Create files outside internal/

### Workflow
1. Check existing patterns
2. Reuse before creating
3. Follow conventions EXACTLY
4. Test all paths

## Build & Run

```bash
# Build EVM
cd ../.. && zig build

# Run CLI
cd apps/cli
go build . && ./guillotine-cli
```

## Dependencies
- bubbletea: TUI framework
- bubbles: Components
- lipgloss: Styling
- guillotine/sdks/go: FFI bindings

*v2.0.0 - Full EVM Integration*