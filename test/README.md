# Guillotine Test Suite

This directory contains the comprehensive test infrastructure for the Guillotine EVM implementation, organized into multiple specialized test categories targeting different aspects of EVM functionality.

## Test Organization

### Core Test Categories

```
test/
├── differential/     # Differential testing against REVM reference implementation
├── evm/             # Direct EVM component testing
├── fusion/          # Bytecode fusion and optimization tests
├── fuzz/            # Fuzz testing (macOS only)
├── official/        # Ethereum execution-spec-tests integration
└── *.zig           # Standalone integration tests
```

## Test Categories

### 1. Differential Testing (`differential/`)

**Purpose**: Compare Guillotine execution results against REVM (Rust EVM) reference implementation

**Key Features**:
- Executes identical bytecode on both Guillotine and REVM
- Compares gas usage, execution results, and execution traces
- Detects implementation inconsistencies and correctness bugs
- Comprehensive error reporting with human-readable diffs

**Test Coverage**:
- All EVM opcodes (arithmetic, bitwise, memory, storage, system)
- Gas calculation accuracy
- Stack and memory operations
- Control flow (jumps, calls, returns)
- Error handling and edge cases
- Contract deployment and interaction

**Key Files**:
- `differential_testor.zig` - Main differential testing framework
- `*_test.zig` - Individual opcode and feature tests

**Usage**:
```bash
# Run all differential tests (via root.zig)
zig build test

# Individual tests are imported via test/root.zig
```

### 2. EVM Component Tests (`evm/`)

**Purpose**: Direct unit testing of EVM components

**Coverage**:
- Individual opcode implementations (`opcodes/` - 140+ test files)
- Frame execution and state management
- Memory and storage operations
- Gas calculation components
- Tracing and debugging features

**Structure**:
```
evm/
├── opcodes/        # Per-opcode tests (00_test.zig to ff_test.zig)
├── snailtracer_test.zig  # Execution tracing tests
└── *.zig          # Component-specific tests
```

**Key Features**:
- Each opcode has dedicated test file (e.g., `01_test.zig` for ADD opcode)
- Tests cover normal operation, edge cases, and error conditions
- Integration with differential testing framework

### 3. Fusion Tests (`fusion/`)

**Purpose**: Test bytecode optimization and fusion patterns

**Coverage**:
- Bytecode pattern recognition
- Fusion transformations and optimizations
- Performance benchmarking of fused operations
- Advanced fusion integration tests

**Files**:
- `fusion_benchmark.zig` - Performance testing of fusion optimizations
- `advanced_fusion_integration_test.zig` - Complex fusion scenarios

### 4. Fuzz Testing (`fuzz/`)

**Platform**: **macOS only** (uses `std.testing.fuzzInput`)

**Purpose**: Crash detection and robustness testing with random inputs

**Test Philosophy**:
- **Crash detection, not correctness** - designed to find segfaults, hangs, and assertion failures
- All execution errors are acceptable outcomes
- Focus on boundary conditions and malformed inputs

**Coverage**:
- Random bytecode execution
- Stack operation boundary testing
- Memory expansion edge cases
- Arithmetic overflow/underflow
- Invalid jump destinations
- Gas exhaustion scenarios

**Usage** (macOS only):
```bash
# Run all fuzz tests
zig build test --fuzz

# Run specific fuzz test
zig test test/fuzz/bytecode_fuzz.zig --fuzz

# With specific seed for reproducibility
zig test test/fuzz/bytecode_fuzz.zig --fuzz --seed 12345
```

### 5. Official Ethereum Tests (`official/`)

**Purpose**: Integration with official Ethereum execution-spec-tests

**Version**: v4.5.0 execution-spec-tests fixtures

**Test Types**:
- **State Tests**: Isolated state transition testing
- **Blockchain Tests**: Full block execution testing

**Coverage**:
- All Ethereum hard forks (Frontier → Cancun)
- EIP implementations and edge cases
- Real-world transaction scenarios
- Cross-client compatibility validation

**Structure**:
```
official/
├── fixtures/           # Extracted test fixtures (v4.5.0)
├── state_smoke_test.zig    # State transition test runner
└── blockchain_smoke_test.zig  # Blockchain test runner
```

**Usage**:
```bash
# Run official state tests (non-strict mode)
zig build test-official

# Run with strict post-state validation
zig build test-official-strict

# Run blockchain tests
zig build test-official-blockchain
zig build test-official-blockchain-strict
```

## Build System Integration

### Main Test Commands

