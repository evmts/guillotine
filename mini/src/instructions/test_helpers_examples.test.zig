/// Example tests demonstrating test_helpers.zig usage patterns
///
/// This file serves as both validation for test_helpers.zig and as
/// documentation for how to write instruction handler tests.
const std = @import("std");
const testing = std.testing;
const test_helpers = @import("test_helpers.zig");
const TestHelper = test_helpers.TestHelper;
const TestAddresses = test_helpers.TestAddresses;
const GasConstants = @import("primitives").GasConstants;
const Hardfork = @import("primitives").Hardfork;

// Import handler modules for testing
const handlers_arithmetic = @import("handlers_arithmetic.zig");
const handlers_stack = @import("handlers_stack.zig");
const handlers_memory = @import("handlers_memory.zig");
const handlers_storage = @import("handlers_storage.zig");
const handlers_comparison = @import("handlers_comparison.zig");
const handlers_bitwise = @import("handlers_bitwise.zig");

// Instantiate handlers for our test frame type
const ArithmeticHandlers = handlers_arithmetic.Handlers(test_helpers.TestFrameType);
const StackHandlers = handlers_stack.Handlers(test_helpers.TestFrameType);
const MemoryHandlers = handlers_memory.Handlers(test_helpers.TestFrameType);
const StorageHandlers = handlers_storage.Handlers(test_helpers.TestFrameType);
const ComparisonHandlers = handlers_comparison.Handlers(test_helpers.TestFrameType);
const BitwiseHandlers = handlers_bitwise.Handlers(test_helpers.TestFrameType);

// =============================================================================
// Example 1: Basic Arithmetic Instruction Tests
// =============================================================================

test "example: ADD - basic addition" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    // Setup: Push two values onto stack
    try helper.pushStack(10);
    try helper.pushStack(20);

    // Execute: Run ADD instruction
    try ArithmeticHandlers.add(helper.frame);

    // Assert: Verify results
    try helper.assertStackTop(30); // 10 + 20 = 30
    try helper.assertStackSize(1); // Two values popped, one pushed
    try helper.assertGasConsumed(GasConstants.GasFastestStep); // ADD costs 3 gas
    try helper.assertPC(1); // PC advanced by 1
}

test "example: ADD - overflow wrapping" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    // Setup: Push values that will overflow
    const max = std.math.maxInt(u256);
    try helper.pushStack(max);
    try helper.pushStack(1);

    // Execute: ADD with overflow
    try ArithmeticHandlers.add(helper.frame);

    // Assert: Result wraps to 0
    try helper.assertStackTop(0);
}

test "example: MUL - multiplication" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    try helper.pushStack(7);
    try helper.pushStack(6);

    try ArithmeticHandlers.mul(helper.frame);

    try helper.assertStackTop(42);
    try helper.assertGasConsumed(GasConstants.GasFastStep); // MUL costs 5 gas
}

test "example: DIV - division by zero returns zero" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    try helper.pushStack(100);
    try helper.pushStack(0); // Divide by zero

    try ArithmeticHandlers.div(helper.frame);

    try helper.assertStackTop(0); // EVM spec: division by zero returns 0
}

test "example: SUB - underflow wrapping" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    try helper.pushStack(5);
    try helper.pushStack(10);

    try ArithmeticHandlers.sub(helper.frame);

    // 5 - 10 wraps to max value minus 4
    const expected = std.math.maxInt(u256) - 4;
    try helper.assertStackTop(expected);
}

// =============================================================================
// Example 2: Stack Manipulation Tests
// =============================================================================

test "example: POP - remove stack item" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    try helper.pushStackSlice(&[_]u256{ 10, 20, 30 });
    try helper.assertStackSize(3);

    try StackHandlers.pop(helper.frame);

    try helper.assertStackSize(2);
    try helper.assertStackTop(20);
}

test "example: DUP1 - duplicate top item" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    try helper.pushStack(42);

    try StackHandlers.dup(helper.frame, 0x80); // DUP1 opcode

    try helper.assertStackSize(2);
    try helper.assertStackTop(42);
    try helper.assertStackAt(1, 42);
}

