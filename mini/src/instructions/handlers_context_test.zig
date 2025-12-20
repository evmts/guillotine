/// Unit tests for execution context opcode handlers
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

// Helper to create a test frame with custom parameters
fn createTestFrameWithParams(
    allocator: std.mem.Allocator,
    evm: *Evm,
    bytecode: []const u8,
    hardfork: Hardfork,
    gas: i64,
    caller: Address,
    address: Address,
    value: u256,
    calldata: []const u8,
) !Frame {
    return try Frame.init(
        allocator,
        bytecode,
        gas,
        caller,
        address,
        value,
        calldata,
        @ptrCast(evm),
        hardfork,
        false, // is_static
    );
}

// ============================================================================
// ADDRESS Tests
// ============================================================================

test "ADDRESS: returns current contract address" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x30}; // ADDRESS
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    // Execute ADDRESS
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.address(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    const expected = Address.toU256(frame.address);
    try testing.expectEqual(expected, frame.stack.items[0]);

    // Verify gas consumed (GasQuickStep = 2)
    try testing.expectEqual(@as(i64, GasConstants.GasQuickStep), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "ADDRESS: gas cost correct" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x30}; // ADDRESS
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    // Execute ADDRESS
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.address(&frame);

    // Verify gas consumed is exactly GasQuickStep
    try testing.expectEqual(@as(i64, GasConstants.GasQuickStep), initial_gas - frame.gas_remaining);
}

test "ADDRESS: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x30}; // ADDRESS
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1); // Only 1 gas
    defer frame.deinit();

    // Execute ADDRESS with insufficient gas (need 2, have 1)
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    const result = ContextHandlers.address(&frame);

    // Verify error
    try testing.expectError(error.OutOfGas, result);
}

// ============================================================================
// BALANCE Tests
// ============================================================================

test "BALANCE: returns account balance" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x31}; // BALANCE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Set a balance for the test address
    const test_addr = try Address.fromHex("0x1234567890123456789012345678901234567890");
    const test_balance: u256 = 12345;
    try evm.balances.put(test_addr, test_balance);

    // Push address on stack
    try frame.pushStack(Address.toU256(test_addr));

    // Execute BALANCE
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.balance(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(test_balance, frame.stack.items[0]);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "BALANCE: cold access cost (Berlin+)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BERLIN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x31}; // BALANCE
    var frame = try createTestFrame(allocator, evm, bytecode, .BERLIN, 1_000_000);
    defer frame.deinit();

    const test_addr = try Address.fromHex("0x1234567890123456789012345678901234567890");
    try frame.pushStack(Address.toU256(test_addr));

    const initial_gas = frame.gas_remaining;

    // Execute BALANCE (first access = cold)
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.balance(&frame);

    // Verify cold access cost (2600)
    try testing.expectEqual(@as(i64, GasConstants.ColdAccountAccessCost), initial_gas - frame.gas_remaining);
}

test "BALANCE: warm access cost (Berlin+)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BERLIN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x31}; // BALANCE
    var frame = try createTestFrame(allocator, evm, bytecode, .BERLIN, 1_000_000);
    defer frame.deinit();

    const test_addr = try Address.fromHex("0x1234567890123456789012345678901234567890");

    // First access to warm it up
    _ = try evm.accessAddress(test_addr);

    try frame.pushStack(Address.toU256(test_addr));
    const initial_gas = frame.gas_remaining;

    // Execute BALANCE (second access = warm)
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.balance(&frame);

    // Verify warm access cost (100)
    try testing.expectEqual(@as(i64, GasConstants.WarmStorageReadCost), initial_gas - frame.gas_remaining);
}

test "BALANCE: gas cost Istanbul" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .ISTANBUL);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x31}; // BALANCE
    var frame = try createTestFrame(allocator, evm, bytecode, .ISTANBUL, 1_000_000);
    defer frame.deinit();

    const test_addr = try Address.fromHex("0x1234567890123456789012345678901234567890");
    try frame.pushStack(Address.toU256(test_addr));

    const initial_gas = frame.gas_remaining;

    // Execute BALANCE
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.balance(&frame);

    // Verify Istanbul gas cost (700)
    try testing.expectEqual(@as(i64, 700), initial_gas - frame.gas_remaining);
}

