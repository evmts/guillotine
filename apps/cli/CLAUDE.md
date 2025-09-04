# Guillotine CLI

## Overview

The Guillotine CLI is a terminal user interface (TUI) application for interacting with the Guillotine EVM implementation. Built with Go and the Bubbletea framework, it follows domain-driven design with clear separation between application orchestration, business logic, and presentation layers.

## Architecture

### Domain-Driven Design Structure

```
apps/cli/
├── main.go                    # Entry point - initializes and runs the Bubbletea program
├── go.mod                     # Go module definition (module: guillotine-cli)
├── go.sum                     # Dependency lock file
├── poc_test.go                # Proof-of-concept tests for EVM call functionality
└── internal/                  # Internal packages (not externally importable)
    ├── app/                   # Application orchestration layer (MVU pattern)
    │   ├── app.go            # Application initialization (InitialModel, Init)
    │   ├── model.go          # Model struct definition (state only)
    │   ├── update.go         # Update method (event handling & state changes)
    │   ├── view.go           # View method (rendering logic)
    │   ├── navigation.go     # State-based navigation handling
    │   ├── handlers.go       # Command handlers and business logic
    │   ├── call_parameters.go # Call parameter management functions
    │   ├── table_updates.go  # Table state management
    │   └── clipboard.go      # Clipboard operations
    │
    ├── core/                  # Business logic organized by domain
    │   ├── evm/              # EVM domain (call execution & validation)
    │   │   ├── executor.go   # EVM call execution logic
    │   │   ├── validator.go  # Call parameter validation
    │   │   ├── converter.go  # Type conversions for EVM
    │   │   ├── vm_manager.go # VM lifecycle management
    │   │   └── parsers.go    # Address and hex data parsing
    │   │
    │   ├── history/          # History domain
    │   │   ├── manager.go    # Call history management
    │   │   ├── entry.go      # History entry types
    │   │   └── contract.go   # Contract tracking
    │   │
    │   └── state/            # State persistence domain
    │       ├── persistence.go # State save/load operations
    │       └── replay.go     # State replay on startup
    │
    ├── types/                 # Type definitions and data structures
    │   ├── call.go           # Core types (AppState, CallParameters, etc.)
    │   └── errors.go         # Error types and definitions
    │
    ├── config/               # Configuration and constants
    │   ├── keys.go          # Key bindings and shortcuts
    │   ├── messages.go      # UI text strings and labels
    │   ├── theme.go         # Colors, styles, and visual theming
    │   ├── call_defaults.go # Default values for EVM calls
    │   └── help.go          # Help text configuration
    │
    └── ui/                   # Pure rendering functions (no state)
        ├── header.go        # Title and subtitle rendering
        ├── menu.go          # Menu item rendering
        ├── help.go          # Help text rendering
        ├── layout.go        # Layout composition and spacing
        ├── call_input.go    # Input field rendering
        ├── call_list.go     # Parameter list display
        ├── call_result.go   # Result display formatting
        ├── history_list.go  # History table rendering
        ├── contract_list.go # Contract table rendering
        ├── clipboard_manager.go # Clipboard utilities
        └── table_factory.go # Table creation helpers
```

## MVU Pattern

### Model-View-Update (MVU) Pattern

The application follows Bubbletea's MVU pattern with strict separation of concerns:

#### Model (`app/model.go`)
Pure state container with no methods:
- Application state (greeting, cursor, choices, quitting)
- UI state (width, height, selected items)
- Call state (parameters, validation errors, results)
- Domain managers (vmManager, historyManager)
- Table components (historyTable, contractsTable)

#### Update (`app/update.go`)
Handles all events and state changes:
- Processes keyboard input
- Manages state transitions
- Orchestrates business logic
- Returns commands for async operations

#### View (`app/view.go`)
Pure rendering function:
- Delegates to UI components
- No state modifications
- Returns formatted strings for display

### Application States

