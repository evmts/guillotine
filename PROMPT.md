# EVM Frame Fat Struct and Context Refactoring

## Executive Summary
This document outlines a major architectural refactoring of the Guillotine EVM implementation with two complementary goals:
1. **Fat Struct Design**: Consolidate all execution state (Contract, Stack, Memory, and ReturnData fields) directly into the Frame struct
2. **Context Integration**: Add immutable block and transaction context to Frame, simplifying operation signatures

These changes will improve performance through better cache locality, reduce parameter passing overhead, and create a cleaner API for opcode implementations.

## Current Architecture

### Frame Structure (`src/evm/frame/frame.zig`)
Currently, Frame contains references to separate structs:
- `contract: *Contract` - Contract execution context
- `memory: Memory` - Manages byte-addressable memory
- `stack: Stack` - Manages 256-bit word stack
- `return_data: ReturnData` - Manages return data from calls
- Plus various scalar fields (gas_remaining, pc, is_static, etc.)

### Stack Structure (`src/evm/stack/stack.zig`)
- Fixed-size array: `data: [1024]u256`
- Size tracking: `size: usize`
- Methods for push, pop, dup, swap operations

### Memory Structure (`src/evm/memory/memory.zig`)
- Complex memory management with shared buffers
- Fields: `my_checkpoint`, `memory_limit`, `shared_buffer_ref`, `allocator`, `owns_buffer`
- Cached gas expansion calculations
- Methods split across multiple files (read.zig, write.zig, context.zig, slice.zig)

### ReturnData Structure (`src/evm/evm/return_data.zig`)
- Dynamic buffer: `data: std.ArrayList(u8)`
- Allocator reference

### Contract Structure (`src/evm/frame/contract.zig`)
Contract contains extensive execution context:
- Identity fields: `address`, `caller`, `value`
- Code fields: `code`, `code_hash`, `code_size`, `analysis`
- Gas fields: `gas`, `gas_refund`
- Storage tracking: `storage_access`, `original_storage`, `is_cold`
- Flags: `is_deployment`, `is_system_call`, `is_static`, `has_jumpdests`, `is_empty`

### Operation Signatures
Currently, all opcode handlers have this signature:
```zig
pub fn op_name(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult
```
Where:
- `pc` = program counter (redundant, same as `frame.pc`)
- `interpreter` = pointer to VM (`*Vm`)
- `state` = pointer to Frame (`*Frame`)

### Context Access Pattern
Operations that need blockchain context currently access it through the VM:
- Block context: `vm.context.block_number`, `vm.context.block_coinbase`, etc.
- Transaction context: `vm.tx.gas_price`, `vm.tx.origin`, etc.

## Target Architecture

### Consolidated Frame Structure
The new Frame should contain all state fields directly:

```zig
const Frame = @This();

// === EXISTING FRAME FIELDS ===
// Hot fields (frequently accessed)
gas_remaining: u64 = 0,
pc: usize = 0,
allocator: std.mem.Allocator,

// Control flow fields
stop: bool = false,
is_static: bool = false,
depth: u32 = 0,
cost: u64 = 0,
err: ?ExecutionError.Error = null,

// Data fields
input: []const u8 = &[_]u8{},
output: []const u8 = &[_]u8{},
op: []const u8 = &.{},

// === FIELDS FROM CONTRACT ===
// Identity and Context
address: primitives.Address.Address,
caller: primitives.Address.Address,
value: u256,

// Code and Analysis
code: []const u8,
code_hash: [32]u8,
code_size: u64,
analysis: ?*const CodeAnalysis,

// Gas Tracking (gas_refund only, gas merged with gas_remaining)
gas_refund: u64,

// Execution Flags
is_deployment: bool,
is_system_call: bool,

// Storage Access Tracking (EIP-2929)
storage_access: ?*std.AutoHashMap(u256, bool),
original_storage: ?*std.AutoHashMap(u256, u256),
is_cold: bool,

// Optimization Fields
has_jumpdests: bool,
is_empty: bool,

// === FIELDS FROM STACK ===
stack_data: [1024]u256 align(@alignOf(u256)) = undefined,
stack_size: usize = 0,

// === FIELDS FROM MEMORY ===
memory_checkpoint: usize,
memory_limit: u64,
memory_shared_buffer_ref: *std.ArrayList(u8),
memory_owns_buffer: bool,
memory_cached_expansion: struct {
    last_size: u64,
    last_cost: u64,
} = .{ .last_size = 0, .last_cost = 0 },

// === FIELDS FROM RETURN DATA ===
return_data_buffer: std.ArrayList(u8),

// === NEW CONTEXT FIELDS (IMMUTABLE) ===
// Block context - set once at frame creation, never modified
block_context: Context,

// Transaction context - set once at frame creation, never modified
tx_context: Transaction,
```

