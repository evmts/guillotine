/// Unit tests for stack manipulation opcode handlers
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
// POP Tests
// ============================================================================

test "POP: removes top stack item" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x50}; // POP
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: push 3 values
    try frame.pushStack(100);
    try frame.pushStack(200);
    try frame.pushStack(300);

    const initial_gas = frame.gas_remaining;

    // Execute POP
    const StackHandlers = @import("handlers_stack.zig").Handlers(@TypeOf(frame));
    try StackHandlers.pop(&frame);

    // Verify stack depth decreased by 1
    try testing.expectEqual(@as(usize, 2), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 200), frame.stack.items[frame.stack.items.len - 1]);

    // Verify gas consumed (GasQuickStep = 2)
    try testing.expectEqual(@as(i64, 2), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "POP: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x50}; // POP
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Execute POP on empty stack
    const StackHandlers = @import("handlers_stack.zig").Handlers(@TypeOf(frame));
    const result = StackHandlers.pop(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "POP: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x50}; // POP
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1); // Only 1 gas
    defer frame.deinit();

    try frame.pushStack(100);

    // Execute POP with insufficient gas (need 2, have 1)
    const StackHandlers = @import("handlers_stack.zig").Handlers(@TypeOf(frame));
    const result = StackHandlers.pop(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// PUSH0 Tests
// ============================================================================

test "PUSH0: pushes zero onto stack (Shanghai+)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .SHANGHAI);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5f}; // PUSH0
    var frame = try createTestFrame(allocator, evm, bytecode, .SHANGHAI, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    // Execute PUSH0
    const StackHandlers = @import("handlers_stack.zig").Handlers(@TypeOf(frame));
    try StackHandlers.push(&frame, 0x5f);

    // Verify stack has 0 on top
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);

    // Verify gas consumed (GasQuickStep = 2)
    try testing.expectEqual(@as(i64, 2), initial_gas - frame.gas_remaining);

    // Verify PC incremented by 1 (no immediate bytes)
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "PUSH0: invalid before Shanghai" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .LONDON);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5f}; // PUSH0
    var frame = try createTestFrame(allocator, evm, bytecode, .LONDON, 1_000_000);
    defer frame.deinit();

    // Execute PUSH0 on London (pre-Shanghai)
    const StackHandlers = @import("handlers_stack.zig").Handlers(@TypeOf(frame));
    const result = StackHandlers.push(&frame, 0x5f);

    // Verify error
    try testing.expectError(error.InvalidOpcode, result);
}

// ============================================================================
// PUSH1-PUSH32 Tests
// ============================================================================

test "PUSH1: pushes single byte" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{ 0x60, 0x42 }; // PUSH1 0x42
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    // Execute PUSH1
    const StackHandlers = @import("handlers_stack.zig").Handlers(@TypeOf(frame));
    try StackHandlers.push(&frame, 0x60);

    // Verify stack has 0x42 on top
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 0x42), frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented by 2 (opcode + 1 byte)
    try testing.expectEqual(@as(u32, 2), frame.pc);
}

test "PUSH2: pushes two bytes" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{ 0x61, 0x12, 0x34 }; // PUSH2 0x1234
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    // Execute PUSH2
    const StackHandlers = @import("handlers_stack.zig").Handlers(@TypeOf(frame));
    try StackHandlers.push(&frame, 0x61);

    // Verify stack has 0x1234 on top
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 0x1234), frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented by 3 (opcode + 2 bytes)
    try testing.expectEqual(@as(u32, 3), frame.pc);
}

test "PUSH32: pushes all 32 bytes" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    // PUSH32 with max value (all 0xff)
    var bytecode: [33]u8 = undefined;
    bytecode[0] = 0x7f; // PUSH32
    @memset(bytecode[1..], 0xff);

    var frame = try createTestFrame(allocator, evm, &bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    // Execute PUSH32
    const StackHandlers = @import("handlers_stack.zig").Handlers(@TypeOf(frame));
    try StackHandlers.push(&frame, 0x7f);

    // Verify stack has max u256 on top
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, std.math.maxInt(u256)), frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented by 33 (opcode + 32 bytes)
    try testing.expectEqual(@as(u32, 33), frame.pc);
}

test "PUSH: insufficient bytecode error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    // PUSH2 with only 1 byte of data (should have 2)
    const bytecode = &[_]u8{ 0x61, 0x12 }; // PUSH2 with incomplete data
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Execute PUSH2 (expecting 2 bytes, only 1 available)
    const StackHandlers = @import("handlers_stack.zig").Handlers(@TypeOf(frame));
    const result = StackHandlers.push(&frame, 0x61);

    // Verify error
    try testing.expectError(error.InvalidPush, result);
}

test "PUSH: stack overflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{ 0x60, 0x42 }; // PUSH1 0x42
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Fill stack to maximum (1024 items)
    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        try frame.pushStack(i);
    }

    // Execute PUSH1 on full stack
    const StackHandlers = @import("handlers_stack.zig").Handlers(@TypeOf(frame));
    const result = StackHandlers.push(&frame, 0x60);

    // Verify error
    try testing.expectError(error.StackOverflow, result);
}

// ============================================================================
// DUP1-DUP16 Tests
// ============================================================================

