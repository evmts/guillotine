# Advanced Fusion Patterns - Implementation Reference

This document contains the complete implementation details for advanced fusion patterns that were previously implemented in Guillotine EVM. These patterns optimize sequences of 3+ opcodes into single fused operations.

## Table of Contents
1. [Constant Folding Patterns](#constant-folding-patterns)
2. [Multi-PUSH/POP Patterns](#multi-pushpop-patterns)
3. [ISZERO-JUMPI Pattern](#iszero-jumpi-pattern)
4. [DUP2-MSTORE-PUSH Pattern](#dup2-mstore-push-pattern)
5. [Jump Optimization Patterns](#jump-optimization-patterns)
6. [Pattern Detection Infrastructure](#pattern-detection-infrastructure)
7. [Handler Implementation Notes](#handler-implementation-notes)

## Constant Folding Patterns

### Pattern Detection
Detects sequences where two constants are pushed followed by an arithmetic operation, and folds them into a single constant at compile time.

```zig
const checkConstantFoldingPatternWithFusion = struct {
    fn check(bytecode: []const u8, position: PcType) ?FusionInfo {
        // Pattern A: PUSH1 a, PUSH1 b, <arith-op> (5 opcodes)
        // Pattern B: PUSH1 a, PUSH1 b, PUSH1 shift, SHL, SUB (8 opcodes)
        if (position + 4 >= bytecode.len) return null;

        // First PUSH1
        if (bytecode[position] != @intFromEnum(Opcode.PUSH1)) return null;
        const value1 = bytecode[position + 1];

        // Second PUSH1
        if (bytecode[position + 2] != @intFromEnum(Opcode.PUSH1)) return null;
        const value2 = bytecode[position + 3];

        // Next byte decides between pattern A and B
        const next = bytecode[position + 4];

        // Pattern A: arithmetic op directly after two PUSH1
        if (next == @intFromEnum(Opcode.ADD) or
            next == @intFromEnum(Opcode.SUB) or
            next == @intFromEnum(Opcode.MUL))
        {
            const folded_value: u256 = switch (next) {
                @intFromEnum(Opcode.ADD) => @as(u256, value1) +% @as(u256, value2),
                @intFromEnum(Opcode.SUB) => @as(u256, value1) -% @as(u256, value2),
                @intFromEnum(Opcode.MUL) => @as(u256, value1) *% @as(u256, value2),
                else => unreachable,
            };
            return FusionInfo{
                .fusion_type = .constant_fold,
                .original_length = 5,
                .folded_value = folded_value,
            };
        }

        // Pattern B: PUSH1 shift, SHL, SUB (8-opcode pattern)
        if (position + 7 < bytecode.len and
            next == @intFromEnum(Opcode.PUSH1) and
            bytecode[position + 6] == @intFromEnum(Opcode.SHL) and
            bytecode[position + 7] == @intFromEnum(Opcode.SUB))
        {
            const shift_amount = bytecode[position + 5];
            const shifted: u256 = if (shift_amount < 256)
                (@as(u256, value2) << @as(u8, @intCast(shift_amount)))
            else
                0;
            const folded_value: u256 = @as(u256, value1) -% shifted;
            return FusionInfo{
                .fusion_type = .constant_fold,
                .original_length = 8,
                .folded_value = folded_value,
            };
        }

        return null;
    }
}.check;
```

### Supported Patterns
- `PUSH1 a, PUSH1 b, ADD` → Single PUSH with value `(a + b)`
- `PUSH1 a, PUSH1 b, SUB` → Single PUSH with value `(a - b)`
- `PUSH1 a, PUSH1 b, MUL` → Single PUSH with value `(a * b)`
- `PUSH1 a, PUSH1 b, PUSH1 shift, SHL, SUB` → Single PUSH with value `a - (b << shift)`

## Multi-PUSH/POP Patterns

### Multi-PUSH Pattern Detection
Detects sequences of consecutive PUSH operations and fuses them into a single operation.

```zig
const checkNPushPattern = struct {
    fn check(bytecode: []const u8, position: PcType, n: u8) ?FusionInfo {
        if (position + n > bytecode.len) return null;
        
        var current_pc = position;
        var total_length: PcType = 0;
        
        // Check for n consecutive PUSH instructions
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            if (current_pc >= bytecode.len) return null;
            const op = bytecode[current_pc];
            if (op < @intFromEnum(Opcode.PUSH1) or op > @intFromEnum(Opcode.PUSH32)) {
                return null;
            }
            const push_size = op - @intFromEnum(Opcode.PUSH1) + 1;
            current_pc += 1 + push_size;
            total_length += 1 + push_size;
        }
        
        return FusionInfo{
            .fusion_type = .multi_push,
            .original_length = total_length,
            .count = n,
        };
    }
}.check;
```

### Multi-POP Pattern Detection
Detects sequences of consecutive POP operations and fuses them into a single operation.

```zig
const checkNPopPattern = struct {
    fn check(bytecode: []const u8, position: PcType, n: u8) ?FusionInfo {
        if (position + n > bytecode.len) return null;
        
        // Check if we have n consecutive POP instructions
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            if (bytecode[position + i] != @intFromEnum(Opcode.POP)) {
                return null;
            }
        }
        
        return FusionInfo{
            .fusion_type = .multi_pop,
            .original_length = n,
            .count = n,
        };
    }
}.check;
```

### Supported Patterns
- 2-PUSH sequence: Two consecutive PUSH operations
- 3-PUSH sequence: Three consecutive PUSH operations
- 2-POP sequence: `POP, POP`
- 3-POP sequence: `POP, POP, POP`

## ISZERO-JUMPI Pattern

### Pattern Detection
Detects the common pattern of checking if a value is zero and conditionally jumping.

```zig
const checkIszeroJumpiFusion = struct {
    fn check(bytecode: []const u8, position: PcType) ?FusionInfo {
        if (position + 2 >= bytecode.len) return null;
        
        // Check for ISZERO
        if (bytecode[position] != @intFromEnum(Opcode.ISZERO)) return null;
        
        // Check for PUSH after ISZERO
        const push_pc = position + 1;
        const push_op = bytecode[push_pc];
        if (push_op < @intFromEnum(Opcode.PUSH1) or push_op > @intFromEnum(Opcode.PUSH32)) {
            return null;
        }
        
        const push_size = push_op - @intFromEnum(Opcode.PUSH1) + 1;
        const jumpi_pc = push_pc + 1 + push_size;
        
        // Check for JUMPI
        if (jumpi_pc >= bytecode.len or bytecode[jumpi_pc] != @intFromEnum(Opcode.JUMPI)) {
            return null;
        }
        
        return FusionInfo{
            .fusion_type = .iszero_jumpi,
            .original_length = jumpi_pc + 1 - position,
        };
    }
}.check;
```

### Pattern Structure
- `ISZERO, PUSH<n> target, JUMPI` → Single fused operation that combines the zero check and conditional jump

## DUP2-MSTORE-PUSH Pattern

### Pattern Detection
Detects a common memory operation pattern used in Solidity for struct/array operations.

```zig
const checkDup2MstorePushFusion = struct {
    fn check(bytecode: []const u8, position: PcType) ?FusionInfo {
        if (position + 3 >= bytecode.len) return null;
        
        // Check for DUP2
        if (bytecode[position] != @intFromEnum(Opcode.DUP2)) return null;
        
        // Check for MSTORE
        if (bytecode[position + 1] != @intFromEnum(Opcode.MSTORE)) return null;
        
        // Check for PUSH after MSTORE
        const push_pc = position + 2;
        const push_op = bytecode[push_pc];
        if (push_op < @intFromEnum(Opcode.PUSH1) or push_op > @intFromEnum(Opcode.PUSH32)) {
            return null;
        }
        
        const push_size = push_op - @intFromEnum(Opcode.PUSH1) + 1;
        
        return FusionInfo{
            .fusion_type = .dup2_mstore_push,
            .original_length = 3 + push_size,
        };
    }
}.check;
```

### Pattern Structure
- `DUP2, MSTORE, PUSH<n> value` → Single fused operation that duplicates the second stack item, stores to memory, and pushes a new value

## Jump Optimization Patterns

### Jump Fusion Detection
Detects patterns where JUMPDEST is immediately followed by PUSH and JUMP/JUMPI, allowing direct jump to the final target.

```zig
// Look ahead for fusion pattern after JUMPDEST
if (pc + 1 < code.len) {
    const next_opcode = code[pc + 1];
    if (next_opcode >= @intFromEnum(Opcode.PUSH1) and next_opcode <= @intFromEnum(Opcode.PUSH32)) {
        const push_size = next_opcode - @intFromEnum(Opcode.PUSH1) + 1;
        const jump_pc = pc + 2 + push_size;
        
        // Check for JUMP after PUSH
        if (jump_pc < code.len and code[jump_pc] == @intFromEnum(Opcode.JUMP)) {
            // Extract target from PUSH data
            if (pc + 2 + push_size <= code.len) {
                var target_accum: u32 = 0;
                for (code[pc + 2..pc + 2 + push_size]) |byte| {
                    target_accum = (target_accum << 8) | byte;
                }
                if (target_accum <= std.math.maxInt(PcType)) {
                    try jump_fusions.put(pc, @intCast(target_accum));
                }
            }
        }
        // Check for JUMPI pattern
        else if (jump_pc + 1 < code.len) {
            const next_next_opcode = code[jump_pc];
            if (next_next_opcode >= @intFromEnum(Opcode.PUSH1) and next_next_opcode <= @intFromEnum(Opcode.PUSH32)) {
                const push2_size = next_next_opcode - @intFromEnum(Opcode.PUSH1) + 1;
                const jumpi_pc = jump_pc + 1 + push2_size;
                
                if (jumpi_pc < code.len and code[jumpi_pc] == @intFromEnum(Opcode.JUMPI)) {
                    // Extract target from first PUSH
                    if (pc + 2 + push_size <= code.len) {
                        var target_accum: u32 = 0;
                        for (code[pc + 2..pc + 2 + push_size]) |byte| {
                            target_accum = (target_accum << 8) | byte;
                        }
                        if (target_accum <= std.math.maxInt(PcType)) {
                            try jump_fusions.put(pc, @intCast(target_accum));
                        }
                    }
                }
            }
        }
    }
}
```

### Supported Patterns
- `JUMPDEST → PUSH target → JUMP` → Direct jump to target
- `JUMPDEST → PUSH target → PUSH condition → JUMPI` → Direct conditional jump to target

## Pattern Detection Infrastructure

### FusionInfo Structure
```zig
pub const FusionInfo = struct {
    fusion_type: FusionType,
    /// Length of original instruction sequence
    original_length: PcType,
    /// For constant folding, the computed value
    folded_value: ?u256 = null,
    /// For multi-PUSH/POP, number of operations
    count: ?u8 = null,
};

pub const FusionType = enum {
    /// Constant folding (e.g., PUSH PUSH SHL SUB -> single PUSH)
    constant_fold,
    /// Multiple PUSH instructions (2 or 3)
    multi_push,
    /// Multiple POP instructions (2 or 3) 
    multi_pop,
    /// ISZERO PUSH JUMPI sequence
    iszero_jumpi,
    /// DUP2 MSTORE PUSH sequence
    dup2_mstore_push,
};
```

### Pattern Priority Order
Patterns are checked in priority order during bytecode analysis:
1. Constant folding (8 opcodes max) - Highest priority
2. 3-PUSH fusion
3. 3-POP fusion
4. ISZERO-JUMPI pattern
5. DUP2-MSTORE-PUSH pattern
6. 2-PUSH fusion
7. 2-POP fusion - Lowest priority

## Handler Implementation Notes

### Handler Requirements for Fused Operations
Each fused operation needs a specialized handler that:
1. Performs all operations atomically
2. Updates stack correctly for the entire sequence
3. Accounts for correct gas costs
4. Maintains proper PC advancement

### Example: Constant Fold Handler
```zig
// Instead of executing PUSH1 a, PUSH1 b, ADD
// The handler would:
// 1. Push the pre-computed value (a + b) directly onto the stack
// 2. Account for gas cost of all three operations
// 3. Advance PC past all original opcodes
```

### Example: Multi-POP Handler
```zig
// Instead of executing POP, POP, POP
// The handler would:
// 1. Pop 3 values from stack in one operation
// 2. Check for stack underflow once
// 3. Update stack pointer by 3
```

### Example: ISZERO-JUMPI Handler
```zig
// Instead of executing ISZERO, PUSH target, JUMPI
// The handler would:
// 1. Pop value from stack
// 2. Check if zero
// 3. If zero, jump directly to target (no intermediate PUSH)
// 4. Save gas by avoiding the PUSH operation
```

## Integration with Dispatch System

### Detection Phase
The patterns are detected during bytecode analysis in a single pass:
```zig
// Single pass through bytecode
var pc: PcType = 0;
while (pc < code.len) {
    const opcode = code[pc];
    
    // Check for advanced fusion patterns (in priority order)
    // This needs to happen before processing individual opcodes
    
    // 1. Check for constant folding pattern (highest priority, longest pattern)
    if (checkConstantFoldingPatternWithFusion(code, pc)) |fusion_info| {
        try advanced_fusions.put(pc, fusion_info);
        pc += fusion_info.original_length;
        continue;
    }
    
    // 2. Check for 3-PUSH fusion
    if (checkNPushPattern(code, pc, 3)) |fusion_info| {
        try advanced_fusions.put(pc, fusion_info);
        pc += fusion_info.original_length;
        continue;
    }
    
    // ... check other patterns in priority order ...
}
```

### Execution Phase
During execution, the dispatch system would:
1. Check if current PC has an advanced fusion entry
2. If yes, execute the fused handler
3. Skip past all original opcodes in the fused sequence
4. Continue with next instruction after the fusion

## Performance Benefits

### Constant Folding
- Eliminates runtime arithmetic operations
- Reduces stack operations
- Improves branch prediction by reducing instruction count

### Multi-PUSH/POP
- Reduces loop overhead for consecutive operations
- Better cache locality by batching stack operations
- Single bounds check instead of multiple

### ISZERO-JUMPI
- Common pattern in Solidity (if statements)
- Eliminates intermediate PUSH operation
- Reduces stack depth requirements

### DUP2-MSTORE-PUSH
- Common in array/struct operations
- Reduces instruction dispatch overhead
- Better pipeline utilization

### Jump Optimization
- Eliminates intermediate jumps (tail call optimization)
- Reduces JUMPDEST validation overhead
- Improves branch prediction accuracy

## Testing Considerations

Each fusion pattern should be tested with:
1. Correct execution semantics
2. Gas cost accuracy
3. Stack depth tracking
4. Edge cases (pattern at end of bytecode)
5. Interaction with other fusions
6. Performance benchmarks comparing fused vs unfused execution