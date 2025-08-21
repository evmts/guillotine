# TODO: Register-Based EVM Interpreter Implementation Plan

## Current Status

We have successfully implemented:
1. **SSA Conversion** (`analysis3.zig`): Converts stack-based EVM bytecode to SSA form
2. **Dependency Graph**: Tracks value dependencies for register allocation
3. **Register Allocation**: Linear scan allocator with immediate register freeing
4. **Code Generation**: Converts SSA to register operations with metadata encoding
5. **Register Frame** (`stack_frame3.zig`): Storage and execution for register operations

## Research from Reference Implementation

### Key Insights from `tailcalls.zig`:
1. **Tailcall Pattern**: All operations use `Error!noreturn` and call `next(frame)`
2. **No Allocations**: Operations directly manipulate frame state
3. **Metadata Usage**: PUSH operations use precomputed metadata for O(1) access
4. **Fusion Operations**: Many fused operations like `op_push_then_add`
5. **Error Propagation**: Uses `ExecutionError.Error` enum

### Key Insights from `interpret2.zig`:
1. **Preparation Phase**: Uses `analysis2.prepare()` to build ops array and metadata
2. **Fixed Buffer Allocator**: Uses 1MB static buffer for analysis
3. **Tailcall Start**: `@call(.always_tail, frame.ops[0], .{frame})`

### Key Insights from `stack_frame.zig`:
1. **Cache-Optimized Layout**: Hot fields in first cache line
2. **Pre-allocation**: Uses tiered allocation based on bytecode size
3. **Direct State Access**: Frame owns execution state directly

## Implementation Plan

### Step 1: Create `interpret3.zig` with Tailcall Dispatch (TDD)

#### 1.1 Basic Structure
```zig
// Function pointer type for register-based tailcall
pub const RegisterTailcallFunc = *const fn (frame: *RegisterFrame) Error!noreturn;

// Helper to advance to next instruction
pub inline fn next(frame: *RegisterFrame) Error!noreturn {
    frame.pc += 1;
    return @call(.always_tail, frame.dispatch_table[frame.pc], .{frame});
}
```

#### 1.2 Core Operations to Implement First (Linear Execution)
- `op_stop` - Terminate execution
- `op_load_imm` - Load immediate to register
- `op_add_reg` - Add two registers
- `op_mul_reg` - Multiply two registers
- `op_sub_reg` - Subtract registers
- `op_div_reg` - Divide registers
- `op_pop_reg` - Pop/discard register value (no-op in register machine)

#### 1.3 Test Pattern
```zig
test "execute simple add program" {
    // 1. Create bytecode: PUSH 5, PUSH 10, ADD, STOP
    // 2. Run through analysis3 to get register ops
    // 3. Create RegisterFrame
    // 4. Execute with interpret3
    // 5. Verify final register state
}
```

### Step 2: Implement All Linear Opcodes

#### 2.1 Arithmetic Operations
- All arithmetic from `execution/arithmetic.zig`
- Pattern: Read from src registers, write to dest register

#### 2.2 Comparison Operations  
- All comparisons from `execution/comparison.zig`
- Pattern: Compare registers, write 0/1 to dest

#### 2.3 Bitwise Operations
- All bitwise ops from `execution/bitwise.zig`
- Pattern: Operate on register values

#### 2.4 Stack Operations (Register Equivalents)
- DUP → copy_reg (copy register to another)
- SWAP → swap_reg (swap two registers)
- POP → Already handled in SSA (no-op)

#### 2.5 Memory Operations
- MLOAD/MSTORE need register-based addressing
- MSIZE can read from frame state

#### 2.6 Storage Operations
- SLOAD/SSTORE with register addressing
- TLOAD/TSTORE for transient storage

#### 2.7 Environment Operations
- ADDRESS, BALANCE, CALLER, etc.
- These load values into registers

### Step 3: Handle Control Flow (Loops)

#### 3.1 Basic Block Analysis
- Extend analysis3 to identify basic blocks
- Track block boundaries at JUMPDEST

#### 3.2 Phi Functions for Loops
- Add phi nodes at loop headers
- Reserve registers for loop-carried values

#### 3.3 Jump Operations
- `jump_reg` - Jump to address in register
- `jumpi_reg` - Conditional jump based on register
- Need to map PC values to register op indices

## Key Design Decisions

### Register Allocation Strategy
1. **Loop Variables**: Reserve dedicated registers for values used across loop iterations
2. **Spill Strategy**: For now, fail if we run out of registers (no spilling)
3. **Calling Convention**: Define register usage for CALL operations

### Metadata Encoding
- 32-bit metadata field in RegisterOp
- Bits 0-7: Destination register
- Bits 8-15: Source1 register  
- Bits 16-23: Source2 register
- Bits 24-31: Op-specific data

### Error Handling
- Use same `ExecutionError.Error` enum as reference
- Propagate errors through tailcall chain
- Terminal operations return specific errors (STOP, RETURN, REVERT)

## Testing Strategy

### Unit Tests (in same file)
1. Test each operation individually
2. Test operation sequences
3. Test edge cases (division by zero, overflow)
4. Test register bounds checking

### Integration Tests
1. Use real EVM bytecode examples
2. Compare results with stack-based interpreter
3. Verify gas consumption matches

### Performance Tests
1. Benchmark vs interpret2
2. Measure register allocation efficiency
3. Profile cache usage

## Implementation Order

1. **Phase 1**: Basic interpreter structure + arithmetic ops
2. **Phase 2**: All linear operations (no jumps)
3. **Phase 3**: Control flow and loops
4. **Phase 4**: System operations (CALL, CREATE)
5. **Phase 5**: Optimization and benchmarking

## Open Questions

1. **Register Spilling**: How to handle programs that need more than 16 registers?
2. **Function Calls**: How to save/restore registers across CALL operations?
3. **Gas Metering**: Should we track gas in a register or frame field?
4. **Memory Access**: Should memory addresses come from registers or immediates?

## Notes from User Instructions

- Everything goes in `interpret3.zig` (no separate tailcalls file)
- Follow TDD with unit tests for the interpreter
- Use real analysis module (analysis3) to generate register ops
- Focus on linear execution first (no jumps/loops)
- Reference `tailcalls.zig` for implementation patterns
- Fix analysis bugs with TDD as discovered