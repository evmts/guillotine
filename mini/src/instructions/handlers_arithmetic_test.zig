/// Unit tests for arithmetic opcode handlers
const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;
const Hardfork = primitives.Hardfork;
const Address = primitives.Address.Address;
const evm_mod = @import("../evm.zig");
const Evm = evm_mod.Evm(.{});
const Frame = @import("../frame.zig").Frame(.{});

// Helper to create a test EVM instance
fn createTestEvm(allocator: std.mem.Allocator, hardfork: Hardfork) !*Evm {
    const evm = try allocator.create(Evm);
    const block_context = evm_mod.BlockContext{
        .chain_id = 1,
        .block_number = 1,
        .block_timestamp = 1000,
        .block_difficulty = 0,
        .block_prevrandao = 0,
        .block_coinbase = try Address.fromHex("0x0000000000000000000000000000000000000000"),
        .block_gas_limit = 10_000_000,
        .block_base_fee = 1,
        .blob_base_fee = 1,
    };
    evm.* = try Evm.init(allocator, null, hardfork, block_context, null);
    return evm;
}

// Helper to create a test frame
fn createTestFrame(
    allocator: std.mem.Allocator,
    evm: *Evm,
    bytecode: []const u8,
    hardfork: Hardfork,
    gas: i64,
) !Frame {
    const caller = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");
    return try Frame.init(
        allocator,
        bytecode,
        gas,
        caller,
        address,
        0, // value
        &.{}, // calldata
        @ptrCast(evm),
        hardfork,
        false, // is_static
    );
}

// ============================================================================
// ADD Tests
// ============================================================================

test "ADD: basic addition" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x01}; // ADD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 5 + 3 = 8
    try frame.pushStack(5);
    try frame.pushStack(3);

    const initial_gas = frame.gas_remaining;

    // Execute ADD
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.add(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 8), frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "ADD: overflow wrapping" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x01}; // ADD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: max + 1 should wrap to 0
    try frame.pushStack(std.math.maxInt(u256));
    try frame.pushStack(1);

    // Execute ADD
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.add(&frame);

    // Verify result wraps to 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "ADD: max + max wraps to max-1" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x01}; // ADD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: max + max = 2*max = max-1 (wrapping)
    const max = std.math.maxInt(u256);
    try frame.pushStack(max);
    try frame.pushStack(max);

    // Execute ADD
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.add(&frame);

    // Verify result: max + max wraps to max - 1
    try testing.expectEqual(@as(u256, max -% 1), frame.stack.items[0]);
}

test "ADD: zero addition" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x01}; // ADD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 0 + 0 = 0
    try frame.pushStack(0);
    try frame.pushStack(0);

    // Execute ADD
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.add(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "ADD: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x01}; // ADD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(5);

    // Execute ADD with insufficient stack
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    const result = ArithHandlers.add(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "ADD: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x01}; // ADD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 2); // Only 2 gas
    defer frame.deinit();

    try frame.pushStack(5);
    try frame.pushStack(3);

    // Execute ADD with insufficient gas (need 3, have 2)
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    const result = ArithHandlers.add(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// MUL Tests
// ============================================================================

test "MUL: basic multiplication" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x02}; // MUL
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 5 * 3 = 15
    try frame.pushStack(5);
    try frame.pushStack(3);

    const initial_gas = frame.gas_remaining;

    // Execute MUL
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.mul(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 15), frame.stack.items[0]);

    // Verify gas consumed (GasFastStep = 5)
    try testing.expectEqual(@as(i64, 5), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "MUL: overflow wrapping" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x02}; // MUL
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: max * 2 should wrap
    try frame.pushStack(std.math.maxInt(u256));
    try frame.pushStack(2);

    // Execute MUL
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.mul(&frame);

    // Verify result wraps (max * 2 = -2 in two's complement = max - 1)
    const max = std.math.maxInt(u256);
    const expected: u256 = max -% 1;
    try testing.expectEqual(expected, frame.stack.items[0]);
}

test "MUL: zero multiplication" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x02}; // MUL
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 100 * 0 = 0
    try frame.pushStack(100);
    try frame.pushStack(0);

    // Execute MUL
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.mul(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "MUL: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x02}; // MUL
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(5);

    // Execute MUL with insufficient stack
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    const result = ArithHandlers.mul(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// SUB Tests
// ============================================================================

test "SUB: basic subtraction" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x03}; // SUB
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 10 - 3 = 7
    try frame.pushStack(10);
    try frame.pushStack(3);

    const initial_gas = frame.gas_remaining;

    // Execute SUB
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.sub(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 7), frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "SUB: underflow wrapping" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x03}; // SUB
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 0 - 1 should wrap to max
    try frame.pushStack(0);
    try frame.pushStack(1);

    // Execute SUB
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.sub(&frame);

    // Verify result wraps to max u256
    try testing.expectEqual(@as(u256, std.math.maxInt(u256)), frame.stack.items[0]);
}

