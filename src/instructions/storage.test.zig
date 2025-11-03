/// Tests for storage instruction implementations
/// Phase 4 - Test storage operations (STUBS - full tests require Phase 12 EVM integration)
const std = @import("std");
const testing = std.testing;
const Frame = @import("Frame.zig");
const storage = @import("storage.zig");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

// Test helper
fn makeFrame(allocator: std.mem.Allocator, hardfork: primitives.Hardfork) !Frame {
    return try Frame.initFull(
        allocator,
        &[_]u8{},
        1000000, // gas
        Address.zero(),
        Address.zero(),
        0,
        &[_]u8{},
        hardfork,
    );
}

// SLOAD opcode (0x54)
test "SLOAD: stub returns 0 for all storage slots" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator, .CANCUN);
    defer frame.deinit(allocator);

    // Load from arbitrary key
    const key: u256 = 0x1234567890abcdef;
    try frame.stack.push(key);
    try storage.SloadInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    // Stub implementation returns 0
    try testing.expectEqual(@as(u256, 0), result);
}

test "SLOAD: multiple loads" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator, .CANCUN);
    defer frame.deinit(allocator);

    // Load multiple keys
    try frame.stack.push(1);
    try storage.SloadInstruction(Frame).run(&frame);
    const val1 = try frame.stack.pop();

    try frame.stack.push(2);
    try storage.SloadInstruction(Frame).run(&frame);
    const val2 = try frame.stack.pop();

    // Stubs return 0
    try testing.expectEqual(@as(u256, 0), val1);
    try testing.expectEqual(@as(u256, 0), val2);
}

// SSTORE opcode (0x55)
test "SSTORE: stub accepts key/value pairs" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator, .CANCUN);
    defer frame.deinit(allocator);

    // Store value at key
    const key: u256 = 0x123;
    const value: u256 = 0x456;
    try frame.stack.push(value);
    try frame.stack.push(key);
    try storage.SstoreInstruction(Frame).run(&frame);

    // Stub does nothing, stack should be empty
    try testing.expectEqual(@as(usize, 0), frame.stack.len());
}

test "SSTORE: multiple stores" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator, .CANCUN);
    defer frame.deinit(allocator);

    // Store multiple values
    try frame.stack.push(100);
    try frame.stack.push(1);
    try storage.SstoreInstruction(Frame).run(&frame);

    try frame.stack.push(200);
    try frame.stack.push(2);
    try storage.SstoreInstruction(Frame).run(&frame);

    // Stack should be empty
    try testing.expectEqual(@as(usize, 0), frame.stack.len());
}

// TLOAD opcode (0x5c) - Cancun+
test "TLOAD: returns 0 for all transient slots (Cancun+)" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator, .CANCUN);
    defer frame.deinit(allocator);

    // Load from transient storage
    const key: u256 = 0x42;
    try frame.stack.push(key);
    try storage.TloadInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

test "TLOAD: fails before Cancun" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator, .LONDON);
    defer frame.deinit(allocator);

    try frame.stack.push(0x42);
    const result = storage.TloadInstruction(Frame).run(&frame);
    try testing.expectError(error.InvalidOpcode, result);
}

test "TLOAD: charges gas (100)" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator, .CANCUN);
    defer frame.deinit(allocator);

    const gas_before = frame.gas_remaining;

    try frame.stack.push(0);
    try storage.TloadInstruction(Frame).run(&frame);

    const gas_after = frame.gas_remaining;
    const gas_used = gas_before - gas_after;

    // TLOAD costs 100 gas (TLoadGas)
    try testing.expectEqual(@as(i64, 100), gas_used);
}

// TSTORE opcode (0x5d) - Cancun+
test "TSTORE: stub accepts key/value for transient storage (Cancun+)" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator, .CANCUN);
    defer frame.deinit(allocator);

    const key: u256 = 0x123;
    const value: u256 = 0x456;
    try frame.stack.push(value);
    try frame.stack.push(key);
    try storage.TstoreInstruction(Frame).run(&frame);

    // Stack should be empty
    try testing.expectEqual(@as(usize, 0), frame.stack.len());
}

test "TSTORE: fails before Cancun" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator, .LONDON);
    defer frame.deinit(allocator);

    try frame.stack.push(0x456);
    try frame.stack.push(0x123);
    const result = storage.TstoreInstruction(Frame).run(&frame);
    try testing.expectError(error.InvalidOpcode, result);
}

test "TSTORE: charges gas (100)" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator, .CANCUN);
    defer frame.deinit(allocator);

    const gas_before = frame.gas_remaining;

    try frame.stack.push(0x456);
    try frame.stack.push(0x123);
    try storage.TstoreInstruction(Frame).run(&frame);

    const gas_after = frame.gas_remaining;
    const gas_used = gas_before - gas_after;

    // TSTORE costs 100 gas (TStoreGas)
    try testing.expectEqual(@as(i64, 100), gas_used);
}

// Integration: Mixed storage operations
test "Storage: SLOAD/SSTORE sequence" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator, .CANCUN);
    defer frame.deinit(allocator);

    const key: u256 = 1;
    const value: u256 = 0x123456;

    // SSTORE
    try frame.stack.push(value);
    try frame.stack.push(key);
    try storage.SstoreInstruction(Frame).run(&frame);

    // SLOAD (stub returns 0, not stored value)
    try frame.stack.push(key);
    try storage.SloadInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    // Note: Stub doesn't persist, returns 0
    try testing.expectEqual(@as(u256, 0), result);
}

test "Storage: TLOAD/TSTORE sequence" {
    const allocator = testing.allocator;
    var frame = try makeFrame(allocator, .CANCUN);
    defer frame.deinit(allocator);

    const key: u256 = 1;
    const value: u256 = 0xabcdef;

    // TSTORE
    try frame.stack.push(value);
    try frame.stack.push(key);
    try storage.TstoreInstruction(Frame).run(&frame);

    // TLOAD (stub returns 0, not stored value)
    try frame.stack.push(key);
    try storage.TloadInstruction(Frame).run(&frame);

    const result = try frame.stack.pop();
    // Note: Stub doesn't persist, returns 0
    try testing.expectEqual(@as(u256, 0), result);
}

// NOTE: Full storage tests require Phase 12 EVM integration
// - SLOAD: warm/cold access costs, storage state
// - SSTORE: hardfork-aware gas costs, refund logic, static call check, sentry gas
// - TLOAD/TSTORE: transient storage state, cleared at tx end