```go
type AppState int

const (
    StateMainMenu           // Main menu selection
    StateCallParameterList  // Parameter list for editing
    StateCallParameterEdit  // Editing a parameter
    StateCallTypeEdit      // Selecting call type
    StateCallExecuting     // Async call in progress
    StateCallResult        // Displaying results
    StateCallHistory       // Browsing history
    StateCallHistoryDetail // Viewing history entry
    StateContracts         // Contract list
    StateContractDetail    // Contract details
    StateConfirmReset      // Reset confirmation
)
```

### Domain Separation

#### Application Layer (`internal/app/`)
- **Orchestration**: Coordinates between domains
- **Event Handling**: User input and system events
- **State Management**: Application-wide state
- **Command Creation**: Async operations
- **No business logic**: Delegates to core domains

#### Core Business Logic (`internal/core/`)
Each domain is self-contained with clear responsibilities:

**EVM Domain** (`core/evm/`)
- Call execution and validation
- Type conversions for FFI
- VM lifecycle management
- Address and data parsing
- No UI concerns

**History Domain** (`core/history/`)
- Call history tracking
- Contract management
- Rotation policies
- No persistence logic

**State Domain** (`core/state/`)
- Persistence operations
- State replay on startup
- File management
- No UI or validation

#### Type Definitions (`internal/types/`)
- Pure data structures only
- No methods or business logic
- Shared across all layers
- Error type definitions

#### Configuration (`internal/config/`)
- Constants and defaults
- Key bindings
- UI strings
- Theme definitions
- No logic or state

#### UI Components (`internal/ui/`)
- Pure rendering functions
- No state management
- No business logic
- Composable components
- Take data, return strings

## EVM Integration

### Call Execution Flow

1. **Parameter Collection**: User inputs via UI
2. **Validation**: `core/evm/validator.go` validates parameters
3. **Type Conversion**: `core/evm/converter.go` converts to Zig types
4. **FFI Bridge**: Parameters sent via CGo bindings
5. **EVM Execution**: Guillotine processes the call
6. **Result Handling**: Convert back to Go types
7. **History Update**: Track in history manager
8. **State Persistence**: Save to disk asynchronously

### Supported Call Types

- `CALL`: Standard message call with value transfer
- `STATICCALL`: Read-only call, no state changes
- `DELEGATECALL`: Execute in caller's context
- `CREATE`: Deploy new contract
- `CREATE2`: Deploy with deterministic address

### Memory Management

- Go manages high-level objects
- Zig handles EVM execution memory
- Proper cleanup via `defer vm.Close()`
- No manual memory management required

## Error Handling

### Error Types (`types/errors.go`)

```go
type InputParamErrorType string

const (
    ErrorInvalidCallerAddress
    ErrorInvalidTargetAddress
    ErrorInvalidGasLimit
    ErrorInvalidValue
    ErrorInvalidInputData
    ErrorInvalidSalt
    ErrorCallTypeRequired
    ErrorUnsupportedCallType
)

type InputParamError struct {
    Type      InputParamErrorType
    ParamName string
    Details   string
}
```

### Error Flow

1. **Validation Errors**: Show inline in UI
2. **Execution Errors**: Display in result screen
3. **System Errors**: Log and show user-friendly message

## Key Design Principles

### 1. Separation of Concerns
- Each package has ONE responsibility
- No cross-cutting concerns
- Clear boundaries between layers

### 2. Pure Functions
- UI components are stateless
- Business logic is testable
- Side effects isolated to app layer

### 3. Domain-Driven Design
- Business logic organized by domain
- Self-contained domains
- Clear aggregate boundaries

### 4. Type Safety
- Strong typing throughout
- Error types for each domain
- Validation at boundaries

### 5. Async Operations
- Non-blocking UI
- Command pattern for I/O
- Graceful error handling

## Development Guidelines

### Adding New Features

#### 1. New Domain Logic
Create in appropriate `core/` subdomain:
```go
// core/newdomain/processor.go
package newdomain

func ProcessSomething(input types.Input) (types.Output, error) {
    // Pure business logic
}
```

