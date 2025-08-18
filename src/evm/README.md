# Guillotine EVM Architecture

Core Ethereum Virtual Machine implementation for Guillotine.

## Overview

Guillotine implements a high-performance Ethereum Virtual Machine (EVM) in Zig with three distinct interpreters, each serving different purposes in the evolution of the codebase. The primary interpreter (`interpret2.zig`) uses an innovative recursive tailcall dispatch mechanism for optimal performance.

## Architecture Layers

### 1. Core EVM (`evm.zig`)
The main VM instance that orchestrates execution:
- Manages blockchain state through `DatabaseInterface`
- Handles transaction context and gas accounting
- Coordinates frame stack for nested calls
- Integrates with precompiled contracts
- Manages access lists (EIP-2929) and self-destruct operations (EIP-6780)

### 2. Interpreters

#### Primary: `interpret2.zig` (Tailcall Dispatch)
The production interpreter using recursive tailcall optimization:
- **Preprocessing Phase**: Analyzes bytecode using `SimpleAnalysis` from `analysis2.zig`
- **Compilation Phase**: Converts opcodes to function pointers for direct dispatch
- **Fusion Optimization**: Detects and fuses common patterns (PUSH+operation sequences)
- **Execution Phase**: Recursive tailcalls through operation handlers with zero overhead

#### Legacy: `interpreter.zig` 
The original jump-table based interpreter (being phased out):
- Traditional switch-based opcode dispatch
- Used as reference implementation
- Simpler but less performant architecture

#### Minimal: `mini_evm.zig`
Lightweight interpreter for testing and specific use cases:
- Simplified execution model
- Minimal dependencies
- Used for isolated testing scenarios

### 3. Execution Frame (`frame.zig`)
The execution context for EVM operations:
```zig
Frame = {
    gas_remaining: u64,        // Gas tracking
    stack: Stack,              // 1024-element operand stack
    memory: Memory,            // Byte-addressable memory
    host: Host,                // External interface
    state: DatabaseInterface,  // Storage access
    contract_address: Address, // Current contract
    analysis: *CodeAnalysis,   // Bytecode analysis cache
    // ... additional context fields
}
```

### 4. Host Interface (`host.zig`)
Abstraction layer between EVM and external world:
- **Account Operations**: Balance, code, existence checks
- **Block Information**: Number, timestamp, gas limit, etc.
- **State Management**: Storage access, journaling, snapshots
- **Call Execution**: Nested calls, contract creation
- **Event Emission**: LOG0-LOG4 operations

### 5. Bytecode Analysis (`analysis.zig`, `analysis2.zig`)

#### Standard Analysis (`analysis.zig`)
Comprehensive bytecode analysis for the legacy interpreter:
- Jump destination validation
- Basic block detection
- Stack depth tracking
- Gas cost pre-calculation

#### Simple Analysis (`analysis2.zig`)
Streamlined analysis for tailcall interpreter:
- PC to instruction index mapping
- Metadata extraction for opcodes
- Minimal overhead design

### 6. Tailcall System (`evm/evm/tailcalls.zig`)

The heart of the performance optimization:
```zig
// Each opcode is a tail-recursive function
pub fn op_add(frame: *anyopaque, analysis: *const SimpleAnalysis, 
              metadata: [*]const u32, ops: [*]const *const anyopaque, 
              ip: *usize) Error!noreturn {
    // Execute operation
    execution.arithmetic.op_add(frame);
    // Tail call to next instruction
    return next(frame, analysis, metadata, ops, ip);
}
```

Key optimizations:
- **Fusion Operations**: `op_push_then_add`, `op_push_then_jump`, etc.
- **Direct Dispatch**: No switch statements or jump tables
- **Zero-Cost Abstraction**: Compiles to optimal machine code

### 7. Operation Executors (`execution/`)

