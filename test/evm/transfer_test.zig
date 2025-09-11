const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

const Database = evm.Database;
const Account = evm.Account;
const BlockInfo = evm.BlockInfo;
const TransactionContext = evm.TransactionContext;
const Address = primitives.Address;

// Create the default EVM type
const DefaultEvm = evm.Evm(.{});

test "self-transfer should not change balance" {
    const allocator = testing.allocator;
    
    // Create database
    var database = Database.init(allocator);
    defer database.deinit();
    
    // Create block info and transaction context
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1_000_000_000,
        .prev_randao = [_]u8{0} ** 32,
        .chain_id = 1,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };
    const tx_context = TransactionContext{
        .gas_limit = 100_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    // Create caller account with balance  
    const caller_address = Address{ .bytes = [_]u8{0x12, 0x34, 0x56, 0x78, 0x90} ++ [_]u8{0} ** 15 };
    const initial_balance: u256 = 1_000_000_000;
    const caller_account = Account{
        .balance = initial_balance,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try database.set_account(caller_address.bytes, caller_account);
    
    // Create EVM instance
    var evm_instance = try DefaultEvm.init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address,
        .CANCUN
    );
    defer evm_instance.deinit();
    
    // Create a simple contract that transfers value to itself
    // This bytecode: CALLER PUSH1 100 CALL (simplified self-transfer attempt)
    // More realistic: we'll use a basic call that should trigger the transfer logic
    const transfer_value: u256 = 100;
    
    // Make a call to self with some value - this should trigger doTransfer internally
    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = caller_address,  // Self-call
            .input = &.{},
            .value = transfer_value,
            .gas = 100_000,
        },
    };
    
    const result = evm_instance.call(call_params);
    
    // Check that the balance didn't change (self-transfer should be no-op)
    const final_account = (try database.get_account(caller_address.bytes)).?;
    
    // With the fix, balance should remain the same
    // Without the fix, balance would be initial_balance + transfer_value = 1100
    try std.testing.expectEqual(initial_balance, final_account.balance);
    
    // The call should succeed
    try std.testing.expect(result.success);
}

test "normal transfer between different accounts works correctly" {
    const allocator = testing.allocator;
    
    // Create database
    var database = Database.init(allocator);
    defer database.deinit();
    
    // Create block info and transaction context
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1_000_000_000,
        .prev_randao = [_]u8{0} ** 32,
        .chain_id = 1,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };
    const tx_context = TransactionContext{
        .gas_limit = 100_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    // Create caller and target accounts
    const caller_address = Address{ .bytes = [_]u8{0x12, 0x34, 0x56, 0x78, 0x90} ++ [_]u8{0} ** 15 };
    const target_address = Address{ .bytes = [_]u8{0x98, 0x76, 0x54, 0x32, 0x10} ++ [_]u8{0} ** 15 };
    
    const initial_caller_balance: u256 = 1_000_000_000;
    const initial_target_balance: u256 = 500_000_000;
    const transfer_value: u256 = 100;
    
    const caller_account = Account{
        .balance = initial_caller_balance,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    
    const target_account = Account{
        .balance = initial_target_balance,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    
    try database.set_account(caller_address.bytes, caller_account);
    try database.set_account(target_address.bytes, target_account);
    
    // Create EVM instance
    var evm_instance = try DefaultEvm.init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address,
        .CANCUN
    );
    defer evm_instance.deinit();
    
    // Make a call to different account with value
    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = target_address,
            .input = &.{},
            .value = transfer_value,
            .gas = 100_000,
        },
    };
    
    const result = evm_instance.call(call_params);
    
    // Check that balances changed correctly
    const final_caller_account = (try database.get_account(caller_address.bytes)).?;
    const final_target_account = (try database.get_account(target_address.bytes)).?;
    
    try std.testing.expectEqual(initial_caller_balance - transfer_value, final_caller_account.balance);
    try std.testing.expectEqual(initial_target_balance + transfer_value, final_target_account.balance);

    // Log the entire result
    std.debug.print("Result: {}\n", .{result});
    
    // The call should succeed
    try std.testing.expect(result.success);
}