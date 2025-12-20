# Primitives

Fundamental Ethereum types, constants, and utilities that form the building blocks for all Ethereum operations in Guillotine.

## Overview

The primitives module provides the core data types, encoding utilities, cryptographic operations, and fundamental constants needed for Ethereum development. It serves as the foundation layer that all other Guillotine components build upon, ensuring type safety, standard compliance, and optimal performance across the entire system.

## Components and Architecture

### Core Types
- **`address.zig`** - Ethereum address utilities with checksum validation and contract address generation
- **`numeric.zig`** - Big integer arithmetic and number format conversions
- **`uint.zig`** - High-performance arbitrary-precision unsigned integer implementation
- **`state.zig`** - Account state definitions and storage key management
- **`gas_constants.zig`** - Comprehensive EVM gas cost constants and calculations

### Encoding & Serialization
- **`hex.zig`** - Hexadecimal encoding/decoding with comprehensive validation
- **`rlp.zig`** - Recursive Length Prefix (RLP) encoding for Ethereum data structures
- **`abi.zig`** - Application Binary Interface type definitions
- **`abi_encoding.zig`** - High-level ABI encoding and decoding utilities

### Transaction Support
- **`transaction.zig`** - All Ethereum transaction types (Legacy, EIP-1559, EIP-4844)
- **`access_list.zig`** - EIP-2930 access list implementation for gas optimization
- **`authorization.zig`** - EIP-7702 authorization lists for EOA code delegation
- **`blob.zig`** - EIP-4844 blob transaction data structures and KZG commitments
- **`fee_market.zig`** - EIP-1559 fee market calculations and base fee management

### Ethereum Standards
- **`event_log.zig`** - Contract event log structures and topic handling
- **`siwe.zig`** - Sign-In with Ethereum (EIP-4361) message parsing and validation

### Utilities
- **`logs.zig`** - Logging configuration and structured output
- **`root.zig`** - Module exports and common type aliases

## Key Features

### Type Safety
- **Strong Typing**: Prevents common bugs through compile-time type checking
- **Zero-Cost Abstractions**: Performance equivalent to manual implementations
- **Memory Safety**: Careful ownership semantics and allocation patterns
- **Overflow Protection**: Safe arithmetic operations with explicit overflow handling

### Standard Compliance
- **EIP Compatibility**: Full support for all relevant Ethereum Improvement Proposals
- **Specification Adherence**: Strict compliance with Ethereum Yellow Paper and EIPs
- **Test Vector Validation**: Extensive testing against official Ethereum test vectors
- **Cross-Client Compatibility**: Interoperability with other Ethereum implementations

### Performance Optimization
- **Minimal Allocations**: Designed to minimize heap allocations in critical paths
- **Cache-Friendly Layouts**: Struct organization optimized for CPU cache performance
- **Vectorized Operations**: SIMD-optimized arithmetic where applicable
- **Compile-Time Computation**: Maximum use of comptime for constant folding

## Integration Points

### EVM Core
- **Opcode Implementation**: Provides data types for all EVM operations
- **State Management**: Account and storage representations for world state
- **Gas Accounting**: Comprehensive gas cost calculations and tracking
- **Address Resolution**: Contract address computation and validation

### Network Layer
- **Transaction Processing**: Complete transaction lifecycle support
- **Block Structure**: Block header and body data representations  
- **Consensus Integration**: Data types for proof-of-stake consensus
- **P2P Communication**: Serialization for network protocol messages

### Database Interface
- **Storage Primitives**: Efficient key-value representations
- **State Serialization**: RLP encoding for persistent storage
- **Merkle Tree Integration**: Hash computation and tree node structures
- **Migration Support**: Version-aware data structure evolution

## Usage Examples

### Address Operations
```zig
const primitives = @import("primitives");

// Create address from hex string with validation
const addr = try primitives.Address.from_hex("0x742d35Cc6641C91B6E4bb6ac...");

// Generate contract address (CREATE)
const contract_addr = primitives.Address.get_contract_address(deployer_addr, nonce);

// Generate contract address (CREATE2)  
const create2_addr = primitives.Address.get_create2_address(
    deployer_addr, salt, bytecode_hash
);

// Validate checksum
const is_valid = primitives.Address.is_valid_checksum("0x742d35Cc6641C91B6E4bb6ac...");
```

