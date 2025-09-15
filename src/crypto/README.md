# Crypto - Cryptographic Utilities and Implementations

## ⚠️ Security Notice

**UNAUDITED IMPLEMENTATIONS**: This module contains custom cryptographic implementations that have NOT been security audited. Many functions are explicitly marked as `unaudited_` and include extensive security warnings. These implementations are provided for educational and testing purposes. **DO NOT USE IN PRODUCTION** without proper security audit and testing.

## Overview

This directory provides comprehensive cryptographic implementations used throughout Guillotine, including hash functions, digital signatures, elliptic curve operations, and specialized cryptographic constructs required for Ethereum Virtual Machine (EVM) execution. The implementation prioritizes performance, EVM compatibility, and educational clarity.

## Components

### Core Cryptographic Files
- **`crypto.zig`** - Central cryptographic utilities and high-level operations interface with ECDSA, key management
- **`root.zig`** - Main module exports and public API definitions
- **`hash.zig`** - Hash function interface and module re-exports
- **`hash_utils.zig`** - Core hash types, utilities, and Keccak256 implementation
- **`hash_algorithms.zig`** - Collection of hash algorithm implementations

### Hash Function Implementations
- **`keccak_asm.zig`** - Assembly-optimized Keccak-256 implementation
- **`keccak256_accel.zig`** - Hardware-accelerated Keccak-256 with SIMD optimizations
- **`sha256_accel.zig`** - Hardware-accelerated SHA-256 with CPU feature detection
- **`blake2.zig`** - BLAKE2 hash function implementation
- **`ripemd160.zig`** - RIPEMD-160 hash function implementation

### Elliptic Curve Cryptography
- **`secp256k1.zig`** - Complete secp256k1 curve implementation with ECDSA operations (⚠️ UNAUDITED)
- **`bn254/`** - Complete BN254/alt_bn128 curve implementation for zkSNARKs and pairing-based cryptography
- **`bn254.zig`** - BN254 curve module exports and public interface

### BN254 Curve Components
- **`bn254/FpMont.zig`** - Montgomery form finite field arithmetic over Fp
- **`bn254/Fp2Mont.zig`** - Quadratic extension field Fp2 operations
- **`bn254/Fp6Mont.zig`** - Sextic extension field Fp6 operations  
- **`bn254/Fp12Mont.zig`** - Degree-12 extension field Fp12 operations
- **`bn254/Fr.zig`** - Scalar field Fr arithmetic
- **`bn254/G1.zig`** - G1 group operations (elliptic curve points)
- **`bn254/G2.zig`** - G2 group operations (twisted curve points)
- **`bn254/pairing.zig`** - Optimal ate pairing implementation
- **`bn254/curve_parameters.zig`** - BN254 curve constants and precomputed values

### Advanced Cryptographic Operations
- **`modexp.zig`** - Arbitrary-precision modular exponentiation (⚠️ UNAUDITED)
- **`eip712.zig`** - EIP-712 structured data signing and domain separation
- **`c_kzg.zig`** - KZG commitment scheme bindings for EIP-4844 blob transactions

### Performance and Testing
- **`cpu_features.zig`** - Runtime CPU feature detection for hardware acceleration
- **`hardware_accel_benchmarks.zig`** - Performance benchmarking suite for accelerated functions

## Key Features

### Hash Functions
- **Keccak-256**: Primary Ethereum hash function with optimized implementations
- **SHA-256**: Standard cryptographic hash with hardware acceleration
- **BLAKE2**: High-performance hash function for specific use cases
- **RIPEMD-160**: Legacy hash function for Bitcoin compatibility

### Digital Signatures
- **ECDSA**: Elliptic Curve Digital Signature Algorithm (⚠️ UNAUDITED implementation)
- **secp256k1**: Bitcoin/Ethereum curve for transaction signatures
- **Public key recovery**: Recover public keys from ECDSA signatures
- **EIP-712**: Structured data signing for typed messages and domain separation
- **EIP-191**: Personal message signing with Ethereum prefix