test "BALANCE: gas cost Tangerine Whistle" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .TANGERINE_WHISTLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x31}; // BALANCE
    var frame = try createTestFrame(allocator, evm, bytecode, .TANGERINE_WHISTLE, 1_000_000);
    defer frame.deinit();

    const test_addr = try Address.fromHex("0x1234567890123456789012345678901234567890");
    try frame.pushStack(Address.toU256(test_addr));

    const initial_gas = frame.gas_remaining;

    // Execute BALANCE
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.balance(&frame);

    // Verify Tangerine Whistle gas cost (400)
    try testing.expectEqual(@as(i64, 400), initial_gas - frame.gas_remaining);
}

test "BALANCE: gas cost pre-Tangerine" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .HOMESTEAD);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x31}; // BALANCE
    var frame = try createTestFrame(allocator, evm, bytecode, .HOMESTEAD, 1_000_000);
    defer frame.deinit();

    const test_addr = try Address.fromHex("0x1234567890123456789012345678901234567890");
    try frame.pushStack(Address.toU256(test_addr));

    const initial_gas = frame.gas_remaining;

    // Execute BALANCE
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.balance(&frame);

    // Verify pre-Tangerine gas cost (20)
    try testing.expectEqual(@as(i64, 20), initial_gas - frame.gas_remaining);
}

test "BALANCE: zero balance for unknown address" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x31}; // BALANCE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const test_addr = try Address.fromHex("0x9999999999999999999999999999999999999999");
    try frame.pushStack(Address.toU256(test_addr));

    // Execute BALANCE
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.balance(&frame);

    // Verify result is 0 for unknown address
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "BALANCE: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x31}; // BALANCE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Execute BALANCE with empty stack
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    const result = ContextHandlers.balance(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// ORIGIN Tests
// ============================================================================

test "ORIGIN: returns transaction origin" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x32}; // ORIGIN
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    // Execute ORIGIN
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.origin(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    const expected = Address.toU256(evm.origin);
    try testing.expectEqual(expected, frame.stack.items[0]);

    // Verify gas consumed (GasQuickStep = 2)
    try testing.expectEqual(@as(i64, GasConstants.GasQuickStep), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

// ============================================================================
// CALLER Tests
// ============================================================================

test "CALLER: returns caller address" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x33}; // CALLER
    const caller = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");
    var frame = try createTestFrameWithParams(allocator, evm, bytecode, .CANCUN, 1_000_000, caller, address, 0, &.{});
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    // Execute CALLER
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.caller(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    const expected = Address.toU256(caller);
    try testing.expectEqual(expected, frame.stack.items[0]);

    // Verify gas consumed (GasQuickStep = 2)
    try testing.expectEqual(@as(i64, GasConstants.GasQuickStep), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

// ============================================================================
// CALLVALUE Tests
// ============================================================================

test "CALLVALUE: returns call value" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x34}; // CALLVALUE
    const caller = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");
    const value: u256 = 99999;
    var frame = try createTestFrameWithParams(allocator, evm, bytecode, .CANCUN, 1_000_000, caller, address, value, &.{});
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    // Execute CALLVALUE
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.callvalue(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(value, frame.stack.items[0]);

    // Verify gas consumed (GasQuickStep = 2)
    try testing.expectEqual(@as(i64, GasConstants.GasQuickStep), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "CALLVALUE: zero value" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x34}; // CALLVALUE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Execute CALLVALUE
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.callvalue(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

// ============================================================================
// CALLDATALOAD Tests
// ============================================================================

test "CALLDATALOAD: load 32 bytes from calldata" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x35}; // CALLDATALOAD
    const calldata = &[_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00 };
    const caller = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");
    var frame = try createTestFrameWithParams(allocator, evm, bytecode, .CANCUN, 1_000_000, caller, address, 0, calldata);
    defer frame.deinit();

    try frame.pushStack(0); // offset

    const initial_gas = frame.gas_remaining;

    // Execute CALLDATALOAD
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.calldataload(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);

    // Compute expected value (32 bytes as big-endian u256)
    var expected: u256 = 0;
    for (calldata[0..32]) |byte| {
        expected = (expected << 8) | byte;
    }
    try testing.expectEqual(expected, frame.stack.items[0]);

    // Verify gas consumed (GasFastestStep = 3)
    try testing.expectEqual(@as(i64, GasConstants.GasFastestStep), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "CALLDATALOAD: zero padding when offset beyond calldata" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x35}; // CALLDATALOAD
    const calldata = &[_]u8{ 0x11, 0x22 };
    const caller = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");
    var frame = try createTestFrameWithParams(allocator, evm, bytecode, .CANCUN, 1_000_000, caller, address, 0, calldata);
    defer frame.deinit();

    try frame.pushStack(0); // offset

    // Execute CALLDATALOAD
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.calldataload(&frame);

    // Verify result: 0x1122 followed by 30 zero bytes
    const expected: u256 = (@as(u256, 0x11) << 248) | (@as(u256, 0x22) << 240);
    try testing.expectEqual(expected, frame.stack.items[0]);
}

test "CALLDATALOAD: offset beyond u32 returns zero" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x35}; // CALLDATALOAD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    try frame.pushStack(std.math.maxInt(u256)); // offset > u32

    // Execute CALLDATALOAD
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.calldataload(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "CALLDATALOAD: partial read with zero padding" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x35}; // CALLDATALOAD
    const calldata = &[_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55 };
    const caller = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");
    var frame = try createTestFrameWithParams(allocator, evm, bytecode, .CANCUN, 1_000_000, caller, address, 0, calldata);
    defer frame.deinit();

    try frame.pushStack(2); // offset = 2

    // Execute CALLDATALOAD
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.calldataload(&frame);

    // Verify result: bytes 2,3,4 followed by 29 zero bytes
    const expected: u256 = (@as(u256, 0x33) << 248) | (@as(u256, 0x44) << 240) | (@as(u256, 0x55) << 232);
    try testing.expectEqual(expected, frame.stack.items[0]);
}

