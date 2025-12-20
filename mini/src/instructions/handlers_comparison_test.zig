/// Unit tests for comparison opcode handlers
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
// LT Tests (Less Than - Unsigned)
// ============================================================================

test "LT: basic less than comparison - true" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x10}; // LT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 5 < 10 = true (1)
    // Stack order: push b first, then a (so a is on top)
    try frame.pushStack(10); // b (second from top)
    try frame.pushStack(5);  // a (top of stack)

    const initial_gas = frame.gas_remaining;

    // Execute LT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.lt(&frame);

    // Verify result is 1 (true)
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "LT: basic less than comparison - false" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x10}; // LT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 10 < 5 = false (0)
    // Stack order: push b first, then a (so a is on top)
    try frame.pushStack(5);  // b (second from top)
    try frame.pushStack(10); // a (top of stack)

    // Execute LT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.lt(&frame);

    // Verify result is 0 (false)
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "LT: equal values" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x10}; // LT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 5 < 5 = false (0)
    try frame.pushStack(5);
    try frame.pushStack(5);

    // Execute LT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.lt(&frame);

    // Verify result is 0 (false)
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "LT: zero comparison" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x10}; // LT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 0 < 1 = true (1)
    try frame.pushStack(1);  // b (second from top)
    try frame.pushStack(0);  // a (top of stack)

    // Execute LT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.lt(&frame);

    // Verify result is 1 (true)
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);
}

test "LT: max value comparison" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x10}; // LT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: (max - 1) < max = true (1)
    const max = std.math.maxInt(u256);
    try frame.pushStack(max);       // b (second from top)
    try frame.pushStack(max - 1);   // a (top of stack)

    // Execute LT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.lt(&frame);

    // Verify result is 1 (true)
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);
}

test "LT: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x10}; // LT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(5);

    // Execute LT with insufficient stack
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    const result = CompHandlers.lt(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "LT: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x10}; // LT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 2); // Only 2 gas
    defer frame.deinit();

    try frame.pushStack(5);
    try frame.pushStack(10);

    // Execute LT with insufficient gas (need 3, have 2)
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    const result = CompHandlers.lt(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// GT Tests (Greater Than - Unsigned)
// ============================================================================

test "GT: basic greater than comparison - true" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x11}; // GT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 10 > 5 = true (1)
    try frame.pushStack(5);  // b (second from top)
    try frame.pushStack(10); // a (top of stack)

    const initial_gas = frame.gas_remaining;

    // Execute GT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.gt(&frame);

    // Verify result is 1 (true)
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "GT: basic greater than comparison - false" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x11}; // GT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 5 > 10 = false (0)
    try frame.pushStack(10); // b (second from top)
    try frame.pushStack(5);  // a (top of stack)

    // Execute GT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.gt(&frame);

    // Verify result is 0 (false)
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "GT: equal values" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x11}; // GT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 5 > 5 = false (0)
    try frame.pushStack(5);
    try frame.pushStack(5);

    // Execute GT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.gt(&frame);

    // Verify result is 0 (false)
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "GT: max value comparison" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x11}; // GT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: max > (max - 1) = true (1)
    const max = std.math.maxInt(u256);
    try frame.pushStack(max - 1);   // b (second from top)
    try frame.pushStack(max);       // a (top of stack)

    // Execute GT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.gt(&frame);

    // Verify result is 1 (true)
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);
}

test "GT: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x11}; // GT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(5);

    // Execute GT with insufficient stack
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    const result = CompHandlers.gt(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// SLT Tests (Signed Less Than)
// ============================================================================

test "SLT: basic signed less than - both positive" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x12}; // SLT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 5 < 10 = true (1)
    try frame.pushStack(10); // b (second from top)
    try frame.pushStack(5);  // a (top of stack)

    const initial_gas = frame.gas_remaining;

    // Execute SLT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.slt(&frame);

    // Verify result is 1 (true)
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "SLT: both negative" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x12}; // SLT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: -10 < -5 = true (1)
    const neg_10 = @as(u256, @bitCast(@as(i256, -10)));
    const neg_5 = @as(u256, @bitCast(@as(i256, -5)));
    try frame.pushStack(neg_5);  // b (second from top)
    try frame.pushStack(neg_10); // a (top of stack)

    // Execute SLT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.slt(&frame);

    // Verify result is 1 (true)
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);
}