test "SUB: zero result" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x03}; // SUB
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 5 - 5 = 0
    try frame.pushStack(5);
    try frame.pushStack(5);

    // Execute SUB
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.sub(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "SUB: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x03}; // SUB
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(5);

    // Execute SUB with insufficient stack
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    const result = ArithHandlers.sub(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// DIV Tests
// ============================================================================

test "DIV: basic division" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x04}; // DIV
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 20 / 4 = 5
    try frame.pushStack(20);
    try frame.pushStack(4);

    const initial_gas = frame.gas_remaining;

    // Execute DIV
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.div(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 5), frame.stack.items[0]);

    // Verify gas consumed (GasFastStep = 5)
    try testing.expectEqual(@as(i64, 5), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "DIV: division by zero returns zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x04}; // DIV
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 100 / 0 = 0
    try frame.pushStack(100);
    try frame.pushStack(0);

    // Execute DIV
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.div(&frame);

    // Verify result is 0 (not an error in EVM)
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "DIV: integer division truncates" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x04}; // DIV
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 7 / 3 = 2 (truncated)
    try frame.pushStack(7);
    try frame.pushStack(3);

    // Execute DIV
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.div(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 2), frame.stack.items[0]);
}

test "DIV: max divided by 1" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x04}; // DIV
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: max / 1 = max
    try frame.pushStack(std.math.maxInt(u256));
    try frame.pushStack(1);

    // Execute DIV
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.div(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, std.math.maxInt(u256)), frame.stack.items[0]);
}

test "DIV: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x04}; // DIV
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(5);

    // Execute DIV with insufficient stack
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    const result = ArithHandlers.div(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// SDIV Tests (Signed Division)
// ============================================================================

test "SDIV: basic signed division" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x05}; // SDIV
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 20 / 4 = 5 (both positive)
    try frame.pushStack(20);
    try frame.pushStack(4);

    const initial_gas = frame.gas_remaining;

    // Execute SDIV
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.sdiv(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 5), frame.stack.items[0]);

    // Verify gas consumed (GasFastStep = 5)
    try testing.expectEqual(@as(i64, 5), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "SDIV: negative dividend" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x05}; // SDIV
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: -20 / 4 = -5
    const neg_20 = @as(u256, @bitCast(@as(i256, -20)));
    try frame.pushStack(neg_20);
    try frame.pushStack(4);

    // Execute SDIV
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.sdiv(&frame);

    // Verify result is -5
    const expected = @as(u256, @bitCast(@as(i256, -5)));
    try testing.expectEqual(expected, frame.stack.items[0]);
}

test "SDIV: negative divisor" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x05}; // SDIV
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 20 / -4 = -5
    const neg_4 = @as(u256, @bitCast(@as(i256, -4)));
    try frame.pushStack(20);
    try frame.pushStack(neg_4);

    // Execute SDIV
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.sdiv(&frame);

    // Verify result is -5
    const expected = @as(u256, @bitCast(@as(i256, -5)));
    try testing.expectEqual(expected, frame.stack.items[0]);
}

test "SDIV: both negative" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x05}; // SDIV
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: -20 / -4 = 5
    const neg_20 = @as(u256, @bitCast(@as(i256, -20)));
    const neg_4 = @as(u256, @bitCast(@as(i256, -4)));
    try frame.pushStack(neg_20);
    try frame.pushStack(neg_4);

    // Execute SDIV
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.sdiv(&frame);

    // Verify result is 5
    try testing.expectEqual(@as(u256, 5), frame.stack.items[0]);
}

test "SDIV: division by zero returns zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x05}; // SDIV
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 100 / 0 = 0
    try frame.pushStack(100);
    try frame.pushStack(0);

    // Execute SDIV
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.sdiv(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "SDIV: MIN_SIGNED / -1 edge case" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x05}; // SDIV
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: MIN_SIGNED / -1 = MIN_SIGNED (overflow case)
    const MIN_SIGNED = @as(u256, 1) << 255;
    try frame.pushStack(MIN_SIGNED);
    try frame.pushStack(std.math.maxInt(u256)); // -1 in two's complement

    // Execute SDIV
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.sdiv(&frame);

    // Verify result is MIN_SIGNED (special case)
    try testing.expectEqual(MIN_SIGNED, frame.stack.items[0]);
}