### Elliptic Curve Operations
- **BN254/alt_bn128**: Pairing-friendly curve for zkSNARKs and zero-knowledge proofs
  - Complete tower field implementation (Fp, Fp2, Fp6, Fp12)
  - Optimal ate pairing for efficient pairing operations
  - Montgomery form arithmetic for performance
- **secp256k1**: Bitcoin/Ethereum curve (⚠️ UNAUDITED custom implementation)
  - Complete point arithmetic in affine coordinates
  - Scalar multiplication with double-and-add
  - Field arithmetic with custom modular operations
- **BLS12-381**: BLS signature-friendly curve (FFI bindings)
  - G1/G2 group operations via external library
  - Pairing operations for BLS signatures
  - Multi-scalar multiplication support

### Performance Optimizations
- **Hardware acceleration**: Utilize CPU-specific instructions (SHA-NI, AVX2)
- **SIMD vectorization**: Parallel processing for hash functions
- **Montgomery arithmetic**: Efficient modular arithmetic for finite fields
- **Constant-time operations**: Side-channel attack resistance (where implemented)
- **CPU feature detection**: Runtime selection of optimal implementations

## Architecture

### Cryptographic Interface
```zig
const crypto = @import("crypto");

// Hash functions
const Hash = crypto.Hash;
const hash = Hash.keccak256("Hello, Ethereum!");

// ECDSA (secp256k1) - ⚠️ UNAUDITED developer utilities
const Crypto = crypto.Crypto;
const private_key = try Crypto.unaudited_randomPrivateKey();
const public_key = try Crypto.unaudited_getPublicKey(private_key);
const address = public_key.to_address();
const signature = try Crypto.unaudited_signMessage("hello", private_key);
const is_valid = try Crypto.unaudited_verifyMessage("hello", signature, address);

// BLS12-381 operations (conditionally compiled)
const bls = crypto.bls12_381;
try bls.g1_add(input_data, output_buffer);
try bls.pairing(input_data, output_buffer);
```

### Hardware Acceleration
- **Keccak256_Accel**: SIMD-optimized Keccak256 with AVX2 support
- **SHA256_Accel**: CPU instruction acceleration with SHA-NI support  
- **cpu_features**: Runtime detection of available CPU features

### KZG Commitments (EIP-4844)
```zig
const c_kzg = crypto.c_kzg;

// Load trusted setup for KZG operations
try c_kzg.loadTrustedSetupFile("trusted_setup.txt", 0);

// KZG operations for blob verification
const commitment: c_kzg.KZGCommitment = undefined;
const proof: c_kzg.KZGProof = undefined;
const blob: c_kzg.Blob = undefined;
```

## Security Considerations

### ⚠️ Critical Security Warnings

**UNAUDITED CUSTOM IMPLEMENTATIONS**: This crypto module contains several custom cryptographic implementations that have **NOT** been security audited:

- **secp256k1.zig**: Custom elliptic curve implementation with potential timing vulnerabilities
- **modexp.zig**: Custom modular exponentiation with possible side-channel leaks
- **crypto.zig**: Custom ECDSA signing and key derivation functions

All functions marked with `unaudited_` prefix carry significant security risks and should **NOT** be used in production.

### Security Properties (Where Implemented)
- **Input validation**: Range checks for signature parameters and curve points
- **Malleability protection**: Low-S enforcement for ECDSA signatures (EIP-2)
- **Hash function security**: Uses standard library Keccak256 implementation
- **Memory safety**: Proper bounds checking and error handling

### Known Security Limitations
- **Non-constant time**: Custom field arithmetic may leak timing information
- **Side-channel vulnerabilities**: Power analysis and cache timing attacks possible
- **Unvalidated edge cases**: Custom implementations may have undiscovered bugs
- **No formal verification**: Implementations not mathematically proven correct

