const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const evm = @import("evm");

// Test demonstrating STATICCALL write protection issue
//
// Issue: STATICCALL should enforce read-only execution. Any attempt to modify state
// (SSTORE, LOG, CREATE, SELFDESTRUCT, or calls with value) should fail immediately.
//
// Current bug: The executeStaticcall function in src/evm.zig passes `true` for the
// is_static parameter to execute_frame, which should enable write protection.
// However, the storage write protection check in handlers_storage.zig's sstore
// function seems to not be properly enforcing this restriction.
//
// Expected behavior:
// - When a STATICCALL executes code that attempts SSTORE
// - The SSTORE operation should fail with WriteProtection error
// - The entire STATICCALL should return success=false
test "STATICCALL should fail when attempting state modifications" {
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
    
    // Create two addresses: caller and target
    const caller_addr = primitives.Address{ .bytes = [_]u8{0x07} ** 20 };
    const target_addr = primitives.Address{ .bytes = [_]u8{0x08} ** 20 };
    
    // Set up initial state
    try db.set_account(caller_addr.bytes, evm.Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });
    try db.set_account(target_addr.bytes, evm.Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Target's code that attempts to write to storage:
    // PUSH1 0xDD PUSH1 0x00 SSTORE
    // This attempts to store value 0xDD at storage slot 0
    const target_code_with_sstore = [_]u8{ 0x60, 0xDD, 0x60, 0x00, 0x55 };
    const code_hash = try db.set_code(&target_code_with_sstore);
    
    // Update the target account with the code hash
    try db.set_account(target_addr.bytes, evm.Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Execute STATICCALL from caller to target
    const call_params = evm.Evm(.{}).CallParams{
        .staticcall = .{
            .caller = caller_addr,
            .to = target_addr,
            .input = &[_]u8{},
            .gas = 100_000,
        },
    };
    
    const result = vm.call(call_params);
    
    // CRITICAL TEST: The call should FAIL because SSTORE is not allowed in static context
    try testing.expect(!result.success);
    
    // Verify that storage was NOT modified
    const storage_value = try db.get_storage(target_addr.bytes, 0);
    try testing.expectEqual(@as(u256, 0), storage_value);
    
    // This test currently FAILS because the STATICCALL succeeds when it should fail.
    // The issue appears to be that the write protection check in the SSTORE handler
    // is not properly detecting that we're in a static context, or the error is not
    // being properly propagated to cause the STATICCALL to fail.
}

// Additional test: STATICCALL should succeed for read-only operations
test "STATICCALL should succeed for read-only operations" {
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
    
    const caller_addr = primitives.Address{ .bytes = [_]u8{0x09} ** 20 };
    const target_addr = primitives.Address{ .bytes = [_]u8{0x0A} ** 20 };
    
    try db.set_account(caller_addr.bytes, evm.Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });
    try db.set_account(target_addr.bytes, evm.Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Set some storage value to read
    try db.set_storage(target_addr.bytes, 0, 0xBEEF);
    
    // Target's code that only reads storage (no writes):
    // PUSH1 0x00 SLOAD PUSH1 0x00 MSTORE PUSH1 0x20 PUSH1 0x00 RETURN
    // This loads storage slot 0, stores it in memory, and returns it
    const read_only_code = [_]u8{ 
        0x60, 0x00,       // PUSH1 0x00
        0x54,             // SLOAD
        0x60, 0x00,       // PUSH1 0x00
        0x52,             // MSTORE
        0x60, 0x20,       // PUSH1 0x20
        0x60, 0x00,       // PUSH1 0x00
        0xF3,             // RETURN
    };
    const read_code_hash = try db.set_code(&read_only_code);
    
    // Update the target account with the code hash
    try db.set_account(target_addr.bytes, evm.Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = read_code_hash,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Execute STATICCALL
    const call_params = evm.Evm(.{}).CallParams{
        .staticcall = .{
            .caller = caller_addr,
            .to = target_addr,
            .input = &[_]u8{},
            .gas = 100_000,
        },
    };
    
    const result = vm.call(call_params);
    
    // This should succeed because it's read-only
    try testing.expect(result.success);
    
    // Verify the output contains the storage value
    try testing.expect(result.output.len == 32);
    // The output should contain 0xBEEF in the last bytes of the 32-byte word
    var output_value: u256 = 0;
    for (result.output[0..32]) |byte| {
        output_value = (output_value << 8) | byte;
    }
    try testing.expectEqual(@as(u256, 0xBEEF), output_value);
}