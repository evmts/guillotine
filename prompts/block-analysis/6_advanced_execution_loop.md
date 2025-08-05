# Phase 6: Advanced Execution Loop

## Objective
Implement the main advanced interpreter execution loop that processes the instruction stream generated in Phase 5, achieving 2x or better performance improvement over the traditional bytecode interpreter.

## Background
This is the culmination of all previous phases. The advanced execution loop:
1. Processes pre-analyzed instruction streams
2. Uses pointer-based stack operations (Phase 1)
3. Leverages block validation (Phase 3)
4. Employs optimized jump resolution (Phase 4)
5. Executes without bytecode decoding overhead

## Dependencies
- All previous phases (1-5) must be complete
- Instruction stream generation
- BEGINBLOCK intrinsic
- Pointer-based stack
- Jump analysis

## Architecture Overview

### Execution State
```zig
pub const AdvancedExecutionState = struct {
    // Core VM state
    frame: *Frame,
    interpreter: *Vm,
    
    // Advanced mode specific
    gas_left: i64,                          // Signed for underflow detection
    stack: [*]u256,                         // Stack pointer (from Phase 1)
    stack_bottom: [*]const u256,           // Base of stack
    instructions: []const Instruction,      // Instruction stream
    jump_analysis: *const JumpAnalysis,    // Jump targets
    
    // Block execution state
    current_block_cost: u32,               // For GAS opcode correction
    block_gas_consumed: u32,               // Track consumption within block
    
    pub fn init(frame: *Frame, stream: *const InstructionStream) AdvancedExecutionState {
        return .{
            .frame = frame,
            .interpreter = frame.interpreter,
            .gas_left = @intCast(i64, frame.gas_remaining),
            .stack = frame.stack.data.ptr,
            .stack_bottom = frame.stack.data.ptr,
            .instructions = stream.instructions.items,
            .jump_analysis = &frame.contract.jump_analysis,
            .current_block_cost = 0,
            .block_gas_consumed = 0,
        };
    }
    
    // Stack operations (inlined for performance)
    pub inline fn stack_push(self: *AdvancedExecutionState, value: u256) void {
        self.stack[0] = value;
        self.stack += 1;
    }
    
    pub inline fn stack_pop(self: *AdvancedExecutionState) u256 {
        self.stack -= 1;
        return self.stack[0];
    }
    
    pub inline fn stack_top(self: *AdvancedExecutionState) *u256 {
        return &self.stack[-1];
    }
    
    pub inline fn stack_size(self: *const AdvancedExecutionState) usize {
        return @intCast(usize, @divExact(@ptrToInt(self.stack) - @ptrToInt(self.stack_bottom), @sizeOf(u256)));
    }
    
    pub fn exit(self: *AdvancedExecutionState, status: ExecutionError) ?*const Instruction {
        self.frame.status = status;
        return null;
    }
};
```

### Main Execution Loop
```zig
pub fn executeAdvanced(
    frame: *Frame,
    stream: *const InstructionStream,
    jump_analysis: *const JumpAnalysis,
) ExecutionError!void {
    var state = AdvancedExecutionState.init(frame, stream);
    
    // Start at first instruction
    var instr: ?*const Instruction = &stream.instructions.items[0];
    
    // EVMone's exact dispatch loop - minimal overhead
    while (instr) |current| {
        instr = current.fn(current, &state);
    }
    
    // Update frame with final state
    frame.gas_remaining = if (state.gas_left > 0) 
        @intCast(u64, state.gas_left) 
    else 
        0;
    
    // Update stack size
    frame.stack.items.len = state.stack_size();
}
```

## Implementation Steps

### Step 1: Create Advanced Execution Module
```zig
// New file: src/evm/advanced/execute.zig
const std = @import("std");
const Frame = @import("../frame/frame.zig").Frame;
const Vm = @import("../evm.zig").Vm;
const ExecutionError = @import("../execution_error.zig").ExecutionError;
const Instruction = @import("instruction.zig").Instruction;
const InstructionStream = @import("instruction.zig").InstructionStream;
const JumpAnalysis = @import("../frame/code_analysis.zig").JumpAnalysis;

pub const AdvancedMode = struct {
    enabled: bool = false,
    cache_analysis: bool = true,
    optimize_patterns: bool = true,
    
    pub fn shouldUseAdvanced(self: AdvancedMode, code_size: usize) bool {
        // Use advanced mode for contracts > 100 bytes
        return self.enabled and code_size > 100;
    }
};
```

