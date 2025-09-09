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
    │   ├── bytecode/         # Bytecode analysis domain
    │   │   ├── bytecode.go   # Bytecode analysis using Go SDK bindings
    │   │   └── bytecode_test.go # Bytecode analysis tests
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
    │   ├── disassembly.go    # Disassembly types (DisassemblyResult, Instructions, etc.)
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
        ├── bytecode_disassembly.go # Bytecode disassembly rendering
        ├── split_panel.go   # Split panel layout for contract details
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
- Disassembly state (result, current block index, instructions table)
- Domain managers (vmManager, historyManager)
- Table components (historyTable, contractsTable, instructionsTable)

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

**Bytecode Domain** (`core/bytecode/`)
- Bytecode analysis via Go SDK bindings (`github.com/evmts/guillotine/sdks/go/bytecode`)
- Instruction extraction with metadata (PC, gas, stack I/O)
- Basic block identification via SDK Analysis
- Jump destination tracking and validation
- Push value extraction and decimal conversion
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

## Bytecode Disassembly

### Overview

The CLI provides comprehensive bytecode disassembly capabilities for deployed contracts. When viewing contract details, the interface displays a split-panel view with contract information on the left and interactive bytecode disassembly on the right.

### Disassembly Features

#### Analysis Components
- **Instructions**: Full EVM instruction listing with program counter, opcodes, gas costs
- **Basic Blocks**: Control flow blocks for code structure analysis
- **Jumpdests**: Jump destination identification and highlighting
- **Statistics**: Bytecode size, instruction count, block count, gas analysis

#### Interactive Navigation
- **Block Navigation**: Use left/right arrow keys (←/h, →/l) to navigate between basic blocks
- **Instruction Scrolling**: Use up/down arrow keys (↑/k, ↓/j) to scroll within instruction tables
- **Opcode Highlighting**: Important opcodes (CALL, SSTORE, etc.) are visually highlighted
- **Jump Target Analysis**: Push values targeting jumpdests are automatically identified

### Disassembly Flow

1. **Contract Selection**: Select a deployed contract from the contracts list
2. **Automatic Analysis**: Bytecode is analyzed using Go SDK bindings
3. **Block Navigation**: Navigate between basic blocks to understand control flow
4. **Instruction Details**: View detailed instruction information including:
   - Program Counter (PC) position
   - Opcode name and hex value (from `bytecode.OpcodeName()`)
   - Push values with decimal conversion for small values
   - Gas cost per instruction (from `bytecode.OpcodeInfo()`)
   - Stack input/output effects
   - Jump destination identification

### Integration with Go SDK

The disassembly system uses the Guillotine Go SDK bytecode package:
- **Efficient Analysis**: Native bytecode analysis via `bytecode.Analyze()`
- **Comprehensive Results**: Full instruction metadata, basic blocks, and jump destinations
- **Type Safety**: Strongly typed results with `bytecode.DisassemblyResult` and `bytecode.Analysis`
- **Memory Management**: Automatic cleanup via Go garbage collection

### UI Architecture

#### Split Panel Design
- **Left Panel (40%)**: Contract details (address, deployment time, bytecode size)
- **Right Panel (60%)**: Interactive disassembly table with block navigation
- **Responsive Layout**: Adapts to terminal size with minimum viable dimensions

#### Table Component Integration
- **Scrollable Instructions**: Large bytecode handled via paginated table view
- **Contextual Highlighting**: Jumpdests, important opcodes, and jump targets emphasized
- **Real-time Updates**: Smooth navigation between blocks with instant table updates

## Bytecode Analysis Navigation

Bytecode analysis components are organized as follows:

```bash
# Core bytecode analysis implementation
cat apps/cli/internal/core/bytecode/bytecode.go

# UI rendering for disassembly
cat apps/cli/internal/ui/bytecode_disassembly.go

# Integration in app handlers
grep -n "bytecode\|disassembly" apps/cli/internal/app/*.go

# SDK bytecode package usage
grep -n "github.com/evmts/guillotine/sdks/go/bytecode" apps/cli/internal/core/bytecode/*.go
```

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

