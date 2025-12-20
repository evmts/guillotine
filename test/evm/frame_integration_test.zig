//! Integration tests for Frame operations using real EVM components
//! instead of MockHost.

const std = @import("std");
const Evm = @import("evm").DefaultEvm;
const MemoryDatabase = @import("evm").MemoryDatabase;
const Address = @import("voltaire").Address.Address;
const primitives = @import("voltaire");
const CallParams = @import("call_params.zig").CallParams;
const BlockInfo = @import("evm").BlockInfo;
const TransactionContext = @import("evm").TransactionContext;
const Hardfork = @import("evm").Hardfork;

// Helper to convert number to Address
fn to_address(value: u256) Address {
    var addr: Address = [_]u8{0} ** 20;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        addr[19 - i] = @truncate(value >> @intCast(i * 8));
    }
    return addr;
}

/// Helper to create a configured EVM instance for testing
fn createTestEvm(allocator: std.mem.Allocator) !struct { evm: *Evm, memory_db: *MemoryDatabase } {
    const memory_db = try allocator.create(MemoryDatabase);
    memory_db.* = MemoryDatabase.init(allocator);
    const db_interface = memory_db.to_database_interface();
    
    const block_info = BlockInfo.init();
    const tx_context = TransactionContext{
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    const gas_price = 0;
    const origin = primitives.ZERO_ADDRESS;
    const hardfork = Hardfork.CANCUN;
    
    const evm = try allocator.create(Evm);
    evm.* = try Evm.init(allocator, db_interface, block_info, tx_context, gas_price, origin, hardfork);
    return .{ .evm = evm, .memory_db = memory_db };
}

test "EVM CALL operation - integration" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    const ctx = try createTestEvm(allocator);
    var evm = ctx.evm;
    var memory_db = ctx.memory_db;
    defer {
        evm.deinit();
        allocator.destroy(evm);
        memory_db.deinit();
        allocator.destroy(memory_db);
    }
    
    // Deploy a simple contract that returns success
    const target_bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE (store 1 at memory offset 0)
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN (return 32 bytes from offset 0)
    };
    
    const target_address = to_address(0x2000);
    const code_hash = try evm.database.set_code(&target_bytecode);
    var account = @import("evm").Account.zero();
    account.code_hash = code_hash;
    account.balance = 1000; // Give it some balance
    try evm.database.set_account(target_address, account);
    
    // Top-level CALL via EVM
    const caller_address = to_address(0x1000);
    const params = @import("call_params.zig").CallParams{ .call = .{
        .caller = caller_address,
        .to = target_address,
        .value = 0,
        .input = &.{},
        .gas = 100000,
    } };
    const call_result1 = try evm.call(params);
    try std.testing.expect(call_result1.success);
    try std.testing.expectEqual(@as(usize, 32), call_result1.output.len);
    try std.testing.expectEqual(@as(u8, 1), call_result1.output[31]);
}

test "EVM CALL with value transfer - integration" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    const ctx2 = try createTestEvm(allocator);
    var evm = ctx2.evm;
    var memory_db = ctx2.memory_db;
    defer {
        evm.deinit();
        allocator.destroy(evm);
        memory_db.deinit();
        allocator.destroy(memory_db);
    }
    
    // Set up accounts with balances
    const caller_address = to_address(0x1000);
    const target_address = to_address(0x2000);
    
    var caller_account = @import("evm").Account.zero();
    caller_account.balance = 10000; // Caller has 10000 wei
    try evm.database.set_account(caller_address, caller_account);
    
    var target_account = @import("evm").Account.zero();
    target_account.balance = 500; // Target starts with 500 wei
    try evm.database.set_account(target_address, target_account);
    
    // Direct CALL via EVM with value
    const params = @import("call_params.zig").CallParams{ .call = .{
        .caller = caller_address,
        .to = target_address,
        .value = 1000,
        .input = &.{},
        .gas = 100000,
    } };
    const result_call = try evm.call(params);
    try std.testing.expect(result_call.success);
    
    // Verify balances were updated
    const caller_after = try evm.database.get_account(caller_address);
    const target_after = try evm.database.get_account(target_address);
    
    try std.testing.expectEqual(@as(u256, 9000), caller_after.?.balance);  // 10000 - 1000
    try std.testing.expectEqual(@as(u256, 1500), target_after.?.balance);  // 500 + 1000
}

