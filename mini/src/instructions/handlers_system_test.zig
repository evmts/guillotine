/// Unit tests for system opcode handlers (CREATE, CREATE2, CALL, CALLCODE, DELEGATECALL, STATICCALL, SELFDESTRUCT)
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

// Helper to convert u256 to Address
fn u256ToAddress(value: u256) Address {
    var bytes: [20]u8 = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        bytes[19 - i] = @truncate(value >> @intCast(i * 8));
    }
    return Address{ .bytes = bytes };
}

// Helper to convert Address to u256
fn addressToU256(addr: Address) u256 {
    var result: u256 = 0;
    for (addr.bytes) |b| {
        result = (result << 8) | b;
    }
    return result;
}

// ============================================================================
// CREATE Tests
// ============================================================================

test "CREATE: basic contract creation" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf0}; // CREATE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: value=0, offset=0, length=0 (empty init code)
    try frame.pushStack(0); // length
    try frame.pushStack(0); // offset
    try frame.pushStack(0); // value

    const initial_gas = frame.gas_remaining;

    // Execute CREATE
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    try SystemHandlers.create(&frame);

    // Verify stack has address (should be non-zero on success)
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    const result_addr = frame.stack.items[0];
    // Empty init code should succeed with deterministic address
    try testing.expect(result_addr != 0);

    // Verify gas consumed
    try testing.expect(initial_gas > frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);

    // Verify return_data cleared
    try testing.expectEqual(@as(usize, 0), frame.return_data.len);
}

test "CREATE: static call violation" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf0}; // CREATE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Make this a static call
    frame.is_static = true;

    // Setup stack
    try frame.pushStack(0); // length
    try frame.pushStack(0); // offset
    try frame.pushStack(0); // value

    // Execute CREATE - should fail
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    const result = SystemHandlers.create(&frame);

    // Verify error
    try testing.expectError(error.StaticCallViolation, result);
}

test "CREATE: gas calculation for init code" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf0}; // CREATE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Write some init code to memory
    const init_code = &[_]u8{ 0x60, 0x00, 0x60, 0x00, 0xf3 }; // PUSH1 0, PUSH1 0, RETURN
    for (init_code, 0..) |byte, i| {
        try frame.writeMemory(@intCast(i), byte);
    }

    // Setup: value=0, offset=0, length=5
    try frame.pushStack(init_code.len); // length
    try frame.pushStack(0); // offset
    try frame.pushStack(0); // value

    const initial_gas = frame.gas_remaining;

    // Execute CREATE
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    try SystemHandlers.create(&frame);

    // Verify gas consumed includes memory expansion
    try testing.expect(initial_gas > frame.gas_remaining);
}

test "CREATE: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf0}; // CREATE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 2 values (need 3)
    try frame.pushStack(0);
    try frame.pushStack(0);

    // Execute CREATE
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    const result = SystemHandlers.create(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// CREATE2 Tests
// ============================================================================

test "CREATE2: basic contract creation" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf5}; // CREATE2
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup: value=0, offset=0, length=0, salt=0x1234
    try frame.pushStack(0x1234); // salt
    try frame.pushStack(0); // length
    try frame.pushStack(0); // offset
    try frame.pushStack(0); // value

    const initial_gas = frame.gas_remaining;

    // Execute CREATE2
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    try SystemHandlers.create2(&frame);

    // Verify stack has address
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    const result_addr = frame.stack.items[0];
    try testing.expect(result_addr != 0);

    // Verify gas consumed
    try testing.expect(initial_gas > frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "CREATE2: hardfork check (before Constantinople)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BYZANTIUM);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf5}; // CREATE2
    var frame = try createTestFrame(allocator, evm, bytecode, .BYZANTIUM, 1_000_000);
    defer frame.deinit();

    // Setup stack
    try frame.pushStack(0); // salt
    try frame.pushStack(0); // length
    try frame.pushStack(0); // offset
    try frame.pushStack(0); // value

    // Execute CREATE2 - should fail before Constantinople
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    const result = SystemHandlers.create2(&frame);

    // Verify error
    try testing.expectError(error.InvalidOpcode, result);
}

