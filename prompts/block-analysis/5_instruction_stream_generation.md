# Phase 5: Instruction Stream Generation

## Objective
Transform EVM bytecode into an optimized linear instruction stream where each instruction contains its execution function pointer and pre-computed arguments, eliminating bytecode decoding overhead during execution.

## Background
Traditional interpreters decode bytecode on every execution:
1. Read opcode byte
2. Look up operation in jump table
3. Extract immediate values (for PUSH)
4. Validate and execute

The instruction stream pre-computes all of this during analysis, so execution just follows function pointers.

## Dependencies
- Phase 2: Block metadata (for BEGINBLOCK instructions)
- Phase 3: BEGINBLOCK intrinsic (inserted into stream)
- Phase 4: Jump analysis (for jump target resolution)

## Current State vs Target

### Current Execution (Bytecode Interpretation)
```zig
while (pc < code.len) {
    const opcode = code[pc];
    pc += 1;
    
    // Decode and dispatch every time
    const op = jump_table[opcode];
    if (op == null) return error.InvalidOpcode;
    
    // Extract push values
    if (isPush(opcode)) {
        const value = readPushValue(code, pc, opcode);
        pc += getPushSize(opcode);
        try op.execute(frame, value);
    } else {
        try op.execute(frame);
    }
}
```

### Target Execution (Instruction Stream)
```zig
var instr = &instructions[0];
while (instr != null) {
    // Just follow function pointers - no decoding!
    instr = instr.fn(instr, state);
}
```

## Implementation Steps

### Step 1: Define Instruction Structure
```zig
// Exactly 16 bytes for cache line efficiency
pub const Instruction = struct {
    fn: InstructionExecFn,      // 8 bytes - function pointer
    arg: InstructionArgument,    // 8 bytes - union
};

pub const InstructionExecFn = *const fn(
    instr: *const Instruction,
    state: *AdvancedExecutionState
) ?*const Instruction;

// Union must be exactly 8 bytes
pub const InstructionArgument = union {
    number: i64,                 // For PC, GAS, block gas
    push_value: *const u256,     // For PUSH9-32
    small_push_value: u64,       // For PUSH1-8 (inline)
    block: BlockMetadata,        // For BEGINBLOCK (8 bytes)
};

comptime {
    std.debug.assert(@sizeOf(Instruction) == 16);
    std.debug.assert(@sizeOf(InstructionArgument) == 8);
}
```

### Step 2: Instruction Stream Builder
```zig
pub const InstructionStream = struct {
    instructions: ArrayList(Instruction),
    push_values: ArrayList(u256),  // Storage for large push values
    allocator: Allocator,
    
    pub fn init(allocator: Allocator, code_size: usize) !InstructionStream {
        var stream = InstructionStream{
            .instructions = ArrayList(Instruction).init(allocator),
            .push_values = ArrayList(u256).init(allocator),
            .allocator = allocator,
        };
        
        // EVMone's memory strategy: reserve code_size + 2
        try stream.instructions.ensureTotalCapacity(code_size + 2);
        try stream.push_values.ensureTotalCapacity(code_size / 10); // Estimate
        
        return stream;
    }
    
    pub fn addInstruction(self: *InstructionStream, fn_ptr: InstructionExecFn) !*Instruction {
        const instr = try self.instructions.addOne();
        instr.* = .{
            .fn = fn_ptr,
            .arg = .{ .number = 0 },
        };
        return instr;
    }
    
    pub fn addPushValue(self: *InstructionStream, value: u256) !*const u256 {
        const ptr = try self.push_values.addOne();
        ptr.* = value;
        return ptr;
    }
    
    pub fn deinit(self: *InstructionStream) void {
        self.instructions.deinit();
        self.push_values.deinit();
    }
};
```