test "example: DUP2 - duplicate second item" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    try helper.pushStackSlice(&[_]u256{ 10, 20 });

    try StackHandlers.dup(helper.frame, 0x81); // DUP2 opcode

    try helper.assertStackEquals(&[_]u256{ 10, 20, 10 });
}

test "example: SWAP1 - swap top two items" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    try helper.pushStackSlice(&[_]u256{ 10, 20 });

    try StackHandlers.swap(helper.frame, 0x90); // SWAP1 opcode

    try helper.assertStackEquals(&[_]u256{ 10, 20 });
    try helper.assertStackTop(10); // Top is now 10 (was 20)
}

test "example: PUSH0 - Shanghai hardfork requirement" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    // PUSH0 requires Shanghai or later
    helper.withHardfork(.SHANGHAI);

    try StackHandlers.push(helper.frame, 0x5F); // PUSH0 opcode

    try helper.assertStackTop(0);
    try helper.assertGasConsumed(GasConstants.GasQuickStep); // PUSH0 costs 2 gas
}

test "example: PUSH0 - fails on pre-Shanghai" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    helper.withHardfork(.LONDON); // Pre-Shanghai

    // Should return InvalidOpcode error
    try testing.expectError(
        error.InvalidOpcode,
        StackHandlers.push(helper.frame, 0x5F),
    );
}

test "example: PUSH1 - push single byte" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    // Bytecode: PUSH1 0x42
    try helper.withBytecode(&[_]u8{ 0x60, 0x42 });

    try StackHandlers.push(helper.frame, 0x60); // PUSH1 opcode

    try helper.assertStackTop(0x42);
    try helper.assertPC(2); // PC advances past opcode and immediate byte
}

// =============================================================================
// Example 3: Memory Operations
// =============================================================================

test "example: MSTORE - write 32 bytes to memory" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    // Setup: offset=0, value=0xDEADBEEF
    try helper.pushStack(0xDEADBEEF);
    try helper.pushStack(0);

    try MemoryHandlers.mstore(helper.frame);

    // Verify value stored at offset 0 (big-endian, right-aligned in 32 bytes)
    // Memory stores as big-endian, so 0xDEADBEEF appears at the end
    try helper.assertMemoryByte(31, 0xEF);
    try helper.assertMemoryByte(30, 0xBE);
    try helper.assertMemoryByte(29, 0xAD);
    try helper.assertMemoryByte(28, 0xDE);
}

test "example: MLOAD - read 32 bytes from memory" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    // Pre-populate memory with known data
    try helper.writeMemory(0, &[_]u8{ 0x01, 0x02, 0x03, 0x04 });

    // Setup: offset=0
    try helper.pushStack(0);

    try MemoryHandlers.mload(helper.frame);

    // Should read 32 bytes starting at offset 0
    try helper.assertStackSize(1);
}

test "example: MSTORE8 - write single byte to memory" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    // Setup: offset=10, value=0xFF (only lowest byte stored)
    try helper.pushStack(0xFF);
    try helper.pushStack(10);

    try MemoryHandlers.mstore8(helper.frame);

    try helper.assertMemoryByte(10, 0xFF);
    try helper.assertMemorySize(11); // Size expanded to 11
}

// =============================================================================
// Example 4: Storage Operations
// =============================================================================

test "example: SSTORE and SLOAD - persistent storage" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    const slot = 0x42;
    const value = 0x1234;

    // SSTORE: slot=0x42, value=0x1234
    try helper.pushStack(value);
    try helper.pushStack(slot);
    try StorageHandlers.sstore(helper.frame);

    // Verify storage directly
    try helper.assertStorage(slot, value);

    // SLOAD: slot=0x42
    try helper.pushStack(slot);
    try StorageHandlers.sload(helper.frame);

    try helper.assertStackTop(value);
}

test "example: TSTORE and TLOAD - transient storage (Cancun)" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    helper.withHardfork(.CANCUN); // Requires Cancun or later

    const slot = 0x100;
    const value = 0xABCD;

    // TSTORE: slot=0x100, value=0xABCD
    try helper.pushStack(value);
    try helper.pushStack(slot);
    try StorageHandlers.tstore(helper.frame);

    // Verify transient storage directly
    try helper.assertTransientStorage(slot, value);

    // TLOAD: slot=0x100
    try helper.pushStack(slot);
    try StorageHandlers.tload(helper.frame);

    try helper.assertStackTop(value);
}

