# Block-Level Validation Implementation for Zig EVM

<objective>
Implement evmone-style block analysis and validation in the Zig EVM to achieve significant performance improvements by validating stack requirements and consuming gas at the block level rather than per-instruction.
</objective>

<context>
## Background

The Zig EVM (Guillotine) currently validates stack requirements and consumes gas for each instruction during execution. This creates significant overhead, especially for compute-intensive contracts. evmone's advanced interpreter demonstrates that grouping instructions into "blocks" and performing validation once per block can dramatically improve performance.

### What is a Block?

A **block** is a sequence of instructions that executes linearly without branching. Blocks end at:
- Control flow instructions: `JUMP`, `JUMPI`, `STOP`, `RETURN`, `REVERT`, `SELFDESTRUCT`
- Jump destinations: `JUMPDEST`
- Invalid opcodes or end of code

### Current Performance Baseline

From our latest benchmarks on snailtracer:
- Guillotine: 859ms (after PC-to-operation optimization)
- evmone: 2.91ms (295x faster!)
- Target: Achieve at least 10x improvement through block analysis
</context>

<reference-implementation>
## evmone Reference Implementation

```cpp
// evmone: Fast Ethereum Virtual Machine implementation
// Copyright 2019 The evmone Authors.
// SPDX-License-Identifier: Apache-2.0

#include "advanced_analysis.hpp"
#include <cassert>

namespace evmone::advanced
{
/// Clamps x to the max value of To type.
template <typename To, typename T>
static constexpr To clamp(T x) noexcept
{
    constexpr auto max = std::numeric_limits<To>::max();
    return x <= max ? static_cast<To>(x) : max;
}

struct BlockAnalysis
{
    int64_t gas_cost = 0;

    int stack_req = 0;
    int stack_max_growth = 0;
    int stack_change = 0;

    /// The index of the beginblock instruction that starts the block.
    /// This is the place where the analysis data is going to be dumped.
    size_t begin_block_index = 0;

    explicit BlockAnalysis(size_t index) noexcept : begin_block_index{index} {}

    /// Close the current block by producing compressed information about the block.
    [[nodiscard]] BlockInfo close() const noexcept
    {
        return {clamp<decltype(BlockInfo{}.gas_cost)>(gas_cost),
            clamp<decltype(BlockInfo{}.stack_req)>(stack_req),
            clamp<decltype(BlockInfo{}.stack_max_growth)>(stack_max_growth)};
    }
};

AdvancedCodeAnalysis analyze(evmc_revision rev, bytes_view code) noexcept
{
    const auto& op_tbl = get_op_table(rev);
    const auto opx_beginblock_fn = op_tbl[OPX_BEGINBLOCK].fn;

    AdvancedCodeAnalysis analysis;

    const auto max_instrs_size = code.size() + 2;  // Additional OPX_BEGINBLOCK and STOP
    analysis.instrs.reserve(max_instrs_size);

    // This is 2x more than needed but using (code.size() / 2 + 1) increases page-faults 1000x.
    const auto max_args_storage_size = code.size() + 1;
    analysis.push_values.reserve(max_args_storage_size);

    // Create first block.
    analysis.instrs.emplace_back(opx_beginblock_fn);
    auto block = BlockAnalysis{0};

    const auto code_begin = code.data();
    const auto code_end = code_begin + code.size();
    auto code_pos = code_begin;
    while (code_pos != code_end)
    {
        const auto opcode = *code_pos++;
        const auto& opcode_info = op_tbl[opcode];

        if (opcode == OP_JUMPDEST)
        {
            // Save current block.
            analysis.instrs[block.begin_block_index].arg.block = block.close();
            // Create new block.
            block = BlockAnalysis{analysis.instrs.size()};

            // The JUMPDEST is always the first instruction in the block.
            analysis.jumpdest_offsets.emplace_back(static_cast<int32_t>(code_pos - code_begin - 1));
            analysis.jumpdest_targets.emplace_back(static_cast<int32_t>(analysis.instrs.size()));
        }

        analysis.instrs.emplace_back(opcode_info.fn);

        block.stack_req = std::max(block.stack_req, opcode_info.stack_req - block.stack_change);
        block.stack_change += opcode_info.stack_change;
        block.stack_max_growth = std::max(block.stack_max_growth, block.stack_change);

        block.gas_cost += opcode_info.gas_cost;

        auto& instr = analysis.instrs.back();

        switch (opcode)
        {
        default:
            break;

        case OP_JUMP:
        case OP_STOP:
        case OP_RETURN:
        case OP_REVERT:
        case OP_SELFDESTRUCT:
            // Skip dead code till next JUMPDEST or code end.
            while (code_pos != code_end && *code_pos != OP_JUMPDEST)
            {
                if (*code_pos >= OP_PUSH1 && *code_pos <= OP_PUSH32)
                {
                    const auto push_size = static_cast<size_t>(*code_pos - OP_PUSH1) + 1;
                    code_pos = std::min(code_pos + push_size + 1, code_end);
                }
                else
                    ++code_pos;
            }
            break;

        case OP_JUMPI:
            // JUMPI closes current block and starts a new one
            analysis.instrs[block.begin_block_index].arg.block = block.close();
            block = BlockAnalysis{analysis.instrs.size() - 1};
            break;

        // ... PUSH handling code ...
        }
    }

    // Save current block.
    analysis.instrs[block.begin_block_index].arg.block = block.close();

    // Make sure the last block is terminated.
    analysis.instrs.emplace_back(op_tbl[OP_STOP].fn);

    return analysis;
}
}  // namespace evmone::advanced
```