test "SDIV: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x05}; // SDIV
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(5);

    // Execute SDIV with insufficient stack
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    const result = ArithHandlers.sdiv(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// MOD Tests
// ============================================================================

test "MOD: basic modulo" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x06}; // MOD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 10 % 3 = 1
    try frame.pushStack(10);
    try frame.pushStack(3);

    const initial_gas = frame.gas_remaining;

    // Execute MOD
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.mod(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);

    // Verify gas consumed (GasFastStep = 5)
    try testing.expectEqual(@as(i64, 5), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "MOD: modulo by zero returns zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x06}; // MOD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 100 % 0 = 0
    try frame.pushStack(100);
    try frame.pushStack(0);

    // Execute MOD
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.mod(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "MOD: zero modulo" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x06}; // MOD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 0 % 5 = 0
    try frame.pushStack(0);
    try frame.pushStack(5);

    // Execute MOD
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.mod(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "MOD: max modulo 1" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x06}; // MOD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: max % 1 = 0
    try frame.pushStack(std.math.maxInt(u256));
    try frame.pushStack(1);

    // Execute MOD
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.mod(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "MOD: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x06}; // MOD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(5);

    // Execute MOD with insufficient stack
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    const result = ArithHandlers.mod(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// SMOD Tests (Signed Modulo)
// ============================================================================

test "SMOD: basic signed modulo" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x07}; // SMOD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 10 % 3 = 1 (both positive)
    try frame.pushStack(10);
    try frame.pushStack(3);

    const initial_gas = frame.gas_remaining;

    // Execute SMOD
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.smod(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);

    // Verify gas consumed (GasFastStep = 5)
    try testing.expectEqual(@as(i64, 5), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "SMOD: negative dividend" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x07}; // SMOD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: -10 % 3 = -1 (sign follows dividend)
    const neg_10 = @as(u256, @bitCast(@as(i256, -10)));
    try frame.pushStack(neg_10);
    try frame.pushStack(3);

    // Execute SMOD
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.smod(&frame);

    // Verify result is -1
    const expected = @as(u256, @bitCast(@as(i256, -1)));
    try testing.expectEqual(expected, frame.stack.items[0]);
}

test "SMOD: negative divisor" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x07}; // SMOD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 10 % -3 = 1 (sign follows dividend)
    const neg_3 = @as(u256, @bitCast(@as(i256, -3)));
    try frame.pushStack(10);
    try frame.pushStack(neg_3);

    // Execute SMOD
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.smod(&frame);

    // Verify result is 1
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);
}

test "SMOD: both negative" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x07}; // SMOD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: -10 % -3 = -1 (sign follows dividend)
    const neg_10 = @as(u256, @bitCast(@as(i256, -10)));
    const neg_3 = @as(u256, @bitCast(@as(i256, -3)));
    try frame.pushStack(neg_10);
    try frame.pushStack(neg_3);

    // Execute SMOD
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.smod(&frame);

    // Verify result is -1
    const expected = @as(u256, @bitCast(@as(i256, -1)));
    try testing.expectEqual(expected, frame.stack.items[0]);
}

test "SMOD: modulo by zero returns zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x07}; // SMOD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 100 % 0 = 0
    try frame.pushStack(100);
    try frame.pushStack(0);

    // Execute SMOD
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.smod(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "SMOD: MIN_SIGNED % -1 edge case" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x07}; // SMOD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: MIN_SIGNED % -1 = 0 (special case)
    const MIN_SIGNED = @as(u256, 1) << 255;
    try frame.pushStack(MIN_SIGNED);
    try frame.pushStack(std.math.maxInt(u256)); // -1 in two's complement

    // Execute SMOD
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.smod(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "SMOD: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x07}; // SMOD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(5);

    // Execute SMOD with insufficient stack
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    const result = ArithHandlers.smod(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// ADDMOD Tests
// ============================================================================

test "ADDMOD: basic addmod" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x08}; // ADDMOD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: (5 + 3) % 4 = 8 % 4 = 0
    try frame.pushStack(5);
    try frame.pushStack(3);
    try frame.pushStack(4);

    const initial_gas = frame.gas_remaining;

    // Execute ADDMOD
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.addmod(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);

    // Verify gas consumed (GasMidStep = 8)
    try testing.expectEqual(@as(i64, 8), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "ADDMOD: prevents overflow via u512" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x08}; // ADDMOD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: (max + max) % 10
    // This would overflow u256, but should work with u512 intermediate
    const max = std.math.maxInt(u256);
    try frame.pushStack(max);
    try frame.pushStack(max);
    try frame.pushStack(10);

    // Execute ADDMOD
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.addmod(&frame);

    // Verify result: (max + max) % 10 = (2*max) % 10
    // 2*max = 2^256 - 2, so (2^256 - 2) % 10 = 8
    try testing.expectEqual(@as(u256, 8), frame.stack.items[0]);
}

