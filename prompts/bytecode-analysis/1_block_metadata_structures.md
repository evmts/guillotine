# Task 1: Create Block Metadata Structures

<context>
You are implementing block-based execution optimization for the Guillotine EVM. This is the first task in a series to batch gas and stack validation per basic block instead of per instruction, achieving 20-30% performance improvement.

<current_architecture>
- Guillotine uses BitVec64 for O(1) jump validation
- CodeAnalysis struct holds bytecode analysis results
- Analysis is cached by code hash in an LRU cache
- Current validation happens per instruction
</current_architecture>

<evmone_reference>
EVMOne uses these exact structures for 2-3x speedup:
- BlockInfo: 8 bytes packed struct in union
- AdvancedCodeAnalysis: Contains block metadata arrays
- BlockAnalysis: Temporary struct during analysis
Key insight: 8-byte BlockInfo fits in CPU register for atomic loads
</evmone_reference>

<goal>
Add the foundational data structures needed for block-based execution without breaking existing functionality.
</goal>
</context>

<task>
<objective>
Create BlockMetadata struct and enhance CodeAnalysis to support block-based execution.
</objective>

<requirements>
1. Create a BlockMetadata packed struct (exactly 8 bytes)
2. Add block-related fields to CodeAnalysis struct
3. Ensure backward compatibility - existing code must continue working
4. Follow Guillotine's coding standards (see CLAUDE.md)
</requirements>

<specifications>
<BlockMetadata>
```zig
// Must be exactly 8 bytes for cache efficiency and atomic loads
pub const BlockMetadata = packed struct {
    gas_cost: u32,      // Total gas for block (4 bytes)
    stack_req: i16,     // Min stack items needed (2 bytes)  
    stack_max: i16,     // Max stack growth (2 bytes)
};

// Debug assertions for safety
comptime {
    std.debug.assert(@sizeOf(BlockMetadata) == 8);
    std.debug.assert(@alignOf(BlockMetadata) >= 4); // Ensure proper alignment
    
    // Verify field offsets match EVMOne layout
    std.debug.assert(@offsetOf(BlockMetadata, "gas_cost") == 0);
    std.debug.assert(@offsetOf(BlockMetadata, "stack_req") == 4);
    std.debug.assert(@offsetOf(BlockMetadata, "stack_max") == 6);
}
```
- Use packed struct to ensure 8-byte size (matches EVMOne BlockInfo)
- Fields must support typical EVM ranges (gas up to 4B, stack -1024 to +1024)
- Proper alignment ensures atomic loads on all architectures
</BlockMetadata>

<CodeAnalysisEnhancements>
Add these fields to the existing CodeAnalysis struct in `src/evm/frame/code_analysis.zig`:
```zig
// NEW fields to add:
block_starts: BitVec64,           // Bit vector marking block boundaries
block_metadata: []BlockMetadata,  // Array of block metadata
pc_to_block: []u16,              // Maps PC to block index
block_count: u16,                // Total number of blocks
```
</CodeAnalysisEnhancements>

<implementation_details>
1. Place BlockMetadata in code_analysis.zig before CodeAnalysis
2. Add fields to CodeAnalysis maintaining field order (hot fields first)
3. Update deinit() to free new allocations with proper null checks:
   ```zig
   pub fn deinit(self: *CodeAnalysis, allocator: std.mem.Allocator) void {
       // Existing deallocations
       self.code_segments.deinit(allocator);
       self.jumpdest_bitmap.deinit(allocator);
       if (self.block_gas_costs) |costs| {
           allocator.free(costs);
       }
       
       // NEW: Free block-related allocations
       if (self.block_metadata.len > 0) {
           allocator.free(self.block_metadata);
       }
       if (self.pc_to_block.len > 0) {
           allocator.free(self.pc_to_block);
       }
       self.block_starts.deinit(allocator);
       
       // Memory best practice: zero out pointers after free
       self.* = undefined;
   }
   ```
4. Initialize new fields to safe defaults in analyze_code:
   ```zig
   analysis.block_starts = BitVec64.init(allocator, 0) catch BitVec64{};
   analysis.block_metadata = &[_]BlockMetadata{};
   analysis.pc_to_block = &[_]u16{};
   analysis.block_count = 0;
   ```
</implementation_details>
</specifications>

