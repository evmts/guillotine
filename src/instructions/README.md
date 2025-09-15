# Instructions Module

## Overview

The Instructions module contains the complete implementation of EVM opcodes organized into semantic handler groups. Each handler file provides optimized implementations of related EVM operations with consistent interfaces and performance characteristics.

This module implements the full EVM instruction set according to the Ethereum Yellow Paper specification, with handlers organized by functional categories for maintainability and efficient dispatch.

## Handler Files

### Core Handler Files

#### `handlers_arithmetic.zig` - Arithmetic Operations
**Opcodes**: 0x01-0x0B
**Functions**:
- `add()` - Addition with overflow wrapping (0x01)
- `mul()` - Multiplication with overflow wrapping (0x02)
- `sub()` - Subtraction with underflow wrapping (0x03)
- `div()` - Unsigned division, returns 0 on division by zero (0x04)
- `sdiv()` - Signed division with proper handling of edge cases (0x05)
- `mod()` - Modulo operation, returns 0 when divisor is 0 (0x06)
- `smod()` - Signed modulo operation (0x07)
- `addmod()` - Modular addition (a + b) % N (0x08)
- `mulmod()` - Modular multiplication (a * b) % N (0x09)
- `exp()` - Exponentiation with gas-based complexity (0x0A)
- `signextend()` - Sign extension for smaller integer types (0x0B)

#### `handlers_bitwise.zig` - Bitwise Operations
**Opcodes**: 0x16-0x1D
**Functions**:
- `and()` - Bitwise AND operation (0x16)
- `or()` - Bitwise OR operation (0x17)
- `xor()` - Bitwise XOR operation (0x18)
- `not()` - Bitwise NOT operation (0x19)
- `byte()` - Extract specific byte from word (0x1A)
- `shl()` - Shift left operation (0x1B)
- `shr()` - Logical shift right operation (0x1C)
- `sar()` - Arithmetic shift right operation (0x1D)

#### `handlers_comparison.zig` - Comparison Operations
**Opcodes**: 0x10-0x15
**Functions**:
- `lt()` - Unsigned less than comparison (0x10)
- `gt()` - Unsigned greater than comparison (0x11)
- `slt()` - Signed less than comparison (0x12)
- `sgt()` - Signed greater than comparison (0x13)
- `eq()` - Equality comparison (0x14)
- `iszero()` - Check if value is zero (0x15)

#### `handlers_context.zig` - Environmental Information
**Opcodes**: 0x30-0x4A, 0x58, 0x5A
**Functions**:
- Account information: ADDRESS, BALANCE, ORIGIN, CALLER, CALLVALUE, SELFBALANCE
- Call data: CALLDATALOAD, CALLDATASIZE, CALLDATACOPY
- Code operations: CODESIZE, CODECOPY, EXTCODESIZE, EXTCODECOPY, EXTCODEHASH
- Return data: RETURNDATASIZE, RETURNDATACOPY
- Block information: BLOCKHASH, COINBASE, TIMESTAMP, NUMBER, DIFFICULTY/PREVRANDAO
- Gas and chain: GASPRICE, GASLIMIT, CHAINID, BASEFEE, GAS
- Blob operations: BLOBHASH, BLOBBASEFEE (EIP-4844)
- Program counter: PC

#### `handlers_jump.zig` - Control Flow Operations
**Opcodes**: 0x56-0x57, 0x5B, 0x58
**Functions**:
- `jump()` - Unconditional jump to destination (0x56)
- `jumpi()` - Conditional jump based on condition (0x57)
- `jumpdest()` - Valid jump destination marker (0x5B)
- `pc()` - Get current program counter (0x58)

#### `handlers_keccak.zig` - Cryptographic Hash Operations
**Opcodes**: 0x20
**Functions**:
- `keccak256()` - Keccak-256 hash function with size-optimized variants (0x20)

#### `handlers_log.zig` - Event Logging Operations
**Opcodes**: 0xA0-0xA4
**Functions**:
- `generateLogHandler()` - Template function generating LOG0-LOG4 handlers
- Supports logging with 0-4 indexed topics for efficient event filtering

#### `handlers_memory.zig` - Memory Operations
**Opcodes**: 0x51-0x59, 0x5E
**Functions**:
- `mload()` - Load 32-byte word from memory (0x51)
- `mstore()` - Store 32-byte word to memory (0x52)
- `mstore8()` - Store single byte to memory (0x53)
- `msize()` - Get current memory size in bytes (0x59)
- `mcopy()` - Copy memory regions (EIP-5656) (0x5E)

