# Guillotine CLI Documentation

## Architecture Overview

The Guillotine CLI is a terminal user interface (TUI) application for interacting with the Guillotine EVM implementation. Built with Go and the Bubbletea framework, it provides an interactive interface for executing EVM calls and testing smart contract interactions. It follows a Model-View-Update (MVU) architecture pattern with strict separation of concerns.

## Directory Structure

```
apps/cli/
├── main.go                 # Entry point - initializes and runs the Bubbletea program
├── go.mod                  # Go module definition (module: guillotine-cli)
├── go.sum                  # Dependency lock file
├── poc_test.go            # Proof-of-concept tests for EVM call functionality
└── internal/               # Internal packages (Go convention - not externally importable)
    ├── types/              # Type definitions and data structures
    │   └── call_types.go  # EVM call parameters, execution results, app states
    ├── config/            # Configuration, constants, and styling
    │   ├── keys.go       # Key bindings and keyboard shortcuts
    │   ├── messages.go   # All UI text strings (titles, labels, messages)
    │   ├── theme.go      # Colors, styles, and visual theming
    │   ├── call_defaults.go # Default values for EVM call parameters
    │   └── errors.go     # Error types and validation error handling
    ├── app/              # Application logic and state management
    │   ├── model.go      # Bubbletea Model: state, Init(), Update(), View()
    │   ├── call_executor.go # EVM call execution and validation logic
    │   └── validation_test.go # Unit tests for validation functions
    └── ui/               # Reusable UI components
        ├── header.go     # Title and subtitle rendering
        ├── menu.go       # Menu item rendering with selection state
        ├── help.go       # Help text generation from key bindings
        ├── layout.go     # Layout composition, spacing, and centering
        ├── call_input.go # Call parameter input field rendering
        └── call_list.go  # Call parameter list display
```

## Core Concepts

### 1. Bubbletea MVU Pattern

The application follows Bubbletea's Model-View-Update pattern:

- **Model** (`app/model.go`): Contains application state
  - `greeting`: Application title
  - `cursor`: Current menu selection index
  - `choices`: Menu items array
  - `selected`: Map tracking selected items
  - `quitting`: Exit state flag
  - `width/height`: Terminal dimensions
  - **Call-related state**:
    - `state`: Current application state (enum: MainMenu, CallParameterList, etc.)
    - `callParams`: EVM call parameters (type, addresses, gas, value, data)
    - `callParamCursor`: Current parameter selection in edit mode
    - `editingParam`: Name of parameter being edited
    - `textInput`: Bubbletea text input model for parameter editing
    - `validationError`: Current validation error message
    - `callResult`: Execution result from EVM call
    - `callTypeSelector`: Index for call type selection

- **Update** (`model.Update()`): Handles events and state changes
  - Processes keyboard input based on current state
  - Updates cursor position for menus and parameter lists
  - Manages state transitions between screens
  - Validates input parameters
  - Executes EVM calls asynchronously
  - Handles window resizing
  - Triggers exit sequences

- **View** (`model.View()`): Renders UI based on current state
  - Composes UI components based on `AppState`
  - Applies layout and styling
  - Shows appropriate screen (menu, parameter list, edit, result)
  - Returns string for terminal display

### 2. Package Responsibilities

#### `internal/types/`
Core type definitions and data structures:
- **call_types.go**: Defines `AppState` enum, `CallParameters`, `CallExecution` result types
- Centralizes all application-specific types
- Provides helper methods for type conversions

#### `internal/config/`
Central configuration hub for all constants and settings:
- **keys.go**: Keyboard bindings, help text generation
- **messages.go**: All user-facing text strings
- **theme.go**: Color palette, text styles, box styles
- **call_defaults.go**: Default values for EVM call parameters, call type mappings
- **errors.go**: Custom error types, validation error handling with user-friendly messages

#### `internal/app/`
Application logic and state management:
- **model.go**: Core application logic, state transitions, main render function
- **call_executor.go**: EVM call execution logic, parameter validation, FFI integration
- **validation_test.go**: Unit tests for input validation functions

