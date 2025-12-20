/// Unit tests for bitwise opcode handlers
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
// AND Tests
// ============================================================================

test "AND: basic bitwise AND" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x16}; // AND
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 0b1111 AND 0b1010 = 0b1010
    try frame.pushStack(0b1111);
    try frame.pushStack(0b1010);

    const initial_gas = frame.gas_remaining;

    // Execute AND
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.op_and(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 0b1010), frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "AND: all ones AND all ones = all ones" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x16}; // AND
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const max = std.math.maxInt(u256);
    try frame.pushStack(max);
    try frame.pushStack(max);

    // Execute AND
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.op_and(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, max), frame.stack.items[0]);
}

test "AND: all ones AND zero = zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x16}; // AND
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    try frame.pushStack(std.math.maxInt(u256));
    try frame.pushStack(0);

    // Execute AND
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.op_and(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "AND: zero AND zero = zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x16}; // AND
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    try frame.pushStack(0);
    try frame.pushStack(0);

    // Execute AND
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.op_and(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "AND: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x16}; // AND
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(5);

    // Execute AND with insufficient stack
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    const result = BitwiseHandlers.op_and(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "AND: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x16}; // AND
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 2); // Only 2 gas
    defer frame.deinit();

    try frame.pushStack(5);
    try frame.pushStack(3);

    // Execute AND with insufficient gas (need 3, have 2)
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    const result = BitwiseHandlers.op_and(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// OR Tests
// ============================================================================

test "OR: basic bitwise OR" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x17}; // OR
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 0b1010 OR 0b0101 = 0b1111
    try frame.pushStack(0b1010);
    try frame.pushStack(0b0101);

    const initial_gas = frame.gas_remaining;

    // Execute OR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.op_or(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 0b1111), frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "OR: all ones OR all ones = all ones" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x17}; // OR
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const max = std.math.maxInt(u256);
    try frame.pushStack(max);
    try frame.pushStack(max);

    // Execute OR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.op_or(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, max), frame.stack.items[0]);
}

test "OR: zero OR zero = zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x17}; // OR
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    try frame.pushStack(0);
    try frame.pushStack(0);

    // Execute OR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.op_or(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "OR: all ones OR zero = all ones" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x17}; // OR
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    try frame.pushStack(std.math.maxInt(u256));
    try frame.pushStack(0);

    // Execute OR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.op_or(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, std.math.maxInt(u256)), frame.stack.items[0]);
}

test "OR: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x17}; // OR
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(5);

    // Execute OR with insufficient stack
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    const result = BitwiseHandlers.op_or(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "OR: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x17}; // OR
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 2); // Only 2 gas
    defer frame.deinit();

    try frame.pushStack(5);
    try frame.pushStack(3);

    // Execute OR with insufficient gas (need 3, have 2)
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    const result = BitwiseHandlers.op_or(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// XOR Tests
// ============================================================================

test "XOR: basic bitwise XOR" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x18}; // XOR
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 0b1111 XOR 0b1010 = 0b0101
    try frame.pushStack(0b1111);
    try frame.pushStack(0b1010);

    const initial_gas = frame.gas_remaining;

    // Execute XOR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.op_xor(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 0b0101), frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "XOR: identical values = zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x18}; // XOR
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    try frame.pushStack(0x12345678);
    try frame.pushStack(0x12345678);

    // Execute XOR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.op_xor(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "XOR: all ones XOR all ones = zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x18}; // XOR
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const max = std.math.maxInt(u256);
    try frame.pushStack(max);
    try frame.pushStack(max);

    // Execute XOR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.op_xor(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "XOR: zero XOR zero = zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x18}; // XOR
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    try frame.pushStack(0);
    try frame.pushStack(0);

    // Execute XOR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.op_xor(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "XOR: value XOR zero = value" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x18}; // XOR
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const value = 0x123456;
    try frame.pushStack(value);
    try frame.pushStack(0);

    // Execute XOR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.op_xor(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, value), frame.stack.items[0]);
}

