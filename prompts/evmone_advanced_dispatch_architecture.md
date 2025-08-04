# EVMOne-Style Advanced Dispatch Architecture for Guillotine

## Overview

This document outlines implementing EVMOne's advanced interpreter architecture in Guillotine. EVMOne achieves 2-3x performance over basic interpreters through pre-analysis and block-based execution. Guillotine already has several foundational components we can leverage.

## Current Architecture (Interpreter Mode)

Guillotine currently uses a traditional interpreter with some optimizations:
- Direct bytecode execution via jump table (O(1) dispatch)
- Per-instruction gas charging and stack validation
- Optimized PUSH1-PUSH8 with inline values (already implemented!)
- Fast stack validation in ReleaseFast mode (already implemented!)
- Pre-computed jump destinations in BitVec64 (already implemented!)
- LRU cache for code analysis (already implemented!)

## Proposed Architecture (Advanced Mode)

### 1. Core Data Structures

```zig
// Instruction function signature - returns next instruction pointer
pub const InstructionExecFn = *const fn (
    instr: *const Instruction, 
    state: *AdvancedExecutionState
) ?*const Instruction;

// EVMOne's exact instruction structure - 16 bytes total
pub const Instruction = struct {
    fn: InstructionExecFn,    // 8 bytes
    arg: InstructionArgument,  // 8 bytes (union)
};

// EVMOne's exact union - no jump_target field!
pub const InstructionArgument = union {
    number: i64,                    // For PC, GAS, block gas correction
    push_value: *const u256,        // PUSH9-PUSH32 only
    small_push_value: u64,          // PUSH1-PUSH8 only (key optimization)
    block: BlockInfo,               // For BEGINBLOCK intrinsic
};

// EVMOne's BlockInfo - fits in 8 bytes for union
pub const BlockInfo = struct {
    gas_cost: u32,         // Total base gas of block
    stack_req: i16,        // Min stack items needed  
    stack_max_growth: i16, // Max stack growth
};

// EVMOne's analysis result with sorted arrays for binary search
pub const AdvancedCodeAnalysis = struct {
    instrs: std.ArrayList(Instruction),      // Pre-analyzed instructions
    push_values: std.ArrayList(u256),        // Storage for PUSH9-32
    jumpdest_offsets: std.ArrayList(i32),    // Sorted PC values  
    jumpdest_targets: std.ArrayList(i32),    // Instruction indexes
    allocator: std.mem.Allocator,
    
    // Binary search for jump destinations
    pub fn findJumpdest(self: *const AdvancedCodeAnalysis, offset: i32) i32 {
        const idx = std.sort.binarySearch(i32, offset, self.jumpdest_offsets.items, {}, std.sort.asc(i32));
        if (idx) |i| {
            return self.jumpdest_targets.items[i];
        }
        return -1;
    }
    
    pub fn deinit(self: *AdvancedCodeAnalysis) void {
        self.instrs.deinit();
        self.push_values.deinit();
        self.jumpdest_offsets.deinit();
        self.jumpdest_targets.deinit();
    }
};

// Helper for tracking block metadata during analysis
const BlockAnalysis = struct {
    begin_block_index: usize,
    gas_cost: u32 = 0,
    stack_req: i16 = 0,
    stack_change: i8 = 0,
    stack_max_growth: i16 = 0,
    
    pub fn close(self: BlockAnalysis) BlockInfo {
        return .{
            .gas_cost = self.gas_cost,
            .stack_req = self.stack_req,
            .stack_max_growth = self.stack_max_growth,
        };
    }
};
```

### 2. Code Analysis Phase

The analysis phase transforms bytecode into an optimized instruction stream:

```zig
pub fn analyze(allocator: std.mem.Allocator, code: []const u8, table: *const JumpTable) !AdvancedCodeAnalysis {
    var analysis = AdvancedCodeAnalysis{
        .instrs = std.ArrayList(Instruction).init(allocator),
        .push_values = std.ArrayList(u256).init(allocator),
        .jumpdest_offsets = std.ArrayList(i32).init(allocator),
        .jumpdest_targets = std.ArrayList(i32).init(allocator),
        .allocator = allocator,
    };
    
    // EVMOne's memory strategy: reserve code.size() + 2
    try analysis.instrs.ensureTotalCapacity(code.len + 2);
    try analysis.push_values.ensureTotalCapacity(code.len + 1);
    
    // Insert first BEGINBLOCK
    analysis.instrs.appendAssumeCapacity(.{ 
        .fn = opx_beginblock_advanced, 
        .arg = .{ .block = .{ .gas_cost = 0, .stack_req = 0, .stack_max_growth = 0 } } 
    });
    
    var block = BlockAnalysis{ .begin_block_index = 0 };
    var pos: usize = 0;
    
    while (pos < code.len) {
        const opcode = code[pos];
        pos += 1;
        
        // EVMOne's exact block boundary logic
        if (opcode == 0x5B) { // JUMPDEST
            // Save current block
            analysis.instrs.items[block.begin_block_index].arg.block = block.close();
            // Create new block
            block = BlockAnalysis{ .begin_block_index = analysis.instrs.items.len };
            
            // Record jump destination
            try analysis.jumpdest_offsets.append(@intCast(i32, pos - 1));
            try analysis.jumpdest_targets.append(@intCast(i32, analysis.instrs.items.len));
        }
        
        // Get operation from our existing jump table
        const op = table.get_operation(opcode);
        analysis.instrs.appendAssumeCapacity(.{ .fn = convertToAdvancedFn(op), .arg = .{ .number = 0 } });
        
        // Track block requirements using our existing stack height changes
        const stack_change = stack_height_changes.get_stack_height_change(opcode);
        block.stack_req = @max(block.stack_req, op.min_stack - block.stack_change);
        block.stack_change += stack_change;
        block.stack_max_growth = @max(block.stack_max_growth, block.stack_change);
        block.gas_cost += op.constant_gas;
        
        var instr = &analysis.instrs.items[analysis.instrs.items.len - 1];
        
        // Handle specific opcodes
        switch (opcode) {
            // Terminating instructions - skip unreachable code
            0x00, 0x56, 0xf3, 0xfd, 0xff => { // STOP, JUMP, RETURN, REVERT, SELFDESTRUCT
                while (pos < code.len and code[pos] != 0x5B) {
                    if (Opcode.is_push(code[pos])) {
                        const push_size = Opcode.get_push_size(code[pos]);
                        pos = @min(pos + push_size + 1, code.len);
                    } else {
                        pos += 1;
                    }
                }
            },
            
            // JUMPI creates new block
            0x57 => {
                analysis.instrs.items[block.begin_block_index].arg.block = block.close();
                block = BlockAnalysis{ .begin_block_index = analysis.instrs.items.len - 1 };
            },
            
            // PUSH optimization - reuse our existing logic
            0x60...0x68 => { // PUSH1-PUSH8
                const push_size = opcode - 0x60 + 1;
                var value: u64 = 0;
                // Read bytes in big-endian order (matching our make_push_small)
                var i: usize = 0;
                while (i < push_size and pos < code.len) : (i += 1) {
                    value = (value << 8) | code[pos];
                    pos += 1;
                }
                instr.arg = .{ .small_push_value = value };
            },
            
            0x69...0x7f => { // PUSH9-PUSH32
                const push_size = opcode - 0x60 + 1;
                const push_value = try analysis.push_values.addOne();
                push_value.* = 0;
                // Read bytes matching our make_push implementation
                var i: usize = 0;
                while (i < push_size and pos < code.len) : (i += 1) {
                    const byte_value = @as(u256, code[pos]);
                    const shift = @intCast(u8, (push_size - 1 - i) * 8);
                    push_value.* |= byte_value << shift;
                    pos += 1;
                }
                instr.arg = .{ .push_value = push_value };
            },
            
            // Store block gas for dynamic gas correction
            0x5a, 0xf1, 0xf2, 0xf4, 0xfa, 0xf0, 0xf5, 0x55 => { // GAS, CALL*, CREATE*, SSTORE
                instr.arg = .{ .number = @intCast(i64, block.gas_cost) };
            },
            
            0x58 => { // PC
                instr.arg = .{ .number = @intCast(i64, pos - 1) };
            },
            
            else => {},
        }
    }
    
    // Close final block
    analysis.instrs.items[block.begin_block_index].arg.block = block.close();
    
    // Add final STOP
    analysis.instrs.appendAssumeCapacity(.{ 
        .fn = convertToAdvancedFn(table.get_operation(0x00)), 
        .arg = .{ .number = 0 } 
    });
    
    return analysis;
}
```