### Step 3: Bytecode to Instruction Stream Conversion
```zig
pub fn generateInstructionStream(
    allocator: Allocator,
    code: []const u8,
    blocks: []const BlockAnalysis,
    jump_table: *const JumpTable,
) !InstructionStream {
    var stream = try InstructionStream.init(allocator, code.len);
    errdefer stream.deinit();
    
    var pc: usize = 0;
    var block_index: usize = 0;
    
    // Insert first BEGINBLOCK
    if (blocks.len > 0) {
        const instr = try stream.addInstruction(opx_beginblock_advanced);
        instr.arg = .{ .block = blocks[0].metadata };
    }
    
    while (pc < code.len) {
        const opcode = code[pc];
        pc += 1;
        
        // Check for block boundary
        if (block_index + 1 < blocks.len and pc == blocks[block_index + 1].start_pc) {
            block_index += 1;
            
            // Insert BEGINBLOCK for new block
            const instr = try stream.addInstruction(opx_beginblock_advanced);
            instr.arg = .{ .block = blocks[block_index].metadata };
        }
        
        // Convert opcode to instruction
        const op_fn = getAdvancedOperation(opcode);
        const instr = try stream.addInstruction(op_fn);
        
        // Handle special opcodes
        switch (opcode) {
            // PUSH1-PUSH8: inline value
            0x60...0x67 => {
                const push_size = opcode - 0x5F;
                var value: u64 = 0;
                
                // Read bytes in big-endian
                var i: usize = 0;
                while (i < push_size and pc < code.len) : (i += 1) {
                    value = (value << 8) | code[pc];
                    pc += 1;
                }
                
                instr.arg = .{ .small_push_value = value };
            },
            
            // PUSH9-PUSH32: separate storage
            0x68...0x7F => {
                const push_size = opcode - 0x5F;
                var value: u256 = 0;
                
                // Read bytes in big-endian
                var i: usize = 0;
                while (i < push_size and pc < code.len) : (i += 1) {
                    const byte = @as(u256, code[pc]);
                    const shift = @intCast(u8, (push_size - 1 - i) * 8);
                    value |= byte << shift;
                    pc += 1;
                }
                
                const value_ptr = try stream.addPushValue(value);
                instr.arg = .{ .push_value = value_ptr };
            },
            
            // PC: store current PC value
            0x58 => {
                instr.arg = .{ .number = @intCast(i64, pc - 1) };
            },
            
            // GAS and dynamic gas ops: store block gas for correction
            0x5A, 0xF1, 0xF2, 0xF4, 0xFA, 0xF0, 0xF5, 0x55 => {
                if (block_index < blocks.len) {
                    instr.arg = .{ .number = @intCast(i64, blocks[block_index].metadata.gas_cost) };
                }
            },
            
            // Skip unreachable code after terminators
            0x00, 0x56, 0xF3, 0xFD, 0xFF => {
                // Skip to next JUMPDEST or end
                while (pc < code.len and code[pc] != 0x5B) {
                    if (code[pc] >= 0x60 and code[pc] <= 0x7F) {
                        pc += code[pc] - 0x5F + 1;
                    } else {
                        pc += 1;
                    }
                }
            },
            
            else => {},
        }
    }
    
    // Add final STOP instruction
    _ = try stream.addInstruction(op_stop_advanced);
    
    return stream;
}
```

### Step 4: Advanced Operation Functions
```zig
// Example implementations for instruction stream execution

fn op_add_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const b = state.stack_pop();
    const a = state.stack_top().*;
    state.stack_top().* = a +% b;
    return instr + 1;  // Next instruction
}

fn op_push_small_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack_push(instr.arg.small_push_value);
    return instr + 1;
}

fn op_push_full_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack_push(instr.arg.push_value.*);
    return instr + 1;
}

fn op_jump_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const dest = state.stack_pop();
    
    if (dest > std.math.maxInt(u32)) {
        return state.exit(error.InvalidJump);
    }
    
    // Binary search for jump target
    const target_index = state.jump_analysis.getJumpTarget(@intCast(u32, dest));
    if (target_index == null) {
        return state.exit(error.InvalidJump);
    }
    
    return &state.instructions[target_index.?];
}

fn op_pc_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    // PC was stored during analysis
    state.stack_push(@intCast(u256, instr.arg.number));
    return instr + 1;
}

fn op_gas_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    // Correct for block gas pre-deduction
    const block_gas_remaining = instr.arg.number - state.block_gas_consumed;
    const actual_gas = state.gas_left + block_gas_remaining;
    state.stack_push(@intCast(u256, actual_gas));
    return instr + 1;
}
```

