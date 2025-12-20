# Primitives Library Source Code

Core implementation of Ethereum primitives and cryptographic operations in Zig.

## Directory Structure

### Primitives (`primitives/`)
Core Ethereum types and encoding/decoding utilities:
- **uint256** - 256-bit unsigned integer arithmetic
- **Address** - Ethereum address types and operations
- **Hex** - Hexadecimal encoding/decoding
- **RLP** - Recursive Length Prefix encoding/decoding
- **ABI** - Application Binary Interface encoding/decoding
- **Transactions** - Transaction types and signing
- **Logs** - Event log structures

### Cryptography (`crypto/`)
Cryptographic primitives and operations:
- **Keccak-256** - Primary Ethereum hash function
- **secp256k1** - ECDSA signatures for transaction signing
- **BLS12-381** - Pairing-friendly elliptic curve (via lib/blst)
- **BN254** - Alt-BN128 curve for zkSNARK operations
- **KZG Commitments** - EIP-4844 blob commitments (via lib/c-kzg-4844)
- **SHA256** - Standard SHA-256 hashing
- **RIPEMD160** - Legacy RIPEMD-160 hashing
- **Blake2** - High-performance Blake2 hashing

## Build System

All modules are integrated through Zig's build system:
- `zig build` - Compile libraries
- `zig build test` - Run all tests (primitives + crypto)

## Key Design Principles

1. **Memory Safety** - Careful memory management with explicit ownership
2. **Correctness** - Strong typing and comprehensive testing
3. **Modularity** - Clear separation between primitives and crypto
4. **Zero Dependencies** - Only links to required C libraries (blst, c-kzg-4844)

## External Dependencies

The crypto module links to these C/Rust libraries:
- **lib/blst/** - BLS12-381 implementation (C)
- **lib/c-kzg-4844/** - KZG commitments (C)
- **lib/ark/** - BN254 curve support (optional)
