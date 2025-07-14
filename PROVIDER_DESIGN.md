# Provider & Primitives Design Document

This document outlines the features and APIs needed for the `primitives` and `provider` packages to achieve feature parity with viem.

## Overview

Our goal is to create a comprehensive Ethereum client library in Zig that matches viem's functionality while leveraging Zig's performance and safety features.

## Primitives Package Checklist

### Core Types
- [ ] Address type with validation
- [ ] Hash types (32-byte, transaction hash, block hash)
- [ ] Hex string type with validation
- [ ] Bytes types (fixed and dynamic)
- [ ] U256/I256 types
- [ ] Block number types (latest, pending, earliest, safe, finalized)
- [ ] Chain ID type

### Transaction Types
- [ ] Legacy transaction (pre-EIP-1559)
- [ ] EIP-1559 transaction (type 2)
- [ ] EIP-2930 transaction (type 1, access list)
- [ ] EIP-4844 blob transaction (type 3)
- [ ] EIP-7702 authorization transaction
- [ ] Transaction envelope for type routing
- [ ] Transaction receipt type
- [ ] Transaction request builder

### Block Types
- [ ] Block header
- [ ] Block with transactions
- [ ] Block with transaction hashes
- [ ] Uncle/ommer blocks

### Account Types
- [ ] EOA (Externally Owned Account)
- [ ] Contract account
- [ ] Account state (nonce, balance, code, storage)

### Event/Log Types
- [ ] Log entry
- [ ] Event filter
- [ ] Topic types
- [ ] Bloom filter

### ABI Types
- [ ] ABI parameter types
- [ ] Function selector
- [ ] Event signature
- [ ] Error types
- [ ] Tuple support

### Encoding/Decoding
- [ ] RLP encoding/decoding (already implemented)
- [ ] ABI encoding/decoding
- [ ] Packed encoding
- [ ] Event log decoding
- [ ] Function data encoding

### Hashing & Crypto
- [ ] Keccak256
- [ ] SHA256
- [ ] ECDSA signatures
- [ ] EIP-712 structured data hashing
- [ ] Message signing/recovery

### Utilities
- [ ] Unit conversions (wei, gwei, ether)
- [ ] Address utilities (checksum, validation)
- [ ] Hex/bytes conversions
- [ ] Number formatting
- [ ] String manipulation for addresses

## Provider Package Checklist

### Client Types
- [ ] Public client (read-only operations)
- [ ] Wallet client (write operations)
- [ ] Test client (for testing)
- [ ] Client configuration

### Transport Layer
- [ ] HTTP transport
- [ ] WebSocket transport
- [ ] IPC transport
- [ ] Fallback transport (multiple providers)
- [ ] Retry logic
- [ ] Request batching

### Chain Interaction
- [ ] Get chain ID
- [ ] Get block number
- [ ] Get gas price
- [ ] Get max priority fee per gas
- [ ] Get fee history
- [ ] Estimate gas
- [ ] Get transaction count (nonce)

### Block Operations
- [ ] Get block by number
- [ ] Get block by hash
- [ ] Get block transaction count
- [ ] Watch blocks
- [ ] Get uncle by block hash and index

### Transaction Operations
- [ ] Send transaction
- [ ] Send raw transaction
- [ ] Get transaction by hash
- [ ] Get transaction receipt
- [ ] Get transaction confirmation
- [ ] Wait for transaction receipt
- [ ] Replace transaction (speed up/cancel)
- [ ] Watch pending transactions

### Account Operations
- [ ] Get balance
- [ ] Get code
- [ ] Get storage at
- [ ] Get transaction count
- [ ] Get proof

### Contract Interaction
- [ ] Call contract (eth_call)
- [ ] Estimate contract gas
- [ ] Deploy contract
- [ ] Get contract bytecode
- [ ] Multicall support
- [ ] Read contract
- [ ] Write contract
- [ ] Simulate contract

### Event & Log Operations
- [ ] Get logs
- [ ] Get filter changes
- [ ] Create filter
- [ ] Watch events
- [ ] Watch contract events
- [ ] Parse event logs

### ENS Support
- [ ] Resolve ENS names
- [ ] Reverse ENS lookup
- [ ] Get ENS avatar
- [ ] Get ENS text records

### L2/Rollup Support
- [ ] L1 gas estimation for L2s
- [ ] L2-specific operations
- [ ] Optimism support
- [ ] Arbitrum support
- [ ] zkSync support

### Utilities
- [ ] Request caching
- [ ] Request deduplication
- [ ] Error handling and retries
- [ ] Request middleware
- [ ] Performance monitoring

### WebSocket Features
- [ ] Subscribe to new heads
- [ ] Subscribe to logs
- [ ] Subscribe to pending transactions
- [ ] Subscription management
- [ ] Auto-reconnection

### Advanced Features
- [ ] EIP-4337 account abstraction
- [ ] WebAuthn accounts
- [ ] Smart account support
- [ ] Batch transactions
- [ ] Permit support

## Implementation Priority

### Phase 1: Core Primitives
1. Basic types (Address, Hash, U256)
2. Transaction types
3. ABI encoding/decoding
4. Basic hashing functions

### Phase 2: Basic Provider
1. HTTP transport
2. Basic RPC methods (eth_call, eth_sendTransaction)
3. Block and transaction queries
4. Error handling

### Phase 3: Advanced Features
1. WebSocket support
2. Event watching
3. Contract interactions
4. ENS support

### Phase 4: L2 & Account Abstraction
1. L2-specific features
2. Smart accounts
3. Advanced gas estimation
4. Multicall optimizations

## Design Principles

1. **Type Safety**: Leverage Zig's type system for compile-time guarantees
2. **Performance**: Minimize allocations, use stack allocation where possible
3. **Error Handling**: Use Zig's error unions for explicit error handling
4. **Modularity**: Keep primitives separate from provider logic
5. **Testing**: Comprehensive test coverage with no abstractions
6. **Documentation**: Clear examples and API documentation

## API Examples

```zig
// Primitives usage
const addr = try Address.from_string("0x742d35Cc6634C0532925a3b844Bc9e7595f8fA82");
const value = try parseEther("1.5");
const hash = try keccak256("hello world");

// Provider usage
var client = try Provider.init(allocator, .{
    .url = "https://mainnet.infura.io/v3/YOUR-API-KEY",
    .chain_id = 1,
});
defer client.deinit();

const balance = try client.getBalance(addr);
const block = try client.getBlock(.{ .latest = {} });

// Contract interaction
const contract = Contract.init(client, contract_address, abi);
const result = try contract.read("balanceOf", .{owner_address});
```

## Next Steps

1. Review and prioritize features based on use cases
2. Design detailed APIs for each module
3. Implement core primitives first
4. Build provider on top of primitives
5. Add comprehensive tests for each feature
6. Create migration guide from viem to our library