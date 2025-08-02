# Implement Threaded Code Execution for Indirect Call Threading

## Overview

This prompt describes how to implement evmone-style threaded code execution in the Zig EVM to eliminate interpreter loop overhead through indirect call threading, where each instruction directly calls the next without returning to a central dispatch loop.

## Background: evmone's Threaded Code Architecture

evmone's advanced interpreter implements indirect call threading as described in their documentation:

> "The _indirect call threading_ is the dispatch method used - a loaded EVM program is a table with pointers to functions implementing virtual instructions."

### Key Implementation Details

1. **Instruction Structure**:
```cpp
struct Instruction {
    instruction_exec_fn fn = nullptr;    // Function pointer
    InstructionArgument arg;             // Embedded argument
};

using instruction_exec_fn = const Instruction* (*)(const Instruction*, AdvancedExecutionState&);
```

2. **Execution Loop**:
```cpp
const auto* instr = state.analysis.advanced->instrs.data();
while (instr != nullptr)
    instr = instr->fn(instr, state);  // Each instruction returns the next
```

3. **Instruction Implementation Pattern**:
```cpp
// Normal progression
template <void InstrFn(AdvancedExecutionState&) noexcept>
const Instruction* op(const Instruction* instr, AdvancedExecutionState& state) noexcept {
    InstrFn(state);
    return ++instr;  // Return next instruction
}

// Control flow
const Instruction* op_jump(const Instruction*, AdvancedExecutionState& state) noexcept {
    const auto dst = state.stack.pop();
    auto pc = find_jumpdest(*state.analysis.advanced, static_cast<int>(dst));
    if (pc < 0)
        return state.exit(EVMC_BAD_JUMP_DESTINATION);
    return &state.analysis.advanced->instrs[static_cast<size_t>(pc)];  // Direct jump
}
```

### Performance Benefits

- **No interpreter loop overhead**: Direct function-to-function calls
- **Better CPU pipeline utilization**: Predictable call/return patterns
- **Improved branch prediction**: No central dispatch point
- **Cache efficiency**: Linear instruction access pattern

## Current State Analysis

### Strengths Already in Place

1. **Efficient Dispatch** (`interpret.zig`):
   - Pre-computed `pc_to_op_entries` table eliminates decoding
   - Direct function pointer dispatch (no switch statement)
   - Block-level gas and stack validation

2. **Comprehensive Analysis** (`single_pass_analysis.zig`):
   - Single-pass bytecode analysis
   - Pre-computed operation metadata
   - Jump destination validation

3. **Operation Architecture** (`operation.zig`):
   - Clean function pointer design
   - Consistent execution signatures
   - Separation of concerns

### Current Inefficiencies

1. **Traditional Interpreter Loop**:
```zig
while (pc < contract.code_size) {
    // Fetch operation
    const entry = pc_to_op_entry_table[pc_index];
    // Execute
    const exec_result = operation.execute(pc, interpreter, state);
    // Update PC
    pc += result.bytes_consumed;
}
```

2. **Loop Overhead Per Instruction**:
   - Condition check: `pc < contract.code_size`
   - PC arithmetic: `pc += bytes_consumed`
   - Loop branch: Jump back to loop start
   - Branch misprediction potential

3. **Async Analysis** (needs removal):
   - Current code attempts async analysis on non-WASM
   - Threaded execution requires complete analysis upfront

## Proposed Implementation

### 1. Core Threaded Instruction Structure

Create a unified instruction representation that combines operation and argument:

```zig
// In frame/advanced_instruction.zig

pub const ThreadedInstruction = struct {
    /// Function that executes instruction and returns next
    exec_fn: ThreadedExecFunc,
    
    /// Pre-extracted/computed argument
    arg: InstructionArg,
    
    /// Metadata for optimization
    meta: InstructionMeta,
};

pub const ThreadedExecFunc = *const fn (
    instr: *const ThreadedInstruction,
    state: *Frame
) ?*const ThreadedInstruction;

pub const InstructionArg = union(enum) {
    none: void,
    small_push: u64,              // PUSH1-PUSH8 embedded
    large_push_idx: u32,          // Index into separate array
    pc_value: u32,                // For PC opcode
    gas_correction: i32,          // For GAS opcode
    block_info: BlockInfo,        // For block boundaries
    jump_dest_idx: u32,           // Pre-validated jump target
};

pub const InstructionMeta = packed struct {
    /// Original bytecode size (1-33 bytes)
    size: u6,
    /// Whether this starts a new block
    is_block_start: bool,
    /// Reserved for future use
    reserved: u1 = 0,
};

pub const BlockInfo = struct {
    gas_cost: u32,
    stack_req: u16,
    stack_max_growth: u16,
};
```