### Step 2: Implement Core Advanced Operations
```zig
// Arithmetic operations - no validation needed
pub fn op_add_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const b = state.stack_pop();
    const a = state.stack_top().*;
    state.stack_top().* = a +% b;
    return instr + 1;
}

pub fn op_mul_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const b = state.stack_pop();
    const a = state.stack_top().*;
    state.stack_top().* = a *% b;
    return instr + 1;
}

// Stack operations
pub fn op_dup1_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const value = state.stack[-1];
    state.stack_push(value);
    return instr + 1;
}

pub fn op_swap1_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const tmp = state.stack[-1];
    state.stack[-1] = state.stack[-2];
    state.stack[-2] = tmp;
    return instr + 1;
}

// Memory operations
pub fn op_mload_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const offset = state.stack_pop();
    
    // Memory expansion cost handled by BEGINBLOCK
    const value = state.frame.memory.read_word(@intCast(usize, offset));
    state.stack_push(value);
    
    return instr + 1;
}

pub fn op_mstore_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const offset = state.stack_pop();
    const value = state.stack_pop();
    
    state.frame.memory.write_word(@intCast(usize, offset), value);
    
    return instr + 1;
}
```

### Step 3: Control Flow Operations
```zig
pub fn op_jump_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const dest = state.stack_pop();
    
    // Fast bounds check
    if (dest > std.math.maxInt(u32)) {
        return state.exit(ExecutionError.InvalidJump);
    }
    
    // Binary search for jump target (from Phase 4)
    const target_index = state.jump_analysis.getJumpTarget(@intCast(u32, dest)) orelse {
        return state.exit(ExecutionError.InvalidJump);
    };
    
    return &state.instructions[target_index];
}

pub fn op_jumpi_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const dest = state.stack_pop();
    const condition = state.stack_pop();
    
    if (condition != 0) {
        // Take jump
        if (dest > std.math.maxInt(u32)) {
            return state.exit(ExecutionError.InvalidJump);
        }
        
        const target_index = state.jump_analysis.getJumpTarget(@intCast(u32, dest)) orelse {
            return state.exit(ExecutionError.InvalidJump);
        };
        
        return &state.instructions[target_index];
    }
    
    // Fall through
    return instr + 1;
}

pub fn op_pc_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    // PC was pre-computed during analysis
    state.stack_push(@intCast(u256, instr.arg.number));
    return instr + 1;
}
```

### Step 4: System Operations
```zig
pub fn op_call_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    // Restore gas for dynamic calculation
    const gas_correction = @intCast(i64, state.current_block_cost - state.block_gas_consumed);
    state.gas_left += gas_correction;
    
    // Read call parameters
    const gas = state.stack_pop();
    const address = state.stack_pop();
    const value = state.stack_pop();
    const args_offset = state.stack_pop();
    const args_size = state.stack_pop();
    const ret_offset = state.stack_pop();
    const ret_size = state.stack_pop();
    
    // Calculate dynamic gas
    const call_gas = calculateCallGas(gas, value, state.gas_left);
    
    if (state.gas_left < call_gas) {
        // Push failure, continue execution
        state.stack_push(0);
        state.gas_left -= gas_correction;
        return instr + 1;
    }
    
    // Perform call
    const result = state.interpreter.call(
        address,
        value,
        args_offset,
        args_size,
        ret_offset,
        ret_size,
        call_gas,
    );
    
    state.stack_push(if (result) 1 else 0);
    
    // Restore block gas tracking
    state.gas_left -= gas_correction;
    
    return instr + 1;
}

pub fn op_return_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const offset = state.stack_pop();
    const size = state.stack_pop();
    
    // Set return data
    state.frame.return_data = state.frame.memory.read(@intCast(usize, offset), @intCast(usize, size));
    
    return state.exit(ExecutionError.Success);
}
```

### Step 5: Integration with VM
```zig
// In src/evm/evm.zig
pub const Vm = struct {
    // ... existing fields ...
    advanced_mode: AdvancedMode,
    analysis_cache: LruCache(Hash, InstructionStream),
    
    pub fn execute(self: *Vm, frame: *Frame) !void {
        // Check if we should use advanced mode
        if (self.advanced_mode.shouldUseAdvanced(frame.contract.code.len)) {
            // Try to get cached analysis
            const cache_key = hash(frame.contract.code);
            const stream = self.analysis_cache.get(cache_key) orelse blk: {
                // Generate instruction stream
                const new_stream = try generateInstructionStream(
                    self.allocator,
                    frame.contract.code,
                    frame.contract.blocks,
                    &self.jump_table,
                );
                
                if (self.advanced_mode.cache_analysis) {
                    try self.analysis_cache.put(cache_key, new_stream);
                }
                
                break :blk new_stream;
            };
            
            // Execute in advanced mode
            try executeAdvanced(frame, stream, &frame.contract.jump_analysis);
        } else {
            // Fall back to traditional interpreter
            try executeTraditional(frame);
        }
    }
};
```