#### `internal/ui/`
Reusable UI components that are pure functions:
- Each component takes data and returns formatted strings
- No state management within UI components
- Composable and testable
- **New components**:
  - `call_input.go`: Text input fields for EVM parameters with validation
  - `call_list.go`: Display list of call parameters with navigation

## Application States

### State Flow
The application uses a finite state machine with the following states:
```go
type AppState int

const (
    StateMainMenu           // Initial menu screen
    StateCallParameterList  // List of call parameters to edit
    StateCallParameterEdit  // Editing a specific parameter
    StateCallExecuting      // Async EVM call in progress
    StateCallResult         // Display call execution results
)
```

### State Transitions
```
MainMenu → (Execute Call) → CallParameterList
CallParameterList → (Select) → CallParameterEdit
CallParameterEdit → (Save) → CallParameterList
CallParameterList → (Execute) → CallExecuting → CallResult
CallResult → (Back) → MainMenu
```

## EVM Integration

### Call Execution Flow
1. **Parameter Collection**: User inputs call parameters through UI
2. **Validation**: `call_executor.go` validates all parameters
3. **FFI Bridge**: Parameters converted to Zig types via CGo bindings
4. **EVM Execution**: Guillotine EVM processes the call
5. **Result Handling**: Results converted back to Go types for display

### Supported Call Types
- `CALL`: Standard message call with value transfer
- `STATICCALL`: Read-only call, no state changes
- `DELEGATECALL`: Execute in caller's context
- `CREATE`: Deploy new contract
- `CREATE2`: Deploy with deterministic address

### Validation Rules
```go
// Address validation: 40 hex characters (without 0x prefix)
// Gas limit: Valid uint64
// Value: Valid uint64 in Wei
// Input data: Valid hex string starting with 0x
// Salt: Required for CREATE2, 64 hex characters
```

## Error Handling

### Error Types
1. **Input Validation Errors** (`InputParamError`)
   - Invalid addresses
   - Invalid numeric values
   - Malformed hex data
   - Missing required fields

2. **EVM Execution Errors**
   - Out of gas
   - Revert with reason
   - Invalid opcode
   - Stack overflow/underflow

3. **System Errors**
   - FFI failures
   - Memory allocation
   - Panic recovery

### Error Display Pattern
```go
// Validation errors show inline
if err := ValidateCallParameters(params); err != nil {
    m.validationError = err.UIError() // User-friendly message
}

// Execution errors show in result screen
if result.Status != Success {
    // Display error reason and gas consumed
}
```

## Common Modifications

### Adding a New Menu Item

1. **Add the menu label** in `internal/config/messages.go`:
```go
const (
    MenuNewFeature = "New Feature Name"
)

func GetMenuItems() []string {
    return []string{
        MenuRunTest,
        MenuNewFeature,  // Add here
        MenuExit,
    }
}
```

2. **Handle the selection** in `internal/app/model.go`:
```go
if config.IsKey(msgStr, config.KeySelect) {
    switch m.choices[m.cursor] {
    case config.MenuNewFeature:
        // Handle new feature action
    case config.MenuExit:
        // Existing exit logic
    }
}
```

### Changing Colors/Theme

Edit `internal/config/theme.go`:
```go
// Modify color palette
Amber = lipgloss.Color("#FCD34D")  // Change hex value

// Modify styles
TitleStyle = lipgloss.NewStyle().
    Bold(true).
    Foreground(Background).
    Background(Amber).  // Uses color defined above
    Padding(0, 3)
```

### Modifying Key Bindings

Edit `internal/config/keys.go`:
```go
// Change key combinations
KeyQuit = []string{"ctrl+c", "q", "esc"}  // Add 'esc' as quit key

// Update help text
var HelpBindings = []KeyBinding{
    {Key: "↑/k", Description: "up"},
    {Key: "↓/j", Description: "down"},
    // Add or modify entries
}
```

### Adjusting Layout Spacing

