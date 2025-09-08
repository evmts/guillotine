# CLI App

Application model and orchestration for the Bubble Tea demo.

## Components

- `model.go` — TUI model/state, update/view functions

## Key Features

### Data Models
The application defines structured data models for:

- **EVM Execution Context** - Parameters and state for EVM operations
- **Transaction Data** - Ethereum transaction representation and metadata
- **Debug Information** - Execution traces, state changes, and performance metrics
- **Configuration Models** - Typed configuration structures with validation
- **Result Types** - Standardized response formats for different operations

### Business Logic

#### Command Orchestration
- Coordinates between different CLI commands and their implementations
- Manages the lifecycle of EVM operations from initialization to cleanup
- Handles error propagation and recovery strategies

#### Data Validation
- Input validation for transaction data, addresses, and bytecode
- Configuration validation with meaningful error messages
- Runtime validation of EVM state and execution parameters

#### State Management
- Manages application state across command execution
- Handles concurrent operations and resource sharing
- Provides consistent state snapshots for debugging and analysis

## Architecture

Model‑driven Bubble Tea design:
- State as Go structs
- Pure update/view functions

### Error Handling Strategy
```go
type AppError struct {
    Code    ErrorCode
    Message string
    Cause   error
    Context map[string]interface{}
}
```

### Service Layer Pattern
The app package provides services that:
- Abstract complex operations into simple interfaces
- Handle cross-cutting concerns like logging and metrics
- Provide consistent error handling and recovery

## Usage Patterns

The demo wires a simple Bubble Tea program in `apps/cli/main.go`; `internal/app` owns the tea.Model.

## Integration Points

The app package integrates with:

1. **CLI Framework** - Command parsing and routing
2. **Configuration System** - Loading and validating settings
3. **EVM Core** - Executing EVM operations via CGO bindings
4. **UI Components** - Presenting results and progress to users
5. **External APIs** - Fetching blockchain data and submitting transactions

## Development Guidelines

### Model Definition
- Use explicit field tags for JSON serialization
- Include validation tags for automated input checking
- Document all public fields with clear descriptions
- Use appropriate Go types (e.g., `*big.Int` for large numbers)

### Error Handling
- Create specific error types for different failure modes
- Include sufficient context for debugging
- Use error wrapping to preserve the error chain
- Provide user-friendly error messages

### Testing
- Write comprehensive unit tests for all business logic
- Use table-driven tests for validation functions
- Mock external dependencies for isolated testing
- Include integration tests for complete workflows

## Performance Considerations

- Lazy loading of expensive resources
- Connection pooling for external API calls
- Efficient memory management for large datasets
- Caching strategies for frequently accessed data

## Security Notes

- Sanitize all user inputs before processing
- Validate cryptographic parameters and signatures
- Handle sensitive data (private keys, secrets) securely
- Implement proper access controls and audit logging
