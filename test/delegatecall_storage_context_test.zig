const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const evm = @import("evm");

// Test demonstrating DELEGATECALL storage context issue
// 
// Issue: DELEGATECALL should execute the target contract's code but in the caller's storage context.
// This means storage operations (SSTORE) should modify the caller's storage, not the delegate's.
//
// Current bug: The executeDelegatecall function in src/evm.zig passes params.to as the 
// address parameter to execute_frame, which causes storage operations to happen in the 
// delegate's context instead of the caller's context.
//
// Expected behavior:
// - When contract A does DELEGATECALL to contract B
// - B's code executes, but any SSTORE operations should modify A's storage
// - B's storage should remain unchanged
test "DELEGATECALL should store in caller's context, not delegate's context" {
    const allocator = testing.allocator;
    
    // Initialize database and EVM
    var db = evm.Database.init(allocator);
    defer db.deinit();
    
    const block_info = evm.BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    
    const tx_context = evm.TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var vm = try evm.Evm(.{}).init(allocator, &db, block_info, tx_context, 0, primitives.Address.ZERO_ADDRESS, .BERLIN);
    defer vm.deinit();
    
    // Create two addresses: caller and delegate
    const caller_addr = primitives.Address{ .bytes = [_]u8{0x01} ** 20 };
    const delegate_addr = primitives.Address{ .bytes = [_]u8{0x02} ** 20 };
    
    // Set up initial state
    // Caller has initial storage value 0xAA at slot 0
    try db.set_storage(caller_addr.bytes, 0, 0xAA);
    try db.set_account(caller_addr.bytes, evm.Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Delegate has no initial storage (should remain 0)
    try db.set_account(delegate_addr.bytes, evm.Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Delegate's code: PUSH1 0xCC PUSH1 0x00 SSTORE
    // This stores value 0xCC at storage slot 0
    const delegate_code = [_]u8{ 0x60, 0xCC, 0x60, 0x00, 0x55 };
    const code_hash = try db.set_code(&delegate_code);
    
    // Update the delegate account with the code hash
    try db.set_account(delegate_addr.bytes, evm.Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Execute DELEGATECALL from caller to delegate
    const call_params = evm.Evm(.{}).CallParams{
        .delegatecall = .{
            .caller = caller_addr,
            .to = delegate_addr,
            .input = &[_]u8{},
            .gas = 100_000,
        },
    };
    
    const result = vm.call(call_params);
    
    // Verify the call succeeded
    try testing.expect(result.success);
    
    // CRITICAL TEST: Verify storage was modified in caller's context
    const caller_storage = try db.get_storage(caller_addr.bytes, 0);
    try testing.expectEqual(@as(u256, 0xCC), caller_storage);
    
    // CRITICAL TEST: Verify delegate's storage remained unchanged
    const delegate_storage = try db.get_storage(delegate_addr.bytes, 0);
    try testing.expectEqual(@as(u256, 0), delegate_storage);
    
    // This test currently FAILS because executeDelegatecall passes params.to (delegate_addr)
    // as the address parameter to execute_frame, causing storage operations to happen
    // in the wrong context.
    //
    // The fix is to pass params.caller as the address parameter instead, so that
    // storage operations happen in the caller's context.
}