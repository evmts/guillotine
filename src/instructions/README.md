# Instructions Module

## Overview

The Instructions module contains the complete implementation of EVM opcodes organized into semantic handler groups. Each handler file provides optimized implementations of related EVM operations with consistent interfaces and performance characteristics.

This module implements the full EVM instruction set according to the Ethereum Yellow Paper specification, with handlers organized by functional categories for maintainability and efficient dispatch.

## Core Components

### Handler Files

- **`handlers_arithmetic.zig`** - Arithmetic operations (ADD, MUL, SUB, DIV, MOD, EXP, etc.)
- **`handlers_bitwise.zig`** - Bitwise logic operations (AND, OR, XOR, NOT, SHL, SHR, SAR, BYTE)
- **`handlers_comparison.zig`** - Comparison operations (LT, GT, SLT, SGT, EQ, ISZERO)
- **`handlers_context.zig`** - Environment and context queries (ADDRESS, BALANCE, CALLER, ORIGIN, block info, etc.)
- **`handlers_jump.zig`** - Control flow operations (JUMP, JUMPI, JUMPDEST, PC)
- **`handlers_keccak.zig`** - Cryptographic hash operations (KECCAK256)
- **`handlers_log.zig`** - Event logging operations (LOG0, LOG1, LOG2, LOG3, LOG4)
- **`handlers_memory.zig`** - Memory operations (MLOAD, MSTORE, MSTORE8, MSIZE)
- **`handlers_stack.zig`** - Stack manipulation operations (PUSH1-32, POP, DUP1-16, SWAP1-16)
- **`handlers_storage.zig`** - Persistent storage operations (SLOAD, SSTORE, TLOAD, TSTORE)
- **`handlers_system.zig`** - System operations (CALL, CREATE, RETURN, REVERT, SELFDESTRUCT)

### Synthetic Variants

Several handler files include synthetic variants optimized for specific execution contexts:
- **`handlers_arithmetic_synthetic.zig`** - Fused PUSH+arithmetic operations (ADD, MUL, DIV, SUB)
- **`handlers_bitwise_synthetic.zig`** - Fused PUSH+bitwise operations (AND, OR, XOR)
- **`handlers_memory_synthetic.zig`** - Fused PUSH+memory operations (MLOAD, MSTORE)
- **`handlers_jump_synthetic.zig`** - Optimized static jump operations without binary search
- **`handlers_advanced_synthetic.zig`** - Complex fusion patterns (MULTI_PUSH, ISZERO_JUMPI, FUNCTION_DISPATCH)

## Key Data Structures

### Handler Function Signature
```zig
pub fn opcode_handler(
    self: *FrameType, 
    cursor: [*]const Dispatch.Item
) Error!noreturn {
    // Opcode implementation
    // Get operation data and advance to next instruction
    const dispatch = Dispatch{ .cursor = cursor };
    const op_data = dispatch.getOpData(.OPCODE_NAME);
    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
}
```

### Handler Registration
```zig
pub fn Handlers(comptime FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;
        
        // Handler implementations...
    };
}
```

### Dispatch Integration
Handlers integrate with the dispatch system through:
- Cursor-based execution chains
- Tail call optimization
- Type-safe opcode binding

## Performance Considerations

### Tail Call Optimization
All handlers use Zig's tail call optimization to eliminate function call overhead:
```zig
const dispatch = Dispatch{ .cursor = cursor };
const op_data = dispatch.getOpData(.OPCODE_NAME);
return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
```

### Stack Validation
Handlers use assertion-based validation for performance:
```zig
std.debug.assert(self.stack.size() >= 2); // Required stack items
self.stack.binary_op_unsafe(struct { 
    fn op(top: WordType, second: WordType) WordType { 
        return top +% second; 
    } 
}.op);
```

### Memory Alignment  
Critical data structures maintain proper alignment for optimal memory access patterns.