test "XOR: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x18}; // XOR
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(5);

    // Execute XOR with insufficient stack
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    const result = BitwiseHandlers.op_xor(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "XOR: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x18}; // XOR
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 2); // Only 2 gas
    defer frame.deinit();

    try frame.pushStack(5);
    try frame.pushStack(3);

    // Execute XOR with insufficient gas (need 3, have 2)
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    const result = BitwiseHandlers.op_xor(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// NOT Tests
// ============================================================================

test "NOT: basic bitwise NOT" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x19}; // NOT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: NOT 0 = all ones
    try frame.pushStack(0);

    const initial_gas = frame.gas_remaining;

    // Execute NOT
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.op_not(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, std.math.maxInt(u256)), frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "NOT: NOT of all ones = zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x19}; // NOT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    try frame.pushStack(std.math.maxInt(u256));

    // Execute NOT
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.op_not(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "NOT: double NOT returns original" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{ 0x19, 0x19 }; // NOT NOT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const value = 0x123456789ABCDEF;
    try frame.pushStack(value);

    // Execute NOT
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.op_not(&frame);

    // Execute NOT again
    frame.pc = 1;
    try BitwiseHandlers.op_not(&frame);

    // Verify result is back to original
    try testing.expectEqual(@as(u256, value), frame.stack.items[0]);
}

test "NOT: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x19}; // NOT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Execute NOT on empty stack
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    const result = BitwiseHandlers.op_not(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "NOT: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x19}; // NOT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 2); // Only 2 gas
    defer frame.deinit();

    try frame.pushStack(5);

    // Execute NOT with insufficient gas (need 3, have 2)
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    const result = BitwiseHandlers.op_not(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// BYTE Tests
// ============================================================================

test "BYTE: extract byte at position 0" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1a}; // BYTE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: extract byte 0 from 0xFF00...00 (most significant byte)
    try frame.pushStack(0);
    try frame.pushStack(@as(u256, 0xFF) << 248);

    const initial_gas = frame.gas_remaining;

    // Execute BYTE
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.byte(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 0xFF), frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "BYTE: extract byte at position 31" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1a}; // BYTE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: extract byte 31 from 0x...AB (least significant byte)
    try frame.pushStack(31);
    try frame.pushStack(0xAB);

    // Execute BYTE
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.byte(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0xAB), frame.stack.items[0]);
}

test "BYTE: extract byte at position 15" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1a}; // BYTE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: extract byte 15 (middle byte)
    // Value: 0x00...00CD00...00 (byte 15 is 0xCD)
    const value = @as(u256, 0xCD) << 128;
    try frame.pushStack(15);
    try frame.pushStack(value);

    // Execute BYTE
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.byte(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0xCD), frame.stack.items[0]);
}

