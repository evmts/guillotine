# Opcode Metadata - Opcode Dispatch System

High-performance opcode dispatch mechanism that maps EVM opcodes to their implementations while enforcing hardfork rules and stack validation.

## Purpose

The opcode metadata system provides:
- Fast O(1) opcode-to-function dispatch
- Hardfork-aware operation availability
- Centralized stack validation
- Operation metadata (gas costs, stack effects)
- Size-optimized execution path

## Architecture

The system consists of two main components:

1. **Opcode Metadata**: Maps opcodes to function pointers based on hardfork
2. **Operation Config**: Metadata about each operation (stack requirements, gas)

The opcode metadata validates all stack preconditions, allowing individual operations to use unsafe (but fast) stack operations without compromising safety.

## Files

### `opcode_metadata.zig`
Core dispatch table mapping opcodes to implementations.

**Structure**:
```zig
OpcodeMetadata = struct {
    table: [256]OperationFunc,  // Function pointers indexed by opcode
    config: [256]Operation,      // Operation metadata
}
```

**Key Features**:
- Hardfork-specific table generation
- Stack validation before dispatch
- Disabled opcode handling
- Performance-optimized dispatch

**Key Methods**:
- `init(hardfork)`: Create table for specific hardfork
- `generate()`: Build function pointer array
- `execute()`: Dispatch with validation

**Execution Flow**:
1. Fetch opcode from bytecode
2. Look up operation config
3. Validate stack has required items
4. Dispatch to operation function
5. Operation modifies stack/state
6. Return execution result

**Performance**:
- O(1) dispatch via array indexing
- Single bounds check for stack validation
- No per-operation validation overhead

**Used By**: Main interpreter loop

### `operation_config.zig`
Generates operation metadata for each hardfork.

**Operation Structure**:
```zig
Operation = struct {
    // Function pointer to implementation
    exec: OperationFunc,
    
    // Stack configuration
    min_stack: u16,        // Items required
    max_stack: u16,        // Items after execution
    
    // Gas cost (simple operations only)
    static_gas: ?u64,      // None for dynamic gas
}
```

**Key Functions**:
- `generateHardforkOperationTable()`: Build config for hardfork
- Maps each opcode to its metadata
- Handles hardfork-specific availability

**Hardfork Evolution Examples**:
- `PUSH0`: Added in Shanghai
- `TLOAD/TSTORE`: Added in Cancun
- `DIFFICULTY→PREVRANDAO`: Changed in Merge
- `SELFDESTRUCT`: Behavior modified over time

**Categories Covered**:
1. Arithmetic operations
2. Comparison operations
3. Bitwise operations
4. Keccak hashing
5. Environmental queries
6. Block information
7. Stack operations
8. Memory operations
9. Storage operations
10. Control flow
11. System operations
12. Logging

**Used By**: Jump table initialization

## Operation Categories

### Always Available (Frontier+)
- **Arithmetic**: ADD, MUL, SUB, DIV, SDIV, MOD, SMOD, EXP, SIGNEXTEND
- **Comparison**: LT, GT, SLT, SGT, EQ, ISZERO
- **Bitwise**: AND, OR, XOR, NOT, BYTE, SHL, SHR, SAR
- **Keccak**: KECCAK256
- **Environment**: ADDRESS, BALANCE, ORIGIN, CALLER, CALLVALUE, CALLDATASIZE, GASPRICE
- **Block**: BLOCKHASH, COINBASE, TIMESTAMP, NUMBER, GASLIMIT
- **Stack**: POP, PUSH1-PUSH32, DUP1-DUP16, SWAP1-SWAP16
- **Memory**: MLOAD, MSTORE, MSTORE8, MSIZE
- **Storage**: SLOAD, SSTORE
- **Flow**: JUMP, JUMPI, PC, GAS, JUMPDEST, STOP, RETURN, INVALID
- **System**: CREATE, CALL, CALLCODE, SELFDESTRUCT
- **Data**: CALLDATALOAD, CALLDATACOPY, CODESIZE, CODECOPY, EXTCODESIZE, EXTCODECOPY
- **Logs**: LOG0, LOG1, LOG2, LOG3, LOG4

### Hardfork-Specific Additions
- **Homestead**: DELEGATECALL
- **Byzantium**: REVERT, RETURNDATASIZE, RETURNDATACOPY, STATICCALL
- **Constantinople**: CREATE2, EXTCODEHASH
- **Istanbul**: CHAINID, SELFBALANCE
- **London**: BASEFEE
- **Shanghai**: PUSH0
- **Cancun**: TLOAD, TSTORE, BLOBHASH, BLOBBASEFEE, MCOPY

## Usage

### Basic Execution
```zig
const table = OpcodeMetadata.init_from_hardfork(.LONDON);

const opcode = 0x01; // ADD
const op = table.get_operation(opcode);
// Then use op.execute(...) with your interpreter/state as appropriate
```

### Creating Custom Tables
```zig
// Get operation config for specific hardfork
const operations = generateHardforkOperationTable(.SHANGHAI);

// Check if opcode is available
if (operations[0x5f].exec != invalidOpcode) {
    // PUSH0 is available in Shanghai
}
```

## Stack Validation

The opcode metadata performs critical safety checks:

1. **Underflow Prevention**: Ensures enough items for operation
2. **Overflow Prevention**: Ensures room for results
3. **Single Validation Point**: One check covers entire operation

This allows operations to use unsafe stack access:
```zig
// In operation implementation - no bounds checks needed!
const a = state.stack.items[state.stack.items.len - 1];
const b = state.stack.items[state.stack.items.len - 2];
```

## Performance Characteristics

- **Dispatch**: ~2-3 CPU cycles (array lookup)
- **Validation**: ~5-10 cycles (comparison + branch)
- **Total Overhead**: <15 cycles per operation
- **Memory**: 4KB per opcode metadata (256 entries × 16 bytes)

## Hardfork Support

Tables are generated at runtime based on hardfork:
- Unsupported opcodes point to `invalidOpcode`
- Gas costs reflect hardfork-specific values
- Behavior changes handled by different function pointers

## Error Handling

Operations can return:
- `Result.Continue`: Normal execution
- `Result.Stop`: Halt execution
- `Result.Return`: Return data to caller
- `Result.Revert`: Revert state changes
- `Error`: Out of gas, stack errors, etc.

## Testing

The module includes:
- Hardfork compatibility tests
- Stack validation tests
- Operation availability tests
- Performance benchmarks

## Design Benefits

1. **Safety**: Centralized validation prevents stack errors
2. **Performance**: Minimal per-operation overhead
3. **Flexibility**: Easy hardfork additions
4. **Size**: Operations can omit validation code
5. **Clarity**: Clean separation of dispatch and execution

## Implementation Notes

- Function pointers are stored directly (no indirection)
- Config and table are separate for cache efficiency
- Operations assume valid stack (faster execution)
- Invalid opcodes consume all gas
- Table generation is deterministic

## Future Considerations

- EOF (EVM Object Format) will change dispatch
- New opcodes require table regeneration
- Static jumps may enable further optimization
- SIMD operations could batch simple opcodes