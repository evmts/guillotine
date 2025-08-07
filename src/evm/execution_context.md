# ExecutionContext (Frame) - Main EVM State Structure

## Overview

The `ExecutionContext` (aliased as `Frame`) is the **primary data structure** for holding EVM execution state in Guillotine. Located at `src/evm/execution_context.zig`, this structure represents a complete execution context for EVM bytecode, containing all the state needed by opcode executors during contract execution.

This structure replaced the heavier, more complex Frame implementation with a data-oriented design optimized for cache performance and minimal memory allocations.

## Core Design Philosophy

- **Data-Oriented Design**: Fields are ordered by access frequency for optimal cache locality
- **Zero Circular Dependencies**: Self-contained structure that doesn't create import cycles
- **Minimal Allocations**: Only allocates what's necessary, with explicit ownership patterns
- **Performance First**: Hot data (stack, gas) is placed at the beginning of the struct

## Structure Layout (64-bit optimized)

### Hot Data (Most Frequently Accessed)
```zig
stack: Stack,                    // 33,536 bytes - accessed every opcode
gas_remaining: u64,              // 8 bytes - checked constantly for gas consumption
```

### Packed Flags (64-bit aligned)
```zig
flags: Flags,                    // 8 bytes - packed hardfork flags and execution state
```

### Frequently Accessed Pointers
```zig
memory: *Memory,                 // 8 bytes - hot for MLOAD/MSTORE operations
analysis: *const CodeAnalysis,   // 8 bytes - hot for JUMP/JUMPI validation
access_list: *AccessList,        // 8 bytes - warm for EIP-2929 access tracking
state: DatabaseInterface,        // 16 bytes - medium frequency for storage ops
```

### Cold Data (Rarely Accessed)
```zig
input: []const u8,               // 16 bytes - calldata for CALLDATALOAD/SIZE/COPY
output: []const u8,              // 16 bytes - only for RETURN/REVERT
contract_address: Address,       // 20 bytes - rarely needed directly
self_destruct: ?*SelfDestruct,   // 8 bytes - very rare (SELFDESTRUCT opcode)
```

## Field Documentation

### Core Execution State

#### `stack: Stack`
- **Purpose**: The EVM execution stack (max 1024 elements)
- **Size**: 33,536 bytes 
- **Access Pattern**: Accessed by virtually every opcode
- **Operations**: PUSH/POP operations, DUP, SWAP
- **Location**: `src/evm/stack/stack.zig`

#### `gas_remaining: u64`
- **Purpose**: Tracks remaining gas for current execution
- **Access Pattern**: Checked/modified constantly during execution
- **Operations**: Gas consumption validation, out-of-gas detection
- **Critical**: Execution halts when this reaches 0

#### `flags: Flags` (Packed Struct - 64 bits total)
Contains execution state and hardfork feature flags:

**Execution State (11 bits)**:
- `depth: u10` (10 bits) - Call stack depth (0-1023)
- `is_static: bool` (1 bit) - Static call restriction flag

**Hardfork Feature Flags (33 bits used, ordered newest→oldest)**:
- `is_prague: bool` - Future hardfork
- `is_cancun: bool` + EIP flags (4 bits) - Latest (2024)
- `is_shanghai: bool` + EIP flags (5 bits) - 2023
- `is_merge: bool` - 2022  
- `is_london: bool` + EIP flags (4 bits) - 2021
- `is_berlin: bool` + EIP flags (2 bits) - 2021
- `is_istanbul: bool` through `is_homestead: bool` (6 bits) - 2019-2016
- `_reserved: u20` - Future expansion

### Memory and Code Analysis

#### `memory: *Memory`
- **Purpose**: Byte-addressable memory for MLOAD/MSTORE operations
- **Access Pattern**: Hot for memory opcodes (MLOAD, MSTORE, MSIZE, etc.)
- **Implementation**: `src/evm/memory/memory.zig`
- **Growth**: Dynamically expands as needed, gas cost increases quadratically