<testing>
Create comprehensive tests in code_analysis.zig:
```zig
test "BlockMetadata is exactly 8 bytes and properly aligned" {
    try std.testing.expectEqual(8, @sizeOf(BlockMetadata));
    try std.testing.expect(@alignOf(BlockMetadata) >= 4);
    
    // Test field access
    const block = BlockMetadata{ .gas_cost = 100, .stack_req = -5, .stack_max = 10 };
    try std.testing.expectEqual(@as(u32, 100), block.gas_cost);
    try std.testing.expectEqual(@as(i16, -5), block.stack_req);
    try std.testing.expectEqual(@as(i16, 10), block.stack_max);
}

test "BlockMetadata handles extreme values" {
    // Test maximum values
    const max_block = BlockMetadata{
        .gas_cost = std.math.maxInt(u32),
        .stack_req = std.math.maxInt(i16),
        .stack_max = std.math.maxInt(i16),
    };
    try std.testing.expectEqual(@as(u32, 4_294_967_295), max_block.gas_cost);
    
    // Test minimum values
    const min_block = BlockMetadata{
        .gas_cost = 0,
        .stack_req = std.math.minInt(i16),
        .stack_max = std.math.minInt(i16),
    };
    try std.testing.expectEqual(@as(i16, -32768), min_block.stack_req);
}

test "CodeAnalysis with block data initializes and deinits correctly" {
    const allocator = std.testing.allocator;
    
    var analysis = CodeAnalysis{
        .code_segments = try BitVec64.init(allocator, 100),
        .jumpdest_bitmap = try BitVec64.init(allocator, 100),
        .block_starts = try BitVec64.init(allocator, 100),
        .block_metadata = try allocator.alloc(BlockMetadata, 10),
        .pc_to_block = try allocator.alloc(u16, 100),
        .block_count = 10,
        .max_stack_depth = 0,
        .has_dynamic_jumps = false,
        .has_static_jumps = false,
        .has_selfdestruct = false,
        .has_create = false,
        .block_gas_costs = null,
    };
    defer analysis.deinit(allocator);
    
    // Verify fields are accessible
    try std.testing.expectEqual(@as(u16, 10), analysis.block_count);
    try std.testing.expectEqual(@as(usize, 10), analysis.block_metadata.len);
    try std.testing.expectEqual(@as(usize, 100), analysis.pc_to_block.len);
    
    // Test pc_to_block mapping
    analysis.pc_to_block[50] = 5;
    try std.testing.expectEqual(@as(u16, 5), analysis.pc_to_block[50]);
}

test "CodeAnalysis deinit handles partially initialized state" {
    const allocator = std.testing.allocator;
    
    // Test with empty block data
    var analysis = CodeAnalysis{
        .code_segments = try BitVec64.init(allocator, 10),
        .jumpdest_bitmap = try BitVec64.init(allocator, 10),
        .block_starts = BitVec64{}, // Empty
        .block_metadata = &[_]BlockMetadata{},
        .pc_to_block = &[_]u16{},
        .block_count = 0,
        .max_stack_depth = 0,
        .has_dynamic_jumps = false,
        .has_static_jumps = false,
        .has_selfdestruct = false,
        .has_create = false,
        .block_gas_costs = null,
    };
    
    // Should not crash on deinit
    analysis.deinit(allocator);
}
```
</testing>

<benchmarking>
Add benchmark using zbench to measure struct access performance:
```zig
const zbench = @import("zbench");

fn benchmarkBlockMetadataAccess(b: *zbench.Benchmark) void {
    const blocks = [_]BlockMetadata{
        .{ .gas_cost = 100, .stack_req = 2, .stack_max = 3 },
        .{ .gas_cost = 200, .stack_req = 1, .stack_max = 2 },
        .{ .gas_cost = 300, .stack_req = 3, .stack_max = 5 },
    };
    
    var total_gas: u64 = 0;
    b.run(for (0..b.iterations) |_| {
        for (blocks) |block| {
            total_gas += block.gas_cost;
            _ = block.stack_req;
            _ = block.stack_max;
        }
    });
    
    std.mem.doNotOptimizeAway(total_gas);
}
```
</benchmarking>

<validation>
After implementation, run:
```bash
zig build test
```
Ensure all existing tests pass - we haven't changed any behavior yet.
</validation>
</task>

<success_criteria>
- [ ] BlockMetadata struct compiles and is exactly 8 bytes
- [ ] CodeAnalysis has new block-related fields
- [ ] deinit() properly frees new allocations
- [ ] All existing tests continue to pass
- [ ] New tests for block structures pass
</success_criteria>