### Branch Prediction
Handler organization minimizes branch mispredictions through:
- Consistent control flow patterns
- Predictable error handling paths
- Optimized common case execution

## Usage Examples

### Basic Arithmetic Handler
```zig
/// ADD opcode (0x01) - Addition with overflow wrapping
pub fn add(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
    std.debug.assert(self.stack.size() >= 2); 
    
    self.stack.binary_op_unsafe(struct { 
        fn op(top: WordType, second: WordType) WordType { 
            return top +% second; 
        } 
    }.op);

    const dispatch = Dispatch{ .cursor = cursor };
    const op_data = dispatch.getOpData(.ADD);
    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
}
```

### Memory Operation Handler
```zig
/// MSTORE opcode (0x52) - Store word to memory (EVM expansion semantics)
pub fn mstore(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
    const dispatch = Dispatch{ .cursor = cursor };
    std.debug.assert(self.stack.size() >= 2);
    const offset = self.stack.pop_unsafe();
    const value = self.stack.pop_unsafe();

    // Gas calculation and memory expansion handled by frame
    const memory_cost = try self.calculateMemoryGas(offset, 32);
    self.gas_remaining -= @intCast(memory_cost);
    if (self.gas_remaining < 0) return Error.OutOfGas;

    try self.memory.set_u256_evm(self.getAllocator(), @as(u24, @intCast(offset)), value);

    const op_data = dispatch.getOpData(.MSTORE);
    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
}
```

### Control Flow Handler
```zig
/// JUMPI opcode (0x57) - Conditional jump  
pub fn jumpi(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
    const dispatch = Dispatch{ .cursor = cursor };
    std.debug.assert(self.stack.size() >= 2);
    const dest = self.stack.pop_unsafe();
    const condition = self.stack.pop_unsafe();
    
    if (condition != 0) {
        // Validate jump destination
        if (!self.jump_table.is_valid_dest(dest)) {
            return Error.InvalidJumpDestination;
        }
        // Jump to destination using dispatch binary search
        const jump_cursor = self.dispatch.binary_search_cursor(dest);
        return @call(FrameType.getTailCallModifier(), jump_cursor[0].opcode_handler, .{ self, jump_cursor });
    } else {
        // Continue to next instruction
        const op_data = dispatch.getOpData(.JUMPI);
        return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
    }
}
```

## Handler Categories

### Arithmetic Handlers (0x01-0x0B)
- Basic operations: ADD, MUL, SUB, DIV, MOD
- Signed operations: SDIV, SMOD
- Modular arithmetic: ADDMOD, MULMOD
- Advanced: EXP (exponentiation), SIGNEXTEND

### Comparison Handlers (0x10-0x15)
- Unsigned comparison: LT, GT, EQ
- Signed comparison: SLT, SGT
- Boolean operations: ISZERO

### Bitwise Handlers (0x16-0x1D)
- Logic operations: AND, OR, XOR, NOT
- Byte operations: BYTE (extract byte from word)
- Shift operations: SHL, SHR, SAR (arithmetic shift)

### Keccak Handler (0x20)
- Cryptographic hash: KECCAK256 (with size-optimized variants)

### Context Handlers (0x30-0x4A, 0x58, 0x5A)
- Account info: ADDRESS, BALANCE, ORIGIN, CALLER, CALLVALUE, SELFBALANCE
- Call data: CALLDATALOAD, CALLDATASIZE, CALLDATACOPY
- Code operations: CODESIZE, CODECOPY, EXTCODESIZE, EXTCODECOPY, EXTCODEHASH
- Return data: RETURNDATASIZE, RETURNDATACOPY
- Block info: BLOCKHASH, COINBASE, TIMESTAMP, NUMBER, DIFFICULTY/PREVRANDAO
- Gas and chain: GASPRICE, GASLIMIT, CHAINID, BASEFEE, GAS
- Blob operations: BLOBHASH, BLOBBASEFEE (EIP-4844)
- Program counter: PC

