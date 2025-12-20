/// Unit tests for memory opcode handlers
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
// MLOAD Tests
// ============================================================================

test "MLOAD: basic load from offset 0" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x51}; // MLOAD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Write test pattern to memory (0xFF at byte 0, then zeros)
    try frame.writeMemory(0, 0xFF);

    // Setup: Load from offset 0
    try frame.pushStack(0);

    const initial_gas = frame.gas_remaining;

    // Execute MLOAD
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.mload(&frame);

    // Verify result (big-endian: 0xFF00...00)
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    const expected = @as(u256, 0xFF) << 248; // First byte in big-endian
    try testing.expectEqual(expected, frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep + memory expansion cost)
    // GasFastestStep = 3, memory expansion for 32 bytes = 3 gas
    try testing.expectEqual(@as(i64, 6), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "MLOAD: load from non-zero offset" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x51}; // MLOAD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Write test pattern to memory at offset 64
    try frame.writeMemory(64, 0xAB);
    try frame.writeMemory(65, 0xCD);

    // Setup: Load from offset 64
    try frame.pushStack(64);

    // Execute MLOAD
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.mload(&frame);

    // Verify result (big-endian: 0xABCD00...00)
    const expected = (@as(u256, 0xAB) << 248) | (@as(u256, 0xCD) << 240);
    try testing.expectEqual(expected, frame.stack.items[0]);
}

test "MLOAD: memory expansion cost increases" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x51}; // MLOAD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // First expansion: 0-32 bytes
    try frame.pushStack(0);
    const initial_gas1 = frame.gas_remaining;
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.mload(&frame);
    const cost1 = initial_gas1 - frame.gas_remaining;

    // Reset PC
    frame.pc = 0;
    _ = try frame.popStack(); // Remove result

    // Second expansion: 32-64 bytes (should cost more due to quadratic growth)
    try frame.pushStack(32);
    const initial_gas2 = frame.gas_remaining;
    try MemHandlers.mload(&frame);
    const cost2 = initial_gas2 - frame.gas_remaining;

    // Second expansion should cost at least as much as first
    // (quadratic component starts to matter)
    try testing.expect(cost2 >= cost1);
}

test "MLOAD: word-aligned size tracking" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x51}; // MLOAD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Load from offset 1 (should expand to 32 bytes)
    try frame.pushStack(1);
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.mload(&frame);

    // Verify memory size is word-aligned to 32 (covers bytes 0-32)
    try testing.expectEqual(@as(u32, 32), frame.memory_size);
}

test "MLOAD: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x51}; // MLOAD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Don't push offset
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    const result = MemHandlers.mload(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "MLOAD: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x51}; // MLOAD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 5); // Not enough gas
    defer frame.deinit();

    try frame.pushStack(0);

    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    const result = MemHandlers.mload(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

test "MLOAD: offset out of bounds error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x51}; // MLOAD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Push offset that doesn't fit in u32
    try frame.pushStack(std.math.maxInt(u256));

    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    const result = MemHandlers.mload(&frame);

    // Verify error
    try testing.expectError(error.OutOfBounds, result);
}

// ============================================================================
// MSTORE Tests
// ============================================================================

test "MSTORE: basic store at offset 0" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x52}; // MSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: Store 0x123456 at offset 0
    try frame.pushStack(0); // offset
    try frame.pushStack(0x123456); // value

    const initial_gas = frame.gas_remaining;

    // Execute MSTORE
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.mstore(&frame);

    // Verify memory contents (big-endian: last 3 bytes should be 0x123456)
    const byte29 = frame.readMemory(29);
    const byte30 = frame.readMemory(30);
    const byte31 = frame.readMemory(31);
    try testing.expectEqual(@as(u8, 0x12), byte29);
    try testing.expectEqual(@as(u8, 0x34), byte30);
    try testing.expectEqual(@as(u8, 0x56), byte31);

    // Verify gas consumed (GasFastestStep + memory expansion)
    try testing.expectEqual(@as(i64, 6), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "MSTORE: store at non-zero offset" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x52}; // MSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: Store 0xFF at offset 64
    try frame.pushStack(64); // offset
    try frame.pushStack(0xFF); // value

    // Execute MSTORE
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.mstore(&frame);

    // Verify memory contents (byte 95 should be 0xFF)
    const byte95 = frame.readMemory(95);
    try testing.expectEqual(@as(u8, 0xFF), byte95);

    // Verify memory size expanded to cover offset 64-95 (aligned to 96)
    try testing.expectEqual(@as(u32, 96), frame.memory_size);
}

