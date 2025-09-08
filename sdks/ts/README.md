# Guillotine TypeScript

> Experimental/PoC: This SDK is a vibecoded proof-of-concept. APIs are unstable and may change. We're looking for early users to try it and tell us what APIs you want — please open an issue or ping us on Telegram.

📚 **[View Full Documentation](https://guillotine.dev/sdks/typescript)**

## Status

- Maturity: Experimental proof‑of‑concept
- API stability: Unstable; breaking changes expected
- Feedback: https://github.com/evmts/Guillotine/issues or Telegram https://t.me/+ANThR9bHDLAwMjUx

High-performance Ethereum Virtual Machine (EVM) implementation for TypeScript/JavaScript, powered by WebAssembly.

## Features

- 🚀 **High Performance**: WebAssembly-compiled Zig implementation
- 🔒 **Type Safe**: Full TypeScript support with strict typing
- 🧩 **Modular**: Separate modules for different EVM components
- 🔄 **Async First**: Non-blocking operations with Promise-based API
- 🧪 **Well Tested**: Comprehensive test suite with real EVM execution
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

## Quick Start

```typescript
import { EVM, Address, U256, Bytes } from '@evmts/guillotine';

// Create an EVM instance
const evm = await EVM.create();

// Execute bytecode
const result = await evm.execute({
  bytecode: Bytes.from('0x6001600201'), // PUSH1 1, PUSH1 2, ADD
  gasLimit: 100000n,
  caller: Address.from('0x1234567890123456789012345678901234567890'),
  value: U256.zero()
});

if (result.success) {
  console.log('Gas used:', result.gasUsed);
  console.log('Return data:', result.output.toHex());
} else {
  console.log('Execution failed:', result.error);
}

// Clean up
evm.destroy();
```

## Core Concepts

### EVM Instance

The main entry point for executing EVM bytecode:

```typescript
const evm = await EVM.create({
  hardfork: 'shanghai', // Optional: specify hardfork rules
  enableTracing: false  // Optional: enable execution tracing
});
```

### State Management

Manage blockchain state with the built-in state database:

```typescript
// Set account balance
await evm.stateDB.setBalance(
  Address.from('0x742d35Cc6634C0532925a3b844Bc9e7595f7BBDc'),
  U256.from('1000000000000000000') // 1 ETH
);

// Deploy contract code
await evm.stateDB.setCode(contractAddress, contractBytecode);

// Set storage values
await evm.stateDB.setStorage(contractAddress, slot, value);
```

### Transaction Execution

Execute transactions with full context:

```typescript
const result = await evm.execute({
  // Transaction parameters
  caller: Address.from('0x...'),
  to: Address.from('0x...'),
  value: U256.from('1000000000000000000'),
  input: Bytes.from('0x...'),
  gasLimit: 100000n,
  gasPrice: U256.from('20000000000'),
  
  // Block context
  blockNumber: 1000000n,
  timestamp: Date.now() / 1000,
  coinbase: Address.from('0x...'),
  difficulty: U256.zero(),
  gasLimit: 30000000n,
  baseFee: U256.from('10000000000')
});
```

### Low-Level Frame API

For direct bytecode execution and debugging:

```typescript
const frame = await Frame.create({
  bytecode: Bytes.from('0x...'),
  gasLimit: 100000n
});

// Enable step-by-step execution
frame.enableStepping();

while (!frame.isStopped()) {
  const step = await frame.step();
  console.log(`PC: ${step.pc}, Opcode: ${step.opcode}, Gas: ${step.gasRemaining}`);
}

frame.destroy();
```

## API Documentation

See [API_DESIGN.md](./API_DESIGN.md) for comprehensive API documentation.

### Main Modules

- **EVM**: Main execution engine
- **Frame**: Low-level execution context
- **Stack**: EVM stack operations
- **Memory**: EVM memory management
- **StateDB**: Blockchain state management
- **Bytecode**: Bytecode analysis and optimization

### Primitive Types

- **Address**: 20-byte Ethereum address
- **U256**: 256-bit unsigned integer
- **Bytes**: Variable-length byte array
- **Hash**: 32-byte hash value

## Examples

### Deploy and Call a Contract

```typescript
// Deploy a simple storage contract
const deployCode = Bytes.from('0x608060405234801561001057600080fd5b50610150806100206000396000f3fe608060405234801561001057600080fd5b50600436106100365760003560e01c80632e64cec11461003b5780636057361d14610059575b600080fd5b610043610075565b60405161005091906100e2565b60405180910390f35b610073600480360381019061006e91906100ae565b61007e565b005b60008054905090565b8060008190555050565b60008135905061009881610103565b92915050565b6000602082840312156100b057600080fd5b60006100be84828501610089565b91505092915050565b60006100d2826100d8565b82525050565b6000819050919050565b60006020820190506100f760008301846100c7565b92915050565b50919050565b61010c816100d8565b811461011757600080fd5b5056fea264697066735822122064e2a6a82e23e69b1e28e2e8d573fa513043efbf84e32331f184990797c5b52a64736f6c63430008040033');

const deployResult = await evm.execute({
  caller: Address.from('0x1234567890123456789012345678901234567890'),
  input: deployCode,
  gasLimit: 1000000n
});

const contractAddress = deployResult.createdAddress;

// Call the deployed contract
const calldata = Bytes.from('0x6057361d0000000000000000000000000000000000000000000000000000000000000042'); // store(66)

const callResult = await evm.execute({
  caller: Address.from('0x1234567890123456789012345678901234567890'),
  to: contractAddress,
  input: calldata,
  gasLimit: 100000n
});
```

### Custom Tracer

```typescript
class GasTracer {
  private gasPerOpcode = new Map<string, bigint>();
  
  async onStep(step: TraceStep): Promise<void> {
    const current = this.gasPerOpcode.get(step.opcode) || 0n;
    this.gasPerOpcode.set(step.opcode, current + step.gasCost);
  }
  
  report() {
    console.log('Gas usage by opcode:');
    for (const [opcode, gas] of this.gasPerOpcode) {
      console.log(`  ${opcode}: ${gas}`);
    }
  }
}

const tracer = new GasTracer();
const evm = await EVM.create({ tracer });

// Execute transaction...

tracer.report();
```

## Performance

Guillotine is designed for maximum performance:

- **WebAssembly**: Core EVM implementation compiled from Zig to WASM
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
├── core/          # Core EVM functionality
├── primitives/    # Ethereum primitive types
├── bytecode/      # Bytecode analysis
├── state/         # State management
├── wasm/          # WASM bindings
└── test/          # Test utilities
```

## Testing

All code is developed using Test-Driven Development (TDD) with Bun test:

```typescript
import { describe, it, expect } from 'bun:test';
import { Address } from '../address';

describe('Address', () => {
  it('should create address from hex string', () => {
    const addr = Address.from('0x742d35Cc6634C0532925a3b844Bc9e7595f7BBDc');
    expect(addr.toString()).toBe('0x742d35cc6634c0532925a3b844bc9e7595f7bbdc');
  });
  
  it('should detect zero address', () => {
    const zero = Address.zero();
    expect(zero.isZero()).toBe(true);
  });
});
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
