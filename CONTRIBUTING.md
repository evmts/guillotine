# Contributing to Guillotine

Thank you so much for you interest in contributing to Guillotine!

We welcome contributions to Guillotine! This document provides guidelines and instructions for contributing to the project.

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
6. **Run all tests** including differential tests against revm/MinimalEvm

Example PR description:

```
## AI Disclosure
This PR contains AI-generated code using Claude.

### Prompts used:
- "Add error handling for invalid bytecode in the EVM parser"
- "Write tests for the new error cases"

### Human Description:
This change adds proper error handling for malformed bytecode that was causing panics in production. Fixes #123.

### Testing:
- ✅ zig build test-opcodes passes
- ✅ Differential tests against revm pass
- ✅ No performance regression in benchmarks
```

If your contribution is large please open a discussion to chat about the change before doing the work.

## Critical Safety Requirements

**⚠️ WARNING: This is mission-critical financial infrastructure.** ANY bug can result in catastrophic loss of funds. Please follow these requirements:

### Zero Tolerance Policy

- ❌ **NO** broken builds or failing tests
- ❌ **NO** stub implementations (`error.NotImplemented`)
- ❌ **NO** commented-out code (use Git for history)
- ❌ **NO** `std.debug.print` in production code (use `log.zig`)
- ❌ **NO** skipping tests or disabling problematic code

### Memory Safety

- **Always** pair allocations with `defer` or `errdefer`
- **Always** validate memory bounds before access
- **Always** zero-initialize expanded memory regions
- **Never** leak memory - proper cleanup is mandatory

### Testing Requirements

- **Every** code change must pass `zig build test-opcodes`
- **Critical** changes require differential testing against revm
- **Gas costs** must match Yellow Paper specification exactly
- **Stack operations** must validate depth before execution

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
├── internal/           # Internal utilities (safety counters, etc.)
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
│   ├── MinimalEvm.zig  # Standalone 65KB EVM for testing
│   └── pc_tracker.zig  # Execution flow tracking
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
└── steps/              # Build step definitions
```

### Key Files

- `src/evm.zig` - Core EVM implementation
- `src/frame/frame.zig` - The most important datastructure in the evm
- `src/instructions/*.zig` - Individual opcode handlers for the evm
- `src/tracer/tracer.zig` - Execution tracing and debugging infrastructure
- `src/tracer/MinimalEvm.zig` - Standalone EVM for differential testing
- `src/preprocessor/dispatch.zig` - Bytecode dispatch optimization
- `src/root.zig` - Module root exports
- `build.zig` - Main build configuration

## Code Quality Standards

### Assertion and Error Handling

- Use `tracer.assert()` with descriptive messages for runtime validation
- Provide clear error messages that help debugging
- Handle all error cases explicitly - no silent failures
- Use `errdefer` for cleanup on error paths

### Documentation

- Each module should have a CLAUDE.md file documenting:
  - Mission-critical aspects
  - Implementation details
  - Safety requirements
  - Testing guidelines
- Keep documentation close to code for maintainability

### Performance Considerations

- Use `_unsafe` operations only after validation
- Implement tail call optimization for opcode dispatch
- Cache frequently accessed data
- Profile before optimizing

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

# Run tests (use test-opcodes to avoid hanging issues)
zig build test-opcodes
```

**Note**: The Zig build system automatically runs `cargo build` as a dependency step when building Rust libraries. On the first build, this may take longer as Cargo downloads and compiles dependencies.

#### Regular Development

```bash
# Build the project
zig build

# Run tests
zig build test-opcodes
```

### Development Workflow

1. **Always verify builds**: After any code change, run:
   ```bash
   zig build && zig build test-opcodes
   ```
2. **Enable debug logging** in tests when needed:
   ```zig
   test {
       std.testing.log_level = .debug;
   }
   ```
3. **Use tracer assertions** for debugging instead of `std.debug.assert`:

   ```zig
   // Good - provides context on failure
   self.getTracer().assert(condition, "descriptive message");

   // Avoid - no context on failure
   std.debug.assert(condition);
   ```

4. **Test against MinimalEvm** for correctness verification:
   ```bash
   zig build test-snailtracer  # Differential testing
   ```