### 3. Execution State (Leveraging Existing Components)

```zig
pub const AdvancedExecutionState = struct {
    // Reuse existing Frame fields
    frame: *Frame,              // Already has stack, memory, gas_remaining
    interpreter: *Vm,           // Already has context, state, etc.
    
    // Advanced mode specific
    gas_left: i64,              // Signed for underflow detection
    current_block_cost: u32,    // For GAS opcode correction
    analysis: *const AdvancedCodeAnalysis,
    
    // Stack pointer optimization (reuse existing stack)
    pub fn stack_top(self: *AdvancedExecutionState) *u256 {
        return &self.frame.stack.items[self.frame.stack.size - 1];
    }
    
    pub fn stack_pop(self: *AdvancedExecutionState) u256 {
        // We can use pop_unsafe because block validation ensures safety
        return self.frame.stack.pop_unsafe();
    }
    
    pub fn stack_push(self: *AdvancedExecutionState, value: u256) void {
        // We can use append_unsafe because block validation ensures capacity
        self.frame.stack.append_unsafe(value);
    }
    
    pub fn exit(self: *AdvancedExecutionState, status: ExecutionError.Error) ?*const Instruction {
        self.frame.status = status;
        return null;
    }
};
```

### 4. Instruction Implementations

Example implementations showing the pattern:

```zig
// Arithmetic - reuse existing optimized implementations
fn op_add_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    // Reuse our existing optimized ADD from arithmetic.zig
    const b = state.stack_pop();
    const a = state.stack_top().*;
    state.stack_top().* = a +% b;
    return instr + 1;
}

// PUSH - leverage our existing optimized PUSH implementations
fn op_push_small_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    // Reuse pattern from our make_push_small
    state.stack_push(instr.arg.small_push_value);
    return instr + 1;
}

fn op_push_full_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    state.stack_push(instr.arg.push_value.*);
    return instr + 1;
}

// BEGINBLOCK - handles gas and stack validation for entire block
fn opx_beginblock_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const block = &instr.arg.block;
    
    // Single gas check for entire block
    state.gas_left -= block.gas_cost;
    if (state.gas_left < 0) return state.exit(ExecutionError.Error.OutOfGas);
    
    // Single stack validation for entire block
    const stack_size = @intCast(i16, state.frame.stack.size);
    if (stack_size < block.stack_req) return state.exit(ExecutionError.Error.StackUnderflow);
    if (stack_size + block.stack_max_growth > Stack.CAPACITY) {
        return state.exit(ExecutionError.Error.StackOverflow);
    }
    
    state.current_block_cost = block.gas_cost;
    return instr + 1;
}

// JUMP with binary search (EVMOne's approach)
fn op_jump_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const dst = state.stack_pop();
    
    // Check if valid PC
    if (dst > std.math.maxInt(i32)) return state.exit(ExecutionError.Error.InvalidJumpDest);
    
    // Binary search in sorted jumpdest_offsets
    const pc = @intCast(i32, dst);
    const target = state.analysis.findJumpdest(pc);
    
    if (target < 0) return state.exit(ExecutionError.Error.InvalidJumpDest);
    return &state.analysis.instrs.items[@intCast(usize, target)];
}

// JUMPI - EVMOne reuses JUMP logic
fn op_jumpi_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const cond = state.stack_pop();
    if (cond != 0) {
        return op_jump_advanced(instr, state);
    } else {
        _ = state.stack_pop(); // Remove destination
        return instr + 1; // Or execute follow-through BEGINBLOCK
    }
}

// Dynamic gas correction pattern (for SSTORE, CALL, etc)
fn op_sstore_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const gas_left_correction = state.current_block_cost - instr.arg.number;
    state.gas_left += gas_left_correction;
    
    // Execute core SSTORE logic with dynamic gas
    // ... (reuse existing SSTORE implementation)
    
    state.gas_left -= gas_left_correction;
    if (state.gas_left < 0) return state.exit(ExecutionError.Error.OutOfGas);
    
    return instr + 1;
}
```

