# EVMOne Bytecode Analysis Research

## Executive Summary

EVMOne achieves 2-3x performance improvement over traditional interpreters through a sophisticated bytecode analysis phase that transforms EVM bytecode into an optimized internal representation. The key innovations are:

1. **Block-based execution** - Groups instructions into basic blocks with single gas/stack check
2. **Indirect threading** - Uses function pointers for ~2x faster dispatch than switch statements
3. **Pre-computed metadata** - Analyzes jump destinations, stack requirements, and gas costs upfront
4. **Optimized PUSH handling** - Inline storage for PUSH1-8, separate storage for PUSH9-32

## Architecture Overview

### Core Components

```
advanced_analysis.hpp/cpp    - Bytecode analysis and transformation
advanced_execution.hpp/cpp   - Execution engine using analyzed code
advanced_instructions.cpp    - Instruction implementations
```

### Key Data Structures

#### 1. Instruction (16 bytes total)
```c++
struct Instruction {
    instruction_exec_fn fn;    // 8 bytes - function pointer
    InstructionArgument arg;   // 8 bytes - union of possible arguments
};
```

#### 2. InstructionArgument (8-byte union)
```c++
union InstructionArgument {
    int64_t number;                 // For PC, GAS, block gas correction
    const uint256* push_value;      // Pointer to large PUSH values (9-32 bytes)
    uint64_t small_push_value;      // Inline small PUSH values (1-8 bytes)
    BlockInfo block;                // Basic block metadata
};
```

#### 3. BlockInfo (8 bytes, fits in union)
```c++
struct BlockInfo {
    uint32_t gas_cost;        // Total base gas cost of all instructions
    int16_t stack_req;        // Minimum stack items required
    int16_t stack_max_growth; // Maximum stack growth in block
};
```

#### 4. AdvancedCodeAnalysis
```c++
struct AdvancedCodeAnalysis {
    vector<Instruction> instrs;        // Analyzed instruction stream
    vector<uint256> push_values;       // Storage for large PUSH values
    vector<int32_t> jumpdest_offsets;  // Sorted list of JUMPDEST positions
    vector<int32_t> jumpdest_targets;  // Corresponding instruction indices
};
```

## The Analysis Algorithm

### Overview
The analysis phase performs a single pass through the bytecode, transforming it into an optimized instruction stream. Here's the complete algorithm broken down:

### 1. Memory Pre-allocation
```c++
// Reserve memory to avoid reallocations during analysis
instrs.reserve(code.size() + 2);      // +2 for BEGINBLOCK and STOP
push_values.reserve(code.size() + 1);  // Worst case: all PUSH instructions
```

### 2. Block Analysis
Every bytecode starts with an implicit basic block:

```c++
// Insert initial BEGINBLOCK instruction
instrs.emplace_back(opx_beginblock_fn);
BlockAnalysis block{.begin_block_index = 0};
```

### 3. Main Analysis Loop
```c++
while (pos < code.end) {
    opcode = *pos++;
    
    // JUMPDEST creates new basic block
    if (opcode == OP_JUMPDEST) {
        // Save current block metadata
        instrs[block.begin_block_index].arg.block = block.close();
        // Start new block
        block = BlockAnalysis{.begin_block_index = instrs.size()};
        // Record jump destination for binary search
        jumpdest_offsets.push_back(pos - 1);
        jumpdest_targets.push_back(instrs.size());
    }
    
    // Add instruction
    instrs.emplace_back(operation_fn);
    
    // Update block requirements
    block.stack_req = max(block.stack_req, op.stack_req - block.stack_change);
    block.stack_change += op.stack_change;
    block.stack_max_growth = max(block.stack_max_growth, block.stack_change);
    block.gas_cost += op.gas_cost;
}
```

### 4. Special Instruction Handling

#### Terminating Instructions (STOP, JUMP, RETURN, REVERT, SELFDESTRUCT)
```c++
// Skip unreachable code until next JUMPDEST
while (pos < code.end && *pos != OP_JUMPDEST) {
    if (is_push_opcode(*pos)) {
        push_size = *pos - OP_PUSH1 + 1;
        pos = min(pos + push_size + 1, code.end);
    } else {
        pos++;
    }
}
```

#### JUMPI (Conditional Jump)
```c++
// JUMPI can continue execution, so start new block
instrs[block.begin_block_index].arg.block = block.close();
block = BlockAnalysis{.begin_block_index = instrs.size() - 1};
```

