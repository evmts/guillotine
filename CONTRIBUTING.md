# Contributing to Guillotine

Thank you so much for you interest in contributing to Guillotine!

We welcome contributions to Guillotine! This document provides guidelines and instructions for contributing to the project.

## Temporary warning

The build is currently set up in a way that causes zig build test to often hang forever. To workaround this for now apply following diff

```
diff --git a/lib/revm/Cargo.toml b/lib/revm/Cargo.toml
index a3661c9b..484ba27a 100644
--- a/lib/revm/Cargo.toml
+++ b/lib/revm/Cargo.toml
@@ -23,13 +23,13 @@ cbindgen = "0.24"

 [profile.release]
 panic = "abort"
-lto = true
-codegen-units = 1
+lto = false
+codegen-units = 16

 [profile.bench]
 panic = "abort"
-lto = true
-codegen-units = 1
+lto = false
+codegen-units = 16

 # [[bin]]
 # name = "verify_lt_order"
```

## AI-Assisted Contributions

**AI-assisted contributions are welcome with proper disclosure.** If you use AI tools (like GitHub Copilot, Claude, ChatGPT, etc.) to generate code:

1. **Disclose AI usage** at the top of your PR description
2. **Include all prompts** used to generate the changes
3. **Provide a human-written description** explaining:
   - Why the change is desired
   - What problem it solves
   - Link to any related issues
4. **Review and understand** all AI-generated code before submitting
5. **Take responsibility** for the correctness and quality of the code

Example PR description:

```
## AI Disclosure
This PR contains AI-generated code using Claude.

### Prompts used:
- "Add error handling for invalid bytecode in the EVM parser"
- "Write tests for the new error cases"

### Human Description:
This change adds proper error handling for malformed bytecode that was causing panics in production. Fixes #123.
```

If your contribution is large please open a discussion to chat about the change before doing the work.

## Code of Conduct

We are committed to providing a welcoming and inclusive environment. All contributors are expected to:

- Be respectful and considerate in all interactions
- Welcome newcomers and help them get started
- Focus on constructive criticism and collaborative problem-solving
- Respect differing viewpoints and experiences

## Project structure

### Source Directory Structure

```
src/
├── _test_utils/         # Testing utilities and fixtures
├── block/               # Block data structures and validation
├── bytecode/            # Bytecode analysis and optimization
├── cli/                 # Command-line interface
├── crypto/              # Cryptographic operations (Keccak, BN254, etc.)
│   └── bn254/          # BN254 elliptic curve operations
├── devtool/            # Development tools and web UI
├── eips_and_hardforks/ # EIP implementations and hardfork configurations
├── frame/              # Execution frame and context management
├── instructions/       # EVM opcode implementations
├── kzg/                # KZG commitment scheme support
├── memory/             # EVM memory management
├── opcodes/            # Opcode definitions and tables
├── precompiles/        # Precompiled contract implementations
├── preprocessor/       # Bytecode preprocessing and optimization
├── primitives/         # Core types (Address, U256, Bytes32, etc.)
├── provider/           # RPC provider interfaces
├── solidity/           # Solidity compiler integration
├── stack/              # EVM stack implementation
├── storage/            # State storage and database interfaces
├── tracer/             # Transaction tracing and debugging
└── trie/               # Merkle Patricia Trie implementation
```

### Build System

```
build/
├── bindings/           # Language bindings generation
├── config.zig          # Build configuration
├── executables/        # Executable targets
├── libraries/          # Library dependencies (BN254, REVM)
├── modules.zig         # Module definitions
├── steps/              # Build step definitions
└── utils.zig           # Build utilities
```

### Key Files

- `src/evm.zig` - Core EVM implementation
- `src/frame/frame.zig` - The most important datastructure in the evm
- `src/instructions/*.zig` - Individual opcode handlers for the evm
- `src/root.zig` - Module root exports
- `build.zig` - Main build configuration

## Getting Started

1. **Fork the repository** on GitHub
2. **Clone your fork** locally:
   ```bash
   git clone https://github.com/YOUR-USERNAME/Guillotine.git
   cd Guillotine
   ```
3. **Add upstream remote**:
   ```bash
   git remote add upstream https://github.com/evmts/Guillotine.git
   ```
4. **Create a feature branch**:
   ```bash
   git checkout -b feature/your-feature-name
   ```

## Development Setup

### Prerequisites

- Zig 0.15.1 or later
- Git
- Rust toolchain (required for ark and revm dependencies)
- Golang and node.js if working with the cli and native app

### Building the Project

#### First-time Setup (Fresh Machine)

When building on a fresh machine or after a fresh clone, you need to initialize submodules:

```bash
# Initialize and update git submodules
git submodule update --init --recursive

# Build the project (Zig automatically runs cargo build for Rust dependencies)
zig build

# Run tests
zig build test
```

**Note**: The Zig build system automatically runs `cargo build` as a dependency step when building Rust libraries. On the first build, this may take longer as Cargo downloads and compiles dependencies.

#### Regular Development

```bash
# Build the project
zig build

# Run tests
zig build test
```

### Development Workflow

1. **Always verify builds**: After any code change, run:
   ```bash
   zig build && zig build test
   ```
2. **Enable debug logging** in tests when needed:
   ```zig
   test {
       std.testing.log_level = .debug;
   }
   ```