test "MSTORE: full u256 value" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x52}; // MSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: Store max u256
    const max_value = std.math.maxInt(u256);
    try frame.pushStack(0); // offset
    try frame.pushStack(max_value); // value

    // Execute MSTORE
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.mstore(&frame);

    // Verify all 32 bytes are 0xFF
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        const byte = frame.readMemory(i);
        try testing.expectEqual(@as(u8, 0xFF), byte);
    }
}

test "MSTORE: word-aligned size tracking" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x52}; // MSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Store at offset 1 (should expand to 32 bytes to cover 1-32)
    try frame.pushStack(1); // offset
    try frame.pushStack(0x42); // value

    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.mstore(&frame);

    // Verify memory size is word-aligned to 32
    try testing.expectEqual(@as(u32, 32), frame.memory_size);
}

test "MSTORE: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x52}; // MSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(0);

    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    const result = MemHandlers.mstore(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "MSTORE: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x52}; // MSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 5); // Not enough gas
    defer frame.deinit();

    try frame.pushStack(0); // offset
    try frame.pushStack(0x42); // value

    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    const result = MemHandlers.mstore(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

test "MSTORE: offset out of bounds error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x52}; // MSTORE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Push offset that doesn't fit in u32
    try frame.pushStack(std.math.maxInt(u256)); // offset
    try frame.pushStack(0x42); // value

    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    const result = MemHandlers.mstore(&frame);

    // Verify error
    try testing.expectError(error.OutOfBounds, result);
}

// ============================================================================
// MSTORE8 Tests
// ============================================================================

test "MSTORE8: basic single byte store" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x53}; // MSTORE8
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: Store 0xFF at offset 0
    try frame.pushStack(0); // offset
    try frame.pushStack(0xFF); // value

    const initial_gas = frame.gas_remaining;

    // Execute MSTORE8
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.mstore8(&frame);

    // Verify memory contents
    const byte0 = frame.readMemory(0);
    try testing.expectEqual(@as(u8, 0xFF), byte0);

    // Verify gas consumed (GasFastestStep + memory expansion for 1 byte)
    try testing.expectEqual(@as(i64, 6), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "MSTORE8: truncates to single byte" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x53}; // MSTORE8
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: Store 0x123456 (should truncate to 0x56)
    try frame.pushStack(0); // offset
    try frame.pushStack(0x123456); // value

    // Execute MSTORE8
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.mstore8(&frame);

    // Verify only lower byte is stored
    const byte0 = frame.readMemory(0);
    try testing.expectEqual(@as(u8, 0x56), byte0);
}

test "MSTORE8: store at non-zero offset" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x53}; // MSTORE8
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: Store 0xAB at offset 100
    try frame.pushStack(100); // offset
    try frame.pushStack(0xAB); // value

    // Execute MSTORE8
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.mstore8(&frame);

    // Verify memory contents
    const byte100 = frame.readMemory(100);
    try testing.expectEqual(@as(u8, 0xAB), byte100);

    // Verify memory size expanded (aligned to 128)
    try testing.expectEqual(@as(u32, 128), frame.memory_size);
}

test "MSTORE8: word-aligned size tracking" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x53}; // MSTORE8
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Store at offset 31 (should expand to 32 bytes)
    try frame.pushStack(31); // offset
    try frame.pushStack(0x42); // value

    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.mstore8(&frame);

    // Verify memory size is word-aligned to 32
    try testing.expectEqual(@as(u32, 32), frame.memory_size);
}

test "MSTORE8: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x53}; // MSTORE8
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(0);

    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    const result = MemHandlers.mstore8(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "MSTORE8: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x53}; // MSTORE8
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 5); // Not enough gas
    defer frame.deinit();

    try frame.pushStack(0); // offset
    try frame.pushStack(0x42); // value

    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    const result = MemHandlers.mstore8(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

test "MSTORE8: offset out of bounds error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x53}; // MSTORE8
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Push offset that doesn't fit in u32
    try frame.pushStack(std.math.maxInt(u256)); // offset
    try frame.pushStack(0x42); // value

    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    const result = MemHandlers.mstore8(&frame);

    // Verify error
    try testing.expectError(error.OutOfBounds, result);
}

// ============================================================================
// MSIZE Tests
// ============================================================================

test "MSIZE: initial size is zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x59}; // MSIZE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    // Execute MSIZE
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.msize(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);

    // Verify gas consumed (GasQuickStep = 2)
    try testing.expectEqual(@as(i64, 2), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "MSIZE: after memory expansion" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x59}; // MSIZE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Expand memory by writing at offset 64
    try frame.writeMemory(64, 0xFF);

    // Execute MSIZE
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.msize(&frame);

    // Verify result is word-aligned (96 bytes covers offset 64)
    try testing.expectEqual(@as(u256, 96), frame.stack.items[0]);
}