```bash
# Run all tests (via test/root.zig)
zig build test

# Run per-opcode differential tests
zig build test-opcodes

# Run official Ethereum tests
zig build test-official
zig build test-official-strict

# Run synthetic opcode tests
zig build test-synthetic
```

### Individual Opcode Testing

Each EVM opcode has individual test targets:

```bash
# Test specific opcodes
zig build test-opcodes-0x01  # ADD opcode
zig build test-opcodes-0x10  # LT opcode
zig build test-opcodes-0xf3  # RETURN opcode
```

## Test Infrastructure

### Core Testing Framework

**DifferentialTestor** (`differential/differential_testor.zig`):
- Primary testing framework comparing Guillotine vs REVM
- Handles contract deployment, execution, and result comparison
- Comprehensive diff generation and error reporting
- Support for both traced and non-traced execution modes

### Test Organization Pattern

**Module System**: All tests use Zig's module system via `zig build test`
- Tests must be imported through build system, not run directly with `zig test`
- Resolves module dependencies (primitives, evm, revm packages)

**Error Handling**: 
- Differential tests fail on implementation mismatches
- Unit tests validate specific component behavior
- Fuzz tests focus on crash prevention, not correctness

### Memory Management

**Allocation Strategy**:
- Tests use `std.testing.allocator` for automatic leak detection
- Proper cleanup with `defer` patterns throughout
- Database and EVM instance lifecycle management

## Writing Tests

### Differential Test Pattern

```zig
const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;

test "differential: your test name" {
    const allocator = std.testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    const bytecode = [_]u8{
        // Your EVM bytecode here
        0x60, 0x01,  // PUSH1 1
        0x60, 0x02,  // PUSH1 2  
        0x01,        // ADD
        0x00,        // STOP
    };
    
    try testor.test_bytecode(&bytecode);
}
```

### Unit Test Pattern

```zig
const std = @import("std");
const evm = @import("evm");

test "unit: component functionality" {
    const allocator = std.testing.allocator;
    
    // Test specific EVM component
    var component = try evm.Component.init(allocator);
    defer component.deinit();
    
    // Test assertions
    try std.testing.expect(component.some_method() == expected_value);
}
```

### Fuzz Test Pattern (macOS only)

```zig
test "fuzz crash detection" {
    const input = std.testing.fuzzInput(.{});
    if (input.len < 4) return;
    
    const allocator = std.testing.allocator;
    
    // Test with random input - all errors are acceptable
    some_evm_operation(input) catch |err| {
        // Fuzz tests focus on crash detection, not correctness
        return;
    };
}
```

## Test Coverage

### Current Status

- **243 total test files** across all categories
- **140+ individual opcode tests** with differential validation
- **50+ differential test scenarios** covering major EVM features
- **Comprehensive official test integration** with Ethereum execution-spec-tests
- **Cross-platform support** (except fuzz tests which require macOS)

### Quality Standards

**Zero Tolerance Policy**:
- No broken builds or test failures
- No stub implementations or commented-out tests
- Immediate fix required for any test regressions
- Evidence-based debugging (no speculation)

**Memory Safety**:
- All allocations tracked with proper cleanup
- Leak detection via `std.testing.allocator`
- Clear ownership patterns for dynamically allocated resources

## Debugging Tests

### Test Failure Investigation

1. **Check test output** - Zig tests are silent when passing
2. **Use differential test error reporting** - comprehensive diffs with context
3. **Enable debug logging** via `log.zig` (never use `std.debug.print`)
4. **Create minimal reproductions** for complex failures
5. **Compare with REVM behavior** for correctness validation

### Common Issues

- **Module import errors**: Ensure using `zig build test`, not direct `zig test`
- **Memory leaks**: Check `defer` cleanup patterns
- **Gas calculation mismatches**: Review EIP-2929 warm/cold access logic
- **Trace divergence**: Compare execution traces between implementations

## Platform Notes

### macOS
- Full test suite support including fuzz testing
- Recommended development platform
- `std.testing.fuzzInput` available

### Linux/Windows
- All tests work except fuzz tests
- Fuzz tests will fail due to macOS-only `std.testing.fuzzInput`
- Consider macOS CI runners for complete test coverage

## CI/CD Integration

```yaml
# GitHub Actions example
- name: Run Core Tests
  run: zig build test

- name: Run Opcode Tests  
  run: zig build test-opcodes

- name: Run Official Tests
  run: zig build test-official

# macOS-only fuzz tests
- name: Run Fuzz Tests
  runs-on: macos-latest
  run: zig build test --fuzz
```

---

For specific details about each test category, see the individual README files in each subdirectory.