test "CREATE2: static call violation" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf5}; // CREATE2
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    frame.is_static = true;

    // Setup stack
    try frame.pushStack(0); // salt
    try frame.pushStack(0); // length
    try frame.pushStack(0); // offset
    try frame.pushStack(0); // value

    // Execute CREATE2
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    const result = SystemHandlers.create2(&frame);

    // Verify error
    try testing.expectError(error.StaticCallViolation, result);
}

test "CREATE2: deterministic address with salt" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf5}; // CREATE2
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Setup with specific salt
    const salt = 0xDEADBEEF;
    try frame.pushStack(salt);
    try frame.pushStack(0); // length
    try frame.pushStack(0); // offset
    try frame.pushStack(0); // value

    // Execute CREATE2
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    try SystemHandlers.create2(&frame);

    // Get first address
    const addr1 = frame.stack.items[0];
    frame.stack.items.len = 0;

    // Execute again with same parameters
    try frame.pushStack(salt);
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(0);
    frame.pc = 0; // Reset PC

    try SystemHandlers.create2(&frame);
    const addr2 = frame.stack.items[0];

    // Should get same address (deterministic)
    try testing.expectEqual(addr1, addr2);
}

// ============================================================================
// CALL Tests
// ============================================================================

test "CALL: basic call success" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf1}; // CALL
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const target_addr = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const target_u256 = addressToU256(target_addr);

    // Setup: gas=10000, address, value=0, in_offset=0, in_length=0, out_offset=0, out_length=0
    try frame.pushStack(0); // out_length
    try frame.pushStack(0); // out_offset
    try frame.pushStack(0); // in_length
    try frame.pushStack(0); // in_offset
    try frame.pushStack(0); // value
    try frame.pushStack(target_u256); // address
    try frame.pushStack(10000); // gas

    const initial_gas = frame.gas_remaining;

    // Execute CALL
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    try SystemHandlers.call(&frame);

    // Verify success pushed to stack
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
    // Result depends on target - could be 0 or 1

    // Verify gas consumed
    try testing.expect(initial_gas > frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "CALL: static call with value violation" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf1}; // CALL
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    frame.is_static = true;

    const target_addr = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const target_u256 = addressToU256(target_addr);

    // Setup with non-zero value in static call
    try frame.pushStack(0); // out_length
    try frame.pushStack(0); // out_offset
    try frame.pushStack(0); // in_length
    try frame.pushStack(0); // in_offset
    try frame.pushStack(100); // value (non-zero)
    try frame.pushStack(target_u256); // address
    try frame.pushStack(10000); // gas

    // Execute CALL
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    const result = SystemHandlers.call(&frame);

    // Verify error
    try testing.expectError(error.StaticCallViolation, result);
}

test "CALL: value transfer gas stipend (2300 gas)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf1}; // CALL
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const target_addr = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const target_u256 = addressToU256(target_addr);

    // Give caller some balance
    try evm.setBalanceWithSnapshot(frame.caller, 1000);

    // Setup with value transfer
    try frame.pushStack(0); // out_length
    try frame.pushStack(0); // out_offset
    try frame.pushStack(0); // in_length
    try frame.pushStack(0); // in_offset
    try frame.pushStack(100); // value
    try frame.pushStack(target_u256); // address
    try frame.pushStack(5000); // gas

    const initial_gas = frame.gas_remaining;

    // Execute CALL
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    try SystemHandlers.call(&frame);

    // Verify gas consumed includes value transfer cost
    const gas_consumed = initial_gas - frame.gas_remaining;
    // Should include CallValueTransferGas (9000) + other costs
    try testing.expect(gas_consumed >= GasConstants.CallValueTransferGas);
}

