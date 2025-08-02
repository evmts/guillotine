# Implement Pre-Extracted Instructions for Cache-Efficient EVM Execution

## Overview

This prompt describes how to implement evmone-style pre-extracted instructions in the Zig EVM to improve cache efficiency by co-locating instruction metadata and arguments, eliminating bytecode memory access during execution.

## Background: evmone's Approach

evmone's advanced interpreter uses a two-level instruction representation:

```cpp
struct Instruction {
    instruction_exec_fn fn = nullptr;
    InstructionArgument arg;
};

union InstructionArgument {
    int64_t number;
    const intx::uint256* push_value;    // Pointer for PUSH9-PUSH32
    uint64_t small_push_value;           // Direct value for PUSH1-PUSH8
    BlockInfo block{};
};
```

Key insights:
- Small PUSH values (≤8 bytes) stored directly in the instruction
- Large PUSH values stored in a separate vector with pointers
- All instruction data accessed sequentially during execution
- Eliminates bytecode memory access for PUSH operations

## Current State Analysis

### Strengths Already in Place

1. **PcToOpEntry Table** (`code_analysis.zig`):
   ```zig
   pub const PcToOpEntry = struct {
       operation: *const Operation.Operation,
       opcode_byte: u8,
       min_stack: u32,
       max_stack: u32,
       constant_gas: u64,
       undefined: bool,
   };
   ```
   - Eliminates bytecode → opcode → operation indirection
   - Pre-caches validation data

2. **Block-Level Execution** (`interpret.zig`):
   - Pre-validates entire blocks
   - Consumes gas at block level
   - Skips per-instruction validation when block is validated

3. **Single-Pass Analysis** (`single_pass_analysis.zig`):
   - Builds all analysis data in one cache-efficient pass
   - Already identifies blocks and jump destinations

### Current Inefficiency

PUSH operations still read from bytecode during execution:
```zig
// op_push1 reads from bytecode
const value: u256 = if (pc + 1 < code.len) code[pc + 1] else 0;

// make_push_small loops through bytecode
for (0..n) |i| {
    if (pc + 1 + i < code.len) {
        value = (value << 8) | code[pc + 1 + i];
    }
}
```

This causes:
- Cache misses when bytecode and stack are in different cache lines
- Repeated reads for loops containing PUSH instructions
- Memory bandwidth waste

## Proposed Implementation

### 1. Extended PcToOpEntry Structure

Replace current `PcToOpEntry` with an extended version:

```zig
// In code_analysis.zig
pub const InstructionArg = union(enum) {
    /// No argument
    none: void,
    
    /// Small push value (PUSH1-PUSH8) - stored directly
    small_push: u64,
    
    /// Large push value (PUSH9-PUSH32) - index into push_values array
    large_push_idx: u32,
    
    /// Block info for block-aware execution
    block: struct {
        /// Index into blocks array
        block_idx: u32,
        /// Whether this is first instruction in block
        is_block_start: bool,
    },
    
    /// Static jump destination (pre-validated)
    static_jump: u32,
};

pub const ExtendedPcToOpEntry = struct {
    /// Original fields
    operation: *const Operation.Operation,
    opcode_byte: u8,
    min_stack: u32,
    max_stack: u32,
    constant_gas: u64,
    undefined: bool,
    
    /// NEW: Pre-extracted argument
    arg: InstructionArg,
    
    /// NEW: Actual instruction size (1-33 bytes)
    size: u8,
};
```

### 2. Update CodeAnalysis Structure

Add storage for large push values:

```zig
pub const CodeAnalysis = struct {
    // ... existing fields ...
    
    /// NEW: Replaces pc_to_op_entries
    extended_entries: ?[]const ExtendedPcToOpEntry,
    
    /// NEW: Storage for PUSH9-PUSH32 values
    /// Separate array improves cache locality for common case (no large pushes)
    large_push_values: ?[]const u256,
    
    // ... rest of struct ...
};
```

### 3. Update Single-Pass Analysis

Modify `analyzeSinglePass` to extract arguments:

