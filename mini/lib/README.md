# Guillotine External Dependencies (`lib/`)

This directory contains external libraries and dependencies required by Guillotine, the high-performance Zig EVM implementation. All dependencies are carefully chosen to support Guillotine's core mission of providing a fast, memory-safe, and correct Ethereum Virtual Machine.

## Overview

The `lib/` directory contains four main dependency categories:
- **Cryptographic libraries** for elliptic curve operations and KZG commitments
- **Reference implementations** for differential testing and validation
- **Compilation infrastructure** for Solidity contract support
- **Performance-critical native libraries** built in Rust

## Dependencies

### 🔐 `c-kzg-4844/` - KZG Polynomial Commitments

**Purpose**: Provides KZG polynomial commitment operations required for EIP-4844 (Proto-Danksharding) and EIP-7594.

**Technology**: C library with Zig bindings
**Version**: Ethereum Foundation official implementation
**License**: Apache-2.0

**Key Features**:
- Blob to KZG commitment conversion
- KZG proof computation and verification
- Batch verification for performance
- EIP-4844 and EIP-7594 compliance
- Embedded trusted setup (807KB when used)
- Dead code elimination for unused features

**Integration**: 
- Used by `src/evm/precompiles` for KZG operations
- Automatically built via `zig build` with blst dependency
- Provides Zig-native API through `lib/c-kzg-4844/bindings/zig/`

**Build Requirements**:
- Git submodule (`git submodule update --init --recursive`)
- Trusted setup file (auto-downloaded from Ethereum Foundation)

### 🧮 `ark/` - BN254 Elliptic Curve Operations

**Purpose**: Production-grade BN254 elliptic curve implementation for EVM precompiles 0x06 (ECADD), 0x07 (ECMUL), and 0x08 (ECPAIRING).

**Technology**: Rust wrapper around arkworks ecosystem
**Dependencies**: ark-bn254, ark-ec, ark-ff, ark-serialize
**License**: MIT

**Key Features**:
- Scalar multiplication and pairing operations
- Memory-safe FFI bindings
- WASM-compatible placeholder implementations
- Production-tested cryptographic primitives

**Integration**:
- Linked via Rust build system in `Cargo.toml` workspace
- Used by `src/crypto` and `src/evm/precompiles`
- C header generation via cbindgen

**Future**: Planned replacement with pure Zig implementation to eliminate Rust dependency.

### 🔄 `revm/` - Reference EVM for Differential Testing

**Purpose**: Rust Ethereum Virtual Machine used as a reference implementation for differential testing and validation.

**Technology**: Rust library (revm 14.0)
**Dependencies**: revm-primitives 10.0, alloy-primitives 0.8
**License**: MIT

**Key Features**:
- Complete EVM implementation in Rust
- Serves as oracle for differential testing
- High-performance assembly-optimized KECCAK256
- Shared cryptographic dependencies with other components

**Integration**:
- Used in `test/differential/` for validating Guillotine behavior
- Built as static library via Cargo workspace
- C FFI bindings generated via cbindgen
- Accessed through `lib/revm/revm.zig`

**Testing**: Critical for ensuring Guillotine correctness against established reference.

### ⚙️ `foundry-compilers/` - Solidity Compilation Infrastructure

**Purpose**: Seamless Solidity compilation integration for contract deployment and testing.

**Technology**: Zig wrapper around Foundry's compiler infrastructure
**Dependencies**: foundry-compilers (Rust), zabi (Zig ABI parsing)
**License**: MIT

**Key Features**:
- Full Solidity compilation support
- In-memory and file-based compilation
- Strongly typed ABI parsing with compile-time safety
- Automatic Solc version management
- Caching support for improved performance
- Production-ready API design

**Integration**:
- Three-layer architecture: Rust → C bindings → Zig API
- Used by testing infrastructure and development tools
- Automatic zabi integration for type-safe ABI handling

**API Highlights**:
```zig
var result = try Compiler.compileSource(allocator, "contract.sol", source, settings);
defer result.deinit();

// Strongly typed ABI access
for (result.contracts[0].abi) |item| {
    switch (item) {
        .abiFunction => |func| // Type-safe function metadata
    }
}
```

## Build System Integration

### Cargo Workspace Configuration

All Rust dependencies are managed through a unified workspace in the root `Cargo.toml`:

```toml
[workspace]
members = ["lib/foundry-compilers", "lib/ark", "lib/revm"]

[workspace.dependencies]
revm = { version = "14.0", features = ["c-kzg", "blst", "std", "serde"] }
revm-primitives = "10.0"
alloy-primitives = "0.8"
# Arkworks dependencies
ark-bn254 = "0.5.0"
ark-ec = "0.5.0"
ark-ff = "0.5.0"
ark-serialize = "0.5.0"
ark-bls12-381 = "0.5.0"
```

### Zig Build Integration

The main `build.zig` orchestrates all dependencies:

1. **Submodule Verification**: Ensures c-kzg-4844 submodule is initialized
2. **Library Creation**: Creates static libraries for each Rust component
3. **Module Wiring**: Provides unified module imports for Guillotine
4. **Asset Generation**: Handles trusted setup and binding generation

### Build Commands

```bash
# Standard build (includes all dependencies)
zig build

# Test with differential validation
zig build test-opcodes

# Build individual components
zig build test-foundry  # Test Solidity compilation
```

## Memory Management

All external libraries follow Guillotine's strict memory safety protocols:

- **RAII patterns** with defer/errdefer cleanup
- **Clear ownership semantics** for allocated resources  
- **No memory leaks** - every allocation paired with deallocation
- **Error handling** with proper resource cleanup on failure paths

## Performance Considerations

- **Static linking** preferred for better optimization
- **LTO enabled** for cross-library optimization
- **Assembly optimizations** in critical paths (KECCAK256)
- **Dead code elimination** for unused library features
- **Caching support** where applicable (Solidity compilation)

## Security & Auditing

- **c-kzg-4844**: Security audited by Sigma Prime (June 2023)
- **arkworks**: Production-tested cryptographic library
- **revm**: Established reference implementation with extensive testing
- **Memory safety**: All FFI boundaries carefully managed

## Version Management

| Component | Version | Update Policy |
|-----------|---------|---------------|
| c-kzg-4844 | Latest stable | Track Ethereum Foundation releases |
| revm | 14.0 | Update with EVM specification changes |
| arkworks | 0.5.0 | Stable cryptographic primitives |
| foundry-compilers | Latest | Track Foundry ecosystem updates |

## Development Notes

### Adding New Dependencies

1. Evaluate necessity - prefer Zig-native solutions
2. Security audit requirements for cryptographic code  
3. Memory safety verification for all FFI boundaries
4. Integration with existing build system
5. Documentation and testing requirements

### Debugging External Libraries

- Use `test/differential/` for revm-based validation
- Enable debug symbols in Cargo.toml for Rust components
- Leverage Guillotine's logging system (`log.zig`) instead of native print statements
- Follow TDD practices for any modifications

### Future Roadmap

- **Pure Zig cryptography**: Replace Rust dependencies with native Zig implementations
- **WASM optimization**: Improve browser compatibility
- **Performance benchmarking**: Continuous performance monitoring
- **Security hardening**: Regular dependency audits and updates

---

**Note**: All external dependencies are carefully vetted for security, performance, and compatibility with Guillotine's architecture. Changes to this directory should follow the project's security and development protocols outlined in `CLAUDE.md`.