# Guillotine TypeScript

> Experimental/PoC: This SDK is a vibecoded proof-of-concept. APIs are unstable and may change. We're looking for early users to try it and tell us what APIs you want — please open an issue or ping us on Telegram.

📚 **[View Full Documentation](https://guillotine.dev/sdks/typescript)**

## Status

- Maturity: Experimental proof‑of‑concept
- API stability: Unstable; breaking changes expected
- Feedback: https://github.com/evmts/Guillotine/issues or Telegram https://t.me/+ANThR9bHDLAwMjUx

High-performance Ethereum Virtual Machine (Evm) implementation for TypeScript/JavaScript, powered by WebAssembly.

## Features

- 🚀 **High Performance**: WebAssembly-compiled Zig implementation
- 🔒 **Type Safe**: Full TypeScript support with strict typing
- 🧩 **Modular**: Separate modules for different Evm components
- 🔄 **Async First**: Non-blocking operations with Promise-based API
- 🧪 **Well Tested**: Comprehensive test suite with real Evm execution
- 📦 **Zero Dependencies**: Only runtime dependency is the WASM module
- 🌐 **Universal**: Works in Node.js, Bun, and browsers

## Installation

```bash
npm install @evmts/guillotine
# or
yarn add @evmts/guillotine
# or
bun add @evmts/guillotine
```

### WASM Module Setup

The SDK requires a WebAssembly module compiled from the Zig implementation. The loader will automatically search for the WASM file in these locations:

1. Custom path if provided to `GuillotineEvm.create(wasmPath)`
2. `../wasm/guillotine-evm.wasm` (relative to package)
3. `../../../../zig-out/bin/guillotine-evm.wasm` (development)
4. `zig-out/bin/guillotine-evm.wasm` (project root)

For browser usage, ensure the WASM file is served at `/wasm/guillotine-evm.wasm`.

## Quick Start

```typescript
import { GuillotineEvm, Address, U256, Bytes } from '@evmts/guillotine';

// Create an Evm instance
const evm = await GuillotineEvm.create();

// Execute bytecode
const result = await evm.execute({
  bytecode: Bytes.from('0x6001600201'), // PUSH1 1, PUSH1 2, ADD
  gasLimit: 100000n,
  caller: Address.from('0x1234567890123456789012345678901234567890'),
  value: U256.zero()
});

if (result.success) {
  console.log('Gas used:', result.gasUsed);
  console.log('Return data:', result.returnData.toHex());
} else {
  console.log('Execution failed:', result.revertReason?.toString());
}

// Clean up
evm.close();
```

## Core Concepts

### Evm Instance

The main entry point for executing Evm bytecode:

```typescript
// Create Evm instance (no options currently supported)
const evm = await GuillotineEvm.create();

// Optionally specify custom WASM path
const evm = await GuillotineEvm.create('/path/to/guillotine-evm.wasm');
```

### State Management

Manage blockchain state with the built-in methods:

```typescript
// Set account balance
await evm.setBalance(
  Address.from('0x742d35Cc6634C0532925a3b844Bc9e7595f7BBDc'),
  U256.from('1000000000000000000') // 1 ETH
);

// Get account balance
const balance = await evm.getBalance(address);

// Set contract code
await evm.setCode(contractAddress, contractBytecode);

// Get contract code
const code = await evm.getCode(contractAddress);

// Set storage slot
await evm.setStorage(contractAddress, key, value);

// Get storage slot
const value = await evm.getStorage(contractAddress, key);
```

### Transaction Execution

Execute bytecode with execution parameters:

```typescript
const result = await evm.execute({
  bytecode: Bytes.from('0x6001600101'), // PUSH1 1, PUSH1 1, ADD
  caller: Address.from('0x742d35Cc6634C0532925a3b844Bc9e7595f7BBDc'),
  to: Address.from('0x1234567890123456789012345678901234567890'),
  value: U256.from('1000000000000000000'),
  input: Bytes.from('0x'),
  gasLimit: 100000n
});

// Check execution result
if (result.isSuccess()) {
  console.log('Success! Gas used:', result.gasUsed);
  console.log('Return data:', result.returnData.toHex());
} else {
  console.log('Failed! Gas used:', result.gasUsed);
  if (result.hasRevertReason()) {
    console.log('Revert reason:', result.getRevertReasonString());
  }
}
```

## API Documentation

### Main Classes

- **GuillotineEvm**: Main execution engine with state management
- **ExecutionResult**: Result of Evm execution with gas usage and output data
- **ExecutionParams**: Parameters for Evm execution (bytecode, caller, etc.)

### Primitive Types

- **Address**: 20-byte Ethereum address with hex string and byte array conversion
- **U256**: 256-bit unsigned integer with arithmetic and bitwise operations  
- **Bytes**: Variable-length byte array with hex string conversion
- **Hash**: 32-byte hash value with hex string conversion

### Core API

#### GuillotineEvm

```typescript
class GuillotineEvm {
  // Create new Evm instance
  static async create(wasmPath?: string): Promise<GuillotineEvm>
  
  // Execute bytecode
  async execute(params: ExecutionParams): Promise<ExecutionResult>
  
  // State management
  async setBalance(address: Address, balance: U256): Promise<void>
  async getBalance(address: Address): Promise<U256>
  async setCode(address: Address, code: Bytes): Promise<void>  
  async getCode(address: Address): Promise<Bytes>
  async setStorage(address: Address, key: U256, value: U256): Promise<void>
  async getStorage(address: Address, key: U256): Promise<U256>
  
  // Utilities
  getVersion(): string
  close(): void
}
```

#### ExecutionParams

```typescript
interface ExecutionParams {
  bytecode: Bytes        // The bytecode to execute
  caller?: Address       // Caller address (defaults to zero address)
  to?: Address          // Target address (defaults to zero address) 
  value?: U256          // Value to transfer (defaults to zero)
  input?: Bytes         // Input data (defaults to empty)
  gasLimit?: bigint     // Gas limit (defaults to 1,000,000)
}
```

#### ExecutionResult

```typescript
class ExecutionResult {
  readonly success: boolean
  readonly gasUsed: bigint
  readonly returnData: Bytes
  readonly revertReason: Bytes
  
  // Helper methods
  isSuccess(): boolean
  isFailure(): boolean
  hasReturnData(): boolean
  hasRevertReason(): boolean
  getRevertReasonString(): string | null
  getReturnDataString(): string | null
}
```

#### Error Handling

```typescript
// Error types
type GuillotineErrorType = 
  | 'InitializationFailed'
  | 'WasmLoadFailed' 
  | 'WasmNotLoaded'
  | 'VMCreationFailed'
  | 'VMNotInitialized'
  | 'ExecutionFailed'
  | 'InvalidBytecode'
  | 'InvalidAddress'
  | 'InvalidValue'
  | 'OutOfGas'
  | 'StackOverflow'
  | 'StackUnderflow' 
  | 'InvalidJump'
  | 'InvalidOpcode'
  | 'MemoryError'
  | 'StateError'
  | 'UnknownError';

class GuillotineError extends Error {
  readonly type: GuillotineErrorType;
  readonly cause?: Error;
  
  // Static factory methods
  static initializationFailed(message: string, cause?: Error): GuillotineError
  static executionFailed(message: string, cause?: Error): GuillotineError
  static invalidBytecode(message: string): GuillotineError
  // ... other static methods
}
```

## Examples

### Simple Bytecode Execution

```typescript
import { GuillotineEvm, Address, U256, Bytes } from '@evmts/guillotine';

const evm = await GuillotineEvm.create();

// Execute simple arithmetic: PUSH1 5, PUSH1 3, ADD
const result = await evm.execute({
  bytecode: Bytes.from('0x6005600301'),
  gasLimit: 100000n
});

console.log('Success:', result.isSuccess());
console.log('Gas used:', result.gasUsed);
console.log('Return data:', result.returnData.toHex());

evm.close();
```

### Working with Account State

```typescript
const evm = await GuillotineEvm.create();

const address = Address.from('0x742d35Cc6634C0532925a3b844Bc9e7595f7BBDc');

// Set initial balance
await evm.setBalance(address, U256.from('1000000000000000000')); // 1 ETH

// Check balance
const balance = await evm.getBalance(address);
console.log('Balance:', balance.toString(), 'wei');

// Set contract code
const code = Bytes.from('0x6001600101'); // PUSH1 1, PUSH1 1, ADD
await evm.setCode(address, code);

// Get code back
const retrievedCode = await evm.getCode(address);
console.log('Code:', retrievedCode.toHex());

// Set storage
const key = U256.from(0);
const value = U256.from(42);
await evm.setStorage(address, key, value);

// Get storage
const retrievedValue = await evm.getStorage(address, key);
console.log('Storage[0]:', retrievedValue.toString());

evm.close();
```

### Error Handling

```typescript
import { GuillotineError } from '@evmts/guillotine';

try {
  const evm = await GuillotineEvm.create();
  
  const result = await evm.execute({
    bytecode: Bytes.from('0xfd'), // REVERT opcode
    gasLimit: 100000n
  });
  
  if (result.isFailure()) {
    console.log('Execution reverted');
    if (result.hasRevertReason()) {
      console.log('Revert reason:', result.getRevertReasonString());
    }
  }
  
  evm.close();
} catch (error) {
  if (error instanceof GuillotineError) {
    console.log('Guillotine error:', error.type, error.message);
  } else {
    console.log('Unknown error:', error);
  }
}
```

## Performance

Guillotine is designed for maximum performance:

- **WebAssembly**: Core Evm implementation compiled from Zig to WASM
- **Zero-copy operations**: Minimal data copying between JS and WASM
- **Optimized bytecode**: Advanced bytecode analysis and optimization
- **Memory pooling**: Efficient memory management in WASM

Benchmarks show 2-10x performance improvements over pure JavaScript implementations for typical smart contract execution.

## Development

```bash
# Install dependencies
bun install

# Run tests
bun test

# Run specific test file
bun test src/primitives/address.test.ts

# Build TypeScript
bun run build

# Lint code
bun run lint

# Format code
bun run format
```

### Project Structure

```
src/
├── evm/           # Evm execution engine
├── primitives/    # Ethereum primitive types (Address, U256, Bytes, Hash)
├── wasm/          # WebAssembly loading and bindings
├── errors.ts      # Error types and handling
└── index.ts       # Main exports
```

## Testing

All code is developed using Test-Driven Development (TDD) with Bun test:

```typescript
import { describe, it, expect } from 'bun:test';
import { Address } from './address';

describe('Address', () => {
  it('should create address from hex string', () => {
    const addr = Address.fromHex('0x742d35Cc6634C0532925a3b844Bc9e7595f7BBDc');
    expect(addr.toHex()).toBe('0x742d35cc6634c0532925a3b844bc9e7595f7bbdc');
  });
  
  it('should detect zero address', () => {
    const zero = Address.zero();
    expect(zero.isZero()).toBe(true);
  });
});
```

Run tests with:

```bash
# Run all tests
bun test

# Run specific test file
bun test src/primitives/address.test.ts

# Run tests with coverage
bun test --coverage
```

## Contributing

Contributions are welcome! Please read our [Contributing Guide](../../CONTRIBUTING.md) for details.

## License

MIT License - see [LICENSE](../../LICENSE) for details.

## Related Projects

- [Guillotine](https://github.com/evmts/guillotine) - The main Zig implementation
- [Guillotine Go](../go) - Go bindings
- [Guillotine Python](../python) - Python bindings
- [Guillotine Rust](../rust) - Rust bindings