#### PUSH Instructions
```c++
// PUSH1-PUSH8: Store value inline (8 bytes or less)
if (push_size <= 8) {
    uint64_t value = 0;
    for (i = 0; i < push_size; i++) {
        value = (value << 8) | *pos++;
    }
    instr.arg.small_push_value = value;
}
// PUSH9-PUSH32: Store in separate array
else {
    auto& push_value = push_values.emplace_back();
    // Copy bytes in big-endian order
    for (i = 0; i < push_size; i++) {
        push_value |= uint256(*pos++) << ((push_size - 1 - i) * 8);
    }
    instr.arg.push_value = &push_value;
}
```

#### Gas-Aware Instructions
```c++
// Store block's gas cost for dynamic gas calculation
case OP_GAS:
case OP_CALL:
case OP_SSTORE:
    instr.arg.number = block.gas_cost;
    break;

// Store program counter
case OP_PC:
    instr.arg.number = pos - code.begin - 1;
    break;
```

## Execution Phase

### 1. Main Execution Loop
The entire interpreter is just 3 lines:
```c++
const Instruction* instr = &analysis.instrs[0];
while (instr != nullptr)
    instr = instr->fn(instr, state);
```

### 2. BEGINBLOCK - The Performance Key
This single instruction replaces hundreds of individual checks:
```c++
const Instruction* opx_beginblock(const Instruction* instr, AdvancedExecutionState& state) {
    const BlockInfo& block = instr->arg.block;
    
    // Single gas check for entire block
    state.gas_left -= block.gas_cost;
    if (state.gas_left < 0)
        return state.exit(EVMC_OUT_OF_GAS);
    
    // Single stack validation for entire block
    int stack_size = state.stack_size();
    if (stack_size < block.stack_req)
        return state.exit(EVMC_STACK_UNDERFLOW);
    if (stack_size + block.stack_max_growth > 1024)
        return state.exit(EVMC_STACK_OVERFLOW);
    
    state.current_block_cost = block.gas_cost;
    return ++instr;
}
```

### 3. Optimized Instructions

#### PUSH (Small Values)
```c++
const Instruction* op_push_small(const Instruction* instr, AdvancedExecutionState& state) {
    state.stack.push(instr->arg.small_push_value);  // No memory access!
    return ++instr;
}
```

#### JUMP with Binary Search
```c++
const Instruction* op_jump(const Instruction*, AdvancedExecutionState& state) {
    uint256 dst = state.stack.pop();
    
    // Binary search in sorted jumpdest_offsets (O(log n))
    int pc = find_jumpdest(*state.analysis, dst);
    if (pc < 0)
        return state.exit(EVMC_BAD_JUMP_DESTINATION);
    
    return &state.analysis->instrs[pc];
}
```

#### Dynamic Gas Instructions
```c++
const Instruction* op_sstore(const Instruction* instr, AdvancedExecutionState& state) {
    // Restore actual gas for dynamic calculation
    int64_t gas_correction = state.current_block_cost - instr->arg.number;
    state.gas_left += gas_correction;
    
    // Execute SSTORE with dynamic gas
    // ... core SSTORE logic ...
    
    // Deduct correction
    state.gas_left -= gas_correction;
    if (state.gas_left < 0)
        return state.exit(EVMC_OUT_OF_GAS);
    
    return ++instr;
}
```

## Test Cases Analysis

### 1. Basic Analysis Tests (`analysis_test.cpp`)

#### Simple Execution Flow
```c++
TEST(analysis, example1) {
    code = push(0x2a) + push(0x1e) + OP_MSTORE8 + OP_MSIZE + push(0) + OP_SSTORE;
    // Verifies:
    // - 8 instructions total (including BEGINBLOCK and STOP)
    // - Correct function pointers assigned
    // - Block gas cost = 14
    // - Stack requirements calculated correctly
}
```

#### Stack Height Tracking
```c++
TEST(analysis, stack_up_and_down) {
    code = OP_DUP2 + 6 * OP_DUP1 + 10 * OP_POP + push(0);
    // Verifies:
    // - stack_req = 3 (minimum needed to start)
    // - stack_max_growth = 7 (peak stack usage)
    // - Correct gas calculation
}
```

#### PUSH Optimization
```c++
TEST(analysis, push) {
    code = push(0x8807060504030201) + "7f00ee";  // PUSH8 + PUSH32
    // Verifies:
    // - Small push stored inline as uint64_t
    // - Large push stored in separate array with pointer
}
```

### 2. Jump Destination Tests

#### Dead Code Elimination
```c++
TEST(analysis, jump_dead_code) {
    code = push(6) + OP_JUMP + 3 * OP_ADD + OP_JUMPDEST;
    // Verifies:
    // - Dead code (3 ADDs) skipped
    // - JUMPDEST still recorded
    // - Correct instruction count (5, not 8)
}
```