Modular opcode implementations organized by category:
- `arithmetic.zig`: ADD, SUB, MUL, DIV, MOD, EXP, etc.
- `bitwise.zig`: AND, OR, XOR, SHL, SHR, SAR
- `comparison.zig`: LT, GT, EQ, ISZERO
- `memory.zig`: MLOAD, MSTORE, MSIZE, MCOPY
- `storage.zig`: SLOAD, SSTORE, TLOAD, TSTORE
- `stack.zig`: PUSH, POP, DUP, SWAP operations
- `control.zig`: JUMP, JUMPI, PC, STOP, REVERT
- `system.zig`: CALL, CREATE, DELEGATECALL, STATICCALL
- `environment.zig`: ADDRESS, BALANCE, CALLER, CALLVALUE
- `block.zig`: BLOCKHASH, TIMESTAMP, NUMBER, GASLIMIT
- `crypto.zig`: KECCAK256
- `log.zig`: LOG0-LOG4

### 8. EVM Entry Point (`evm/evm/call2.zig`)

The bridge between external calls and the interpreter:
1. **Parameter Extraction**: Unpacks `CallParams` union
2. **Validation**: Checks depth limits, input sizes
3. **Precompile Detection**: Routes to precompiled contracts if applicable
4. **Frame Setup**: Initializes execution context
5. **Interpreter Invocation**: Calls `interpret2` with prepared frame
6. **Result Handling**: Maps execution errors to `CallResult`

## Execution Flow

### Standard Call Flow
```
Evm.call() 
  → call2() [entry point]
    → Create Host interface
    → Setup Frame with context
    → interpret2() [main interpreter]
      → SimpleAnalysis.analyze() [bytecode preprocessing]
      → Build tailcall dispatch table
      → Apply fusion optimizations
      → Execute first operation (recursive tailcalls)
        → op_xxx() calls continue until STOP/RETURN/REVERT
    → Return CallResult
```

### Nested Call Flow (CALL/DELEGATECALL/STATICCALL)
```
op_call() [in tailcalls.zig]
  → execution.system.op_call() [executor]
    → Prepare CallParams
    → frame.host.call() [host interface]
      → Evm.call() [recursive entry]
        → call2() [new frame created]
          → ... nested execution ...
    → Handle result and gas accounting
  → Continue to next operation
```

### Contract Creation Flow (CREATE/CREATE2)
```
op_create() [in tailcalls.zig]
  → execution.system.op_create() [executor]
    → Validate and prepare init code
    → frame.host.call(CallParams.create)
      → Evm.create_contract() [special handling]
        → Deploy init code
        → Execute constructor
        → Store runtime code
    → Return created address
```

## Memory Model

### Stack
- 1024 elements maximum (EVM specification)
- 256-bit values
- 32KB pre-allocated for performance
- Located in `stack/stack.zig`

### Memory
- Byte-addressable, word-aligned operations
- Dynamic expansion with gas charging
- Initial 4KB capacity, doubles on demand
- Implementation in `memory/memory.zig`

### Storage
- 256-bit key-value pairs per contract
- Warm/cold access tracking (EIP-2929)
- Original value tracking for gas refunds
- Managed through `state/database_interface.zig`

### Transient Storage (EIP-1153)
- Transaction-scoped storage
- Cleared after transaction
- Uses same key-value model as persistent storage

## Gas Management

### Static Gas
Pre-calculated during analysis phase:
- Fixed costs per opcode
- Known memory expansion costs
- Predictable control flow costs

### Dynamic Gas
Calculated during execution:
- Memory expansion beyond initial analysis
- Storage operations (SSTORE gas varies by value)
- Call operations (63/64 rule, stipends)
- Precompile-specific costs

### Precompiled Contracts (`precompiles/`)

Built-in contracts at specific addresses:
- `ecrecover.zig` (0x01) - Signature recovery
- `sha256.zig` (0x02) - SHA256 hash
- `ripemd160.zig` (0x03) - RIPEMD160 hash
- `identity.zig` (0x04) - Data copy
- `modexp.zig` (0x05) - Modular exponentiation
- `ecadd.zig` (0x06) - BN254 curve addition
- `ecmul.zig` (0x07) - BN254 curve multiplication
- `ecpairing.zig` (0x08) - BN254 pairing check
- `blake2f.zig` (0x09) - Blake2 compression
- `kzg_point_evaluation.zig` (0x0a) - KZG commitment verification

