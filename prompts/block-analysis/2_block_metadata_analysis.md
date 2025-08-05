# Phase 2: Block Metadata Analysis

## Objective
Implement comprehensive block analysis that pre-computes gas costs, stack requirements, and stack growth for each basic block in the bytecode, enabling bulk validation and optimized execution.

## Background
Currently, gas and stack validation happens on every opcode. By analyzing code in blocks (sequences of instructions between jumps), we can:
- Validate gas once per block instead of per instruction
- Check stack requirements once at block entry
- Skip validation for straight-line code within blocks

## Dependencies
- Phase 1: Stack pointer refactoring (completed)
- Existing: BitVec64 for jump destinations

## Current State Analysis

### Existing Components We Can Leverage
```zig
// From src/evm/frame/code_analysis.zig
pub const BlockMetadata = packed struct {
    gas_cost: u32,      // Total gas for block
    stack_req: i16,     // Min stack items needed
    stack_max: i16,     // Max stack growth
};

// Already have SoA implementation started
pub const BlockMetadataSoA = struct {
    gas_costs: []u32,
    stack_reqs: []i16,
    stack_max_growths: []i16,
    count: u16,
};
```

### What Needs Implementation
1. Block boundary detection algorithm
2. Per-block gas accumulation
3. Stack effect tracking through blocks
4. Integration with existing code analysis

## Implementation Steps

### Step 1: Block Boundary Detection
```zig
pub fn identifyBlockBoundaries(code: []const u8) ![]usize {
    // A new block starts at:
    // 1. Code beginning (PC=0)
    // 2. After JUMPDEST (jump target)
    // 3. After JUMP, RETURN, REVERT, STOP, INVALID, SELFDESTRUCT (terminators)
    // 4. After JUMPI (conditional branch)
    
    var boundaries = ArrayList(usize).init(allocator);
    try boundaries.append(0); // First block
    
    var pc: usize = 0;
    while (pc < code.len) {
        const op = code[pc];
        pc += 1;
        
        switch (op) {
            0x5B => { // JUMPDEST
                try boundaries.append(pc); // New block after JUMPDEST
            },
            0x56, 0x00, 0xF3, 0xFD, 0xFE, 0xFF => { // Terminators
                if (pc < code.len) {
                    try boundaries.append(pc);
                }
                // Skip unreachable code until next JUMPDEST
                while (pc < code.len and code[pc] != 0x5B) {
                    if (isPush(code[pc])) {
                        pc += getPushSize(code[pc]) + 1;
                    } else {
                        pc += 1;
                    }
                }
            },
            0x57 => { // JUMPI
                if (pc < code.len) {
                    try boundaries.append(pc); // Fall-through block
                }
            },
            0x60...0x7F => { // PUSH opcodes
                pc += op - 0x5F; // Skip push data
            },
            else => {},
        }
    }
    
    return boundaries.toOwnedSlice();
}
```

### Step 2: Block Analysis Structure
```zig
pub const BlockAnalysis = struct {
    start_pc: usize,
    end_pc: usize,
    gas_cost: u32,
    stack_req: i16,     // Minimum stack height at entry
    stack_change: i8,   // Net stack change
    stack_max_growth: i16, // Maximum growth during block
    
    pub fn analyze(code: []const u8, start: usize, end: usize) BlockAnalysis {
        var analysis = BlockAnalysis{
            .start_pc = start,
            .end_pc = end,
            .gas_cost = 0,
            .stack_req = 0,
            .stack_change = 0,
            .stack_max_growth = 0,
        };
        
        var current_stack_change: i8 = 0;
        var pc = start;
        
        while (pc < end) {
            const op = code[pc];
            const op_info = getOperationInfo(op);
            
            // Accumulate gas
            analysis.gas_cost += op_info.constant_gas;
            
            // Track stack requirements
            const stack_needed = op_info.min_stack - current_stack_change;
            analysis.stack_req = @max(analysis.stack_req, stack_needed);
            
            // Update stack change
            current_stack_change += op_info.stack_change;
            analysis.stack_max_growth = @max(analysis.stack_max_growth, current_stack_change);
            
            // Skip push data
            if (isPush(op)) {
                pc += getPushSize(op) + 1;
            } else {
                pc += 1;
            }
        }
        
        analysis.stack_change = current_stack_change;
        return analysis;
    }
};
```

