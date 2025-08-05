# Task 2: Implement Block Analysis Algorithm

<context>
You are implementing the core block analysis algorithm that identifies basic blocks in EVM bytecode. This builds on Task 1 where BlockMetadata and CodeAnalysis structures were added.

<prerequisites>
- Task 1 completed: BlockMetadata struct and enhanced CodeAnalysis exist
- Understanding of EVM basic blocks: sequences of instructions ending with JUMP, JUMPI, STOP, RETURN, REVERT, or JUMPDEST
</prerequisites>

<existing_code>
- Contract.analyze_code() in contract.zig performs current analysis
- BitVec64.codeBitmap() identifies code vs data bytes
- JUMPDEST positions are already being found
- operation_config.OPERATIONS[] provides gas costs and stack requirements
- stack_height_changes.get_stack_height_change() gives net stack effect
</existing_code>

<evmone_insights>
EVMOne's algorithm key points:
1. JUMPDEST always starts new block (even if previous was terminating)
2. JUMPI creates block at current position (not after)
3. Dead code elimination: skip bytes after terminating ops until JUMPDEST
4. Pre-allocation: reserve code.size() + 2 to avoid reallocation
5. Stack tracking resets at each block boundary

Corner cases from EVMOne:
- Empty code gets BEGINBLOCK + STOP (2 instructions)
- JUMPI at end of code doesn't crash
- Multiple consecutive JUMPDESTs each create new blocks
- PUSH without enough data bytes handled gracefully
- Unreachable code after STOP/RETURN/REVERT is skipped
- Stack requirements can be negative (block produces more than consumes)
</evmone_insights>
</context>

<task>
<objective>
Implement analyzeBlocks function that identifies basic blocks and computes their metadata.
</objective>

<algorithm_overview>

1. Single pass through bytecode
2. Track current block's gas cost and stack requirements
3. Create new block at: JUMP, JUMPI, STOP, RETURN, REVERT, JUMPDEST
4. Fill BlockMetadata for each block
5. Build pc_to_block mapping
   </algorithm_overview>

<implementation>
<location>
Add to `src/evm/frame/contract.zig` after the analyze_code function.
</location>

<code_structure>

```zig
/// Analyzes bytecode to identify basic blocks and compute their metadata.
/// A basic block is a sequence of instructions with:
/// - Single entry point (first instruction)
/// - Single exit point (last instruction)
/// - No jumps in the middle
///
/// Returns enhanced CodeAnalysis with block information.
fn analyzeBlocks(allocator: std.mem.Allocator, code: []const u8, base_analysis: *CodeAnalysis) !void {
    // Implementation here
}
```

</code_structure>

<detailed_algorithm>

