# Guillotine

A high-performance Ethereum Virtual Machine (EVM) implementation written in Zig.

## Precompiled Contracts

Guillotine implements Ethereum precompiled contracts with different backends optimized for various deployment targets.

### Precompile Status

| Address | Name | Native (x86/ARM) | WASM | Implementation |
|---------|------|------------------|------|----------------|
| `0x01` | ECRECOVER | ✅ | ✅ | Pure Zig |
| `0x02` | SHA256 | ✅ | ✅ | Pure Zig |
| `0x03` | RIPEMD160 | ✅ | ✅ | Pure Zig |
| `0x04` | IDENTITY | ✅ | ✅ | Pure Zig |
| `0x05` | MODEXP | ✅ | ✅ | Pure Zig |
| `0x06` | ECADD | ✅ | ✅ | Pure Zig (BN254) |
| `0x07` | ECMUL | ✅ | ⚠️ | Rust (arkworks) / Placeholder |
| `0x08` | ECPAIRING | ✅ | ⚠️ | Rust (arkworks) / Limited |
| `0x09` | BLAKE2F | ✅ | ✅ | Pure Zig |
| `0x0a` | KZG_POINT_EVALUATION | ✅ | ✅ | Pure Zig |

### Implementation Details

#### BN254 Elliptic Curve Precompiles (0x06-0x08)

**Native Targets (x86, ARM)**:
- **ECADD**: Pure Zig implementation for optimal performance
- **ECMUL**: Rust backend using [arkworks](https://arkworks.rs/) for production-grade scalar multiplication
- **ECPAIRING**: Rust backend using arkworks for bilinear pairing operations

**WASM Target**:
- **ECADD**: ✅ Fully functional pure Zig implementation
- **ECMUL**: ⚠️ Placeholder implementation (returns point at infinity, logs warning)
- **ECPAIRING**: ⚠️ Limited implementation (handles empty input correctly, non-empty returns false)

#### Gas Costs

All precompiles implement correct gas costs for different Ethereum hardforks:
- **Byzantium**: Original gas costs
- **Istanbul**: Reduced gas costs for BN254 operations (EIP-1108)

### WASM Compatibility

The WASM build (3.1M) is production-ready for most use cases:
- ✅ Complete EVM execution engine
- ✅ All standard precompiles
- ✅ Basic cryptographic operations
- ⚠️ Limited zkSNARK support (ECMUL/ECPAIRING)

For applications requiring full BN254 support in WASM, consider:
- Offloading zkSNARK verification to host environment
- Using WASM-compatible cryptographic libraries
- Implementing pure Zig scalar multiplication and pairing

## Prerequisites

- **Zig 0.14.1 or later** (required for fuzzing support on macOS)

## Build Targets

```bash
# Native build (full precompile support)
zig build

# WASM build (limited BN254 precompiles)
zig build wasm

# Run tests
zig build test

# Run fuzzing tests (requires Zig 0.14.1+)
zig build test --fuzz
```

## Architecture

- **Pure Zig**: Core EVM implementation optimized for safety and performance
- **Conditional Compilation**: Different backends based on target architecture
- **Rust Integration**: Production-grade cryptography via arkworks ecosystem
- **Modular Design**: Easy to extend with additional precompiles

## Library Integration

For external projects that want to integrate Guillotine as a library dependency.

### Required Dependencies

#### BN254 Rust Wrapper
Guillotine uses a Rust-based BN254 elliptic curve implementation for production-grade scalar multiplication and pairing operations:

- **Location**: `src/bn254_wrapper/`
- **Dependencies**: arkworks ecosystem (ark-bn254, ark-ec, ark-ff, ark-serialize)
- **Build**: Static library built from Rust using cargo

#### c-kzg-4844
KZG commitment library for EIP-4844 blob transactions:

- **Dependency**: ethereum/c-kzg-4844
- **Purpose**: KZG point evaluation precompile (0x0a)

#### System Libraries

**Linux**:
```
dl, pthread, m, rt
```

**macOS**:
```
Security framework, CoreFoundation framework
```

### Example build.zig Integration

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add Guillotine as dependency
    const guillotine = b.dependency("guillotine", .{
        .target = target,
        .optimize = optimize,
    });

    // Get Guillotine modules
    const evm_mod = guillotine.module("evm");
    const primitives_mod = guillotine.module("primitives");
    
    // Your executable
    const exe = b.addExecutable(.{
        .name = "your-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Link Guillotine modules
    exe.root_module.addImport("evm", evm_mod);
    exe.root_module.addImport("primitives", primitives_mod);
    
    // Link required libraries (automatically handled by Guillotine modules)
    // The bn254_wrapper and c-kzg-4844 libraries are linked automatically
    // when you import the evm module
    
    b.installArtifact(exe);
}
```

### build.zig.zon Configuration

```zig
.{
    .name = "your-project",
    .version = "0.1.0",
    .dependencies = .{
        .guillotine = .{
            .url = "https://github.com/evmts/Guillotine/archive/<commit-hash>.tar.gz",
            .hash = "<hash>",
        },
    },
    .paths = .{""},
}
```

### Minimal Module Usage

For projects that only need specific Guillotine functionality:

```zig
// Use only primitives (Address, Hex, RLP, etc.)
const primitives = b.dependency("guillotine", .{}).module("primitives");
exe.root_module.addImport("primitives", primitives);

// Use only EVM execution (includes all dependencies)
const evm = b.dependency("guillotine", .{}).module("evm");
exe.root_module.addImport("evm", evm);
```

### Integration Notes

1. **Automatic Linking**: When you import the `evm` module, all required libraries (BN254 wrapper, c-kzg-4844, system libraries) are automatically linked.

2. **Cross-Platform**: The build system automatically detects the target platform and links appropriate system libraries (Security/CoreFoundation on macOS, dl/pthread/m/rt on Linux).

3. **WASM Compatibility**: For WASM targets, BN254 operations use placeholder implementations. Full zkSNARK support requires host environment integration.

4. **Memory Management**: All Guillotine operations require an allocator. Use `std.testing.allocator` for tests or your application's allocator for production.

### Troubleshooting

- **Signal 4 (Illegal Instruction)**: Ensure all system libraries are properly linked. This typically occurs when BN254 operations fail due to missing dependencies.
- **Build Failures**: Verify Zig version compatibility (0.14.1+ required) and ensure Rust toolchain is available for BN254 wrapper compilation.
- **Import Errors**: Use the module system rather than direct file imports. Import `evm` and `primitives` modules as shown above.

---

*Guillotine prioritizes correctness, performance, and safety in Ethereum execution.*