# Memory

EVM-compliant memory management with lazy expansion, SIMD optimizations, and hierarchical context isolation.

## Overview

The `Memory(comptime config)` type implements byte-addressable memory that grows on demand and always expands to 32-byte word boundaries as required by the EVM specification. Child contexts (e.g., CALL frames) can share the same backing buffer using checkpoints, avoiding expensive memory copies.

Key features:
- **Lazy allocation** on first access
- **Zero-initialization** guarantee for all new memory
- **SIMD-optimized** memory operations for better performance
- **Checkpoint system** for nested call contexts
- **Cached gas cost** calculations
- **Configurable memory limits** for DoS protection

Default configuration (see `memory_config.zig`):
- `initial_capacity = 4096` (4KB)
- `memory_limit = 0xFFFFFF` (~16MB, EVM limit)
- `owned = true`
- `vector_length = 1` (SIMD disabled by default)

## Files

- `memory.zig` — Core implementation with SIMD optimizations
- `memory_config.zig` — Compile-time configuration and validation
- `memory_c.zig` — C FFI interface for external integration
- `memory_bench.zig` — Performance benchmarking suite

## Core API

### Memory Lifecycle
- `init(allocator)` / `deinit(allocator)` — create/destroy owned memory
- `init_borrowed(buffer_ptr, checkpoint)` — create borrowed memory view
- `init_child()` — create child memory with shared buffer
- `clear()` — reset memory to initial state

### Memory Operations
- `ensure_capacity(allocator, new_size: u24)` — ensure memory capacity with zero-initialization
- `set_data(allocator, offset, data)` — write raw data without EVM expansion
- `set_data_evm(allocator, offset, data)` — write data with EVM word-alignment
- `get_slice(offset, len)` — read raw data slice
- `size()` — get current memory size

### Word Operations (u256)
- `set_u256(allocator, offset, value)` — write 256-bit word
- `set_u256_evm(allocator, offset, value)` — write word with EVM expansion
- `get_u256(offset)` — read 256-bit word
- `get_u256_evm(allocator, offset)` — read word with EVM expansion

### Byte Operations
- `set_byte(allocator, offset, value)` — write single byte
- `set_byte_evm(allocator, offset, value)` — write byte with EVM expansion
- `get_byte(offset)` — read single byte

### Gas Cost Calculation
- `get_expansion_cost(new_size)` — calculate EVM memory expansion gas cost

## Examples

### Basic Memory Usage

```zig
const std = @import("std");
const MemoryConfig = @import("memory_config.zig").MemoryConfig;
const Memory = @import("memory.zig").Memory;

const OwnedMemory = Memory(.{ .owned = true });

var memory = try OwnedMemory.init(allocator);
defer memory.deinit(allocator);

// Write a u256 value at offset 0
try memory.set_u256(allocator, 0, 1234);
const value = try memory.get_u256(0);
try std.testing.expectEqual(@as(u256, 1234), value);

// EVM-compliant write expands to next 32-byte boundary
const data = [_]u8{0xAA} ** 20;
try memory.set_data_evm(allocator, 40, &data);
```

### Child Memory (Nested Contexts)

```zig
// Parent memory with initial data
var parent = try OwnedMemory.init(allocator);
defer parent.deinit(allocator);

const parent_data = [_]u8{ 0x01, 0x02, 0x03 };
try parent.set_data(allocator, 0, &parent_data);

// Create child memory sharing the same buffer
var child = try parent.init_child();
defer child.deinit(allocator); // no-op for borrowed memory

// Child operations are isolated by checkpoint
const child_data = [_]u8{ 0x11, 0x22 };
try child.set_data(allocator, 0, &child_data);

// Parent sees: [0x01, 0x02, 0x03, 0x11, 0x22]
// Child sees:  [0x11, 0x22] (from its checkpoint)
```

### Gas Cost Calculation