### Stack Handlers (0x50, 0x5F, 0x60-0x7F, 0x80-0x8F, 0x90-0x9F)
- Stack removal: POP
- Zero push: PUSH0 (EIP-3855)
- Push operations: PUSH1-PUSH32 (with inline/pointer optimization)
- Duplication: DUP1-DUP16  
- Swapping: SWAP1-SWAP16

### Memory Handlers (0x51-0x59, 0x5E)
- Word operations: MLOAD, MSTORE
- Byte operations: MSTORE8  
- Size queries: MSIZE
- Data copying: CALLDATACOPY, CODECOPY, RETURNDATACOPY
- Memory copy: MCOPY (EIP-5656)

### Storage Handlers (0x54-0x55, EIP-1153)
- Persistent storage: SLOAD, SSTORE
- Transient storage: TLOAD, TSTORE (EIP-1153)

### System Handlers (0xF0-0xFF)
- Contract creation: CREATE, CREATE2
- External calls: CALL, STATICCALL, DELEGATECALL, CALLCODE
- Execution termination: RETURN, REVERT, SELFDESTRUCT
- Authorization (EIP-3074): AUTH, AUTHCALL

## Synthetic Optimizations

The instruction handlers include several synthetic variants that fuse multiple operations for performance:

### Bytecode Fusion Patterns

#### PUSH+Arithmetic Fusion
- **PUSH_ADD_INLINE/POINTER** - Combines PUSH + ADD in single operation
- **PUSH_MUL_INLINE/POINTER** - Combines PUSH + MUL in single operation
- **PUSH_DIV_INLINE/POINTER** - Combines PUSH + DIV in single operation
- **PUSH_SUB_INLINE/POINTER** - Combines PUSH + SUB in single operation

#### PUSH+Bitwise Fusion
- **PUSH_AND_INLINE/POINTER** - Combines PUSH + AND in single operation
- **PUSH_OR_INLINE/POINTER** - Combines PUSH + OR in single operation
- **PUSH_XOR_INLINE/POINTER** - Combines PUSH + XOR in single operation

#### PUSH+Memory Fusion
- **PUSH_MLOAD_INLINE/POINTER** - Combines PUSH + MLOAD in single operation
- **PUSH_MSTORE_INLINE/POINTER** - Combines PUSH + MSTORE in single operation

#### Advanced Fusion Patterns
- **MULTI_PUSH_2/3** - Push multiple values in single operation
- **ISZERO_JUMPI** - Combined zero check and conditional jump
- **JUMP_TO_STATIC_LOCATION** - Direct jump without binary search
- **JUMPI_TO_STATIC_LOCATION** - Direct conditional jump without binary search
- **FUNCTION_DISPATCH** - Optimized function selector matching
- **CALLVALUE_CHECK** - Optimized payable function check

### Inline vs Pointer Values

Synthetic operations distinguish between:
- **Inline values** (≤8 bytes): Stored directly in dispatch metadata
- **Pointer values** (>8 bytes): Stored in constant pool, referenced by index

## Error Handling

Handler errors are propagated through the execution chain with specific error types:
- `StackOverflow`/`StackUnderflow` - Stack constraint violations
- `InvalidJumpDestination` - Invalid JUMP/JUMPI targets
- `OutOfGas` - Insufficient gas for operation
- `StaticViolation` - State modification in static context
- `InvalidOpcode` - Unrecognized instruction

All handlers maintain clean error propagation with proper resource cleanup through defer patterns.

## Integration Notes

### With Frame Module
Handlers receive frame context and manipulate:
- Stack state through safe/unsafe operations
- Memory through expansion and access APIs  
- Storage through database interface
- Gas accounting through frame gas tracker

### With Dispatch Module
Handlers integrate with dispatch through:
- Cursor-based instruction iteration
- Tail call chaining for performance
- Type-safe opcode binding

### With Opcodes Module
Handler binding relies on opcode definitions for:
- Instruction identification
- Gas cost lookup
- Validation requirements