### Key Insights from evmone:

1. **Block boundaries** are identified during a single pass through the bytecode
2. **Stack requirements** are computed incrementally as instructions are processed
3. **Gas costs** are accumulated for the entire block
4. **Dead code** after terminators is skipped until the next JUMPDEST
5. **Block metadata** is stored compactly using clamped integer types
</reference-implementation>

<current-zig-implementation>
## Current Zig Implementation State

### What We Have:
1. **CodeAnalysis struct** (`code_analysis.zig`) with:
   - `pc_to_op_entries`: Direct PC-to-operation mapping
   - `jumpdest_positions`: Valid jump destinations
   - `code_segments`: BitVec marking code vs data

2. **Contract struct** (`contract.zig`) with:
   - Global LRU cache for analysis results
   - On-demand analysis triggered by first jump

3. **Interpreter** (`interpret.zig`) with:
   - Per-instruction validation and gas consumption
   - Cached operation lookup via `pc_to_op_entries`

### Performance Profile:
- ~70% of execution time in instruction dispatch and validation
- ~20% in stack operations
- ~10% in gas accounting
- Block-level validation can eliminate most of the 70% overhead
</current-zig-implementation>

<implementation-plan>
## Test-Driven Development Approach

### Phase 1: Data Structures and Basic Block Identification

#### Step 1.1: Define Block Structures
**Test First:**
```zig
test "BlockInfo stores block metadata compactly" {
    const block = BlockInfo{
        .gas_cost = 21000,
        .stack_req = 2,
        .stack_max_growth = 3,
        .start_pc = 0,
        .end_pc = 10,
    };
    try expectEqual(@as(u32, 21000), block.gas_cost);
    try expectEqual(@as(u16, 2), block.stack_req);
}
```

**Implementation:**
Add to `code_analysis.zig`:
```zig
pub const BlockInfo = struct {
    /// Total gas cost for all instructions in this block
    gas_cost: u32,
    /// Required stack height at block entry
    stack_req: u16,
    /// Maximum stack growth within the block
    stack_max_growth: u16,
    /// PC of first instruction in block
    start_pc: u32,
    /// PC of last instruction in block (inclusive)
    end_pc: u32,
    /// Type of block terminator
    terminator: BlockTerminator,
};

pub const BlockTerminator = enum {
    jump,
    jumpi,
    stop,
    return_,
    revert,
    selfdestruct,
    invalid,
    fall_through,
};
```

#### Step 1.2: Block Discovery Algorithm
**Test First:**
```zig
test "identify blocks in simple bytecode" {
    // PUSH1 0x02 PUSH1 0x03 ADD JUMPDEST PUSH1 0x01 STOP
    const code = [_]u8{0x60, 0x02, 0x60, 0x03, 0x01, 0x5b, 0x60, 0x01, 0x00};
    const blocks = try identifyBlocks(allocator, &code);
    defer allocator.free(blocks);
    
    try expectEqual(@as(usize, 2), blocks.len);
    try expectEqual(@as(u32, 0), blocks[0].start_pc);
    try expectEqual(@as(u32, 4), blocks[0].end_pc);
    try expectEqual(BlockTerminator.fall_through, blocks[0].terminator);
    try expectEqual(@as(u32, 5), blocks[1].start_pc);
    try expectEqual(@as(u32, 8), blocks[1].end_pc);
    try expectEqual(BlockTerminator.stop, blocks[1].terminator);
}
```

