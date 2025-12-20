//! Integration tests for Frame system opcodes (CALL, DELEGATECALL, STATICCALL, CREATE, CREATE2, SELFDESTRUCT)
//! Uses real EVM instances instead of MockHost

const std = @import("std");
const Frame = @import("evm").Frame;
const TestHelpers = @import("frame_test_helpers.zig");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const Evm = @import("evm").DefaultEvm;
const CallParams = @import("call_params.zig").CallParams;

// Import needed types
const toAddress = TestHelpers.toAddress;
const addressToU256 = TestHelpers.addressToU256;

test "Frame call basic functionality" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    var test_evm = try TestHelpers.createTestEvm(allocator);
    defer test_evm.deinit();
    
    // Deploy a simple contract that returns success
    const target_address = toAddress(0x2000);
    try TestHelpers.deploySuccessContract(&test_evm, target_address);
    
    // Create frame
    const F = Frame(.{ .has_database = true });
    const bytecode = [_]u8{ 0xF1, 0x00 }; // CALL STOP
    const host = test_evm.evm.to_host();
    
    var frame = try F.init(allocator, &bytecode, 100000, test_evm.evm.database, host);
    defer frame.deinit(allocator);
    
    // Setup stack: [gas, address, value, input_offset, input_size, output_offset, output_size]
    try frame.stack.push(21000);                          // gas
    try frame.stack.push(addressToU256(target_address)); // address
    try frame.stack.push(0);                              // value
    try frame.stack.push(0);                              // input_offset
    try frame.stack.push(0);                              // input_size
    try frame.stack.push(0);                              // output_offset
    try frame.stack.push(32);                             // output_size
    
    // Execute CALL
    try frame.call();
    
    // Should push success (1) to stack
    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), result);
}

test "Frame call static context with value fails" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    var test_evm = try TestHelpers.createTestEvm(allocator);
    defer test_evm.deinit();
    
    const target_address = toAddress(0x2000);
    try TestHelpers.setupAccount(&test_evm, target_address, 1000, &[_]u8{});
    
    // Create frame
    const F = Frame(.{ .has_database = true });
    const bytecode = [_]u8{ 0xF1, 0x00 }; // CALL STOP
    const host = test_evm.evm.to_host();
    
    var frame = try F.init(allocator, &bytecode, 100000, test_evm.evm.database, host);
    defer frame.deinit(allocator);
    frame.is_static = true; // Set static context
    
    // Setup stack with non-zero value
    try frame.stack.push(21000);                          // gas
    try frame.stack.push(addressToU256(target_address)); // address
    try frame.stack.push(100);                            // value (non-zero)
    try frame.stack.push(0);                              // input_offset
    try frame.stack.push(0);                              // input_size
    try frame.stack.push(0);                              // output_offset
    try frame.stack.push(0);                              // output_size
    
    // Should fail with WriteProtection
    try std.testing.expectError(error.WriteProtection, frame.call());
}

test "Frame call stack underflow" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    var test_evm = try TestHelpers.createTestEvm(allocator);
    defer test_evm.deinit();
    
    // Create frame
    const F = Frame(.{ .has_database = true });
    const bytecode = [_]u8{ 0xF1, 0x00 }; // CALL STOP
    const host = test_evm.evm.to_host();
    
    var frame = try F.init(allocator, &bytecode, 100000, test_evm.evm.database, host);
    defer frame.deinit(allocator);
    
    // Only push 3 items instead of required 7
    try frame.stack.push(21000);
    try frame.stack.push(0x1234);
    try frame.stack.push(100);
    
    // Should fail with stack underflow
    try std.testing.expectError(error.StackUnderflow, frame.call());
}

