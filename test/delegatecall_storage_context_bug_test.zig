const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const evm = @import("evm");
const DefaultEvm = evm.DefaultEvm;
const Address = primitives.Address;
const Account = evm.Account;
const Database = evm.Database;

// Test that demonstrates the DELEGATECALL storage context bug.
// This test shows that DELEGATECALL currently modifies target contract's storage
// instead of the caller's storage, violating EVM specification.
test "DELEGATECALL storage context bug demonstration" {
    const allocator = testing.allocator;
    
    // Create database and EVM instance
    var db = Database.init(allocator);
    defer db.deinit();
    
    var evm = try DefaultEvm.init(
        allocator,
        &db,
        .{ .number = 1, .timestamp = 1, .gas_limit = 1000000, .coinbase = Address.zero(), .base_fee = 0, .chain_id = 1, .difficulty = 0, .prev_randao = [_]u8{0} ** 32 },
        .{ .gas_limit = 1000000, .coinbase = Address.zero(), .chain_id = 1, .blob_versioned_hashes = &.{} },
        0,
        Address.zero(),
        .DEFAULT,
    );
    defer evm.deinit();
    
    // Contract B: Simple contract that stores 42 in slot 0
    const bytecode_b = [_]u8{
        0x60, 0x2A,  // PUSH1 42 (value to store)
        0x60, 0x00,  // PUSH1 0 (storage slot)
        0x55,        // SSTORE (store 42 in slot 0)
        0x60, 0x01,  // PUSH1 1 (success indicator)
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE (store success in memory)
        0x60, 0x20,  // PUSH1 32 (return size)
        0x60, 0x00,  // PUSH1 0 (return offset)
        0xF3,        // RETURN
    };
    
    // Contract A: Performs DELEGATECALL to Contract B
    const addr_b = Address.from_u256(101);
    const bytecode_a = [_]u8{
        // DELEGATECALL setup (6 stack items required)
        0x60, 0x20,  // PUSH1 32 (retSize) 
        0x60, 0x00,  // PUSH1 0 (retOffset)
        0x60, 0x00,  // PUSH1 0 (argsSize) 
        0x60, 0x00,  // PUSH1 0 (argsOffset)
        0x73,        // PUSH20 (contract B address)
    } ++ addr_b.bytes ++ [_]u8{
        0x5A,        // GAS (all remaining gas)
        0xF4,        // DELEGATECALL
        // Return the call result
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE (store result in memory)
        0x60, 0x20,  // PUSH1 32 (return size)
        0x60, 0x00,  // PUSH1 0 (return offset)
        0xF3,        // RETURN
    };
    
    // Set up contract addresses
    const addr_a = Address.from_u256(100);
    
    // Store bytecode and create accounts
    const code_hash_a = try db.set_code(&bytecode_a);
    const code_hash_b = try db.set_code(&bytecode_b);
    
    const account_a = Account{ 
        .balance = 0, 
        .code_hash = code_hash_a, 
        .storage_root = [_]u8{0} ** 32, 
        .nonce = 0, 
        .delegated_address = null 
    };
    const account_b = Account{ 
        .balance = 0, 
        .code_hash = code_hash_b, 
        .storage_root = [_]u8{0} ** 32, 
        .nonce = 0, 
        .delegated_address = null 
    };
    
    try db.set_account(addr_a.bytes, account_a);
    try db.set_account(addr_b.bytes, account_b);
    
    // Execute DELEGATECALL: A calls B
    const result = evm.call(.{ .call = .{
        .caller = Address.zero(),
        .to = addr_a,
        .value = 0,
        .input = &.{},
        .gas = 100000,
    }});
    
    // The call should succeed
    try testing.expect(result.success);
    
    // Check storage states
    const storage_a_slot_0 = try db.get_storage(addr_a.bytes, 0);
    const storage_b_slot_0 = try db.get_storage(addr_b.bytes, 0);
    
    // BUG: Currently this test will FAIL because:
    // - storage_a_slot_0 will be 0 (unchanged) 
    // - storage_b_slot_0 will be 42 (incorrectly modified)
    //
    // EXPECTED behavior per EVM spec:
    // - storage_a_slot_0 should be 42 (caller's storage modified)
    // - storage_b_slot_0 should be 0 (target's storage unchanged)
    
    std.debug.print("Contract A storage slot 0: {}\n", .{storage_a_slot_0});
    std.debug.print("Contract B storage slot 0: {}\n", .{storage_b_slot_0});
    
    // These assertions demonstrate the bug:
    // Currently FAILING assertions (this is the bug we're fixing):
    try testing.expectEqual(@as(u256, 42), storage_a_slot_0);  // Should pass but currently fails
    try testing.expectEqual(@as(u256, 0), storage_b_slot_0);   // Should pass but currently fails
}