#### Step 1.3: Stack and Gas Analysis
**Test First:**
```zig
test "compute block stack requirements" {
    // PUSH1 0x02 PUSH1 0x03 ADD (requires 0, grows by 1)
    const code = [_]u8{0x60, 0x02, 0x60, 0x03, 0x01};
    const block = try analyzeBlock(allocator, &code, 0, 4);
    
    try expectEqual(@as(u16, 0), block.stack_req);
    try expectEqual(@as(u16, 1), block.stack_max_growth);
    try expectEqual(@as(u32, 3 + 3 + 3), block.gas_cost); // 3 gas per instruction
}
```

### Phase 2: Integration with CodeAnalysis

#### Step 2.1: Extend CodeAnalysis Structure
**Test First:**
```zig
test "CodeAnalysis includes block information" {
    const code = [_]u8{0x60, 0x02, 0x60, 0x03, 0x01, 0x00};
    const analysis = try Contract.analyze_code(allocator, &code, hash, &jump_table);
    defer analysis.deinit(allocator);
    
    try expect(analysis.blocks != null);
    try expectEqual(@as(usize, 1), analysis.blocks.?.len);
}
```

#### Step 2.2: PC-to-Block Mapping
**Test First:**
```zig
test "map PC to block index" {
    const code = [_]u8{0x60, 0x02, 0x5b, 0x60, 0x03, 0x00};
    const analysis = try Contract.analyze_code(allocator, &code, hash, &jump_table);
    defer analysis.deinit(allocator);
    
    try expectEqual(@as(u32, 0), analysis.pc_to_block[0]); // PUSH1
    try expectEqual(@as(u32, 0), analysis.pc_to_block[1]); // 0x02
    try expectEqual(@as(u32, 1), analysis.pc_to_block[2]); // JUMPDEST
}
```

### Phase 3: Block-Aware Interpreter

#### Step 3.1: Block Validation
**Test First:**
```zig
test "validate block requirements once" {
    var contract = Contract.init(...);
    const result = try vm.interpret_blocks(&contract, input, false);
    
    // Verify gas is consumed per-block, not per-instruction
    try expectEqual(@as(u64, initial_gas - block0.gas_cost), contract.gas);
}
```

#### Step 3.2: Block Execution
**Test First:**
```zig
test "execute block without per-instruction checks" {
    // Create a compute-heavy block (many ADDs)
    var code = ArrayList(u8).init(allocator);
    defer code.deinit();
    
    // PUSH1 0x01
    try code.appendSlice(&[_]u8{0x60, 0x01});
    // 100 DUP1 ADD sequences
    for (0..100) |_| {
        try code.appendSlice(&[_]u8{0x80, 0x01}); // DUP1 ADD
    }
    try code.append(0x00); // STOP
    
    // Measure performance improvement
    const start = std.time.nanoTimestamp();
    const result = try vm.interpret_blocks(&contract, &[_]u8{}, false);
    const elapsed = std.time.nanoTimestamp() - start;
    
    // Should be significantly faster than instruction-by-instruction
    try expect(elapsed < baseline_time / 2);
}
```

### Phase 4: Advanced Optimizations

#### Step 4.1: Static Jump Resolution
**Test First:**
```zig
test "pre-validate static jumps" {
    // PUSH1 0x04 JUMP STOP JUMPDEST STOP
    const code = [_]u8{0x60, 0x04, 0x56, 0x00, 0x5b, 0x00};
    const analysis = try Contract.analyze_code(allocator, &code, hash, &jump_table);
    
    const block0 = analysis.blocks.?[0];
    try expect(block0.static_jump_valid);
    try expectEqual(@as(u32, 1), block0.static_jump_target_block);
}
```

#### Step 4.2: Superblock Formation
**Test First:**
```zig
test "merge sequential blocks into superblocks" {
    // Multiple small blocks that can be merged
    const code = [_]u8{
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x02, // PUSH1 0x02  
        0x01,       // ADD
        0x60, 0x03, // PUSH1 0x03
        0x01,       // ADD
        0x00,       // STOP
    };
    
    const analysis = try Contract.analyze_code_with_superblocks(allocator, &code, hash, &jump_table);
    // Should create one superblock instead of multiple small blocks
    try expectEqual(@as(usize, 1), analysis.blocks.?.len);
}
```