### 5. Main Execution Loop

```zig
pub fn executeAdvanced(
    frame: *Frame,
    interpreter: *Vm,
    analysis: *const AdvancedCodeAnalysis,
) !void {
    var state = AdvancedExecutionState{
        .frame = frame,
        .interpreter = interpreter,
        .gas_left = @intCast(i64, frame.gas_remaining),
        .current_block_cost = 0,
        .analysis = analysis,
    };
    
    // EVMone's exact dispatch loop
    var instr: ?*const Instruction = &analysis.instrs.items[0];
    while (instr) |i| {
        instr = i.fn(i, &state);
    }
    
    // Update frame with final gas
    const gas_left = if (frame.status == .Success or frame.status == .Revert) state.gas_left else 0;
    frame.gas_remaining = @intCast(u64, @max(0, gas_left));
}
```

## Key Implementation Details (From EVMOne)

1. **Memory Pre-allocation**: Reserve `code.size + 2` for instructions, `code.size + 1` for push values
2. **PUSH Threshold**: PUSH1-PUSH8 inline (matching our existing optimization!), PUSH9-PUSH32 separate
3. **Block Boundaries**: JUMPDEST always starts new block, after JUMPI, after terminating ops
4. **Jump Resolution**: Binary search on sorted arrays, NOT hash map (O(log n))
5. **Gas Correction**: Store block gas in `arg.number` for GAS/CALL/SSTORE
6. **No Caching**: Analysis done fresh each execution (we can improve this with our LRU cache!)

## Leveraging Existing Guillotine Components

1. **Stack Operations**: Reuse our optimized `pop_unsafe()`, `append_unsafe()` from Stack
2. **PUSH Optimization**: Our `op_push1` and `make_push_small` already match EVMOne's approach!
3. **Jump Validation**: Convert our BitVec64 jumpdest validation to sorted array for binary search
4. **Operation Metadata**: Reuse our Operation struct's min_stack, max_stack, constant_gas
5. **Stack Height Changes**: Use our pre-computed STACK_HEIGHT_CHANGES table
6. **Code Analysis Cache**: Our AnalysisLRUCache can cache the analysis results!

## Performance Characteristics

- **Dispatch overhead**: 2 memory loads (instr, fn) + 1 indirect call
- **Block overhead**: ~10-20 instructions amortized over block
- **Jump cost**: O(log n) binary search
- **Memory**: ~2x bytecode size for analysis structures

## Implementation Strategy

### Phase 1: Core Infrastructure
1. Implement Instruction and AdvancedCodeAnalysis structures
2. Create BlockAnalysis helper for tracking block metadata
3. Implement BEGINBLOCK intrinsic for gas/stack validation

### Phase 2: Code Analysis
1. Port EVMOne's analyze() algorithm
2. Convert existing Operation handlers to advanced handlers
3. Implement binary search for jump destinations

### Phase 3: Integration
1. Add advanced mode flag to VM
2. Cache analysis results in our existing AnalysisLRUCache
3. Benchmark against current interpreter

## Critical Differences from Initial Proposal

1. **No jump_target in union** - EVMOne uses binary search at runtime
2. **Block placement** - After JUMPI, not at arbitrary boundaries
3. **Gas correction** - Via arg.number, not separate field
4. **Memory strategy** - Over-allocate based on code size
5. **BEGINBLOCK** - Replaces JUMPDEST, not separate instruction

## Open Questions

- Should we maintain interpreter mode as fallback?
- How to handle code that's hostile to analysis?
- What's the memory overhead vs performance tradeoff?
- Should analysis be cached between executions?