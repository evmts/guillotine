# Contributing to Guillotine

We welcome contributions to Guillotine! This document provides guidelines and instructions for contributing to the project.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Coding Standards](#coding-standards)
- [Testing Philosophy](#testing-philosophy)
- [Memory Management](#memory-management)
- [Submitting Changes](#submitting-changes)
- [Issue Guidelines](#issue-guidelines)
- [Review Process](#review-process)

## Code of Conduct

We are committed to providing a welcoming and inclusive environment. All contributors are expected to:

- Be respectful and considerate in all interactions
- Welcome newcomers and help them get started
- Focus on constructive criticism and collaborative problem-solving
- Respect differing viewpoints and experiences

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

- Zig 0.14.1 or later
- Git
- Rust toolchain (required for BN254 and REVM dependencies)
- Cargo for building Rust dependencies

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

# Run EVM comparison benchmarks
zig build bench-compare

# Run official EVM benchmarks (hyperfine required)
zig build build-evm-runner  # Build the benchmark runner
# Then use hyperfine to benchmark specific test cases:
hyperfine --runs 10 \
  "zig-out/bin/evm-runner --contract-code-path bench/official/cases/ten-thousand-hashes/bytecode.txt --calldata 0x30627b7c"
```

### Development Workflow

1. **Always verify builds**: After any code change, run:
   ```bash
   zig build && zig build test
   ```
   
2. **Enable debug logging** in tests when needed:
   ```zig
   test {
       std.testing.log_level = .warn;
   }
   ```

## Coding Standards

### Core Principles

1. **Single Responsibility**: Keep functions focused on one task
2. **Minimal else statements**: Avoid else statements unless necessary
3. **Single word variables**: Prefer concise names (`n` over `number`, `i` over `index`)
4. **camelCase naming**: Use camelCase for all identifiers
5. **Tests in source files**: Include tests in the same file as the implementation

### Code Style Examples

```zig
// Good - single responsibility, no else
pub fn validate(n: u256) !void {
    if (n > MAX_VALUE) return error.Overflow;
    if (n == 0) return error.Zero;
}

// Bad - unnecessary else
pub fn validate(number: u256) !void {
    if (number > MAX_VALUE) {
        return error.Overflow;
    } else {
        // unnecessary else
    }
}
```

### Import Rules

- Use module imports from `build.zig`
- No relative imports with `../`
- Direct imports without aliases:
  ```zig
  // Good
  const Address = @import("primitives").Address;
  
  // Bad
  const addr = @import("primitives").Address;
  ```

## Testing Philosophy

### No Abstractions in Tests

Tests should be self-contained with zero abstractions:

- **No test helper functions** - Copy setup code directly
- **No shared utilities** - Each test is independent
- **Explicit over DRY** - Clarity trumps reusability in tests

### Test Structure Example

```zig
test "ADD opcode adds two values" {
    const allocator = std.testing.allocator;
    
    // Complete setup inline
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Test implementation...
}
```

### Testing Requirements

- All new code must include tests
- Tests must pass before submitting PR
- Use descriptive test names
- Test edge cases and error conditions

## Memory Management

### Critical Rules

1. **Every allocation needs deallocation**:
   ```zig
   const thing = try allocator.create(Thing);
   defer allocator.destroy(thing);
   ```

2. **Use defer patterns**:
   ```zig
   // Pattern 1: Same scope cleanup
   const data = try allocator.alloc(u8, size);
   defer allocator.free(data);
   
   // Pattern 2: Error handling before ownership transfer
   const thing = try allocator.create(Thing);
   errdefer allocator.destroy(thing);
   ```

3. **Think about ownership**: Always be clear about who owns allocated memory

### EVM-Specific Patterns

```zig
// Always use defer after init
var vm = try Evm.init(allocator, db_interface);
defer vm.deinit();

var frame = try Frame.init(allocator, &vm, gas, contract, caller, input);
defer frame.deinit();
```

## Submitting Changes

### Commit Messages

Write clear, descriptive commit messages:
- Start with a verb (add, fix, update, refactor)
- Keep the first line under 72 characters
- Reference issue numbers when applicable

Examples:
```
fix: correct gas calculation for SSTORE opcode

add: implement PUSH0 opcode for Shanghai fork

refactor: simplify stack validation logic
```

### Pull Request Process

1. **Update your fork**:
   ```bash
   git fetch upstream
   git rebase upstream/main
   ```

2. **Ensure all tests pass**:
   ```bash
   zig build && zig build test
   ```

3. **Create pull request**:
   - Use a descriptive title
   - Reference related issues
   - Describe what changes were made and why
   - Include test results

### PR Checklist

Before submitting:
- [ ] Code follows project style guidelines
- [ ] All tests pass
- [ ] New code includes tests
- [ ] Memory is properly managed
- [ ] Documentation is updated if needed
- [ ] Commit messages are clear

## Issue Guidelines

### Reporting Bugs

Include:
- Zig version
- Operating system
- Steps to reproduce
- Expected vs actual behavior
- Error messages or logs

### Feature Requests

Describe:
- The problem you're trying to solve
- Your proposed solution
- Alternative approaches considered
- Impact on existing functionality

## Benchmarking

### Official EVM Benchmarks

The `bench/official` directory contains standardized EVM benchmarks for performance testing:

#### Available Test Cases
- `erc20-approval-transfer` - ERC20 approval and transfer operations
- `erc20-mint` - ERC20 token minting
- `erc20-transfer` - Basic ERC20 transfers
- `snailtracer` - Complex computation benchmark
- `ten-thousand-hashes` - Hash-intensive operations (keccak256)

#### Running Benchmarks

1. **Install hyperfine** (required for statistical benchmarking):
   ```bash
   # macOS
   brew install hyperfine
   
   # Linux/WSL
   cargo install hyperfine
   ```

2. **Build the benchmark runner**:
   ```bash
   zig build build-evm-runner
   ```

3. **Run individual benchmarks**:
   ```bash
   # Example: ten-thousand-hashes benchmark
   hyperfine --runs 10 --warmup 3 \
     "zig-out/bin/evm-runner --contract-code-path bench/official/cases/ten-thousand-hashes/bytecode.txt --calldata 0x30627b7c"
   ```

4. **Run all benchmarks** (work in progress):
   ```bash
   # The orchestrator at bench/official/src/main.zig will eventually automate this
   zig-out/bin/evm-runner --help  # See available options
   ```

#### Benchmark Structure
- Test cases are in `bench/official/cases/`
- Each case contains:
  - `bytecode.txt` - Contract bytecode in hex format
  - `calldata.txt` - Input data for contract calls
- The runner deploys the contract and executes it with the provided calldata

## Review Process

### What to Expect

- Constructive feedback on code quality
- Suggestions for improvements
- Questions about design decisions
- Request for additional tests or documentation

### Review Timeline

- Initial review within 3-5 days
- Follow-up responses within 24-48 hours
- PRs are typically merged within a week of approval

### After Approval

Once approved:
1. Squash commits if requested
2. Ensure branch is up to date with main
3. Wait for maintainer to merge

## Getting Help

- Open an issue for questions
- Join community discussions
- Review existing PRs for examples
- Check CLAUDE.md for AI-assisted development guidelines

## Recognition

Contributors are recognized in:
- GitHub contributors page
- Release notes for significant contributions
- Project documentation where appropriate

Thank you for contributing to Guillotine!