test "CALLDATALOAD: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x35}; // CALLDATALOAD
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Execute CALLDATALOAD with empty stack
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    const result = ContextHandlers.calldataload(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// CALLDATASIZE Tests
// ============================================================================

test "CALLDATASIZE: returns calldata size" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x36}; // CALLDATASIZE
    const calldata = &[_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55 };
    const caller = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");
    var frame = try createTestFrameWithParams(allocator, evm, bytecode, .CANCUN, 1_000_000, caller, address, 0, calldata);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    // Execute CALLDATASIZE
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.calldatasize(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 5), frame.stack.items[0]);

    // Verify gas consumed (GasQuickStep = 2)
    try testing.expectEqual(@as(i64, GasConstants.GasQuickStep), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "CALLDATASIZE: zero for empty calldata" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x36}; // CALLDATASIZE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Execute CALLDATASIZE
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.calldatasize(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

// ============================================================================
// CALLDATACOPY Tests
// ============================================================================

test "CALLDATACOPY: copy calldata to memory" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x37}; // CALLDATACOPY
    const calldata = &[_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55 };
    const caller = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");
    var frame = try createTestFrameWithParams(allocator, evm, bytecode, .CANCUN, 1_000_000, caller, address, 0, calldata);
    defer frame.deinit();

    try frame.pushStack(3); // length
    try frame.pushStack(1); // offset in calldata
    try frame.pushStack(0); // dest offset in memory

    // Execute CALLDATACOPY
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.calldatacopy(&frame);

    // Verify memory contains bytes 1,2,3 from calldata
    try testing.expectEqual(@as(u8, 0x22), frame.readMemory(0));
    try testing.expectEqual(@as(u8, 0x33), frame.readMemory(1));
    try testing.expectEqual(@as(u8, 0x44), frame.readMemory(2));

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "CALLDATACOPY: zero padding when reading beyond calldata" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x37}; // CALLDATACOPY
    const calldata = &[_]u8{ 0x11, 0x22 };
    const caller = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");
    var frame = try createTestFrameWithParams(allocator, evm, bytecode, .CANCUN, 1_000_000, caller, address, 0, calldata);
    defer frame.deinit();

    try frame.pushStack(5); // length (beyond calldata)
    try frame.pushStack(0); // offset in calldata
    try frame.pushStack(0); // dest offset in memory

    // Execute CALLDATACOPY
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.calldatacopy(&frame);

    // Verify memory contains calldata followed by zeros
    try testing.expectEqual(@as(u8, 0x11), frame.readMemory(0));
    try testing.expectEqual(@as(u8, 0x22), frame.readMemory(1));
    try testing.expectEqual(@as(u8, 0x00), frame.readMemory(2));
    try testing.expectEqual(@as(u8, 0x00), frame.readMemory(3));
    try testing.expectEqual(@as(u8, 0x00), frame.readMemory(4));
}

