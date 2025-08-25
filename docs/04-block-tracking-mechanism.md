# Block Tracking Mechanism: Monitoring Execution at Block Boundaries

## Executive Summary

This research document provides a comprehensive analysis of the block tracking mechanism in Guillotine EVM, covering both optimized and minimal execution modes. The system handles block creation at PC=0 and JUMPDEST opcodes, with metadata embedded in the instruction stream for optimized execution and computed at runtime for minimal execution.

## Key Findings

1. **Block Structure**: Blocks are created at PC=0 (entry point) and at each JUMPDEST opcode
2. **Metadata Storage**: In optimized mode, metadata is embedded directly in the instruction stream; in minimal mode, it's computed at runtime
3. **Block Detection**: Both modes can detect block boundaries, but with different performance characteristics
4. **Zero-Overhead When Disabled**: The system uses compile-time elimination when tracking is disabled

## 1. Deep Dive into Block Architecture

### 1.1 TempBlock Structure Analysis

From `src/evm/planner.zig` lines 43-44 and 314-320:

```zig
// Track blocks during analysis with temporary structure
const TempBlock = struct {
    pc: PcType,
    metadata: JumpDestMetadata,
};
```

The `TempBlock` structure is used during bytecode analysis to track block boundaries and their associated metadata. It contains:

- `pc`: The program counter where the block starts (0 for entry block, JUMPDEST location for others)
- `metadata`: Gas and stack height information for the block

### 1.2 JumpDestMetadata Fields

From `src/evm/plan.zig`:

```zig
/// Metadata for JUMPDEST instructions.
/// On 64-bit systems this fits in usize, on 32-bit it requires pointer.
pub const JumpDestMetadata = packed struct {
    gas: u32,
    min_stack: i16,
    max_stack: i16,
};
```

Fields:

- `gas`: Static gas consumed within the block
- `min_stack`: Minimum stack height reached during block execution
- `max_stack`: Maximum stack height reached during block execution

### 1.3 Block Creation Logic

Blocks are created at two points:

1. **PC=0 (Entry Block)**: Created automatically at the start of bytecode execution
2. **JUMPDEST Opcodes**: Created when the planner encounters a valid JUMPDEST instruction

From `src/evm/planner.zig`:

```zig
// Pass 2: build blocks and compute instructionIndex parity, static gas, and stack ranges
var stream_idx: usize = 0;
var block_idx: usize = 0;
blocks[0] = .{
    .pc = 0,
    .metadata = .{ .gas = 0, .min_stack = 0, .max_stack = 0 }
};
```

### 1.4 Metadata Embedding in Instruction Stream

In optimized mode, metadata is embedded directly in the instruction stream:

- On 64-bit systems: Stored inline as `jumpdest_metadata`
- On 32-bit systems: Stored in a separate array and referenced by pointer

From `src/evm/planner.zig`:

```zig
// On 64-bit systems, store metadata directly
if (@sizeOf(usize) == 8) {
    try stream.append(.{ .jumpdest_metadata = jd_metadata });
} else {
    // On 32-bit systems, store in dedicated JumpDest metadata array and use pointer
    const jd_idx = jumpdests.items.len;
    try jumpdests.append(jd_metadata);
    const metadata_ptr = &jumpdests.items[jd_idx];
    try stream.append(.{ .jumpdest_pointer = metadata_ptr });
}
```

### 1.5 Block Boundary Detection Patterns

Block boundaries are detected through:

1. Entry point (PC=0)
2. JUMPDEST opcodes
3. Control flow operations (JUMP, JUMPI, etc.)
4. Exception handling points

## 2. JUMPDEST Handling Analysis

### 2.1 JUMPDEST Opcode Handler

In `src/evm/frame.zig`, the JUMPDEST handler is a no-op:

```zig
pub fn jumpdest(self: *Self) Error!void {
    _ = self;
    // JUMPDEST does nothing - it's just a marker for valid jump destinations
}
```

This makes sense as JUMPDEST is purely a validation marker with no execution semantics.

### 2.2 Optimized Plan JUMPDEST Handling

In optimized mode, JUMPDEST metadata is precomputed and embedded:

From `src/evm/planner.zig`:

```zig
} else if (op == @intFromEnum(Opcode.JUMPDEST)) {
    // JUMPDEST needs metadata
    const handler_ptr = handlers[op];
    try stream.append(.{ .handler = handler_ptr });

    // Find the block metadata for this JUMPDEST
    var metadata_found = false;
    for (blocks) |block| {
        if (block.pc == i) {
            // Found the metadata for this JUMPDEST
            const jd_metadata = block.metadata;

            // On 64-bit systems, store metadata directly
            if (@sizeOf(usize) == 8) {
                try stream.append(.{ .jumpdest_metadata = jd_metadata });
            } else {
                // On 32-bit systems, store in dedicated JumpDest metadata array and use pointer
                const jd_idx = jumpdests.items.len;
                try jumpdests.append(jd_metadata);
                const metadata_ptr = &jumpdests.items[jd_idx];
                try stream.append(.{ .jumpdest_pointer = metadata_ptr });
            }
            metadata_found = true;
            break;
        }
    }
}
```

