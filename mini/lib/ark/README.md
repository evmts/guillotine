# BN254 Rust Wrapper

Rust-based BN254 elliptic curve implementation for production-grade scalar multiplication and pairing operations.

## Overview

This wrapper provides BN254 elliptic curve operations using the arkworks ecosystem (ark-bn254, ark-ec, ark-ff, ark-serialize) for use in EVM precompiles.

## Usage

The BN254 wrapper is used by:
- `src/crypto` - For elliptic curve operations
- `src/evm/precompiles` - For ECMUL (0x07) and ECPAIRING (0x08) precompiles

The wrapper is automatically linked when importing the EVM module.

## Build Requirements

- Rust toolchain (will be replaced with pure Zig implementation, see issue #1)
- Generated C header for FFI binding

## WASM Compatibility

For WASM targets, BN254 operations use placeholder implementations. Full zkSNARK support requires host environment integration.

## Future

This Rust wrapper is temporary and will be replaced with a pure Zig implementation to eliminate the Rust toolchain dependency.