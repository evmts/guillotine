# Execution Context Analysis

## Overview
This document analyzes all Frame properties and VM methods used by EVM execution handlers to design a minimal ExecutionContext struct that replaces Frame.

## Frame Properties Used

### From interpret.zig (Main execution loop)
- `frame.stack` - Stack operations (.append, .pop_unsafe)
- `frame.gas_remaining` - Gas tracking and consumption 
- `frame.contract` - Contract reference (.valid_jumpdest method)
- `frame.allocator` - Memory allocator for operations
- `frame.output` - Return/revert data output

### From arithmetic.zig Analysis

#### op_add (line 65-78)
- `frame.stack` - `.pop_unsafe()`, `.peek_unsafe()`, `.set_top_unsafe()`
- No other frame properties used

### From memory.zig Analysis  

#### op_mload (line 26-64)
- `frame.stack` - `.peek_unsafe()`, `.set_top_unsafe()`
- `frame.memory` - `.get_expansion_cost()`, `.ensure_context_capacity()`, `.get_u256()`
- `frame` - `.consume_gas()` method

#### op_mstore (line 66-100)
- `frame.stack` - `.pop2_unsafe()`
- `frame.memory` - `.get_expansion_cost()`, `.ensure_context_capacity()`, `.set_u256()`
- `frame` - `.consume_gas()` method

### From control.zig Analysis

#### op_jump (line 22-47)
- `frame.stack` - `.pop_unsafe()` to get destination
- `frame.depth` - For debug logging only
- `frame.gas_remaining` - For debug logging only
- `frame.contract` - `.valid_jumpdest(frame.allocator, dest)` method call
- `frame.allocator` - Passed to valid_jumpdest
- `frame.pc` - Set jump destination (but we ignore PC in new design)

#### op_jumpi (line 49-83)  
- `frame.stack` - `.pop2_unsafe()` to get destination and condition
- `frame.depth` - For debug logging only
- `frame.contract` - `.valid_jumpdest(frame.allocator, destination)` method call
- `frame.allocator` - Passed to valid_jumpdest
- `frame.pc` - Set jump destination (but we ignore PC in new design)

#### op_pc (line 85-96)
- `frame.stack` - `.append_unsafe(pc)` to push PC value

#### op_return (line 107-163)
- `frame.stack` - `.pop2_unsafe()` to get offset and size
- `frame.memory` - `.get_expansion_cost()`, `.ensure_context_capacity()`, `.get_slice()`
- `frame.output` - Set return data
- `frame` - `.consume_gas()` method

#### op_revert (line 165-209)  
- `frame.stack` - `.pop2_unsafe()` to get offset and size
- `frame.memory` - `.get_expansion_cost()`, `.ensure_context_capacity()`, `.get_slice()`
- `frame.output` - Set revert data
- `frame` - `.consume_gas()` method

#### op_invalid (line 211-223)
- `frame.gas_remaining` - Set to 0 (consume all gas)

#### op_selfdestruct (line 225-262)
- `frame.is_static` - Check for write protection
- `frame.stack` - `.pop_unsafe()` to get recipient
- `frame.contract.address` - Contract's address for destruction
- `frame` - `.consume_gas()` method
- `vm.access_list` - `.access_address()` method  
- `vm.state` - `.mark_for_destruction()` method

## VM/Interpreter Methods Used

### From control.zig
- `vm.access_list.access_address(recipient)` - EIP-2929 address access
- `vm.state.mark_for_destruction(address, recipient)` - Mark contract for destruction

### Frame Methods Used
- `frame.consume_gas(amount)` - Gas consumption with overflow check

## Properties NOT Used in Advanced Interpreter
- `frame.pc` - Not tracked in instruction stream execution
- `frame.stop` - Not needed with new error handling
- `frame.cost` - Not used in execution handlers
- `frame.err` - Not used in execution handlers  
- `frame.op` - Not used in execution handlers
- `frame.return_data` - Not directly accessed by handlers
- `frame.vm` - Only used to access specific methods

## Data-Oriented Design Proposal

### Minimal ExecutionContext Struct

```zig
/// Minimal execution context for EVM opcodes
/// Replaces the heavy Frame struct with only essential data
const ExecutionContext = struct {
    // Core execution state
    stack: Stack,
    memory: Memory,
    gas_remaining: u64,
    output: []const u8,
    
    // Environment flags
    is_static: bool,
    depth: u32,
    
    // Memory management
    allocator: std.mem.Allocator,
    
    // Contract data (minimal interface)
    contract_address: primitives.Address.Address,
    valid_jumpdest_fn: *const fn (allocator: std.mem.Allocator, dest: u256) bool,
    
    // VM interface (minimal methods)
    access_address_fn: *const fn (address: primitives.Address.Address) AccessError!u64,
    mark_destruction_fn: *const fn (contract_addr: primitives.Address.Address, recipient: primitives.Address.Address) StateError!void,
    
    // Gas consumption with bounds checking
    pub fn consume_gas(self: *ExecutionContext, amount: u64) !void {
        if (self.gas_remaining < amount) {
            return ExecutionError.Error.OutOfGas;
        }
        self.gas_remaining -= amount;
    }
    
    // Jump destination validation
    pub fn valid_jumpdest(self: *ExecutionContext, dest: u256) bool {
        return self.valid_jumpdest_fn(self.allocator, dest);
    }
    
    // Address access for EIP-2929
    pub fn access_address(self: *ExecutionContext, addr: primitives.Address.Address) !u64 {
        return self.access_address_fn(addr);
    }
    
    // Mark contract for destruction  
    pub fn mark_for_destruction(self: *ExecutionContext, recipient: primitives.Address.Address) !void {
        return self.mark_destruction_fn(self.contract_address, recipient);
    }
};
```

### Memory Layout Benefits
1. **Smaller struct** - ~200 bytes vs 500+ bytes for Frame
2. **Better cache locality** - Hot data (stack, gas) together  
3. **Function pointers** - No object coupling, just behavior
4. **Arena-friendly** - Can be allocated in execution arena

### Required VM Interface Methods
```zig  
// VM must expose these minimal interfaces
pub const VmInterface = struct {
    access_address: *const fn (address: primitives.Address.Address) AccessError!u64,
    mark_destruction: *const fn (contract: primitives.Address.Address, recipient: primitives.Address.Address) StateError!void,
};

// Contract must expose minimal interface
pub const ContractInterface = struct {
    address: primitives.Address.Address,
    valid_jumpdest: *const fn (allocator: std.mem.Allocator, dest: u256) bool,
};
```

### ExecutionFunc Signature Update
```zig
pub const ExecutionFunc = *const fn (pc: usize, ctx: *ExecutionContext) ExecutionError.Error!ExecutionResult;
```

This removes the interpreter parameter entirely since all needed VM functionality is exposed through function pointers on the context.

## Implementation Benefits

1. **Dependency Breaking** - No circular dependencies between execution handlers and VM/Frame
2. **Performance** - Smaller, cache-friendly struct with hot data co-located  
3. **Testability** - Function pointers allow easy mocking in tests
4. **Modularity** - Execution handlers only depend on minimal interface
5. **Memory Efficiency** - No unused fields, optimal packing

## Next Steps

1. Implement ExecutionContext struct
2. Update ExecutionFunc signature  
3. Modify all execution handlers to use ExecutionContext
4. Update interpret_block.zig to create ExecutionContext from VM state
5. Remove Frame dependency from execution package