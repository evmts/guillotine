# GuillotineEVM Go SDK - Design Document

## Overview

This document outlines the design for a comprehensive Go SDK that wraps the GuillotineEVM C API. The SDK follows Go idioms and provides an ergonomic interface to the high-performance EVM implementation.

## Design Principles

1. **Ergonomic Go API**: Use Go conventions and patterns
2. **Safety**: Memory-safe with automatic cleanup
3. **Performance**: Minimal overhead over C API
4. **Real Implementation**: No stubs, mocks, or placeholders
5. **Comprehensive**: Cover all C API functionality

## Package Structure

```
github.com/evmts/guillotine/bindings/go/
├── primitives/          # Ethereum primitive types (existing)
├── evm/                 # Main EVM execution (existing, needs update)
├── plan/                # Bytecode analysis and execution plans
├── planner/             # Bytecode optimization and caching  
├── precompiles/         # Ethereum precompiled contracts
├── bytecode/            # Bytecode parsing and validation
├── hardfork/            # Ethereum hardfork management
└── stack/               # EVM stack operations
```

## Available C APIs

Based on root_c.zig, the following C API modules are available:
- `frame_c.zig` - Frame execution context and operations
- `bytecode_c.zig` - Bytecode analysis and validation
- `memory_c.zig` - EVM memory operations
- `stack_c.zig` - EVM stack operations
- `plan_c.zig` - Execution plan analysis
- `planner_c.zig` - Bytecode optimization and caching
- `precompiles_c.zig` - Precompiled contracts
- `hardfork_c.zig` - Hardfork management

## Implementation Strategy

1. **Test-Driven Development**: Write tests first, then implement
2. **Real C Integration**: Use actual C API calls with CGO
3. **Error Handling**: Proper Go error handling with typed errors
4. **Resource Management**: Use finalizers and explicit Close methods
5. **Concurrency Safe**: All types safe for concurrent use

## Package Implementation Order

1. **Stack** - Fundamental EVM stack operations
2. **Bytecode** - Bytecode parsing and analysis
3. **Hardfork** - Hardfork management and feature detection
4. **Plan** - Execution plan analysis
5. **Planner** - Bytecode optimization
6. **Precompiles** - Precompiled contracts

Each package will:
- Follow TDD methodology
- Have comprehensive test coverage
- Use real C API integration
- Provide ergonomic Go interfaces
- Handle errors properly
- Manage resources safely