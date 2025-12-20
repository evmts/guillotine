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
const modexp_module = @import("modexp.zig");
pub const ModExp = modexp_module.ModExp;

// Hash implementations
pub const Hash = @import("hash.zig");
pub const HashAlgorithms = @import("hash_algorithms.zig");
pub const HashUtils = @import("hash_utils.zig");
const blake2_module = @import("blake2.zig");
pub const Blake2 = blake2_module.Blake2;
const ripemd160_module = @import("ripemd160.zig");
pub const Ripemd160 = ripemd160_module.Ripemd160;

// Ethereum standards
pub const Eip712 = @import("eip712.zig");

// Hardware acceleration
pub const CpuFeatures = @import("cpu_features.zig");
pub const SHA256_Accel = @import("sha256_accel.zig");
pub const Keccak256_Accel = @import("keccak256_accel.zig");
pub const keccak_asm = @import("keccak_asm.zig");

// Rust FFI wrappers (compiled from src/crypto/*.rs)
pub const bn254_wrapper = @import("bn254_wrapper.rs");
pub const keccak_wrapper = @import("keccak_wrapper.rs");

// KZG commitments for EIP-4844
const builtin = @import("builtin");
pub const kzg_trusted_setup = @import("kzg_trusted_setup.zig");
pub const kzg_setup = @import("kzg_setup.zig");
pub const c_kzg = if (builtin.target.cpu.arch != .wasm32)
    @import("c_kzg")
else
    struct {
        // Stub for WASM builds - KZG operations not supported
        pub const KZGCommitment = [48]u8;
        pub const KZGProof = [48]u8;
        pub const Bytes32 = [32]u8;
        pub const Blob = [131072]u8;

        pub fn verifyKZGProof(commitment: *const KZGCommitment, z: *const Bytes32, y: *const Bytes32, proof: *const KZGProof) !bool {
            _ = commitment;
            _ = z;
            _ = y;
            _ = proof;
            return error.NotSupported;
        }

        pub fn blobToKZGCommitment(blob: *const Blob) !KZGCommitment {
            _ = blob;
            return error.NotSupported;
        }

        pub fn computeKZGProof(blob: *const Blob, z: *const Bytes32) !struct { proof: KZGProof, y: Bytes32 } {
            _ = blob;
            _ = z;
            return error.NotSupported;
        }

        pub fn loadTrustedSetupFile(path: []const u8, precompute: usize) !void {
            _ = path;
            _ = precompute;
            return error.NotSupported;
        }

        pub fn loadTrustedSetupFromText(data: []const u8, precompute: usize) !void {
            _ = data;
            _ = precompute;
            return error.NotSupported;
        }

        pub fn freeTrustedSetup() !void {
            return error.NotSupported;
        }
    };

// BN254 elliptic curve - dual implementations
pub const bn254 = @import("bn254.zig"); // Pure Zig implementation
pub const bn254_arkworks = if (builtin.target.cpu.arch != .wasm32)
    @import("bn254_arkworks.zig") // Rust arkworks - production-grade, audited
else
    struct {
        // Stub for WASM builds - Rust FFI not supported
        pub const BN254Error = error{NotSupported};
        pub fn init() BN254Error!void {
            return error.NotSupported;
        }
        pub fn ecmul(input: []const u8, output: []u8) BN254Error!void {
            _ = input;
            _ = output;
            return error.NotSupported;
        }
        pub fn ecpairing(input: []const u8, output: []u8) BN254Error!void {
            _ = input;
            _ = output;
            return error.NotSupported;
        }
    };

// Export BLS12-381 from crypto.zig
pub const bls12_381 = Crypto.bls12_381;