```zig
// Calculate EVM memory expansion costs
var memory = try OwnedMemory.init(allocator);
defer memory.deinit(allocator);

const cost_256 = memory.get_expansion_cost(256); // 3*8 + (8*8)/512 = 24
try memory.ensure_capacity(allocator, 256);

// No additional cost for sizes within current capacity
const no_cost = memory.get_expansion_cost(128); // 0
```

### SIMD Optimizations

```zig
// Enable SIMD for better performance on large operations
const SIMDMemory = Memory(.{
    .owned = true,
    .vector_length = 16, // 16-byte SIMD vectors
});

var memory = try SIMDMemory.init(allocator);
defer memory.deinit(allocator);

// Large data operations automatically use SIMD when beneficial
var large_data: [1024]u8 = undefined;
@memset(&large_data, 0xFF);
try memory.set_data_evm(allocator, 0, &large_data);
```

## Performance Optimizations

### Fast-Path Memory Growth
Small memory expansions (≤32 bytes) use a fast path that:
- Reuses existing capacity when possible
- Avoids unnecessary memory allocations
- Uses optimized zeroing for new regions

### SIMD Memory Operations
When `vector_length > 1`, memory operations automatically use SIMD:
- **Zeroing**: Vectorized initialization of new memory regions
- **Copying**: Optimized data transfer for large operations
- **Alignment**: Automatic handling of alignment requirements

### Cached Gas Calculations
Gas costs are calculated using optimized bit operations:
```zig
// Memory cost formula: 3 * words + words² / 512
fn calculate_memory_cost(words: u64) u64 {
    return 3 * words + std.math.shr(u64, words * words, 9);
}
```

## Memory Configuration

```zig
const MemoryConfig = @import("memory_config.zig").MemoryConfig;

// High-performance configuration
const HighPerf = MemoryConfig{
    .initial_capacity = 8192,    // 8KB initial
    .memory_limit = 0x1000000,   // 16MB limit
    .vector_length = 32,         // 32-byte SIMD vectors
    .owned = true,
};

// Memory-constrained configuration
const LowMemory = MemoryConfig{
    .initial_capacity = 1024,    // 1KB initial
    .memory_limit = 0x100000,    // 1MB limit
    .vector_length = 1,          // No SIMD
    .owned = true,
};
```

## Integration with EVM

### Gas Cost Accounting
Memory expansion follows EVM gas cost formula:
- Linear component: 3 gas per word
- Quadratic component: words² / 512 gas
- Only charges for net expansion

### Word Alignment
EVM operations automatically expand memory to 32-byte word boundaries:
- `set_data_evm()` rounds up to next word boundary
- `get_u256_evm()` expands memory if reading beyond current size
- Standard operations (`set_data()`, `get_u256()`) do not auto-expand

### Context Isolation
Child memories provide clean isolation:
- Share physical buffer to avoid copies
- Maintain separate size accounting via checkpoints
- Support nested call frames and exception handling

## Error Handling

Memory operations use comprehensive error types:

```zig
pub const MemoryError = error{
    OutOfMemory,      // System allocation failure
    MemoryOverflow,   // Size exceeds configured limits
    OutOfBounds,      // Access beyond valid memory range
};
```

All memory operations properly handle errors with:
- Clean resource management via defer/errdefer
- Consistent error propagation
- Memory safety guarantees

## Testing and Benchmarking

The memory module includes comprehensive test coverage:
- Basic operations (read/write/expand)
- Child memory isolation
- Gas cost calculations
- SIMD optimization verification
- Edge cases and error conditions

Performance benchmarks cover:
- Memory allocation and expansion
- SIMD vs scalar operation performance
- Child memory overhead
- Gas cost calculation performance

## Notes

- All newly allocated bytes are guaranteed zero-initialized
- Owned and borrowed memory types have identical layout and performance
- SIMD optimizations are conditionally compiled and alignment-aware
- Memory limits provide protection against DoS attacks
- The public API requires an allocator for any operation that may grow memory