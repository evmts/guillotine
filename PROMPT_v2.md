# EVM Memory Pre-allocation Refactoring

## Overview

Refactor the EVM to use a tiered, upfront allocation strategy where StackFrame owns a single static buffer for all non-growable allocations. This eliminates scattered allocations and improves performance through better cache locality.

## Key Design Principles

1. **Size-based allocation tiers**: Components export functions that calculate allocation needs based on bytecode size
2. **StackFrame ownership**: StackFrame.init pre-allocates a single static buffer for all components
3. **Special case for growable memory**: Memory.zig remains separate as the only growable component
4. **Move allocation logic upstream**: Call sites (call2.zig) handle allocation, not implementations
5. **Zero internal allocations**: Components receive pre-allocated buffers as arguments

## Implementation Requirements

### 1. Component Allocation Functions

Each component that needs memory must export a function with this signature:

```zig
pub const AllocationInfo = struct {
    size: usize,
    alignment: usize = 8,  // Default 8-byte alignment
    can_grow: bool = false,
};

pub fn calculate_allocation(bytecode_size: usize) AllocationInfo {
    // Calculate based on bytecode size
}
```

Components to update:
- `stack.zig` - Fixed size (always 32KB for 1024 elements)
- `analysis2.zig` - Variable based on bytecode (inst_to_pc, pc_to_inst arrays)
- Metadata array - Variable based on bytecode
- Ops array - Variable based on bytecode

Example implementations:
```zig
// In stack.zig
pub fn calculate_allocation(bytecode_size: usize) AllocationInfo {
    _ = bytecode_size; // Stack size is fixed
    return .{
        .size = CAPACITY * @sizeOf(u256),
        .alignment = @alignOf(u256),
    };
}

// In analysis2.zig
pub fn calculate_allocation(bytecode_size: usize) AllocationInfo {
    // Worst case: every byte is an instruction
    const max_instructions = bytecode_size;
    return .{
        .size = max_instructions * @sizeOf(u16) * 2, // inst_to_pc + pc_to_inst
        .alignment = @alignOf(u16),
    };
}
```

### 2. Tiered Allocation Strategy

Define allocation tiers to minimize waste:

```zig
pub const AllocationTier = enum(u32) {
    tiny = 4 * 1024,      // 4KB contracts
    small = 8 * 1024,     // 8KB contracts  
    medium = 16 * 1024,   // 16KB contracts (Snailtracer size)
    large = 32 * 1024,    // 32KB contracts
    huge = 64 * 1024,     // 64KB contracts (theoretical max)

    pub fn select_tier(bytecode_size: usize) AllocationTier {
        if (bytecode_size <= 4096) return .tiny;
        if (bytecode_size <= 8192) return .small;
        if (bytecode_size <= 16384) return .medium;
        if (bytecode_size <= 32768) return .large;
        return .huge;
    }

    pub fn buffer_size(self: AllocationTier) usize {
        // Calculate total buffer needed for tier
        // This would sum up all component allocations for this bytecode size
        return switch (self) {
            .tiny => 128 * 1024,   // 128KB total
            .small => 256 * 1024,  // 256KB total
            .medium => 512 * 1024, // 512KB total
            .large => 768 * 1024,  // 768KB total
            .huge => 1536 * 1024,  // 1.5MB total
        };
    }
};
```

### 3. StackFrame Pre-allocation

Update `StackFrame` to include buffer management:

```zig
pub const StackFrame = struct {
    // ... existing fields ...
    
    // Buffer management
    static_buffer: []u8,
    buffer_allocator: std.heap.FixedBufferAllocator,
    
    pub fn init(
        bytecode_size: usize,
        gas_remaining: u64,
        contract_address: primitives.Address.Address,
        host: Host,
        state: DatabaseInterface,
        allocator: std.mem.Allocator,
    ) !StackFrame {
        // Select tier and allocate buffer
        const tier = AllocationTier.select_tier(bytecode_size);
        const buffer_size = tier.buffer_size();
        
        const static_buffer = try allocator.alloc(u8, buffer_size);
        errdefer allocator.free(static_buffer);
        
        var fba = std.heap.FixedBufferAllocator.init(static_buffer);
        const fba_allocator = fba.allocator();
        
        // Pre-allocate all components
        const stack = try Stack.init_with_buffer(fba_allocator);
        const memory = try Memory.init_default(allocator); // Uses heap allocator
        
        // ... allocate other components ...
        
        return StackFrame{
            .static_buffer = static_buffer,
            .buffer_allocator = fba,
            .stack = stack,
            .memory = memory,
            // ... other fields ...
        };
    }
    
    pub fn deinit(self: *StackFrame) void {
        // Components don't free their memory (owned by buffer)
        self.memory.deinit(); // Memory manages its own heap allocation
        self.allocator.free(self.static_buffer);
    }
};
```

### 4. Memory.zig Special Handling

Document why Memory is handled separately:

```zig
// In memory.zig
/// Memory is the ONLY component that can grow during execution.
/// It manages its own heap allocation separately from the StackFrame's
/// static buffer. This is because:
/// 1. Memory can expand dynamically based on MLOAD/MSTORE operations
/// 2. Memory expansion has specific gas costs that must be calculated
/// 3. Memory size is unbounded (up to gas limits)
/// 
/// All other components have fixed size determined by bytecode size.
pub fn calculate_allocation(bytecode_size: usize) AllocationInfo {
    _ = bytecode_size;
    return .{
        .size = INITIAL_CAPACITY, // Just initial size hint
        .can_grow = true,         // This is the key difference
    };
}
```

### 5. Analysis Refactoring

Update analysis2.zig to accept buffers:

```zig
pub fn prepare_with_buffers(
    inst_to_pc: []u16,
    pc_to_inst: []u16,
    metadata: []u32,
    ops: []*const anyopaque,
    code: []const u8,
) !struct {
    analysis: SimpleAnalysis,
    metadata: []u32,
    ops: []*const anyopaque,
} {
    // Verify buffer sizes
    std.debug.assert(pc_to_inst.len >= code.len);
    std.debug.assert(inst_to_pc.len >= count_instructions(code));
    
    // Fill buffers in-place
    // ... implementation ...
    
    return .{
        .analysis = SimpleAnalysis{
            .inst_to_pc = inst_to_pc[0..actual_inst_count],
            .pc_to_inst = pc_to_inst,
            .bytecode = code,
        },
        .metadata = metadata[0..actual_metadata_count],
        .ops = ops[0..actual_ops_count],
    };
}
```

### 6. Error Handling

Add proper error handling for allocation failures:

```zig
pub const AllocationError = error{
    BytecodeTooLarge,      // Exceeds 64KB limit
    InsufficientBuffer,    // Buffer too small (programming error)
    OutOfMemory,          // Heap allocation failed
};
```

### 7. Performance Considerations

1. **Alignment**: Ensure proper alignment for each component in the buffer
2. **Padding**: Add padding between allocations to prevent false sharing
3. **NUMA awareness**: Consider allocating buffer with huge pages if available

```zig
fn align_forward(addr: usize, alignment: usize) usize {
    return (addr + alignment - 1) & ~(alignment - 1);
}
```

### 8. Testing Strategy

Create comprehensive tests for each tier:

```zig
test "allocation tier selection" {
    try expectEqual(AllocationTier.tiny, AllocationTier.select_tier(1024));
    try expectEqual(AllocationTier.small, AllocationTier.select_tier(5000));
    try expectEqual(AllocationTier.medium, AllocationTier.select_tier(10000));
    try expectEqual(AllocationTier.large, AllocationTier.select_tier(20000));
    try expectEqual(AllocationTier.huge, AllocationTier.select_tier(50000));
}

test "buffer allocation for each tier" {
    // Test that each tier allocates sufficient space
    const test_cases = [_]struct { 
        bytecode_size: usize,
        tier: AllocationTier,
    }{
        .{ .bytecode_size = 1000, .tier = .tiny },
        .{ .bytecode_size = 5000, .tier = .small },
        // ... more cases
    };
    
    for (test_cases) |tc| {
        var frame = try StackFrame.init(tc.bytecode_size, ...);
        defer frame.deinit();
        
        // Verify allocations succeeded
        try expect(frame.stack.data != null);
        try expect(frame.analysis.inst_to_pc.len > 0);
    }
}
```

### 9. Migration Checklist

- [ ] Add `calculate_allocation` to stack.zig
- [ ] Add `calculate_allocation` to analysis2.zig  
- [ ] Create `AllocationTier` enum with size mappings
- [ ] Update StackFrame to manage static buffer
- [ ] Update Stack.init to accept pre-allocated buffer
- [ ] Create `prepare_with_buffers` in analysis2.zig
- [ ] Update call2.zig to call prepare before creating frame
- [ ] Remove allocations from interpret2.zig
- [ ] Add debug assertions throughout
- [ ] Create tests for each tier
- [ ] Benchmark allocation performance
- [ ] Document Memory.zig special handling

## Benefits

1. **Single allocation per frame** - Better performance
2. **Predictable memory usage** - Known upfront costs
3. **Better cache locality** - All data in contiguous memory
4. **No allocation during execution** - All memory pre-allocated
5. **Clear ownership model** - StackFrame owns the buffer
6. **Reduced fragmentation** - Single large allocation vs many small ones
7. **Easier to track memory usage** - One place to measure

## Potential Future Optimizations

1. **Buffer pooling**: Reuse allocated buffers across frames
2. **NUMA-aware allocation**: Pin buffers to CPU nodes
3. **Huge pages**: Use 2MB pages for large allocations
4. **Custom allocator**: Skip general allocator overhead
5. **Compile-time tiers**: Use comptime to generate optimal tier sizes