test "CALLDATACOPY: gas cost includes memory expansion and copy" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x37}; // CALLDATACOPY
    const calldata = &[_]u8{ 0x11, 0x22, 0x33 };
    const caller = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const address = try Address.fromHex("0x2222222222222222222222222222222222222222");
    var frame = try createTestFrameWithParams(allocator, evm, bytecode, .CANCUN, 1_000_000, caller, address, 0, calldata);
    defer frame.deinit();

    try frame.pushStack(3); // length
    try frame.pushStack(0); // offset in calldata
    try frame.pushStack(0); // dest offset in memory

    const initial_gas = frame.gas_remaining;

    // Execute CALLDATACOPY
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.calldatacopy(&frame);

    // Verify gas consumed: GasFastestStep (3) + memory expansion + copy cost
    // Copy cost = 3 words * 3 = 9
    // Memory expansion for 3 bytes = 3 (for first 32 bytes)
    const gas_used = initial_gas - frame.gas_remaining;
    try testing.expect(gas_used >= GasConstants.GasFastestStep);
}

test "CALLDATACOPY: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x37}; // CALLDATACOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 2 values (need 3)
    try frame.pushStack(0);
    try frame.pushStack(0);

    // Execute CALLDATACOPY with insufficient stack
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    const result = ContextHandlers.calldatacopy(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// CODESIZE Tests
// ============================================================================

test "CODESIZE: returns bytecode size" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{ 0x38, 0x60, 0x00, 0x60, 0x00 }; // CODESIZE + some extra bytes
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    // Execute CODESIZE
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.codesize(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 5), frame.stack.items[0]);

    // Verify gas consumed (GasQuickStep = 2)
    try testing.expectEqual(@as(i64, GasConstants.GasQuickStep), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

// ============================================================================
// CODECOPY Tests
// ============================================================================

test "CODECOPY: copy bytecode to memory" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{ 0x39, 0x11, 0x22, 0x33, 0x44, 0x55 }; // CODECOPY + data
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    try frame.pushStack(3); // length
    try frame.pushStack(1); // offset in code
    try frame.pushStack(0); // dest offset in memory

    // Execute CODECOPY
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.codecopy(&frame);

    // Verify memory contains bytes 1,2,3 from bytecode
    try testing.expectEqual(@as(u8, 0x11), frame.readMemory(0));
    try testing.expectEqual(@as(u8, 0x22), frame.readMemory(1));
    try testing.expectEqual(@as(u8, 0x33), frame.readMemory(2));

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "CODECOPY: zero padding when reading beyond code" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{ 0x39, 0x11, 0x22 }; // CODECOPY + 2 bytes
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    try frame.pushStack(5); // length (beyond code)
    try frame.pushStack(0); // offset in code
    try frame.pushStack(0); // dest offset in memory

    // Execute CODECOPY
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.codecopy(&frame);

    // Verify memory contains code followed by zeros
    try testing.expectEqual(@as(u8, 0x39), frame.readMemory(0));
    try testing.expectEqual(@as(u8, 0x11), frame.readMemory(1));
    try testing.expectEqual(@as(u8, 0x22), frame.readMemory(2));
    try testing.expectEqual(@as(u8, 0x00), frame.readMemory(3));
    try testing.expectEqual(@as(u8, 0x00), frame.readMemory(4));
}

// ============================================================================
// GASPRICE Tests
// ============================================================================