Edit `internal/ui/layout.go`:
```go
// Modify padding calculations in ComposeVertical()
headerHeight := 3     // Lines allocated for header
menuHeight := ...     // Lines for menu
helpHeight := 1       // Lines for help text
availableSpace := l.Height - 6  // Adjust total spacing

// Modify box padding in theme.go
BoxStyle = lipgloss.NewStyle().
    Padding(1, 3)  // (vertical, horizontal) padding
```

## Adding New Features

### 1. New UI Component

Create new file in `internal/ui/`:
```go
// internal/ui/status.go
package ui

import (
    "guillotine-cli/internal/config"
    "github.com/charmbracelet/lipgloss"
)

func RenderStatus(status string) string {
    style := config.GetStatusStyle(status)
    return style.Render(status)
}
```

### 2. New Configuration Type

Add to appropriate file in `internal/config/`:
```go
// For new keys → keys.go
KeyNewAction = []string{"n", "ctrl+n"}

// For new messages → messages.go
const StatusRunning = "Running..."

// For new styles → theme.go
StatusStyle = lipgloss.NewStyle().Foreground(ChartGreen)
```

### 3. New State Field

Add to Model struct in `internal/app/model.go`:
```go
type Model struct {
    // ... existing fields
    newField string  // Add new state field
}

// Initialize in InitialModel()
func InitialModel() Model {
    return Model{
        // ... existing initialization
        newField: "initial value",
    }
}
```

## Code Conventions

### Go Conventions
- **Package names**: Lowercase, single word (`config`, `app`, `ui`)
- **File names**: Lowercase with underscores (`model.go`, `keys.go`)
- **Exported names**: PascalCase (`TitleStyle`, `GetMenuItems`)
- **Internal names**: camelCase (`menuItems`, `spaceBetween`)

### Project-Specific Conventions
- **No redundant package structures**: Don't create `keys/keys.go`, use `config/keys.go`
- **Single source of truth**: All strings in `messages.go`, all colors in `theme.go`
- **Pure UI functions**: UI components don't manage state, only render
- **Explicit constants**: Use named constants instead of magic strings/numbers

### Import Order
```go
import (
    // Standard library
    "fmt"
    "strings"
    
    // Internal packages
    "guillotine-cli/internal/config"
    "guillotine-cli/internal/ui"
    
    // External packages
    tea "github.com/charmbracelet/bubbletea"
    "github.com/charmbracelet/lipgloss"
)
```

## Terminal Modes

The CLI uses Bubbletea's alternate screen mode:
- **EnterAltScreen**: Switches to alternate buffer (preserves terminal history)
- **ExitAltScreen**: Restores original terminal on exit
- **ClearScreen**: Cleans display on startup

## Build and Run

### Build
```bash
cd apps/cli
go build -o guillotine-cli .
```

### Run
```bash
./guillotine-cli
```

### Dependencies
- **github.com/charmbracelet/bubbletea**: TUI framework
- **github.com/charmbracelet/bubbles**: UI components (textinput)
- **github.com/charmbracelet/lipgloss**: Terminal styling
- **github.com/evmts/guillotine/sdks/go**: EVM FFI bindings
  - `/evm`: Main EVM interface
  - `/primitives`: Ethereum types (Address, U256, Bytes)

### Build Requirements
- Go 1.25+ (for type parameters and improved CGo)
- Zig 0.15+ (for building Guillotine library)
- CGo enabled (for FFI bridge to Zig)
- Dynamic library: `libguillotine.dylib` (macOS) or `.so` (Linux)

### Update Dependencies
```bash
go mod tidy  # Clean up unused dependencies
go get -u    # Update all dependencies
```

## Asynchronous Operations

### Command Pattern for Long-Running Tasks
The CLI uses Bubbletea's command pattern for async operations:

```go
// Define a result message type
type callResultMsg struct {
    result *types.CallExecution
    err    error
}

// Create an async command
func executeCallCmd(params types.CallParameters) tea.Cmd {
    return func() tea.Msg {
        result, err := ExecuteCall(params)
        return callResultMsg{result: result, err: err}
    }
}

// Handle the result in Update()
case callResultMsg:
    m.callResult = msg.result
    m.state = types.StateCallResult
```