test "MSIZE: tracks word-aligned size" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x59}; // MSIZE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Expand memory by writing at offset 1 (should align to 32)
    try frame.writeMemory(1, 0xAB);

    // Execute MSIZE
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.msize(&frame);

    // Verify result is word-aligned to 32
    try testing.expectEqual(@as(u256, 32), frame.stack.items[0]);
}

test "MSIZE: after multiple expansions" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x59}; // MSIZE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // First expansion
    try frame.writeMemory(31, 0xFF); // memory_size = 32

    // Second expansion
    try frame.writeMemory(63, 0xAA); // memory_size = 64

    // Third expansion
    try frame.writeMemory(100, 0xBB); // memory_size = 128

    // Execute MSIZE
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.msize(&frame);

    // Verify result reflects largest expansion
    try testing.expectEqual(@as(u256, 128), frame.stack.items[0]);
}

test "MSIZE: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x59}; // MSIZE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1); // Not enough gas
    defer frame.deinit();

    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    const result = MemHandlers.msize(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// MCOPY Tests
// ============================================================================

test "MCOPY: basic copy operation" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5e}; // MCOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Write source data at offset 0
    try frame.writeMemory(0, 0xAA);
    try frame.writeMemory(1, 0xBB);
    try frame.writeMemory(2, 0xCC);

    // Setup: Copy 3 bytes from offset 0 to offset 64
    try frame.pushStack(64); // dest
    try frame.pushStack(0);  // src
    try frame.pushStack(3);  // len

    const initial_gas = frame.gas_remaining;

    // Execute MCOPY
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.mcopy(&frame);

    // Verify destination has copied data
    const byte64 = frame.readMemory(64);
    const byte65 = frame.readMemory(65);
    const byte66 = frame.readMemory(66);
    try testing.expectEqual(@as(u8, 0xAA), byte64);
    try testing.expectEqual(@as(u8, 0xBB), byte65);
    try testing.expectEqual(@as(u8, 0xCC), byte66);

    // Verify gas consumed (GasFastestStep + memory expansion + copy cost)
    // GasFastestStep = 3, copy cost = 3 * ceil(3/32) = 3, expansion cost varies
    const gas_consumed = initial_gas - frame.gas_remaining;
    try testing.expect(gas_consumed >= 6); // At least base + copy

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "MCOPY: overlapping regions forward" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5e}; // MCOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Write source data
    try frame.writeMemory(0, 0x01);
    try frame.writeMemory(1, 0x02);
    try frame.writeMemory(2, 0x03);
    try frame.writeMemory(3, 0x04);

    // Setup: Copy overlapping (src=0, dest=2, len=2)
    try frame.pushStack(2);  // dest
    try frame.pushStack(0);  // src
    try frame.pushStack(2);  // len

    // Execute MCOPY
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.mcopy(&frame);

    // Verify correct behavior with overlap (uses temp buffer)
    const byte2 = frame.readMemory(2);
    const byte3 = frame.readMemory(3);
    try testing.expectEqual(@as(u8, 0x01), byte2);
    try testing.expectEqual(@as(u8, 0x02), byte3);
}

test "MCOPY: overlapping regions backward" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5e}; // MCOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Write source data
    try frame.writeMemory(2, 0xAA);
    try frame.writeMemory(3, 0xBB);
    try frame.writeMemory(4, 0xCC);

    // Setup: Copy overlapping backward (src=2, dest=0, len=3)
    try frame.pushStack(0);  // dest
    try frame.pushStack(2);  // src
    try frame.pushStack(3);  // len

    // Execute MCOPY
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.mcopy(&frame);

    // Verify correct behavior
    const byte0 = frame.readMemory(0);
    const byte1 = frame.readMemory(1);
    const byte2 = frame.readMemory(2);
    try testing.expectEqual(@as(u8, 0xAA), byte0);
    try testing.expectEqual(@as(u8, 0xBB), byte1);
    try testing.expectEqual(@as(u8, 0xCC), byte2);
}