test "GASPRICE: returns gas price" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    // Set a custom gas price
    evm.gas_price = 12345;

    const bytecode = &[_]u8{0x3a}; // GASPRICE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    // Execute GASPRICE
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.gasprice(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 12345), frame.stack.items[0]);

    // Verify gas consumed (GasQuickStep = 2)
    try testing.expectEqual(@as(i64, GasConstants.GasQuickStep), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

// ============================================================================
// EXTCODESIZE Tests
// ============================================================================

test "EXTCODESIZE: returns external code size" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3b}; // EXTCODESIZE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Set code for an external address
    const ext_addr = try Address.fromHex("0x1234567890123456789012345678901234567890");
    const ext_code = &[_]u8{ 0x60, 0x00, 0x60, 0x00 };
    try evm.code.put(ext_addr, ext_code);

    try frame.pushStack(Address.toU256(ext_addr));

    // Execute EXTCODESIZE
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.extcodesize(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 4), frame.stack.items[0]);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "EXTCODESIZE: zero for empty account" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3b}; // EXTCODESIZE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const ext_addr = try Address.fromHex("0x9999999999999999999999999999999999999999");
    try frame.pushStack(Address.toU256(ext_addr));

    // Execute EXTCODESIZE
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.extcodesize(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "EXTCODESIZE: cold access cost (Berlin+)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BERLIN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3b}; // EXTCODESIZE
    var frame = try createTestFrame(allocator, evm, bytecode, .BERLIN, 1_000_000);
    defer frame.deinit();

    const ext_addr = try Address.fromHex("0x1234567890123456789012345678901234567890");
    try frame.pushStack(Address.toU256(ext_addr));

    const initial_gas = frame.gas_remaining;

    // Execute EXTCODESIZE (first access = cold)
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.extcodesize(&frame);

    // Verify cold access cost (2600)
    try testing.expectEqual(@as(i64, GasConstants.ColdAccountAccessCost), initial_gas - frame.gas_remaining);
}

test "EXTCODESIZE: warm access cost (Berlin+)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BERLIN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3b}; // EXTCODESIZE
    var frame = try createTestFrame(allocator, evm, bytecode, .BERLIN, 1_000_000);
    defer frame.deinit();

    const ext_addr = try Address.fromHex("0x1234567890123456789012345678901234567890");

    // First access to warm it up
    _ = try evm.accessAddress(ext_addr);

    try frame.pushStack(Address.toU256(ext_addr));
    const initial_gas = frame.gas_remaining;

    // Execute EXTCODESIZE (second access = warm)
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.extcodesize(&frame);

    // Verify warm access cost (100)
    try testing.expectEqual(@as(i64, GasConstants.WarmStorageReadCost), initial_gas - frame.gas_remaining);
}

test "EXTCODESIZE: gas cost Tangerine Whistle" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .TANGERINE_WHISTLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3b}; // EXTCODESIZE
    var frame = try createTestFrame(allocator, evm, bytecode, .TANGERINE_WHISTLE, 1_000_000);
    defer frame.deinit();

    const ext_addr = try Address.fromHex("0x1234567890123456789012345678901234567890");
    try frame.pushStack(Address.toU256(ext_addr));

    const initial_gas = frame.gas_remaining;

    // Execute EXTCODESIZE
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.extcodesize(&frame);

    // Verify Tangerine Whistle gas cost (700)
    try testing.expectEqual(@as(i64, 700), initial_gas - frame.gas_remaining);
}

// ============================================================================
// EXTCODECOPY Tests
// ============================================================================

