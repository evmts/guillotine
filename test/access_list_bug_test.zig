//! Test to demonstrate the access list bug where accessed addresses and storage
//! are tracked during execution but never returned in CallResult.

const std = @import("std");
const Evm = @import("evm").DefaultEvm;
const MemoryDatabase = @import("evm").MemoryDatabase;
const Address = @import("primitives").Address.Address;
const primitives = @import("primitives");
const CallParams = @import("evm").CallParams;
const BlockInfo = @import("evm").DefaultBlockInfo;
const TransactionContext = @import("evm").TransactionContext;
const Hardfork = @import("evm").Hardfork;
const Account = @import("evm").Account;

/// Helper to create a configured EVM instance for testing
fn createTestEvm(allocator: std.mem.Allocator) !struct { evm: *Evm, memory_db: *MemoryDatabase } {
    const memory_db = try allocator.create(MemoryDatabase);
    memory_db.* = MemoryDatabase.init(allocator);
    const db_interface = memory_db.to_database_interface();
    
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .chain_id = 1,
        .difficulty = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    
    const tx_context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
        .blob_versioned_hashes = &.{},
    };
    
    const gas_price = 0;
    const origin = primitives.ZERO_ADDRESS;
    const hardfork = Hardfork.CANCUN;
    
    const evm = try allocator.create(Evm);
    evm.* = try Evm.init(allocator, db_interface, block_info, tx_context, gas_price, origin, hardfork);
    return .{ .evm = evm, .memory_db = memory_db };
}

test "Access lists should be populated in CallResult" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Create EVM instance
    const ctx = try createTestEvm(allocator);
    var evm = ctx.evm;
    defer {
        evm.deinit();
        allocator.destroy(evm);
        ctx.memory_db.deinit();
        allocator.destroy(ctx.memory_db);
    }
    
    // Deploy contracts
    const contract_a = Address.fromHex("1111111111111111111111111111111111111111") catch unreachable;
    const contract_b = Address.fromHex("2222222222222222222222222222222222222222") catch unreachable;
    
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
    
    const code_hash_a = try ctx.memory_db.set_code(&bytecode_a);
    const account_a = Account{
        .balance = 0,
        .code_hash = code_hash_a,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
        .delegated_address = null,
    };
    try ctx.memory_db.set_account(contract_a.bytes, account_a);
    
    // Set up contract B (empty code)
    const account_b = Account{
        .balance = 1000,
        .code_hash = primitives.EMPTY_CODE_HASH,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
        .delegated_address = null,
    };
    try ctx.memory_db.set_account(contract_b.bytes, account_b);
    
    // Execute call to contract A
    const params = CallParams{ .call = .{
        .caller = primitives.ZERO_ADDRESS,
        .to = contract_a,
        .value = 0,
        .input = &.{},
        .gas = 100_000,
    }};
    
    const result = try evm.call(params);
    
    // Verify access lists were populated
    try testing.expect(result.success);
    
    // Should have accessed at least contract_a and contract_b
    std.debug.print("Accessed addresses count: {}\n", .{result.accessed_addresses.len});
    for (result.accessed_addresses, 0..) |addr, i| {
        std.debug.print("  Address[{}]: {any}\n", .{i, addr});
    }
    
    try testing.expect(result.accessed_addresses.len >= 2);
    
    // Should have accessed storage slots 0, 5, and 10
    std.debug.print("Accessed storage count: {}\n", .{result.accessed_storage.len});
    for (result.accessed_storage, 0..) |access, i| {
        std.debug.print("  Storage[{}]: {any} slot {}\n", .{i, access.address, access.slot});
    }
    
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