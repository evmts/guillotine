# CLAUDE.md - EVM Module Implementation Guide

This document provides implementation-specific guidance for AI assistants working on the Guillotine EVM module. It supplements the main `/CLAUDE.md` with EVM-specific patterns, pitfalls, and requirements.

## Critical Implementation Requirements

### Interpreter Selection

**ALWAYS use `interpret2.zig` for production code**:
- The tailcall interpreter is the primary implementation
- `interpreter.zig` is legacy and being phased out
- `mini_evm.zig` is only for isolated testing scenarios

### Memory Management in EVM Context

**CRITICAL**: The EVM has specific memory ownership patterns that MUST be followed:

1. **Frame Lifecycle**:
   ```zig
   // ALWAYS pair Frame.init with Frame.deinit
   var frame = try Frame.init(...);
   defer frame.deinit(allocator);
   ```

2. **Analysis Ownership**:
   - `CodeAnalysis` in legacy interpreter owns its memory
   - `SimpleAnalysis` in interpret2 has minimal allocations
   - NEVER free analysis while a frame references it

3. **Output Buffer Management**:
   - `self.current_output` is VM-owned, callers MUST NOT free
   - Output slices are views into VM memory
   - Valid only until next VM operation

### Tailcall Implementation Patterns

When adding new opcodes to `tailcalls.zig`:

```zig
pub fn op_new_opcode(
    frame_ptr: *anyopaque,
    analysis: *const SimpleAnalysis,
    metadata: [*]const u32,
    ops: [*]const *const anyopaque,
    ip: *usize
) Error!noreturn {
    const frame: *Frame = @ptrCast(@alignCast(frame_ptr));
    
    // 1. Perform operation
    try execution.category.op_new_opcode(frame);
    
    // 2. ALWAYS tail call to next
    return next(frame_ptr, analysis, metadata, ops, ip);
}
```

**NEVER**:
- Return without calling `next()`
- Add non-tail recursion
- Allocate memory in opcode handlers

### Operation Fusion Requirements

When implementing fusion operations:

1. **Pattern Detection** (in `interpret2.zig`):
   ```zig
   // Check for PUSH followed by target operation
   if (i + 1 < analysis.instructions.len) {
       const next_op = opcodes[analysis.instructions[i + 1].opcode];
       if (next_op == .ADD) {
           ops[i] = @ptrCast(&tailcalls.op_push_then_add);
           continue;
       }
   }
   ```

2. **Fusion Implementation** (in `tailcalls.zig`):
   ```zig
   pub fn op_push_then_add(...) Error!noreturn {
       // Extract push value from metadata
       const value = extractPushValue(metadata, ip);
       
       // Pop operand
       const a = try frame.stack.pop();
       
       // Perform fused operation
       const result = a +% value;
       try frame.stack.push(result);
       
       // Skip the fused instruction
       ip.* += 1;
       
       return next(...);
   }
   ```

### Gas Calculation Patterns

**CRITICAL**: Gas must be charged BEFORE operations that can fail:

```zig
// CORRECT: Charge gas first
try frame.useGas(gas_cost);
const result = try risky_operation();

// WRONG: Operation before gas
const result = try risky_operation();
try frame.useGas(gas_cost);  // Too late!
```

### Call Depth Management

**ALWAYS maintain correct frame depth**:

```zig
// In call2.zig for nested calls
const new_depth = self.current_frame_depth + 1;
if (new_depth >= MAX_CALL_DEPTH) {
    return error.CallDepthExceeded;
}
self.current_frame_depth = new_depth;
defer self.current_frame_depth -= 1;
```

## Common Pitfalls and Solutions

### Pitfall 1: Incorrect Stack Validation

**Problem**: Not checking stack requirements before operations
**Solution**: ALWAYS validate in executors:
```zig
pub fn op_add(frame: *Frame) !void {
    // Validate BEFORE popping
    if (frame.stack.depth() < 2) return error.StackUnderflow;
    
    const b = try frame.stack.pop();
    const a = try frame.stack.pop();
    try frame.stack.push(a +% b);
}
```

### Pitfall 2: Memory Expansion Without Gas

**Problem**: Expanding memory without charging gas
**Solution**: Use Frame's memory methods that handle gas:
```zig
// CORRECT: Frame method handles gas
try frame.memory_resize(new_size);

// WRONG: Direct memory access
frame.memory.data.items.len = new_size;
```

### Pitfall 3: Forgetting Snapshot Revert

**Problem**: Not reverting state on nested call failure
**Solution**: Always use snapshot pattern:
```zig
const snapshot = host.create_snapshot();
const result = try nested_call();
if (!result.success) {
    host.revert_to_snapshot(snapshot);
}
```

### Pitfall 4: Modifying Code During Execution

**Problem**: Attempting to modify bytecode while executing
**Solution**: Code is immutable during execution - use memory for mutable data

## Testing Requirements for EVM Changes

### Unit Test Pattern