test "EXTCODECOPY: copy external code to memory" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3c}; // EXTCODECOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Set code for an external address
    const ext_addr = try Address.fromHex("0x1234567890123456789012345678901234567890");
    const ext_code = &[_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55 };
    try evm.code.put(ext_addr, ext_code);

    try frame.pushStack(3); // size
    try frame.pushStack(1); // offset in code
    try frame.pushStack(0); // dest offset in memory
    try frame.pushStack(Address.toU256(ext_addr)); // address

    // Execute EXTCODECOPY
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.extcodecopy(&frame);

    // Verify memory contains bytes 1,2,3 from external code
    try testing.expectEqual(@as(u8, 0x22), frame.readMemory(0));
    try testing.expectEqual(@as(u8, 0x33), frame.readMemory(1));
    try testing.expectEqual(@as(u8, 0x44), frame.readMemory(2));

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "EXTCODECOPY: zero padding when reading beyond code" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3c}; // EXTCODECOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Set code for an external address
    const ext_addr = try Address.fromHex("0x1234567890123456789012345678901234567890");
    const ext_code = &[_]u8{ 0x11, 0x22 };
    try evm.code.put(ext_addr, ext_code);

    try frame.pushStack(5); // size (beyond code)
    try frame.pushStack(0); // offset in code
    try frame.pushStack(0); // dest offset in memory
    try frame.pushStack(Address.toU256(ext_addr)); // address

    // Execute EXTCODECOPY
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.extcodecopy(&frame);

    // Verify memory contains code followed by zeros
    try testing.expectEqual(@as(u8, 0x11), frame.readMemory(0));
    try testing.expectEqual(@as(u8, 0x22), frame.readMemory(1));
    try testing.expectEqual(@as(u8, 0x00), frame.readMemory(2));
    try testing.expectEqual(@as(u8, 0x00), frame.readMemory(3));
    try testing.expectEqual(@as(u8, 0x00), frame.readMemory(4));
}

test "EXTCODECOPY: cold access cost (Berlin+)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BERLIN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3c}; // EXTCODECOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .BERLIN, 1_000_000);
    defer frame.deinit();

    const ext_addr = try Address.fromHex("0x1234567890123456789012345678901234567890");

    try frame.pushStack(0); // size
    try frame.pushStack(0); // offset in code
    try frame.pushStack(0); // dest offset in memory
    try frame.pushStack(Address.toU256(ext_addr)); // address

    const initial_gas = frame.gas_remaining;

    // Execute EXTCODECOPY (first access = cold)
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.extcodecopy(&frame);

    // Verify cold access cost is included (2600)
    const gas_used = initial_gas - frame.gas_remaining;
    try testing.expect(gas_used >= GasConstants.ColdAccountAccessCost);
}

// ============================================================================
// RETURNDATASIZE Tests
// ============================================================================

test "RETURNDATASIZE: returns return data size" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BYZANTIUM);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3d}; // RETURNDATASIZE
    var frame = try createTestFrame(allocator, evm, bytecode, .BYZANTIUM, 1_000_000);
    defer frame.deinit();

    // Set return data
    const return_data = &[_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55 };
    frame.return_data = return_data;

    const initial_gas = frame.gas_remaining;

    // Execute RETURNDATASIZE
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.returndatasize(&frame);

    // Verify result
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expectEqual(@as(u256, 5), frame.stack.items[0]);

    // Verify gas consumed (GasQuickStep = 2)
    try testing.expectEqual(@as(i64, GasConstants.GasQuickStep), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "RETURNDATASIZE: zero for no return data" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BYZANTIUM);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3d}; // RETURNDATASIZE
    var frame = try createTestFrame(allocator, evm, bytecode, .BYZANTIUM, 1_000_000);
    defer frame.deinit();

    // Execute RETURNDATASIZE
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.returndatasize(&frame);

    // Verify result is 0
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "RETURNDATASIZE: invalid before Byzantium" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .SPURIOUS_DRAGON);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3d}; // RETURNDATASIZE
    var frame = try createTestFrame(allocator, evm, bytecode, .SPURIOUS_DRAGON, 1_000_000);
    defer frame.deinit();

    // Execute RETURNDATASIZE
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    const result = ContextHandlers.returndatasize(&frame);

    // Verify error
    try testing.expectError(error.InvalidOpcode, result);
}

// ============================================================================
// RETURNDATACOPY Tests
// ============================================================================

