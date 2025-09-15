# CLI Module

This module provides the command-line interface for the Guillotine EVM implementation.

## Overview

The CLI module serves as the main entry point for interacting with Guillotine through command-line tools. It provides various utilities for testing, debugging, and running EVM operations from the command line.

## Files

### test_main.zig

A simple test application that demonstrates the CLI module is building correctly.

**Features:**
- Basic CLI application structure
- Output to stdout for verification
- Simple event loop for testing purposes

**Usage:**
```bash
zig build cli
./zig-out/bin/guillotine-cli
```

## Architecture

The CLI module is designed to provide:

1. **EVM Execution Interface**: Run bytecode and transactions from command line
2. **Development Tools**: Debugging and analysis utilities
3. **Testing Framework**: Command-line test runners
4. **Configuration Management**: CLI-based configuration options
5. **Integration Tools**: Interface with other blockchain tools and networks

## Planned Features

The CLI module is designed to support:

### Execution Commands
- `run`: Execute EVM bytecode with specified parameters
- `trace`: Execute with detailed tracing enabled
- `debug`: Interactive debugging session
- `benchmark`: Performance benchmarking utilities

### Analysis Commands
- `analyze`: Static bytecode analysis
- `disassemble`: Disassemble bytecode to human-readable format
- `verify`: Verify bytecode against specifications
- `profile`: Profile execution performance

### Testing Commands
- `test`: Run official Ethereum test vectors
- `fuzz`: Fuzzing test execution
- `differential`: Compare with reference implementations
- `regression`: Regression testing suite

### Utility Commands
- `config`: Manage configuration settings
- `version`: Display version and build information
- `help`: Comprehensive help system

## Integration

The CLI module integrates with:
- All core EVM modules for execution capabilities
- Testing frameworks for validation
- Configuration systems for settings management
- Logging systems for output formatting
- External tools through standard interfaces

## Development

The CLI module follows these principles:

1. **User-Friendly**: Clear, intuitive command structure
2. **Scriptable**: Machine-readable output formats
3. **Extensible**: Plugin architecture for custom commands
4. **Robust**: Comprehensive error handling and validation
5. **Performant**: Efficient execution with minimal overhead