test "SLT: negative less than positive" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x12}; // SLT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: -1 < 1 = true (1)
    const neg_1 = @as(u256, @bitCast(@as(i256, -1)));
    try frame.pushStack(1);      // b (second from top)
    try frame.pushStack(neg_1);  // a (top of stack)

    // Execute SLT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.slt(&frame);

    // Verify result is 1 (true)
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);
}

test "SLT: positive not less than negative" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x12}; // SLT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 1 < -1 = false (0)
    const neg_1 = @as(u256, @bitCast(@as(i256, -1)));
    try frame.pushStack(neg_1);  // b (second from top)
    try frame.pushStack(1);      // a (top of stack)

    // Execute SLT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.slt(&frame);

    // Verify result is 0 (false)
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "SLT: MIN_SIGNED boundary" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x12}; // SLT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: MIN_SIGNED < 0 = true (1)
    // MIN_SIGNED is the most negative value
    const MIN_SIGNED = @as(u256, 1) << 255;
    try frame.pushStack(0);          // b (second from top)
    try frame.pushStack(MIN_SIGNED); // a (top of stack)

    // Execute SLT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.slt(&frame);

    // Verify result is 1 (true)
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);
}

test "SLT: MAX_SIGNED boundary" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x12}; // SLT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 0 < MAX_SIGNED = true (1)
    // MAX_SIGNED is the most positive value (2^255 - 1)
    const MAX_SIGNED = (@as(u256, 1) << 255) - 1;
    try frame.pushStack(MAX_SIGNED); // b (second from top)
    try frame.pushStack(0);          // a (top of stack)

    // Execute SLT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.slt(&frame);

    // Verify result is 1 (true)
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);
}

test "SLT: equal values" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x12}; // SLT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: -5 < -5 = false (0)
    const neg_5 = @as(u256, @bitCast(@as(i256, -5)));
    try frame.pushStack(neg_5);
    try frame.pushStack(neg_5);

    // Execute SLT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.slt(&frame);

    // Verify result is 0 (false)
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "SLT: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x12}; // SLT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(5);

    // Execute SLT with insufficient stack
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    const result = CompHandlers.slt(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// SGT Tests (Signed Greater Than)
// ============================================================================

test "SGT: basic signed greater than - both positive" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x13}; // SGT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 10 > 5 = true (1)
    try frame.pushStack(5);  // b (second from top)
    try frame.pushStack(10); // a (top of stack)

    const initial_gas = frame.gas_remaining;

    // Execute SGT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.sgt(&frame);

    // Verify result is 1 (true)
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "SGT: both negative" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x13}; // SGT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: -5 > -10 = true (1)
    const neg_5 = @as(u256, @bitCast(@as(i256, -5)));
    const neg_10 = @as(u256, @bitCast(@as(i256, -10)));
    try frame.pushStack(neg_10); // b (second from top)
    try frame.pushStack(neg_5);  // a (top of stack)

    // Execute SGT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.sgt(&frame);

    // Verify result is 1 (true)
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);
}

test "SGT: positive greater than negative" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x13}; // SGT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 1 > -1 = true (1)
    const neg_1 = @as(u256, @bitCast(@as(i256, -1)));
    try frame.pushStack(neg_1);  // b (second from top)
    try frame.pushStack(1);      // a (top of stack)

    // Execute SGT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.sgt(&frame);

    // Verify result is 1 (true)
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);
}

test "SGT: negative not greater than positive" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x13}; // SGT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: -1 > 1 = false (0)
    const neg_1 = @as(u256, @bitCast(@as(i256, -1)));
    try frame.pushStack(1);      // b (second from top)
    try frame.pushStack(neg_1);  // a (top of stack)

    // Execute SGT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.sgt(&frame);

    // Verify result is 0 (false)
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "SGT: MIN_SIGNED boundary" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x13}; // SGT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 0 > MIN_SIGNED = true (1)
    const MIN_SIGNED = @as(u256, 1) << 255;
    try frame.pushStack(0);
    try frame.pushStack(MIN_SIGNED);

    // Execute SGT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.sgt(&frame);

    // Verify result is 1 (true)
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);
}

test "SGT: MAX_SIGNED boundary" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x13}; // SGT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: MAX_SIGNED > 0 = true (1)
    const MAX_SIGNED = (@as(u256, 1) << 255) - 1;
    try frame.pushStack(MAX_SIGNED);
    try frame.pushStack(0);

    // Execute SGT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.sgt(&frame);

    // Verify result is 1 (true)
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);
}