test "RETURNDATACOPY: copy return data to memory" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BYZANTIUM);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3e}; // RETURNDATACOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .BYZANTIUM, 1_000_000);
    defer frame.deinit();

    // Set return data
    const return_data = &[_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55 };
    frame.return_data = return_data;

    try frame.pushStack(3); // length
    try frame.pushStack(1); // offset in return data
    try frame.pushStack(0); // dest offset in memory

    // Execute RETURNDATACOPY
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.returndatacopy(&frame);

    // Verify memory contains bytes 1,2,3 from return data
    try testing.expectEqual(@as(u8, 0x22), frame.readMemory(0));
    try testing.expectEqual(@as(u8, 0x33), frame.readMemory(1));
    try testing.expectEqual(@as(u8, 0x44), frame.readMemory(2));

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "RETURNDATACOPY: out of bounds error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BYZANTIUM);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3e}; // RETURNDATACOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .BYZANTIUM, 1_000_000);
    defer frame.deinit();

    // Set return data
    const return_data = &[_]u8{ 0x11, 0x22, 0x33 };
    frame.return_data = return_data;

    try frame.pushStack(5); // length (beyond return data)
    try frame.pushStack(0); // offset in return data
    try frame.pushStack(0); // dest offset in memory

    // Execute RETURNDATACOPY
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    const result = ContextHandlers.returndatacopy(&frame);

    // Verify error
    try testing.expectError(error.OutOfBounds, result);
}

test "RETURNDATACOPY: offset out of bounds error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BYZANTIUM);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3e}; // RETURNDATACOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .BYZANTIUM, 1_000_000);
    defer frame.deinit();

    // Set return data
    const return_data = &[_]u8{ 0x11, 0x22, 0x33 };
    frame.return_data = return_data;

    try frame.pushStack(1); // length
    try frame.pushStack(5); // offset (beyond return data)
    try frame.pushStack(0); // dest offset in memory

    // Execute RETURNDATACOPY
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    const result = ContextHandlers.returndatacopy(&frame);

    // Verify error
    try testing.expectError(error.OutOfBounds, result);
}

test "RETURNDATACOPY: invalid before Byzantium" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .SPURIOUS_DRAGON);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3e}; // RETURNDATACOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .SPURIOUS_DRAGON, 1_000_000);
    defer frame.deinit();

    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(0);

    // Execute RETURNDATACOPY
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    const result = ContextHandlers.returndatacopy(&frame);

    // Verify error
    try testing.expectError(error.InvalidOpcode, result);
}

test "RETURNDATACOPY: gas cost includes memory expansion and copy" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BYZANTIUM);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3e}; // RETURNDATACOPY
    var frame = try createTestFrame(allocator, evm, bytecode, .BYZANTIUM, 1_000_000);
    defer frame.deinit();

    // Set return data
    const return_data = &[_]u8{ 0x11, 0x22, 0x33 };
    frame.return_data = return_data;

    try frame.pushStack(3); // length
    try frame.pushStack(0); // offset in return data
    try frame.pushStack(0); // dest offset in memory

    const initial_gas = frame.gas_remaining;

    // Execute RETURNDATACOPY
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.returndatacopy(&frame);

    // Verify gas consumed: GasFastestStep (3) + memory expansion + copy cost
    const gas_used = initial_gas - frame.gas_remaining;
    try testing.expect(gas_used >= GasConstants.GasFastestStep);
}

// ============================================================================
// EXTCODEHASH Tests
// ============================================================================

test "EXTCODEHASH: returns code hash for non-empty account" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3f}; // EXTCODEHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    // Set code for an external address
    const ext_addr = try Address.fromHex("0x1234567890123456789012345678901234567890");
    const ext_code = &[_]u8{ 0x60, 0x00, 0x60, 0x00 };
    try evm.code.put(ext_addr, ext_code);

    try frame.pushStack(Address.toU256(ext_addr));

    // Execute EXTCODEHASH
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.extcodehash(&frame);

    // Verify result is not zero (hash computed)
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    try testing.expect(frame.stack.items[0] != 0);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "EXTCODEHASH: returns zero for empty account" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3f}; // EXTCODEHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    const ext_addr = try Address.fromHex("0x9999999999999999999999999999999999999999");
    try frame.pushStack(Address.toU256(ext_addr));

    // Execute EXTCODEHASH
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.extcodehash(&frame);

    // Verify result is 0 for empty account
    try testing.expectEqual(@as(u256, 0), frame.stack.items[0]);
}

