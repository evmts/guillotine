# Phase 3: BEGINBLOCK Intrinsic Implementation

## Objective
Implement the BEGINBLOCK intrinsic operation that performs bulk validation (gas and stack checks) for an entire basic block, eliminating per-instruction validation overhead.

## Background
In traditional interpreters, every opcode checks:
1. Gas availability (compare and branch)
2. Stack underflow (compare and branch) 
3. Stack overflow (compare and branch)

With BEGINBLOCK, we do all checks once per block (10-50 instructions typically), reducing validation overhead by 90%+.

## Dependencies
- Phase 1: Stack pointer refactoring (for fast stack size access)
- Phase 2: Block metadata analysis (provides gas/stack requirements)

## Current State Analysis

### Per-Instruction Validation (Current)
```zig
// Current: Every opcode does this
pub fn op_add(frame: *Frame) !void {
    // Gas check
    if (frame.gas_remaining < 3) return error.OutOfGas;
    frame.gas_remaining -= 3;
    
    // Stack check
    if (frame.stack.size() < 2) return error.StackUnderflow;
    
    // Operation
    const b = try frame.stack.pop();
    const a = try frame.stack.pop();
    try frame.stack.push(a + b);
}
```

### Block Validation (Target)
```zig
// Target: One check per block
pub fn opx_beginblock(frame: *Frame, block: BlockMetadata) !void {
    // Single gas check for entire block
    if (frame.gas_remaining < block.gas_cost) {
        return error.OutOfGas;
    }
    frame.gas_remaining -= block.gas_cost;
    
    // Single stack validation for entire block
    const stack_size = @intCast(i16, frame.stack.size());
    if (stack_size < block.stack_req) {
        return error.StackUnderflow;
    }
    if (stack_size + block.stack_max_growth > Stack.CAPACITY) {
        return error.StackOverflow;
    }
    
    // No validation needed for rest of block!
}
```

## Implementation Steps

### Step 1: Define Intrinsic Opcode
```zig
// In src/evm/opcodes/opcode.zig
pub const intrinsic_opcodes = enum(u8) {
    // EVMone uses JUMPDEST (0x5B) as BEGINBLOCK
    // This is clever: JUMPDEST becomes BEGINBLOCK in advanced mode
    OPX_BEGINBLOCK = 0x5B,
};

// In src/evm/opcodes/operation.zig
pub const IntrinsicOperation = struct {
    execute: *const fn(*Frame, BlockMetadata) ExecutionError!void,
    name: []const u8,
};

pub const intrinsics = [_]IntrinsicOperation{
    .{
        .execute = opx_beginblock,
        .name = "BEGINBLOCK",
    },
};
```

### Step 2: Implement BEGINBLOCK Operation
```zig
// New file: src/evm/execution/intrinsics.zig
const std = @import("std");
const Frame = @import("../frame/frame.zig").Frame;
const BlockMetadata = @import("../frame/code_analysis.zig").BlockMetadata;
const ExecutionError = @import("../execution_error.zig").ExecutionError;
const Stack = @import("../stack/stack.zig").Stack;

/// BEGINBLOCK intrinsic - performs bulk validation for a basic block
pub fn opx_beginblock(frame: *Frame, block: BlockMetadata) ExecutionError!void {
    // Store current block cost for GAS opcode correction
    frame.current_block_cost = block.gas_cost;
    
    // Bulk gas validation
    const gas_left = @intCast(i64, frame.gas_remaining) - @intCast(i64, block.gas_cost);
    if (gas_left < 0) {
        return ExecutionError.OutOfGas;
    }
    
    // Bulk stack validation
    const stack_size = @intCast(i16, frame.stack.size());
    
    // Check minimum stack requirement
    if (stack_size < block.stack_req) {
        return ExecutionError.StackUnderflow;
    }
    
    // Check maximum stack growth won't overflow
    const max_stack = @intCast(i32, stack_size) + @intCast(i32, block.stack_max_growth);
    if (max_stack > Stack.CAPACITY) {
        return ExecutionError.StackOverflow;
    }
    
    // Deduct gas for entire block
    frame.gas_remaining = @intCast(u64, gas_left);
    
    // Mark that we're in validated block (for debugging)
    if (builtin.mode == .Debug) {
        frame.in_validated_block = true;
        frame.block_end_pc = frame.pc + block.size;
    }
}

/// Special handling for GAS opcode within blocks
pub fn op_gas_with_correction(frame: *Frame) ExecutionError!void {
    // The GAS opcode needs to return gas AFTER the current instruction
    // But we've already deducted the entire block's gas
    // So we need to add back the gas not yet consumed in this block
    
    const gas_correction = frame.current_block_cost - frame.block_gas_consumed;
    const corrected_gas = frame.gas_remaining + gas_correction;
    
    try frame.stack.push(@intCast(u256, corrected_gas));
    frame.block_gas_consumed += 1; // GAS opcode costs 1 gas
}
```