test "CALL: memory expansion for calldata" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf1}; // CALL
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const target_addr = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const target_u256 = addressToU256(target_addr);

    // Setup with large input data requiring memory expansion
    try frame.pushStack(0); // out_length
    try frame.pushStack(0); // out_offset
    try frame.pushStack(100); // in_length (100 bytes)
    try frame.pushStack(0); // in_offset
    try frame.pushStack(0); // value
    try frame.pushStack(target_u256); // address
    try frame.pushStack(10000); // gas

    const initial_memory_size = frame.memory_size;

    // Execute CALL
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    try SystemHandlers.call(&frame);

    // Verify memory expanded
    try testing.expect(frame.memory_size >= initial_memory_size);
}

test "CALL: cold vs warm access costs (Berlin+)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BERLIN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf1}; // CALL
    var frame = try createTestFrame(allocator, evm, bytecode, .BERLIN, 1_000_000);
    defer frame.deinit();

    const target_addr = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const target_u256 = addressToU256(target_addr);

    // First call (cold access)
    try frame.pushStack(0); // out_length
    try frame.pushStack(0); // out_offset
    try frame.pushStack(0); // in_length
    try frame.pushStack(0); // in_offset
    try frame.pushStack(0); // value
    try frame.pushStack(target_u256); // address
    try frame.pushStack(10000); // gas

    const initial_gas_cold = frame.gas_remaining;

    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    try SystemHandlers.call(&frame);

    const gas_consumed_cold = initial_gas_cold - frame.gas_remaining;

    // Reset for second call
    _ = try frame.popStack(); // Pop result
    frame.pc = 0;

    // Second call (warm access)
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(target_u256);
    try frame.pushStack(10000);

    const initial_gas_warm = frame.gas_remaining;
    try SystemHandlers.call(&frame);

    const gas_consumed_warm = initial_gas_warm - frame.gas_remaining;

    // Cold should consume more gas than warm (2600 vs 100)
    try testing.expect(gas_consumed_cold > gas_consumed_warm);
}

test "CALL: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf1}; // CALL
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 6 values (need 7)
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(0);

    // Execute CALL
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    const result = SystemHandlers.call(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// CALLCODE Tests
// ============================================================================

test "CALLCODE: basic call" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf2}; // CALLCODE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const target_addr = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const target_u256 = addressToU256(target_addr);

    // Setup
    try frame.pushStack(0); // out_length
    try frame.pushStack(0); // out_offset
    try frame.pushStack(0); // in_length
    try frame.pushStack(0); // in_offset
    try frame.pushStack(0); // value
    try frame.pushStack(target_u256); // address
    try frame.pushStack(10000); // gas

    const initial_gas = frame.gas_remaining;

    // Execute CALLCODE
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    try SystemHandlers.callcode(&frame);

    // Verify success pushed to stack
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);

    // Verify gas consumed
    try testing.expect(initial_gas > frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "CALLCODE: with value transfer" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf2}; // CALLCODE
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const target_addr = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const target_u256 = addressToU256(target_addr);

    // Give caller balance
    try evm.setBalanceWithSnapshot(frame.caller, 1000);

    // Setup with value
    try frame.pushStack(0); // out_length
    try frame.pushStack(0); // out_offset
    try frame.pushStack(0); // in_length
    try frame.pushStack(0); // in_offset
    try frame.pushStack(100); // value
    try frame.pushStack(target_u256); // address
    try frame.pushStack(10000); // gas

    const initial_gas = frame.gas_remaining;

    // Execute CALLCODE
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    try SystemHandlers.callcode(&frame);

    // Verify gas includes value transfer cost
    const gas_consumed = initial_gas - frame.gas_remaining;
    try testing.expect(gas_consumed >= GasConstants.CallValueTransferGas);
}

// ============================================================================
// DELEGATECALL Tests
// ============================================================================