test "Frame delegatecall basic functionality" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    var test_evm = try TestHelpers.createTestEvm(allocator);
    defer test_evm.deinit();
    
    // Deploy context reader contract
    const target_address = toAddress(0x2000);
    try TestHelpers.deployContextReaderContract(&test_evm, target_address);
    
    // Create frame with specific context
    const F = Frame(.{ .has_database = true });
    const bytecode = [_]u8{ 0xF4, 0x00 }; // DELEGATECALL STOP
    const host = test_evm.evm.to_host();
    
    var frame = try F.init(allocator, &bytecode, 100000, test_evm.evm.database, host);
    defer frame.deinit(allocator);
    
    const caller_address = toAddress(0x1000);
    frame.contract_address = caller_address;
    frame.caller = toAddress(0x3000);
    frame.value = 999;
    
    // Setup stack: [gas, address, input_offset, input_size, output_offset, output_size]
    try frame.stack.push(50000);                          // gas
    try frame.stack.push(addressToU256(target_address)); // address
    try frame.stack.push(0);                              // input_offset
    try frame.stack.push(0);                              // input_size
    try frame.stack.push(0);                              // output_offset
    try frame.stack.push(32);                             // output_size
    
    // Execute DELEGATECALL
    try frame.delegatecall();
    
    // Should push success (1) to stack
    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), result);
}

test "Frame staticcall basic functionality" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    var test_evm = try TestHelpers.createTestEvm(allocator);
    defer test_evm.deinit();
    
    // Deploy simple success contract
    const target_address = toAddress(0x2000);
    try TestHelpers.deploySuccessContract(&test_evm, target_address);
    
    // Create frame
    const F = Frame(.{ .has_database = true });
    const bytecode = [_]u8{ 0xFA, 0x00 }; // STATICCALL STOP
    const host = test_evm.evm.to_host();
    
    var frame = try F.init(allocator, &bytecode, 100000, test_evm.evm.database, host);
    defer frame.deinit(allocator);
    
    // Setup stack: [gas, address, input_offset, input_size, output_offset, output_size]
    try frame.stack.push(50000);                          // gas
    try frame.stack.push(addressToU256(target_address)); // address
    try frame.stack.push(0);                              // input_offset
    try frame.stack.push(0);                              // input_size
    try frame.stack.push(0);                              // output_offset
    try frame.stack.push(32);                             // output_size
    
    // Execute STATICCALL
    try frame.staticcall();
    
    // Should push success (1) to stack
    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), result);
}

test "Frame staticcall prevents state changes" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    var test_evm = try TestHelpers.createTestEvm(allocator);
    defer test_evm.deinit();
    
    // Deploy contract that tries to modify storage
    const target_address = toAddress(0x2000);
    try TestHelpers.deployStorageModifierContract(&test_evm, target_address);
    
    // Create frame
    const F = Frame(.{ .has_database = true });
    const bytecode = [_]u8{ 0xFA, 0x00 }; // STATICCALL STOP
    const host = test_evm.evm.to_host();
    
    var frame = try F.init(allocator, &bytecode, 100000, test_evm.evm.database, host);
    defer frame.deinit(allocator);
    
    // Setup stack for STATICCALL
    try frame.stack.push(50000);                          // gas
    try frame.stack.push(addressToU256(target_address)); // address
    try frame.stack.push(0);                              // input_offset
    try frame.stack.push(0);                              // input_size
    try frame.stack.push(0);                              // output_offset
    try frame.stack.push(32);                             // output_size
    
    // Execute STATICCALL
    try frame.staticcall();
    
    // Should fail because the called contract tries to modify state
    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result); // Failure
}

