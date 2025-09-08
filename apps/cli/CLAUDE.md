# Guillotine CLI Documentation

## Architecture Overview

The Guillotine CLI is a terminal user interface (TUI) application built with Go and the Bubbletea framework. It follows a Model-View-Update (MVU) architecture pattern with strict separation of concerns.

## Directory Structure

```
apps/cli/
├── main.go                 # Entry point - initializes and runs the Bubbletea program
├── go.mod                  # Go module definition (module: guillotine-cli)
├── go.sum                  # Dependency lock file
└── internal/               # Internal packages (Go convention - not externally importable)
    ├── config/            # Configuration, constants, and styling
    │   ├── keys.go       # Key bindings and keyboard shortcuts
    │   ├── messages.go   # All UI text strings (titles, labels, messages)
    │   └── theme.go      # Colors, styles, and visual theming
    ├── app/              # Application logic and state management
    │   └── model.go      # Bubbletea Model: state, Init(), Update(), View()
    └── ui/               # Reusable UI components
        ├── header.go     # Title and subtitle rendering
        ├── menu.go       # Menu item rendering with selection state
        ├── help.go       # Help text generation from key bindings
        └── layout.go     # Layout composition, spacing, and centering
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

- **Update** (`model.Update()`): Handles events and state changes
  - Processes keyboard input
  - Updates cursor position
  - Manages window resizing
  - Triggers exit sequences

- **View** (`model.View()`): Renders UI based on current state
  - Composes UI components
  - Applies layout and styling
  - Returns string for terminal display

### 2. Package Responsibilities

#### `internal/config/`
Central configuration hub for all constants and settings:
- **keys.go**: Keyboard bindings, help text generation
- **messages.go**: All user-facing text strings
- **theme.go**: Color palette, text styles, box styles

#### `internal/app/`
Application logic and state management:
- **model.go**: Core application logic, state transitions, main render function

#### `internal/ui/`
Reusable UI components that are pure functions:
- Each component takes data and returns formatted strings
- No state management within UI components
- Composable and testable

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
- **github.com/charmbracelet/lipgloss**: Terminal styling

### Update Dependencies
```bash
go mod tidy  # Clean up unused dependencies
go get -u    # Update all dependencies
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
| `config/keys.go` | Key bindings | Adding new shortcuts or changing existing |
| `config/messages.go` | UI text | Changing any displayed text |
| `config/theme.go` | Visual styling | Adjusting colors, borders, padding |
| `app/model.go` | Core logic | Adding features, handling events |
| `ui/layout.go` | Spacing/positioning | Adjusting element placement |
| `ui/menu.go` | Menu rendering | Changing menu appearance |
| `ui/header.go` | Title rendering | Modifying header display |
| `ui/help.go` | Help text | Changing help display format |

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
5. **Single Source of Truth**: ALL strings in messages.go, ALL colors in theme.go, ALL keys in keys.go

### File Placement Rules
```yaml
MUST place code in correct location:
  User text: internal/config/messages.go ONLY
  Colors/styles: internal/config/theme.go ONLY
  Key bindings: internal/config/keys.go ONLY
  State/logic: internal/app/model.go ONLY
  UI rendering: internal/ui/*.go (pure functions)
  NEVER: Create new packages without being able to justify it with strong confidence
  NEVER: Mix concerns across packages
```

### Code Patterns to Follow
```yaml
UI Components:
  - Take data as parameters, return strings
  - NO side effects, NO state management
  - Use existing styles from theme.go
  - Compose using lipgloss methods

State Management:
  - ALL state changes in Update() method
  - Use existing Model fields before adding new
  - Handle ALL keyboard events explicitly
  - Always update dimensions on WindowSizeMsg

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
  - Opcodes: Use handler pattern (handlers_*.go)
  - UI text: Check messages.go FIRST
  - Styles: Check theme.go FIRST
  - State: Check Model struct in model.go
  - Rendering: Check ui/ components

Before creating:
  - Search for similar existing code
  - Check if pattern already exists
  - Reuse before recreating
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

---

*This documentation should be updated whenever significant architectural changes are made to the CLI.*