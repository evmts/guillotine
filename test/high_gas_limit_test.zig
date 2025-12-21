const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");
const testing = std.testing;

test "High gas limit crash reproduction" {
    const allocator = testing.allocator;
    
    // The problematic gas limit from HighGasLimitFiller.json
    const HIGH_GAS_LIMIT: u64 = 0x7fffffffffffffff; // Max i64 value
    
    std.log.info("Testing with gas limit: {}", .{HIGH_GAS_LIMIT});
    
    // Create block info with the high gas limit
    const block_info = evm.BlockInfo{
        .chain_id = 1,
        .number = 1,
        .parent_hash = [_]u8{0} ** 32,
        .timestamp = 1000,
        .difficulty = 0x020000,
        .gas_limit = HIGH_GAS_LIMIT, // This is causing the crash
        .coinbase = primitives.Address.fromBytes(&([_]u8{0x2a} ++ [_]u8{0xdc} ** 19)) catch unreachable,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };
    
    // Set up database
    var database = evm.Database.init(allocator);
    defer database.deinit();
    
    // Create sender account with balance
    const sender = primitives.Address.fromBytes(&([_]u8{0xa9} ++ [_]u8{0x4f} ** 19)) catch unreachable;
    const sender_account = evm.Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
        .delegated_address = null,
    };
    try database.set_account(sender.bytes, sender_account);
    
    // Create recipient account
    const recipient = primitives.Address.fromBytes(&([_]u8{0xb9} ++ [_]u8{0x4f} ** 19)) catch unreachable;
    
    // Transaction context
    const tx_context = evm.TransactionContext{
        .gas_limit = 100_000, // Transaction gas limit (not the block gas limit)
        .coinbase = block_info.coinbase,
        .chain_id = 1,
        .blob_versioned_hashes = &.{},
        .blob_base_fee = 0,
    };
    
    // Try to create EVM instance - this might crash
    std.log.info("Creating EVM instance...", .{});
    
    var evm_instance = try evm.MainnetEvm.init(
        allocator,
        &database,
        block_info,
        tx_context,
        10, // gas_price
        sender,
    );
    defer evm_instance.deinit();
    
    std.log.info("EVM instance created successfully", .{});
    
    // Create a simple call
    const call_params = evm.CallParams{
        .call = .{
            .caller = sender,
            .to = recipient,
            .value = 900,
            .input = &.{0x32, 0x40, 0x34, 0x95, 0x48, 0x98, 0x34, 0x54}, // Some data
            .gas = 100_000,
        },
    };
    
    std.log.info("Executing call...", .{});
    var result = evm_instance.call(call_params);
    defer result.deinit(allocator);

    std.log.info("Test completed without crash", .{});
}

test "High gas limit with smaller value" {
    const allocator = testing.allocator;
    
    // Test with a more reasonable gas limit
    const NORMAL_GAS_LIMIT: u64 = 30_000_000;
    
    std.log.info("Testing with normal gas limit: {}", .{NORMAL_GAS_LIMIT});
    
    // Create block info with normal gas limit
    const block_info = evm.BlockInfo{
        .chain_id = 1,
        .number = 1,
        .parent_hash = [_]u8{0} ** 32,
        .timestamp = 1000,
        .difficulty = 0x020000,
        .gas_limit = NORMAL_GAS_LIMIT,
        .coinbase = primitives.Address.fromBytes(&([_]u8{0x2a} ++ [_]u8{0xdc} ** 19)) catch unreachable,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };
    
    // Set up database
    var database = evm.Database.init(allocator);
    defer database.deinit();
    
    // Create sender account
    const sender = primitives.Address.fromBytes(&([_]u8{0xa9} ++ [_]u8{0x4f} ** 19)) catch unreachable;
    const sender_account = evm.Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
        .delegated_address = null,
    };
    try database.set_account(sender.bytes, sender_account);
    
    // Transaction context
    const tx_context = evm.TransactionContext{
        .gas_limit = 100_000,
        .coinbase = block_info.coinbase,
        .chain_id = 1,
        .blob_versioned_hashes = &.{},
        .blob_base_fee = 0,
    };
    
    var evm_instance = try evm.MainnetEvm.init(
        allocator,
        &database,
        block_info,
        tx_context,
        10,
        sender,
    );
    defer evm_instance.deinit();
    
    std.log.info("Normal gas limit test completed successfully", .{});
}