#### `analysis: *const CodeAnalysis`
- **Purpose**: Pre-computed bytecode analysis including valid jump destinations
- **Access Pattern**: Hot for control flow opcodes (JUMP, JUMPI)
- **Key Feature**: `jumpdest_bitmap` for O(1) jump destination validation
- **Implementation**: `src/evm/frame/code_analysis.zig`

### State and Access Tracking

#### `access_list: *AccessList`
- **Purpose**: EIP-2929 warm/cold access tracking for addresses and storage keys
- **Access Pattern**: Frequently accessed for gas cost calculations
- **Gas Impact**: First access = cold (expensive), subsequent = warm (cheap)
- **Implementation**: `src/evm/access_list.zig`

#### `state: DatabaseInterface`
- **Purpose**: Interface to blockchain state (accounts, storage, balances)
- **Access Pattern**: Medium frequency for storage operations (SLOAD, SSTORE)
- **Operations**: Storage read/write, balance queries, account existence
- **Implementation**: `src/evm/state/database_interface.zig`

### Input/Output and Contract Context

#### `input: []const u8`
- **Purpose**: Calldata passed to the contract execution
- **Access Pattern**: Cold - accessed only by calldata opcodes
- **Usage**: CALLDATALOAD, CALLDATASIZE, CALLDATACOPY operations
- **Contents**: Transaction calldata or internal call parameters

#### `output: []const u8`
- **Purpose**: Return data from RETURN or REVERT operations
- **Access Pattern**: Cold - only set/read on function exit
- **Usage**: Captured by calling contracts for return value processing

#### `contract_address: Address`
- **Purpose**: Address of the currently executing contract
- **Access Pattern**: Cold - rarely accessed directly during execution
- **Usage**: Storage operations, self-destruct operations, address-based opcodes

#### `self_destruct: ?*SelfDestruct`
- **Purpose**: Tracks contracts marked for destruction via SELFDESTRUCT
- **Access Pattern**: Very cold - only used by SELFDESTRUCT opcode
- **Optional**: Can be null if self-destruct is not available in current hardfork
- **Implementation**: `src/evm/self_destruct.zig`

## Key Methods

### Gas Management
```zig
consume_gas(amount: u64) !void                    // Gas consumption with bounds checking
```

### Jump Validation
```zig
valid_jumpdest(dest: u256) bool                   // O(1) jump destination validation
```

### Access List Operations (EIP-2929)
```zig
access_address(addr: Address) !u64                // Address access cost calculation
mark_storage_slot_warm(slot: u256) !bool          // Storage slot warming
```

### Storage Operations
```zig
get_storage(slot: u256) u256                      // Read from persistent storage
set_storage(slot: u256, value: u256) !void        // Write to persistent storage
get_transient_storage(slot: u256) u256            // Read from transient storage (EIP-1153)
set_transient_storage(slot: u256, value: u256) !void // Write to transient storage
```

### Contract Operations
```zig
mark_for_destruction(recipient: Address) !void    // SELFDESTRUCT implementation
set_output(data: []const u8) void                 // Set RETURN/REVERT data
```

### Compatibility Accessors
```zig
depth() u32                                        // Get call depth
is_static() bool                                   // Check static call status
set_depth(d: u32) void                            // Set call depth
set_is_static(static: bool) void                   // Set static call flag
```

## References Throughout Codebase

### Primary Usage in Interpretation Loop
**File**: `src/evm/evm/interpret.zig:62-74`
- Frame initialization with all required components
- Main execution loop consumes gas and manages state
- Error handling and result generation

**Critical Lines**:
- Line 148: `nextInstruction.opcode_fn(@ptrCast(&frame))` - Frame passed to all opcodes
- Lines 117-144: Jump destination validation using `frame.valid_jumpdest()`
- Lines 194-198: Gas consumption using `frame.consume_gas()`

