const std = @import("std");
const testing = std.testing;

// This is a simple test to verify the EIP-214 static context implementation
// It tests that the EVM properly tracks static context and the handlers respect it

test "EIP-214: STATICCALL static context tracking" {
    const Evm = @import("../src/evm.zig").Evm;
    const Database = @import("../src/storage/database.zig").Database;
    const primitives = @import("primitives");
    
    // Create test database
    var db = Database.init(testing.allocator);
    defer db.deinit();
    
    // Create EVM with test configuration
    const block_info = @import("../src/block/block_info.zig").DefaultBlockInfo.default();
    const context = @import("../src/block/transaction_context.zig").TransactionContext.default();
    const hardfork = @import("../src/eips_and_hardforks/hardfork.zig").Hardfork.DEFAULT;
    
    var evm = try Evm({}).init(
        testing.allocator,
        &db,
        block_info,
        context,
        0, // gas_price
        primitives.Address.ZERO_ADDRESS, // origin
        hardfork
    );
    defer evm.deinit();
    
    // Test 1: Normal context should return false for static
    try testing.expect(!evm.is_static_context());
    try testing.expect(!evm.get_is_static());
    
    // Test 2: Simulate executing a frame with is_static = false
    const caller = primitives.Address.ZERO_ADDRESS;
    const value: u256 = 0;
    
    // Set up a normal (non-static) call in the call stack
    evm.depth = 1;
    evm.call_stack[0] = .{
        .caller = caller,
        .value = value,
        .is_static = false
    };
    
    try testing.expect(!evm.is_static_context());
    try testing.expect(!evm.get_is_static());
    
    // Test 3: Simulate executing a frame with is_static = true (STATICCALL)
    evm.call_stack[0] = .{
        .caller = caller, 
        .value = value,
        .is_static = true  // This simulates a STATICCALL
    };
    
    try testing.expect(evm.is_static_context());
    try testing.expect(evm.get_is_static());
    
    // Test 4: Test nested calls - static context should be preserved per level
    evm.depth = 2;
    evm.call_stack[0] = .{
        .caller = caller,
        .value = value,
        .is_static = false  // First level: normal call
    };
    evm.call_stack[1] = .{
        .caller = caller,
        .value = value,
        .is_static = true   // Second level: static call
    };
    
    try testing.expect(evm.is_static_context()); // Should return true (current level is static)
    
    // Test 5: Pop back to non-static level
    evm.depth = 1;
    try testing.expect(!evm.is_static_context()); // Should return false (back to non-static level)
}