### Step 6: Optimized Patterns
```zig
// Superinstructions for common patterns
pub fn op_push1_add_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    // Combines PUSH1 + ADD into single operation
    const a = state.stack_top().*;
    state.stack_top().* = a +% instr.arg.small_push_value;
    return instr + 1;
}

pub fn op_iszero_jumpi_advanced(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    // Combines ISZERO + JUMPI
    const value = state.stack_pop();
    const dest = state.stack_pop();
    
    if (value == 0) {
        // Take jump
        const target_index = state.jump_analysis.getJumpTarget(@intCast(u32, dest)) orelse {
            return state.exit(ExecutionError.InvalidJump);
        };
        return &state.instructions[target_index];
    }
    
    return instr + 1;
}
```

## Testing Requirements

### Correctness Tests
```zig
test "advanced execution matches traditional" {
    const bytecodes = [_][]const u8{
        @embedFile("test_contracts/factorial.bin"),
        @embedFile("test_contracts/fibonacci.bin"),
        @embedFile("test_contracts/erc20.bin"),
    };
    
    for (bytecodes) |bytecode| {
        // Execute in traditional mode
        var trad_frame = try Frame.init(...);
        try executeTraditional(&trad_frame);
        const trad_result = trad_frame.return_data;
        const trad_gas = trad_frame.gas_remaining;
        
        // Execute in advanced mode
        var adv_frame = try Frame.init(...);
        const stream = try generateInstructionStream(...);
        try executeAdvanced(&adv_frame, stream, ...);
        const adv_result = adv_frame.return_data;
        const adv_gas = adv_frame.gas_remaining;
        
        // Results must match exactly
        try expectEqualSlices(u8, trad_result, adv_result);
        try expectEqual(trad_gas, adv_gas);
    }
}
```

### Performance Tests
```zig
test "advanced mode performance improvement" {
    const bytecode = @embedFile("bench/snailtracer.bin");
    
    // Benchmark traditional mode
    const trad_start = std.time.nanoTimestamp();
    for (0..100) |_| {
        var frame = try Frame.init(...);
        try executeTraditional(&frame);
    }
    const trad_time = std.time.nanoTimestamp() - trad_start;
    
    // Benchmark advanced mode
    const stream = try generateInstructionStream(...);
    const adv_start = std.time.nanoTimestamp();
    for (0..100) |_| {
        var frame = try Frame.init(...);
        try executeAdvanced(&frame, stream, ...);
    }
    const adv_time = std.time.nanoTimestamp() - adv_start;
    
    const speedup = @intToFloat(f64, trad_time) / @intToFloat(f64, adv_time);
    std.debug.print("Speedup: {.2}x\n", .{speedup});
    
    // Should achieve at least 2x speedup
    try expect(speedup >= 2.0);
}
```

## Success Criteria

### Functional
- [ ] All opcodes implemented in advanced mode
- [ ] Identical execution results to traditional mode
- [ ] Correct gas accounting
- [ ] All existing tests pass

### Performance
- [ ] 2x or better performance on snailtracer
- [ ] Reduced CPU cycles per instruction
- [ ] Better branch prediction statistics
- [ ] Lower cache miss rate

### Code Quality
- [ ] Clean integration with existing VM
- [ ] Well-documented execution flow
- [ ] Maintainable dual-mode architecture

## Benchmarking

### Official Benchmarks
```bash
# Build with advanced mode
zig build build-evm-runner -Doptimize=ReleaseFast -Dadvanced=true

# Run benchmarks
hyperfine --warmup 3 --runs 10 \
    "./zig-out/bin/evm-runner --mode=traditional bench/snailtracer.bin" \
    "./zig-out/bin/evm-runner --mode=advanced bench/snailtracer.bin"
```

### Expected Results
- snailtracer: 2-3x faster
- ten-thousand-hashes: 1.5-2x faster
- erc20-transfer: 1.3-1.5x faster

## Risk Mitigation

### Correctness
- Extensive differential testing
- Fuzzing both modes with same inputs
- Verify gas consumption matches exactly

### Performance Regression
- Profile both modes thoroughly
- Monitor cache behavior
- Ensure stream generation doesn't dominate

### Maintenance
- Keep both modes working
- Clear mode selection logic
- Document performance characteristics

## Reference Implementation

EVMone's execution:
- `evmone/lib/evmone/advanced_execution.cpp`
- Simple dispatch loop with function pointers
- No branch prediction hints needed (CPU figures it out)

## Success Metrics

This completes the advanced interpreter implementation. Expected outcomes:
- 2-3x performance improvement on compute-heavy workloads
- Maintained correctness and gas accuracy
- Production-ready dual-mode execution
- Foundation for future optimizations