## Hardfork Support

The EVM adapts behavior based on configured hardfork:
- **Frontier**: Original EVM rules
- **Tangerine Whistle**: EIP-150 gas changes
- **Spurious Dragon**: EIP-161 state clearing
- **Byzantium**: EIP-140 REVERT, EIP-196 precompiles
- **Constantinople**: EIP-145 bitwise operations
- **Istanbul**: EIP-152 BLAKE2, EIP-1344 CHAINID
- **Berlin**: EIP-2929 gas cost changes
- **London**: EIP-1559 base fee, EIP-3529 refund reduction
- **Shanghai**: EIP-3855 PUSH0, EIP-3860 initcode limit
- **Cancun**: EIP-1153 transient storage, EIP-6780 SELFDESTRUCT changes

## Performance Optimizations

### Tailcall Dispatch
- Zero-overhead operation chaining
- CPU branch predictor friendly
- Optimal instruction cache usage

### Operation Fusion
Detected patterns are replaced with fused operations:
- `PUSH + ADD` → `op_push_then_add`
- `PUSH + JUMP` → `op_push_then_jump`
- `PUSH + MLOAD` → `op_push_then_mload`
- `PUSH + EQ/LT/GT` → Fused comparisons
- `PUSH + SLOAD` → `op_push_then_sload`
- And many more...

### Memory Layout
- Hot fields grouped in cache lines
- Aligned data structures
- Minimal pointer indirection

### Compile-Time Optimizations
- Release builds skip safety checks
- Inlined operations
- Comptime gas calculations where possible

## State Management Components

### State Database (`state/`)
- `state.zig`: Main state implementation
- `database_interface.zig`: Abstract database interface
- `memory_database.zig`: In-memory implementation for testing
- `journal.zig`: State change tracking for reverts

### Access Lists (`access_list/`)
- EIP-2930/2929 implementation
- Warm/cold address and storage tracking
- Gas cost optimization for accessed state

### Precompiled Contracts (`precompiles/`)
Built-in contracts at specific addresses:
- `0x01`: ECRECOVER - Signature recovery
- `0x02`: SHA256 - SHA256 hash
- `0x03`: RIPEMD160 - RIPEMD160 hash
- `0x04`: IDENTITY - Data copy
- `0x05`: MODEXP - Modular exponentiation
- `0x06`: ECADD - BN254 curve addition
- `0x07`: ECMUL - BN254 curve multiplication
- `0x08`: ECPAIRING - BN254 pairing check
- `0x09`: BLAKE2F - Blake2 compression
- `0x0A`: KZG_POINT_EVAL - KZG commitment verification

## Testing Strategy

### No Abstractions in Tests
All tests are self-contained with explicit setup:
- No helper functions
- Direct setup and assertions
- Copy-paste over DRY for clarity

### Test Organization
- Unit tests colocated with implementation
- Integration tests in `test/evm/`
- Fuzzing for security-critical operations
- Official EVM test vectors for compliance

## Usage Example

```zig
// Create EVM instance
var evm = try Evm.init(allocator, database, chain_rules);
defer evm.deinit();

// Execute a call using interpret2
const result = try evm.call2(CallParams{
    .call = .{
        .caller = caller_address,
        .to = contract_address,
        .value = 0,
        .input = calldata,
        .gas = gas_limit,
    },
});

// Check result
if (result.success) {
    // Use result.output
} else {
    // Handle failure
}
```

## Design Principles

1. **Performance First**: Tailcall dispatch, operation fusion, pre-validation
2. **Zero Allocation Philosophy**: Allocate upfront, avoid runtime allocations
3. **Clear Error Handling**: Every operation returns typed errors
4. **Modular Boundaries**: Each component has clear interfaces
5. **Comprehensive Testing**: Unit tests colocated with implementation

## Future Improvements

### Planned Optimizations
- Super-instruction detection for complex patterns
- Profile-guided optimization
- Parallel execution for independent operations
- JIT compilation for hot paths

### Architecture Evolution
- Complete migration from legacy interpreter
- Enhanced static analysis
- Improved memory pooling
- Advanced gas metering strategies