### Opcode Executor Usage

All opcode executors in `src/evm/execution/` take `*ExecutionContext` as their primary parameter:

#### Arithmetic Operations (`src/evm/execution/arithmetic.zig`)
- **Pattern**: All functions take `context: *ExecutionContext`
- **Stack Access**: `context.stack.pop()`, `context.stack.append()`
- **Gas**: Managed by jump table, but context tracks remaining gas

#### Stack Operations (`src/evm/execution/stack.zig`)
- **Line 15**: `op_pop(context: *ExecutionContext)`
- **Line 19**: `op_push0(context: *ExecutionContext)` - checks `context.flags.is_eip3855` (planned)
- **Usage**: Direct stack manipulation through context

#### Memory Operations (`src/evm/execution/memory.zig`)
- **Memory Access**: Through `context.memory` pointer
- **Gas Costs**: Memory expansion gas calculated and consumed
- **Opcodes**: MLOAD, MSTORE, MSIZE, MCOPY (checks `context.flags.is_eip5656` - planned)

#### Storage Operations (`src/evm/execution/storage.zig`)
- **Storage Access**: `context.get_storage()`, `context.set_storage()`
- **Access List**: `context.mark_storage_slot_warm()` for EIP-2929
- **Static Checks**: `context.flags.is_static` for SSTORE, TSTORE
- **Opcodes**: SLOAD, SSTORE, TLOAD/TSTORE (check `context.flags.is_eip1153` - planned)

#### Control Flow (`src/evm/execution/control.zig`)
- **Jump Validation**: `context.valid_jumpdest()` for JUMP/JUMPI
- **Gas Consumption**: `context.consume_gas()` for all operations
- **Opcodes**: JUMP, JUMPI, PC, STOP

#### Environment Operations (`src/evm/execution/environment.zig`)
- **Contract Data**: `context.contract_address` for ADDRESS opcode
- **Calldata Access**: `context.input` for CALLDATALOAD, CALLDATASIZE, CALLDATACOPY
- **State Access**: Through `context.state` interface
- **Opcodes**: ADDRESS, BALANCE, ORIGIN, CALLER, CALLDATALOAD, CALLDATASIZE, CALLDATACOPY

#### System Operations (`src/evm/execution/system.zig`)
- **Complex State**: Uses multiple context fields for CALL/CREATE operations
- **Access Lists**: Manages warm/cold access costs
- **Output**: Sets `context.output` for RETURN/REVERT

#### Cryptographic Operations (`src/evm/execution/crypto.zig`)
- **Memory**: Accesses memory through `context.memory`
- **Stack**: Input/output through context stack
- **Opcodes**: KECCAK256

#### Logging Operations (`src/evm/execution/log.zig`)
- **Event Emission**: `context.emit_log()` (TODO: integration pending)
- **Memory Access**: For log data extraction
- **Opcodes**: LOG0, LOG1, LOG2, LOG3, LOG4

#### Block Information (`src/evm/execution/block.zig`)
- **Environment**: Block-related data through context
- **EIP Checks**: BASEFEE checks `context.flags.is_eip3198` (planned)
- **Address Warming**: COINBASE uses `context.flags.is_eip3651` for warming (planned)
- **Opcodes**: BLOCKHASH, COINBASE, TIMESTAMP, NUMBER, BASEFEE, etc.

### Legacy Frame Support

**Files**: `src/evm/frame/` directory
- Contains older Frame implementation for compatibility
- Being phased out in favor of ExecutionContext
- Some components still reference the legacy Frame type

### Jump Table Integration

**File**: `src/evm/jump_table/jump_table.zig`
- ExecutionContext passed to all opcode function pointers
- Function signature: `fn(*ExecutionContext) ExecutionError.Error!void`

## Initialization Pattern