test "ADDMOD: modulo by zero returns zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x08}; // ADDMOD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: (5 + 3) % 0 = 0
    try frame.pushStack(5);
    try frame.pushStack(3);
    try frame.pushStack(0);

    // Execute ADDMOD
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.addmod(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "ADDMOD: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x08}; // ADDMOD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 2 values (need 3)
    try frame.pushStack(5);
    try frame.pushStack(3);

    // Execute ADDMOD with insufficient stack
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    const result = ArithHandlers.addmod(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// MULMOD Tests
// ============================================================================

test "MULMOD: basic mulmod" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x09}; // MULMOD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: (5 * 3) % 7 = 15 % 7 = 1
    try frame.pushStack(5);
    try frame.pushStack(3);
    try frame.pushStack(7);

    const initial_gas = frame.gas_remaining;

    // Execute MULMOD
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.mulmod(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);

    // Verify gas consumed (GasMidStep = 8)
    try testing.expectEqual(@as(i64, 8), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "MULMOD: prevents overflow via u512" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x09}; // MULMOD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: (max * 2) % 10
    // This would overflow u256, but should work with u512 intermediate
    const max = std.math.maxInt(u256);
    try frame.pushStack(max);
    try frame.pushStack(2);
    try frame.pushStack(10);

    // Execute MULMOD
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.mulmod(&frame);

    // Verify result: (max * 2) % 10 = (2^256 - 2) % 10 = 8
    try testing.expectEqual(@as(u256, 8), frame.stack.items[0]);
}

test "MULMOD: modulo by zero returns zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x09}; // MULMOD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: (5 * 3) % 0 = 0
    try frame.pushStack(5);
    try frame.pushStack(3);
    try frame.pushStack(0);

    // Execute MULMOD
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.mulmod(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "MULMOD: zero multiplication" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x09}; // MULMOD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: (0 * 3) % 7 = 0
    try frame.pushStack(0);
    try frame.pushStack(3);
    try frame.pushStack(7);

    // Execute MULMOD
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.mulmod(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "MULMOD: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x09}; // MULMOD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 2 values (need 3)
    try frame.pushStack(5);
    try frame.pushStack(3);

    // Execute MULMOD with insufficient stack
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    const result = ArithHandlers.mulmod(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// EXP Tests
// ============================================================================

test "EXP: basic exponentiation" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x0a}; // EXP
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 2^3 = 8
    try frame.pushStack(2);
    try frame.pushStack(3);

    const initial_gas = frame.gas_remaining;

    // Execute EXP
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.exp(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 8), frame.stack.items[0]);

    // Verify gas consumed (GasSlowStep + EXP_BYTE_COST * byte_length(3))
    // GasSlowStep = 10, EXP_BYTE_COST = 50, byte_length(3) = 1
    // Total = 10 + 50*1 = 60
    try testing.expectEqual(@as(i64, 60), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "EXP: exponent zero returns one" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x0a}; // EXP
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 5^0 = 1
    try frame.pushStack(5);
    try frame.pushStack(0);

    const initial_gas = frame.gas_remaining;

    // Execute EXP
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.exp(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);

    // Verify gas consumed (GasSlowStep + 0*50 = 10)
    try testing.expectEqual(@as(i64, 10), initial_gas - frame.gas_remaining);
}

test "EXP: base zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x0a}; // EXP
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 0^3 = 0
    try frame.pushStack(0);
    try frame.pushStack(3);

    // Execute EXP
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.exp(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "EXP: both zero (0^0 = 1 by convention)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x0a}; // EXP
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 0^0 = 1 (mathematical convention)
    try frame.pushStack(0);
    try frame.pushStack(0);

    // Execute EXP
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.exp(&frame);

    // Verify result is 1
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);
}