```zig
// In single_pass_analysis.zig, around line 50
var large_push_values = std.ArrayList(u256).init(allocator);
defer large_push_values.deinit();

while (i < code.len) {
    const op = code[i];
    var arg = InstructionArg{ .none = {} };
    var instr_size: u8 = 1;
    
    // Extract arguments based on opcode
    switch (op) {
        0x60...0x7f => { // PUSH1-PUSH32
            const push_size = op - 0x5f;
            instr_size = 1 + push_size;
            
            // Extract value from bytecode
            if (i + push_size < code.len) {
                if (push_size <= 8) {
                    // Small push - store directly
                    var value: u64 = 0;
                    var j: usize = 0;
                    while (j < push_size) : (j += 1) {
                        value = (value << 8) | code[i + 1 + j];
                    }
                    arg = .{ .small_push = value };
                } else {
                    // Large push - store in separate array
                    var value: u256 = 0;
                    var j: usize = 0;
                    while (j < push_size) : (j += 1) {
                        if (i + 1 + j < code.len) {
                            value = (value << 8) | code[i + 1 + j];
                        }
                    }
                    arg = .{ .large_push_idx = @intCast(large_push_values.items.len) };
                    try large_push_values.append(value);
                }
            }
        },
        
        0x56 => { // JUMP
            // Check if previous was PUSH with constant
            if (i > 0 and canExtractStaticJump(code, i, extended_entries)) {
                const dest = extractStaticJumpDest(extended_entries, i);
                if (jumpdests.contains(dest)) {
                    arg = .{ .static_jump = dest };
                }
            }
        },
        
        else => {},
    }
    
    // Handle block tracking
    if (current_block_idx != null and i == current_block.start_pc) {
        arg = .{ .block = .{
            .block_idx = current_block_idx.?,
            .is_block_start = true,
        }};
    }
    
    // Store extended entry
    if (extended_entries) |entries| {
        entries[i] = ExtendedPcToOpEntry{
            .operation = operation,
            .opcode_byte = op,
            .min_stack = operation.min_stack,
            .max_stack = operation.max_stack,
            .constant_gas = operation.constant_gas,
            .undefined = operation.undefined,
            .arg = arg,
            .size = instr_size,
        };
    }
    
    // Skip PUSH data bytes
    i += instr_size;
}
```

### 4. Create Optimized Operations

Add new operations that use pre-extracted values:

```zig
// In execution/stack.zig

/// PUSH operation using pre-extracted small value (PUSH1-PUSH8)
pub fn push_preextracted_small(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = interpreter;
    const frame = state;
    
    // Get extended entry - guaranteed to exist in fast path
    const entry = frame.contract.analysis.?.extended_entries.?[pc];
    
    // Stack check already done by block validation
    frame.stack.append_unsafe(@as(u256, entry.arg.small_push));
    
    return Operation.ExecutionResult{ .bytes_consumed = entry.size };
}

/// PUSH operation using pre-extracted large value (PUSH9-PUSH32)
pub fn push_preextracted_large(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = interpreter;
    const frame = state;
    
    const entry = frame.contract.analysis.?.extended_entries.?[pc];
    const value = frame.contract.analysis.?.large_push_values.?[entry.arg.large_push_idx];
    
    frame.stack.append_unsafe(value);
    
    return Operation.ExecutionResult{ .bytes_consumed = entry.size };
}

/// Fallback for when pre-extraction unavailable
pub fn push_fallback(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    // Detect push size from opcode and dispatch to original implementation
    const frame = state;
    const opcode = frame.contract.code[pc];
    const n = opcode - 0x5f;
    
    if (n == 1) return op_push1(pc, interpreter, state);
    if (n <= 8) return make_push_small(n)(pc, interpreter, state);
    return make_push(n)(pc, interpreter, state);
}
```

### 5. Update Jump Table Construction

Modify `jump_table.zig` to use optimized operations when analysis available:

```zig
// In init_from_hardfork, replace PUSH operation setup

// Build operations that check for pre-extraction at runtime
inline for (0..32) |i| {
    const n = i + 1;
    jt.table[0x60 + i] = &Operation{
        .execute = if (n == 1) 
            push_with_preextract_check_1
        else if (n <= 8)
            push_with_preextract_check_small
        else
            push_with_preextract_check_large,
        .constant_gas = execution.gas_constants.GasFastestStep,
        .min_stack = 0,
        .max_stack = Stack.CAPACITY - 1,
    };
}

// Runtime dispatch functions
fn push_with_preextract_check_1(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) !Operation.ExecutionResult {
    const frame = state;
    if (frame.contract.analysis) |analysis| {
        if (analysis.extended_entries) |entries| {
            if (entries[pc].arg == .small_push) {
                return push_preextracted_small(pc, interpreter, state);
            }
        }
    }
    return op_push1(pc, interpreter, state);
}
```

