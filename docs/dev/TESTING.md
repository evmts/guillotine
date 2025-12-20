# Testing

This document covers test organization, running tests, and debugging test failures.

## Test Categories

### Unit Tests

Module-specific tests embedded in source files:

```bash
# Run all unit tests
zig build test-unit

# Performance EVM
# Tests in src/**/*.zig

# Mini EVM
# Tests in mini/src/**/*.zig
```

### Integration Tests

Cross-module testing:

```bash
# Run integration tests
zig build test-integration

# Located in test/**/*.zig
```

### Spec Tests

Ethereum execution specification compliance:

```bash
# Run all spec tests
zig build specs

# Mini EVM specs
cd mini && zig build specs
```

### Differential Tests

Compare against reference implementations:

```bash
# Run differential tests
zig build test-opcodes

# Run snailtracer benchmark
zig build test-snailtracer
```

## Running Tests

### Basic Commands

```bash
# Build project
zig build

# Run all tests (specs → integration → unit)
zig build test

# Run specific test category
zig build test-unit
zig build test-integration
zig build specs
```

### Filtering Tests

```bash
# Filter by name pattern
zig build test-unit -Dtest-filter='stack'
zig build test-integration -Dtest-filter='ADD opcode'
zig build specs -Dtest-filter='Cancun'

# Mini EVM filtering
cd mini
zig build specs -Dtest-filter='transientStorage'
```

### Hardfork-Specific Tests

```bash
# Performance EVM
zig build -Devm-hardfork=CANCUN
zig build test -Devm-hardfork=SHANGHAI

# Mini EVM granular targets
zig build specs-cancun-tstore-basic
zig build specs-cancun-mcopy
zig build specs-shanghai-push0
zig build specs-berlin-acl
```

## Test Organization

### Performance EVM Test Structure

```
test/
├── evm/                    # Full EVM execution tests
│   ├── access_list_test.zig
│   ├── erc20_deploy_test.zig
│   ├── transfer_test.zig
│   └── snailtracer_test.zig
├── differential/           # Comparison with revm
│   ├── math_ops_test.zig
│   ├── stack_ops_test.zig
│   ├── storage_ops_test.zig
│   └── precompiles_test.zig
├── fusion/                 # Opcode fusion tests
├── fuzz/                   # Fuzz testing
├── eips_and_hardforks/     # EIP-specific tests
├── execution-spec-tests/   # Ethereum spec tests
└── official/               # Official Ethereum tests
```

### Mini EVM Test Structure

```
mini/test/
├── specs/
│   ├── runner.zig          # Test runner infrastructure
│   ├── test_host.zig       # Mock host implementation
│   └── assembler.zig       # Bytecode assembly
└── unit_test_helpers.zig   # Test utilities
```

## Debugging Tests

### Isolating Failures

```bash
# Mini EVM: Isolate a specific test
cd mini
bun scripts/isolate-test.ts "exact_test_name"
```

This provides:
- Maximum debug output
- Automatic failure type detection
- Trace divergence analysis
- Next-step guidance

### Trace Comparison

```bash
# Generate trace
TEST_FILTER="test_name" zig build specs

# Output shows:
# - Step number
# - PC
# - Opcode
# - Gas remaining
# - Stack state
```

### Common Failure Types

1. **Gas Mismatch**
   - Check gas calculation order
   - Verify cold/warm access
   - Check refund calculations

2. **Stack Mismatch**
   - Verify LIFO order (pop = top)
   - Check underflow/overflow
   - Verify DUP/SWAP indices

3. **Invalid Jump**
   - Check JUMPDEST analysis
   - Verify jump target is valid
   - Check PUSH data skipping

4. **Storage Mismatch**
   - Verify original vs current tracking
   - Check transient storage handling
   - Verify snapshot/restore

### Debug Logging

```zig
// Enable in tests
test {
    std.testing.log_level = .debug;
}

// Note: Passing tests produce NO output
// Only failures show output
```

### Using the Tracer

```zig
// Tracer syncs Frame with MinimalEvm
// In Debug/ReleaseSafe builds:
self.beforeInstruction(.ADD, cursor);  // Validates state

// On divergence:
// "Execution divergence at step N: Stack size mismatch"
```

