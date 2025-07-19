# EVM Memory Subsystem Benchmarks

This document describes the comprehensive benchmarking suite for the EVM memory subsystem in Guillotine.

## Overview

The memory subsystem benchmarks are designed to measure performance across all critical aspects of EVM memory operations, including:
- Memory allocation and expansion
- Read/write operations with various access patterns
- Shared buffer architecture performance
- EVM-specific memory patterns
- Edge cases and boundary conditions

## Benchmark Categories

### 1. Memory Allocation and Expansion
Tests the performance of memory initialization and dynamic expansion:
- `Memory init (small)` - Initialize with 1KB capacity
- `Memory init (large)` - Initialize with 1MB capacity
- `Memory expansion (small)` - Expand to 1KB
- `Memory expansion (large)` - Expand to 1MB
- `Memory expansion (incremental)` - Gradual expansion pattern

### 2. Read Operations
Measures read performance with different access patterns:
- `Memory read u256 (sequential)` - Sequential 32-byte reads
- `Memory read u256 (random)` - Random access 32-byte reads
- `Memory read slice (small)` - Small slice reads (32 bytes)
- `Memory read slice (large)` - Large slice reads (1KB)
- `Memory read byte (sequential)` - Single byte sequential reads

### 3. Write Operations
Tests write performance patterns:
- `Memory write u256 (sequential)` - Sequential 32-byte writes
- `Memory write u256 (random)` - Random access 32-byte writes
- `Memory write data (small)` - Small data writes (32 bytes)
- `Memory write data (large)` - Large data writes (64KB)
- `Memory write data (bounded)` - Bounded writes with partial copies

### 4. Shared Buffer Architecture
Benchmarks the performance of child memory contexts:
- `Memory child context creation` - Creating child contexts
- `Memory child context access` - Accessing shared buffer through children

### 5. EVM Patterns
Tests common EVM memory access patterns:
- `Memory EVM CODECOPY` - Simulates CODECOPY operation
- `Memory EVM CALLDATACOPY` - Simulates CALLDATACOPY with offsets
- `Memory EVM RETURNDATACOPY` - Simulates RETURNDATACOPY
- `Memory EVM MLOAD/MSTORE` - Common load/store patterns
- `Memory EVM Keccak pattern` - Memory access for hashing
- `Memory EVM expansion` - Gradual memory expansion during execution

### 6. Edge Cases
Tests boundary conditions and special cases:
- `Memory zero length ops` - Zero-length reads and writes
- `Memory near limit` - Operations near memory limit
- `Memory alignment patterns` - Misaligned memory access

### 7. Copy vs Set Operations
Compares memcpy and memset performance:
- `Memory memcpy (small)` - Small memory copies
- `Memory memcpy (large)` - Large memory copies
- `Memory memset pattern` - Zero-filling patterns

## Running the Benchmarks

To run all memory benchmarks:
```bash
zig build bench
```

To run benchmarks with specific options:
```bash
# Run with custom iterations
./zig-out/bin/guillotine-bench

# Run with verbose output
./zig-out/bin/guillotine-bench --verbose
```

## Implementation Details

The benchmarks are implemented in two files:
- `bench/memory_zbench.zig` - zbench-compatible benchmark functions
- `bench/memory_benchmark.zig` - Standalone benchmark suite with detailed metrics

### Key Performance Metrics

The benchmarks measure:
- **Throughput** - MB/s for read/write operations
- **Latency** - Time per operation in nanoseconds
- **Memory overhead** - Allocation and expansion costs
- **Cache efficiency** - Through access pattern variations

### Memory Architecture

The Guillotine memory subsystem features:
- **Shared buffer architecture** - Multiple contexts share a single buffer
- **Checkpoint-based isolation** - Each context has its own view
- **Dynamic expansion** - Grows as needed up to configured limit
- **Zero-initialization** - New memory is always zeroed
- **Efficient copying** - Uses optimized memcpy/memset operations

### Optimization Opportunities

Based on benchmark results, consider:
1. **Memory pooling** - Reuse allocated buffers
2. **Page-aligned allocation** - Improve cache performance
3. **SIMD operations** - For large copies and fills
4. **Memory prefetching** - For predictable access patterns
5. **Custom allocators** - Reduce allocation overhead

## Benchmark Results

Results are displayed in the console with:
- Operation name
- Mean execution time
- Operations per second
- Standard deviation
- Min/max times

Example output:
```
Memory init (small)         mean: 125.3ns  ops/s: 7.98M  std: 12.1ns
Memory read u256 (seq)      mean: 45.2ns   ops/s: 22.1M  std: 3.4ns
Memory write data (large)   mean: 15.3µs   ops/s: 65.4K  std: 1.2µs
```

## Integration with CI/CD

The memory benchmarks can be integrated into CI pipelines to:
- Track performance regressions
- Compare different implementations
- Validate optimization efforts
- Generate performance reports

## Future Enhancements

Planned improvements:
1. **Comparative benchmarks** - Against other EVM implementations
2. **Memory pressure tests** - Concurrent access patterns
3. **NUMA awareness** - For multi-socket systems
4. **Profile-guided optimization** - Based on real workloads
5. **Memory access heatmaps** - Visualize access patterns