test "Frame DELEGATECALL preserves context - real integration test" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    const ctx3 = try createTestEvm(allocator);
    var evm = ctx3.evm;
    var memory_db = ctx3.memory_db;
    defer {
        evm.deinit();
        allocator.destroy(evm);
        memory_db.deinit();
        allocator.destroy(memory_db);
    }
    
    // Deploy a contract that reads CALLER and VALUE and returns their sum
    const target_bytecode = [_]u8{
        0x33,       // CALLER
        0x34,       // CALLVALUE
        0x01,       // ADD (combine them)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    const original_caller = to_address(0x1111);
    const target_address = to_address(0x3333);
    
    const code_hash = try evm.database.set_code(&target_bytecode);
    var account = @import("evm").Account.zero();
    account.code_hash = code_hash;
    try evm.database.set_account(target_address, account);
    
    // Execute top-level DELEGATECALL (preserves caller, value is 0 at top-level)
    const params = @import("call_params.zig").CallParams{ .delegatecall = .{
        .caller = original_caller,
        .to = target_address,
        .input = &.{},
        .gas = 100000,
    } };
    const call_result2 = try evm.call(params);
    try std.testing.expect(call_result2.success);
    try std.testing.expectEqual(@as(usize, 32), call_result2.output.len);
    const returned_value = std.mem.readInt(u256, call_result2.output[0..32], .big);
    // At top-level: expected = original_caller + 0
    const expected = to_u256(original_caller) + 0;
    try std.testing.expectEqual(expected, returned_value);
}

test "EVM STATICCALL prevents state changes - integration" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    const ctx4 = try createTestEvm(allocator);
    var evm = ctx4.evm;
    var memory_db = ctx4.memory_db;
    defer {
        evm.deinit();
        allocator.destroy(evm);
        memory_db.deinit();
        allocator.destroy(memory_db);
    }
    
    // Deploy a contract that tries to modify storage
    const target_bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE (try to store 0x42 at slot 0) - should fail in static context
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    const target_address = to_address(0x4000);
    const code_hash = try evm.database.set_code(&target_bytecode);
    var account = @import("evm").Account.zero();
    account.code_hash = code_hash;
    try evm.database.set_account(target_address, account);
    
    // STATICCALL through EVM; attempt to SSTORE must fail
    const sc_params = @import("call_params.zig").CallParams{ .staticcall = .{
        .caller = to_address(0xABCD),
        .to = target_address,
        .input = &.{},
        .gas = 100000,
    } };
    const sc_result = try evm.call(sc_params);
    try std.testing.expect(!sc_result.success);
    // Verify storage was not modified
    const storage_value = try evm.database.get_storage(target_address, 0);
    try std.testing.expectEqual(@as(u256, 0), storage_value);
}

test "Frame CREATE operation - real integration test" {
    const allocator = std.testing.allocator;
    
    // Create real EVM instance
    const result = try createTestEvm(allocator);
    var evm = result.evm;
    var memory_db = result.memory_db;
    defer {
        evm.deinit();
        allocator.destroy(evm);
        memory_db.deinit();
        allocator.destroy(memory_db);
    }
    
    // Set up creator account with balance
    const creator_address = to_address(0x5000);
    var creator_account = @import("evm").Account.zero();
    creator_account.balance = 10000;
    try evm.database.set_account(creator_address, creator_account);
    
    // Prepare init code that deploys a simple contract
    const init_code = [_]u8{
        // Constructor: return a simple contract that stores 42
        0x60, 0x0A, // PUSH1 10 (size of runtime code)
        0x60, 0x0C, // PUSH1 12 (offset of runtime code)
        0x60, 0x00, // PUSH1 0 (destination in memory)
        0x39,       // CODECOPY
        0x60, 0x0A, // PUSH1 10 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xF3,       // RETURN
        // Runtime code (10 bytes):
        0x60, 0x2A, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    // CREATE via EVM
    const create_params = @import("call_params.zig").CallParams{ .create = .{
        .caller = creator_address,
        .value = 1000,
        .init_code = &init_code,
        .gas = 200000,
    } };
    const create_result = try evm.call(create_params);
    try std.testing.expect(create_result.success);
    // Output contains created address bytes
    try std.testing.expectEqual(@as(usize, 20), create_result.output.len);
    var created_address: Address = undefined;
    @memcpy(&created_address, create_result.output[0..20]);
    const created_account = try evm.database.get_account(created_address);
    
    try std.testing.expect(created_account != null);
    try std.testing.expectEqual(@as(u256, 1000), created_account.?.balance); // Should have the transferred value
    
    // Verify creator's balance was reduced
    const creator_after = try evm.database.get_account(creator_address);
    try std.testing.expect(creator_after.?.balance < 10000); // Balance reduced by value + gas
}

// Helper to convert u256 to Address
fn from_u256(value: u256) Address {
    var addr: Address = [_]u8{0} ** 20;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        addr[19 - i] = @truncate(value >> @intCast(i * 8));
    }
    return addr;
}

// Helper to convert Address to u256
fn to_u256(addr: Address) u256 {
    var result: u256 = 0;
    for (addr, 0..) |byte, i| {
        result |= @as(u256, byte) << @intCast((19 - i) * 8);
    }
    return result;
}