#### 2. New UI Component
Create pure function in `ui/`:
```go
// ui/new_component.go
package ui

func RenderNewComponent(data types.Data) string {
    // Pure rendering, no state
}
```

#### 3. New State Field
Add to Model struct:
```go
// app/model.go
type Model struct {
    // existing fields...
    newField types.NewType
}
```

#### 4. New Configuration
Add to appropriate `config/` file:
```go
// config/messages.go
const NewFeatureTitle = "New Feature"

// config/keys.go
var KeyNewAction = []string{"n", "ctrl+n"}

// config/theme.go
var NewStyle = lipgloss.NewStyle().Bold(true)
```

### File Placement Rules

```yaml
MUST place code in correct location:
  Type definitions: types/*.go
  Error types: types/errors.go
  Business logic: core/<domain>/*.go
  State management: app/*.go
  Pure rendering: ui/*.go
  Configuration: config/*.go
  
NEVER:
  Put methods on type structs
  Mix UI with business logic
  Create circular dependencies
  Put logic in config files
  Add state to UI components
```

### Testing Strategy

#### Unit Tests
- Test pure functions in isolation
- Place alongside source files
- Focus on business logic

```go
// core/evm/validator_test.go
func TestValidateCallParameters(t *testing.T) {
    // Test validation logic
}
```

#### Integration Tests
- Test full MVU cycle
- Mock external dependencies
- Verify state transitions

```go
// app/update_test.go
func TestStateTransitions(t *testing.T) {
    // Test Update() behavior
}
```

## Build and Run

### Prerequisites
- Go 1.25+ (generics and improved CGo)
- Zig 0.15+ (Guillotine library)
- CGo enabled
- Dynamic library: `libguillotine.dylib` (macOS) or `.so` (Linux)

### Commands
```bash
# Build Guillotine library
cd ../..
zig build

# Build CLI
cd src/cli
go build -o guillotine-cli .

# Run
./guillotine-cli

# Update dependencies
go mod tidy
go get -u
```

## Performance Considerations

- EVM calls: 10-100ms depending on complexity
- UI updates: 60 FPS via Bubbletea
- View() rendering: Keep under 16ms
- Async commands: Any operation >50ms
- State persistence: Non-blocking background saves

## Common Modifications

### Adding Menu Item
1. Add to `config/messages.go`:
```go
const MenuNewFeature = "New Feature"
```

2. Update menu items function:
```go
func GetMenuItems() []string {
    return []string{
        MenuMakeCall,
        MenuNewFeature, // Add here
        MenuExit,
    }
}
```

3. Handle in `app/handlers.go`:
```go
case config.MenuNewFeature:
    // Handle selection
```

### Changing Theme
Edit `config/theme.go`:
```go
// Change colors
Amber = lipgloss.Color("#FCD34D")

// Modify styles
TitleStyle = lipgloss.NewStyle().
    Bold(true).
    Foreground(Background)
```

### Adding Key Binding
Edit `config/keys.go`:
```go
var KeyNewAction = []string{"n", "ctrl+n"}

// Update help
var HelpBindings = []KeyBinding{
    {Key: "n", Description: "new action"},
}
```

## LLM Assistant Instructions

### CRITICAL: Follow These Patterns

1. **Domain-Driven Design**: Respect domain boundaries
2. **Pure Functions**: UI components have no state
3. **Type Safety**: Use types package for all types
4. **Single Responsibility**: One concern per package
5. **No Cross-Cutting**: Keep domains isolated

### Zero Tolerance

- ❌ Methods on type structs (use functions instead)
- ❌ Business logic in UI components
- ❌ State in rendering functions
- ❌ Hardcoded strings (use config)
- ❌ Cross-domain imports
- ❌ Circular dependencies

### Always Remember

- Types are pure data structures
- UI components are pure functions
- Business logic lives in core/
- Orchestration happens in app/
- Configuration is centralized
*Last Updated: January 2025*
