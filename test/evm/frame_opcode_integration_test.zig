//! Integration tests for basic Frame opcodes using real EVM instances
//! This file demonstrates the migration from MockHost to real EVM testing

const std = @import("std");
const Frame = @import("evm").Frame;
const TestHelpers = @import("frame_test_helpers.zig");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;

// Import needed types and helpers
const toAddress = TestHelpers.toAddress;
const addressToU256 = TestHelpers.addressToU256;

test "Frame op_add basic integration test" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    var test_evm = try TestHelpers.createTestEvm(allocator);
    defer test_evm.deinit();
    
    // Create frame with minimal bytecode (just ADD followed by STOP)
    const F = Frame(.{ .has_database = true });
    const bytecode = [_]u8{ 0x01, 0x00 }; // ADD STOP
    const host = test_evm.evm.to_host();
    
    var frame = try F.init(allocator, &bytecode, 100000, test_evm.evm.database, host);
    defer frame.deinit(allocator);
    
    // Setup stack for ADD operation
    try frame.stack.push(10);
    try frame.stack.push(20);
    
    // Execute ADD
    try frame.add();
    
    // Verify result
    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 30), result);
}

test "Frame op_mul basic integration test" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    var test_evm = try TestHelpers.createTestEvm(allocator);
    defer test_evm.deinit();
    
    // Create frame
    const F = Frame(.{ .has_database = true });
    const bytecode = [_]u8{ 0x02, 0x00 }; // MUL STOP
    const host = test_evm.evm.to_host();
    
    var frame = try F.init(allocator, &bytecode, 100000, test_evm.evm.database, host);
    defer frame.deinit(allocator);
    
    // Setup stack for MUL operation
    try frame.stack.push(7);
    try frame.stack.push(6);
    
    // Execute MUL
    try frame.mul();
    
    // Verify result
    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 42), result);
}

test "Frame op_sload op_sstore integration test with real database" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    var test_evm = try TestHelpers.createTestEvm(allocator);
    defer test_evm.deinit();
    
    // Set up a contract account
    const contract_address = toAddress(0x1000);
    try TestHelpers.setupAccount(&test_evm, contract_address, 0, &[_]u8{});
    
    // Create frame
    const F = Frame(.{ .has_database = true });
    const bytecode = [_]u8{ 0x55, 0x54, 0x00 }; // SSTORE SLOAD STOP
    const host = test_evm.evm.to_host();
    
    var frame = try F.init(allocator, &bytecode, 100000, test_evm.evm.database, host);
    defer frame.deinit(allocator);
    
    frame.contract_address = contract_address;
    
    // Test SSTORE: store value 42 at slot 0
    try frame.stack.push(0);  // slot
    try frame.stack.push(42); // value
    try frame.sstore();
    
    // Test SLOAD: load value from slot 0
    try frame.stack.push(0);  // slot
    try frame.sload();
    
    // Verify the stored value was loaded correctly
    const loaded_value = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 42), loaded_value);
    
    // Verify the value is actually in the database
    const db_value = try test_evm.evm.database.get_storage(contract_address, 0);
    try std.testing.expectEqual(@as(u256, 42), db_value);
}

test "Frame op_keccak256 integration test with memory" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    var test_evm = try TestHelpers.createTestEvm(allocator);
    defer test_evm.deinit();
    
    // Create frame
    const F = Frame(.{ .has_database = true });
    const bytecode = [_]u8{ 0x20, 0x00 }; // KECCAK256 STOP
    const host = test_evm.evm.to_host();
    
    var frame = try F.init(allocator, &bytecode, 100000, test_evm.evm.database, host);
    defer frame.deinit(allocator);
    
    // Store test data "hello" in memory at offset 0
    const test_data = "hello";
    try frame.memory.set_data(0, test_data);
    
    // Setup stack for KECCAK256 operation
    try frame.stack.push(0); // offset
    try frame.stack.push(test_data.len); // length
    
    // Execute KECCAK256
    try frame.keccak256();
    
    // Verify we got a result (should be keccak256 hash of "hello")
    const result = try frame.stack.pop();
    try std.testing.expect(result != 0); // Should not be zero
    
    // Known keccak256("hello") = 0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8
    const expected: u256 = 0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8;
    try std.testing.expectEqual(expected, result);
}

test "Frame op_balance integration test with real accounts" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    var test_evm = try TestHelpers.createTestEvm(allocator);
    defer test_evm.deinit();
    
    // Set up an account with a specific balance
    const target_address = toAddress(0x1234);
    try TestHelpers.setupAccount(&test_evm, target_address, 5000, &[_]u8{});
    
    // Create frame
    const F = Frame(.{ .has_database = true });
    const bytecode = [_]u8{ 0x31, 0x00 }; // BALANCE STOP
    const host = test_evm.evm.to_host();
    
    var frame = try F.init(allocator, &bytecode, 100000, test_evm.evm.database, host);
    defer frame.deinit(allocator);
    
    // Setup stack for BALANCE operation
    try frame.stack.push(addressToU256(target_address));
    
    // Execute BALANCE
    try frame.balance();
    
    // Verify the balance is correct
    const balance = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 5000), balance);
}

test "Frame gas consumption tracking in real EVM context" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    var test_evm = try TestHelpers.createTestEvm(allocator);
    defer test_evm.deinit();
    
    // Create frame with limited gas
    const F = Frame(.{ .has_database = true });
    const bytecode = [_]u8{ 0x01, 0x00 }; // ADD STOP
    const host = test_evm.evm.to_host();
    
    var frame = try F.init(allocator, &bytecode, 100, test_evm.evm.database, host); // Low gas limit
    defer frame.deinit(allocator);
    
    const initial_gas = frame.gas_remaining;
    
    // Setup stack for ADD operation
    try frame.stack.push(10);
    try frame.stack.push(20);
    
    // Execute ADD
    try frame.add();
    
    // Verify gas was consumed
    try std.testing.expect(frame.gas_remaining < initial_gas);
    
    // Verify result is still correct
    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 30), result);
}