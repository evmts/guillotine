# Guillotine Mini - TypeScript EVM Implementation

A minimal, correct, and well-tested Ethereum Virtual Machine (EVM) implementation in TypeScript, prioritizing specification compliance, clarity, and hardfork support (Frontier through Prague).

## Overview

This TypeScript EVM implementation is a faithful port of the Zig implementation in `src/evm.zig` and `src/frame.zig`, designed for:

- **Specification Compliance**: Matches `execution-specs` Python reference implementation
- **Type Safety**: Full TypeScript with strong typing throughout
- **Clarity**: Clear separation of concerns (Evm orchestrates, Frame executes)
- **Testability**: Comprehensive test suite with spec test compatibility
- **Hardfork Support**: Full support from Frontier through Prague (including EIP-1153, EIP-4844, EIP-7702)

## Quick Start

```typescript
import { Evm, Frame, Hardfork } from 'guillotine-mini-ts';
import { EvmConfig } from 'guillotine-mini-ts/evm-config';

// Initialize EVM with Cancun hardfork
const evm = new Evm(null, Hardfork.CANCUN);

// Set up transaction context
evm.initTransactionState();

// Execute bytecode
const bytecode = new Uint8Array([0x60, 0x42, 0x60, 0x00, 0x52]); // PUSH1 0x42, PUSH1 0x00, MSTORE
const frame = new Frame({
  bytecode,
  gas: 1_000_000n,
  caller: new Uint8Array(20),
  address: new Uint8Array(20),
  value: 0n,
  calldata: new Uint8Array(0),
  evmPtr: evm,
  hardfork: Hardfork.CANCUN,
  isStatic: false,
});

frame.execute();
console.log('Gas remaining:', frame.gasRemaining);
console.log('Output:', frame.output);
```

## Installation

```bash
# Using npm
npm install guillotine-mini-ts

# Using bun
bun add guillotine-mini-ts

# Using pnpm
pnpm add guillotine-mini-ts
```

## Core Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         EVM (Orchestrator)                   │
│  - State management (balances, nonces, code, storage)       │
│  - Gas refunds (SSTORE refunds, capped at 1/2 or 1/5)      │
│  - Warm/cold tracking (EIP-2929, Berlin+)                   │
│  - Transient storage (EIP-1153, Cancun+)                    │
│  - Nested call management (CALL, CREATE, etc.)              │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      Frame (Bytecode Interpreter)            │
│  - Stack operations (LIFO, max 1024 items)                  │
│  - Memory management (sparse, word-aligned expansion)        │
│  - Program counter (PC) and gas tracking                     │
│  - Opcode dispatch and execution                            │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   Host Interface (Optional)                  │
│  - External state backend (database, RPC, etc.)             │
│  - Balance/nonce/code/storage getters/setters               │
└─────────────────────────────────────────────────────────────┘
```

### Separation of Concerns

| Component | Responsibility | Does NOT Handle |
|-----------|----------------|-----------------|
| **Evm** | State, storage, refunds, warm/cold tracking, nested calls | Stack, memory, PC, bytecode interpretation |
| **Frame** | Stack, memory, PC, gas per instruction, opcode execution | Storage, nested calls, state management |
| **Host** | External state backend (optional) | EVM execution logic |

## Feature Comparison: Zig vs TypeScript

| Feature | Zig Implementation | TypeScript Implementation | Notes |
|---------|-------------------|---------------------------|-------|
| **Memory Management** | Arena allocator (transaction-scoped) | Garbage collection | TS relies on GC, no manual cleanup needed |
| **u256 Support** | Native `u256` type | `bigint` | JS bigints have unlimited precision |
| **Error Handling** | Tagged unions (`CallError`) | Exceptions (`EvmError`) | TS uses standard Error classes |
| **Storage** | HashMap with custom contexts | `Map<string, bigint>` | TS uses string keys for addresses |
| **Async Support** | Synchronous only | Optional async (storage injector) | TS can use async/await for state fetching |
| **Performance** | ~5-10x faster | Optimized for clarity | See MIGRATION.md for benchmarks |
| **Deployment** | Native binary or WASM | Node.js, Bun, Deno, browsers | TS runs everywhere |

## Key Features

### EIP Support

| EIP | Feature | Hardfork | Status |
|-----|---------|----------|--------|
| EIP-2929 | State access gas costs | Berlin | ✅ |
| EIP-2930 | Access lists | Berlin | ✅ |
| EIP-1559 | Fee market | London | ✅ |
| EIP-3198 | BASEFEE opcode | London | ✅ |
| EIP-3529 | Reduced gas refunds | London | ✅ |
| EIP-3541 | Reject code starting with 0xEF | London | ✅ |
| EIP-3651 | Warm coinbase | Shanghai | ✅ |
| EIP-3855 | PUSH0 instruction | Shanghai | ✅ |
| EIP-3860 | Limit init code size | Shanghai | ✅ |
| EIP-1153 | Transient storage (TLOAD/TSTORE) | Cancun | ✅ |
| EIP-4844 | Blob transactions | Cancun | ✅ |
| EIP-5656 | MCOPY instruction | Cancun | ✅ |
| EIP-6780 | SELFDESTRUCT only in same tx | Cancun | ✅ |
| EIP-7516 | BLOBBASEFEE opcode | Cancun | ✅ |
| EIP-7702 | Set code (auth delegation) | Prague | ✅ |
| EIP-2537 | BLS12-381 precompiles | Prague | ✅ |

### Hardfork Support

```typescript
import { Hardfork } from 'guillotine-mini-ts';