### Safe Components
- **Standard library hashes**: Keccak256, SHA256 via std.crypto
- **BN254 curve**: Well-tested implementation for precompiles
- **BLS12-381**: External audited library via FFI bindings
- **KZG commitments**: Official c-kzg library bindings

## Usage Examples

### Basic Hash Operations
```zig
const crypto = @import("crypto");
const Hash = crypto.Hash;

const data = "Hello, Ethereum!";
const hash = Hash.keccak256(data);
const zero_hash = Hash.zero();
const is_empty = Hash.is_zero(hash);
```

### Digital Signatures (⚠️ UNAUDITED developer helpers)
```zig
const Crypto = (@import("crypto")).Crypto;

const private_key = try Crypto.unaudited_randomPrivateKey();
const public_key = try Crypto.unaudited_getPublicKey(private_key);
const message_hash = (@import("crypto")).Hash.keccak256("msg");
const signature = try Crypto.unaudited_signHash(message_hash, private_key);
const address = public_key.to_address();
const is_valid = try Crypto.unaudited_verifyMessage("msg", signature, address);
```

### EIP-712 Structured Data
```zig
const Eip712 = (@import("crypto")).Eip712;
const domain = Eip712.Eip712Domain{
    .name = "MyDApp",
    .version = "1",
    .chain_id = 1,
    .verifying_contract = contract_address,
    .salt = null,
};

// Note: Full EIP-712 implementation requires type definition and encoding
// See eip712.zig for complete implementation details
```

### Address Operations
```zig
const Crypto = (@import("crypto")).Crypto;

// Derive Ethereum address from public key
const address = Crypto.public_key_to_address(public_key);

// Hash message with EIP-191 prefix
const message_hash = Crypto.hash_message("Hello, Ethereum!");

// Signature validation
const is_valid = Crypto.is_valid_signature(signature);
```

## Integration with Guillotine

The crypto module integrates with:

### EVM Core
- **Transaction signing**: ECDSA signature verification
- **Address derivation**: Account and contract address generation
- **Hash operations**: State root calculation, transaction hashing

### Precompiled Contracts
- **ecRecover (0x01)**: ECDSA signature recovery using secp256k1
- **sha256 (0x02)**: SHA-256 hash computation with hardware acceleration
- **ripemd160 (0x03)**: RIPEMD-160 hash computation
- **modexp (0x05)**: Arbitrary-precision modular exponentiation (⚠️ UNAUDITED)
- **BN254 operations (0x06-0x08)**: alt_bn128 elliptic curve and pairing operations
  - **ecAdd (0x06)**: BN254 G1 point addition
  - **ecMul (0x07)**: BN254 G1 scalar multiplication  
  - **ecPairing (0x08)**: BN254 optimal ate pairing
- **BLS12-381 operations (0x0a-0x0d)**: BLS12-381 curve operations (EIP-2537)
  - **G1Add (0x0a)**: BLS12-381 G1 point addition
  - **G1Mul (0x0b)**: BLS12-381 G1 scalar multiplication
  - **G1MultiExp (0x0c)**: BLS12-381 G1 multi-scalar multiplication
  - **Pairing (0x0d)**: BLS12-381 pairing check
- **KZG Point Evaluation (0x0a)**: EIP-4844 blob verification using KZG commitments

### State Management
- **Merkle trees**: Keccak-256 for tree node hashing
- **Storage keys**: Hash-based storage addressing
- **Bloom filters**: Efficient event filtering

## Testing and Validation

### Test Coverage
- **Unit tests**: Individual function correctness
- **Cross-validation**: Comparison with reference implementations
- **Edge cases**: Boundary conditions and error handling
- **Performance tests**: Benchmark critical operations

### Compliance Testing
- **Ethereum test suite**: Official test vector validation
- **EIP compliance**: Implementation matches specifications
- **Interoperability**: Compatible with other EVM implementations

### Fuzzing and Robustness
- **Random input testing**: Handle arbitrary inputs gracefully
- **Boundary condition testing**: Edge cases and overflow conditions
- **Property-based testing**: Cryptographic properties maintained