test "EXTCODEHASH: invalid before Constantinople" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BYZANTIUM);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3f}; // EXTCODEHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .BYZANTIUM, 1_000_000);
    defer frame.deinit();

    const ext_addr = try Address.fromHex("0x1234567890123456789012345678901234567890");
    try frame.pushStack(Address.toU256(ext_addr));

    // Execute EXTCODEHASH
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    const result = ContextHandlers.extcodehash(&frame);

    // Verify error
    try testing.expectError(error.InvalidOpcode, result);
}

test "EXTCODEHASH: cold access cost (Berlin+)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BERLIN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3f}; // EXTCODEHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .BERLIN, 1_000_000);
    defer frame.deinit();

    const ext_addr = try Address.fromHex("0x1234567890123456789012345678901234567890");
    try frame.pushStack(Address.toU256(ext_addr));

    const initial_gas = frame.gas_remaining;

    // Execute EXTCODEHASH (first access = cold)
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.extcodehash(&frame);

    // Verify cold access cost (2600)
    try testing.expectEqual(@as(i64, GasConstants.ColdAccountAccessCost), initial_gas - frame.gas_remaining);
}

test "EXTCODEHASH: warm access cost (Berlin+)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BERLIN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3f}; // EXTCODEHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .BERLIN, 1_000_000);
    defer frame.deinit();

    const ext_addr = try Address.fromHex("0x1234567890123456789012345678901234567890");

    // First access to warm it up
    _ = try evm.accessAddress(ext_addr);

    try frame.pushStack(Address.toU256(ext_addr));
    const initial_gas = frame.gas_remaining;

    // Execute EXTCODEHASH (second access = warm)
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.extcodehash(&frame);

    // Verify warm access cost (100)
    try testing.expectEqual(@as(i64, GasConstants.WarmStorageReadCost), initial_gas - frame.gas_remaining);
}

test "EXTCODEHASH: gas cost Istanbul" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .ISTANBUL);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3f}; // EXTCODEHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .ISTANBUL, 1_000_000);
    defer frame.deinit();

    const ext_addr = try Address.fromHex("0x1234567890123456789012345678901234567890");
    try frame.pushStack(Address.toU256(ext_addr));

    const initial_gas = frame.gas_remaining;

    // Execute EXTCODEHASH
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.extcodehash(&frame);

    // Verify Istanbul gas cost (700)
    try testing.expectEqual(@as(i64, 700), initial_gas - frame.gas_remaining);
}

test "EXTCODEHASH: gas cost Constantinople" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CONSTANTINOPLE);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x3f}; // EXTCODEHASH
    var frame = try createTestFrame(allocator, evm, bytecode, .CONSTANTINOPLE, 1_000_000);
    defer frame.deinit();

    const ext_addr = try Address.fromHex("0x1234567890123456789012345678901234567890");
    try frame.pushStack(Address.toU256(ext_addr));

    const initial_gas = frame.gas_remaining;

    // Execute EXTCODEHASH
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.extcodehash(&frame);

    // Verify Constantinople gas cost (400)
    try testing.expectEqual(@as(i64, 400), initial_gas - frame.gas_remaining);
}

// ============================================================================
// GAS Tests
// ============================================================================

test "GAS: returns remaining gas" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5a}; // GAS
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;

    // Execute GAS
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.gas(&frame);

    // Verify result is remaining gas AFTER consuming GasQuickStep
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    const expected_remaining = @as(u256, @intCast(initial_gas - GasConstants.GasQuickStep));
    try testing.expectEqual(expected_remaining, frame.stack.items[0]);

    // Verify gas consumed (GasQuickStep = 2)
    try testing.expectEqual(@as(i64, GasConstants.GasQuickStep), initial_gas - frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "GAS: reflects gas consumption" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0x5a}; // GAS
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 100);
    defer frame.deinit();

    // Execute GAS
    const ContextHandlers = @import("handlers_context.zig").Handlers(@TypeOf(frame));
    try ContextHandlers.gas(&frame);

    // Verify result
    const expected: u256 = 100 - GasConstants.GasQuickStep;
    try testing.expectEqual(expected, frame.stack.items[0]);
}