test "EXP: overflow wrapping" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x0a}; // EXP
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 2^256 should wrap
    try frame.pushStack(2);
    try frame.pushStack(256);

    // Execute EXP
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.exp(&frame);

    // Verify result wraps to 0 (2^256 mod 2^256 = 0)
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "EXP: gas cost scales with exponent byte length" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x0a}; // EXP
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 2^0x100 (exponent = 256, byte_length = 2)
    try frame.pushStack(2);
    try frame.pushStack(0x100);

    const initial_gas = frame.gas_remaining;

    // Execute EXP
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.exp(&frame);

    // Verify gas consumed (GasSlowStep + EXP_BYTE_COST * byte_length(0x100))
    // GasSlowStep = 10, EXP_BYTE_COST = 50, byte_length(0x100) = 2
    // Total = 10 + 50*2 = 110
    try testing.expectEqual(@as(i64, 110), initial_gas - frame.gas_remaining);
}

test "EXP: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x0a}; // EXP
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(5);

    // Execute EXP with insufficient stack
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    const result = ArithHandlers.exp(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// SIGNEXTEND Tests
// ============================================================================

test "SIGNEXTEND: basic sign extension" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x0b}; // SIGNEXTEND
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: Sign extend byte 0 of 0xFF (negative byte)
    try frame.pushStack(0); // byte index
    try frame.pushStack(0xFF); // value with negative sign bit in byte 0

    const initial_gas = frame.gas_remaining;

    // Execute SIGNEXTEND
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.signextend(&frame);

    // Verify result (should extend with 1s)
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, std.math.maxInt(u256)), frame.stack.items[0]);

    // Verify gas consumed (GasFastStep = 5)
    try testing.expectEqual(@as(i64, 5), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "SIGNEXTEND: positive sign extension" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x0b}; // SIGNEXTEND
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: Sign extend byte 0 of 0x7F (positive byte)
    try frame.pushStack(0); // byte index
    try frame.pushStack(0x7F); // value with positive sign bit in byte 0

    // Execute SIGNEXTEND
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.signextend(&frame);

    // Verify result (should stay 0x7F, upper bits cleared)
    try testing.expectEqual(@as(u256, 0x7F), frame.stack.items[0]);
}

test "SIGNEXTEND: byte index 1" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x0b}; // SIGNEXTEND
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: Sign extend from byte 1 of 0x80FF (negative)
    try frame.pushStack(1); // byte index
    try frame.pushStack(0x80FF); // bit 15 is set (negative for 2-byte value)

    // Execute SIGNEXTEND
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.signextend(&frame);

    // Verify result (should extend with 1s from bit 15)
    const mask = (@as(u256, 1) << 16) - 1;
    const expected = 0x80FF | ~mask;
    try testing.expectEqual(expected, frame.stack.items[0]);
}

test "SIGNEXTEND: byte index 31 no change" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x0b}; // SIGNEXTEND
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: Sign extend from byte 31 (full u256, no change)
    try frame.pushStack(31); // byte index
    try frame.pushStack(0x12345678);

    // Execute SIGNEXTEND
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.signextend(&frame);

    // Verify result (no change)
    try testing.expectEqual(@as(u256, 0x12345678), frame.stack.items[0]);
}

test "SIGNEXTEND: byte index > 31 no change" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x0b}; // SIGNEXTEND
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: Sign extend from byte 100 (out of range, no change)
    try frame.pushStack(100); // byte index
    try frame.pushStack(0x12345678);

    // Execute SIGNEXTEND
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.signextend(&frame);

    // Verify result (no change)
    try testing.expectEqual(@as(u256, 0x12345678), frame.stack.items[0]);
}

test "SIGNEXTEND: zero value" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x0b}; // SIGNEXTEND
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: Sign extend 0
    try frame.pushStack(0); // byte index
    try frame.pushStack(0); // value

    // Execute SIGNEXTEND
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.signextend(&frame);

    // Verify result is still 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "SIGNEXTEND: clear upper bits on positive" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x0b}; // SIGNEXTEND
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: Value with upper bits set, but sign bit clear
    try frame.pushStack(0); // byte index
    try frame.pushStack(0xFFFFFF7F); // upper bits set, but bit 7 is 0 (positive)

    // Execute SIGNEXTEND
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    try ArithHandlers.signextend(&frame);

    // Verify result (upper bits should be cleared)
    try testing.expectEqual(@as(u256, 0x7F), frame.stack.items[0]);
}

test "SIGNEXTEND: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x0b}; // SIGNEXTEND
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(5);

    // Execute SIGNEXTEND with insufficient stack
    const ArithHandlers = @import("handlers_arithmetic.zig").Handlers(@TypeOf(frame));
    const result = ArithHandlers.signextend(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}