### 2. Instruction Implementation Patterns

Following evmone's pattern, create wrapper functions and specific implementations:

```zig
// In execution/threaded_ops.zig

/// Generic wrapper for simple operations
fn makeThreadedOp(comptime op_fn: fn(*Frame) void) ThreadedExecFunc {
    return struct {
        fn exec(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
            op_fn(state);
            return instr + 1;
        }
    }.exec;
}

/// Wrapper for operations that can fail
fn makeThreadedOpWithError(comptime op_fn: fn(*Frame) !void) ThreadedExecFunc {
    return struct {
        fn exec(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
            op_fn(state) catch return null;
            return instr + 1;
        }
    }.exec;
}

// Arithmetic operations
pub const op_add_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        state.stack.push_unsafe(a +% b);
    }
}.op);

// Stack operations with embedded values
pub fn op_push_small_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    state.stack.push_unsafe(@as(u256, instr.arg.small_push));
    return instr + 1;
}

pub fn op_push_large_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    const value = state.push_values[instr.arg.large_push_idx];
    state.stack.push_unsafe(value);
    return instr + 1;
}

// Control flow
pub fn op_jump_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    const target = state.stack.pop_unsafe();
    
    // Use pre-validated jump destination
    if (target > std.math.maxInt(u32)) return null;
    const target_idx = state.jumpdest_map.get(@intCast(u32, target)) orelse return null;
    
    return &state.instructions[target_idx];
}

pub fn op_jumpi_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    const target = state.stack.pop_unsafe();
    const condition = state.stack.pop_unsafe();
    
    if (condition != 0) {
        if (target > std.math.maxInt(u32)) return null;
        const target_idx = state.jumpdest_map.get(@intCast(u32, target)) orelse return null;
        return &state.instructions[target_idx];
    }
    
    return instr + 1;
}

// Block boundaries
pub fn opx_beginblock_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    const block = instr.arg.block_info;
    
    // Consume gas for entire block
    if (state.gas_remaining < block.gas_cost) return null;
    state.gas_remaining -= block.gas_cost;
    
    // Validate stack requirements
    const stack_size = @intCast(i32, state.stack.size());
    if (stack_size < block.stack_req) return null;
    if (stack_size + block.stack_max_growth > Stack.CAPACITY) return null;
    
    state.current_block_gas = block.gas_cost;
    return instr + 1;
}

// Termination
pub fn op_stop_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    _ = instr;
    state.return_reason = .Stop;
    return null;
}

// Operations with embedded PC value
pub fn op_pc_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    state.stack.push_unsafe(@as(u256, instr.arg.pc_value));
    return instr + 1;
}

// Operations with gas correction
pub fn op_gas_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    const correction = state.current_block_gas - instr.arg.gas_correction;
    const gas = @intCast(u256, state.gas_remaining + correction);
    state.stack.push_unsafe(gas);
    return instr + 1;
}
```

### 3. Enhanced Analysis for Threaded Code

Modify analysis to build threaded instruction stream:

```zig
// In single_pass_analysis.zig

pub const ThreadedAnalysis = struct {
    /// Array of threaded instructions
    instructions: []ThreadedInstruction,
    
    /// Storage for large PUSH values
    push_values: []const u256,
    
    /// Jump destination mapping (PC -> instruction index)
    jumpdest_map: std.AutoHashMap(u32, u32),
    
    /// Block information
    blocks: []const BlockInfo,
};

pub fn analyzeThreaded(
    allocator: std.mem.Allocator,
    code: []const u8,
    code_hash: primitives.Hash,
    jump_table: *const JumpTable,
) !ThreadedAnalysis {
    var instructions = std.ArrayList(ThreadedInstruction).init(allocator);
    defer instructions.deinit();
    
    var push_values = std.ArrayList(u256).init(allocator);
    defer push_values.deinit();
    
    var jumpdest_map = std.AutoHashMap(u32, u32).init(allocator);
    defer jumpdest_map.deinit();
    
    var block_analysis = BlockAnalyzer.init();
    var i: usize = 0;
    
    while (i < code.len) {
        const op = code[i];
        const operation = jump_table.table[op];
        
        // Check for block boundaries
        if (op == 0x5b or block_analysis.should_split()) { // JUMPDEST
            if (instructions.items.len > 0) {
                // Insert block begin instruction
                const block_info = block_analysis.finalize();
                try instructions.append(.{
                    .exec_fn = opx_beginblock_threaded,
                    .arg = .{ .block_info = block_info },
                    .meta = .{ .size = 0, .is_block_start = true },
                });
            }
            block_analysis.reset();
            
            // Record jump destination
            if (op == 0x5b) {
                try jumpdest_map.put(@intCast(u32, i), @intCast(u32, instructions.items.len));
            }
        }
        
        // Build instruction based on opcode
        var instr = ThreadedInstruction{
            .exec_fn = getThreadedFunction(op),
            .arg = .{ .none = {} },
            .meta = .{ .size = 1, .is_block_start = false },
        };
        
        // Extract arguments
        switch (op) {
            0x60...0x7f => { // PUSH1-PUSH32
                const push_size = op - 0x5f;
                instr.meta.size = 1 + push_size;
                
                if (i + push_size < code.len) {
                    if (push_size <= 8) {
                        // Small push - embed directly
                        var value: u64 = 0;
                        for (0..push_size) |j| {
                            value = (value << 8) | code[i + 1 + j];
                        }
                        instr.arg = .{ .small_push = value };
                        instr.exec_fn = op_push_small_threaded;
                    } else {
                        // Large push - store separately
                        var value: u256 = 0;
                        for (0..push_size) |j| {
                            value = (value << 8) | code[i + 1 + j];
                        }
                        instr.arg = .{ .large_push_idx = @intCast(u32, push_values.items.len) };
                        try push_values.append(value);
                        instr.exec_fn = op_push_large_threaded;
                    }
                }
            },
            
            0x58 => { // PC
                instr.arg = .{ .pc_value = @intCast(u32, i) };
                instr.exec_fn = op_pc_threaded;
            },
            
            0x5a => { // GAS
                instr.arg = .{ .gas_correction = block_analysis.gas_used };
                instr.exec_fn = op_gas_threaded;
            },
            
            else => {},
        }
        
        // Update block analysis
        block_analysis.addInstruction(operation);
        
        try instructions.append(instr);
        i += instr.meta.size;
    }
    
    // Finalize last block
    if (instructions.items.len > 0) {
        const block_info = block_analysis.finalize();
        try instructions.insert(instructions.items.len - 1, .{
            .exec_fn = opx_beginblock_threaded,
            .arg = .{ .block_info = block_info },
            .meta = .{ .size = 0, .is_block_start = true },
        });
    }
    
    return ThreadedAnalysis{
        .instructions = try instructions.toOwnedSlice(),
        .push_values = try push_values.toOwnedSlice(),
        .jumpdest_map = jumpdest_map,
        .blocks = block_analysis.blocks,
    };
}
```

### 4. Threaded Interpreter Implementation

Replace the traditional interpreter loop:

```zig
// In interpret.zig

/// Execute using threaded code (indirect call threading)
fn interpretThreaded(
    self: *Vm,
    contract: *Contract,
    input: []const u8,
    is_static: bool,
) ExecutionError.Error!RunResult {
    // Remove async analysis - must be synchronous
    if (contract.threaded_analysis == null and contract.code_size > 0) {
        contract.threaded_analysis = try analyzeThreaded(
            self.allocator,
            contract.code,
            contract.code_hash,
            &self.table,
        );
    }
    
    const analysis = contract.threaded_analysis orelse return error.AnalysisRequired;
    
    // Create frame with threaded execution context
    var frame = Frame{
        .vm = self,
        .contract = contract,
        .gas_remaining = contract.gas,
        .caller = contract.caller,
        .input = input,
        .is_static = self.read_only or is_static,
        .depth = @intCast(u32, self.depth),
        // Threaded-specific fields
        .instructions = analysis.instructions,
        .push_values = analysis.push_values,
        .jumpdest_map = &analysis.jumpdest_map,
        .current_block_gas = 0,
        .return_reason = .Continue,
    };
    defer frame.deinit();
    
    // Initialize stack
    frame.stack.ensureInitialized();
    
    // CRITICAL: The threaded execution loop
    var instr: ?*const ThreadedInstruction = &analysis.instructions[0];
    while (instr) |current| {
        instr = current.exec_fn(current, &frame);
    }
    
    // Handle results based on return reason
    contract.gas = frame.gas_remaining;
    self.return_data = &[_]u8{};
    
    const output = if (frame.output.len > 0)
        try self.allocator.dupe(u8, frame.output)
    else
        null;
    
    return RunResult.init(
        contract.gas,
        frame.gas_remaining,
        switch (frame.return_reason) {
            .Stop => .Success,
            .Return => .Success,
            .Revert => .Revert,
            .OutOfGas => .OutOfGas,
            else => .Invalid,
        },
        null,
        output,
    );
}

// Update main interpret function
pub fn interpret(
    self: *Vm,
    contract: *Contract,
    input: []const u8,
    is_static: bool,
) ExecutionError.Error!RunResult {
    // Always remove async analysis attempts
    if (contract.analysis == null and contract.code_size > 0) {
        contract.analysis = try Contract.analyze_code(
            self.allocator,
            contract.code,
            contract.code_hash,
            &self.table,
        );
    }
    
    // Try threaded execution if supported
    if (build_options.enable_threaded_execution) {
        return interpretThreaded(self, contract, input, is_static);
    }
    
    // ... existing interpreter code ...
}
```

### 5. Operation Mapping

Create a mapping from opcodes to threaded functions:

```zig
// In execution/threaded_ops.zig

pub fn getThreadedFunction(opcode: u8) ThreadedExecFunc {
    return switch (opcode) {
        // Arithmetic
        0x01 => op_add_threaded,
        0x02 => op_mul_threaded,
        0x03 => op_sub_threaded,
        0x04 => op_div_threaded,
        // ... all arithmetic ops
        
        // Stack operations handled specially for PUSH
        0x50 => op_pop_threaded,
        0x51 => op_mload_threaded,
        0x52 => op_mstore_threaded,
        // ... memory ops
        
        // Control flow
        0x56 => op_jump_threaded,
        0x57 => op_jumpi_threaded,
        0x58 => op_pc_threaded,  // Special handling
        0x5a => op_gas_threaded,  // Special handling
        0x5b => op_jumpdest_threaded,
        
        // System
        0x00 => op_stop_threaded,
        0xf3 => op_return_threaded,
        0xfd => op_revert_threaded,
        0xff => op_selfdestruct_threaded,
        
        // DUP operations
        0x80...0x8f => makeDupThreaded(opcode - 0x7f),
        
        // SWAP operations  
        0x90...0x9f => makeSwapThreaded(opcode - 0x8f),
        
        // LOG operations
        0xa0...0xa4 => makeLogThreaded(opcode - 0xa0),
        
        // Invalid/undefined
        else => op_invalid_threaded,
    };
}
```

## Memory Layout and Performance Optimization

### Instruction Memory Layout
```
ThreadedInstruction size: 24 bytes
- exec_fn: 8 bytes (function pointer)
- arg: 8 bytes (union)  
- meta: 1 byte (packed struct)
- padding: 7 bytes

Optimized for:
- 8-byte alignment for function pointers
- Sequential access pattern
- Efficient cache line usage (2-3 instructions per 64-byte line)
```

### Execution State Layout
```zig
// Frame fields ordered for cache efficiency
pub const Frame = struct {
    // Hot fields (accessed every instruction)
    stack: Stack,                    // 32KB pre-allocated
    gas_remaining: i64,              // 8 bytes
    instructions: []ThreadedInstruction, // 8 bytes (slice)
    
    // Warm fields (accessed occasionally)
    memory: Memory,                  // Memory management
    jumpdest_map: *std.AutoHashMap, // Jump resolution
    push_values: []const u256,       // Large constants
    
    // Cold fields (rarely accessed)
    vm: *Vm,
    contract: *Contract,
    return_data: []u8,
    logs: std.ArrayList(Log),
};
```

## Implementation Steps

### Phase 1: Foundation (1 day)
1. Remove async analysis from `interpret.zig`
   - Delete lines 48-72 (async analysis attempts)
   - Always use synchronous `Contract.analyze_code`
2. Create `frame/advanced_instruction.zig`
   - Define `ThreadedInstruction` structure
   - Define `InstructionArg` union
   - Define `ThreadedExecFunc` signature