Every opcode implementation MUST have a test:

```zig
test "OPCODE_NAME basic functionality" {
    const allocator = std.testing.allocator;
    
    // Full setup - no helpers
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Test with interpret2
    const code = &[_]u8{0x60, 0x05, 0x60, 0x0A, 0x01}; // PUSH 5, PUSH 10, ADD
    const result = try vm.call2(...);
    
    try std.testing.expect(result.success);
    // Verify results
}
```

### Benchmark Validation

**CRITICAL**: Benchmarks MUST only measure successful operations:

```zig
// In benchmark setup
const result = try vm.call2(params);
if (!result.success) {
    std.debug.panic("Benchmark operation failed - invalid benchmark!", .{});
}
```

## Hardfork-Specific Implementation

When implementing hardfork-specific behavior:

```zig
// In executor
pub fn op_selfdestruct(frame: *Frame) !void {
    if (frame.host.chain_rules().is_cancun) {
        // EIP-6780: Only delete in same transaction
        if (!frame.host.is_contract_new(frame.contract_address)) {
            // Just transfer balance, don't delete
            return;
        }
    }
    // Original behavior
}
```

## Performance Guidelines

### Cache-Friendly Patterns

1. **Group hot fields** in Frame:
   ```zig
   // HOT fields together
   gas_remaining: u64,
   pc: usize,
   stack: Stack,
   
   // COLD fields together  
   logs: ArrayList(Log),
   created_addresses: ArrayList(Address),
   ```

2. **Minimize indirection**:
   ```zig
   // GOOD: Direct field access
   frame.gas_remaining -= cost;
   
   // BAD: Unnecessary indirection
   frame.getGasPtr().* -= cost;
   ```

### Compile-Time Optimizations

Use comptime where possible:
```zig
// Gas costs known at compile time
const gas_cost = comptime calculateGasCost(opcode);

// Fusion patterns determined at compile time
const should_fuse = comptime checkFusionEligible(op1, op2);
```

## Integration with Host Interface

### Host Method Requirements

When adding new host methods:

1. **Add to vtable** in `host.zig`:
   ```zig
   pub const VTable = struct {
       new_method: *const fn(*anyopaque, params) ReturnType,
   };
   ```

2. **Implement in Evm**:
   ```zig
   fn host_new_method(ctx: *anyopaque, params) ReturnType {
       const self: *Evm = @ptrCast(@alignCast(ctx));
       // Implementation
   }
   ```

3. **Use in operations**:
   ```zig
   const result = frame.host.new_method(params);
   ```

## Debugging EVM Execution

### Required Debug Patterns

When debugging EVM issues, ALWAYS use logging:

```zig
const Log = @import("../log.zig");

// At function entry
Log.debug("[op_call] gas={}, depth={}", .{frame.gas_remaining, frame.depth});

// Before critical operations
Log.debug("[op_call] About to create nested frame", .{});

// After operations
Log.debug("[op_call] Result: success={}, gas_left={}", .{result.success, result.gas_left});
```

### Stack Trace Analysis

For tailcall interpreter issues:
1. The stack trace will show recursive calls through `next()`
2. Look for the last successful operation before failure
3. Add logging at the failing operation
4. Trace backwards through the execution

## Code Review Checklist

Before committing EVM changes, verify:

- [ ] All Frame.init calls have matching deinit
- [ ] Gas is charged before operations that can fail
- [ ] Stack validation occurs before popping values
- [ ] Memory expansion includes gas calculation
- [ ] Snapshots are created/reverted for nested calls
- [ ] Tests use interpret2, not legacy interpreter
- [ ] No allocations in hot paths (opcode handlers)
- [ ] Hardfork conditions are checked where applicable
- [ ] Benchmarks only measure successful operations
- [ ] Debug logging is added for new code paths

## Special Considerations

### EIP-1153 Transient Storage

Transient storage MUST be cleared after each transaction:
```zig
// In top-level call cleanup
defer self.state.clear_transient_storage();
```

### EIP-2929 Access Lists

Always track first access:
```zig
const accessed = try self.access_list.access_address(address);
const gas_cost = if (accessed.cold) COLD_ACCESS_COST else WARM_ACCESS_COST;
```

### EIP-4844 Blob Transactions

Blob data is NOT available to EVM:
```zig
// BLOBHASH opcode returns versioned hash, not data
const hash = try frame.host.get_blob_hash(index);
```

## Performance Profiling

When profiling interpret2:
1. Focus on `next()` call overhead - should be near zero
2. Check fusion hit rates - higher is better
3. Monitor stack/memory allocation patterns
4. Verify branch prediction efficiency

## Future Improvements Tracking

Track these metrics for optimization opportunities:
- Hot opcode sequences not yet fused
- Memory allocation patterns that could be pooled
- Repeated analysis that could be cached
- State access patterns for prefetching

---

*This guide ensures consistent, correct, and performant EVM implementation. Always refer to this when modifying EVM code.*