## Implementation Strategy

### 1. Frame Structure Updates
- Move all fields from Stack, Memory, and ReturnData directly into Frame
- Maintain field naming conventions (prefix with component name)
- Preserve memory layout optimizations (hot fields first)

### 2. Method Organization
Create new files in `src/evm/frame/`:
- `stack_ops.zig` - Stack operations on Frame
- `memory_ops.zig` - Memory operations on Frame
- Move existing memory operation files to frame directory

### 3. Method Implementation Pattern
Methods should operate on Frame but focus on their specific fields:

```zig
// In src/evm/frame/stack_ops.zig
pub fn stack_push(self: *Frame, value: u256) Error!void {
    if (self.stack_size >= 1024) {
        @branchHint(.cold);
        return Error.StackOverflow;
    }
    self.stack_data[self.stack_size] = value;
    self.stack_size += 1;
}

// In src/evm/frame/memory_ops.zig
pub fn memory_get_u256(self: *const Frame, offset: u64) u256 {
    // Implementation using self.memory_* fields
}
```

### 4. Import Pattern
In Frame, use `usingnamespace` to import methods:

```zig
// In frame.zig
pub usingnamespace @import("stack_ops.zig");
pub usingnamespace @import("memory_ops.zig");
// etc.
```

### 5. Simplified Operation Signatures
Update all opcode handlers to use the new simplified signature:

```zig
// Old signature
pub fn op_add(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;          // Unused - just frame.pc
    _ = interpreter; // Often unused
    const frame = state;
    // ...
}

// New signature  
pub fn op_add(vm: *Vm, frame: *Frame) ExecutionError.Error!Operation.ExecutionResult {
    // Direct access to frame.pc if needed
    // Direct access to vm for state operations
}
```

### 6. Context Access Pattern
Operations can now access context directly from Frame:

```zig
// Before
const vm = interpreter;
try frame.stack.append(vm.context.block_base_fee);

// After
try frame.stack_push(frame.block_context.block_base_fee);
```

## Files Requiring Updates

### Core Files to Modify
1. **Frame Definition**
   - `src/evm/frame/frame.zig` - Main struct definition