```zig
fn analyzeBlocks(allocator: std.mem.Allocator, code: []const u8, base_analysis: *CodeAnalysis) !void {
    // Debug assertions for invariants
    std.debug.assert(base_analysis.code_segments.bits.len > 0 or code.len == 0);
    std.debug.assert(base_analysis.jumpdest_bitmap.bits.len > 0 or code.len == 0);
    
    // Memory best practice: pre-allocate to avoid reallocation
    var blocks = std.ArrayList(BlockMetadata).init(allocator);
    defer blocks.deinit();
    try blocks.ensureUnusedCapacity(@max(code.len / 4, 16)); // Estimate: avg 4 bytes per block

    var block_starts = try BitVec64.init(allocator, code.len);
    errdefer block_starts.deinit(allocator);

    var pc_to_block = try allocator.alloc(u16, code.len);
    errdefer allocator.free(pc_to_block);
    
    // Zero-initialize for safety
    @memset(pc_to_block, 0);

    // Current block being analyzed
    var current_block = BlockMetadata{
        .gas_cost = 0,
        .stack_req = 0,
        .stack_max = 0,
    };
    var stack_height: i16 = 0;
    var block_idx: u16 = 0;
    
    // Handle empty code edge case
    if (code.len == 0) {
        base_analysis.block_starts = block_starts;
        base_analysis.block_metadata = try blocks.toOwnedSlice();
        base_analysis.pc_to_block = pc_to_block;
        base_analysis.block_count = 0;
        return;
    }

    // Mark first instruction as block start
    block_starts.setUnchecked(0);

    var pc: usize = 0;
    while (pc < code.len) {
        const op = code[pc];
        pc_to_block[pc] = block_idx;

        // Get operation info from existing infrastructure
        const operation = operation_config.OPERATIONS[op];
        current_block.gas_cost = @min(current_block.gas_cost + operation.constant_gas, std.math.maxInt(u32));

        // Stack analysis using existing stack height changes
        const height_change = stack_height_changes.get_stack_height_change(op);
        const stack_before = stack_height;
        stack_height += height_change;

        // Update requirements (can be negative if block produces items)
        if (operation.min_stack > 0) {
            const needed = @as(i16, @intCast(operation.min_stack)) - stack_before;
            current_block.stack_req = @max(current_block.stack_req, needed);
        }
        current_block.stack_max = @max(current_block.stack_max, stack_height);
        
        // Debug assertion: stack max should never be negative at block start
        std.debug.assert(current_block.stack_max >= 0);

        // Check if this ends the block
        const ends_block = switch (op) {
            0x56, 0x57 => true,        // JUMP, JUMPI
            0x00, 0xf3, 0xfd => true,  // STOP, RETURN, REVERT
            0xff => true,              // SELFDESTRUCT
            else => false,
        };

        // JUMPDEST starts a new block (check using code segments)
        const next_is_jumpdest = if (pc + 1 < code.len)
            code[pc + 1] == 0x5b and base_analysis.code_segments.isSetUnchecked(pc + 1)
        else
            false;

        // Advance PC before block handling
        if (opcode.is_push(op)) {
            const push_size = opcode.get_push_size(op);
            // Mark push data bytes with same block index
            var i: usize = 1;
            while (i <= push_size and pc + i < code.len) : (i += 1) {
                pc_to_block[pc + i] = block_idx;
            }
            pc = @min(pc + push_size + 1, code.len);
        } else {
            pc += 1;
        }
        
        // Dead code elimination after terminating instructions
        if (ends_block and op != 0x57) { // Not JUMPI
            // Skip unreachable code until next JUMPDEST
            while (pc < code.len and code[pc] != 0x5b) {
                pc_to_block[pc] = std.math.maxInt(u16); // Mark as unreachable
                if (opcode.is_push(code[pc])) {
                    const skip_size = opcode.get_push_size(code[pc]);
                    pc = @min(pc + skip_size + 1, code.len);
                } else {
                    pc += 1;
                }
            }
        }

        if (ends_block or next_is_jumpdest) {
            // Save current block
            try blocks.append(current_block);

            // Start new block if not at end
            if (pc < code.len) {
                block_starts.setUnchecked(pc);
                current_block = .{ .gas_cost = 0, .stack_req = 0, .stack_max = 0 };
                stack_height = 0;
                block_idx += 1;
            }
        }
    }

    // Don't forget the last block if it wasn't closed
    if (blocks.items.len == block_idx) {
        try blocks.append(current_block);
    }
    
    // Debug assertions for output invariants
    std.debug.assert(blocks.items.len <= std.math.maxInt(u16));
    for (blocks.items) |block| {
        std.debug.assert(block.gas_cost < std.math.maxInt(u32));
    }

    // Transfer ownership to base_analysis
    base_analysis.block_starts = block_starts;
    base_analysis.block_metadata = try blocks.toOwnedSlice();
    base_analysis.pc_to_block = pc_to_block;
    base_analysis.block_count = @intCast(blocks.items.len);
}
```

</detailed_algorithm>

<integration>
Modify analyze_code to call analyzeBlocks:
```zig
pub fn analyze_code(allocator: std.mem.Allocator, code: []const u8, code_hash: [32]u8) !?*const CodeAnalysis {
    // ... existing code ...
    
    // After creating analysis and setting up jumpdests:
    
    // NEW: Analyze blocks
    try analyzeBlocks(allocator, code, analysis);
    
    // ... rest of existing code ...
}
```
</integration>
</implementation>