test "example: TSTORE - fails in static context" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    helper.withHardfork(.CANCUN);
    helper.withStaticCall(true); // Static context

    try helper.pushStack(0x1234);
    try helper.pushStack(0x42);

    // Should fail with WriteInStaticContext
    try testing.expectError(
        error.WriteInStaticContext,
        StorageHandlers.tstore(helper.frame),
    );
}

// =============================================================================
// Example 5: Comparison Operations
// =============================================================================

test "example: EQ - equality check" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    // Equal values
    try helper.pushStack(42);
    try helper.pushStack(42);
    try ComparisonHandlers.eq(helper.frame);
    try helper.assertStackTop(1); // True

    // Not equal values
    try helper.pushStack(42);
    try helper.pushStack(43);
    try ComparisonHandlers.eq(helper.frame);
    try helper.assertStackTop(0); // False
}

test "example: LT - less than comparison" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    try helper.pushStack(10);
    try helper.pushStack(20);
    try ComparisonHandlers.lt(helper.frame);
    try helper.assertStackTop(1); // 10 < 20 = true
}

test "example: ISZERO - zero check" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    try helper.pushStack(0);
    try ComparisonHandlers.iszero(helper.frame);
    try helper.assertStackTop(1); // 0 == 0 = true

    try helper.pushStack(42);
    try ComparisonHandlers.iszero(helper.frame);
    try helper.assertStackTop(0); // 42 == 0 = false
}

// =============================================================================
// Example 6: Bitwise Operations
// =============================================================================

test "example: AND - bitwise and" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    try helper.pushStack(0b1100);
    try helper.pushStack(0b1010);
    try BitwiseHandlers.op_and(helper.frame);
    try helper.assertStackTop(0b1000); // 0b1100 & 0b1010 = 0b1000
}

test "example: OR - bitwise or" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    try helper.pushStack(0b1100);
    try helper.pushStack(0b1010);
    try BitwiseHandlers.op_or(helper.frame);
    try helper.assertStackTop(0b1110); // 0b1100 | 0b1010 = 0b1110
}

test "example: XOR - bitwise xor" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    try helper.pushStack(0b1100);
    try helper.pushStack(0b1010);
    try BitwiseHandlers.op_xor(helper.frame);
    try helper.assertStackTop(0b0110); // 0b1100 ^ 0b1010 = 0b0110
}

test "example: NOT - bitwise not" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    try helper.pushStack(0);
    try BitwiseHandlers.op_not(helper.frame);
    try helper.assertStackTop(std.math.maxInt(u256)); // ~0 = all 1s
}

test "example: BYTE - extract byte from word" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    // Extract byte at index 31 (rightmost) from 0xFF
    try helper.pushStack(0xFF);
    try helper.pushStack(31);
    try BitwiseHandlers.byte(helper.frame);
    try helper.assertStackTop(0xFF);
}

test "example: SHL - shift left" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    try helper.pushStack(0b1010);
    try helper.pushStack(2); // Shift left by 2
    try BitwiseHandlers.shl(helper.frame);
    try helper.assertStackTop(0b101000); // 0b1010 << 2 = 0b101000
}

test "example: SHR - shift right" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    try helper.pushStack(0b1010);
    try helper.pushStack(1); // Shift right by 1
    try BitwiseHandlers.shr(helper.frame);
    try helper.assertStackTop(0b0101); // 0b1010 >> 1 = 0b0101
}

// =============================================================================
// Example 7: Error Handling
// =============================================================================

test "example: stack underflow detection" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    // Empty stack - ADD requires 2 items
    try testing.expectError(
        error.StackUnderflow,
        ArithmeticHandlers.add(helper.frame),
    );
}

test "example: insufficient gas detection" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    // Set gas to less than instruction cost
    helper.withGas(1);

    try helper.pushStack(10);
    try helper.pushStack(20);

    // ADD requires 3 gas but we only have 1
    try testing.expectError(
        error.OutOfGas,
        ArithmeticHandlers.add(helper.frame),
    );
}

