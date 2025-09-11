const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const testing = std.testing;

const Evm = evm.Evm;
const Database = evm.Database;
const BlockInfo = evm.BlockInfo;
const TransactionContext = evm.TransactionContext;

// This is a simple test to verify the EIP-214 static context implementation
// It tests that the EVM properly tracks static context and the handlers respect it
test "EIP-214: STATICCALL static context tracking" {
    // Create test database
    var db = Database.init(testing.allocator);
    defer db.deinit();
    
    // Create EVM with test configuration
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 20_000_000,
        .timestamp = 1_800_000_000,
        .difficulty = 0,
        .gas_limit = 1_000_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 7,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 1000000000,
        .blob_versioned_hashes = &.{},
    };

    const tx_context = TransactionContext{
        .gas_limit = 1_000_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm_instance = try Evm(.{}).init(
        testing.allocator,
        &db,
        block_info,
        tx_context,
        0,
        primitives.ZERO_ADDRESS,
        .CANCUN
    );
    defer evm_instance.deinit();
    
    // Test 1: Normal context should return false for static
    try testing.expect(!evm_instance.is_static_context());
    
    // Test 2: Simulate executing a frame with is_static = false
    const caller = primitives.Address.ZERO_ADDRESS;
    const value: u256 = 0;
    
    // Set up a normal (non-static) call in the call stack
    evm_instance.depth = 1;
    evm_instance.call_stack[0] = .{
        .caller = caller,
        .value = value,
        .is_static = false
    };
    
    try testing.expect(!evm_instance.is_static_context());
    
    // Test 3: Simulate executing a frame with is_static = true (STATICCALL)
    evm_instance.call_stack[0] = .{
        .caller = caller, 
        .value = value,
        .is_static = true  // This simulates a STATICCALL
    };
    
    try testing.expect(evm_instance.is_static_context());
    
    // Test 4: Test nested calls - static context should be preserved per level
    evm_instance.depth = 2;
    evm_instance.call_stack[0] = .{
        .caller = caller,
        .value = value,
        .is_static = false  // First level: normal call
    };
    evm_instance.call_stack[1] = .{
        .caller = caller,
        .value = value,
        .is_static = true   // Second level: static call
    };
    
    try testing.expect(evm_instance.is_static_context()); // Should return true (current level is static)
    
    // Test 5: Pop back to non-static level
    evm_instance.depth = 1;
    try testing.expect(!evm_instance.is_static_context()); // Should return false (back to non-static level)
}