test "DUP1: duplicates top stack item" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x80}; // DUP1
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: push 3 values
    try frame.pushStack(100);
    try frame.pushStack(200);
    try frame.pushStack(300);

    const initial_gas = frame.gas_remaining;

    // Execute DUP1
    const StackHandlers = @import("handlers_stack.zig").Handlers(@TypeOf(frame));
    try StackHandlers.dup(&frame, 0x80);

    // Verify stack depth increased by 1
    try testing.expectEqual(@as(usize, 4), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 300), frame.stack.items[frame.stack.items.len - 1]);

    // Verify second item is also 300
    try testing.expectEqual(@as(u256, 300), frame.stack.items[frame.stack.items.len - 2]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "DUP2: duplicates second stack item" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x81}; // DUP2
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: push 3 values
    try frame.pushStack(100);
    try frame.pushStack(200);
    try frame.pushStack(300);

    // Execute DUP2
    const StackHandlers = @import("handlers_stack.zig").Handlers(@TypeOf(frame));
    try StackHandlers.dup(&frame, 0x81);

    // Verify stack depth increased by 1
    try testing.expectEqual(@as(usize, 4), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 200), frame.stack.items[frame.stack.items.len - 1]); // Second item duplicated to top
}

test "DUP16: duplicates sixteenth stack item" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x8f}; // DUP16
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Create stack with 16 items
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        try frame.pushStack(i + 1);
    }

    // Execute DUP16
    const StackHandlers = @import("handlers_stack.zig").Handlers(@TypeOf(frame));
    try StackHandlers.dup(&frame, 0x8f);

    // Verify stack depth increased by 1
    try testing.expectEqual(@as(usize, 17), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 1), frame.stack.items[frame.stack.items.len - 1]); // 16th item (bottom) duplicated to top
}

test "DUP: stack underflow when stack too shallow" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x82}; // DUP3
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: Only 2 items, need 3 for DUP3
    try frame.pushStack(100);
    try frame.pushStack(200);

    // Execute DUP3 with insufficient stack depth
    const StackHandlers = @import("handlers_stack.zig").Handlers(@TypeOf(frame));
    const result = StackHandlers.dup(&frame, 0x82);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "DUP: stack overflow when stack at limit" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x80}; // DUP1
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Fill stack to maximum (1024 items)
    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        try frame.pushStack(i);
    }

    // Execute DUP1 on full stack
    const StackHandlers = @import("handlers_stack.zig").Handlers(@TypeOf(frame));
    const result = StackHandlers.dup(&frame, 0x80);

    // Verify error
    try testing.expectError(error.StackOverflow, result);
}

// ============================================================================
// SWAP1-SWAP16 Tests
// ============================================================================

test "SWAP1: swaps top two stack items" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x90}; // SWAP1
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: push 3 values
    try frame.pushStack(100);
    try frame.pushStack(200);
    try frame.pushStack(300);

    const initial_gas = frame.gas_remaining;

    // Execute SWAP1
    const StackHandlers = @import("handlers_stack.zig").Handlers(@TypeOf(frame));
    try StackHandlers.swap(&frame, 0x90);

    // Verify stack depth unchanged
    try testing.expectEqual(@as(usize, 3), frame.stack.items.len);

    // Verify top is now 200 (was second)
    try testing.expectEqual(@as(u256, 200), frame.stack.items[frame.stack.items.len - 1]);

    // Verify second is now 300 (was top)
    try testing.expectEqual(@as(u256, 300), frame.stack.items[frame.stack.items.len - 2]);

    // Verify third is unchanged
    try testing.expectEqual(@as(u256, 100), frame.stack.items[frame.stack.items.len - 3]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "SWAP2: swaps top with third item" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x91}; // SWAP2
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: push 3 values
    try frame.pushStack(100);
    try frame.pushStack(200);
    try frame.pushStack(300);

    // Execute SWAP2
    const StackHandlers = @import("handlers_stack.zig").Handlers(@TypeOf(frame));
    try StackHandlers.swap(&frame, 0x91);

    // Verify stack depth unchanged
    try testing.expectEqual(@as(usize, 3), frame.stack.items.len);

    // Verify top is now 100 (was third)
    try testing.expectEqual(@as(u256, 100), frame.stack.items[frame.stack.items.len - 1]);

    // Verify second is unchanged
    try testing.expectEqual(@as(u256, 200), frame.stack.items[frame.stack.items.len - 2]);

    // Verify third is now 300 (was top)
    try testing.expectEqual(@as(u256, 300), frame.stack.items[frame.stack.items.len - 3]);
}

test "SWAP16: swaps top with seventeenth item" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x9f}; // SWAP16
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Create stack with 17 items
    var i: usize = 0;
    while (i < 17) : (i += 1) {
        try frame.pushStack(i + 1);
    }

    // Execute SWAP16
    const StackHandlers = @import("handlers_stack.zig").Handlers(@TypeOf(frame));
    try StackHandlers.swap(&frame, 0x9f);

    // Verify stack depth unchanged
    try testing.expectEqual(@as(usize, 17), frame.stack.items.len);

    // Verify top is now 1 (was 17th from top)
    try testing.expectEqual(@as(u256, 1), frame.stack.items[frame.stack.items.len - 1]);

    // Verify 17th from top is now 17 (was top)
    try testing.expectEqual(@as(u256, 17), frame.stack.items[frame.stack.items.len - 17]);
}

test "SWAP: stack underflow when not enough items" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x91}; // SWAP2
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: Only 1 item, need 3 for SWAP2
    try frame.pushStack(100);

    // Execute SWAP2 with insufficient stack depth
    const StackHandlers = @import("handlers_stack.zig").Handlers(@TypeOf(frame));
    const result = StackHandlers.swap(&frame, 0x91);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "SWAP1: stack underflow with only one item" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x90}; // SWAP1
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: Only 1 item, need 2 for SWAP1
    try frame.pushStack(100);

    // Execute SWAP1 with insufficient stack depth
    const StackHandlers = @import("handlers_stack.zig").Handlers(@TypeOf(frame));
    const result = StackHandlers.swap(&frame, 0x90);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}
