# Bytecode Preprocessor

Advanced bytecode preprocessing and optimization system for maximizing EVM execution performance through dispatch optimization, instruction fusion patterns, and jump table generation with static resolution.

## Overview

The preprocessor module transforms raw EVM bytecode into highly optimized dispatch schedules, enabling Guillotine to achieve superior performance through compile-time analysis and runtime optimization. It implements sophisticated bytecode analysis, instruction fusion with 15+ synthetic opcodes, static jump resolution, and efficient dispatch table generation.

## Components

### Core Processing

- **`dispatch.zig`** - Main dispatch schedule generation with 15+ fusion patterns and static jump resolution
- **`dispatch_metadata.zig`** - Packed metadata structures for dispatch optimization (64-bit aligned)
- **`dispatch_opcode_data.zig`** - Comptime opcode-specific data extraction with type safety
- **`dispatch_test.zig`** - Comprehensive testing suite for dispatch functionality

### Specialized Modules

- **`dispatch_jump_table.zig`** - Binary search jump table with interpolated starting points
- **`dispatch_jump_table_builder.zig`** - Builder pattern for jump table construction
- **`dispatch_pretty_print.zig`** - Human-readable dispatch schedule visualization with ANSI colors
- **`dispatch_allocated_memory.zig`** - Memory allocation tracking for dispatch items
- **`dispatch_item.zig`** - 64-bit dispatch item union definitions

## Features

### Bytecode Analysis

- **Single-pass parsing** - Complete bytecode analysis with opcode recognition and validation
- **Jump destination mapping** - Binary-searchable JUMPDEST location tracking with PC indexing
- **Basic block analysis** - First block gas calculation for immediate execution optimization
- **Pattern recognition** - Identifies 8+ high-impact fusion patterns automatically

### Instruction Fusion (15+ Synthetic Opcodes)

- **Arithmetic fusion** - PUSH+ADD/MUL/SUB/DIV with inline/pointer value storage
- **Bitwise fusion** - PUSH+AND/OR/XOR optimizations for common patterns
- **Memory fusion** - PUSH+MLOAD/MSTORE/MSTORE8 with static offset optimization
- **Static jump resolution** - Direct dispatch pointer jumps bypassing binary search
- **Multi-operation fusion** - Advanced patterns: MULTI_PUSH, DUP3_ADD_MSTORE, FUNCTION_DISPATCH
- **Control flow optimization** - ISZERO_JUMPI, CALLVALUE_CHECK, PUSH0_REVERT patterns

### Dispatch Optimization

- **O(1) dispatch** - Prebuilt schedule eliminates bytecode parsing during execution
- **Cache-friendly layout** - 64-bit aligned dispatch items for optimal memory access
- **Value deduplication** - Hash-based u256 storage with pointer metadata for large values
- **Inline optimization** - Small values (≤64-bit) stored directly in dispatch stream
- **Forward reference resolution** - Single-pass static jump resolution without backpatching

### Jump Table Generation

- **Binary search optimization** - Interpolated starting points reduce average search iterations
- **Static validation** - All jump destinations validated during preprocessing
- **Compact entries** - Direct dispatch pointers eliminate binary search for static jumps
- **Cache-optimized layout** - Sequential memory access patterns for dispatch items

## Usage Examples

### Basic Dispatch Generation

```zig
const std = @import("std");
const Dispatch = @import("dispatch.zig").Dispatch;
const Frame = @import("../frame/frame.zig").Frame;

pub fn createDispatch(allocator: std.mem.Allocator, bytecode: anytype) !Dispatch(Frame).DispatchSchedule {
    const opcode_handlers = &frame_handlers.OPCODE_HANDLERS;
    
    // Generate optimized dispatch schedule with fusion patterns
    const schedule = try Dispatch(Frame).init(
        allocator,
        bytecode,
        opcode_handlers,
    );
    
    return schedule; // Returns DispatchSchedule with items and u256_values
}
```

### Jump Table Creation

```zig
const DispatchType = Dispatch(Frame);

pub fn createJumpTable(
    allocator: std.mem.Allocator,
    schedule: []const DispatchType.Item,
    bytecode: anytype,
) !DispatchType.JumpTable {
    return try DispatchType.createJumpTable(
        allocator,
        schedule,
        bytecode,
    );
}
```