test "BYTE: position >= 32 returns zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1a}; // BYTE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: extract byte 32 (out of bounds)
    try frame.pushStack(32);
    try frame.pushStack(std.math.maxInt(u256));

    // Execute BYTE
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.byte(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "BYTE: large position returns zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1a}; // BYTE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: extract byte 1000 (way out of bounds)
    try frame.pushStack(1000);
    try frame.pushStack(std.math.maxInt(u256));

    // Execute BYTE
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.byte(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "BYTE: zero value returns zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1a}; // BYTE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: extract byte from zero
    try frame.pushStack(0);
    try frame.pushStack(0);

    // Execute BYTE
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.byte(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "BYTE: all positions 0-31" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    // Create a value where byte i = i
    var value: u256 = 0;
    var i: u8 = 0;
    while (i < 32) : (i += 1) {
        value |= @as(u256, i) << @intCast((31 - i) * 8);
    }

    // Test each position
    i = 0;
    while (i < 32) : (i += 1) {
        const bytecode = &[_]u8{0x1a}; // BYTE
        var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
        defer frame.deinit();

        try frame.pushStack(i);
        try frame.pushStack(value);

        const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
        try BitwiseHandlers.byte(&frame);

        // Verify we extracted the correct byte
        try testing.expectEqual(@as(u256, i), frame.stack.items[0]);
    }

    evm.deinit();
    allocator.destroy(evm);
}

test "BYTE: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1a}; // BYTE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(5);

    // Execute BYTE with insufficient stack
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    const result = BitwiseHandlers.byte(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "BYTE: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1a}; // BYTE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 2); // Only 2 gas
    defer frame.deinit();

    try frame.pushStack(0);
    try frame.pushStack(0xFF);

    // Execute BYTE with insufficient gas (need 3, have 2)
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    const result = BitwiseHandlers.byte(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// SHL Tests (EIP-145, Constantinople+)
// ============================================================================

test "SHL: basic shift left" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1b}; // SHL
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: 0xFF << 8 = 0xFF00
    try frame.pushStack(8);
    try frame.pushStack(0xFF);

    const initial_gas = frame.gas_remaining;

    // Execute SHL
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.shl(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 0xFF00), frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "SHL: shift by zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1b}; // SHL
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: 0xFF << 0 = 0xFF
    try frame.pushStack(0);
    try frame.pushStack(0xFF);

    // Execute SHL
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.shl(&frame);

    // Verify result unchanged
    try testing.expectEqual(@as(u256, 0xFF), frame.stack.items[0]);
}

test "SHL: shift by 1" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1b}; // SHL
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: 5 << 1 = 10
    try frame.pushStack(1);
    try frame.pushStack(5);

    // Execute SHL
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.shl(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 10), frame.stack.items[0]);
}

test "SHL: shift by 255" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1b}; // SHL
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: 1 << 255 = sign bit set
    try frame.pushStack(255);
    try frame.pushStack(1);

    // Execute SHL
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.shl(&frame);

    // Verify result
    const expected = @as(u256, 1) << 255;
    try testing.expectEqual(expected, frame.stack.items[0]);
}

test "SHL: shift by 256 returns zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1b}; // SHL
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: any value << 256 = 0
    try frame.pushStack(256);
    try frame.pushStack(std.math.maxInt(u256));

    // Execute SHL
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.shl(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "SHL: shift by large amount returns zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1b}; // SHL
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: any value << 1000 = 0
    try frame.pushStack(1000);
    try frame.pushStack(0x123456);

    // Execute SHL
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.shl(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "SHL: shift zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1b}; // SHL
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: 0 << 8 = 0
    try frame.pushStack(8);
    try frame.pushStack(0);

    // Execute SHL
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.shl(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "SHL: invalid before Constantinople" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BYZANTIUM);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1b}; // SHL
    var frame = try createTestFrame(allocator, evm, bytecode, .BYZANTIUM, 1_000_000);
    defer frame.deinit();

    try frame.pushStack(8);
    try frame.pushStack(0xFF);

    // Execute SHL on Byzantium (pre-Constantinople)
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    const result = BitwiseHandlers.shl(&frame);

    // Verify error
    try testing.expectError(error.InvalidOpcode, result);
}

test "SHL: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1b}; // SHL
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(5);

    // Execute SHL with insufficient stack
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    const result = BitwiseHandlers.shl(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "SHL: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1b}; // SHL
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 2); // Only 2 gas
    defer frame.deinit();

    try frame.pushStack(8);
    try frame.pushStack(0xFF);

    // Execute SHL with insufficient gas (need 3, have 2)
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    const result = BitwiseHandlers.shl(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// SHR Tests (EIP-145, Constantinople+)
// ============================================================================

test "SHR: basic shift right" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1c}; // SHR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: 0xFF00 >> 8 = 0xFF
    try frame.pushStack(8);
    try frame.pushStack(0xFF00);

    const initial_gas = frame.gas_remaining;

    // Execute SHR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.shr(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 0xFF), frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "SHR: shift by zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1c}; // SHR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: 0xFF >> 0 = 0xFF
    try frame.pushStack(0);
    try frame.pushStack(0xFF);

    // Execute SHR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.shr(&frame);

    // Verify result unchanged
    try testing.expectEqual(@as(u256, 0xFF), frame.stack.items[0]);
}