test "Frame create basic functionality" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    var test_evm = try TestHelpers.createTestEvm(allocator);
    defer test_evm.deinit();
    
    // Set up creator account with balance
    const creator_address = toAddress(0x1000);
    try TestHelpers.setupAccount(&test_evm, creator_address, 10000, &[_]u8{});
    
    // Create frame
    const F = Frame(.{ .has_database = true });
    const bytecode = [_]u8{ 0xF0, 0x00 }; // CREATE STOP
    const host = test_evm.evm.to_host();
    
    var frame = try F.init(allocator, &bytecode, 200000, test_evm.evm.database, host);
    defer frame.deinit(allocator);
    
    frame.contract_address = creator_address;
    
    // Store init code in memory
    const init_code = TestHelpers.getSimpleInitCode();
    try frame.memory.set_data(0, &init_code);
    
    // Setup stack: [value, offset, size]
    try frame.stack.push(1000);       // value
    try frame.stack.push(0);          // offset
    try frame.stack.push(init_code.len); // size
    
    // Execute CREATE
    try frame.create();
    
    // Get the created contract address from stack
    const created_address_u256 = try frame.stack.pop();
    
    // Verify contract was created (non-zero address)
    try std.testing.expect(created_address_u256 != 0);
}

test "Frame create static context fails" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    var test_evm = try TestHelpers.createTestEvm(allocator);
    defer test_evm.deinit();
    
    // Create frame
    const F = Frame(.{ .has_database = true });
    const bytecode = [_]u8{ 0xF0, 0x00 }; // CREATE STOP
    const host = test_evm.evm.to_host();
    
    var frame = try F.init(allocator, &bytecode, 100000, test_evm.evm.database, host);
    defer frame.deinit(allocator);
    frame.is_static = true; // Set static context
    
    // Setup stack
    try frame.stack.push(100); // value
    try frame.stack.push(0);   // offset
    try frame.stack.push(0);   // size
    
    // Should fail with WriteProtection
    try std.testing.expectError(error.WriteProtection, frame.create());
}

test "Frame create2 basic functionality" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    var test_evm = try TestHelpers.createTestEvm(allocator);
    defer test_evm.deinit();
    
    // Set up creator account with balance
    const creator_address = toAddress(0x1000);
    try TestHelpers.setupAccount(&test_evm, creator_address, 10000, &[_]u8{});
    
    // Create frame
    const F = Frame(.{ .has_database = true });
    const bytecode = [_]u8{ 0xF5, 0x00 }; // CREATE2 STOP
    const host = test_evm.evm.to_host();
    
    var frame = try F.init(allocator, &bytecode, 200000, test_evm.evm.database, host);
    defer frame.deinit(allocator);
    
    frame.contract_address = creator_address;
    
    // Store init code in memory
    const init_code = TestHelpers.getSimpleInitCode();
    try frame.memory.set_data(0, &init_code);
    
    // Setup stack: [value, offset, size, salt]
    try frame.stack.push(1000);              // value
    try frame.stack.push(0);                 // offset
    try frame.stack.push(init_code.len);     // size
    try frame.stack.push(0x123456789abcdef0); // salt
    
    // Execute CREATE2
    try frame.create2();
    
    // Get the created contract address from stack
    const created_address_u256 = try frame.stack.pop();
    
    // Verify contract was created (non-zero address)
    try std.testing.expect(created_address_u256 != 0);
}

test "Frame selfdestruct basic functionality" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    var test_evm = try TestHelpers.createTestEvm(allocator);
    defer test_evm.deinit();
    
    // Set up contract and recipient
    const contract_address = toAddress(0x1000);
    const recipient_address = toAddress(0x2000);
    
    try TestHelpers.setupAccount(&test_evm, contract_address, 5000, &[_]u8{});
    try TestHelpers.setupAccount(&test_evm, recipient_address, 1000, &[_]u8{});
    
    // Create frame
    const F = Frame(.{ .has_database = true });
    const bytecode = [_]u8{ 0xFF, 0x00 }; // SELFDESTRUCT STOP
    const host = test_evm.evm.to_host();
    
    var frame = try F.init(allocator, &bytecode, 100000, test_evm.evm.database, host);
    defer frame.deinit(allocator);
    
    frame.contract_address = contract_address;
    
    // Setup stack: [recipient]
    try frame.stack.push(addressToU256(recipient_address));
    
    // Execute SELFDESTRUCT
    try frame.selfdestruct();
}

