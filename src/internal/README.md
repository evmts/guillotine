# Internal Module

This module provides internal utilities and infrastructure components used throughout the Guillotine EVM implementation.

## Overview

The internal module contains low-level utilities, safety mechanisms, and infrastructure code that supports the core EVM functionality. These components are designed to provide reliable, secure, and performant building blocks for the EVM implementation.

## Files

### safety_counter.zig

A configurable safety counter utility that provides runtime protection against infinite loops, excessive iterations, and resource exhaustion attacks.

**Key Features:**
- Generic counter type supporting various integer types (u32, u64, usize)
- Compile-time enable/disable modes for zero-cost abstraction in production
- Automatic panic on limit exceeded to prevent DoS attacks
- Platform-aware handling (different behavior on WASM vs native)

**Usage:**
```zig
const Counter = SafetyCounter(u32, .enabled);
var counter = Counter.init(1000); // Limit of 1000 iterations

// In a loop or recursive function
counter.inc(); // Increment and check limit
```

**Safety Considerations:**
- Always set reasonable limits based on expected workload
- Use enabled mode during development and testing
- Consider disabled mode for performance-critical production paths
- Monitor for safety counter triggers in logs

## Design Principles

1. **Safety First**: All utilities prioritize preventing system abuse and resource exhaustion
2. **Zero-Cost Abstractions**: Compile-time configuration allows optimizing away safety checks in production
3. **Platform Awareness**: Handle different target platforms (WASM, native) appropriately
4. **Logging Integration**: Provide detailed logging for debugging and monitoring
5. **Generic Design**: Support multiple data types and use cases through compile-time generics

## Integration

Internal utilities are used throughout the EVM implementation to provide:
- Loop bounds checking in bytecode analysis
- Recursion depth limiting in call chains
- Resource usage monitoring in memory operations
- Gas calculation overflow protection
- Stack depth validation

## Testing

The internal module includes comprehensive unit tests covering:
- Basic functionality with different numeric types
- Enable/disable mode behavior
- Edge cases and boundary conditions
- Platform-specific behavior validation