### Dispatch Execution

```zig
pub fn executeWithDispatch(
    frame: *Frame,
    dispatch_schedule: *const Dispatch(Frame).DispatchSchedule,
) !void {
    var dispatch = dispatch_schedule.getDispatch();
    
    // Execute first block gas optimization
    const first_block_gas = dispatch.getFirstBlockGas();
    try frame.gas.consume(first_block_gas.gas);
    
    while (true) {
        const item = dispatch.cursor[0];
        dispatch.cursor += 1;
        
        switch (item) {
            .opcode_handler => |handler| {
                try handler(frame, dispatch.cursor);
                // Handler is responsible for advancing cursor and termination
            },
            .jump_dest => |metadata| {
                // Apply basic block gas and stack validation
                try frame.gas.consume(metadata.gas);
                // Handlers can use unsafe operations after validation
            },
            .push_inline => |metadata| {
                try frame.stack.push_unsafe(@intCast(metadata.value));
                dispatch.cursor += 1;
            },
            .push_pointer => |metadata| {
                const value = dispatch_schedule.getU256Value(metadata.index);
                try frame.stack.push_unsafe(value);
                dispatch.cursor += 1;
            },
            .jump_static => |metadata| {
                // Direct jump to resolved dispatch location
                dispatch.cursor = @ptrCast(metadata.dispatch);
            },
        }
    }
}
```

### Instruction Fusion

```zig
// Example of PUSH + ADD fusion with value deduplication using U256Storage
const OpcodeSynthetic = @import("../opcodes/opcode_synthetic.zig").OpcodeSynthetic;

fn handleFusionOperation(
    self: *Self,
    allocator: std.mem.Allocator,
    value: u256,
    next_opcode: u8,
) !void {
    // Determine synthetic opcode based on next instruction
    const synthetic_opcode: OpcodeSynthetic = switch (next_opcode) {
        0x01 => OpcodeSynthetic.PUSH_ADD_INLINE, // or PUSH_ADD_POINTER
        0x02 => OpcodeSynthetic.PUSH_MUL_INLINE, // or PUSH_MUL_POINTER
        0x03 => OpcodeSynthetic.PUSH_SUB_INLINE, // or PUSH_SUB_POINTER
        0x04 => OpcodeSynthetic.PUSH_DIV_INLINE, // or PUSH_DIV_POINTER
        0x16 => OpcodeSynthetic.PUSH_AND_INLINE, // or PUSH_AND_POINTER
        0x17 => OpcodeSynthetic.PUSH_OR_INLINE,  // or PUSH_OR_POINTER
        0x18 => OpcodeSynthetic.PUSH_XOR_INLINE, // or PUSH_XOR_POINTER
        else => return, // No fusion available
    };
    
    // Use U256Storage for value deduplication
    if (value <= std.math.maxInt(u64)) {
        // Small values: use inline variant
        const handler = self.getSyntheticHandler(@intFromEnum(synthetic_opcode));
        try self.schedule_items.append(.{ .opcode_handler = handler });
        try self.schedule_items.append(.{ 
            .push_inline = .{ .value = @intCast(value) }
        });
    } else {
        // Large values: use pointer variant with deduplication
        const pointer_opcode = @intFromEnum(synthetic_opcode) + 1; // _POINTER variant
        const handler = self.getSyntheticHandler(pointer_opcode);
        try self.schedule_items.append(.{ .opcode_handler = handler });
        
        // Deduplicate via U256Storage hash map
        const value_index = try self.u256_storage.getOrPut(allocator, value);
        try self.schedule_items.append(.{ 
            .push_pointer = .{ .index = value_index }
        });
    }
}
```

### Gas Cost Optimization

```zig
pub fn calculateFirstBlockGas(bytecode: []const u8) u64 {
    var gas: u64 = 0;
    var iter = bytecode.createIterator();
    const opcode_info = @import("../opcodes/opcode_data.zig").OPCODE_INFO;
    
    while (iter.next()) |op_data| {
        switch (op_data) {
            .regular => |data| {
                const gas_cost = opcode_info[data.opcode].gas_cost;
                gas = std.math.add(u64, gas, gas_cost) catch gas;
                
                // Stop at control flow instructions
                switch (data.opcode) {
                    0x56, 0x57, 0x00, 0xf3, 0xfd, 0xfe, 0xff => return gas,
                    else => {},
                }
            },
            .push => |data| {
                const push_opcode = 0x60 + data.size - 1;
                const gas_cost = opcode_info[push_opcode].gas_cost;
                gas = std.math.add(u64, gas, gas_cost) catch gas;
            },
            .jumpdest => return gas,
            else => gas += 6, // Default cost
        }
    }
    
    return gas;
}
```

