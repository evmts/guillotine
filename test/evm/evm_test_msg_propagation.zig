//! Tests for msg.sender and msg.value propagation across call types

const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const evm_mod = @import("evm.zig");
const Evm = evm_mod.Evm;
const DefaultEvm = evm_mod.DefaultEvm;
const DefaultBlockInfo = evm_mod.DefaultBlockInfo;
const TransactionContext = evm_mod.TransactionContext;
const Account = evm_mod.Account;
const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
const DatabaseInterface = @import("database_interface.zig").DatabaseInterface;

const ZERO_ADDRESS = Address.ZERO;

test "EVM msg.sender propagation in CALL" {
    const allocator = testing.allocator;
    
    // Create test database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);
    
    // Add a contract that returns the caller address
    // CALLER opcode pushes msg.sender to stack
    const contract_code = [_]u8{
        0x33,        // CALLER
        0x60, 0x00,  // PUSH1 0
        0x52,        // MSTORE - store caller at memory[0]
        0x60, 0x20,  // PUSH1 32
        0x60, 0x00,  // PUSH1 0
        0xF3,        // RETURN - return 32 bytes from memory[0]
    };
    const contract_address: Address = [_]u8{0x42} ++ [_]u8{0} ** 19;
    var account = Account{
        .nonce = 0,
        .balance = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    account.set_code(&contract_code);
    try memory_db.set_account(contract_address, account);
    
    const block_info = DefaultBlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .gas_limit = 30_000_000,
        .difficulty = 1,
        .coinbase = ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    
    const original_caller: Address = [_]u8{0xAA} ++ [_]u8{0} ** 19;
    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm = try DefaultEvm.init(allocator, db_interface, block_info, tx_context, 0, original_caller, .BERLIN);
    defer evm.deinit();
    
    // Test CALL - new msg.sender should be the calling contract
    const calling_contract: Address = [_]u8{0xBB} ++ [_]u8{0} ** 19;
    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = calling_contract, // This becomes msg.sender in the called contract
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 1000000,
        },
    };
    
    const result = try evm.call(call_params);
    try testing.expect(result.success);
    
    // The returned data should be the caller address (calling_contract)
    try testing.expectEqual(@as(usize, 32), result.output.len);
    
    // Convert output bytes to address (last 20 bytes of the 32-byte word)
    var returned_address: Address = undefined;
    @memcpy(&returned_address, result.output[12..32]);
    
    try testing.expectEqualSlices(u8, &calling_contract, &returned_address);
}

test "EVM msg.sender preservation in DELEGATECALL" {
    const allocator = testing.allocator;
    
    // Create test database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);
    
    // Add a contract that returns the caller address
    const contract_code = [_]u8{
        0x33,        // CALLER
        0x60, 0x00,  // PUSH1 0
        0x52,        // MSTORE - store caller at memory[0]
        0x60, 0x20,  // PUSH1 32
        0x60, 0x00,  // PUSH1 0
        0xF3,        // RETURN - return 32 bytes from memory[0]
    };
    const contract_address: Address = [_]u8{0x42} ++ [_]u8{0} ** 19;
    var account = Account{
        .nonce = 0,
        .balance = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    account.set_code(&contract_code);
    try memory_db.set_account(contract_address, account);
    
    const block_info = DefaultBlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .gas_limit = 30_000_000,
        .difficulty = 1,
        .coinbase = ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    
    const original_caller: Address = [_]u8{0xAA} ++ [_]u8{0} ** 19;
    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm = try DefaultEvm.init(allocator, db_interface, block_info, tx_context, 0, original_caller, .BERLIN);
    defer evm.deinit();
    
    // Test DELEGATECALL - should preserve original caller
    const delegatecall_params = DefaultEvm.CallParams{
        .delegatecall = .{
            .caller = original_caller, // This should be preserved in delegatecall
            .to = contract_address,
            .input = &.{},
            .gas = 1000000,
        },
    };
    
    const result = try evm.call(delegatecall_params);
    try testing.expect(result.success);
    
    // The returned data should be the original caller address
    try testing.expectEqual(@as(usize, 32), result.output.len);
    
    // Convert output bytes to address (last 20 bytes of the 32-byte word)
    var returned_address: Address = undefined;
    @memcpy(&returned_address, result.output[12..32]);
    
    try testing.expectEqualSlices(u8, &original_caller, &returned_address);
}

test "EVM msg.value propagation" {
    const allocator = testing.allocator;
    
    // Create test database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);
    
    // Add a contract that returns the call value
    const contract_code = [_]u8{
        0x34,        // CALLVALUE
        0x60, 0x00,  // PUSH1 0
        0x52,        // MSTORE - store value at memory[0]
        0x60, 0x20,  // PUSH1 32
        0x60, 0x00,  // PUSH1 0
        0xF3,        // RETURN - return 32 bytes from memory[0]
    };
    const contract_address: Address = [_]u8{0x42} ++ [_]u8{0} ** 19;
    var account = Account{
        .nonce = 0,
        .balance = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    account.set_code(&contract_code);
    try memory_db.set_account(contract_address, account);
    
    // Give caller some balance to send value
    const caller_address: Address = [_]u8{0xAA} ++ [_]u8{0} ** 19;
    var caller_account = Account{
        .nonce = 0,
        .balance = 1000000,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    caller_account.set_code_empty();
    try memory_db.set_account(caller_address, caller_account);
    
    const block_info = DefaultBlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .gas_limit = 30_000_000,
        .difficulty = 1,
        .coinbase = ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    
    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm = try DefaultEvm.init(allocator, db_interface, block_info, tx_context, 0, caller_address, .BERLIN);
    defer evm.deinit();
    
    // Test CALL with value
    const test_value: u256 = 12345;
    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = test_value,
            .input = &.{},
            .gas = 1000000,
        },
    };
    
    const result = try evm.call(call_params);
    try testing.expect(result.success);
    
    // The returned data should be the call value
    try testing.expectEqual(@as(usize, 32), result.output.len);
    
    // Convert output bytes to u256
    const returned_value = std.mem.readInt(u256, result.output[0..32], .big);
    
    try testing.expectEqual(test_value, returned_value);
}