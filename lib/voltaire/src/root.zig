//! Primitives - Core Ethereum primitives and cryptographic operations
//!
//! This library provides the foundational types and operations for Ethereum:
//! - Primitives: uint256, address, hex encoding, RLP, ABI, transactions
//! - Crypto: Keccak-256, secp256k1, BLS12-381, BN254, KZG commitments

const std = @import("std");

// Re-export primitives module
pub const Primitives = @import("voltaire");

// Re-export crypto module
pub const Crypto = @import("crypto");

// Run tests
test {
    _ = @import("voltaire");
    _ = @import("crypto");
}
