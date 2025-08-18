# Memory Pre-allocation Refactoring Progress

## Completed Tasks

### 1. ✅ Baseline Testing
- Created `failingtests.md` documenting all pre-existing test failures
- Identified 8 compilation error groups and 14 runtime test failures

### 2. ✅ Component Allocation Functions
- **stack.zig**: Added `calculate_allocation()` function with tests
  - Returns fixed 32KB allocation regardless of bytecode size
  - Added `AllocationInfo` struct for size/alignment/growth properties
  
- **analysis2.zig**: Added allocation calculation functions
  - `calculate_analysis_allocation()` - for inst_to_pc and pc_to_inst arrays
  - `calculate_metadata_allocation()` - for metadata array
  - `calculate_ops_allocation()` - for function pointer array
  - All functions calculate based on bytecode size

### 3. ✅ Allocation Tier System
- Created `allocation_tier.zig` with tiered allocation strategy
  - 5 tiers: tiny (4KB), small (8KB), medium (16KB), large (32KB), huge (64KB)
  - `select_tier()` chooses appropriate tier based on bytecode size
  - `buffer_size()` calculates total buffer needed including alignment
  - Comprehensive tests for tier selection and buffer sizing

### 4. ✅ StackFrame Buffer Management
- Updated `StackFrame` struct to include:
  - `static_buffer: []u8` - the pre-allocated buffer
  - `buffer_allocator: *std.heap.FixedBufferAllocator` - manages sub-allocations
  
- Added new initialization method:
  - `init_with_bytecode_size()` - allocates tiered buffer based on bytecode
  - Keeps original `init()` for compatibility
  
- Updated `deinit()` to properly free buffer and FBA
- Added `get_buffer_allocator()` for external access

### 5. ✅ Prepare with Pre-allocated Buffers
- Created `prepare_with_buffers()` in analysis2.zig
  - Accepts pre-allocated slices instead of allocating internally
  - Includes debug assertions to verify buffer sizes
  - Returns trimmed slices with actual data
  - Maintains fusion logic from original prepare()

## Remaining Tasks

### 6. 🔄 Update Stack.init
- Need to create `init_with_buffer()` that accepts pre-allocated memory
- Keep original `init()` for compatibility

### 7. 🔄 Update call2.zig
- Modify to use `StackFrame.init_with_bytecode_size()`
- Call `prepare_with_buffers()` using frame's buffer allocator
- Pass prepared data to interpret2

### 8. 🔄 Clean up interpret2.zig
- Remove static buffer allocation
- Remove call to `prepare()`
- Add assertions that data is pre-prepared
- Use frame's pre-allocated data

### 9. 🔄 Add Debug Assertions
- Verify buffer sizes throughout
- Check alignment requirements
- Validate successful allocations

### 10. 🔄 Comprehensive Testing
- Test each allocation tier
- Verify no memory leaks
- Benchmark allocation performance
- Test with real contracts (Snailtracer, etc.)

## Key Design Decisions Made

1. **Memory.zig remains separate** - As the only growable component, it continues using heap allocation
2. **Tiered approach** - Avoids allocating 1MB for every frame when most contracts are small
3. **Buffer ownership** - StackFrame owns the buffer and FBA for its lifetime
4. **Compatibility maintained** - Original init methods preserved for gradual migration
5. **Pre-allocation in call sites** - Moves allocation logic upstream for better control

## Import Issues to Fix

- `tailcalls.zig` has incorrect import path for StackFrame
- Some tests may need updating for new struct fields

## Performance Expectations

- Single allocation per frame instead of multiple scattered allocations
- Better cache locality with contiguous memory
- Reduced allocator overhead
- Predictable memory usage based on bytecode size
- No allocations during opcode execution