#### `handlers_stack.zig` - Stack Operations
**Opcodes**: 0x50, 0x5F, 0x60-0x7F, 0x80-0x8F, 0x90-0x9F
**Functions**:
- `pop()` - Remove top stack item (0x50)
- `push0()` - Push zero to stack (EIP-3855) (0x5F)
- `generatePushHandler()` - Template for PUSH1-PUSH32 operations (0x60-0x7F)
- `generateDupHandler()` - Template for DUP1-DUP16 operations (0x80-0x8F)
- `generateSwapHandler()` - Template for SWAP1-SWAP16 operations (0x90-0x9F)

#### `handlers_storage.zig` - Storage Operations
**Opcodes**: 0x54-0x55, EIP-1153
**Functions**:
- `sload()` - Load from persistent storage (0x54)
- `sstore()` - Store to persistent storage with gas refunds (0x55)
- `tload()` - Load from transient storage (EIP-1153)
- `tstore()` - Store to transient storage (EIP-1153)

#### `handlers_system.zig` - System Operations
**Opcodes**: 0xF0-0xFF, 0x00
**Functions**:
- `call()` - External contract call (0xF1)
- `callcode()` - Call with current contract context (0xF2)
- `delegatecall()` - Delegate call preserving msg.sender (0xF4)
- `staticcall()` - Static call without state changes (0xFA)
- `create()` - Create new contract (0xF0)
- `create2()` - Create contract with deterministic address (0xF5)
- `return()` - Return data and halt execution (0xF3)
- `revert()` - Revert transaction with data (0xFD)
- `selfdestruct()` - Destroy contract and send funds (0xFF)
- `stop()` - Halt execution (0x00)
- `auth()` - Authorization opcode (EIP-3074) (0xF6)
- `authcall()` - Authorized call (EIP-3074) (0xF7)

### Synthetic Optimization Files

#### `handlers_arithmetic_synthetic.zig` - Fused Arithmetic Operations
**Functions**:
- `push_add_inline()` / `push_add_pointer()` - PUSH + ADD fusion
- `push_mul_inline()` / `push_mul_pointer()` - PUSH + MUL fusion
- `push_div_inline()` / `push_div_pointer()` - PUSH + DIV fusion
- `push_sub_inline()` / `push_sub_pointer()` - PUSH + SUB fusion

#### `handlers_bitwise_synthetic.zig` - Fused Bitwise Operations
**Functions**:
- `push_and_inline()` / `push_and_pointer()` - PUSH + AND fusion
- `push_or_inline()` / `push_or_pointer()` - PUSH + OR fusion
- `push_xor_inline()` / `push_xor_pointer()` - PUSH + XOR fusion

#### `handlers_memory_synthetic.zig` - Fused Memory Operations
**Functions**:
- `push_mload_inline()` / `push_mload_pointer()` - PUSH + MLOAD fusion
- `push_mstore_inline()` / `push_mstore_pointer()` - PUSH + MSTORE fusion
- `push_mstore8_inline()` / `push_mstore8_pointer()` - PUSH + MSTORE8 fusion

#### `handlers_jump_synthetic.zig` - Optimized Jump Operations
**Functions**:
- `jump_to_static_location()` - Direct jump without binary search
- `jumpi_to_static_location()` - Direct conditional jump without binary search
- `push_jump_inline()` / `push_jump_pointer()` - PUSH + JUMP fusion
- `push_jumpi_inline()` / `push_jumpi_pointer()` - PUSH + JUMPI fusion

#### `handlers_advanced_synthetic.zig` - Complex Fusion Patterns
**Functions**:
- `multi_push_2()` / `multi_push_3()` - Push multiple values efficiently
- `multi_pop_2()` / `multi_pop_3()` - Pop multiple values efficiently
- `iszero_jumpi()` - Combined zero check and conditional jump
- `function_dispatch()` - Optimized function selector matching
- `callvalue_check()` - Optimized payable function check
- `push0_revert()` - Efficient revert with no data
- `dup2_mstore_push()` - Complex stack + memory operation
- `dup3_add_mstore()` - Arithmetic + memory fusion
- `swap1_dup2_add()` - Stack manipulation + arithmetic
- `push_dup3_add()` - Push + stack + arithmetic
- `push_add_dup1()` - Arithmetic + stack duplication
- `mload_swap1_dup2()` - Memory + stack operations

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
