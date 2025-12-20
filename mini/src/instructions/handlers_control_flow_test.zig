/// Unit tests for control flow opcode handlers
const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;
const Hardfork = primitives.Hardfork;
const Address = primitives.Address.Address;
const evm_mod = @import("../evm.zig");
const Evm = evm_mod.Evm(.{});
const Frame = @import("../frame.zig").Frame(.{});
const Bytecode = @import("../bytecode.zig").Bytecode;

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
// STOP Tests
// ============================================================================

test "STOP: halts execution" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x00}; // STOP
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    try testing.expectEqual(false, frame.stopped);

    // Execute STOP
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    try ControlFlowHandlers.stop(&frame);

    // Verify stopped flag is set
    try testing.expectEqual(true, frame.stopped);

    // Verify PC is NOT incremented (STOP doesn't increment PC)
    try testing.expectEqual(@as(u32, 0), frame.pc);
}

test "STOP: sets stopped flag without incrementing PC" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x00}; // STOP
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const initial_pc = frame.pc;
    const initial_gas = frame.gas_remaining;

    // Execute STOP
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    try ControlFlowHandlers.stop(&frame);

    // Verify PC unchanged
    try testing.expectEqual(initial_pc, frame.pc);

    // Verify no gas consumed
    try testing.expectEqual(initial_gas, frame.gas_remaining);

    // Verify stopped flag
    try testing.expectEqual(true, frame.stopped);
}

// ============================================================================
// JUMP Tests
// ============================================================================

test "JUMP: basic unconditional jump to valid JUMPDEST" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    // Bytecode: JUMP to position 5, which has JUMPDEST
    const bytecode = &[_]u8{
        0x56, // JUMP at 0
        0x00, // padding
        0x00, // padding
        0x00, // padding
        0x00, // padding
        0x5b, // JUMPDEST at 5
    };
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Push destination address
    try frame.pushStack(5);

    const initial_gas = frame.gas_remaining;

    // Execute JUMP
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    try ControlFlowHandlers.jump(&frame);

    // Verify PC was set to destination
    try testing.expectEqual(@as(u32, 5), frame.pc);

    // Verify gas consumed (GasMidStep = 8)
    try testing.expectEqual(@as(i64, 8), initial_gas - frame.gas_remaining);

    // Verify stack is empty after pop
    try testing.expectEqual(@as(usize, 0), frame.stack.items.len);
}

test "JUMP: invalid jump destination error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    // Bytecode without JUMPDEST at position 5
    const bytecode = &[_]u8{
        0x56, // JUMP at 0
        0x00, // padding
        0x00, // padding
        0x00, // padding
        0x00, // padding
        0x00, // NOT JUMPDEST at 5
    };
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Push invalid destination
    try frame.pushStack(5);

    // Execute JUMP
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    const result = ControlFlowHandlers.jump(&frame);

    // Verify InvalidJump error
    try testing.expectError(error.InvalidJump, result);
}

test "JUMP: jump to push data is invalid" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    // Bytecode: PUSH1 with 0x5b in data (not a valid JUMPDEST)
    const bytecode = &[_]u8{
        0x56, // JUMP at 0
        0x60, // PUSH1 at 1
        0x5b, // data 0x5b at 2 (looks like JUMPDEST but inside PUSH data)
        0x00, // padding
    };
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Try to jump to position 2 (which is inside PUSH1 data)
    try frame.pushStack(2);

    // Execute JUMP
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    const result = ControlFlowHandlers.jump(&frame);

    // Verify InvalidJump error (bytecode analysis should not mark this as valid)
    try testing.expectError(error.InvalidJump, result);
}

test "JUMP: out of bounds destination error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x56}; // JUMP
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Push destination beyond u32 max
    const huge_dest: u256 = @as(u256, std.math.maxInt(u32)) + 1;
    try frame.pushStack(huge_dest);

    // Execute JUMP
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    const result = ControlFlowHandlers.jump(&frame);

    // Verify OutOfBounds error
    try testing.expectError(error.OutOfBounds, result);
}

test "JUMP: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x56}; // JUMP
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Don't push destination (stack underflow)

    // Execute JUMP
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    const result = ControlFlowHandlers.jump(&frame);

    // Verify StackUnderflow error
    try testing.expectError(error.StackUnderflow, result);
}

test "JUMP: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x56, 0x5b}; // JUMP, JUMPDEST
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 7); // Only 7 gas (need 8)
    defer frame.deinit();

    try frame.pushStack(1);

    // Execute JUMP with insufficient gas
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    const result = ControlFlowHandlers.jump(&frame);

    // Verify OutOfGas error
    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// JUMPI Tests
// ============================================================================