### Benefits
- Non-blocking UI during EVM execution
- Clean separation of I/O from state updates
- Cancellable operations (future enhancement)

## FFI Integration with Guillotine

### Go Bindings Structure
```
github.com/evmts/guillotine/sdks/go/
├── evm/          # Main EVM interface
├── primitives/   # Ethereum types (Address, U256, Bytes)
└── cgo/          # C bindings to Zig library
```

### Memory Management
- Go manages high-level objects
- Zig handles EVM execution memory
- Proper cleanup via `defer vm.Close()`
- No manual memory management required

### Type Conversions
```go
// Go string → Zig Address
addr, _ := parseAddress("0x1234...")
primitives.NewAddress(addr)

// Go uint64 → Zig U256
value := primitives.NewU256(1000000)

// Hex string → Zig Bytes
data := primitives.NewBytes(hexToBytes("0x6060..."))
```

## Testing Guidelines

### Unit Tests
Place tests alongside source files:
```
internal/config/keys_test.go
internal/ui/menu_test.go
```

### Test UI Components
UI components are pure functions, making them easy to test:
```go
func TestRenderMenuItem(t *testing.T) {
    item := MenuItem{Label: "Test"}
    result := RenderMenuItem(item, true, false)
    // Assert expected output
}
```

### Integration Tests
Test the full Model cycle:
```go
func TestModelUpdate(t *testing.T) {
    m := InitialModel()
    // Send key message
    // Assert state change
}
```

## Troubleshooting

### Common Issues

1. **Terminal compatibility**: Some terminals may not support all colors/styles
   - Solution: Test in different terminals (iTerm2, Terminal.app, etc.)

2. **Key binding conflicts**: System or terminal shortcuts may override
   - Solution: Choose alternative key combinations in `keys.go`

3. **Layout issues**: Content appears cut off or misaligned
   - Solution: Adjust calculations in `layout.go`, check terminal size

4. **Build errors**: Missing dependencies
   - Solution: Run `go mod tidy` then `go build`

## Style Guide Summary

### When to Create New Files
- **New UI component**: Create in `internal/ui/`
- **New config type**: Add to existing file in `internal/config/`
- **New major feature**: Consider new package under `internal/`

### Where Things Belong
- **User-facing text**: `internal/config/messages.go`
- **Colors and styles**: `internal/config/theme.go`
- **Keyboard shortcuts**: `internal/config/keys.go`
- **State management**: `internal/app/model.go`
- **UI rendering**: `internal/ui/*.go`

### Maintaining Consistency
1. Always use constants for strings (no hardcoding)
2. Keep UI components pure (no side effects)
3. Handle all state changes in `Update()`
4. Use existing styles before creating new ones
5. Follow existing patterns in the codebase

## Quick Reference

### Key Files and Their Purpose
| File | Purpose | Modify When |
|------|---------|-------------|
| `main.go` | Entry point | Rarely, only for initialization changes |
| `poc_test.go` | Integration tests | Testing EVM call functionality |
| **Types** | | |
| `types/call_types.go` | Type definitions | Adding new types, states, or structures |
| **Config** | | |
| `config/keys.go` | Key bindings | Adding new shortcuts or changing existing |
| `config/messages.go` | UI text | Changing any displayed text |
| `config/theme.go` | Visual styling | Adjusting colors, borders, padding |
| `config/call_defaults.go` | Default values | Changing EVM call defaults |
| `config/errors.go` | Error handling | Adding new error types |
| **App Logic** | | |
| `app/model.go` | Core logic | Adding features, handling events |
| `app/call_executor.go` | EVM execution | Changing call logic or validation |
| `app/validation_test.go` | Validation tests | Testing input validation |
| **UI Components** | | |
| `ui/layout.go` | Spacing/positioning | Adjusting element placement |
| `ui/menu.go` | Menu rendering | Changing menu appearance |
| `ui/header.go` | Title rendering | Modifying header display |
| `ui/help.go` | Help text | Changing help display format |
| `ui/call_input.go` | Input fields | Modifying parameter input UI |
| `ui/call_list.go` | Parameter list | Changing parameter list display |