#### 5. Working with Disassembly Types
When working with bytecode disassembly:
```go
// core/bytecode/bytecode.go - Types and business logic
type Instruction struct {
    PC              uint64
    OpcodeHex       uint8
    OpcodeName      string
    PushValue       *string
    PushValueDecimal *uint64
    GasCost         *uint64
    StackInputs     *uint8
    StackOutputs    *uint8
    // ... other fields
}

type DisassemblyResult struct {
    Instructions []Instruction
    Analysis     *bytecode.Analysis  // From SDK
    // ... other fields
}

func AnalyzeBytecode(bc *bytecode.Bytecode) (*DisassemblyResult, error) {
    // Uses SDK bindings, no UI concerns
}

// ui/bytecode_disassembly.go - Pure rendering
func RenderBytecodeDisassembly(result *bytecode.DisassemblyResult) string {
    // Pure rendering function, no state
}
```

### File Placement Rules

```yaml
MUST place code in correct location:
  Type definitions: types/*.go (call.go, disassembly.go, errors.go)
  Error types: types/errors.go
  Business logic: core/<domain>/*.go (evm/, bytecode/, history/, state/)
  State management: app/*.go
  Pure rendering: ui/*.go (bytecode_disassembly.go, split_panel.go)
  Configuration: config/*.go (keys.go with navigation bindings)
  
NEVER:
  Put methods on type structs
  Mix UI with business logic
  Create circular dependencies
  Put logic in config files
  Add state to UI components
  Put SDK calls in UI components (belongs in core/bytecode/)
  Mix bytecode analysis with rendering logic
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

// core/bytecode/bytecode_test.go
func TestAnalyzeBytecode(t *testing.T) {
    bc := []byte{0x60, 0x01, 0x60, 0x02, 0x01} // PUSH1 1 PUSH1 2 ADD
    result, err := AnalyzeBytecodeFromBytes(bc)
    // Test instruction parsing, gas calculation, block identification
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

// Test disassembly integration
func TestDisassemblyStateTransitions(t *testing.T) {
    // Test navigation between blocks, table updates, async loading
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
- Bytecode analysis: 5-50ms via SDK bindings
- UI updates: 60 FPS via Bubbletea
- View() rendering: Keep under 16ms
- Async commands: Any operation >50ms (includes disassembly loading)
- State persistence: Non-blocking background saves
- Table scrolling: Efficient with large instruction sets via virtualized display
- Block navigation: Instant switching with SDK's pre-analyzed BasicBlocks

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

### Disassembly Navigation Keys
Standard navigation keys for bytecode disassembly:
```go
// Basic navigation
KeyLeft      = []string{"left", "h"}   // Navigate to previous block
KeyRight     = []string{"right", "l"}  // Navigate to next block
KeyUp        = []string{"up", "k"}     // Scroll up in instructions
KeyDown      = []string{"down", "j"}   // Scroll down in instructions
```

### Adding Disassembly Features
To extend disassembly functionality:

1. **New Analysis Function** (`core/bytecode/bytecode.go`):
```go
func AnalyzeJumpPattern(result *DisassemblyResult) map[uint64][]uint64 {
    // Pure business logic for jump pattern analysis
}

func GetInstructionsForBlock(dr *DisassemblyResult, blockIndex int) ([]Instruction, string, error) {
    // Extract instructions for a specific basic block
}
```

2. **Enhanced SDK Integration** (`core/bytecode/bytecode.go`):
```go
// Leverage SDK's Analysis type
type DisassemblyResult struct {
    Instructions []Instruction
    Analysis     *bytecode.Analysis  // SDK provides BasicBlocks, JumpDests
    // ... custom fields
}
```

3. **UI Enhancement** (`ui/bytecode_disassembly.go`):
```go
func RenderBytecodeDisassemblyWithNavigation(data DisassemblyDisplayData) string {
    // Pure rendering with block navigation support
}

func ConvertInstructionsToRows(instructions []bytecode.Instruction, jumpdests []uint32) []table.Row {
    // Convert instructions to table rows for display
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