#### Multiple JUMPDESTs
```c++
TEST(analysis, jumpdests_groups) {
    code = 3 * OP_JUMPDEST + push(1) + 3 * OP_JUMPDEST + push(2) + OP_JUMPI;
    // Verifies:
    // - All 6 JUMPDESTs recorded
    // - Correct mapping to instruction indices
    // - Binary search works correctly
}
```

### 3. Edge Cases

#### Empty Code
```c++
TEST(analysis, empty) {
    // Even empty code gets BEGINBLOCK + STOP
    ASSERT_EQ(analysis.instrs.size(), 2);
}
```

#### JUMPI at End
```c++
TEST(analysis, jumpi_at_the_end) {
    code = bytecode{OP_JUMPI};
    // Verifies JUMPI doesn't crash at code end
}
```

## Implementation Breakdown

### Phase 1: Core Data Structures (2-3 days)
1. **Instruction and InstructionArgument structures**
   - Match EVMOne's exact 16-byte layout
   - Union for space efficiency
   - Function pointer typedef

2. **BlockInfo structure**
   - Must fit in 8 bytes for union
   - Track gas, stack requirements

3. **AdvancedCodeAnalysis**
   - Dynamic arrays for instructions and push values
   - Sorted arrays for jump destinations

### Phase 2: Analysis Algorithm (3-4 days)
1. **Basic block detection**
   - JUMPDEST always starts new block
   - Track block boundaries

2. **Stack analysis**
   - Calculate minimum stack requirements
   - Track maximum growth
   - Net stack change

3. **Gas accumulation**
   - Sum base gas costs per block
   - Store for dynamic gas instructions

4. **Dead code elimination**
   - Skip unreachable code after terminators
   - Handle PUSH data bytes correctly

### Phase 3: Instruction Handlers (4-5 days)
1. **BEGINBLOCK implementation**
   - Batch gas checking
   - Batch stack validation
   - Update current block cost

2. **PUSH optimizations**
   - Inline small values (≤8 bytes)
   - Pointer to large values (>8 bytes)

3. **JUMP/JUMPI with binary search**
   - O(log n) destination lookup
   - Pre-computed instruction indices

4. **Dynamic gas instructions**
   - GAS opcode correction
   - CALL/SSTORE gas adjustment

### Phase 4: Integration (2-3 days)
1. **Execution loop**
   - Simple while loop with function pointers
   - No per-instruction overhead

2. **State management**
   - Link to analysis
   - Track gas and block cost

3. **Testing**
   - Port EVMOne test cases
   - Verify correctness
   - Benchmark performance

## Performance Characteristics

### Memory Usage
- **Analysis structures**: ~2x bytecode size
- **Instruction array**: code_size + 2 entries
- **Push storage**: up to code_size bytes
- **Jump tables**: 2 * number_of_jumpdests * 4 bytes

### Time Complexity
- **Analysis**: O(n) single pass
- **Execution**: O(1) dispatch per instruction
- **Jump validation**: O(log n) binary search
- **Block validation**: O(1) amortized

### Cache Behavior
- **Sequential access**: Instructions laid out linearly
- **Predictable branches**: Function pointer dispatch
- **Hot path optimization**: Common instructions inline

## Key Insights

1. **Block-based validation is the key** - Checking gas and stack once per block instead of per instruction provides the main performance gain

2. **Memory layout matters** - 16-byte instructions fit in cache lines, union keeps data compact

3. **Pre-computation wins** - Analyzing jump destinations, push values, and PC values upfront eliminates runtime work

4. **Dead code elimination helps** - Many contracts have unreachable code that can be skipped

5. **Binary search beats hash maps** - For jump destinations, sorted array with binary search is faster than hash lookups

## Differences from Traditional Interpreters

| Traditional | EVMOne Advanced |
|------------|-----------------|
| Switch dispatch | Function pointer dispatch |
| Per-instruction gas check | Per-block gas check |
| Runtime PUSH parsing | Pre-parsed PUSH values |
| Linear jump search | Binary search O(log n) |
| Runtime stack validation | Pre-computed requirements |
| Process all code | Skip dead code |

## Conclusion

EVMOne's advanced interpreter achieves its performance through careful engineering:
- Batch validation at block boundaries
- Pre-computed metadata
- Optimized memory layout
- Efficient dispatch mechanism

The implementation is complex but the concepts are elegant. By moving work from the hot execution path to the one-time analysis phase, EVMOne achieves 2-3x speedup while maintaining correctness.