<testing>
Add comprehensive tests in contract.zig:
```zig
test "analyzeBlocks identifies basic blocks correctly" {
    const allocator = std.testing.allocator;
    
    // Simple contract: PUSH1 5, PUSH1 10, ADD, STOP
    const code = [_]u8{ 0x60, 0x05, 0x60, 0x0a, 0x01, 0x00 };
    
    const analysis = try analyze_code(allocator, &code, [_]u8{0} ** 32) orelse unreachable;
    defer analysis.deinit(allocator);
    
    // Should have 1 block
    try std.testing.expectEqual(@as(u16, 1), analysis.block_count);
    
    // Block should have correct gas cost
    const block = analysis.block_metadata[0];
    try std.testing.expectEqual(@as(u32, 3 + 3 + 3 + 0), block.gas_cost); // 3 PUSH1s + ADD
}

test "analyzeBlocks handles jumps correctly" {
const allocator = std.testing.allocator;

    // Contract with jump: PUSH1 5, JUMP, JUMPDEST, STOP
    const code = [_]u8{ 0x60, 0x05, 0x56, 0x5b, 0x00 };

    const analysis = try analyze_code(allocator, &code, [_]u8{0} ** 32) orelse unreachable;
    defer analysis.deinit(allocator);

    // Should have 2 blocks (before JUMP, after JUMPDEST)
    try std.testing.expectEqual(@as(u16, 2), analysis.block_count);

    // Check pc_to_block mapping
    try std.testing.expectEqual(@as(u16, 0), analysis.pc_to_block[0]); // PUSH1
    try std.testing.expectEqual(@as(u16, 0), analysis.pc_to_block[2]); // JUMP
    try std.testing.expectEqual(@as(u16, 1), analysis.pc_to_block[3]); // JUMPDEST

}

```
</testing>

<edge_cases>
1. Empty bytecode - should create empty block arrays
2. Code ending with PUSH without enough data
3. Multiple consecutive JUMPDESTs
4. Very large contracts (>65535 blocks would overflow u16)
5. JUMPI at end of code
6. Unreachable code patterns
7. Stack underflow within block (negative stack_req)
</edge_cases>

<benchmarking>
Add zbench benchmark to measure block analysis performance:
```zig
const zbench = @import("zbench");

fn benchmarkBlockAnalysis(b: *zbench.Benchmark) void {
    const allocator = std.testing.allocator;
    
    // Test with different contract sizes
    const contracts = [_][]const u8{
        @embedFile("test_data/small_contract.bin"),   // ~100 bytes
        @embedFile("test_data/medium_contract.bin"),  // ~5KB
        @embedFile("test_data/large_contract.bin"),   // ~24KB
    };
    
    b.run(for (0..b.iterations) |_| {
        for (contracts) |code| {
            const analysis = analyze_code(allocator, code, [_]u8{0} ** 32) catch unreachable;
            defer analysis.deinit(allocator);
            
            // Force use of block data to prevent optimization
            std.mem.doNotOptimizeAway(analysis.block_count);
            std.mem.doNotOptimizeAway(analysis.block_metadata);
        }
    });
}

fn benchmarkBlockAnalysisVsTraditional(b: *zbench.Benchmark) void {
    const allocator = std.testing.allocator;
    const code = @embedFile("test_data/complex_contract.bin");
    
    // Compare time with and without block analysis
    b.run(for (0..b.iterations) |_| {
        // Traditional analysis (jumpdests only)
        const trad_analysis = analyze_code_traditional(allocator, code, [_]u8{0} ** 32) catch unreachable;
        defer trad_analysis.deinit(allocator);
        
        // Block-based analysis
        const block_analysis = analyze_code(allocator, code, [_]u8{0} ** 32) catch unreachable;
        defer block_analysis.deinit(allocator);
    });
}
```
</benchmarking>

<memory_best_practices>
1. **Pre-allocation**: Reserve capacity based on code size to avoid reallocation
2. **Zero-initialization**: Use @memset for safety when allocating arrays
3. **Proper cleanup**: Always use errdefer for partial initialization failures
4. **Ownership transfer**: Clear local variables after transferring ownership
5. **Size validation**: Check that block count fits in u16 before casting
</memory_best_practices>
</task>

<success_criteria>
- [ ] analyzeBlocks correctly identifies all basic blocks
- [ ] BlockMetadata has accurate gas costs and stack requirements
- [ ] pc_to_block mapping is correct for all bytecode positions
- [ ] Integration with analyze_code doesn't break existing functionality
- [ ] All tests pass including new block analysis tests
- [ ] Edge cases are handled gracefully
</success_criteria>
```