test "JUMPI: conditional jump when condition is non-zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{
        0x57, // JUMPI at 0
        0x00, // padding
        0x00, // padding
        0x5b, // JUMPDEST at 3
    };
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Push destination and non-zero condition
    try frame.pushStack(3); // destination
    try frame.pushStack(1); // condition (non-zero = true)

    const initial_gas = frame.gas_remaining;

    // Execute JUMPI
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    try ControlFlowHandlers.jumpi(&frame);

    // Verify PC was set to destination
    try testing.expectEqual(@as(u32, 3), frame.pc);

    // Verify gas consumed (GasSlowStep = 10)
    try testing.expectEqual(@as(i64, 10), initial_gas - frame.gas_remaining);
}

test "JUMPI: no jump when condition is zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{
        0x57, // JUMPI at 0
        0x00, // padding
        0x00, // padding
        0x5b, // JUMPDEST at 3
    };
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Push destination and zero condition
    try frame.pushStack(3); // destination
    try frame.pushStack(0); // condition (zero = false)

    const initial_gas = frame.gas_remaining;

    // Execute JUMPI
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    try ControlFlowHandlers.jumpi(&frame);

    // Verify PC was incremented (not jumped)
    try testing.expectEqual(@as(u32, 1), frame.pc);

    // Verify gas consumed (GasSlowStep = 10)
    try testing.expectEqual(@as(i64, 10), initial_gas - frame.gas_remaining);
}

test "JUMPI: jumps with max u256 condition" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x57, 0x5b}; // JUMPI, JUMPDEST
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Push destination and max condition
    try frame.pushStack(1); // destination
    try frame.pushStack(std.math.maxInt(u256)); // condition (non-zero)

    // Execute JUMPI
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    try ControlFlowHandlers.jumpi(&frame);

    // Verify PC was set to destination
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "JUMPI: invalid jump destination error when condition is true" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{
        0x57, // JUMPI at 0
        0x00, // NOT JUMPDEST at 1
    };
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Push invalid destination and non-zero condition
    try frame.pushStack(1); // invalid destination
    try frame.pushStack(1); // condition (true)

    // Execute JUMPI
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    const result = ControlFlowHandlers.jumpi(&frame);

    // Verify InvalidJump error
    try testing.expectError(error.InvalidJump, result);
}

test "JUMPI: no error when condition is false even if destination invalid" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{
        0x57, // JUMPI at 0
        0x00, // NOT JUMPDEST at 1
    };
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Push invalid destination but zero condition
    try frame.pushStack(1); // invalid destination (not checked when condition is false)
    try frame.pushStack(0); // condition (false)

    // Execute JUMPI
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    try ControlFlowHandlers.jumpi(&frame);

    // Verify no error and PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "JUMPI: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x57}; // JUMPI
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(1);

    // Execute JUMPI
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    const result = ControlFlowHandlers.jumpi(&frame);

    // Verify StackUnderflow error
    try testing.expectError(error.StackUnderflow, result);
}

test "JUMPI: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x57, 0x5b}; // JUMPI, JUMPDEST
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 9); // Only 9 gas (need 10)
    defer frame.deinit();

    try frame.pushStack(1); // destination
    try frame.pushStack(1); // condition

    // Execute JUMPI with insufficient gas
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    const result = ControlFlowHandlers.jumpi(&frame);

    // Verify OutOfGas error
    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// JUMPDEST Tests
// ============================================================================

test "JUMPDEST: consumes gas and increments PC" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5b}; // JUMPDEST
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    // Execute JUMPDEST
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    try ControlFlowHandlers.jumpdest(&frame);

    // Verify gas consumed (JumpdestGas = 1)
    try testing.expectEqual(@as(i64, 1), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "JUMPDEST: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5b}; // JUMPDEST
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 0); // No gas
    defer frame.deinit();

    // Execute JUMPDEST with insufficient gas
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    const result = ControlFlowHandlers.jumpdest(&frame);

    // Verify OutOfGas error
    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// PC Tests
// ============================================================================

test "PC: pushes current program counter" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x58}; // PC
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Set PC to specific value
    frame.pc = 42;

    const initial_gas = frame.gas_remaining;

    // Execute PC
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    try ControlFlowHandlers.pc(&frame);

    // Verify PC value was pushed to stack
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 42), frame.stack.items[0]);

    // Verify gas consumed (GasQuickStep = 2)
    try testing.expectEqual(@as(i64, 2), initial_gas - frame.gas_remaining);

    // Verify PC incremented after push
    try testing.expectEqual(@as(u32, 43), frame.pc);
}