### Transaction Handling
```zig
// Create EIP-1559 transaction
const tx = primitives.Transaction.Eip1559Transaction{
    .chain_id = 1,
    .nonce = 42,
    .max_fee_per_gas = 20_000_000_000, // 20 gwei
    .max_priority_fee_per_gas = 1_000_000_000, // 1 gwei
    .gas_limit = 21_000,
    .to = recipient_address,
    .value = primitives.Uint(256).from_int(1000000000000000000), // 1 ETH
    .data = &[_]u8{},
    .access_list = &[_]primitives.AccessList.AccessListEntry{},
};

// Calculate transaction hash
const tx_hash = try tx.hash(allocator);
defer allocator.free(tx_hash);
```

### 256-bit Integers
```zig
// Work with 256-bit integers
const a = primitives.Uint(256).from_hex("0x1234567890abcdef...") catch unreachable;
const b = primitives.Uint(256).from_int(42);
const sum = a.add(b);
const product = a.mul(b);
```

### Data Encoding
```zig
// RLP encode a transaction
const encoded = try primitives.Rlp.encode(allocator, transaction);
defer allocator.free(encoded);

// Decode RLP data
const decoded = try primitives.Rlp.decode(allocator, encoded_data);
defer decoded.deinit(allocator);

// Hex encode bytes with 0x prefix
const hex_string = try primitives.Hex.encode(allocator, bytes, .with_prefix);
defer allocator.free(hex_string);

// Decode hex string
const decoded_bytes = try primitives.Hex.decode(allocator, "0x1234abcd");
defer allocator.free(decoded_bytes);
```

### ABI Encoding
```zig
// Encode function call
const function_sig = "transfer(address,uint256)";
const params = .{ recipient_address, amount };
const encoded_call = try primitives.AbiEncoding.encode_function_call(
    allocator, function_sig, params
);
defer allocator.free(encoded_call);

// Decode event log
const event_sig = "Transfer(address indexed,address indexed,uint256)";
const decoded_event = try primitives.AbiEncoding.decode_event(
    allocator, event_sig, log_data, log_topics
);
defer decoded_event.deinit(allocator);
```

### Gas Constants
`primitives.GasConstants` exposes the standard EVM gas constants (e.g., `GasFastestStep`, `SloadGas`, `ColdAccountAccessCost`).

## Design Principles

### Minimal Dependencies
The primitives module minimizes external dependencies to ensure:
- **Fast Compilation**: Reduced dependency tree for quicker builds
- **Security**: Smaller attack surface with fewer third-party components
- **Portability**: Easy integration into different environments and platforms

### Memory Management
- **Explicit Ownership**: Clear allocation and deallocation responsibilities
- **RAII Patterns**: Automatic cleanup using defer and errdefer
- **Arena Allocation**: Support for efficient bulk memory management
- **Zero-Copy Operations**: Minimize memory copies in hot paths

### Error Handling
- **Comprehensive Error Types**: Specific error types for different failure modes
- **Error Propagation**: Consistent error handling patterns throughout
- **Recovery Strategies**: Graceful degradation and error recovery where possible
- **Debug Information**: Detailed error context for development and debugging

## Testing Strategy

The primitives module includes extensive test coverage:

### Unit Tests
- **Type Operations**: All arithmetic and comparison operations
- **Encoding/Decoding**: Round-trip testing for all serialization formats
- **Edge Cases**: Boundary conditions and overflow scenarios
- **Error Conditions**: Comprehensive error handling validation

### Property-Based Testing
- **Invariant Checking**: Mathematical properties and consistency rules
- **Fuzz Testing**: Random input validation for robustness
- **Equivalence Testing**: Comparison with reference implementations
- **Performance Benchmarking**: Performance regression detection

### Integration Tests
- **Cross-Module Testing**: Interaction with other Guillotine components
- **Standard Compliance**: Validation against official Ethereum test vectors
- **Compatibility Testing**: Interoperability with other Ethereum tools
- **Regression Testing**: Prevention of functionality breakage

## Performance Characteristics

### Computational Complexity
- **Address Operations**: O(1) for most operations, O(n) for checksum validation
- **Big Integer Arithmetic**: Optimized algorithms with minimal memory allocation
- **Encoding/Decoding**: Linear complexity with input size, minimal copying
- **Hash Operations**: Hardware-accelerated where available

### Memory Usage
- **Stack Allocation**: Preferred for small, fixed-size data
- **Heap Allocation**: Minimized and tracked with clear ownership
- **Memory Pools**: Support for custom allocators and memory pools
- **Garbage Collection**: Zero-GC design for predictable performance

### Optimization Features
- **Compile-Time Evaluation**: Maximum use of comptime for constants
- **SIMD Operations**: Vectorized arithmetic for large integers
- **Cache Optimization**: Data layout optimized for cache performance
- **Branch Prediction**: Minimal branching in hot paths

This primitives module provides the solid foundation needed for building a high-performance, standards-compliant Ethereum implementation while maintaining code clarity and safety.
