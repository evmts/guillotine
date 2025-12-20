# Test Helpers Quick Start Guide

## Overview

The test helpers provide reusable fixtures for testing EVM instruction handlers in `guillotine-mini`.

**Files:**
- `test_helpers.zig` - Core testing infrastructure
- `test_helpers_examples.test.zig` - 40+ example tests demonstrating usage

## Quick Start

### Basic Test Template

```zig
const std = @import("std");
const testing = std.testing;
const test_helpers = @import("test_helpers.zig");
const TestHelper = test_helpers.TestHelper;

test "my instruction test" {
    // 1. Initialize helper
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    // 2. Setup pre-conditions
    try helper.pushStack(10);
    try helper.pushStack(20);

    // 3. Execute instruction
    try MyHandler.myInstruction(helper.frame);

    // 4. Assert post-conditions
    try helper.assertStackTop(30);
    try helper.assertGasConsumed(3);
}
```

## Common Patterns

### Stack Operations

```zig
// Push values
try helper.pushStack(42);
try helper.pushStackSlice(&[_]u256{ 10, 20, 30 }); // 30 is top

// Read values
const top = try helper.peekStack(0); // Don't pop
const val = try helper.popStack(); // Remove from stack

// Assert stack state
try helper.assertStackTop(42);
try helper.assertStackAt(1, 20); // Second from top
try helper.assertStackSize(3);
try helper.assertStackEquals(&[_]u256{ 30, 20, 10 }); // Top to bottom
```

### Memory Operations

```zig
// Write memory
try helper.writeMemory(0, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });

// Read memory
const data = try helper.readMemory(0, 4);
defer helper.allocator.free(data);

// Assert memory
try helper.assertMemoryByte(0, 0xDE);
try helper.assertMemoryEquals(0, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });
try helper.assertMemorySize(4);
```

### Storage Operations

```zig
// Persistent storage
try helper.setStorage(0x42, 0x1234);
try helper.assertStorage(0x42, 0x1234);

// Transient storage (EIP-1153, Cancun+)
helper.withHardfork(.CANCUN);
try helper.setTransientStorage(0x100, 0xABCD);
try helper.assertTransientStorage(0x100, 0xABCD);
```

### Gas Tracking

```zig
// Assert gas usage
try helper.assertGasConsumed(3); // Exact amount
try helper.assertGasRemaining(999_997);
try helper.assertGasConsumedAtLeast(3); // Minimum amount
```

### Configuration (Builder Pattern)

```zig
// Hardfork
helper.withHardfork(.CANCUN);
helper.withHardfork(.BERLIN);

// Execution context
helper.withCaller(TestAddresses.caller);
helper.withAddress(TestAddresses.contract);
helper.withValue(1000); // Wei value
helper.withGas(100_000);
helper.withStaticCall(true);

// Bytecode
try helper.withBytecode(&[_]u8{ 0x60, 0x42 }); // PUSH1 0x42

// Calldata
const calldata = &[_]u8{ 0x01, 0x02, 0x03 };
helper.withCalldata(calldata);
```

### State Setup

```zig
const addr = test_helpers.testAddress(0x1234);

try helper.setBalance(addr, 5000);
try helper.setNonce(addr, 10);
try helper.setCode(addr, &[_]u8{ 0x60, 0x00 });

// Verify state
try testing.expectEqual(@as(u256, 5000), helper.getBalance(addr));
try testing.expectEqual(@as(u64, 10), helper.getNonce(addr));
```

### Error Testing

```zig
// Expect specific error
try testing.expectError(
    error.StackUnderflow,
    MyHandler.myInstruction(helper.frame)
);

// Verify no error occurred
try testing.expect(!helper.frame.stopped);
try testing.expect(!helper.frame.reverted);
```

## Pre-defined Test Addresses

```zig
const TestAddresses = test_helpers.TestAddresses;

TestAddresses.zero                  // 0x0000000000000000000000000000000000000000
TestAddresses.caller                // 0x00000000000000000000000000000000CA11E4
TestAddresses.contract              // 0x0000000000000000000000000000000C047AC7
TestAddresses.other                 // 0x000000000000000000000000000000000007BE4
TestAddresses.precompile_ecrecover  // 0x0000000000000000000000000000000000000001
TestAddresses.precompile_sha256     // 0x0000000000000000000000000000000000000002
TestAddresses.precompile_ripemd160  // 0x0000000000000000000000000000000000000003
TestAddresses.precompile_identity   // 0x0000000000000000000000000000000000000004
```

## Utility Functions

```zig
// Create address from u256
const addr = test_helpers.testAddress(0x1234);

// Convert hex string to bytecode
const code = try test_helpers.bytecodeFromHex(
    testing.allocator,
    "60426000526001601ff3"
);
defer testing.allocator.free(code);
```

## Complete Example

```zig
test "SSTORE and SLOAD integration" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    // Configure hardfork for EIP-2929 (warm/cold access)
    helper.withHardfork(.BERLIN);

    const slot = 0x42;
    const value = 0x1234;

    // SSTORE: store value
    try helper.pushStack(value);
    try helper.pushStack(slot);
    try StorageHandlers.sstore(helper.frame);

    // Verify storage state
    try helper.assertStorage(slot, value);

    // SLOAD: load value
    try helper.pushStack(slot);
    try StorageHandlers.sload(helper.frame);

    // Verify result on stack
    try helper.assertStackTop(value);

    // Verify gas accounting (cold access)
    const expected_gas = GasConstants.ColdSloadCost
                       + GasConstants.SstoreSetGas;
    try helper.assertGasConsumedAtLeast(expected_gas);
}
```

## Handler Instantiation

To test instruction handlers, you need to instantiate them with your TestFrameType:

```zig
const TestFrameType = test_helpers.TestFrameType;
const ArithmeticHandlers = handlers_arithmetic.Handlers(TestFrameType);
const MemoryHandlers = handlers_memory.Handlers(TestFrameType);
const StorageHandlers = handlers_storage.Handlers(TestFrameType);
// etc.
```

## Running Tests

```bash
# Run all tests
zig build test

# Run with specific filter (not implemented yet for test_helpers)
# Use test names: "example:", "TestHelper"
```

## Tips

1. **Always defer cleanup**: `defer helper.deinit();`
2. **Use builder methods**: Chain `withX` methods for readable setup
3. **Test gas consumption**: Verify both functionality AND gas costs
4. **Test error cases**: Don't just test happy paths
5. **Test hardfork transitions**: Use `withHardfork` to test fork-specific behavior
6. **Leverage examples**: See `test_helpers_examples.test.zig` for 40+ examples

## See Also

- `test_helpers.zig` - Full API documentation
- `test_helpers_examples.test.zig` - 40+ working examples
- `handlers_*.zig` - Instruction handler implementations to test
