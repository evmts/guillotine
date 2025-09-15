//! Test for log reversion on REVERT opcode
//! This test demonstrates that logs should be reverted when a transaction fails,
//! but currently they are not (bug).

const std = @import("std");
const Evm = @import("evm").DefaultEvm;
const Database = @import("evm").Database;
const Address = @import("primitives").Address.Address;
const primitives = @import("primitives");
const CallParams = @import("evm").CallParams;
const BlockInfo = @import("evm").BlockInfo;
const TransactionContext = @import("evm").TransactionContext;
const Hardfork = @import("evm").Hardfork;

test "logs should be reverted on REVERT opcode" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    const database = try allocator.create(Database);
    database.* = Database.init(allocator);
    
    const block_info = BlockInfo.init();
    const tx_context = TransactionContext{
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    const gas_price = 0;
    const origin = primitives.ZERO_ADDRESS;
    const hardfork = Hardfork.CANCUN;
    
    const evm = try allocator.create(Evm);
    evm.* = try Evm.init(allocator, database, block_info, tx_context, gas_price, origin, hardfork);
    defer {
        evm.deinit();
        allocator.destroy(evm);
        database.deinit();
        allocator.destroy(database);
    }
    
    // Create contract address from 0x1000
    var contract_addr_bytes: [20]u8 = [_]u8{0} ** 20;
    var i: usize = 0;
    const contract_value: u256 = 0x1000;
    while (i < 20) : (i += 1) {
        contract_addr_bytes[19 - i] = @truncate(contract_value >> @intCast(i * 8));
    }
    const contract_address = Address.fromBytes(&contract_addr_bytes) catch unreachable;
    
    // Bytecode: Emit LOG1 then REVERT
    // PUSH1 0x42, PUSH1 0x00, MSTORE (store data)
    // PUSH1 0x00, PUSH1 0x20, PUSH1 0x99, LOG1 (emit log with correct stack order)
    // PUSH1 0x00, PUSH1 0x00, REVERT
    const bytecode = [_]u8{
        0x60, 0x42,  // PUSH1 0x42
        0x60, 0x00,  // PUSH1 0x00  
        0x52,        // MSTORE
        0x60, 0x00,  // PUSH1 0x00 (offset - bottom of stack)
        0x60, 0x20,  // PUSH1 0x20 (size - middle of stack)
        0x60, 0x99,  // PUSH1 0x99 (topic - top of stack)
        0xA1,        // LOG1
        0x60, 0x00,  // PUSH1 0x00 (offset)
        0x60, 0x00,  // PUSH1 0x00 (size)
        0xFD,        // REVERT
    };
    
    // Deploy contract
    const code_hash = try evm.database.set_code(&bytecode);
    var account = @import("evm").Account.zero();
    account.code_hash = code_hash;
    account.balance = 1000;
    try evm.database.set_account(contract_address.bytes, account);
    
    // Execute call
    // Create caller address from 0x2000
    var caller_addr_bytes: [20]u8 = [_]u8{0} ** 20;
    i = 0;
    const caller_value: u256 = 0x2000;
    while (i < 20) : (i += 1) {
        caller_addr_bytes[19 - i] = @truncate(caller_value >> @intCast(i * 8));
    }
    const caller_address = Address.fromBytes(&caller_addr_bytes) catch unreachable;
    const params = CallParams{ .call = .{
        .caller = caller_address,
        .to = contract_address,
        .value = 0,
        .input = &.{},
        .gas = 100000,
    } };
    
    var result = evm.call(params);
    defer result.deinit(allocator);
    
    // Should fail due to REVERT
    try std.testing.expect(!result.success);
    
    // BUG: This will currently fail - logs are not reverted
    // According to Ethereum spec, all state changes including logs should be reverted
    try std.testing.expectEqual(@as(usize, 0), result.logs.len);
}

test "logs should be preserved on successful execution" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    const database = try allocator.create(Database);
    database.* = Database.init(allocator);
    
    const block_info = BlockInfo.init();
    const tx_context = TransactionContext{
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    const gas_price = 0;
    const origin = primitives.ZERO_ADDRESS;
    const hardfork = Hardfork.CANCUN;
    
    const evm = try allocator.create(Evm);
    evm.* = try Evm.init(allocator, database, block_info, tx_context, gas_price, origin, hardfork);
    defer {
        evm.deinit();
        allocator.destroy(evm);
        database.deinit();
        allocator.destroy(database);
    }
    
    // Create contract address from 0x1000
    var contract_addr_bytes: [20]u8 = [_]u8{0} ** 20;
    var i: usize = 0;
    const contract_value: u256 = 0x1000;
    while (i < 20) : (i += 1) {
        contract_addr_bytes[19 - i] = @truncate(contract_value >> @intCast(i * 8));
    }
    const contract_address = Address.fromBytes(&contract_addr_bytes) catch unreachable;
    
    // Bytecode: Emit LOG1 then RETURN (success)
    // PUSH1 0x42, PUSH1 0x00, MSTORE (store data)
    // PUSH1 0x00, PUSH1 0x20, PUSH1 0x99, LOG1 (emit log with correct stack order)
    // PUSH1 0x00, PUSH1 0x00, RETURN
    const bytecode = [_]u8{
        0x60, 0x42,  // PUSH1 0x42
        0x60, 0x00,  // PUSH1 0x00  
        0x52,        // MSTORE
        0x60, 0x00,  // PUSH1 0x00 (offset - bottom of stack)
        0x60, 0x20,  // PUSH1 0x20 (size - middle of stack)
        0x60, 0x99,  // PUSH1 0x99 (topic - top of stack)
        0xA1,        // LOG1
        0x60, 0x00,  // PUSH1 0x00 (offset)
        0x60, 0x00,  // PUSH1 0x00 (size)
        0xF3,        // RETURN (success)
    };
    
    // Deploy contract
    const code_hash = try evm.database.set_code(&bytecode);
    var account = @import("evm").Account.zero();
    account.code_hash = code_hash;
    account.balance = 1000;
    try evm.database.set_account(contract_address.bytes, account);
    
    // Execute call
    // Create caller address from 0x2000
    var caller_addr_bytes: [20]u8 = [_]u8{0} ** 20;
    i = 0;
    const caller_value: u256 = 0x2000;
    while (i < 20) : (i += 1) {
        caller_addr_bytes[19 - i] = @truncate(caller_value >> @intCast(i * 8));
    }
    const caller_address = Address.fromBytes(&caller_addr_bytes) catch unreachable;
    const params = CallParams{ .call = .{
        .caller = caller_address,
        .to = contract_address,
        .value = 0,
        .input = &.{},
        .gas = 100000,
    } };
    
    var result = evm.call(params);
    defer result.deinit(allocator);
    
    // Should succeed
    try std.testing.expect(result.success);
    
    // Logs should be preserved on successful execution
    try std.testing.expectEqual(@as(usize, 1), result.logs.len);
    
    // Verify log content
    const log = result.logs[0];
    try std.testing.expectEqualSlices(u8, &contract_address.bytes, &log.address.bytes);
    try std.testing.expectEqual(@as(usize, 1), log.topics.len);
    try std.testing.expectEqual(@as(u256, 0x99), log.topics[0]);
    try std.testing.expectEqual(@as(usize, 32), log.data.len);
    try std.testing.expectEqual(@as(u8, 0x42), log.data[31]); // Last byte should be 0x42
}