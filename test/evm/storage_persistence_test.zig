const std = @import("std");
const testing = std.testing;
const evm_mod = @import("evm");
const Evm = evm_mod.DefaultEvm;
const Database = evm_mod.Database;
const Account = evm_mod.Account;
const BlockInfo = evm_mod.BlockInfo;
const TransactionContext = evm_mod.TransactionContext;
const Hardfork = evm_mod.Hardfork;
const primitives = @import("primitives");
const Address = primitives.Address.Address;

test "storage persistence after SSTORE execution" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    
    // Initialize database
    var db = Database.init(testing.allocator);
    defer db.deinit();
    
    // Initialize EVM with required parameters
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm.init(arena.allocator(), &db, block_info, context, 0, primitives.ZERO_ADDRESS, Hardfork.CANCUN);
    defer evm.deinit();
    
    const contract_address: Address = .{ .bytes = [_]u8{0x12} ++ [_]u8{0} ** 19 };
    
    // Bytecode that stores value 42 at storage slot 0
    const bytecode = [_]u8{
        0x60, 0x2A,  // PUSH1 42 (value to store)
        0x60, 0x00,  // PUSH1 0 (storage slot)
        0x55,        // SSTORE
        0x00,        // STOP
    };
    
    // Set up contract account with bytecode
    const code_hash = try db.set_code(&bytecode);
    const account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(contract_address.bytes, account);
    
    // Verify initial storage is 0
    const initial_value = try db.get_storage(contract_address.bytes, 0);
    try testing.expectEqual(@as(u256, 0), initial_value);
    
    // Execute the bytecode
    const result = evm.call(.{
        .call = .{
            .caller = Address.ZERO_ADDRESS,
            .to = contract_address,
            .input = &[_]u8{},
            .gas = 100000,
            .value = 0,
        }
    });
    
    // Verify execution was successful
    try testing.expect(result.success);
    
    // Query storage after execution - THIS SHOULD BE 42 BUT WILL BE 0 (demonstrating the bug)
    const stored_value = try db.get_storage(contract_address.bytes, 0);
    
    // This assertion will fail, demonstrating the issue
    try testing.expectEqual(@as(u256, 42), stored_value);
}

test "storage persistence with multiple SSTORE operations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    
    // Initialize database
    var db = Database.init(testing.allocator);
    defer db.deinit();
    
    // Initialize EVM with required parameters
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm.init(arena.allocator(), &db, block_info, context, 0, primitives.ZERO_ADDRESS, Hardfork.CANCUN);
    defer evm.deinit();
    
    const contract_address: Address = .{ .bytes = [_]u8{0xab} ++ [_]u8{0} ** 19 };
    
    // Bytecode that stores multiple values
    const bytecode = [_]u8{
        // Store 100 at slot 0
        0x60, 0x64,  // PUSH1 100
        0x60, 0x00,  // PUSH1 0
        0x55,        // SSTORE
        
        // Store 200 at slot 1
        0x60, 0xC8,  // PUSH1 200
        0x60, 0x01,  // PUSH1 1
        0x55,        // SSTORE
        
        // Store 300 at slot 2
        0x61, 0x01, 0x2C,  // PUSH2 300
        0x60, 0x02,        // PUSH1 2
        0x55,              // SSTORE
        
        0x00,        // STOP
    };
    
    // Set up contract account with bytecode
    const code_hash = try db.set_code(&bytecode);
    const account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(contract_address.bytes, account);
    
    // Verify initial storage is all zeros
    try testing.expectEqual(@as(u256, 0), try db.get_storage(contract_address.bytes, 0));
    try testing.expectEqual(@as(u256, 0), try db.get_storage(contract_address.bytes, 1));
    try testing.expectEqual(@as(u256, 0), try db.get_storage(contract_address.bytes, 2));
    
    // Execute the bytecode
    const result = evm.call(.{
        .call = .{
            .caller = Address.ZERO_ADDRESS,
            .to = contract_address,
            .input = &[_]u8{},
            .gas = 100000,
            .value = 0,
        }
    });
    
    // Verify execution was successful
    try testing.expect(result.success);
    
    // Query all storage slots after execution - all should have the stored values
    const value0 = try db.get_storage(contract_address.bytes, 0);
    const value1 = try db.get_storage(contract_address.bytes, 1);
    const value2 = try db.get_storage(contract_address.bytes, 2);
    
    // These assertions will fail, demonstrating the issue
    try testing.expectEqual(@as(u256, 100), value0);
    try testing.expectEqual(@as(u256, 200), value1);
    try testing.expectEqual(@as(u256, 300), value2);
}