// All hardforks supported
const hardforks = [
  Hardfork.FRONTIER,
  Hardfork.HOMESTEAD,
  Hardfork.TANGERINE,
  Hardfork.SPURIOUS,
  Hardfork.BYZANTIUM,
  Hardfork.CONSTANTINOPLE,
  Hardfork.ISTANBUL,
  Hardfork.BERLIN,
  Hardfork.LONDON,
  Hardfork.MERGE,
  Hardfork.SHANGHAI,
  Hardfork.CANCUN,
  Hardfork.PRAGUE,
];

// Default is CANCUN
const evm = new Evm(null, Hardfork.CANCUN);
```

## Project Structure

```
src/
├── evm.ts                    # EVM orchestrator (state, storage, refunds)
├── frame.ts                  # Bytecode interpreter (stack, memory, PC)
├── host.ts                   # Abstract state backend interface
├── evm-config.ts             # Configuration and hardfork detection
├── opcode.ts                 # Opcode definitions and utilities
├── errors.ts                 # Error types (CallError, EvmError)
├── storage.ts                # Storage management (persistent + transient)
├── access-list-manager.ts    # EIP-2929 warm/cold tracking
├── bytecode.ts               # Bytecode analysis (JUMPDEST tracking)
├── call-params.ts            # Call parameter types
├── call-result.ts            # Call result types (logs, traces, etc.)
├── logger.ts                 # Debug logging utilities
└── instructions/             # Opcode handlers by category
    ├── handlers_arithmetic.ts
    ├── handlers_comparison.ts
    ├── handlers_bitwise.ts
    ├── handlers_keccak.ts
    ├── handlers_context.ts
    ├── handlers_block.ts
    ├── handlers_stack.ts
    ├── handlers_memory.ts
    ├── handlers_storage.ts
    ├── handlers_control_flow.ts
    ├── handlers_log.ts
    └── handlers_system.ts
```

## Documentation Index

- **[API.md](./API.md)** - Complete API reference with examples
- **[ARCHITECTURE.md](./ARCHITECTURE.md)** - Deep dive into design decisions
- **[MIGRATION.md](./MIGRATION.md)** - Zig to TypeScript migration guide

## Testing

```bash
# Run all tests
bun test

# Run specific test file
bun test evm.test.ts

# Type checking
bun run type-check