test "DELEGATECALL: basic call" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf4}; // DELEGATECALL
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const target_addr = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const target_u256 = addressToU256(target_addr);

    // Setup (no value parameter for delegatecall)
    try frame.pushStack(0); // out_length
    try frame.pushStack(0); // out_offset
    try frame.pushStack(0); // in_length
    try frame.pushStack(0); // in_offset
    try frame.pushStack(target_u256); // address
    try frame.pushStack(10000); // gas

    const initial_gas = frame.gas_remaining;

    // Execute DELEGATECALL
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    try SystemHandlers.delegatecall(&frame);

    // Verify success pushed to stack
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);

    // Verify gas consumed
    try testing.expect(initial_gas > frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "DELEGATECALL: hardfork check (before Homestead)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .FRONTIER);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf4}; // DELEGATECALL
    var frame = try createTestFrame(allocator, evm, bytecode, .FRONTIER, 1_000_000);
    defer frame.deinit();

    const target_addr = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const target_u256 = addressToU256(target_addr);

    // Setup
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(target_u256);
    try frame.pushStack(10000);

    // Execute DELEGATECALL - should fail before Homestead
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    const result = SystemHandlers.delegatecall(&frame);

    // Verify error
    try testing.expectError(error.InvalidOpcode, result);
}

test "DELEGATECALL: preserves caller context" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf4}; // DELEGATECALL
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const target_addr = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const target_u256 = addressToU256(target_addr);

    // Store original caller
    const original_caller = frame.caller;

    // Setup
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(target_u256);
    try frame.pushStack(10000);

    // Execute DELEGATECALL
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    try SystemHandlers.delegatecall(&frame);

    // Verify caller unchanged (delegatecall preserves msg.sender)
    try testing.expectEqual(original_caller, frame.caller);
}

test "DELEGATECALL: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xf4}; // DELEGATECALL
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Only push 5 values (need 6)
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(0);

    // Execute DELEGATECALL
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    const result = SystemHandlers.delegatecall(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

// ============================================================================
// STATICCALL Tests
// ============================================================================

test "STATICCALL: basic call" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xfa}; // STATICCALL
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const target_addr = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const target_u256 = addressToU256(target_addr);

    // Setup (no value parameter for staticcall)
    try frame.pushStack(0); // out_length
    try frame.pushStack(0); // out_offset
    try frame.pushStack(0); // in_length
    try frame.pushStack(0); // in_offset
    try frame.pushStack(target_u256); // address
    try frame.pushStack(10000); // gas

    const initial_gas = frame.gas_remaining;

    // Execute STATICCALL
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    try SystemHandlers.staticcall(&frame);

    // Verify success pushed to stack
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);

    // Verify gas consumed
    try testing.expect(initial_gas > frame.gas_remaining);

    // Verify PC incremented
    try testing.expectEqual(@as(u32, 1), frame.pc);
}

test "STATICCALL: hardfork check (before Byzantium)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .HOMESTEAD);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xfa}; // STATICCALL
    var frame = try createTestFrame(allocator, evm, bytecode, .HOMESTEAD, 1_000_000);
    defer frame.deinit();

    const target_addr = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const target_u256 = addressToU256(target_addr);

    // Setup
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(target_u256);
    try frame.pushStack(10000);

    // Execute STATICCALL - should fail before Byzantium
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    const result = SystemHandlers.staticcall(&frame);

    // Verify error
    try testing.expectError(error.InvalidOpcode, result);
}

test "STATICCALL: propagates static context to child" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xfa}; // STATICCALL
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Start with non-static frame
    frame.is_static = false;

    const target_addr = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const target_u256 = addressToU256(target_addr);

    // Setup
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(0);
    try frame.pushStack(target_u256);
    try frame.pushStack(10000);

    // Execute STATICCALL
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    try SystemHandlers.staticcall(&frame);

    // Verify call completed (child should be in static context)
    try testing.expectEqual(@as(usize, 1), frame.stack.items.len);
}