### Step 5: Optimizations for Common Patterns
```zig
// Detect and optimize common instruction sequences

fn detectPatterns(stream: *InstructionStream, code: []const u8) !void {
    // Pattern: PUSH1 + ADD -> ADD_IMMEDIATE
    // Pattern: DUP1 + SWAP1 -> SWAP1_DUP1
    // Pattern: ISZERO + JUMPI -> JUMPIF_ZERO
    
    var i: usize = 0;
    while (i < stream.instructions.items.len - 1) : (i += 1) {
        const curr = &stream.instructions.items[i];
        const next = &stream.instructions.items[i + 1];
        
        // PUSH1 small_value + ADD -> ADD_IMMEDIATE
        if (curr.fn == op_push_small_advanced and next.fn == op_add_advanced) {
            curr.fn = op_add_immediate_advanced;
            // curr.arg already has the immediate value
            
            // Remove next instruction
            _ = stream.instructions.orderedRemove(i + 1);
        }
    }
}

fn op_add_immediate_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const a = state.stack_top().*;
    state.stack_top().* = a +% instr.arg.small_push_value;
    return instr + 1;
}
```

## Testing Requirements

### Unit Tests
```zig
test "instruction stream generation" {
    const bytecode = [_]u8{
        0x60, 0x01,  // PUSH1 1
        0x60, 0x02,  // PUSH1 2
        0x01,        // ADD
        0x00,        // STOP
    };
    
    const stream = try generateInstructionStream(allocator, &bytecode, &.{}, jump_table);
    defer stream.deinit();
    
    // Should generate: BEGINBLOCK, PUSH1, PUSH1, ADD, STOP
    try expectEqual(@as(usize, 5), stream.instructions.items.len);
    
    // Check first push has inline value
    try expectEqual(@as(u64, 1), stream.instructions.items[1].arg.small_push_value);
}

test "large push value handling" {
    const bytecode = [_]u8{
        0x7F, // PUSH32
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00,
    };
    
    const stream = try generateInstructionStream(allocator, &bytecode, &.{}, jump_table);
    defer stream.deinit();
    
    // Should store value separately
    try expectEqual(@as(usize, 1), stream.push_values.items.len);
}
```

### Performance Tests
1. Measure instruction stream generation time
2. Compare memory usage vs bytecode size
3. Test dispatch overhead reduction

## Success Criteria

### Functional
- [ ] Correctly generates instruction stream for all opcodes
- [ ] Handles all push sizes correctly
- [ ] Preserves execution semantics
- [ ] All tests pass

### Performance
- [ ] Generation time < 1ms for typical contracts
- [ ] Memory usage < 3x bytecode size
- [ ] Enables fast dispatch in execution loop

### Code Quality
- [ ] Clean separation of concerns
- [ ] Well-documented instruction format
- [ ] Extensible for future optimizations

## Benchmarking

### Stream Generation Performance
```zig
fn benchmarkStreamGeneration() !void {
    const contracts = [_][]const u8{
        @embedFile("erc20_bytecode.hex"),
        @embedFile("uniswap_bytecode.hex"),
    };
    
    for (contracts) |bytecode| {
        const start = std.time.nanoTimestamp();
        const stream = try generateInstructionStream(allocator, bytecode, &.{}, jump_table);
        const elapsed = std.time.nanoTimestamp() - start;
        
        std.debug.print(
            "Bytecode: {} bytes, Instructions: {}, Time: {}µs, Memory: {}x\n",
            .{
                bytecode.len,
                stream.instructions.items.len,
                elapsed / 1000,
                (stream.instructions.items.len * 16) / bytecode.len,
            }
        );
        
        stream.deinit();
    }
}
```

## Risk Mitigation

### Memory Usage
- Monitor memory overhead closely
- Consider compression for sparse instructions
- Reuse streams across multiple executions

### Correctness
- Extensive testing against interpreter mode
- Verify identical execution traces
- Fuzz testing with random bytecode

### Performance
- Profile actual contracts
- Ensure generation doesn't dominate execution time
- Cache generated streams

## Reference Implementation

EVMone's approach:
- `evmone/lib/evmone/advanced_analysis.cpp` - instruction generation
- They generate instructions in single pass
- No pattern optimization (we can improve)

## Next Phase Dependencies

This phase enables:
- Phase 6: Advanced execution loop (needs instruction stream)
- All performance benefits of the advanced interpreter