# build/ Directory

## Purpose

The `build/` directory contains build system configuration, scripts, and utilities that support the Zig build process for Guillotine EVM. This is the centralized build configuration system that manages compilation options, executable definitions, library linkage, and build steps.

## Contents

### Core Build Files

- **config.zig** - Build configuration and optimization strategies
- **main.zig** - Main build system entry point
- **modules.zig** - Module dependency management

### Subdirectories

#### executables/

Contains build definitions for various executable targets:

- **benchmarks.zig** - Benchmark executables configuration
- **devtool.zig** - Development tools build configuration
- **evm_runner.zig** - EVM runner executable definition
- **guillotine.zig** - Main Guillotine executable definition

#### libraries/

Contains library build configurations:

- **blst.zig** - BLS signature library configuration
- **bn254.zig** - BN254 elliptic curve library setup
- **c_kzg.zig** - KZG commitment library configuration
- **foundry.zig** - Foundry integration library
- **revm.zig** - REVM comparison library setup

#### steps/

Contains custom build steps and processes

### Configuration System

The build system supports multiple optimization strategies:

- **fast** - Maximum performance compilation
- **small** - Minimum binary size optimization
- **safe** - Balanced approach with safety checks

### Build Options

Key configurable options include:

- EVM parameters (stack size, memory limits, gas limits)
- Feature flags (precompiles, tracing, fusion optimization)
- Library selections (BN254, cryptographic backends)
- Testing and debugging options

## Usage

The build system is used automatically when running:

```bash
# Standard build using build/ configuration
zig build

# Build specific targets defined in executables/
zig build evm-runner
zig build benchmarks

# Build with specific options
zig build -Doptimize=ReleaseFast
zig build -Denable_fusion=true
```

## Key Features

### Modular Design

- Separate configuration files for different executable types
- Reusable library definitions
- Centralized build options management

### Executable Management

- Automated dependency linking
- Target-specific optimization
- Development vs. production configurations

### Library Integration

- External C library linking (blst, c-kzg)
- Zig module dependency management
- Cross-platform compilation support

## Cleaning

The build directory itself doesn't need cleaning as it contains source code. To clean build outputs:

```bash
# Clean generated build artifacts
rm -rf zig-cache/ zig-out/
```

## Rebuilding

Rebuilding happens automatically when:

- Any file in `build/` is modified
- Build configuration changes
- Dependencies are updated

## Important Files

### config.zig

Defines `BuildOptions` struct with all configurable parameters:

- Performance tuning options
- Memory management settings
- Feature toggles
- EVM specification compliance settings

### executables/evm_runner.zig

Core EVM runner build configuration:

- Links all required libraries
- Sets up module imports
- Configures optimization levels

### libraries/

Critical for external dependencies:

- **c_kzg.zig** - KZG polynomial commitment support
- **blst.zig** - BLS12-381 signature operations
- **bn254.zig** - BN254 curve operations for precompiles

## Development Workflow

1. Modify configuration in relevant `.zig` files
2. Run `zig build` to apply changes
3. Use `zig build --help` to see available options
4. Test with `zig build test-opcodes`

## Notes

- This directory is part of the source tree and should be versioned
- Changes here affect all build targets
- Build options are documented in `config.zig`
- Cross-compilation settings are managed through the standard Zig build system
- The build system automatically checks for required submodules and dependencies