### Phase 2: Core Operations (3 days)
1. Create `execution/threaded_ops.zig`
   - Implement wrapper generators (`makeThreadedOp`)
   - Convert all 140+ operations to threaded style
   - Special handling for PUSH, PC, GAS, jumps
2. Test each operation category:
   - Arithmetic (ADD, SUB, MUL, DIV, etc.)
   - Stack operations (DUP1-16, SWAP1-16)
   - Memory operations (MLOAD, MSTORE, etc.)
   - Control flow (JUMP, JUMPI, STOP, RETURN)

### Phase 3: Analysis Enhancement (2 days)
1. Create `analyzeThreaded` in `single_pass_analysis.zig`
   - Build `ThreadedInstruction` array
   - Extract PUSH arguments
   - Insert block boundary instructions
   - Build jump destination mapping
2. Integrate with existing analysis infrastructure
   - Reuse block analysis logic
   - Maintain compatibility with existing analysis

### Phase 4: Threaded Interpreter (2 days)
1. Implement `interpretThreaded` in `interpret.zig`
   - Minimal execution loop (3 lines!)
   - Proper frame initialization
   - Result handling
2. Update main `interpret` function
   - Check for threaded support
   - Fallback to traditional execution
3. Update `Contract` structure
   - Add `threaded_analysis` field
   - Ensure proper cleanup in `deinit`

### Phase 5: Integration and Testing (2 days)
1. Update build configuration
   - Add `enable_threaded_execution` flag
   - Allow runtime selection
2. Create comprehensive tests
   - Correctness tests for all operations
   - Stress tests for control flow
   - Performance benchmarks
3. Debug and optimize
   - Profile execution paths
   - Optimize hot operations
   - Tune memory layout

## Expected Performance Impact

### Improvements (based on evmone results)
- **Loop Overhead**: ~15-20% reduction in CPU cycles
- **Branch Mispredictions**: 50-70% fewer mispredictions
- **Instruction Throughput**: 2-3x improvement for compute-heavy contracts
- **Cache Efficiency**: 30-40% better L1 instruction cache hit rate

### Trade-offs
- **Memory Usage**: ~3x more memory for instruction array
- **Analysis Time**: 20-30% slower initial analysis
- **Code Complexity**: More complex implementation
- **Binary Size**: ~100KB larger due to operation duplication

## Correctness Verification

### Test Categories
1. **Differential Testing**
   ```zig
   test "threaded matches traditional execution" {
       // Run same bytecode through both interpreters
       // Compare gas usage, output, state changes
   }
   ```

2. **Edge Cases**
   - Empty contracts
   - Single instruction contracts  
   - Maximum depth call stacks
   - Out of gas scenarios
   - Invalid jump destinations

3. **Stress Tests**
   - 10,000 jumps
   - Deep recursion
   - Memory expansion limits
   - Stack limits

### Benchmarking Methodology

```zig
const contracts = .{
    "ten-thousand-hashes",  // Tight compute loop
    "erc20-transfer",       // Typical contract
    "snailtracer",         // Complex computation
    "uniswap-v2-swap",     // Real-world DeFi
};

for (contracts) |contract| {
    const traditional = timeExecution(interpret, contract);
    const threaded = timeExecution(interpretThreaded, contract);
    const speedup = traditional / threaded;
    print("{s}: {d:.2}x speedup\n", .{contract, speedup});
}
```

## Future Optimizations

### Possible Extensions
1. **Superinstructions**: Combine common sequences (PUSH+ADD, DUP+SWAP)
2. **Inline Caching**: Cache CALL target resolutions
3. **Trace Compilation**: JIT hot paths to native code
4. **Parallel Analysis**: Multi-threaded bytecode analysis

### Not Implemented (Complexity vs Benefit)
1. **Computed Goto**: Zig doesn't support GCC's computed goto
2. **Tail Call Optimization**: Not guaranteed in Zig
3. **Custom Calling Convention**: Platform-specific complexity

## Conclusion

This threaded code implementation brings evmone's proven optimization technique to the Zig EVM. By eliminating interpreter loop overhead and leveraging existing infrastructure (block analysis, pre-computed operations), we can achieve significant performance improvements with manageable implementation complexity.

The key insight is that our existing `pc_to_op_entries` table already provides most of the benefits - we just need to change how we traverse it from index-based to pointer-based execution.