test "PC: pushes zero at start" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x58}; // PC
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // PC starts at 0

    // Execute PC
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    try ControlFlowHandlers.pc(&frame);

    // Verify PC value 0 was pushed
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);

    // Verify PC incremented to 1
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "PC: stack overflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x58}; // PC
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Fill stack to max (1024 items)
    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        try frame.pushStack(i);
    }

    // Execute PC with full stack
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    const result = ControlFlowHandlers.pc(&frame);

    // Verify StackOverflow error
    try testing.expectError(error.StackOverflow, result);
}

test "PC: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x58}; // PC
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1); // Only 1 gas (need 2)
    defer frame.deinit();

    // Execute PC with insufficient gas
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    const result = ControlFlowHandlers.pc(&frame);

    // Verify OutOfGas error
    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// RETURN Tests
// ============================================================================

test "RETURN: basic return with data" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf3}; // RETURN
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Write some data to memory
    try frame.writeMemory(0, 0x12);
    try frame.writeMemory(1, 0x34);
    try frame.writeMemory(2, 0x56);
    try frame.writeMemory(3, 0x78);

    // Push offset and length
    try frame.pushStack(0); // offset
    try frame.pushStack(4); // length

    // Execute RETURN
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    try ControlFlowHandlers.ret(&frame);

    // Verify stopped flag is set
    try testing.expectEqual(true, frame.stopped);

    // Verify output contains the data
    try testing.expectEqual(@as(usize, 4), frame.output.len);
    try testing.expectEqual(@as(u8, 0x12), frame.output[0]);
    try testing.expectEqual(@as(u8, 0x34), frame.output[1]);
    try testing.expectEqual(@as(u8, 0x56), frame.output[2]);
    try testing.expectEqual(@as(u8, 0x78), frame.output[3]);
}

test "RETURN: empty return (length zero)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf3}; // RETURN
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Push offset and zero length
    try frame.pushStack(0); // offset
    try frame.pushStack(0); // length (zero)

    // Execute RETURN
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    try ControlFlowHandlers.ret(&frame);

    // Verify stopped flag is set
    try testing.expectEqual(true, frame.stopped);

    // Verify output is empty
    try testing.expectEqual(@as(usize, 0), frame.output.len);
}

test "RETURN: memory expansion cost" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf3}; // RETURN
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    // Return data from high memory address (requires expansion)
    try frame.pushStack(1000); // offset
    try frame.pushStack(32); // length

    // Execute RETURN
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    try ControlFlowHandlers.ret(&frame);

    // Verify gas was consumed for memory expansion
    const gas_used = initial_gas - frame.gas_remaining;
    try testing.expect(gas_used > 0);

    // Verify memory was expanded
    try testing.expect(frame.memory_size >= 1024);

    // Verify stopped
    try testing.expectEqual(true, frame.stopped);
}

test "RETURN: out of bounds offset error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf3}; // RETURN
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Push offset beyond u32 max
    const huge_offset: u256 = @as(u256, std.math.maxInt(u32)) + 1;
    try frame.pushStack(huge_offset); // offset
    try frame.pushStack(1); // length

    // Execute RETURN
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    const result = ControlFlowHandlers.ret(&frame);

    // Verify OutOfBounds error
    try testing.expectError(error.OutOfBounds, result);
}

test "RETURN: out of bounds length error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf3}; // RETURN
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Push length beyond u32 max
    const huge_length: u256 = @as(u256, std.math.maxInt(u32)) + 1;
    try frame.pushStack(0); // offset
    try frame.pushStack(huge_length); // length

    // Execute RETURN
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    const result = ControlFlowHandlers.ret(&frame);

    // Verify OutOfBounds error
    try testing.expectError(error.OutOfBounds, result);
}

test "RETURN: offset + length overflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf3}; // RETURN
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Push values that would overflow when added
    try frame.pushStack(std.math.maxInt(u32)); // offset
    try frame.pushStack(1); // length (offset + length overflows)

    // Execute RETURN
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    const result = ControlFlowHandlers.ret(&frame);

    // Verify OutOfBounds error
    try testing.expectError(error.OutOfBounds, result);
}

test "RETURN: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf3}; // RETURN
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(0);

    // Execute RETURN
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    const result = ControlFlowHandlers.ret(&frame);

    // Verify StackUnderflow error
    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// REVERT Tests
// ============================================================================