test "Frame selfdestruct static context fails" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    var test_evm = try TestHelpers.createTestEvm(allocator);
    defer test_evm.deinit();
    
    // Create frame
    const F = Frame(.{ .has_database = true });
    const bytecode = [_]u8{ 0xFF, 0x00 }; // SELFDESTRUCT STOP
    const host = test_evm.evm.to_host();
    
    var frame = try F.init(allocator, &bytecode, 100000, test_evm.evm.database, host);
    defer frame.deinit(allocator);
    frame.is_static = true; // Set static context
    
    // Setup stack
    try frame.stack.push(0x22); // recipient
    
    // Should fail with WriteProtection
    try std.testing.expectError(error.WriteProtection, frame.selfdestruct());
}

test "Frame selfdestruct stack underflow" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    var test_evm = try TestHelpers.createTestEvm(allocator);
    defer test_evm.deinit();
    
    // Create frame
    const F = Frame(.{ .has_database = true });
    const bytecode = [_]u8{ 0xFF, 0x00 }; // SELFDESTRUCT STOP
    const host = test_evm.evm.to_host();
    
    var frame = try F.init(allocator, &bytecode, 100000, test_evm.evm.database, host);
    defer frame.deinit(allocator);
    
    // Empty stack - should fail
    try std.testing.expectError(error.StackUnderflow, frame.selfdestruct());
}

test "Frame system opcodes with failing calls" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    var test_evm = try TestHelpers.createTestEvm(allocator);
    defer test_evm.deinit();
    
    // Deploy a contract that will revert
    const target_address = toAddress(0x2000);
    try TestHelpers.deployRevertContract(&test_evm, target_address);
    
    // Create frame
    const F = Frame(.{ .has_database = true });
    const bytecode = [_]u8{ 0xF1, 0x00 }; // CALL STOP
    const host = test_evm.evm.to_host();
    
    var frame = try F.init(allocator, &bytecode, 100000, test_evm.evm.database, host);
    defer frame.deinit(allocator);
    
    // Setup stack for CALL
    try frame.stack.push(50000);                          // gas
    try frame.stack.push(addressToU256(target_address)); // address
    try frame.stack.push(0);                              // value
    try frame.stack.push(0);                              // input_offset
    try frame.stack.push(0);                              // input_size
    try frame.stack.push(0);                              // output_offset
    try frame.stack.push(32);                             // output_size
    
    // Execute CALL
    try frame.call();
    
    // Should push failure (0) to stack
    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result); // Failed call
}

test "Frame call with value transfer" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    var test_evm = try TestHelpers.createTestEvm(allocator);
    defer test_evm.deinit();
    
    // Set up accounts with balances
    const caller_address = toAddress(0x1000);
    const target_address = toAddress(0x2000);
    
    try TestHelpers.setupAccount(&test_evm, caller_address, 10000, &[_]u8{});
    try TestHelpers.setupAccount(&test_evm, target_address, 500, &[_]u8{});
    
    // Create frame
    const F = Frame(.{ .has_database = true });
    const bytecode = [_]u8{ 0xF1, 0x00 }; // CALL STOP
    const host = test_evm.evm.to_host();
    
    var frame = try F.init(allocator, &bytecode, 100000, test_evm.evm.database, host);
    defer frame.deinit(allocator);
    
    frame.contract_address = caller_address;
    
    // Setup stack with value transfer
    try frame.stack.push(50000);                          // gas
    try frame.stack.push(addressToU256(target_address)); // address
    try frame.stack.push(1000);                           // value (transfer 1000 wei)
    try frame.stack.push(0);                              // input_offset
    try frame.stack.push(0);                              // input_size
    try frame.stack.push(0);                              // output_offset
    try frame.stack.push(0);                              // output_size
    
    // Execute CALL
    try frame.call();
    
    // Verify success
    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1), result);
}