### State Flow
1. User presses key → `Update()` receives `tea.KeyMsg`
2. `Update()` modifies `Model` state based on key
3. `View()` called automatically after `Update()`
4. `View()` composes UI from current state
5. Terminal displays rendered string

### Adding Features Checklist
- [ ] Add constants to `config/messages.go`
- [ ] Add key bindings to `config/keys.go` if needed
- [ ] Add styles to `config/theme.go` if needed
- [ ] Add state fields to `Model` struct
- [ ] Handle events in `Update()`
- [ ] Render in `View()` or create UI component
- [ ] Test the feature
- [ ] Update this documentation if needed

## LLM Assistant Instructions

### CRITICAL: Read This First
**AI assistants MUST follow ALL patterns and conventions in this file. No exceptions.**

### Core Principles
1. **Strict MVU Pattern**: State ONLY in Model, updates ONLY in Update(), rendering ONLY in View()
2. **Package Organization**: NEVER create redundant structures (no `keys/keys.go`, use `config/keys.go`)
3. **Separation of Concerns**: Each package has ONE responsibility - NEVER mix concerns
4. **Pure UI Functions**: UI components NEVER manage state, ONLY render
5. **Single Source of Truth**: ALL strings in messages.go, ALL colors in theme.go, ALL keys in keys.go, ALL types in types/
6. **FFI Safety**: ALWAYS use defer for cleanup, validate before calling Zig functions
7. **Error Handling**: User-friendly messages via UIError(), technical details in logs
8. **Async Pattern**: Use tea.Cmd for long operations, NEVER block Update()

### File Placement Rules
```yaml
MUST place code in correct location:
  Type definitions: internal/types/call_types.go ONLY
  User text: internal/config/messages.go ONLY
  Colors/styles: internal/config/theme.go ONLY
  Key bindings: internal/config/keys.go ONLY
  Error types: internal/config/errors.go ONLY
  Default values: internal/config/call_defaults.go ONLY
  State/logic: internal/app/model.go ONLY
  EVM execution: internal/app/call_executor.go ONLY
  UI rendering: internal/ui/*.go (pure functions)
  Tests: Alongside source files (*_test.go)
  NEVER: Create new packages without strong justification
  NEVER: Mix concerns across packages
  NEVER: Put business logic in UI components
```

### Code Patterns to Follow
```yaml
UI Components:
  - Take data as parameters, return strings
  - NO side effects, NO state management
  - Use existing styles from theme.go
  - Compose using lipgloss methods
  - Text inputs via bubbles/textinput

State Management:
  - ALL state changes in Update() method
  - State transitions via AppState enum
  - Use existing Model fields before adding new
  - Handle ALL keyboard events per state
  - Always update dimensions on WindowSizeMsg
  - Async operations return tea.Cmd

EVM Integration:
  - Validate parameters before FFI calls
  - Convert Go types to primitives.* types
  - Use defer for vm.Close()
  - Handle all error cases from Zig
  - Return structured CallExecution results

Validation:
  - Separate validation from execution
  - Return InputParamError with field context
  - Provide user-friendly error messages
  - Check hex format, address length, numeric ranges

Styling:
  - REUSE existing styles before creating new
  - Define colors as constants in theme.go
  - Apply styles consistently across components
  - Use semantic naming (TitleStyle not YellowBox)
```

### Common Mistakes to AVOID
```yaml
DON'T:
  - Create helper packages (use existing structure)
  - Add state to UI components
  - Hardcode strings (use messages.go)
  - Hardcode colors (use theme.go)
  - Skip key binding definitions
  - Mix Update logic with View rendering
  - Create files outside internal/ structure
  - Ignore existing patterns for "better" ones
  - Block Update() with synchronous calls
  - Forget defer vm.Close() after evm.New()
  - Mix validation with execution logic
  - Return technical errors to UI
  - Create new error types without using errors.go
  - Access FFI directly without validation
```

