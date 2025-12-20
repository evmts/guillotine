# External Cryptographic Libraries (`lib/`)

This directory contains external C/Rust libraries required for cryptographic operations. These dependencies provide production-grade, audited implementations that are used in the Ethereum ecosystem.

## Implementation Strategy: C/Rust + Pure Zig

This library offers **dual implementations** for some cryptographic operations:

| Operation | Pure Zig | C/Rust Production | Zig Wrapper | Use Cases |
|-----------|----------|-------------------|-------------|-----------|
| **Keccak-256** | `std.crypto` (fallback) | `lib/keccak/` (Rust) | `src/crypto/keccak_asm.zig` | **Assembly-optimized hashing** |
| **BN254** | `src/crypto/bn254/` | `lib/ark/` (Rust) | `src/crypto/bn254_arkworks.zig` | Zig: Zero deps, full control<br>Rust: Audited, battle-tested |
| **BLS12-381** | ❌ Not Implemented | `lib/c-kzg-4844/blst/` (C) | `src/crypto/bn254_ffi.zig` (partial) | **Required for KZG & EIP-2537** |
| **KZG (EIP-4844)** | ❌ Not Implemented | `lib/c-kzg-4844/` (C) | `src/crypto/root.zig` (c_kzg) | **Required for blob transactions** |

### Exposed Zig APIs

All external libraries are wrapped in idiomatic Zig interfaces:

- **`crypto.keccak_asm`** - Assembly-optimized Keccak-256 via keccak-asm Rust crate
- **`crypto.bn254`** - Pure Zig BN254 implementation (zero external deps)
- **`crypto.bn254_arkworks`** - Rust arkworks wrapper (ECMUL, ECPAIRING, BLS12-381 ops)
- **`crypto.c_kzg`** - KZG commitments for EIP-4844 blob transactions

### When to Use Each Implementation

**Pure Zig Implementations:**
- ✅ Zero external dependencies
- ✅ Full Zig safety guarantees
- ✅ Easier debugging and modification
- ✅ Better integration with Zig toolchain
- ❌ May require additional optimization

**C/Rust Implementations:**
- ✅ Battle-tested in production
- ✅ Highly optimized (assembly, SIMD)
- ✅ Audited by security firms
- ❌ FFI overhead and complexity
- ❌ External toolchain dependencies

## Dependencies

### 🔐 `c-kzg-4844/` - KZG Polynomial Commitments

**Purpose**: Provides KZG polynomial commitment operations required for EIP-4844 (Proto-Danksharding) blob transactions.

**Technology**: C library (Ethereum Foundation official implementation)
**License**: Apache-2.0

**Key Features**:
- Blob to KZG commitment conversion
- KZG proof computation and verification
- Batch verification for performance
- EIP-4844 compliance
- Embedded trusted setup

**Integration**:
- Used by `src/crypto/` for KZG operations
- Automatically built via `zig build`
- Depends on BLST for elliptic curve operations

**Build Requirements**:
- Git submodule (`git submodule update --init --recursive`)
- BLST library (built automatically)

**Submodule Structure**:
```
lib/c-kzg-4844/
├── blst/           # BLS12-381 implementation (submodule)
├── src/            # KZG C implementation
└── bindings/       # Language bindings
```

### 🧮 `ark/` - BN254 Elliptic Curve Operations

**Status**: ✅ **Production Ready** - Audited implementation used in EVM precompiles

**Purpose**: BN254 (alt_bn128) elliptic curve operations for zkSNARK verification and EVM precompiles (ECADD, ECMUL, ECPAIRING).

**Technology**: Rust wrapper around arkworks ecosystem
**Dependencies**: ark-bn254, ark-ec, ark-ff, ark-serialize
**License**: MIT

**Key Features**:
- Production-tested in Ethereum ecosystem
- Audited arkworks cryptographic primitives
- Scalar multiplication and pairing operations
- Memory-safe FFI bindings
- Used by EVM implementations (ECADD 0x06, ECMUL 0x07, ECPAIRING 0x08)

**Integration**:
- Built automatically via Cargo workspace
- Linked into Zig build via `lib/bn254.zig`
- FFI header at `lib/ark/bn254_wrapper.h`

**Build Requirements**:
- Rust toolchain (cargo)
- Built via: `cargo build` or `cargo build --release`
- Workspace builds to `target/debug/` or `target/release/`

**Pure Zig Alternative**: `src/crypto/bn254/`
- ✅ Complete field tower (Fp, Fp2, Fp6, Fp12)
- ✅ G1 and G2 group operations
- ✅ Optimal ate pairing
- ✅ Comprehensive test suite
- ✅ Zero external dependencies
- 📋 Use when you want to avoid Rust toolchain

### ⚡ `keccak/` - Assembly-Optimized Keccak-256

**Status**: ✅ **Production Ready** - High-performance assembly implementation

**Purpose**: Assembly-optimized Keccak-256 hashing for maximum performance on x86_64 and aarch64 architectures.

