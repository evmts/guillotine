# Guillotine Applications

This directory contains standalone applications built on top of the Guillotine EVM implementation. These applications demonstrate practical usage of Guillotine and provide useful tools for EVM development and testing.

## Overview

The applications in this directory are separate from the core Zig EVM implementation and may use different programming languages and build systems. Each application leverages Guillotine through its SDK bindings to provide specialized functionality.

## Applications

### CLI (`cli/`)

A comprehensive command-line interface and benchmarking tool built in Go that provides multiple ways to interact with the Guillotine EVM.

**Features:**
- **Interactive TUI**: Terminal user interface using Bubble Tea for exploring EVM functionality
- **Bytecode Execution**: Execute EVM bytecode directly with customizable gas limits and input data
- **Contract Deployment**: Deploy and execute constructor bytecode, then call the deployed contract
- **Execution Tracing**: Generate JSON-RPC compatible execution traces for debugging
- **Solidity Compilation**: Compile Solidity source code with configurable optimization settings
- **Performance Benchmarking**: Measure execution time and gas consumption

**Key Components:**
- **TUI Interface**: Interactive terminal interface for EVM exploration
- **Command System**: Comprehensive CLI commands for various EVM operations  
- **Solidity Compiler Integration**: Built-in compiler for .sol files
- **Tracing Support**: Full execution trace generation for debugging
- **Go SDK Integration**: Uses the Guillotine Go SDK for EVM operations

## Architecture

### Design Philosophy

Each application is designed to be:
- **Standalone**: Independent build systems and dependencies
- **SDK-based**: Utilizes appropriate Guillotine SDK (Go, Rust, Python, etc.)
- **Purpose-built**: Focused on specific use cases and workflows
- **Production-ready**: Suitable for real-world EVM development tasks

### Integration with Guillotine Core

Applications connect to the core Guillotine EVM through:
1. **SDK Bindings**: Language-specific bindings in `/sdks/`
2. **CGO Interface**: Direct C API access for performance-critical operations
3. **Shared Libraries**: Dynamic linking to compiled Guillotine libraries

## Getting Started

### Prerequisites

- **Core Guillotine**: Must be built successfully (`zig build`)
- **Language Runtimes**: Specific to each application (Go, Node.js, Python, etc.)
- **SDK Dependencies**: Relevant SDK must be available in `/sdks/`

### Building Applications

Each application has its own build system:

```bash
# CLI (Go)
cd apps/cli
go build -o guillotine-cli
./guillotine-cli --help

# Run interactive TUI
./guillotine-cli tui

# Execute bytecode
./guillotine-cli run --codefile bytecode.hex --gas 1000000

# Compile Solidity
./guillotine-cli compile --source "contract Example { function test() public {} }"

# Generate execution trace
./guillotine-cli trace --bytecode runtime.hex --calldata input.hex --out trace.json
```

## Use Cases

### Development Workflow

1. **Contract Development**: Use the CLI to compile Solidity and test execution
2. **Debugging**: Generate execution traces to understand contract behavior
3. **Performance Testing**: Benchmark gas usage and execution time
4. **Integration Testing**: Execute complex contract interactions

### Educational Purposes

- **EVM Learning**: Interactive exploration of EVM opcodes and execution
- **Gas Optimization**: Analyze gas consumption patterns
- **Bytecode Analysis**: Understand compiled contract behavior

### Production Tools

- **CI/CD Integration**: Automated contract testing and validation
- **Deployment Scripts**: Contract deployment with verification
- **Performance Monitoring**: Execution time and gas usage tracking

## Development

### Adding New Applications

To add a new application:

1. **Create Directory**: `mkdir apps/your-app`
2. **Choose SDK**: Select appropriate SDK from `/sdks/`
3. **Implement Core Logic**: Build application using chosen language/framework
4. **Add Documentation**: Create README.md with usage instructions
5. **Update Main README**: Add entry to this file

### Testing Applications

Each application should include:
- **Unit Tests**: Test individual components
- **Integration Tests**: Test EVM interaction
- **End-to-End Tests**: Test complete workflows
- **Performance Tests**: Benchmark execution

### Dependencies

Applications depend on:
- **Guillotine Core**: Must be built and available
- **SDK Bindings**: Language-specific Guillotine bindings
- **Runtime Dependencies**: Language-specific packages and libraries

## Related Documentation

- **Core EVM**: `/src/README.md` - Core Zig EVM implementation
- **SDK Documentation**: `/sdks/README.md` - Language bindings overview
- **Individual SDKs**: `/sdks/{language}/README.md` - Specific SDK documentation
- **Build System**: `/build.zig` - Core build configuration

## Contributing

### Guidelines

1. **Follow Language Conventions**: Use idiomatic patterns for chosen language
2. **SDK Integration**: Properly utilize Guillotine SDK bindings
3. **Documentation**: Comprehensive README.md for each application
4. **Testing**: Include adequate test coverage
5. **Performance**: Consider execution time and resource usage

### Application Standards

- **Error Handling**: Comprehensive error reporting and recovery
- **Configuration**: Support for configuration files and environment variables
- **Logging**: Structured logging with appropriate levels
- **Security**: Proper input validation and secure defaults
- **Usability**: Clear help text and intuitive interfaces

## Troubleshooting

### Common Issues

**Build Failures:**
- Ensure Guillotine core is built successfully
- Check that required SDK is available and up-to-date
- Verify language runtime version compatibility

**Runtime Errors:**
- Check that Guillotine shared libraries are accessible
- Verify input data format (hex encoding, gas limits, etc.)
- Ensure sufficient system resources for execution

**Performance Issues:**
- Use appropriate gas limits for complex operations
- Consider bytecode optimization for expensive computations
- Monitor memory usage for large contract executions

### Getting Help

- **Issues**: Report problems in the main Guillotine repository
- **Discussions**: Use GitHub Discussions for questions and ideas
- **Documentation**: Check individual application README files
- **Examples**: Reference test files and example usage

## Future Applications

Potential future applications may include:

- **Web Interface**: Browser-based EVM explorer and debugger
- **IDE Plugin**: Integration with popular development environments
- **Blockchain Node**: Full Ethereum node implementation using Guillotine
- **Fuzzing Tools**: Automated contract testing and vulnerability detection
- **Analytics Platform**: Contract execution analysis and metrics