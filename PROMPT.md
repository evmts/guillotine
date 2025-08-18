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
pub fn calculate_allocation(bytecode_size: usize) struct {
    size: usize,
    can_grow: bool,
} {
    // Calculate based on bytecode size
}
```

Components to update:
- `stack.zig` - Fixed size (always 32KB for 1024 elements)
- `analysis2.zig` - Variable based on bytecode (inst_to_pc, pc_to_inst arrays)
- Metadata array - Variable based on bytecode
- Ops array - Variable based on bytecode

### 2. StackFrame Pre-allocation

Update `StackFrame.init` to:
1. Accept bytecode size as parameter
2. Call each component's `calculate_allocation` function
3. Allocate a single static buffer for all non-growable components
4. Use a FixedBufferAllocator to sub-allocate from this buffer
5. Pass pre-allocated slices to component constructors

### 3. Memory.zig Special Handling

Since Memory can grow dynamically:
1. Remove it from the static buffer allocation
2. Let it manage its own memory using the heap allocator
3. Use its `calculate_allocation` to set initial capacity
4. Add clear documentation explaining why Memory is handled separately

### 4. Refactor interpret2.zig

Remove all allocation logic from interpret2:
1. Remove the static buffer and FixedBufferAllocator
2. Remove the call to `analysis2.prepare`
3. Add `std.debug.assert` verifying that analysis has been prepared
4. Assume all data structures are pre-allocated and passed in via StackFrame

### 5. Update call2.zig

Move allocation and preparation to call2:
1. Calculate bytecode size before creating StackFrame
2. Call `analysis2.prepare` with pre-allocated buffers
3. Pass prepared analysis, metadata, and ops to StackFrame.init
4. Handle all allocation before calling interpret2

### 6. Update analysis2.zig

Refactor to accept pre-allocated buffers:
1. Change `prepare` to accept pre-allocated slices as arguments
2. Remove all internal allocations
3. Add `std.debug.assert` verifying buffer sizes match expectations
4. Return error if buffers are too small

## Debug Assertions

Add debug assertions throughout to verify correctness:

```zig
// In interpret2.zig
std.debug.assert(frame.analysis.inst_to_pc.len > 0); // Analysis was prepared
std.debug.assert(frame.ops.len > 0); // Ops array was populated