### Step 3: Modify Execution Loop
```zig
// In src/evm/evm/interpret.zig
pub fn interpret(frame: *Frame) !void {
    const analysis = frame.contract.code_analysis orelse {
        // Fallback to traditional interpreter
        return interpretTraditional(frame);
    };
    
    // Start with first block
    var current_block_index: usize = 0;
    
    while (frame.pc < frame.contract.code.len) {
        // Check if we're entering a new block
        if (frame.pc == analysis.blocks[current_block_index].start_pc) {
            const block = analysis.blocks[current_block_index];
            
            // Execute BEGINBLOCK for validation
            try opx_beginblock(frame, block.metadata);
            
            // Execute instructions in block without validation
            while (frame.pc < block.end_pc) {
                const opcode = frame.contract.code[frame.pc];
                frame.pc += 1;
                
                // Use unsafe operations (no validation)
                const op = jump_table.get_operation_unsafe(opcode);
                try op.execute_unsafe(frame);
            }
            
            current_block_index += 1;
        }
    }
}
```

### Step 4: Create Unsafe Operation Variants
```zig
// In src/evm/execution/arithmetic.zig
pub fn op_add_unsafe(frame: *Frame) void {
    // No gas check - already done by BEGINBLOCK
    // No stack check - already validated
    const b = frame.stack.pop_unsafe();
    const a = frame.stack.pop_unsafe();
    frame.stack.push_unsafe(a +% b);
}

// Similar for all other operations...
```

### Step 5: Handle Dynamic Gas Operations
```zig
// Operations with dynamic gas need special handling
pub fn op_sstore_with_block(frame: *Frame, block_gas_consumed: u32) !void {
    // Add back unused block gas for dynamic calculation
    const gas_correction = frame.current_block_cost - block_gas_consumed;
    frame.gas_remaining += gas_correction;
    
    // Now calculate dynamic gas normally
    const key = frame.stack.pop_unsafe();
    const value = frame.stack.pop_unsafe();
    const gas_cost = try calculateSstoreGas(frame, key, value);
    
    if (frame.gas_remaining < gas_cost) {
        return error.OutOfGas;
    }
    frame.gas_remaining -= gas_cost;
    
    // Perform operation
    try frame.state.sstore(frame.contract.address, key, value);
    
    // Subtract correction again
    frame.gas_remaining -= gas_correction;
}
```

## Testing Requirements

### Unit Tests
```zig
test "BEGINBLOCK validates entire block" {
    var frame = try Frame.init(...);
    defer frame.deinit();
    
    const block = BlockMetadata{
        .gas_cost = 100,
        .stack_req = 2,
        .stack_max_growth = 3,
    };
    
    // Test gas validation
    frame.gas_remaining = 99;
    try expectError(error.OutOfGas, opx_beginblock(&frame, block));
    
    frame.gas_remaining = 100;
    try opx_beginblock(&frame, block);
    try expectEqual(@as(u64, 0), frame.gas_remaining);
    
    // Test stack validation
    frame.gas_remaining = 1000;
    try expectError(error.StackUnderflow, opx_beginblock(&frame, block));
    
    try frame.stack.push(1);
    try frame.stack.push(2);
    try opx_beginblock(&frame, block);
}
```

### Integration Tests
1. Run entire test suite with BEGINBLOCK enabled
2. Verify gas consumption matches traditional interpreter
3. Test edge cases: single-instruction blocks, empty blocks

### Performance Tests
1. Measure reduction in validation overhead
2. Compare branch prediction statistics
3. Test with various block sizes

## Success Criteria

### Functional
- [ ] All validation happens at block boundaries
- [ ] Gas consumption identical to traditional mode
- [ ] Correct handling of dynamic gas operations
- [ ] All tests pass

### Performance
- [ ] 30-40% reduction in validation overhead
- [ ] Improved branch prediction (fewer checks)
- [ ] Measurable speedup on benchmarks

### Code Quality
- [ ] Clear separation of safe/unsafe operations
- [ ] Well-documented gas correction logic
- [ ] Maintainable dual-mode execution

## Benchmarking

### Validation Overhead
```zig
fn benchmarkValidationOverhead() !void {
    // Measure validation cost
    const iterations = 1000000;
    
    // Traditional: validation every operation
    var trad_start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        if (gas < 3) return error.OutOfGas;
        gas -= 3;
        if (stack_size < 2) return error.StackUnderflow;
    }
    const trad_elapsed = std.time.nanoTimestamp() - trad_start;
    
    // BEGINBLOCK: validation once per ~20 operations
    var block_start = std.time.nanoTimestamp();
    for (0..iterations / 20) |_| {
        if (gas < 60) return error.OutOfGas;
        gas -= 60;
        if (stack_size < 2) return error.StackUnderflow;
    }
    const block_elapsed = std.time.nanoTimestamp() - block_start;
    
    std.debug.print("Traditional: {}ns, BEGINBLOCK: {}ns, Speedup: {}x\n", 
        .{trad_elapsed, block_elapsed, trad_elapsed / block_elapsed});
}
```

## Risk Mitigation

### Correctness
- Extensive testing of gas correction logic
- Fuzzing with random block structures
- Comparison with evmone behavior

### Compatibility
- Maintain traditional interpreter as fallback
- Gradual rollout with feature flag
- A/B testing in production

### Edge Cases
- Handle blocks with no gas cost
- Support dynamic jumps correctly
- Deal with gas exhaustion mid-block

## Reference Implementation

EVMone's approach:
- `evmone/lib/evmone/advanced_instructions.cpp` - opx_beginblock
- They replace JUMPDEST with BEGINBLOCK seamlessly
- Gas correction stored in instruction.arg.number

## Next Phase Dependencies

This phase enables:
- Phase 5: Instruction stream (needs BEGINBLOCK in stream)
- Phase 6: Advanced execution (uses BEGINBLOCK for validation)
- Better performance for all subsequent phases