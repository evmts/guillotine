# EVM Module

Core Ethereum Virtual Machine implementation for Guillotine.

## Architecture Overview

The EVM module implements a complete Ethereum Virtual Machine with a focus on performance, correctness, and modularity. It uses a jump table architecture for efficient opcode dispatch and careful memory management throughout.

## Core Components

### Virtual Machine (`evm.zig`)

The main VM implementation that orchestrates execution. Key features:
- Builder pattern for VM configuration
- Integration with state database
- Precompile support
- Transaction execution and validation

### Execution Context (`evm/`)

Low-level VM operations and contract interactions:
- `call_contract.zig`, `delegatecall_contract.zig`, `staticcall_contract.zig` - Contract calling conventions
- `create_contract.zig`, `create2_contract.zig` - Contract creation
- `emit_log.zig` - Event logging
- `*_protected.zig` files - Operations with additional validation for static calls

### Frame Management (`frame/`)

Execution context and call frame handling:
- `frame.zig` - Call frame implementation (stack depth, gas tracking, return data)
- `contract.zig` - Contract code and metadata
- `code_analysis.zig` - Bytecode analysis and jump destination validation
- `bitvec.zig` - Efficient bit vector for valid jump destinations
- `storage_pool.zig` - Frame memory pooling for performance

### Opcode Implementation (`execution/`)

All EVM opcodes organized by category:
- `arithmetic.zig` - ADD, SUB, MUL, DIV, MOD, EXP, etc.
- `bitwise.zig` - AND, OR, XOR, NOT, SHL, SHR, SAR
- `comparison.zig` - LT, GT, SLT, SGT, EQ, ISZERO
- `stack.zig` - PUSH, POP, DUP, SWAP operations
- `memory.zig` - MLOAD, MSTORE, MSTORE8, MSIZE
- `storage.zig` - SLOAD, SSTORE, TLOAD, TSTORE
- `control.zig` - JUMP, JUMPI, PC, STOP
- `system.zig` - CALL, CREATE, RETURN, REVERT, SELFDESTRUCT
- `environment.zig` - ADDRESS, BALANCE, ORIGIN, CALLER, etc.
- `block.zig` - BLOCKHASH, COINBASE, TIMESTAMP, NUMBER, etc.
- `crypto.zig` - KECCAK256
- `log.zig` - LOG0, LOG1, LOG2, LOG3, LOG4

### Jump Table (`jump_table/`)

Efficient opcode dispatch mechanism:
- `jump_table.zig` - Maps opcodes to implementation functions
- `operation_config.zig` - Opcode metadata (gas costs, stack effects)

### Memory Management (`memory/`)

Custom byte-addressable memory implementation:
- `memory.zig` - Main memory structure with expansion tracking
- `evm_allocator.zig` - Custom allocator for EVM memory
- `read.zig`, `write.zig` - Optimized memory operations
- Zero-initialization guarantees
- Gas cost tracking for expansion

### Stack (`stack/`)

256-bit word stack (max 1024 elements):
- `stack.zig` - Stack implementation with overflow/underflow protection
- `stack_validation.zig` - Static stack depth validation
- Optimized push/pop operations

### State Management (`state/`)

Blockchain state and account handling:
- `state.zig` - Main state implementation
- `database_interface.zig` - Abstract database interface
- `memory_database.zig` - In-memory implementation for testing
- `journal.zig` - State change tracking for reverts
- Account creation, balance transfers, storage operations

### Gas Metering (`gas/`)

Gas calculation and tracking:
- `storage_costs.zig` - Dynamic gas costs for storage operations
- Integration with all opcodes for accurate gas accounting

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

### Hard Fork Support (`hardforks/`)

Protocol upgrade handling:
- `hardfork.zig` - Fork enumeration (Frontier through Cancun)
- `chain_rules.zig` - Fork-specific validation rules

### Access Lists (`access_list/`)

EIP-2930 access list support:
- `access_list.zig` - Access list tracking
- Storage and address access optimization

### Blob Transactions (`blob/`)

EIP-4844 blob transaction support:
- `blob_types.zig` - Blob-related types
- `blob_gas_market.zig` - Blob gas pricing
- `kzg_verification.zig` - KZG proof verification

## Usage Example

```zig
const std = @import("std");
const Evm = @import("evm");

// Initialize database
var memory_db = Evm.MemoryDatabase.init(allocator);
defer memory_db.deinit();

// Create VM
const db_interface = memory_db.to_database_interface();
const config = EvmConfig.DEFAULT;
const EvmType = evm.configureEvm(config);
var vm = try EvmType.init(allocator, db_interface, null, 0, false, null);
defer vm.deinit();

// Deploy contract
const bytecode = &[_]u8{ 0x60, 0x42, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xF3 };
var contract = try Evm.Contract.init(allocator, bytecode, .{
    .address = address,
    .gas_limit = 100_000,
});
defer contract.deinit(allocator, null);

// Execute
const result = try vm.interpret(&contract, &[_]u8{});
defer if (result.output) |output| allocator.free(output);
```

## Design Principles

1. **Performance First**: Extensive use of pre-validation and unsafe operations where safe
2. **Zero Allocation Philosophy**: Allocate upfront, avoid runtime allocations
3. **Clear Error Handling**: Every operation returns typed errors
4. **Modular Boundaries**: Each component has clear interfaces
5. **Comprehensive Testing**: Unit tests colocated with implementation

## Contributing

When contributing to the EVM module:
1. Follow existing patterns for error handling and memory management
2. Add tests in the same file as your implementation
3. Ensure all opcodes handle gas correctly
4. Validate static call restrictions where applicable
5. Update hard fork rules if adding new features

## Testing

Tests are colocated with implementation files. Run all EVM tests:
```bash
zig build test
```

Integration tests are in `/test/evm/` for cross-component testing.