## API Reference

### Dispatch Types

#### Main Dispatch

```zig
pub fn Dispatch(comptime FrameType: type) type {
    return struct {
        cursor: [*]const Item,
        
        pub const Item = union(enum) {
            opcode_handler: OpcodeHandler,
            jump_dest: JumpDestMetadata,
            push_inline: PushInlineMetadata,
            push_pointer: PushPointerMetadata,
            pc: PcMetadata,
            jump_static: JumpStaticMetadata,
            first_block_gas: FirstBlockMetadata,
        };
    };
}
```

#### Metadata Types

- `JumpDestMetadata` - Jump destination information and gas costs
- `PushInlineMetadata` - Small values embedded directly in dispatch
- `PushPointerMetadata` - Large values stored as heap pointers
- `PcMetadata` - Program counter values for PC instruction
- `JumpStaticMetadata` - Static jump destination pointers

### Core Functions

- `init()` - Create optimized dispatch schedule from bytecode
- `createJumpTable()` - Generate jump table for efficient JUMPDEST lookup
- `calculateFirstBlockGas()` - Compute gas cost for initial execution block
- `getOpData()` - Extract opcode-specific data from dispatch cursor

### Optimization Features

#### Instruction Fusion Types

- `push_add_fusion` - PUSH followed by ADD
- `push_mul_fusion` - PUSH followed by MUL
- `push_sub_fusion` - PUSH followed by SUB
- `push_div_fusion` - PUSH followed by DIV
- `push_and_fusion` - PUSH followed by AND
- `push_or_fusion` - PUSH followed by OR
- `push_xor_fusion` - PUSH followed by XOR
- `push_jump_fusion` - PUSH followed by JUMP (static jumps)
- `push_jumpi_fusion` - PUSH followed by JUMPI (conditional static jumps)

## Important Considerations

### Memory Management

- **Pointer ownership** - Push pointer metadata owns heap-allocated values
- **Cleanup responsibility** - Caller must free dispatch schedule memory
- **Value lifetime** - Pointer values must outlive dispatch schedule usage
- **Allocation tracking** - Optional memory allocation tracking for debugging

### Performance Optimization

- **Single-pass analysis** - Bytecode is analyzed only once during preprocessing
- **Cache-friendly access** - Sequential memory access patterns for dispatch
- **Minimal overhead** - Optimized for high-frequency execution paths
- **Static resolution** - Maximum resolution at preprocessing time

### Validation and Safety

- **Jump validation** - All jump destinations are validated during preprocessing
- **Gas calculation accuracy** - Precise gas cost computation prevents underflow
- **Error propagation** - Preprocessing errors are properly propagated
- **Runtime safety** - Invalid operations result in proper error handling

### Advanced Features

- **Forward reference resolution** - Handles forward jumps without second pass
- **Fusion pattern recognition** - Automatic detection of fusable instruction patterns
- **Binary search optimization** - Efficient jump table lookup implementation
- **Pretty printing** - Human-readable dispatch schedule visualization

## Testing and Validation

The preprocessor includes extensive tests covering:

- **Unit tests** - Individual component functionality
- **Integration tests** - End-to-end bytecode processing
- **Fuzzing tests** - Robustness against malformed bytecode
- **Performance benchmarks** - Optimization effectiveness measurement

## Development Workflow

1. **Parse** - Analyze raw bytecode structure and opcodes
2. **Optimize** - Apply instruction fusion and static analysis
3. **Generate** - Create optimized dispatch schedule
4. **Validate** - Verify jump destinations and gas calculations
5. **Execute** - Use preprocessed schedule for high-performance execution

The preprocessor is a critical component enabling Guillotine's exceptional performance, transforming bytecode analysis from a runtime cost to a one-time preprocessing step that enables optimal execution performance.