2. **Files to Move to frame/**
   - `src/evm/stack/stack.zig` → `src/evm/frame/stack_ops.zig`
   - `src/evm/memory/memory.zig` → `src/evm/frame/memory_state.zig`
   - `src/evm/memory/read.zig` → `src/evm/frame/memory_read.zig`
   - `src/evm/memory/write.zig` → `src/evm/frame/memory_write.zig`
   - `src/evm/memory/context.zig` → `src/evm/frame/memory_context.zig`
   - `src/evm/memory/slice.zig` → `src/evm/frame/memory_slice.zig`

3. **Operation Module Updates**
   - `src/evm/opcodes/operation.zig` - Update ExecutionFunc signature
   - `src/evm/jump_table/jump_table.zig` - Update execute() to pass vm and frame directly

4. **All Execution Files** (27 files)
   Update references from `frame.stack.*` to `frame.stack_*` AND update signatures:
   - `src/evm/execution/control.zig`
   - `src/evm/execution/arithmetic.zig`
   - `src/evm/execution/system.zig`
   - `src/evm/execution/storage.zig`
   - `src/evm/execution/stack.zig`
   - `src/evm/execution/memory.zig`
   - `src/evm/execution/log.zig`
   - `src/evm/execution/environment.zig`
   - `src/evm/execution/crypto.zig`
   - `src/evm/execution/comparison.zig`
   - `src/evm/execution/block.zig`
   - `src/evm/execution/bitwise.zig`
   - And others...

### Update Patterns

#### Stack Access Updates
```zig
// Before
frame.stack.push(value)
frame.stack.pop()
frame.stack.size

// After
frame.stack_push(value)
frame.stack_pop()
frame.stack_size
```

#### Memory Access Updates
```zig
// Before
frame.memory.get_u256(offset)
frame.memory.set_u256(offset, value)
frame.memory.ensure_capacity(size)

// After
frame.memory_get_u256(offset)
frame.memory_set_u256(offset, value)
frame.memory_ensure_capacity(size)
```

#### Return Data Updates
```zig
// Before
frame.return_data.set_data(data)
frame.return_data.size()

// After
frame.return_data_set(data)
frame.return_data_size()
```

#### Operation Signature Updates
```zig
// Before
pub fn op_basefee(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = state;
    const frame = state;
    const vm = interpreter;
    try frame.stack.append(vm.context.block_base_fee);
    return Operation.ExecutionResult{};
}

// After
pub fn op_basefee(vm: *Vm, frame: *Frame) ExecutionError.Error!Operation.ExecutionResult {
    _ = vm;  // Not needed for this operation
    try frame.stack_push(frame.block_context.block_base_fee);
    return Operation.ExecutionResult{};
}
```

#### Jump Table Execute Updates
```zig
// Before (in jump_table.zig)
pub inline fn execute(self: *const JumpTable, pc: usize, interpreter: operation_module.Interpreter, frame: operation_module.State, opcode: u8) ExecutionError.Error!operation_module.ExecutionResult {
    // ...
    const res = try operation.execute(pc, interpreter, frame);
}

// After
pub inline fn execute(self: *const JumpTable, vm: *Vm, frame: *Frame, opcode: u8) ExecutionError.Error!operation_module.ExecutionResult {
    // ...
    const res = try operation.execute(vm, frame);
}
```

## Validation Steps

1. **Compilation**: All files must compile without errors
2. **Tests**: All existing tests must pass without modification
3. **Memory Safety**: Ensure proper initialization and cleanup
4. **Performance**: Verify no performance regression

## Benefits of This Refactoring

1. **Performance**: 
   - Better cache locality with all data in one struct
   - Reduced parameter passing overhead (3 params → 2 params)
   - Direct access to context data without pointer chasing through VM
   - Eliminated redundant pc parameter

2. **Simplicity**: 
   - Single allocation for frame state
   - Cleaner operation signatures
   - Context data is immutable once set

3. **Clarity**: 
   - Clear ownership model
   - Operations that need context have it directly available
   - No confusion about pc vs frame.pc

4. **Maintenance**: 
   - Easier to understand frame lifecycle
   - Less boilerplate in operation implementations
   - Consistent access patterns for all frame data

## Risks and Mitigations

1. **Risk**: Large number of file changes
   - **Mitigation**: Use systematic approach, update in phases

2. **Risk**: Subtle bugs from changed access patterns
   - **Mitigation**: Rely on existing test suite

3. **Risk**: Memory initialization complexity
   - **Mitigation**: Careful review of init/deinit methods

## Implementation Order

### Part A: Fat Struct Refactoring
1. **Phase 1**: Create new Frame structure with all fields including context
2. **Phase 2**: Move and adapt method files to frame/
3. **Phase 3**: Update Frame to use new methods
4. **Phase 4**: Update all execution files for new access patterns

### Part B: Operation Signature Simplification  
5. **Phase 5**: Update operation.zig ExecutionFunc signature
6. **Phase 6**: Update jump_table.execute to use new signature
7. **Phase 7**: Update all operation implementations with new signature
8. **Phase 8**: Update interpret.zig to pass context during Frame creation

### Cleanup
9. **Phase 9**: Update tests and other references
10. **Phase 10**: Remove old Stack/Memory/ReturnData structs

## Success Criteria

- [ ] All code compiles without errors
- [ ] All tests pass
- [ ] No memory leaks
- [ ] Performance benchmarks show no regression
- [ ] Code review passes

---

## Agent Instructions

You are tasked with implementing this major refactoring. Follow these steps:

1. **Start with Frame struct changes** - Update frame.zig to include all fields inline, including new context fields
2. **Move method files** - Relocate stack/memory files to frame/ directory with new names
3. **Adapt methods** - Update methods to work on Frame instead of separate structs  
4. **Update all references** - Systematically update all files that reference Stack/Memory
5. **Update operation signatures** - Change from (pc, interpreter, state) to (vm, frame)
6. **Update context access** - Change from vm.context to frame.block_context and frame.tx_context
7. **Test frequently** - Run `zig build && zig build test` after each major change
8. **Use agents in parallel** - Deploy multiple agents for updating execution files

Remember:
- This is a breaking change affecting nearly every EVM-related file
- Be extremely careful with memory management
- Preserve all existing functionality
- Follow Zig naming conventions
- No comments unless specifically needed
- Test after every change
- Context fields should be immutable once set
- The pc parameter is redundant - use frame.pc directly

## Key Patterns to Apply

### When updating operations:
```zig
// If operation needs VM state operations:
pub fn op_sload(vm: *Vm, frame: *Frame) ... {
    const value = try vm.state.get_storage(...);
}

// If operation only needs frame data:
pub fn op_add(vm: *Vm, frame: *Frame) ... {
    _ = vm;  // Mark as unused
    const b = frame.stack_pop_unsafe();
}

// If operation needs context:
pub fn op_chainid(vm: *Vm, frame: *Frame) ... {
    _ = vm;
    try frame.stack_push(frame.block_context.chain_id);
}
```

Good luck!