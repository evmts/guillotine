# Contributing to Guillotine

Thank you for your interest in contributing to Guillotine! This document provides guidelines and instructions for contributing to the project.

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
6. **Run all tests**, at least `zig build test-unit` and `zig build test-opcodes` (what CI runs), plus the MinimalEvm differential tests for EVM behavior changes

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
- ✅ Differential tests against MinimalEvm pass
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
- **Critical** changes require differential testing against MinimalEvm (`DifferentialTestor` in `test/differential`, run by `zig build test-integration`)
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
├── block/              # Block info and transaction context
├── bytecode/           # Bytecode analysis, jump validation, stats
├── eips_and_hardforks/ # Hardfork and EIP configuration, system contracts
├── frame/              # Execution frame, call params and results
├── instructions/       # Opcode handlers (handlers_*.zig, *_synthetic.zig)
├── internal/           # Safety counter
├── jit/                # Opt-in native JIT tier (EvmConfig.enable_native_jit)
├── kzg/                # KZG build glue
├── layer2/             # OP Stack and Base rules
├── memory/             # EVM memory
├── opcodes/            # Opcode and synthetic opcode definitions
├── preprocessor/       # Dispatch schedule and jump table construction
├── provider/           # RPC provider and connection pool
├── solidity/           # Solidity test contracts and bytecode
├── stack/              # EVM stack
├── storage/            # Database, journal, access list
├── tracer/             # Tracer and the MinimalEvm reference interpreter
│   ├── minimal_evm.zig       # MinimalEvm, used for differential testing
│   ├── minimal_evm_sync.zig  # Keeps MinimalEvm in step with Frame
│   └── pc_tracker.zig        # Execution flow tracking
└── trie/               # Merkle Patricia Trie
```

Primitives, crypto and the L1 precompiles live in the vendored Voltaire
library under `lib/voltaire/src/` (`primitives/`, `crypto/`, `precompiles/`).

### Build System

There is no `build/` directory. The build is split across:

```
build.zig                # Steps, options, test and spec runners
src/modules.build.zig    # Module graph (evm, primitives, crypto, precompiles, ...)
src/build.zig            # The `run` executable
lib/build.zig            # Rust and C libraries (Foundry, BN254, ...)
bench/bench_step.zig     # `bench`, `bench-build`, `test-bench`
bench/suites_build.zig   # `bench-<suite>` steps
```

### Key Files

- `src/evm.zig` - Core EVM implementation
- `src/frame/frame.zig` - The most important datastructure in the evm
- `src/instructions/*.zig` - Individual opcode handlers for the evm
- `src/tracer/tracer.zig` - Execution tracing and debugging infrastructure
- `src/tracer/minimal_evm.zig` - MinimalEvm, the reference interpreter for differential testing
- `src/preprocessor/dispatch.zig` - Bytecode dispatch optimization
- `src/root.zig` - Module root exports
- `build.zig` - Main build configuration

## Code Quality Standards

### Assertion and Error Handling

- Use the tracer's `assert()` with descriptive messages for runtime validation, for example `(&self.getEvm().tracer).assert(self.stack.size() >= 1, "PUSH_AND_INLINE requires 1 stack item")`
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
   git clone --recursive https://github.com/YOUR-USERNAME/guillotine.git
   cd guillotine
   ```
3. **Add upstream remote**:
   ```bash
   git remote add upstream https://github.com/evmts/guillotine.git
   ```
4. **Create a feature branch**:
   ```bash
   git checkout -b feature/your-feature-name
   ```

## Development Setup

### Prerequisites

- **Zig 0.15.x**: CI uses 0.15.2; `build.zig.zon` requires at least 0.15.1. Zig 0.16 and later have breaking API changes.
- Git
- Rust toolchain with Cargo (stable; `zig build` builds the ark, foundry-compilers and Voltaire crates)
- Bun or Node.js if working on `sdks/typescript` or the docs site

### Building the Project

#### First-time Setup (Fresh Machine)

When building on a fresh machine or after a fresh clone, you need to initialize submodules:

```bash
# Initialize and update git submodules
git submodule update --init --recursive

# Build the project (Zig automatically runs cargo build for Rust dependencies)
zig build

# Run the per-opcode tests (what CI runs after test-unit)
zig build test-opcodes
```

**Note**: The Zig build system automatically runs `cargo build` as a dependency step when building Rust libraries. On the first build, this may take longer as Cargo downloads and compiles dependencies.

#### Regular Development

```bash
# Build the project
zig build

# Run all tests (specs -> integration -> unit; specs need the submodules)
zig build test

# Run specific opcode tests
zig build test-opcodes
```

#### Test Filtering

You can run specific tests using the `-Dtest-filter` option:

```bash
# Run tests matching a specific pattern
zig build test -Dtest-filter='trace validation'

# Run specific opcode tests
zig build test-opcodes -Dtest-filter='ADD opcode'

# Run tests for a specific function
zig build test -Dtest-filter='get_balance'
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
   (&self.getEvm().tracer).assert(condition, "descriptive message");

   // Avoid - no context on failure
   std.debug.assert(condition);
   ```

4. **Test against MinimalEvm** for correctness verification:
   ```bash
   zig build test-integration                         # includes the test/differential suites
   zig build test-integration -Dtest-filter='differential'
   ```

## Troubleshooting

### Common Build Issues

#### Rust Dependency Errors (svm-rs-builds)

If you see errors like `SOLC_VERSION_0_8_31 is defined multiple times`:

```bash
# Update the problematic dependency
cargo update -p svm-rs-builds

# Clean and rebuild
rm -rf target/ .zig-cache/
zig build
```

#### Zig Version Mismatch

If you see errors about `writer` method not found on ArrayList, or other API errors:

```bash
# Check your Zig version
zig version

# Must be 0.15.x (CI uses 0.15.2), NOT 0.16.x
# Use zvm (https://github.com/tristanisham/zvm) to manage versions:
zvm install 0.15.2
zvm use 0.15.2
```

#### Submodule Not Initialized

If specs tests fail to find test files:

```bash
git submodule update --init --recursive
```

#### Cargo Build Fails

Ensure Rust toolchain is installed:

```bash
# Check that Rust and Cargo are installed
rustc --version
cargo --version

# If not installed:
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

### Test Failures

- **Spec failures**: `zig build specs` and `zig build state-tests` still report known failures. Compare with the baselines in [specs/README.md](specs/README.md) before assuming a regression.
- **Memory leak detected**: Check that all allocations have corresponding `defer` cleanup
- **No output from tests**: This is normal - Zig tests only output on failure