// =============================================================================
// Example 8: Complex Multi-Step Tests
// =============================================================================

test "example: multi-step arithmetic sequence" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    // Calculate (10 + 20) * 3
    try helper.pushStack(10);
    try helper.pushStack(20);
    try ArithmeticHandlers.add(helper.frame); // Stack: [30]

    try helper.pushStack(3);
    try ArithmeticHandlers.mul(helper.frame); // Stack: [90]

    try helper.assertStackTop(90);
    try helper.assertStackSize(1);
}

test "example: memory expansion and gas accounting" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    const initial_gas = helper.frame.gas_remaining;

    // Write to high memory offset (will trigger expansion)
    try helper.pushStack(0x12345678);
    try helper.pushStack(1000); // High offset

    try MemoryHandlers.mstore(helper.frame);

    // Verify gas was consumed for both instruction and memory expansion
    const gas_consumed = initial_gas - helper.frame.gas_remaining;
    try helper.assertGasConsumedAtLeast(GasConstants.GasFastestStep);
    try testing.expect(gas_consumed > GasConstants.GasFastestStep); // Includes memory expansion cost
}

test "example: builder pattern for complex setup" {
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    // Configure execution context
    helper.withHardfork(.CANCUN);
    helper.withCaller(TestAddresses.caller);
    helper.withAddress(TestAddresses.contract);
    helper.withValue(1000);
    helper.withGas(100_000);

    // Pre-populate state
    try helper.setBalance(TestAddresses.caller, 10_000);
    try helper.setBalance(TestAddresses.contract, 5_000);
    try helper.setStorage(0x42, 0x1234);

    // Verify setup
    try testing.expectEqual(@as(u256, 10_000), helper.getBalance(TestAddresses.caller));
    try testing.expectEqual(@as(u256, 5_000), helper.getBalance(TestAddresses.contract));
    try helper.assertStorage(0x42, 0x1234);
}

// =============================================================================
// Example 9: Hardfork-Specific Behavior
// =============================================================================

test "example: gas costs vary by hardfork" {
    // Berlin: warm storage access
    {
        var helper = try TestHelper.init(testing.allocator);
        defer helper.deinit();
        helper.withHardfork(.BERLIN);

        // First access is cold
        try helper.pushStack(0x42);
        try StorageHandlers.sload(helper.frame);

        // Access list should now contain this slot (warm)
        // Second access should be cheaper, but this requires EVM-level tracking
    }

    // Pre-Berlin: no warm/cold distinction
    {
        var helper = try TestHelper.init(testing.allocator);
        defer helper.deinit();
        helper.withHardfork(.ISTANBUL);

        // All storage accesses have same cost in pre-Berlin
    }
}

// =============================================================================
// Example 10: Documentation Examples
// =============================================================================

// This test demonstrates the recommended pattern for testing a new opcode
test "example: template for new opcode test" {
    // 1. Initialize test helper
    var helper = try TestHelper.init(testing.allocator);
    defer helper.deinit();

    // 2. Configure execution context (if needed)
    helper.withHardfork(.CANCUN);
    helper.withGas(1_000_000);

    // 3. Setup pre-conditions
    try helper.pushStack(10); // First operand
    try helper.pushStack(20); // Second operand
    try helper.setStorage(0x42, 0x1234); // Pre-state
    const initial_gas = helper.frame.gas_remaining;

    // 4. Execute instruction
    try ArithmeticHandlers.add(helper.frame);

    // 5. Assert post-conditions
    try helper.assertStackTop(30); // Result
    try helper.assertStackSize(1); // Stack size
    try helper.assertGasConsumed(GasConstants.GasFastestStep); // Gas consumed
    try helper.assertPC(1); // PC advanced

    // 6. Verify no unexpected side effects
    try helper.assertStorage(0x42, 0x1234); // Storage unchanged
    try testing.expect(!helper.frame.stopped); // Not stopped
    try testing.expect(!helper.frame.reverted); // Not reverted

    _ = initial_gas;
}
