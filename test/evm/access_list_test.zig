//! Test to demonstrate the access list bug where accessed addresses and storage
//! are tracked during execution but never returned in CallResult.

const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

const Evm = evm.Evm;
const Database = evm.Database;
const CallParams = evm.CallParams;
const Address = primitives.Address.Address;
const BlockInfo = evm.BlockInfo;
const TransactionContext = evm.TransactionContext;

test "Access lists should be populated in CallResult" {
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
    const caller_address = Address.from_hex("0x1234567890123456789012345678901234567890") catch unreachable;
    const caller_account = evm.Account{
        .balance = 1_000_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
        .delegated_address = null,
    };
    try database.set_account(caller_address.bytes, caller_account);
    
    // Create EVM instance
    var evm_instance = try Evm(.{}).init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address,
        .CANCUN
    );
    defer evm_instance.deinit();
    
    // Deploy contracts
    const contract_a = Address.from_hex("0x1111111111111111111111111111111111111111") catch unreachable;
    const contract_b = Address.from_hex("0x2222222222222222222222222222222222222222") catch unreachable;
    
    // Bytecode for contract A:
    // PUSH20 contract_b, BALANCE (accesses address)
    // PUSH1 0, SLOAD (accesses storage slot 0)
    // PUSH1 5, SLOAD (accesses storage slot 5)
    // PUSH1 42, PUSH1 10, SSTORE (accesses storage slot 10)
    // STOP
    var bytecode_a = [_]u8{0x73} ++ contract_b.bytes ++ [_]u8{
        0x31,              // BALANCE
        0x60, 0x00, 0x54,  // PUSH1 0, SLOAD
        0x60, 0x05, 0x54,  // PUSH1 5, SLOAD
        0x60, 0x2a,        // PUSH1 42
        0x60, 0x0a,        // PUSH1 10
        0x55,              // SSTORE
        0x00,              // STOP
    };
    
    const code_hash_a = try database.set_code(&bytecode_a);
    const account_a = evm.Account{
        .balance = 0,
        .code_hash = code_hash_a,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
        .delegated_address = null,
    };
    try database.set_account(contract_a.bytes, account_a);
    
    // Set up contract B (empty code)
    const account_b = evm.Account{
        .balance = 1000,
        .code_hash = primitives.EMPTY_CODE_HASH,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
        .delegated_address = null,
    };
    try database.set_account(contract_b.bytes, account_b);
    
    // Execute call to contract A
    const params = CallParams{ .call = .{
        .caller = caller_address,
        .to = contract_a,
        .value = 0,
        .input = &.{},
        .gas = 100_000,
    }};
    
    var result = evm_instance.call(params);
    defer result.deinit(allocator);
    
    // Verify access lists were populated
    try testing.expect(result.success);
    
    // Should have accessed at least contract_a and contract_b
    try testing.expect(result.accessed_addresses.len >= 2);
    
    // Check that contract_a and contract_b are in the accessed addresses (order doesn't matter)
    var found_contract_a = false;
    var found_contract_b = false;
    for (result.accessed_addresses) |addr| {
        if (std.mem.eql(u8, &addr.bytes, &contract_a.bytes)) {
            found_contract_a = true;
        }
        if (std.mem.eql(u8, &addr.bytes, &contract_b.bytes)) {
            found_contract_b = true;
        }
    }
    try testing.expect(found_contract_a);
    try testing.expect(found_contract_b);
    
    // Should have accessed storage slots 0, 5, and 10
    
    try testing.expect(result.accessed_storage.len == 3);
    
    // Verify specific storage accesses
    var found_slot_0 = false;
    var found_slot_5 = false;
    var found_slot_10 = false;
    
    for (result.accessed_storage) |access| {
        if (std.mem.eql(u8, &access.address.bytes, &contract_a.bytes)) {
            if (access.slot == 0) found_slot_0 = true;
            if (access.slot == 5) found_slot_5 = true;
            if (access.slot == 10) found_slot_10 = true;
        }
    }
    
    try testing.expect(found_slot_0);
    try testing.expect(found_slot_5);
    try testing.expect(found_slot_10);
}