## Implementation Guidelines

### Memory Management
- Pre-allocate block arrays based on bytecode size heuristics
- Use arena allocators for temporary analysis data
- Ensure all block data is freed in `CodeAnalysis.deinit()`

### Error Handling
- Handle malformed bytecode gracefully
- Fall back to instruction interpreter if block analysis fails
- Maintain compatibility with existing error types

### Performance Considerations
- Minimize allocations during analysis
- Use packed structs for block metadata
- Consider SIMD for block boundary detection
- Profile with snailtracer benchmark throughout development

### Compatibility
- Ensure all existing tests pass
- Maintain support for instruction-level debugging
- Preserve exact gas accounting semantics
</implementation-plan>

<success-criteria>
## Success Criteria

### Functional Requirements
- [ ] All existing EVM tests pass without modification
- [ ] Block analysis correctly identifies all block boundaries
- [ ] Stack validation matches instruction-by-instruction results
- [ ] Gas consumption is identical to current implementation

### Performance Requirements
- [ ] Snailtracer benchmark improves by at least 10x
- [ ] Memory usage increases by less than 20%
- [ ] Analysis time is less than 5% of execution time
- [ ] No performance regression on small contracts

### Code Quality
- [ ] 100% test coverage for block analysis code
- [ ] Clear documentation with examples
- [ ] Integration with existing LRU cache
- [ ] Clean separation between block and instruction interpreters
</success-criteria>

<testing-strategy>
## Comprehensive Testing Strategy

### Unit Tests
1. **Block identification**: Empty code, single instruction, complex control flow
2. **Stack analysis**: Underflow detection, max depth calculation
3. **Gas computation**: Accurate per-block costs, dynamic gas handling
4. **Edge cases**: Truncated PUSH, invalid jumps, deep nesting

### Integration Tests
1. **Official test suite**: All Ethereum consensus tests must pass
2. **Benchmark contracts**: snailtracer, ERC20 operations, hash loops
3. **Pathological cases**: Maximum block size, many small blocks
4. **Fuzzing**: Random bytecode to ensure robustness

### Performance Tests
```zig
test "benchmark block vs instruction interpreter" {
    const contracts = [_][]const u8{
        @embedFile("bench/snailtracer.bin"),
        @embedFile("bench/erc20.bin"),
        @embedFile("bench/sha3_loop.bin"),
    };
    
    for (contracts) |bytecode| {
        const t1 = try timeExecution(vm.interpret, bytecode);
        const t2 = try timeExecution(vm.interpret_blocks, bytecode);
        
        std.debug.print("{s}: {d}ms -> {d}ms ({d}x faster)\n", .{
            name, t1, t2, t1 / t2
        });
        
        try expect(t2 < t1); // Block interpreter must be faster
    }
}
```
</testing-strategy>

<development-workflow>
## Recommended Development Workflow

### Day 1: Foundation
1. Create `block_analysis.zig` with basic structures
2. Write comprehensive tests for block identification
3. Implement simple block boundary detection
4. Verify with unit tests

### Day 2: Analysis Integration  
1. Extend `CodeAnalysis` with block data
2. Modify `analyze_code` to perform block analysis
3. Add PC-to-block mapping
4. Test with real contracts

### Day 3: Interpreter Implementation
1. Create `interpret_blocks` function
2. Implement block-level validation
3. Add fast execution within blocks
4. Compare with instruction interpreter

### Day 4: Optimization and Polish
1. Profile and optimize hot paths
2. Implement static jump validation
3. Add superblock formation (optional)
4. Document performance improvements

### Day 5: Integration and Release
1. Run full test suite
2. Benchmark all test contracts
3. Update documentation
4. Create PR with performance data
</development-workflow>

<notes>
## Additional Notes

### Why This Matters
Block-level validation is the single most impactful optimization we can make. It transforms the interpreter from checking every instruction to checking once per block, eliminating ~70% of execution overhead.

### Learning from evmone
evmone proves this approach works. Their 295x performance advantage comes from:
1. Block analysis (this task) - ~10-20x improvement
2. Computed gotos (not applicable in Zig) - ~2x improvement  
3. Other micro-optimizations - ~5-10x improvement

### Future Extensions
Once block analysis is working, we can add:
- Superblock formation for hot paths
- Inline caching for dynamic jumps
- Speculative execution with rollback
- Block-level JIT compilation

Remember: **Test first, optimize second, measure always!**
</notes>