**Technology**: Rust wrapper around keccak-asm (DaniPopes)
**Dependencies**: keccak-asm
**License**: BSD-3-Clause

**Key Features**:
- Platform-specific assembly implementations (x86_64, aarch64)
- SIMD acceleration where available
- Significantly faster than pure software implementations
- Zero-cost FFI abstractions
- Used for all Ethereum hashing operations

**Integration**:
- Built automatically via Cargo workspace
- Linked into Zig build via `lib/keccak.zig`
- FFI header at `lib/keccak/keccak_wrapper.h`
- Exposed via `src/crypto/keccak_asm.zig`

**Build Requirements**:
- Rust toolchain (cargo)
- Built via: `cargo build` or `cargo build --release`
- Workspace builds to `target/debug/` or `target/release/`

**Fallback**: `std.crypto.hash.sha3.Keccak256`
- Used automatically for WASM targets
- Pure Zig implementation when Rust is unavailable

### 🔷 BLST - BLS12-381 Operations

**Status**: ✅ **Available** - Integrated via c-kzg-4844 submodule

**Purpose**: BLS12-381 elliptic curve operations for KZG commitments and BLS signatures.

**Technology**: C implementation (highly optimized)
**License**: Apache-2.0

**Integration**:
- Used by `lib/c-kzg-4844/` for KZG operations
- Can be accessed directly via `lib/blst.zig`
- Built automatically as part of c-kzg-4844

**Current Usage**: Primarily for KZG commitments (EIP-4844)

**Note**: `lib/bls_wrapper.zig` contains only stub implementations. Direct BLST operations require using the c-kzg-4844 wrapper or implementing proper BLST bindings.

### Build System Wrappers

- **`blst.zig`** - Zig build wrapper for BLST library
- **`c-kzg.zig`** - Zig build wrapper for c-kzg-4844
- **`bn254.zig`** - Zig build wrapper for ark BN254 (currently returns null)
- **`bls_wrapper.zig`** - Stub BLS12-381 FFI exports (not implemented)
- **`build.zig`** - Build configuration for all external libraries

## Build System Integration

### Zig Build Integration

The main `build.zig` orchestrates all dependencies:

1. **Submodule Verification**: Ensures c-kzg-4844 submodule is initialized
2. **Library Creation**: Creates static libraries for each component
3. **Linking**: Links crypto libraries to primitives and crypto modules

### Build Commands

```bash
# Build Rust dependencies (run once, or when Rust code changes)
cargo build          # Debug build
cargo build --release # Optimized build

# Standard build (includes all dependencies)
zig build

# Run tests (includes crypto tests)
zig build test
```

**Note**: The Rust BN254 library must be built with cargo before running `zig build`. This is a one-time setup step (or when the Rust code changes).

## Memory Management

All external libraries follow strict memory safety protocols:

- **RAII patterns** with defer/errdefer cleanup
- **Clear ownership semantics** for allocated resources
- **No memory leaks** - every allocation paired with deallocation
- **Error handling** with proper resource cleanup

## Security & Auditing

- **c-kzg-4844**: Security audited by Sigma Prime (June 2023)
- **BLST**: Production-grade BLS12-381 implementation
- **arkworks**: Production-tested cryptographic library
- **Memory safety**: All FFI boundaries carefully managed

## Version Management

| Component | Version | Update Policy |
|-----------|---------|---------------|
| c-kzg-4844 | Latest stable | Track Ethereum Foundation releases |
| BLST | Latest stable | Track official BLST releases |
| arkworks | 0.5.0 | Stable cryptographic primitives |

## Development Notes

### Adding New Dependencies

1. Evaluate necessity - prefer Zig-native solutions when possible
2. Security audit requirements for cryptographic code
3. Memory safety verification for all FFI boundaries
4. Integration with existing build system
5. Documentation and testing requirements

### Debugging External Libraries

- Enable debug symbols for C/Rust components
- Use standard Zig testing and error handling
- Follow TDD practices for any modifications
- Test against known vectors from specifications

### Future Roadmap

#### Completed
- ✅ **Pure Zig BN254**: Complete, production-ready implementation in `src/crypto/bn254/`

#### In Progress
- 🔄 **Pure Zig BLS12-381**: Replace BLST with native Zig implementation
- 🔄 **BLS Wrapper Implementation**: Complete `lib/bls_wrapper.zig` for direct BLST access

#### Planned
- 📋 **Unified API**: Consistent interface for C and Zig implementations
- 📋 **Feature Flags**: Build-time selection of C vs Zig implementations
- 📋 **Performance Parity**: Optimize Zig implementations to match C performance
- 📋 **Pure Zig KZG**: Native implementation to eliminate c-kzg-4844 dependency

---

**Note**: All external dependencies are carefully vetted for security, performance, and compatibility. Changes to this directory should follow the project's security and development protocols outlined in `CLAUDE.md`.