test "SGT: equal values" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x13}; // SGT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: -5 > -5 = false (0)
    const neg_5 = @as(u256, @bitCast(@as(i256, -5)));
    try frame.pushStack(neg_5);
    try frame.pushStack(neg_5);

    // Execute SGT
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.sgt(&frame);

    // Verify result is 0 (false)
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "SGT: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x13}; // SGT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(5);

    // Execute SGT with insufficient stack
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    const result = CompHandlers.sgt(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// EQ Tests (Equality)
// ============================================================================

test "EQ: equal values - true" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x14}; // EQ
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 42 == 42 = true (1)
    try frame.pushStack(42);
    try frame.pushStack(42);

    const initial_gas = frame.gas_remaining;

    // Execute EQ
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.eq(&frame);

    // Verify result is 1 (true)
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "EQ: unequal values - false" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x14}; // EQ
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 42 == 43 = false (0)
    try frame.pushStack(42);
    try frame.pushStack(43);

    // Execute EQ
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.eq(&frame);

    // Verify result is 0 (false)
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "EQ: both zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x14}; // EQ
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 0 == 0 = true (1)
    try frame.pushStack(0);
    try frame.pushStack(0);

    // Execute EQ
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.eq(&frame);

    // Verify result is 1 (true)
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);
}

test "EQ: max values" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x14}; // EQ
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: max == max = true (1)
    const max = std.math.maxInt(u256);
    try frame.pushStack(max);
    try frame.pushStack(max);

    // Execute EQ
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.eq(&frame);

    // Verify result is 1 (true)
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);
}

test "EQ: symmetry (order doesn't matter)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x14}; // EQ
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: 10 == 20 = false (0) - test symmetry
    try frame.pushStack(10);
    try frame.pushStack(20);

    // Execute EQ
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.eq(&frame);

    // Verify result is 0 (false)
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "EQ: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x14}; // EQ
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(5);

    // Execute EQ with insufficient stack
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    const result = CompHandlers.eq(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// ISZERO Tests
// ============================================================================

test "ISZERO: zero value - true" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x15}; // ISZERO
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: iszero(0) = true (1)
    try frame.pushStack(0);

    const initial_gas = frame.gas_remaining;

    // Execute ISZERO
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.iszero(&frame);

    // Verify result is 1 (true)
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "ISZERO: non-zero value - false" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x15}; // ISZERO
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: iszero(1) = false (0)
    try frame.pushStack(1);

    // Execute ISZERO
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.iszero(&frame);

    // Verify result is 0 (false)
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "ISZERO: large value - false" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x15}; // ISZERO
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: iszero(max) = false (0)
    try frame.pushStack(std.math.maxInt(u256));

    // Execute ISZERO
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.iszero(&frame);

    // Verify result is 0 (false)
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "ISZERO: double negation" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x15}; // ISZERO
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: iszero(42) then iszero again = 42 != 0 -> 0 -> iszero(0) = 1
    try frame.pushStack(42);

    // Execute first ISZERO
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    try CompHandlers.iszero(&frame);

    // Result should be 0 (42 is not zero)
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);

    // Reset PC for second operation
    frame.pc = 0;

    // Execute second ISZERO
    try CompHandlers.iszero(&frame);

    // Result should be 1 (0 is zero)
    try testing.expectEqual(@as(u256, 1), frame.stack.items[0]);
}

test "ISZERO: returns 0 or 1 only" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x15}; // ISZERO
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Test with various values to ensure result is always 0 or 1
    const test_values = [_]u256{ 0, 1, 2, 42, 255, 256, 1000, std.math.maxInt(u256) };

    for (test_values) |val| {
        frame.stack.clearRetainingCapacity();
        frame.pc = 0;
        try frame.pushStack(val);

        const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
        try CompHandlers.iszero(&frame);

        const result = frame.stack.items[0];
        // Result must be exactly 0 or 1
        try testing.expect(result == 0 or result == 1);

        // Verify correctness
        const expected: u256 = if (val == 0) 1 else 0;
        try testing.expectEqual(expected, result);
    }
}

test "ISZERO: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x15}; // ISZERO
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Don't push any value (need 1)

    // Execute ISZERO with insufficient stack
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    const result = CompHandlers.iszero(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "ISZERO: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x15}; // ISZERO
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 2); // Only 2 gas
    defer frame.deinit();

    try frame.pushStack(0);

    // Execute ISZERO with insufficient gas (need 3, have 2)
    const CompHandlers = @import("handlers_comparison.zig").Handlers(@TypeOf(frame));
    const result = CompHandlers.iszero(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}
