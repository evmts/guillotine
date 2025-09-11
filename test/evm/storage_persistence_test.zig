const std = @import("std");
const testing = std.testing;
const evm_mod = @import("evm");
const Database = evm_mod.Database;
const Account = evm_mod.Account;
const DefaultEvm = evm_mod.DefaultEvm;
const primitives = @import("primitives");
const Address = primitives.Address.Address;

// This test demonstrates a critical bug in storage persistence that occurs when
// the HashMap grows during EVM execution.
//
// THE BUG:
// Frame receives a copy of the Database struct (database.*). While HashMap's data
// is shared via shallow copy, the HashMap metadata (capacity, count) is separate.
// When SSTORE operations trigger HashMap growth, Frame allocates new memory and
// updates its metadata. Without synchronizing back, the original Database has
// stale pointers to FREED memory, causing segfaults.
//
// THE FIX (in evm.zig):
// After Frame execution, synchronize HashMap structures back to the original Database:
//   self.database.storage = frame.database.storage;
//   self.database.accounts = frame.database.accounts;
//   self.database.transient_storage = frame.database.transient_storage;
//
// WITHOUT FIX: Segmentation fault when accessing storage after HashMap growth
// WITH FIX: Storage correctly persisted and accessible

test "Storage persistence bug - HashMap growth causes segfault without fix" {
    const allocator = testing.allocator;
    
    // Start with a fresh database
    var db = Database.init(allocator);
    defer db.deinit();
    
    // Pre-fill storage to get close to HashMap capacity threshold
    // This makes it easier to trigger growth during contract execution
    var i: u256 = 0;
    while (i < 50) : (i += 1) {
        const addr_bytes = [_]u8{@intCast(i % 10)} ++ [_]u8{0} ** 19;
        try db.set_storage(addr_bytes, i / 10, i * 1000);
    }
    
    // Create EVM
    var evm = try DefaultEvm.init(
        allocator,
        &db,
        .{
            .number = 1,
            .timestamp = 1,
            .gas_limit = 10000000,
            .coinbase = Address.ZERO_ADDRESS,
            .base_fee = 0,
            .difficulty = 0,
            .prev_randao = [_]u8{0} ** 32,
            .chain_id = 1,
            .blob_base_fee = 0,
            .blob_versioned_hashes = &.{},
        },
        .{
            .gas_limit = 10000000,
            .coinbase = Address.ZERO_ADDRESS,
            .chain_id = 1,
            .blob_versioned_hashes = &.{},
            .blob_base_fee = 0,
        },
        0,
        Address.ZERO_ADDRESS,
        .CANCUN,
    );
    defer evm.deinit();
    
    const test_addr: Address = .{ .bytes = [_]u8{0x99} ++ [_]u8{0} ** 19 };
    
    // Create bytecode that stores many values to trigger HashMap growth
    var bytecode = try std.ArrayList(u8).initCapacity(allocator, 512);
    defer bytecode.deinit(allocator);
    
    // Store 50 values - combined with pre-filled storage, this triggers HashMap growth
    var slot: u8 = 0;
    while (slot < 50) : (slot += 1) {
        // PUSH1 value
        try bytecode.append(allocator, 0x60);
        try bytecode.append(allocator, slot + 100);
        // PUSH1 slot
        try bytecode.append(allocator, 0x60);
        try bytecode.append(allocator, slot);
        // SSTORE
        try bytecode.append(allocator, 0x55);
    }
    // STOP
    try bytecode.append(allocator, 0x00);
    
    const code_hash = try db.set_code(bytecode.items);
    const account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(test_addr.bytes, account);
    
    // Execute the contract - this triggers HashMap growth
    var result = evm.call(.{
        .call = .{
            .caller = Address.ZERO_ADDRESS,
            .to = test_addr,
            .value = 0,
            .input = &.{},
            .gas = 10000000,
        },
    });
    defer result.deinit(allocator);
    
    try testing.expect(result.success);
    
    // Now verify storage was persisted by reading it through another EVM call
    // WITHOUT FIX: This would segfault when trying to access the corrupted HashMap
    // WITH FIX: This correctly returns the stored value
    const check_bytecode = [_]u8{
        // Load slot 25 (should be 125)
        0x60, 25,    // PUSH1 25
        0x54,        // SLOAD
        
        // Return it
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 32 (return size)
        0x60, 0x00,  // PUSH1 0 (memory offset)
        0xF3,        // RETURN
    };
    
    const check_code_hash = try db.set_code(&check_bytecode);
    var check_account = (try db.get_account(test_addr.bytes)).?;
    check_account.code_hash = check_code_hash;
    try db.set_account(test_addr.bytes, check_account);
    
    var check_result = evm.call(.{
        .call = .{
            .caller = Address.ZERO_ADDRESS,
            .to = test_addr,
            .value = 0,
            .input = &.{},
            .gas = 50000,
        },
    });
    defer check_result.deinit(allocator);
    
    try testing.expect(check_result.success);
    
    if (check_result.output.len >= 32) {
        var value: u256 = 0;
        var j: usize = 0;
        while (j < 32) : (j += 1) {
            value = (value << 8) | check_result.output[j];
        }
        
        // Expected: slot 25 should have value 125 (25 + 100)
        try testing.expectEqual(@as(u256, 125), value);
    } else {
        try testing.expect(false);
    }
}