### Step 3: Full Code Analysis
```zig
pub const AdvancedCodeAnalysis = struct {
    blocks: []BlockAnalysis,
    block_lookup: HashMap(usize, usize), // PC -> block index
    jumpdests: BitVec64,  // Reuse existing
    
    pub fn analyzeCode(allocator: Allocator, code: []const u8) !AdvancedCodeAnalysis {
        // Get block boundaries
        const boundaries = try identifyBlockBoundaries(code);
        defer allocator.free(boundaries);
        
        // Analyze each block
        var blocks = try allocator.alloc(BlockAnalysis, boundaries.len);
        for (boundaries, 0..) |start_pc, i| {
            const end_pc = if (i + 1 < boundaries.len) 
                boundaries[i + 1] 
            else 
                code.len;
                
            blocks[i] = BlockAnalysis.analyze(code, start_pc, end_pc);
        }
        
        // Build PC -> block lookup
        var lookup = HashMap(usize, usize).init(allocator);
        for (blocks, 0..) |block, i| {
            var pc = block.start_pc;
            while (pc < block.end_pc) : (pc += 1) {
                try lookup.put(pc, i);
            }
        }
        
        return .{
            .blocks = blocks,
            .block_lookup = lookup,
            .jumpdests = try analyzeJumpdests(code), // Existing
        };
    }
};
```

### Step 4: Integration with Frame
```zig
// In src/evm/frame/frame.zig
pub const Frame = struct {
    // ... existing fields ...
    code_analysis: ?*AdvancedCodeAnalysis,
    current_block_index: usize,
    
    pub fn enterBlock(self: *Frame, block_index: usize) !void {
        const block = self.code_analysis.?.blocks[block_index];
        
        // Single gas check for entire block
        if (self.gas_remaining < block.gas_cost) {
            return error.OutOfGas;
        }
        
        // Single stack validation
        const stack_size = @intCast(i16, self.stack.size());
        if (stack_size < block.stack_req) {
            return error.StackUnderflow;
        }
        if (stack_size + block.stack_max_growth > Stack.CAPACITY) {
            return error.StackOverflow;
        }
        
        // Deduct gas for entire block
        self.gas_remaining -= block.gas_cost;
        self.current_block_index = block_index;
    }
};
```

## Testing Requirements

### Unit Tests
1. Test block boundary detection with various bytecode patterns
2. Verify gas accumulation matches per-instruction charging
3. Test stack requirement calculation
4. Edge cases: empty blocks, single instruction blocks

### Integration Tests
1. Run with existing test suite
2. Verify identical gas consumption
3. Test with contracts containing complex control flow

### Performance Tests
1. Measure analysis time for typical contracts
2. Memory overhead of block metadata
3. Cache efficiency of block lookups

## Success Criteria

### Functional
- [ ] Correctly identifies all block boundaries
- [ ] Accurate gas cost pre-computation
- [ ] Correct stack requirement analysis
- [ ] All existing tests pass

### Performance
- [ ] Analysis completes in < 1ms for typical contracts
- [ ] Memory overhead < 10% of bytecode size
- [ ] Enables bulk validation in next phase

### Code Quality
- [ ] Clean integration with existing code analysis
- [ ] Well-documented block detection algorithm
- [ ] Reusable for future optimizations

## Benchmarking

### Analysis Performance
```zig
fn benchmarkBlockAnalysis() !void {
    const bytecodes = [_][]const u8{
        @embedFile("erc20_bytecode.hex"),
        @embedFile("uniswap_bytecode.hex"),
        @embedFile("snailtracer_bytecode.hex"),
    };
    
    for (bytecodes) |bytecode| {
        const start = std.time.milliTimestamp();
        const analysis = try AdvancedCodeAnalysis.analyzeCode(allocator, bytecode);
        const elapsed = std.time.milliTimestamp() - start;
        
        std.debug.print("Analysis time: {}ms, Blocks: {}\n", .{elapsed, analysis.blocks.len});
        analysis.deinit();
    }
}
```

## Risk Mitigation

### Correctness
- Extensive testing against reference implementation
- Fuzzing with random bytecode
- Comparison with evmone's block detection

### Memory Usage
- Limit maximum blocks per contract
- Use compact representations
- Share analysis between calls

### Edge Cases
- Handle malformed bytecode
- Deal with unreachable code
- Support dynamic jumps correctly

## Reference Implementation

EVMone's approach:
- `evmone/lib/evmone/advanced_analysis.cpp` - Block detection
- Key insight: They create blocks at every JUMPDEST and after terminators
- They don't cache analysis (we can improve on this)

## Next Phase Dependencies

This phase enables:
- Phase 3: BEGINBLOCK intrinsic (uses block metadata)
- Phase 4: Jump optimization (part of analysis)
- Phase 5: Instruction stream (needs block structure)