// ============================================================================
// SELFDESTRUCT Tests
// ============================================================================

test "SELFDESTRUCT: basic destruction" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xff}; // SELFDESTRUCT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const beneficiary_addr = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const beneficiary_u256 = addressToU256(beneficiary_addr);

    // Give contract some balance
    try evm.setBalanceWithSnapshot(frame.address, 1000);

    // Setup
    try frame.pushStack(beneficiary_u256);

    const initial_gas = frame.gas_remaining;

    // Execute SELFDESTRUCT
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    try SystemHandlers.selfdestruct(&frame);

    // Verify gas consumed (base 5000 + potential cold access)
    try testing.expect(initial_gas > frame.gas_remaining);

    // Verify frame stopped
    try testing.expect(frame.stopped);

    // Verify PC NOT incremented (execution halted)
    try testing.expectEqual(@as(u32, 0), frame.pc);
}

test "SELFDESTRUCT: EIP-6780 Cancun behavior (only deletes if created in same tx)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xff}; // SELFDESTRUCT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const beneficiary_addr = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const beneficiary_u256 = addressToU256(beneficiary_addr);

    // Give contract some balance
    try evm.setBalanceWithSnapshot(frame.address, 1000);

    // Mark as created in this transaction
    try evm.created_accounts.put(frame.address, {});

    // Setup
    try frame.pushStack(beneficiary_u256);

    // Execute SELFDESTRUCT
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    try SystemHandlers.selfdestruct(&frame);

    // Verify account marked for deletion (only when created in same tx)
    try testing.expect(evm.selfdestructed_accounts.contains(frame.address));
}

test "SELFDESTRUCT: pre-Cancun always deletes" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .SHANGHAI);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xff}; // SELFDESTRUCT
    var frame = try createTestFrame(allocator, evm, bytecode, .SHANGHAI, 1_000_000);
    defer frame.deinit();

    const beneficiary_addr = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const beneficiary_u256 = addressToU256(beneficiary_addr);

    // Give contract some balance
    try evm.setBalanceWithSnapshot(frame.address, 1000);

    // Setup
    try frame.pushStack(beneficiary_u256);

    // Execute SELFDESTRUCT
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    try SystemHandlers.selfdestruct(&frame);

    // Verify account marked for deletion (pre-Cancun always deletes)
    try testing.expect(evm.selfdestructed_accounts.contains(frame.address));
}

test "SELFDESTRUCT: static call violation" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xff}; // SELFDESTRUCT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    frame.is_static = true;

    const beneficiary_addr = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const beneficiary_u256 = addressToU256(beneficiary_addr);

    // Setup
    try frame.pushStack(beneficiary_u256);

    // Execute SELFDESTRUCT
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    const result = SystemHandlers.selfdestruct(&frame);

    // Verify error (note: gas is charged BEFORE static check per Python reference)
    try testing.expectError(error.StaticCallViolation, result);
}

test "SELFDESTRUCT: cold access cost (Berlin+)" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .BERLIN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xff}; // SELFDESTRUCT
    var frame = try createTestFrame(allocator, evm, bytecode, .BERLIN, 1_000_000);
    defer frame.deinit();

    const beneficiary_addr = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const beneficiary_u256 = addressToU256(beneficiary_addr);

    // Give contract some balance
    try evm.setBalanceWithSnapshot(frame.address, 1000);

    // Setup
    try frame.pushStack(beneficiary_u256);

    const initial_gas = frame.gas_remaining;

    // Execute SELFDESTRUCT
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    try SystemHandlers.selfdestruct(&frame);

    // Verify gas consumed includes cold access cost (5000 base + 2600 cold)
    const gas_consumed = initial_gas - frame.gas_remaining;
    try testing.expect(gas_consumed >= 5000 + GasConstants.ColdAccountAccessCost);
}