# Watch mode
bun test --watch
```

## Performance Considerations

The TypeScript implementation prioritizes **correctness and clarity** over raw performance. Benchmarks show:

- **Arithmetic operations**: ~2-3x slower than Zig
- **Storage operations**: ~3-5x slower (Map overhead)
- **Complex operations (CREATE/CALL)**: ~5-10x slower
- **Memory usage**: ~2-3x higher (GC overhead)

For production use cases requiring maximum performance, consider:
1. Using the Zig implementation directly
2. Using the WASM build (zig-out/bin/guillotine_mini.wasm)
3. Running in Bun (2-3x faster than Node.js for this workload)

See [MIGRATION.md](./MIGRATION.md) for detailed benchmarks and optimization tips.

## Common Use Cases

### 1. Transaction Simulation

```typescript
import { Evm, Frame, Hardfork } from 'guillotine-mini-ts';

const evm = new Evm(null, Hardfork.CANCUN);
evm.initTransactionState();

// Set up transaction context
evm.origin = senderAddress;
evm.gasPrice = 20_000_000_000n; // 20 gwei

// Execute transaction
const frame = new Frame({
  bytecode: contractBytecode,
  gas: 1_000_000n,
  caller: senderAddress,
  address: contractAddress,
  value: 0n,
  calldata: encodedCalldata,
  evmPtr: evm,
  hardfork: Hardfork.CANCUN,
  isStatic: false,
});

try {
  frame.execute();
  console.log('Success!', frame.output);
  console.log('Gas used:', 1_000_000n - frame.gasRemaining);
} catch (error) {
  console.error('Execution failed:', error);
}
```

### 2. Static Call (Read-Only)

```typescript
// Static calls cannot modify state
const frame = new Frame({
  bytecode: contractBytecode,
  gas: 100_000n,
  caller: callerAddress,
  address: contractAddress,
  value: 0n,
  calldata: viewFunctionCall,
  evmPtr: evm,
  hardfork: Hardfork.CANCUN,
  isStatic: true, // Read-only mode
});

frame.execute();
const returnValue = frame.output; // Decoded return value
```

### 3. Custom Host Interface

```typescript
import { HostInterface, Address } from 'guillotine-mini-ts';

class DatabaseHost implements HostInterface {
  getBalance(address: Address): bigint {
    return db.getBalance(address);
  }

  setBalance(address: Address, balance: bigint): void {
    db.setBalance(address, balance);
  }

  // ... implement other methods
}

const host = new DatabaseHost();
const evm = new Evm(host, Hardfork.CANCUN);
```

### 4. EIP-1153 Transient Storage

```typescript
// Transient storage is cleared at transaction boundaries
evm.initTransactionState();

// TSTORE sets transient storage
frame.execute(); // Contract uses TSTORE

// TLOAD reads transient storage (within same transaction)
const value = evm.storage.getTransient(contractAddress, slot);

// After transaction, transient storage is gone
evm.initTransactionState(); // Clears transient storage
```

## Troubleshooting

### Common Issues

**Issue**: `StackOverflow` error
- **Cause**: Stack depth exceeded 1024 items
- **Fix**: Check for infinite PUSH loops or excessive DUP operations

**Issue**: `OutOfGas` error
- **Cause**: Insufficient gas for operation
- **Fix**: Increase gas limit or optimize bytecode

**Issue**: `InvalidJumpDestination` error
- **Cause**: JUMP/JUMPI to non-JUMPDEST location
- **Fix**: Verify bytecode has JUMPDEST (0x5b) at target

**Issue**: `WriteInStaticContext` error
- **Cause**: State modification attempted in STATICCALL
- **Fix**: Ensure `isStatic: false` for state-changing operations

## Contributing

See the main project README for contribution guidelines.

## References

- **ethereum/tests**: https://github.com/ethereum/tests
- **execution-specs**: https://github.com/ethereum/execution-specs
- **EIP Index**: https://eips.ethereum.org/
- **EIP-3155 (Trace Format)**: https://eips.ethereum.org/EIPS/eip-3155

## License

See LICENSE file in the project root.