### 6. Update Execution Loop

Modify `interpret.zig` to use extended entries:

```zig
// Replace lines 122-136
const entry = if (contract.analysis) |analysis| blk: {
    if (analysis.extended_entries) |extended| {
        break :blk &extended[pc_index];
    } else if (analysis.pc_to_op_entries) |basic| {
        // Convert basic to extended format
        break :blk &ExtendedPcToOpEntry{
            .operation = basic[pc_index].operation,
            .opcode_byte = basic[pc_index].opcode_byte,
            .min_stack = basic[pc_index].min_stack,
            .max_stack = basic[pc_index].max_stack,
            .constant_gas = basic[pc_index].constant_gas,
            .undefined = basic[pc_index].undefined,
            .arg = .{ .none = {} },
            .size = 1, // Will be corrected by operation
        };
    }
    break :blk null;
} else null;

if (entry == null) {
    // Fallback: build entry on the fly
    // ... existing fallback code ...
}
```

## Memory Layout Optimization

### Cache Line Considerations

```
ExtendedPcToOpEntry size: 32 bytes (fits in half cache line)
- operation: 8 bytes (pointer)
- opcode_byte: 1 byte
- min_stack: 4 bytes
- max_stack: 4 bytes  
- constant_gas: 8 bytes
- undefined: 1 byte
- arg: 8 bytes (union)
- size: 1 byte
- padding: 3 bytes

Cache line (64 bytes) holds 2 instructions
Sequential execution = excellent spatial locality
```

### Memory Usage Analysis

For typical contract (24KB):
- Original: 24KB bytecode + 192KB PcToOpEntry (8x)
- Extended: 24KB bytecode + 384KB ExtendedPcToOpEntry (16x) + ~1KB push values
- Trade-off: 2x memory for instruction table, but better cache performance

## Testing Strategy

### 1. Correctness Tests

```zig
test "pre-extracted PUSH values match runtime extraction" {
    // Test all PUSH1-PUSH32 variants
    // Compare pre-extracted vs runtime extraction
    // Test edge cases (EOF, partial push data)
}

test "static jump pre-validation" {
    // Verify static jumps are correctly identified
    // Test invalid jump rejection
}
```

### 2. Performance Benchmarks

```zig
test "benchmark PUSH-heavy code" {
    // Contract with many PUSH operations
    // Compare execution with/without pre-extraction
    // Measure cache misses using perf counters
}

test "benchmark real contracts" {
    // ERC20, Uniswap, etc.
    // Measure overall performance impact
}
```

### 3. Memory Benchmarks

```zig
test "measure memory overhead" {
    // Compare memory usage before/after
    // Ensure reasonable overhead for typical contracts
}
```

## Implementation Phases

### Phase 1: Foundation (2 days)
- Implement `ExtendedPcToOpEntry` and `InstructionArg`
- Update `CodeAnalysis` structure
- Basic tests for structure layout

### Phase 2: Analysis (3 days)
- Modify `single_pass_analysis.zig` to build extended entries
- Extract PUSH arguments
- Handle static jump detection

### Phase 3: Execution (2 days)
- Implement optimized PUSH operations
- Update jump table dispatch
- Modify execution loop

### Phase 4: Integration (2 days)
- Update Contract to use extended analysis
- Ensure backward compatibility
- Handle analysis caching

### Phase 5: Optimization (1 day)
- Profile and optimize hot paths
- Fine-tune memory layout
- Add comprehensive benchmarks

## Expected Performance Impact

### Improvements
- **Cache Misses**: 30-50% reduction for PUSH-heavy code
- **Execution Speed**: 10-20% faster for typical contracts
- **Branch Prediction**: Better due to simpler PUSH operations

### Trade-offs
- **Memory Usage**: ~2x for instruction table
- **Analysis Time**: ~10% slower (one-time cost)
- **Code Complexity**: Moderate increase

## Alternative Approaches Considered

1. **Embed all values in union**: Too much memory waste for common case
2. **Lazy extraction**: Defeats purpose of cache optimization
3. **Separate PUSH instruction type**: Too much code duplication

## Conclusion

This implementation brings evmone's cache-efficient instruction design to the Zig EVM while leveraging existing infrastructure. The key insight is co-locating all instruction data to maximize cache efficiency during the interpreter's sequential execution pattern.