# CLAUDE.md - Instructions Module

## MISSION CRITICAL: Core Execution Engine
**Financial operations where bugs = fund loss.** Test with `zig build test-opcodes`.

## Handler Architecture

**Function Pattern**:
```zig
pub fn opcode(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
    // Implementation
    const dispatch = Dispatch{ .cursor = cursor };
    const op_data = dispatch.getOpData(.OPCODE);
    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
}
```

**Principles**: Tail calls, unsafe ops after validation, cursor dispatch, precise gas accounting

## File Organization

**Core Handlers**: arithmetic, bitwise, comparison, stack, memory, storage, jump, system, context, keccak, log
**Synthetic**: arithmetic_synthetic, bitwise_synthetic, memory_synthetic, jump_synthetic, advanced_synthetic (PUSH+op fusions)

## Critical Implementation

**Stack**: Validate `self.stack.size() >= N`, use `_unsafe` variants after validation, 1024 max
**Memory**: Quadratic gas costs, `calculateMemoryGas()`, 32-byte words
**Gas**: `self.gas_remaining -= cost`, check overflow, exact Yellow Paper costs

**Error Types**: StackOverflow/Underflow, InvalidJumpDestination, OutOfGas, StaticViolation, InvalidOpcode

## Common Patterns

**Binary Ops**:
```zig
std.debug.assert(self.stack.size() >= 2);
self.stack.binary_op_unsafe(op_function);
```

**Memory Ops**:
```zig
const memory_cost = try self.calculateMemoryGas(offset, size);
self.gas_remaining -= @intCast(memory_cost);
if (self.gas_remaining < 0) return Error.OutOfGas;
```

## Synthetic Optimizations
- **Inline**: ≤8 byte values in dispatch metadata
- **Pointer**: >8 byte values in constant pool
- **Patterns**: PUSH+OP, multi-operations, static jumps

## Performance
- Tail call optimization
- Unsafe ops skip bounds checking
- Cache-friendly layouts
- Exact gas costs per Yellow Paper

## Security
- Validate stack depth before ops
- Check integer overflows
- Validate jump destinations
- Enforce static context
- Accurate gas metering prevents DoS

**Remember: Zero tolerance for errors in financial operations.**