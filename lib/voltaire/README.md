<div align="center">
  <h1>
    Ethereum primitives and cryptography for TypeScript and Zig.
    <br/>
    <br/>
    <img width="200" height="200" alt="image" src="https://github.com/user-attachments/assets/492fabbc-d8d0-4f5b-b9f5-ea05adc5f8ca" />
  </h1>
  <sup>
    <a href="https://www.npmjs.com/package/@tevm/primitives">
       <img src="https://img.shields.io/npm/v/@tevm/primitives.svg" alt="npm version" />
    </a>
    <a href="https://github.com/evmts/primitives">
       <img src="https://img.shields.io/badge/zig-0.15.1+-orange.svg" alt="zig version" />
    </a>
    <a href="https://github.com/evmts/primitives/actions/workflows/ci.yml">
      <img src="https://github.com/evmts/primitives/actions/workflows/ci.yml/badge.svg" alt="CI status" />
    </a>
    <a href="https://github.com/evmts/primitives/blob/main/LICENSE">
      <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License" />
    </a>
  </sup>
</div>

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [What's Included](#whats-included)
- [API Documentation](#api-documentation)
- [Platform Compatibility](#platform-compatibility)
- [Performance](#performance)
- [Native Zig Implementation](#native-zig-implementation)
- [Benchmarking](#benchmarking)
- [Documentation](#documentation)
- [Comparison with Other Libraries](#comparison-with-other-libraries)
- [Security](#security)
- [Contributing](#contributing)
- [Roadmap](#roadmap)
- [License](#license)
- [Related Projects](#related-projects)
- [Credits](#credits)
- [Support](#support)

## Features

- **Pure TypeScript** - Works in any JavaScript environment (Node.js, Bun, Deno, browsers)
- **Type-safe** - Full TypeScript support with comprehensive type definitions
- **Zero native dependencies** - All TypeScript implementations work standalone
- **Optional native performance** - High-performance Zig implementations available via FFI/WASM
- **Battle-tested** - Validated against Ethereum test vectors
- **Modern** - Supports latest EIPs including EIP-1559, EIP-4844, EIP-7702

## Installation

```bash
# Using npm
npm install @tevm/primitives

# Using bun
bun add @tevm/primitives
```

**No native dependencies required** - TypeScript implementations work out of the box.

## Quick Start

```typescript
import {
  keccak256,
  hexToBytes,
  bytesToHex,
  hashMessage,
  Hardfork,
  isAtLeast,
  Opcode,
  calculateNextBaseFee,
} from '@tevm/primitives';

// Keccak-256 hashing (via @noble/hashes)
const data = new TextEncoder().encode('hello world');
const hash = keccak256(data);
console.log('Hash:', bytesToHex(hash));

// EIP-191 personal message hashing
const msgHash = hashMessage('Sign this message');

// Hex utilities
const bytes = hexToBytes('0xabcd1234');
const hex = bytesToHex(bytes); // "0xabcd1234"

// Hardfork comparisons
if (isAtLeast(Hardfork.CANCUN, Hardfork.LONDON)) {
  console.log('Cancun includes London features');
}

// EVM opcodes
const addOpcode = Opcode.ADD;      // 0x01
const pushOpcode = Opcode.PUSH1;   // 0x60

// EIP-1559 gas calculations
const nextBaseFee = calculateNextBaseFee(
  1000000000n,  // parent base fee (1 gwei)
  15000000n,    // parent gas used
  30000000n     // parent gas limit
);
console.log('Next base fee:', nextBaseFee);
```

## What's Included

### Core Primitives

- **Hex Utilities** - Convert between hex strings and bytes
- **Keccak-256** - Cryptographic hashing (via @noble/hashes)
- **EIP-191** - Personal message hashing
- **EIP-712** - Typed structured data hashing
- **Signers** - Private key, HD wallet, and hardware wallet signers (via @noble/curves)

### Ethereum Types

- **Transactions** - Legacy, EIP-1559 (Type 2), EIP-7702 (Type 4)
- **Blocks** - Block headers and complete blocks
- **Receipts** - Transaction receipts with logs
- **Logs** - Event log parsing and filtering
- **Filters** - Block and log filters

### EVM Features

- **Bytecode Analysis** - Jump destination analysis, validation
- **Opcodes** - Complete EVM opcode enumeration with utilities
- **Gas Calculations** - EIP-1559 fee market, intrinsic gas, memory costs
- **Hardforks** - Version comparisons, chronological ordering
- **Precompiles** - Gas cost calculations for all precompiles (0x01-0x13)

### Standards

- **SIWE (EIP-4361)** - Sign-In with Ethereum message handling
- **Event Logs** - Topic filtering, signature hashing
- **Access Lists (EIP-2930)** - Gas cost calculations

## API Documentation

### Comprehensive TypeScript API

See [TYPESCRIPT_API.md](./docs/TYPESCRIPT_API.md) for complete API documentation including:
- Hex utilities and conversions
- Keccak-256 hashing
- Transaction encoding and validation
- Bytecode analysis and validation
- Opcode utilities
- Gas calculations
- Hardfork enumeration
- Event log parsing
- SIWE message handling
- Precompile gas costs

### Examples

#### Working with Transactions

```typescript
import {
  type Transaction,
  validateTransaction,
  hashTransaction,
} from '@tevm/primitives';

const tx: Transaction = {
  type: "eip1559",
  chainId: 1n,
  nonce: 42n,
  maxPriorityFeePerGas: 2000000000n,
  maxFeePerGas: 100000000000n,
  gasLimit: 21000n,
  to: '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045',
  value: 1000000000000000000n,
  data: '0x',
  accessList: [],
};

// Validate structure
if (validateTransaction(tx)) {
  // Compute hash
  const hash = hashTransaction(tx);
  console.log('Transaction hash:', hash);
}
```

#### Analyzing Bytecode

```typescript
import {
  analyzeJumpDestinations,
  validateBytecode,
  isValidJumpDest,
  hexToBytes,
} from '@tevm/primitives';

const bytecode = '0x608060405234801561001057600080fd5b50...';

if (validateBytecode(bytecode)) {
  // Find all JUMPDEST positions
  const jumps = analyzeJumpDestinations(bytecode);
  console.log('Valid jump destinations:', jumps);

  // Check specific position
  const isValid = isValidJumpDest(hexToBytes(bytecode), 100);
  console.log('Position 100 is valid JUMPDEST:', isValid);
}
```

#### Parsing Event Logs

```typescript
import {
  parseEventLog,
  filterLogsByTopics,
  type EventLog,
  type EventSignature,
} from '@tevm/primitives';

const transferSignature: EventSignature = {
  name: 'Transfer',
  inputs: [
    { name: 'from', type: 'address', indexed: true },
    { name: 'to', type: 'address', indexed: true },
    { name: 'value', type: 'uint256', indexed: false },
  ],
};

// Parse log
const decoded = parseEventLog(log, transferSignature);
console.log('From:', decoded.args.from);
console.log('To:', decoded.args.to);
console.log('Value:', decoded.args.value);

// Filter logs by topics
const filtered = filterLogsByTopics(logs, [
  '0xddf252ad...', // Transfer event signature
  null,            // any from address
  '0x...',         // specific to address
]);
```

#### Sign-In with Ethereum (SIWE)

```typescript
import {
  parseMessage,
  formatMessage,
  validateMessage,
  isExpired,
  type SiweMessage,
} from '@tevm/primitives';

const message = `example.com wants you to sign in with your Ethereum account:
0x1234567890123456789012345678901234567890

I accept the Terms of Service

URI: https://example.com/login
Version: 1
Chain ID: 1
Nonce: abcd1234
Issued At: 2024-01-01T00:00:00.000Z`;

// Parse and validate
const parsed = parseMessage(message);
if (validateMessage(parsed) && !isExpired(parsed)) {
  const formatted = formatMessage(parsed);
  console.log('Valid SIWE message:', formatted);
}
```

## Platform Compatibility

### TypeScript/JavaScript

Works in all modern JavaScript environments:
- **Node.js** 18+ (LTS)
- **Bun** - Full support including optional FFI for native bindings
- **Deno** - Full support via npm imports
- **Browsers** - Chrome 90+, Firefox 88+, Safari 14+, Edge 90+

All require BigInt support (available in all modern runtimes).

### Package Exports

```json
{
  "exports": {
    ".": {
      "types": "./types/index.d.ts",
      "import": "./dist/index.js"
    }
  }
}
```

## Performance

TypeScript implementations prioritize correctness and compatibility:

- **Keccak-256**: ~2-5 MB/s (via @noble/hashes)
- **Transaction encoding**: ~1-5k tx/s
- **Hex conversions**: ~50-100 MB/s
- **Bytecode analysis**: ~10-50 MB/s

For high-performance applications requiring 10-100x faster operations, see [Native Zig Implementation](#native-zig-implementation).

## Native Zig Implementation

This library includes high-performance native implementations written in Zig. These are optional and provide significant performance benefits for computationally intensive operations.

### Benefits

- **10-100x faster** cryptographic operations
- **Hardware acceleration** for Keccak-256 (x86-64/ARM assembly)
- **Zero-copy operations** with efficient memory management
- **WASM builds** for near-native browser performance

### Usage

For details on building and using the native Zig implementations, see:
- [ZIG_API.md](./ZIG_API.md) - Complete Zig API reference
- [WASM_SUPPORT.md](./docs/WASM_SUPPORT.md) - WebAssembly build guide
- [WASM-QUICK-START.md](./docs/WASM-QUICK-START.md) - Quick start for WASM deployment

### Benchmarking

Comprehensive performance benchmarks are available for both native Zig and TypeScript implementations.

```bash
# Run Zig benchmarks (opt-in with flag)
zig build -Dwith-benches=true bench

# Run TypeScript comparison benchmarks
bun run vitest bench comparisons/
```

See [BENCHMARKING.md](./BENCHMARKING.md) for detailed instructions, [ZIG_BENCHMARK_RESULTS.md](./ZIG_BENCHMARK_RESULTS.md) for Zig performance data, and [BENCHMARK_RESULTS.md](./BENCHMARK_RESULTS.md) for TypeScript/FFI comparisons.

## Documentation

### TypeScript

- [TYPESCRIPT_API.md](./docs/TYPESCRIPT_API.md) — Complete TypeScript API reference
- [PACKAGE_README.md](./docs/PACKAGE_README.md) — npm package documentation
- [examples/](./examples/) — Usage examples for both Zig and TypeScript

### Native Zig

- [ZIG_API.md](./ZIG_API.md) — Complete Zig API reference and build instructions
- [WASM_SUPPORT.md](./docs/WASM_SUPPORT.md) — WebAssembly build guide and feature parity
- [WASM-QUICK-START.md](./docs/WASM-QUICK-START.md) — Quick start for WASM deployment
- [examples/](./examples/) — Example code and usage patterns

### Development

- [CONTRIBUTING.md](./CONTRIBUTING.md) — Contribution guidelines
- [CLAUDE.md](./CLAUDE.md) — Coding standards and development protocols
- [RELEASE.md](./docs/RELEASE.md) — Release process guide

### Reference

- [CHANGELOG.md](./CHANGELOG.md) — Version history
- [docs/](./docs/) — ⚠️ AI-generated, unverified
- [LLMS.txt](./LLMS.txt) — For LLMs

## Comparison with Other Libraries

### vs ethers.js

- **Smaller** - No wallet/provider code, just primitives
- **Faster** - Optimized implementations with optional native backend
- **Modern** - Latest EIPs (4844, 7702)
- **Type-safe** - Better TypeScript support

### vs viem

- **Complementary** - Can be used together
- **Lower-level** - Focus on primitives, not RPC
- **Portable** - Works everywhere, not just Node/Bun
- **Native option** - Optional Zig implementations for performance

### vs ethereum-cryptography

- **Broader** - Includes transactions, RLP, EVM features, etc.
- **Native option** - Zig implementations available
- **Type-safe** - Full TypeScript with comprehensive types

## Security

This is production-ready software with audited dependencies where possible:

### Audited Components
- **@noble/hashes** - Widely used, audited cryptographic library by Paul Miller
- **@noble/curves** - Audited elliptic curve implementations
- **BLST** - Audited BLS12-381 implementation (C library)
- **c-kzg-4844** - Audited KZG implementation (C library)
- **Arkworks** - Audited BN254 implementation (Rust library)

### Not Audited
- TypeScript implementations (RLP, transactions, ABI parsing, etc.)
- Zig cryptographic primitives
- FFI/WASM bindings

**Report security issues to:** security@tevm.sh

## Contributing

Contributions welcome! See [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines.

Key areas for contribution:
- Additional EIP implementations
- Performance optimizations
- Test coverage improvements
- Documentation enhancements
- Bug fixes

## Roadmap

- [x] Core primitives (hex, keccak256, transactions, etc.)
- [x] EVM features (bytecode, opcodes, gas calculations)
- [x] Ethereum types (blocks, receipts, logs, filters)
- [x] Signer implementations (private key, HD wallet, hardware wallet)
- [ ] ABI encoding/decoding (full implementation)
- [ ] Complete transaction parsing for all types
- [x] Native FFI bindings for Bun
- [x] WASM builds for browser performance
- [ ] Additional hash algorithms
- [ ] More EIP implementations

## License

MIT License - see [LICENSE](./LICENSE) for details

## Related Projects

- [Guillotine](https://github.com/evmts/guillotine) - EVM execution engine using these primitives
- [Guillotine Mini](https://github.com/evmts/guillotine-mini) - Minimal EVM implementation
- [Tevm](https://github.com/evmts/tevm-monorepo) - TypeScript EVM tools

## Credits

Built with:
- [@noble/hashes](https://github.com/paulmillr/noble-hashes) by Paul Miller
- [@noble/curves](https://github.com/paulmillr/noble-curves) by Paul Miller
- [Zig](https://ziglang.org) by Andrew Kelley and contributors
- [BLST](https://github.com/supranational/blst) - BLS12-381 signatures
- [c-kzg-4844](https://github.com/ethereum/c-kzg-4844) - KZG commitments
- [Arkworks](https://github.com/arkworks-rs/curves) - BN254 curve operations
- Ethereum specifications and test vectors

## Support

- [GitHub Issues](https://github.com/evmts/primitives/issues)
- [Discord](https://discord.gg/tevm)
- [Twitter](https://twitter.com/tevm_sh)

---

Made with ❤️ by the Tevm team