## Helper Scripts

### Mini EVM Scripts

```bash
# Isolate test with maximum debug
bun scripts/isolate-test.ts "test_name"

# Run test subset
bun scripts/test-subset.ts Cancun
bun scripts/test-subset.ts transientStorage

# Automated spec fixer
bun scripts/fix-specs.ts
bun scripts/fix-specs.ts suite shanghai-push0
```

## Writing Tests

### Unit Test Pattern

```zig
// In source file
test "ADD correctly adds two values" {
    var frame = try TestFrame.init(testing.allocator);
    defer frame.deinit();

    try frame.pushStack(5);
    try frame.pushStack(3);
    try ArithmeticHandlers.add(&frame);

    try testing.expectEqual(@as(u256, 8), frame.stack.items[0]);
}
```

### Integration Test Pattern

```zig
// In test/**/*.zig
test "ERC20 transfer executes correctly" {
    var evm = try TestEvm.init(testing.allocator);
    defer evm.deinit();

    // Set up contract
    try evm.setCode(contract_address, erc20_bytecode);
    try evm.setBalance(sender, 1000);

    // Execute transfer
    const result = try evm.call(.{
        .caller = sender,
        .address = contract_address,
        .calldata = transfer_calldata,
        .gas = 100000,
    });

    try testing.expect(result.success);
    try testing.expectEqual(@as(u256, 100), evm.balanceOf(recipient));
}
```

### Differential Test Pattern

```zig
test "ADD matches revm implementation" {
    // Execute in Guillotine
    var frame = try Frame.init(allocator, bytecode, gas, ...);
    const guillotine_result = try frame.execute();

    // Execute in revm (via FFI)
    const revm_result = revm.execute(bytecode, gas);

    // Compare
    try testing.expectEqual(guillotine_result.gas_used, revm_result.gas_used);
    try testing.expectEqualSlices(u8, guillotine_result.output, revm_result.output);
}
```

## Spec Test Infrastructure

### Test Generation

Mini EVM generates Zig tests from JSON fixtures:

```bash
# Fixtures from execution-specs
cd mini
python generate_tests.py
```

### Test Format

```zig
// Generated test
test "stTransientStorage_Cancun_TSTORE_basic" {
    const fixture = @embedFile("fixtures/cancun/tstore_basic.json");
    try runJsonTest(fixture);
}
```

### Running Spec Targets

```bash
# Full hardfork
zig build specs-cancun

# Specific EIP
zig build specs-cancun-tstore-basic
zig build specs-cancun-mcopy

# Category
zig build specs-frontier-precompiles
zig build specs-berlin-acl
```

## Continuous Integration

### Test Commands for CI

```bash
# Full test suite
zig build test

# With specific optimization
zig build test -Doptimize=ReleaseSafe

# Coverage (if supported)
zig build test -Dcoverage
```

### Expected Results

- **Passing**: No output
- **Failing**: Error message with location
- **Timeout**: Likely infinite loop

## Debugging Workflow

```bash
# 1. Find failures
zig build specs

# 2. Filter to specific test
zig build specs -Dtest-filter='failing_test_name'

# 3. For Mini: Use isolate script
bun scripts/isolate-test.ts "failing_test_name"

# 4. Review trace output
# Look for divergence point: PC, opcode, gas, stack

# 5. Find Python reference
cd execution-specs/src/ethereum/forks/cancun/vm/instructions/
grep -r "def <opcode_name>" .

# 6. Compare implementations
# Check handler in src/instructions/handlers_*.zig

# 7. Fix and verify
zig build specs -Dtest-filter='failing_test_name'
```

## Test Configuration

### Build Options

```bash
# Hardfork selection
-Devm-hardfork=CANCUN

# Disable gas checks (testing only)
-Devm-disable-gas=true

# Enable/disable fusion
-Devm-enable-fusion=true

# Optimization strategy
-Devm-optimize=safe
```

### Test Timeouts

```zig
// Safety counter prevents infinite loops
const LOOP_QUOTA: u64 = 300_000_000;
```