test "MCOPY: zero length operation" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5e}; // MCOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: Zero-length copy (should charge gas but not expand memory)
    try frame.pushStack(1000); // dest
    try frame.pushStack(2000); // src
    try frame.pushStack(0);    // len

    const initial_gas = frame.gas_remaining;
    const initial_memory_size = frame.memory_size;

    // Execute MCOPY
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.mcopy(&frame);

    // Verify no memory expansion (zero-length copy doesn't expand memory)
    try testing.expectEqual(initial_memory_size, frame.memory_size);

    // Verify gas consumed (only GasFastestStep, no expansion or copy cost)
    try testing.expectEqual(@as(i64, 3), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "MCOPY: memory expansion for both source and destination" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5e}; // MCOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: Copy from offset 100 to 200 (both need expansion)
    try frame.pushStack(200); // dest
    try frame.pushStack(100); // src
    try frame.pushStack(10);  // len

    // Execute MCOPY
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.mcopy(&frame);

    // Verify memory expanded to cover both ranges (210 bytes, aligned to 224)
    try testing.expectEqual(@as(u32, 224), frame.memory_size);
}

test "MCOPY: copy cost scales with length" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5e}; // MCOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // First copy: 32 bytes (1 word)
    try frame.pushStack(64); // dest
    try frame.pushStack(0);  // src
    try frame.pushStack(32); // len

    const initial_gas1 = frame.gas_remaining;
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.mcopy(&frame);
    const cost1 = initial_gas1 - frame.gas_remaining;

    // Reset PC
    frame.pc = 0;

    // Second copy: 64 bytes (2 words, should cost more)
    try frame.pushStack(128); // dest
    try frame.pushStack(0);   // src
    try frame.pushStack(64);  // len

    const initial_gas2 = frame.gas_remaining;
    try MemHandlers.mcopy(&frame);
    const cost2 = initial_gas2 - frame.gas_remaining;

    // Second copy should cost more (more words to copy)
    try testing.expect(cost2 > cost1);
}

test "MCOPY: word-aligned size tracking" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5e}; // MCOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Copy to offset 1, length 1 (should align to 32)
    try frame.pushStack(1);  // dest
    try frame.pushStack(0);  // src
    try frame.pushStack(1);  // len

    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.mcopy(&frame);

    // Verify memory size is word-aligned
    try testing.expectEqual(@as(u32, 32), frame.memory_size);
}

test "MCOPY: hardfork check - pre-Cancun" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .SHANGHAI);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5e}; // MCOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .SHANGHAI, 1_000_000);
    defer frame.deinit();

    // Setup stack
    try frame.pushStack(64); // dest
    try frame.pushStack(0);  // src
    try frame.pushStack(3);  // len

    // Execute MCOPY
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    const result = MemHandlers.mcopy(&frame);

    // Verify error (MCOPY not available before Cancun)
    try testing.expectError(error.InvalidOpcode, result);
}

test "MCOPY: hardfork check - Cancun and after" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5e}; // MCOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Write source data
    try frame.writeMemory(0, 0xFF);

    // Setup stack
    try frame.pushStack(32); // dest
    try frame.pushStack(0);  // src
    try frame.pushStack(1);  // len

    // Execute MCOPY
    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    try MemHandlers.mcopy(&frame);

    // Verify success (should work in Cancun)
    const byte32 = frame.readMemory(32);
    try testing.expectEqual(@as(u8, 0xFF), byte32);
}

test "MCOPY: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5e}; // MCOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 2 values (need 3)
    try frame.pushStack(64);
    try frame.pushStack(0);

    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    const result = MemHandlers.mcopy(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "MCOPY: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5e}; // MCOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 5); // Not enough gas
    defer frame.deinit();

    try frame.pushStack(64); // dest
    try frame.pushStack(0);  // src
    try frame.pushStack(32); // len

    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    const result = MemHandlers.mcopy(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

test "MCOPY: offset out of bounds error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5e}; // MCOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Push dest offset that doesn't fit in u32
    try frame.pushStack(std.math.maxInt(u256)); // dest
    try frame.pushStack(0);  // src
    try frame.pushStack(10); // len

    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    const result = MemHandlers.mcopy(&frame);

    // Verify error (after gas is charged, bounds checking fails)
    try testing.expectError(error.OutOfBounds, result);
}

test "MCOPY: large length triggers out of gas" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5e}; // MCOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Push massive length (copy cost will be astronomical)
    const huge_len: u256 = @as(u256, std.math.maxInt(u64)) + 1;
    try frame.pushStack(0);       // dest
    try frame.pushStack(0);       // src
    try frame.pushStack(huge_len); // len

    const MemHandlers = @import("handlers_memory.zig").Handlers(@TypeOf(frame));
    const result = MemHandlers.mcopy(&frame);

    // Verify error (huge copy cost exceeds available gas)
    try testing.expectError(error.OutOfGas, result);
}