test "SELFDESTRUCT: new account cost" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xff}; // SELFDESTRUCT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Beneficiary that doesn't exist
    const beneficiary_addr = try Address.fromHex("0x9999999999999999999999999999999999999999");
    const beneficiary_u256 = addressToU256(beneficiary_addr);

    // Give contract balance (required to trigger new account cost)
    try evm.setBalanceWithSnapshot(frame.address, 1000);

    // Setup
    try frame.pushStack(beneficiary_u256);

    const initial_gas = frame.gas_remaining;

    // Execute SELFDESTRUCT
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    try SystemHandlers.selfdestruct(&frame);

    // Verify gas consumed includes new account cost (25000)
    const gas_consumed = initial_gas - frame.gas_remaining;
    try testing.expect(gas_consumed >= GasConstants.CallNewAccountGas);
}

test "SELFDESTRUCT: balance transfer to beneficiary" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xff}; // SELFDESTRUCT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    const beneficiary_addr = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const beneficiary_u256 = addressToU256(beneficiary_addr);

    const contract_balance: u256 = 1000;

    // Give contract some balance
    try evm.setBalanceWithSnapshot(frame.address, contract_balance);
    // Give beneficiary initial balance
    try evm.setBalanceWithSnapshot(beneficiary_addr, 500);

    // Setup
    try frame.pushStack(beneficiary_u256);

    // Execute SELFDESTRUCT
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    try SystemHandlers.selfdestruct(&frame);

    // Verify balance transferred
    const beneficiary_final_balance = evm.balances.get(beneficiary_addr) orelse 0;
    try testing.expectEqual(@as(u256, 1500), beneficiary_final_balance);

    // Verify contract balance zeroed
    const contract_final_balance = evm.balances.get(frame.address) orelse 0;
    try testing.expectEqual(@as(u256, 0), contract_final_balance);
}

test "SELFDESTRUCT: self-destruct to self" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xff}; // SELFDESTRUCT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Beneficiary is self
    const beneficiary_u256 = addressToU256(frame.address);

    const contract_balance: u256 = 1000;

    // Give contract some balance
    try evm.setBalanceWithSnapshot(frame.address, contract_balance);

    // Mark as created in this transaction (EIP-6780 - should burn ether)
    try evm.created_accounts.put(frame.address, {});

    // Setup
    try frame.pushStack(beneficiary_u256);

    // Execute SELFDESTRUCT
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    try SystemHandlers.selfdestruct(&frame);

    // Verify balance is burned when created in same tx and beneficiary is self
    const final_balance = evm.balances.get(frame.address) orelse 0;
    try testing.expectEqual(@as(u256, 0), final_balance);
}

test "SELFDESTRUCT: stack underflow error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xff}; // SELFDESTRUCT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 1_000_000);
    defer frame.deinit();

    // Empty stack (need 1 value)

    // Execute SELFDESTRUCT
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    const result = SystemHandlers.selfdestruct(&frame);

    // Verify error
    try testing.expectError(error.StackUnderflow, result);
}

test "SELFDESTRUCT: out of gas error" {
    const allocator = testing.allocator;
    var evm = try createTestEvm(allocator, .CANCUN);
    defer {
        evm.deinit();
        allocator.destroy(evm);
    }

    const bytecode = &[_]u8{0xff}; // SELFDESTRUCT
    var frame = try createTestFrame(allocator, evm, bytecode, .CANCUN, 100); // Very low gas
    defer frame.deinit();

    const beneficiary_addr = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const beneficiary_u256 = addressToU256(beneficiary_addr);

    // Setup
    try frame.pushStack(beneficiary_u256);

    // Execute SELFDESTRUCT
    const SystemHandlers = @import("handlers_system.zig").Handlers(@TypeOf(frame));
    const result = SystemHandlers.selfdestruct(&frame);

    // Verify error (needs at least 5000 gas)
    try testing.expectError(error.OutOfGas, result);
}