test "REVERT: basic revert with data" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xfd}; // REVERT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Write some data to memory
    try frame.writeMemory(0, 0xaa);
    try frame.writeMemory(1, 0xbb);
    try frame.writeMemory(2, 0xcc);
    try frame.writeMemory(3, 0xdd);

    // Push offset and length
    try frame.pushStack(0); // offset
    try frame.pushStack(4); // length

    // Execute REVERT
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    try ControlFlowHandlers.revert(&frame);

    // Verify reverted flag is set
    try testing.expectEqual(true, frame.reverted);

    // Verify stopped flag is NOT set (revert doesn't set stopped)
    try testing.expectEqual(false, frame.stopped);

    // Verify output contains the data
    try testing.expectEqual(@as(usize, 4), frame.output.len);
    try testing.expectEqual(@as(u8, 0xaa), frame.output[0]);
    try testing.expectEqual(@as(u8, 0xbb), frame.output[1]);
    try testing.expectEqual(@as(u8, 0xcc), frame.output[2]);
    try testing.expectEqual(@as(u8, 0xdd), frame.output[3]);
}

test "REVERT: empty revert (length zero)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xfd}; // REVERT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Push offset and zero length
    try frame.pushStack(0); // offset
    try frame.pushStack(0); // length (zero)

    // Execute REVERT
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    try ControlFlowHandlers.revert(&frame);

    // Verify reverted flag is set
    try testing.expectEqual(true, frame.reverted);

    // Verify output is empty
    try testing.expectEqual(@as(usize, 0), frame.output.len);
}

test "REVERT: available in Byzantium and later" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BYZANTIUM);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xfd}; // REVERT
    var frame = try createTestFrame(allocator, evm, bytecode, .BYZANTIUM, 1_000_000);
    defer frame.deinit();

    try frame.pushStack(0); // offset
    try frame.pushStack(0); // length

    // Execute REVERT (should work in Byzantium)
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    try ControlFlowHandlers.revert(&frame);

    // Verify reverted flag is set
    try testing.expectEqual(true, frame.reverted);
}

test "REVERT: invalid opcode before Byzantium" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .TANGERINE_WHISTLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xfd}; // REVERT
    var frame = try createTestFrame(allocator, evm, bytecode, .TANGERINE_WHISTLE, 1_000_000);
    defer frame.deinit();

    try frame.pushStack(0); // offset
    try frame.pushStack(0); // length

    // Execute REVERT (should fail before Byzantium)
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    const result = ControlFlowHandlers.revert(&frame);

    // Verify InvalidOpcode error
    try testing.expectError(error.InvalidOpcode, result);
}

test "REVERT: memory expansion cost" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xfd}; // REVERT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    // Revert with data from high memory address (requires expansion)
    try frame.pushStack(2000); // offset
    try frame.pushStack(32); // length

    // Execute REVERT
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    try ControlFlowHandlers.revert(&frame);

    // Verify gas was consumed for memory expansion
    const gas_used = initial_gas - frame.gas_remaining;
    try testing.expect(gas_used > 0);

    // Verify memory was expanded
    try testing.expect(frame.memory_size >= 2032);

    // Verify reverted
    try testing.expectEqual(true, frame.reverted);
}

test "REVERT: out of bounds offset error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xfd}; // REVERT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Push offset beyond u32 max
    const huge_offset: u256 = @as(u256, std.math.maxInt(u32)) + 1;
    try frame.pushStack(huge_offset); // offset
    try frame.pushStack(1); // length

    // Execute REVERT
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    const result = ControlFlowHandlers.revert(&frame);

    // Verify OutOfBounds error
    try testing.expectError(error.OutOfBounds, result);
}

test "REVERT: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xfd}; // REVERT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 1 value (need 2)
    try frame.pushStack(0);

    // Execute REVERT
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    const result = ControlFlowHandlers.revert(&frame);

    // Verify StackUnderflow error
    try testing.expectError(error.StackUnderflow, result);
}

test "REVERT: returns output data for error message" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xfd}; // REVERT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Write error message to memory (simulating ABI-encoded revert reason)
    // Error selector: 0x08c379a0 (Error(string))
    try frame.writeMemory(0, 0x08);
    try frame.writeMemory(1, 0xc3);
    try frame.writeMemory(2, 0x79);
    try frame.writeMemory(3, 0xa0);

    try frame.pushStack(0); // offset
    try frame.pushStack(4); // length

    // Execute REVERT
    const ControlFlowHandlers = @import("handlers_control_flow.zig").Handlers(@TypeOf(frame));
    try ControlFlowHandlers.revert(&frame);

    // Verify output contains error selector
    try testing.expectEqual(@as(usize, 4), frame.output.len);
    try testing.expectEqual(@as(u8, 0x08), frame.output[0]);
    try testing.expectEqual(@as(u8, 0xc3), frame.output[1]);
    try testing.expectEqual(@as(u8, 0x79), frame.output[2]);
    try testing.expectEqual(@as(u8, 0xa0), frame.output[3]);
}
