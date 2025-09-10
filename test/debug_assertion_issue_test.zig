const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const Address = primitives.Address;
const root = @import("root");
const Evm = root.Evm;
const Database = root.Database;
const Account = root.Account;

test "CALL stack underflow should return error instead of crashing with debug assertion" {
    const allocator = testing.allocator;
    
    // Create EVM instance
    var db = Database.init(allocator);
    defer db.deinit();
    
    var evm = try Evm.init(
        allocator,
        &db,
        .{ .number = 1, .timestamp = 1, .gas_limit = 1000000, .coinbase = Address.zero(), .base_fee = 0, .chain_id = 1, .difficulty = 0, .prev_randao = [_]u8{0} ** 32 },
        .{ .gas_limit = 1000000, .coinbase = Address.zero(), .chain_id = 1, .blob_versioned_hashes = &.{} },
        0,
        Address.zero(),
        .DEFAULT,
    );
    defer evm.deinit();
    
    // Contract bytecode that will cause stack underflow in CALL
    // CALL requires 7 stack items but we only provide 1
    const bytecode = [_]u8{
        0x60, 0x00,  // PUSH1 0 (only 1 item, CALL needs 7)
        0xF1,        // CALL (will fail - needs 7 stack items)
    };
    
    // Set code and create account
    const addr_a = Address.from_u256(100);
    const code_hash = try db.set_code(&bytecode);
    var account_a = Account{ 
        .balance = 0, 
        .code_hash = code_hash, 
        .storage_root = [_]u8{0} ** 32, 
        .nonce = 0, 
        .delegated_address = null 
    };
    try db.set_account(addr_a.bytes, account_a);
    
    // Execute call - currently this would crash with debug assertion
    // After fix, it should return an error gracefully
    const result = evm.call(.{ .call = .{
        .caller = Address.zero(),
        .to = addr_a,
        .value = 0,
        .input = &.{},
        .gas = 100000,
    }});
    
    // Should fail gracefully (not crash)
    try testing.expect(!result.success);
    
    // Should contain error information after fix
    if (result.error_info) |error_info| {
        // Check that error message contains "Stack" or "underflow"
        const has_stack_error = std.mem.indexOf(u8, error_info, "Stack") != null or
                               std.mem.indexOf(u8, error_info, "underflow") != null;
        try testing.expect(has_stack_error);
    }
    
    // Should consume minimal gas (error occurred early)
    try testing.expect(result.gas_left < 100000);
}

test "POP stack underflow should return error instead of crashing" {
    const allocator = testing.allocator;
    
    // Create EVM instance
    var db = Database.init(allocator);
    defer db.deinit();
    
    var evm = try Evm.init(
        allocator,
        &db,
        .{ .number = 1, .timestamp = 1, .gas_limit = 1000000, .coinbase = Address.zero(), .base_fee = 0, .chain_id = 1, .difficulty = 0, .prev_randao = [_]u8{0} ** 32 },
        .{ .gas_limit = 1000000, .coinbase = Address.zero(), .chain_id = 1, .blob_versioned_hashes = &.{} },
        0,
        Address.zero(),
        .DEFAULT,
    );
    defer evm.deinit();
    
    // Contract bytecode that will cause stack underflow with POP
    const bytecode = [_]u8{
        0x50,  // POP (stack is empty - should fail)
        0x00,  // STOP
    };
    
    // Set code and create account
    const addr_a = Address.from_u256(101);
    const code_hash = try db.set_code(&bytecode);
    var account_a = Account{ 
        .balance = 0, 
        .code_hash = code_hash, 
        .storage_root = [_]u8{0} ** 32, 
        .nonce = 0, 
        .delegated_address = null 
    };
    try db.set_account(addr_a.bytes, account_a);
    
    // Execute call - should return error instead of crash
    const result = evm.call(.{ .call = .{
        .caller = Address.zero(),
        .to = addr_a,
        .value = 0,
        .input = &.{},
        .gas = 100000,
    }});
    
    // Should fail gracefully
    try testing.expect(!result.success);
    
    // After fix, should have error information
    if (result.error_info) |error_info| {
        const has_stack_error = std.mem.indexOf(u8, error_info, "Stack") != null or
                               std.mem.indexOf(u8, error_info, "underflow") != null;
        try testing.expect(has_stack_error);
    }
}

test "Stack overflow on PUSH should return error instead of crashing" {
    const allocator = testing.allocator;
    
    // Create EVM instance
    var db = Database.init(allocator);
    defer db.deinit();
    
    var evm = try Evm.init(
        allocator,
        &db,
        .{ .number = 1, .timestamp = 1, .gas_limit = 10000000, .coinbase = Address.zero(), .base_fee = 0, .chain_id = 1, .difficulty = 0, .prev_randao = [_]u8{0} ** 32 },
        .{ .gas_limit = 10000000, .coinbase = Address.zero(), .chain_id = 1, .blob_versioned_hashes = &.{} },
        0,
        Address.zero(),
        .DEFAULT,
    );
    defer evm.deinit();
    
    // Contract bytecode that will cause stack overflow
    // The EVM stack has a maximum depth (typically 1024)
    // Create bytecode that pushes more than the maximum
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Push 1025 values to overflow the stack (max is typically 1024)
    for (0..1025) |_| {
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(0x01); // value 1
    }
    try bytecode.append(0x00); // STOP
    
    // Set code and create account
    const addr_a = Address.from_u256(102);
    const code_hash = try db.set_code(bytecode.items);
    var account_a = Account{ 
        .balance = 0, 
        .code_hash = code_hash, 
        .storage_root = [_]u8{0} ** 32, 
        .nonce = 0, 
        .delegated_address = null 
    };
    try db.set_account(addr_a.bytes, account_a);
    
    // Execute call - should return error instead of crash
    const result = evm.call(.{ .call = .{
        .caller = Address.zero(),
        .to = addr_a,
        .value = 0,
        .input = &.{},
        .gas = 10000000,
    }});
    
    // Should fail gracefully
    try testing.expect(!result.success);
    
    // After fix, should have error information
    if (result.error_info) |error_info| {
        const has_stack_error = std.mem.indexOf(u8, error_info, "Stack") != null or
                               std.mem.indexOf(u8, error_info, "overflow") != null;
        try testing.expect(has_stack_error);
    }
}