```zig
// Typical Frame initialization (from interpret.zig:62-73)
var frame = try Frame.init(
    self.arena_allocator(),           // Allocator for memory
    contract.gas,                     // Initial gas
    is_static,                        // Static call flag
    @as(u32, @intCast(self.depth)),  // Call depth
    contract.address,                 // Contract address
    &analysis,                        // Code analysis
    &access_list,                     // EIP-2929 access tracking
    self.state,                       // Database interface
    chain_rules,                      // Hardfork configuration
    &self_destruct,                   // Self-destruct tracking
    contract.input,                   // Calldata input
);
defer frame.deinit();                 // Cleanup memory
```

## Memory Management

### Allocation Strategy
- **Stack**: Fixed-size array, no allocation needed
- **Memory**: Dynamic allocation through `Memory.init_default()`
- **Analysis**: Pre-computed, shared across execution
- **Access List**: Allocated per execution, tracks warm/cold access
- **Self Destruct**: Optional allocation for destruction tracking

### Cleanup Requirements
- **MUST** call `frame.deinit()` to free memory allocation
- **Memory**: Automatically freed by deinit
- **Other pointers**: Managed by caller (analysis, access_list, etc.)

## Performance Characteristics

### Cache Optimization
- **Hot data first**: Stack and gas at beginning of struct
- **Packed flags**: All hardfork booleans in single 64-bit word
- **Pointer grouping**: Related pointers grouped together

### Memory Usage
- **Total size**: ~33.6 KB per frame (dominated by stack)
- **Stack**: 33,536 bytes (1024 × 32 bytes + metadata)
- **Memory**: Variable size, grows as needed during execution
- **Input/Output**: Variable size slices (16 bytes each for slice headers)
- **Fixed overhead**: ~220 bytes for struct fields and pointers

### Access Patterns
- **Stack**: Accessed every opcode (~1000s of times per execution)
- **Gas**: Checked every opcode for consumption
- **EIP flags (planned)**: Checked by specific opcodes during validation
  - `is_eip3855`: PUSH0 opcode validation 
  - `is_eip5656`: MCOPY opcode validation
  - `is_eip1153`: TLOAD/TSTORE opcode validation
  - `is_eip3198`: BASEFEE opcode validation
  - `is_eip3651`: COINBASE address warming
- **Memory**: Hot during memory-intensive operations
- **Storage**: Medium frequency, depends on contract logic
- **Static flag**: Checked by state-changing opcodes (SSTORE, TSTORE, etc.)
- **Output**: Cold, only set at function exit

## Testing

Comprehensive test suite in `execution_context.zig` covering:
- Basic initialization and state management
- Gas consumption and bounds checking  
- Jump destination validation
- Address access tracking (EIP-2929)
- Output data management
- Static call restrictions
- Self-destruct availability
- Memory footprint optimization

All tests follow the no-abstraction philosophy with inline setup and direct assertions.

## Future Enhancements

### TODOs in Current Implementation
1. **Gas Refunds**: `add_gas_refund()` needs integration with refund tracking system
2. **Log Emission**: `emit_log()` needs integration with VM logging system
3. **EIP Flag Validation**: Add hardfork checks to opcodes:
   - PUSH0: `context.flags.is_eip3855` validation
   - MCOPY: `context.flags.is_eip5656` validation  
   - TLOAD/TSTORE: `context.flags.is_eip1153` validation
   - BASEFEE: `context.flags.is_eip3198` validation
   - COINBASE: `context.flags.is_eip3651` address warming
4. **Hardfork Detection**: More sophisticated hardfork feature detection

### Planned Optimizations
1. **Memory Layout**: Further optimize field ordering for cache performance
2. **Reduced Allocations**: Investigate stack-based alternatives for dynamic components
3. **SIMD Operations**: Leverage vector instructions for stack operations where possible

This ExecutionContext serves as the foundation for all EVM execution in Guillotine, providing a clean, performant, and well-tested interface for opcode implementations while maintaining strict adherence to EVM semantics and gas accounting rules.