test "SHR: shift by 1" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1c}; // SHR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: 10 >> 1 = 5
    try frame.pushStack(1);
    try frame.pushStack(10);

    // Execute SHR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.shr(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 5), frame.stack.items[0]);
}

test "SHR: shift by 255" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1c}; // SHR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: sign bit >> 255 = 1
    const value = @as(u256, 1) << 255;
    try frame.pushStack(255);
    try frame.pushStack(value);

    // Execute SHR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.shr(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);
}

test "SHR: shift by 256 returns zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1c}; // SHR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: any value >> 256 = 0
    try frame.pushStack(256);
    try frame.pushStack(std.math.maxInt(u256));

    // Execute SHR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.shr(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "SHR: shift by large amount returns zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1c}; // SHR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: any value >> 1000 = 0
    try frame.pushStack(1000);
    try frame.pushStack(0x123456);

    // Execute SHR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.shr(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "SHR: shift zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1c}; // SHR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: 0 >> 8 = 0
    try frame.pushStack(8);
    try frame.pushStack(0);

    // Execute SHR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.shr(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "SHR: logical shift (no sign extension)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1c}; // SHR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: shift negative number (sign bit set)
    const value = @as(u256, 1) << 255; // Most significant bit set
    try frame.pushStack(1);
    try frame.pushStack(value);

    // Execute SHR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.shr(&frame);

    // Verify result (should be logical shift, no sign extension)
    const expected = (@as(u256, 1) << 255) >> 1;
    try testing.expectEqual(expected, frame.stack.items[0]);
}

test "SHR: invalid before Constantinople" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BYZANTIUM);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1c}; // SHR
    var frame = try createTestFrame(allocator, evm, bytecode, .BYZANTIUM, 1_000_000);
    defer frame.deinit();

    try frame.pushStack(8);
    try frame.pushStack(0xFF00);

    // Execute SHR on Byzantium (pre-Constantinople)
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    const result = BitwiseHandlers.shr(&frame);

    // Verify error
    try testing.expectError(error.InvalidOpcode, result);
}

test "SHR: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1c}; // SHR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(5);

    // Execute SHR with insufficient stack
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    const result = BitwiseHandlers.shr(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "SHR: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1c}; // SHR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 2); // Only 2 gas
    defer frame.deinit();

    try frame.pushStack(8);
    try frame.pushStack(0xFF00);

    // Execute SHR with insufficient gas (need 3, have 2)
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    const result = BitwiseHandlers.shr(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// SAR Tests (EIP-145, Constantinople+)
// ============================================================================

test "SAR: basic arithmetic shift right" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1d}; // SAR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: 0xFF00 >> 8 = 0xFF (positive number)
    try frame.pushStack(8);
    try frame.pushStack(0xFF00);

    const initial_gas = frame.gas_remaining;

    // Execute SAR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.sar(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 0xFF), frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "SAR: positive number shift" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1d}; // SAR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: 10 >> 1 = 5 (positive)
    try frame.pushStack(1);
    try frame.pushStack(10);

    // Execute SAR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.sar(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 5), frame.stack.items[0]);
}

test "SAR: negative number sign extension" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1d}; // SAR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: -2 (as u256) >> 1 = -1 (sign extension)
    const neg_2 = @as(u256, @bitCast(@as(i256, -2)));
    try frame.pushStack(1);
    try frame.pushStack(neg_2);

    // Execute SAR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.sar(&frame);

    // Verify result is -1 (all bits set)
    const neg_1 = @as(u256, @bitCast(@as(i256, -1)));
    try testing.expectEqual(neg_1, frame.stack.items[0]);
}

