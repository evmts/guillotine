# CLAUDE.md - Memory Module

## MISSION CRITICAL: EVM Memory Semantics
**Memory deviations cause consensus failures and fund loss.**

### EVM Memory Specs
- **Word Size**: 32 bytes (256 bits)
- **Growth**: 32-byte word boundaries only
- **Addressing**: Byte-addressable from 0
- **Initialization**: Zero-initialized on expansion
- **Gas**: Quadratic cost `words * 3 + words² / 512` (EIP-150)

### Core Files
- `memory.zig` - Main implementation, lazy expansion
- `memory_config.zig` - Configuration/validation
- `memory_c.zig` - C FFI interface
- `memory_bench.zig` - Performance benchmarks

## Key Operations
- **MLOAD/MSTORE**: 32-byte word operations
- **MSTORE8**: Single byte operations
- **Word-aligned expansion**: Always 32-byte boundaries
- **Gas formula**: Quadratic expansion cost

## Safety & Performance
- **Bounds checking**: Always validate before access
- **Zero initialization**: Expanded memory must be zeroed
- **Checkpoints**: Save/restore for nested calls
- **Lazy allocation**: Only allocate when accessed
- **Word-aligned growth**: Reduces fragmentation

## Critical Errors
- **Memory overflow**: Check against MEMORY_LIMIT
- **Out of bounds**: Validate all access
- **Allocation failure**: Handle OutOfMemory gracefully

**EVM memory semantics are sacred. Any deviation causes consensus failures.**