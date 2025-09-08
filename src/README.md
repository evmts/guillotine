# Guillotine Source Code

Core implementation of the Guillotine EVM (Ethereum Virtual Machine) in Zig.

## Directory Structure

### Core EVM Components
- **frame/** - Execution frame management for EVM operations
- **instructions/** - EVM instruction/opcode implementations
- **memory/** - EVM memory management and operations
- **stack/** - EVM stack implementation and operations
- **storage/** - Persistent storage handling for contracts

### Blockchain Components
- **block/** - Block structure and validation logic
- **trie/** - Merkle Patricia Trie implementation for state storage
- **primitives/** - Basic types and constants used throughout the codebase

### Cryptography & Precompiles
- **crypto/** - Cryptographic utilities and implementations
- **precompiles/** - EVM precompiled contracts (ecrecover, sha256, etc.)
- **kzg/** - KZG commitment scheme implementation

### Transaction Processing
- **bytecode/** - Bytecode parsing, validation, and analysis
- **opcodes/** - Opcode definitions and metadata
- **preprocessor/** - Bytecode preprocessing and optimization

### Infrastructure
- **provider/** - External data provider interfaces
- **tracer/** - Transaction and execution tracing utilities
- **eips_and_hardforks/** - EIP implementations and hardfork configurations

### Development Tools
- **cli/** - Command-line interface for interacting with Guillotine
- **devtool/** - Development and debugging tools
- **solidity/** - Solidity compilation and deployment utilities

### Testing
- **_test_utils/** - Testing utilities and fixtures

## Build System

All modules are integrated through Zig's build system. Use `zig build` to compile and `zig build test` to run tests.

## Key Design Principles

1. **Memory Safety** - Careful memory management with explicit ownership
2. **Performance** - Cache-conscious data structures and minimal allocations
3. **Correctness** - Strong typing and comprehensive testing
4. **Modularity** - Clear separation of concerns between components