### 2.3 PlanMinimal's JUMPDEST Validation

In minimal mode, JUMPDEST validation is performed at runtime:

From `src/evm/plan_minimal.zig`:

```zig
/// Check if a PC is a valid JUMPDEST.
pub fn isValidJumpDest(self: *const Self, pc: usize) bool {
    if (pc >= self.bytecode.len()) return false;
    return (self.bytecode.is_jumpdest[pc >> 3] & (@as(u8, 1) << @intCast(pc & 7))) != 0;
}
```

This uses precomputed bitmaps to determine valid jump destinations.

### 2.4 Jump Table Construction Logic

The jump table is constructed during planning:

From `src/evm/planner.zig`:

```zig
// Build PC to instruction index mapping
var pc_map = std.AutoHashMap(PcType, InstructionIndexType).init(allocator);
errdefer pc_map.deinit();

// Build instruction stream with handlers and metadata
i = 0;
// Dense PC->instruction index table for fast JUMP/JUMPI
var dense_pc_to_idx = try allocator.alloc(?PlanType.InstructionIndexType, N);
errdefer allocator.free(dense_pc_to_idx);
// Initialize all to null (non-start PCs or out-of-range)
for (dense_pc_to_idx) |*slot| slot.* = null;
```

### 2.5 PC to Block Relationships

The relationship between PC and blocks is maintained through:

1. Direct mapping in optimized mode via `pc_to_instruction_idx_dense`
2. Bitmap analysis in minimal mode via `is_jumpdest` bitmaps

## 3. Instruction Stream Structure

### 3.1 InstructionElement Union Variants

From `src/evm/plan.zig`:

For 64-bit platforms:

```zig
/// Instruction stream element for 64-bit platforms.
pub const InstructionElement64 = packed union {
    handler: *const HandlerFn,
    jumpdest_metadata: JumpDestMetadata,
    inline_value: u64,
    pointer_index: u64,
};
```

For 32-bit platforms:

```zig
/// Instruction stream element for 32-bit platforms.
pub const InstructionElement32 = packed union {
    handler: *const HandlerFn,
    jumpdest_pointer: *const JumpDestMetadata,
    inline_value: u32,
    pointer_index: u32,
};
```

### 3.2 Metadata Storage Patterns

1. **64-bit Systems**: Metadata stored inline in the instruction stream
2. **32-bit Systems**: Metadata stored in separate array with pointers

### 3.3 Handler Pointer Organization

Handler pointers are organized as the first element of each instruction sequence, followed by metadata when applicable.

### 3.4 Instruction Index Advancement

From `src/evm/plan.zig`:

```zig
/// Get the next instruction handler and advance the instruction pointer.
/// Advances by 1 or 2 based on whether the opcode has metadata.
pub fn getNextInstruction(
    self: *const Self,
    idx: *InstructionIndexType,
    comptime opcode: anytype,
) *const HandlerFn {
    // ... implementation details ...

    // Advance past current instruction and its metadata
    idx.* += 1;
    if (has_metadata) idx.* += 1;
}
```

## 4. Block Tracking Interface Implementation

### 4.1 BlockTracker Structure

```zig
pub const BlockTracker = struct {
    // How to detect block entry/exit?
    // Where to store current block info?
    // How to handle nested calls?

    current_block_pc: ?u32,
    blocks_executed: std.ArrayList(BlockExecution),

    const BlockExecution = struct {
        block_pc: u32,
        entry_gas: u64,
        exit_gas: u64,
        entry_stack_height: i32,
        exit_stack_height: i32,
        instruction_count: u32,
        // What else to track?
    };
};
```

### 4.2 Integration with Both Interpreters

#### 4.2.1 Optimized Mode Block Detection

```zig
// How to detect JUMPDEST handler execution
// Extracting metadata from instruction stream
// Tracking block transitions
```

In optimized mode, block detection happens through:

1. Direct examination of the instruction stream
2. Metadata extraction from precomputed values
3. Handler function analysis

#### 4.2.2 Minimal Mode Block Detection

```zig
// Direct PC monitoring for 0x5B (JUMPDEST)
// Runtime block boundary calculation
// Metadata computation without pre-analysis
```

In minimal mode:

1. PC is monitored directly
2. Block boundaries are calculated at runtime
3. Metadata is computed on-demand

### 4.3 Block Metadata Access Patterns

```zig
pub fn getBlockMetadata(plan: *const Plan, block_pc: u32) ?JumpDestMetadata {
    // How is metadata stored after JUMPDEST handler?
    // Different patterns for 64-bit vs 32-bit systems
    // Handling entry block (PC=0) specially
}
```

## 5. Critical Implementation Points

### 5.1 Block Entry Detection

- Hook into JUMPDEST execution
- Detect PC=0 entry block
- Handle CALL/CREATE boundaries
- Track after control flow ops

### 5.2 Block Exit Detection

- JUMP/JUMPI execution
- STOP/RETURN/REVERT
- Fall-through to next block
- Exception handling

### 5.3 State Capture Points

- Gas remaining at boundaries
- Stack height validation
- Memory size tracking
- Storage access patterns

## 6. Zero-Overhead When Disabled

When tracing/tracking is disabled:

- No block tracking allocations
- No boundary detection code
- Inline block handlers directly
- Compile-time elimination

The system uses comptime patterns to ensure zero overhead when disabled.

## 7. Block Tracking for Debugging

```zig
pub const DebugBlockInfo = struct {
    // Original bytecode info
    original_pc_start: u32,
    original_pc_end: u32,
    original_opcodes: []const u8,

    // Optimized execution info
    optimized_idx_start: usize,
    optimized_idx_end: usize,
    fused_operations: []const FusionInfo,

    // Comparison data
    gas_delta: i64,
    stack_operations: u32,

    // Complete after research
};
```

## 8. Performance Considerations

### 8.1 Cost of Block Boundary Detection

- Optimized mode: Minimal (precomputed)
- Minimal mode: Runtime cost for bitmap checks

### 8.2 Memory Overhead of Tracking Info

- Metadata storage varies by platform (inline vs pointer)
- Dense PC mapping arrays for fast lookups

### 8.3 Cache Impact of Metadata Access

- 64-bit systems: Better cache locality with inline metadata
- 32-bit systems: Potential cache misses for pointer dereferences

### 8.4 Branch Prediction for Block Transitions

- Predictable patterns for common control flow
- Potential misprediction penalties for dynamic jumps

## 9. Block Comparison Strategy

For dual-execution validation:

1. Identify corresponding blocks in both modes
2. Capture state at block boundaries
3. Compare gas, stack, memory, storage
4. Report divergences with context

## 10. Implementation Recommendations

### 10.1 Create BlockTracker Type

Implement the BlockTracker structure with minimal overhead for tracking executed blocks.

### 10.2 Add Block Entry/Exit Detection

Implement detection mechanisms for both optimized and minimal modes.

### 10.3 Implement State Capture

Capture gas, stack, memory, and storage state at block boundaries.

### 10.4 Create Block History Tracking

Maintain a history of executed blocks for debugging and validation.

### 10.5 Add Block Metadata Extraction

Implement functions to extract metadata from both execution modes.

### 10.6 Create Visualization Helpers

Develop tools for visualizing block execution flow.

### 10.7 Comprehensive Block Transition Tests

Create tests that validate all block transition scenarios.

## 11. Research Questions Answered

### 11.1 How to efficiently map PC to block start?

- Use dense PC-to-instruction index mapping in optimized mode
- Use precomputed bitmaps in minimal mode

### 11.2 Can we detect blocks without metadata in minimal mode?

Yes, through runtime bitmap analysis of `is_jumpdest`.

### 11.3 What's the cost of runtime block detection?

Minimal in optimized mode (precomputed), moderate in minimal mode (bitmap checks).

### 11.4 How to handle dynamic jumps?

Through the jump table mechanism that maps PC to instruction indices.

### 11.5 Should block info be cached?

Yes, for performance in repeated executions, but with proper invalidation.

## 12. Required Research Areas Documented

All required areas have been documented with code references:

- JUMPDEST handler implementation in `frame.zig`
- Block metadata encoding/decoding in `plan.zig`
- Jump table construction in `planner.zig`
- PC validation logic in `plan_minimal.zig`
- Gas calculation per block in `opcode_data.zig` and `gas_constants.zig`

## 13. Test Requirements

```zig
test "Block tracking captures all transitions" {
    // Multi-block bytecode samples
    // Nested call tracking
    // Exception handling blocks
    // Gas consumption per block
}
```

## 14. Next Steps

1. Implement the BlockTracker structure
2. Add block entry/exit detection for both modes
3. Implement state capture mechanisms
4. Create comprehensive tests
5. Measure and optimize performance
6. Implement debugging and visualization tools