### Adding Features Checklist
```yaml
Before coding:
  1. Identify which packages need changes
  2. Check existing patterns in those packages
  3. Reuse existing constants/styles/components

Implementation order:
  1. Add constants to config/ packages
  2. Add state fields to Model if needed
  3. Handle events in Update()
  4. Create/modify UI components
  5. Compose in View()
  6. Test all paths
  7. Update this documentation if architectural
```

### Navigation & Discovery
```yaml
Finding code:
  - Types: Check types/call_types.go FIRST
  - UI text: Check messages.go FIRST
  - Styles: Check theme.go FIRST
  - State: Check Model struct in model.go
  - Rendering: Check ui/ components
  - Validation: Check call_executor.go
  - Errors: Check errors.go for types
  - Defaults: Check call_defaults.go

EVM call flow:
  1. User selects "Execute Call" from menu
  2. StateCallParameterList shows params
  3. User edits each parameter
  4. Validation runs on save
  5. Execute triggers async call
  6. Result displayed with gas/status

Before creating:
  - Search for similar existing code
  - Check if pattern already exists
  - Reuse before recreating
  - Verify type exists in types/
```

### Testing Requirements
```yaml
UI Components:
  - Test pure functions with various inputs
  - Verify string output format
  - Test edge cases (empty, nil, overflow)

Model Updates:
  - Test state transitions
  - Verify all key handlers
  - Test initialization and cleanup
```

### Import Conventions
```yaml
Order:
  1. Standard library
  2. Internal packages (guillotine-cli/internal/*)
  3. External packages (github.com/*)

Style:
  - Use explicit imports
  - Group by category
  - Maintain consistent ordering
```

### Go Module Boundaries
```yaml
Remember:
  - This is module 'guillotine-cli' (separate from main project)
  - Internal packages can't be imported externally
  - Dependencies are isolated in go.mod
  - Don't import from parent project
```

### Modification Protocol
```yaml
When modifying:
  1. Understand existing pattern FIRST
  2. Follow pattern EXACTLY
  3. Don't "improve" without explicit request
  4. Maintain consistency over optimization
  5. Document only if architectural change

When stuck:
  1. Re-read this documentation
  2. Check existing similar code
  3. Follow established patterns
  4. Ask before breaking conventions
```

### Key Architectural Decisions
```yaml
State Machine:
  - Single AppState enum controls UI flow
  - State determines which View() branch renders
  - Keyboard handling switches per state
  - No nested state machines

FFI Bridge:
  - Go → C → Zig via CGo
  - Primitives package handles type conversion
  - All EVM ops through single vm instance
  - Resource cleanup mandatory

Validation Strategy:
  - Client-side validation before EVM call
  - Separate validation from execution
  - User-friendly error messages
  - Technical details in logs only

Async Execution:
  - tea.Cmd for non-blocking operations
  - Message types for result handling
  - UI remains responsive during calls
  - Error states handled gracefully
```

### Zero Tolerance Violations
```yaml
NEVER:
  - Break MVU pattern separation
  - Create new packages without need
  - Hardcode values (use config/)
  - Add comments explaining obvious code
  - Ignore existing conventions for "cleaner" code
  - Mix state and rendering logic
  - Import from parent project directories
```

## Development Workflow

### Running with EVM
```bash
# Build Guillotine library first
cd ../..
zig build

# Build and run CLI
cd src/cli
go build .
./guillotine-cli
```

### Debugging Tips
1. **EVM Errors**: Check `vm.GetLastError()` for detailed error messages
2. **UI Issues**: Add debug output to `View()` temporarily (remove before commit)
3. **State Problems**: Log state transitions in `Update()`
4. **FFI Crashes**: Verify library path and version compatibility
5. **Input Validation**: Test edge cases with `validation_test.go`

### Performance Considerations
- EVM calls can take 10-100ms depending on complexity
- UI updates at 60 FPS via Bubbletea
- Keep View() rendering under 16ms for smooth UI
- Use async commands for any operation >50ms

---

*This documentation was last updated: January 2025*
*Version: 2.0.0 - Full EVM Integration*
*This documentation should be updated whenever significant architectural changes are made to the CLI.*