test "SAR: negative number large shift" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1d}; // SAR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: negative number >> 255 = -1 (all ones from sign extension)
    const neg_100 = @as(u256, @bitCast(@as(i256, -100)));
    try frame.pushStack(255);
    try frame.pushStack(neg_100);

    // Execute SAR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.sar(&frame);

    // Verify result is -1
    const neg_1 = @as(u256, @bitCast(@as(i256, -1)));
    try testing.expectEqual(neg_1, frame.stack.items[0]);
}

test "SAR: negative number shift by 256+" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1d}; // SAR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: negative number >> 256 = -1 (all ones)
    const neg_42 = @as(u256, @bitCast(@as(i256, -42)));
    try frame.pushStack(256);
    try frame.pushStack(neg_42);

    // Execute SAR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.sar(&frame);

    // Verify result is -1
    const neg_1 = @as(u256, @bitCast(@as(i256, -1)));
    try testing.expectEqual(neg_1, frame.stack.items[0]);
}

test "SAR: negative number shift by large amount" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1d}; // SAR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: negative number >> 1000 = -1 (all ones)
    const neg_value = @as(u256, @bitCast(@as(i256, -123456)));
    try frame.pushStack(1000);
    try frame.pushStack(neg_value);

    // Execute SAR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.sar(&frame);

    // Verify result is -1
    const neg_1 = @as(u256, @bitCast(@as(i256, -1)));
    try testing.expectEqual(neg_1, frame.stack.items[0]);
}

test "SAR: positive number shift by 256+" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1d}; // SAR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: positive number >> 256 = 0
    try frame.pushStack(256);
    try frame.pushStack(0x123456);

    // Execute SAR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.sar(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "SAR: positive number shift by large amount" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1d}; // SAR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: positive number >> 1000 = 0
    try frame.pushStack(1000);
    try frame.pushStack(std.math.maxInt(u256) >> 1); // Max positive value

    // Execute SAR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.sar(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "SAR: shift by zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1d}; // SAR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: value >> 0 = value
    const value = 0x123456;
    try frame.pushStack(0);
    try frame.pushStack(value);

    // Execute SAR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.sar(&frame);

    // Verify result unchanged
    try testing.expectEqual(@as(u256, value), frame.stack.items[0]);
}

test "SAR: shift zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1d}; // SAR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: 0 >> 8 = 0
    try frame.pushStack(8);
    try frame.pushStack(0);

    // Execute SAR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.sar(&frame);

    // Verify result
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "SAR: -1 shifted" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1d}; // SAR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Setup: -1 >> any amount = -1 (all bits remain 1)
    const neg_1 = @as(u256, @bitCast(@as(i256, -1)));
    try frame.pushStack(100);
    try frame.pushStack(neg_1);

    // Execute SAR
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    try BitwiseHandlers.sar(&frame);

    // Verify result is still -1
    try testing.expectEqual(neg_1, frame.stack.items[0]);
}

test "SAR: invalid before Constantinople" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BYZANTIUM);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1d}; // SAR
    var frame = try createTestFrame(allocator, evm, bytecode, .BYZANTIUM, 1_000_000);
    defer frame.deinit();

    try frame.pushStack(8);
    try frame.pushStack(0xFF00);

    // Execute SAR on Byzantium (pre-Constantinople)
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    const result = BitwiseHandlers.sar(&frame);

    // Verify error
    try testing.expectError(error.InvalidOpcode, result);
}

test "SAR: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1d}; // SAR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(5);

    // Execute SAR with insufficient stack
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    const result = BitwiseHandlers.sar(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "SAR: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x1d}; // SAR
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 2); // Only 2 gas
    defer frame.deinit();

    try frame.pushStack(8);
    try frame.pushStack(0xFF00);

    // Execute SAR with insufficient gas (need 3, have 2)
    const BitwiseHandlers = @import("handlers_bitwise.zig").Handlers(@TypeOf(frame));
    const result = BitwiseHandlers.sar(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}