// In analysis2.zig prepare function
std.debug.assert(inst_to_pc_buffer.len >= expected_size);
std.debug.assert(pc_to_inst_buffer.len >= bytecode.len);
```

These assertions:
- Perform hard checks in debug mode
- Become undefined behavior in release mode (no overhead)
- Document invariants and catch bugs early

## Tiered Allocation Strategy

Support these bytecode size tiers:
- 4KB - Small contracts
- 8KB - Medium contracts
- 16KB - Large contracts (like Snailtracer)
- 32KB - Very large contracts
- 64KB - Maximum supported

StackFrame.init should:
1. Check bytecode size
2. Select the next highest tier
3. Allocate buffer for that tier size
4. Use the buffer efficiently for all components

## Benefits

1. **Single allocation per frame** - Better performance
2. **Predictable memory usage** - Known upfront costs
3. **Better cache locality** - All data in contiguous memory
4. **No allocation during execution** - All memory pre-allocated
5. **Clear ownership model** - StackFrame owns the buffer

## Migration Path

1. Add allocation functions to each component (keep existing init functions)
2. Update StackFrame to pre-allocate
3. Update call2.zig to prepare analysis
4. Update interpret2.zig to remove allocations
5. Update component init functions to accept pre-allocated buffers
6. Add comprehensive tests for each tier

---

## AMENDMENT (Based on Implementation Experience)

### What Was Accomplished

1. **Component Allocation Functions** ✅
   - Stack: Added `calculate_allocation()` returning fixed 32KB
   - Analysis2: Added separate functions for analysis, metadata, and ops arrays
   - Created unified `AllocationInfo` struct with size, alignment, and can_grow fields

2. **Allocation Tier System** ✅
   - Created `allocation_tier.zig` with 5 tiers (4KB to 64KB)
   - Implemented `select_tier()` and `buffer_size()` methods
   - Added alignment calculations for proper memory layout

3. **StackFrame Buffer Management** ✅
   - Added `static_buffer` and `buffer_allocator` fields
   - Created `init_with_bytecode_size()` method
   - Maintained backward compatibility with original `init()`
   - Added `get_buffer_allocator()` for external access

4. **Pre-allocated Prepare Function** ✅
   - Created `prepare_with_buffers()` in analysis2.zig
   - Accepts pre-allocated slices instead of allocating internally
   - Maintains fusion logic from original implementation

### Key Learnings and Design Changes

1. **AllocationInfo Structure**
   - Original prompt suggested simple `{size, can_grow}` struct
   - Reality: Need alignment information for proper memory layout
   - Solution: Added `alignment` field with sensible defaults

2. **FixedBufferAllocator Management**
   - Issue: FBA is a value type that gets modified during allocation
   - Solution: Store as pointer (`*std.heap.FixedBufferAllocator`) in StackFrame
   - Properly allocate/deallocate the FBA itself

3. **Compatibility Strategy**
   - Keep original methods for gradual migration
   - New methods have explicit names (`init_with_bytecode_size`, `prepare_with_buffers`)
   - Legacy paths still work during transition

4. **Import Path Issues**
   - Some modules have circular dependencies or incorrect relative imports
   - Need to be careful about module boundaries
   - May need to reorganize some imports as part of cleanup

### What the Original Prompt Should Have Included

1. **Concrete Types**
   ```zig
   pub const AllocationInfo = struct {
       size: usize,
       alignment: usize = 8,
       can_grow: bool = false,
   };
   ```

2. **Alignment Considerations**
   - Different types need different alignments (u256 needs 32-byte alignment)
   - Buffer allocator must handle alignment properly
   - Include alignment helper functions

3. **Error Handling**
   - Define specific error types for allocation failures
   - Handle buffer size verification with proper errors
   - Use debug assertions for development, but have production error paths

4. **Testing Strategy Details**
   - Test each component's allocation function independently
   - Test tier selection with boundary conditions
   - Verify alignment is maintained in allocated buffers

### Remaining Work

1. **Update Stack.init** 🔄
   - Create `init_with_buffer()` accepting pre-allocated memory
   - Ensure proper handling of buffer vs heap allocation in deinit

2. **Update call2.zig** 🔄
   - Use `StackFrame.init_with_bytecode_size()` instead of `init()`
   - Call `prepare_with_buffers()` using frame's buffer allocator
   - Remove empty analysis/metadata/ops initialization

3. **Clean up interpret2.zig** 🔄
   - Remove static buffer and FBA
   - Remove call to `prepare()`
   - Add assertion that analysis is pre-prepared
   - Use frame's pre-allocated data

4. **Fix Import Issues** 🔄
   - Resolve circular dependencies
   - Fix relative import paths
   - Ensure all modules can access needed types

5. **Comprehensive Testing** 🔄
   - Test with real contracts of various sizes
   - Benchmark allocation performance
   - Verify no memory leaks with valgrind
   - Test error paths and edge cases

### Performance Expectations (Refined)

- **Memory usage**: Reduced by ~50-90% for small contracts (4KB vs 1MB)
- **Allocation overhead**: Single allocation vs 5-10 allocations per frame
- **Cache locality**: All frame data in contiguous memory block
- **Predictability**: Allocation size known before execution begins
- **Fragmentation**: Eliminated for frame-local allocations

### Gotchas Discovered

1. **FBA Lifetime**: FixedBufferAllocator must outlive all allocations from it
2. **Alignment Math**: Must align each sub-allocation properly within buffer
3. **Buffer Ownership**: Clear ownership model prevents use-after-free
4. **Test Isolation**: Some tests assume specific memory layouts
5. **Conditional Compilation**: Debug assertions affect struct sizes

### Recommended Next Steps

1. Fix the import path issues first (blocking tests)
2. Update Stack to support pre-allocated buffers
3. Modify call2.zig to use new initialization
4. Clean up interpret2.zig
5. Run comprehensive tests with real contracts
6. Benchmark before/after to verify improvements