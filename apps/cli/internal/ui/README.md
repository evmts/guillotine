# CLI UI - CLI User Interface Components

## Overview

This directory contains the user interface components for the Guillotine CLI. It provides reusable UI elements, layout management, and display formatting to create a consistent and user-friendly command-line experience.

## Components

### Core Files
- **`header.go`** - Application header and branding components
- **`help.go`** - Help system and documentation display
- **`layout.go`** - Layout management and responsive design
- **`menu.go`** - Interactive menu systems and navigation

## Key Features

### UI Component Library
The UI system provides a comprehensive set of reusable components:

#### Header Components
- Application branding and version display
- Status indicators and connection state
- Navigation breadcrumbs and context information
- Progress indicators for long-running operations

#### Layout System
- Responsive layouts that adapt to terminal size
- Grid and column-based display systems
- Dynamic content sizing and wrapping
- Split-pane views for multi-panel interfaces

#### Interactive Elements
- Menu systems with keyboard navigation
- Input forms with validation and auto-completion
- Progress bars and status displays
- Confirmation dialogs and user prompts

#### Help System
- Context-sensitive help display
- Command documentation and examples
- Interactive tutorials and guided workflows
- Error explanations and troubleshooting guides

## Architecture

### Component-Based Design
```go
type Component interface {
    Render(ctx RenderContext) error
    HandleInput(event InputEvent) error
    GetBounds() Rectangle
    SetBounds(bounds Rectangle)
}
```

### Theme Integration
All UI components integrate with the theming system:
- Color scheme application
- Font and styling customization
- Accessibility features (high contrast, screen readers)
- Terminal capability detection

### Event System
```go
type InputEvent struct {
    Type     EventType
    Key      KeyPress
    Mouse    MouseEvent
    Terminal TerminalEvent
}
```

## Layout System

### Responsive Design
The layout system adapts to different terminal sizes:
- **Wide terminals** (>120 columns) - Full multi-column layouts
- **Standard terminals** (80-120 columns) - Optimized two-column layouts
- **Narrow terminals** (<80 columns) - Single-column stacked layouts

### Layout Components
- **HeaderLayout** - Application header with status and navigation
- **MainLayout** - Primary content area with optional sidebars
- **FooterLayout** - Status bar and action prompts
- **ModalLayout** - Overlay dialogs and popups

## Menu System

### Navigation Patterns
```go
type Menu struct {
    Items       []MenuItem
    Selected    int
    Multi       bool
    Searchable  bool
    Paginated   bool
}
```

### Menu Types
- **Command menus** - List of available commands and actions
- **Selection menus** - Choose from a list of options
- **Multi-select menus** - Select multiple items from a list
- **Hierarchical menus** - Nested menu structures with navigation

### Keyboard Shortcuts
- **Arrow keys** - Navigate menu items
- **Enter** - Select current item
- **Space** - Toggle selection (multi-select)
- **Tab** - Navigate between UI sections
- **Escape** - Cancel or go back

## Help System

### Documentation Structure
```go
type HelpContent struct {
    Title       string
    Description string
    Usage       string
    Examples    []Example
    SeeAlso     []string
}
```

### Help Features
- **Command help** - Detailed usage information for each command
- **Interactive help** - Step-by-step guidance for complex operations
- **Context help** - Relevant help based on current application state
- **Error help** - Specific guidance when errors occur

## Display Formatting

### Output Formats
- **Table format** - Structured data in columns
- **JSON format** - Machine-readable output
- **Tree format** - Hierarchical data display
- **Graph format** - Visual representation of relationships

### Data Visualization
- **Execution traces** - Step-by-step EVM execution display
- **State diffs** - Before/after state comparisons
- **Gas usage** - Visual gas consumption analysis
- **Performance metrics** - Timing and resource usage charts

## Usage Patterns

### Creating UI Components
```go
func NewExecutionDisplay(trace ExecutionTrace) *ExecutionDisplay {
    return &ExecutionDisplay{
        trace:  trace,
        layout: NewTableLayout(),
        theme:  GetCurrentTheme(),
    }
}
```

### Handling User Input
```go
func (d *ExecutionDisplay) HandleInput(event InputEvent) error {
    switch event.Type {
    case KeyPress:
        return d.handleKeyPress(event.Key)
    case Mouse:
        return d.handleMouse(event.Mouse)
    default:
        return nil
    }
}
```

## Integration Points

The UI system integrates with:
- **Configuration system** - Theme and display preferences
- **Application logic** - Data models and business operations
- **Terminal libraries** - Low-level terminal control
- **Event system** - User input and application events

## Development Guidelines

### Component Development
- Follow the Component interface for all UI elements
- Implement proper bounds checking and clipping
- Handle terminal resize events gracefully
- Provide keyboard accessibility for all interactions

### Theme Compatibility
- Use theme colors instead of hardcoded values
- Support both light and dark themes
- Test with different terminal types and capabilities
- Provide fallbacks for terminals without color support

### Error Handling
- Display user-friendly error messages
- Provide recovery options when possible
- Include help links for common error scenarios
- Log detailed error information for debugging

### Testing
- Unit tests for individual components
- Integration tests for complete UI flows
- Manual testing on different terminal types
- Accessibility testing with screen readers

## Accessibility Features

- Screen reader compatibility
- High contrast mode support
- Keyboard-only navigation
- Customizable key bindings
- Large text options for visually impaired users