# CLI Internal

Internal packages for the Go CLI demo. Not for external import.

## Components

### Directory Structure
- **`app/`** - Application logic and data models
- **`config/`** - Configuration management and validation
- **`ui/`** - User interface components and layouts

## Architecture

Simple separation of concerns for a small demo:
1. app — model/state and orchestration
2. config — constants and theming
3. ui — views and layout

## Package Responsibilities

### App Package (`app/`)
- Application state management
- Command execution logic
- Data model definitions
- Business rule enforcement

### Config Package (`config/`)
- Configuration file parsing
- Environment variable handling
- Command-line flag processing
- Configuration validation and defaults

### UI Package (`ui/`)
- Terminal user interface components
- Layout management
- Interactive elements
- Display formatting and styling

## Design Principles

### Clean Interfaces
```go
type Service interface {
    Execute(ctx context.Context, request Request) (Response, error)
}
```

### Error Handling
- Structured error types for different failure modes
- Context propagation for cancellation and timeouts
- Graceful degradation when possible

### Configuration Management
- Hierarchical configuration (flags > env > file > defaults)
- Validation at startup to fail fast
- Hot-reload support for development

### User Experience
- Consistent command patterns and help text
- Progress indicators for long-running operations
- Graceful handling of terminal resizing and interrupts

## Integration Points

These internal components integrate with:

1. **Core Guillotine EVM** - Through CGO bindings and C interfaces
2. **External APIs** - Ethereum nodes, block explorers, etc.
3. **File System** - Configuration files, output data, logs
4. **Operating System** - Terminal handling, signal management

## Development Guidelines

- Keep packages focused on a single responsibility
- Use interfaces to define contracts between packages
- Write comprehensive tests for all business logic
- Follow Go conventions for package naming and structure
- Document public APIs with clear examples

## Testing Strategy

- Unit tests for individual components
- Integration tests for package interactions
- End-to-end tests for complete command flows
- Mock external dependencies for reliable testing

## Common Patterns

### Context Usage
All operations accept a `context.Context` for cancellation and timeout handling.

### Error Wrapping
Errors are wrapped with context using `fmt.Errorf` and `%w` verb.

### Logging
Structured logging using a consistent logger interface throughout all packages.

### Configuration
Configuration is loaded once at startup and passed to components that need it.
