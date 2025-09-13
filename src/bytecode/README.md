# Bytecode

Validated EVM bytecode representation with fast iteration, metadata parsing, advanced fusion patterns, and comprehensive analysis capabilities.

## Overview

`bytecode.zig` exposes a `Bytecode(comptime cfg)` factory that builds a strongly-typed bytecode object with:
- Safe validation and bitmap generation in a single pass
- JUMPDEST lookups in O(1) via bitmaps
- Advanced bytecode fusion patterns for dispatch optimization
- Solidity metadata parsing/stripping (runtime code only)
- EIP-170 code size enforcement and EIP-3860 initcode gas helpers
- Basic block analysis with gas cost calculation
- Pattern recognition for optimization opportunities
- C API for external integration
- Comprehensive benchmarking and analysis tools

EOF (EIP-3540/3670/4750/5450) is not supported yet.

## Files

### Core Implementation
- `bytecode.zig` — Core bytecode type with iterator, validation, advanced fusion patterns
- `bytecode_config.zig` — Configuration system with compile-time validation and PC type selection
- `bytecode_analyze.zig` — Standalone analyzer for tooling and external use
- `bytecode_stats.zig` — Comprehensive opcode statistics and pattern analysis

### APIs and Integration
- `bytecode_c.zig` — C FFI interface for external language integration

### Testing and Benchmarking
- `bytecode_tests.zig` — Core functionality tests
- `bytecode_jump_validation_test.zig` — JUMPDEST validation tests
- `bytecode_bench.zig` — Performance benchmarking suite
- `bytecode_bench_simple.zig` — Simplified benchmarks
- `bytecode_bench_test.zig` — Benchmark validation tests

## Validation Model

During `init(...)` we implement a two-phase security model for handling untrusted EVM bytecode:

### Phase 1 - Validation
- Treat ALL bytecode as untrusted and potentially malicious
- Use safe std library functions with runtime checks
- Validate ALL assumptions about bytecode structure
- Check for invalid opcodes, truncated PUSH instructions, invalid jump destinations
- Build validated bitmaps that mark safe regions of code

### Phase 2 - Execution
- Once bytecode passes validation, unsafe builtins can be used for performance
- Bitmap lookups ensure we only execute at valid positions

### Data Structures
- `packed_bitmap` (4 bits/byte): `is_push_data`, `is_op_start`, `is_jumpdest`, `is_fusion_candidate`
- Separate bitmaps for efficient O(1) lookups

### Rules Enforced
- Truncated PUSH detection (no read past end of code)
- Invalid opcodes are treated as `INVALID (0xFE)` for safety
- JUMPDEST bits are set only for true opcode starts
- EIP-170: runtime bytecode must not exceed configured max size
- EIP-3860: initcode size validation and gas calculation

For deployment bytecode with Solidity metadata, validation excludes the metadata suffix while preserving the full input slice for consumers that need it.

## Iterator and Queries

The `Iterator` walks instructions efficiently and yields a comprehensive tagged union (`OpcodeData`):
- Basic opcodes: PUSH (value + size), JUMPDEST, JUMP/JUMPI, STOP, INVALID, regular opcodes
- Advanced fusion patterns when enabled:
  - **Constant folding**: `PUSH1 a PUSH1 b ADD` → folded constant
  - **Multi-operations**: `PUSH PUSH PUSH` (multi-push), `POP POP POP` (multi-pop)
  - **Complex patterns**: `ISZERO PUSH JUMPI`, `DUP2 MSTORE PUSH`
  - **High-impact fusions**: `DUP3 ADD MSTORE`, `SWAP1 DUP2 ADD`, function dispatch patterns

### Advanced Fusion Patterns

The bytecode analyzer detects and can fuse complex instruction sequences:

1. **Constant Folding**: `PUSH1 5 PUSH1 3 ADD` → `PUSH1 8`
2. **Multi-Push/Pop**: `PUSH1 a PUSH1 b PUSH1 c` → single multi-push operation  
3. **Memory Patterns**: `DUP2 MSTORE PUSH1 offset` → optimized memory operation
4. **Control Flow**: `ISZERO PUSH1 target JUMPI` → optimized conditional jump
5. **Function Dispatch**: Common Solidity function selector patterns
6. **Stack Manipulation**: `SWAP1 DUP2 ADD`, `DUP3 ADD MSTORE` patterns

Common helpers:
- `len()` — runtime code length
- `raw()` / `rawWithoutMetadata()` — access to underlying byte slices
- `isValidJumpDest(pc)` — O(1) JUMPDEST validity check
- `calculateInitcodeGas(len)` — EIP-3860 gas cost calculation
- `createIterator()` — create efficient bytecode iterator

## Statistics and Analysis

`BytecodeStats.analyze()` provides comprehensive bytecode analysis:

### Core Statistics
- **Opcode histogram**: Count of each opcode type (0x00-0xFF)
- **PUSH values**: All immediate values with their program counter locations
- **Jump analysis**: JUMP/JUMPI targets, backwards jump detection, valid destinations
- **Fusion opportunities**: Potential PUSH+OP combinations for optimization

### Pattern Analysis
- **2-8 opcode patterns**: Most frequent instruction sequences
- **Top 3 patterns** for each length (2-8 opcodes)
- **Pattern frequency analysis**: Identifies optimization opportunities
- **Complex sequence detection**: Multi-opcode patterns for fusion

### Advanced Features
- **Memory-safe statistics**: All analysis handles invalid/truncated bytecode
- **Contract type detection**: Heuristics for create/deploy vs runtime code
- **Performance metrics**: Backwards jump counting for loop detection
- **Detailed reporting**: Human-readable formatted statistics output

### Usage
```zig
const stats = try BytecodeStats.analyze(allocator, bytecode_slice);
defer stats.deinit(allocator);

// Access detailed analysis
const output = try stats.formatStats(allocator);
defer allocator.free(output);
```

## Configuration and Usage Examples

### Basic Usage

```zig
const BytecodeConfig = @import("bytecode_config.zig").BytecodeConfig;
const Bytecode = @import("bytecode.zig").Bytecode(BytecodeConfig{});

// Initialize with raw bytecode
const bc = try Bytecode.init(allocator, raw_bytes);
defer bc.deinit();

// Iterate through instructions
var it = bc.createIterator();
while (it.next()) |op| switch (op) {
    .push => |p| { 
        log.debug("PUSH value: 0x{x}, size: {}", .{ p.value, p.size });
    },
    .jumpdest => |jd| {
        log.debug("JUMPDEST at PC with gas cost: {}", .{jd.gas_cost});
    },
    .regular => |r| { 
        log.debug("Regular opcode: 0x{x:0>2}", .{r.opcode}); 
    },
    // Advanced fusion patterns
    .constant_fold => |cf| {
        log.debug("Constant folded to: 0x{x}", .{cf.value});
    },
    .multi_push => |mp| {
        log.debug("Multi-push of {} values", .{mp.count});
    },
    else => {},
};

// Query capabilities
const is_valid = bc.isValidJumpDest(0x42);
const gas_cost = bc.calculateInitcodeGas(bc.len());
```

### Custom Configuration

```zig
// Custom configuration with smaller bytecode limits
const custom_config = BytecodeConfig{
    .max_bytecode_size = 16384,  // 16KB limit
    .max_initcode_size = 32768,  // 32KB init limit  
    .fusions_enabled = true,     // Enable optimizations
};

const CustomBytecode = @import("bytecode.zig").Bytecode(custom_config);
// PC type is automatically selected based on max size (u16 in this case)
```

### Standalone Analysis

```zig
const analyze = @import("bytecode_analyze.zig").bytecodeAnalyze;

// Analyze without full bytecode wrapper
const analysis = try analyze(u16, BasicBlock, FusionInfo, allocator, code);
defer {
    allocator.free(analysis.push_pcs);
    allocator.free(analysis.jumpdests);  
    allocator.free(analysis.basic_blocks);
    analysis.jump_fusions.deinit();
    analysis.advanced_fusions.deinit();
}
```

## C API Integration

The bytecode module provides a comprehensive C FFI interface for external language integration:

```c
// Create bytecode from raw bytes
evm_bytecode_handle_t* handle = evm_bytecode_create(bytecode, length);

// Query bytecode properties  
size_t len = evm_bytecode_length(handle);
int is_valid_dest = evm_bytecode_is_valid_jump_dest(handle, pc);

// Get statistics
char* stats_json = evm_bytecode_get_stats_json(handle);

// Cleanup
evm_bytecode_destroy(handle);
```

Error codes and memory management are handled safely with clear error reporting.

## Performance Notes

- **Single-pass validation**: Builds all bitmaps with cache-friendly writes in one scan
- **Packed metadata**: 4-bit per-byte packed data avoids re-scanning for common queries
- **Iterator prefetching**: Prefetches ahead on large bytecode to improve memory locality
- **Fusion optimization**: Advanced patterns are purely optional; correctness never depends on them
- **Memory efficiency**: Configurable PC types (u8/u12/u16/u32) based on bytecode size limits
- **Zero-copy design**: Direct access to underlying bytecode where possible
- **Bitmap lookups**: O(1) JUMPDEST validation using pre-computed bitmaps

## Architecture Integration

The bytecode module integrates seamlessly with other Guillotine EVM components:

- **EVM Frame**: Provides validated bytecode for instruction execution
- **Gas Calculation**: Supports EIP-3860 initcode gas and basic block gas estimation  
- **Planner System**: Supplies jump destination and fusion analysis
- **Tracer Integration**: Enables detailed bytecode-level execution tracing
- **Memory Safety**: All operations are bounds-checked and memory-safe
