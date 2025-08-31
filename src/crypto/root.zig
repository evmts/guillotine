//! Cryptographic Operations - Ethereum cryptography primitives and utilities
//!
//! This module provides the essential cryptographic functions used throughout
//! Ethereum, including hash functions, digital signatures, key generation,
//! and address derivation. It serves as the foundation for transaction
//! signing, account management, and cryptographic verification.
//!
//! ## Core Cryptographic Primitives
//!
//! ### Hash Functions
//! - **Keccak256**: Primary hash function used in Ethereum
//! - **SHA256**: Used in precompiles and some legacy operations
//! - **RIPEMD160**: Used in Bitcoin-compatible operations
//! - **Blake2b**: High-performance alternative hash function
//!
//! ### Digital Signatures
//! - **ECDSA**: Elliptic Curve Digital Signature Algorithm
//! - **secp256k1**: Bitcoin/Ethereum curve for signatures
//! - **Recovery**: Public key recovery from signatures
//! - **Verification**: Signature validation and authenticity
//!
//! ### Key Management
//! - **Private Keys**: 256-bit random values for signing
//! - **Public Keys**: Derived from private keys via ECDSA
//! - **Addresses**: 160-bit identifiers derived from public keys
//! - **Deterministic Generation**: HD wallet support

// Core cryptographic modules
pub const Crypto = @import("crypto.zig");
pub const secp256k1 = @import("secp256k1.zig");
pub const ModExp = @import("modexp.zig");

// Hash implementations
pub const Hash = @import("hash.zig");
pub const HashAlgorithms = @import("hash_algorithms.zig");
pub const HashUtils = @import("hash_utils.zig");
pub const Blake2 = @import("blake2.zig");
pub const Ripemd160 = @import("ripemd160.zig");

// Ethereum standards
pub const Eip712 = @import("eip712.zig");

// Hardware acceleration
pub const CpuFeatures = @import("cpu_features.zig");
pub const SHA256_Accel = @import("sha256_accel.zig");
pub const Keccak256_Accel = @import("keccak256_accel.zig");

// KZG commitments for EIP-4844
pub const c_kzg = @import("c_kzg");

// BN254 for precompiles
pub const bn254 = @import("bn254.zig");

// Export BLS12-381 from crypto.zig
pub const bls12_381 = Crypto.bls12_381;
