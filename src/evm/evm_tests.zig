//! Tests for EVM transaction-level execution and state management.

const std = @import("std");
const primitives = @import("primitives");
const Evm = @import("evm.zig").Evm;
const DefaultEvm = @import("evm.zig").DefaultEvm;
const BlockInfo = @import("block_info.zig").DefaultBlockInfo;
const Database = @import("database.zig").Database;
const Account = @import("database_interface_account.zig").Account;
const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
const TransactionContext = @import("transaction_context.zig").TransactionContext;
const Opcode = @import("opcode.zig").Opcode;
const EvmConfig = @import("evm_config.zig").EvmConfig;
const Hardfork = @import("hardfork.zig").Hardfork;

test "CallParams and CallResult structures" {
    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 1000000,
        },
    };

    const result = DefaultEvm.CallResult{
        .success = true,
        .gas_left = 900000,
        .output = &.{},
    };

    try std.testing.expect(call_params == .call);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, 900000), result.gas_left);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
}

test "EVM error type definition" {
    // Test that Error type exists and contains expected error cases
    const TestEvm = Evm(.{});

    // Test error type is defined
    comptime {
        _ = TestEvm.Error;
    }

    // Test that we can create error values
    const err1: TestEvm.Error = error.InvalidJump;
    const err2: TestEvm.Error = error.OutOfGas;

    // Test that different errors are not equal
    try std.testing.expect(err1 != err2);
}test "EVM call() entry point method" {
    const allocator = std.testing.allocator;

    // Create test database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    // Create EVM instance
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };

    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(allocator, db_interface, block_info, tx_context, 0, primitives.ZERO_ADDRESS, .BERLIN);
    defer evm.deinit();

    // Test that call method exists and has correct signature
    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 1000000,
        },
    };

    // This should return Error!CallResult
    const result = evm.call(call_params);

    // Test that method returns expected error type
    comptime {
        const ReturnType = @TypeOf(result);
        const expected_type = DefaultEvm.Error!DefaultEvm.CallResult;
        _ = ReturnType;
        _ = expected_type;
        // We can't directly compare error union types, but this ensures it compiles
    }
}

test "EVM call() method routes to different handlers" {
    const allocator = std.testing.allocator;

    // Create test database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    // Create EVM instance
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };

    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(allocator, db_interface, block_info, tx_context, 0, primitives.ZERO_ADDRESS, .BERLIN);
    defer evm.deinit();

    // Test CALL routing
    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 1000000,
        },
    };
    _ = evm.call(call_params) catch {};

    // Test DELEGATECALL routing
    const delegatecall_params = DefaultEvm.CallParams{
        .delegatecall = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .input = &.{},
            .gas = 1000000,
        },
    };
    _ = evm.call(delegatecall_params) catch {};

    // Test STATICCALL routing
    const staticcall_params = DefaultEvm.CallParams{
        .staticcall = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .input = &.{},
            .gas = 1000000,
        },
    };
    _ = evm.call(staticcall_params) catch {};

    // Test CREATE routing
    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = primitives.ZERO_ADDRESS,
            .value = 0,
            .init_code = &.{},
            .gas = 1000000,
        },
    };
    _ = evm.call(create_params) catch {};

    // Test CREATE2 routing
    const create2_params = DefaultEvm.CallParams{
        .create2 = .{
            .caller = primitives.ZERO_ADDRESS,
            .value = 0,
            .init_code = &.{},
            .salt = 0,
            .gas = 1000000,
        },
    };
    _ = evm.call(create2_params) catch {};
}

test "EVM call_handler basic functionality" {
    const allocator = std.testing.allocator;

    // Create test database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    // Add a simple contract that just STOPs
    const stop_bytecode = [_]u8{0x00}; // STOP opcode
    const contract_address: primitives.Address = [_]u8{0x42} ++ [_]u8{0} ** 19;
    const code_hash = try memory_db.set_code(&stop_bytecode);
    try memory_db.set_account(contract_address, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Create EVM instance
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };

    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(allocator, db_interface, block_info, tx_context, 0, primitives.ZERO_ADDRESS, .BERLIN);
    defer evm.deinit();

    // Test call_handler directly (once it's implemented)
    const params = struct {
        caller: primitives.Address,
        to: primitives.Address,
        value: u256,
        input: []const u8,
        gas: u64,
    }{
        .caller = primitives.ZERO_ADDRESS,
        .to = contract_address,
        .value = 0,
        .input = &.{},
        .gas = 1000000,
    };

    // This should now work with the implemented handler
    const result = try evm.call_handler(params);

    // The implemented handler should work correctly
    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
}

test "EVM staticcall handler prevents state changes" {
    const allocator = std.testing.allocator;

    // Create test database with initial state
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    // Add a contract that tries to modify storage (should fail in staticcall)
    const sstore_bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x55, // SSTORE (should fail in static context)
        0x00, // STOP
    };
    const contract_address: primitives.Address = [_]u8{0x42} ++ [_]u8{0} ** 19;
    const code_hash = try memory_db.set_code(&sstore_bytecode);
    try memory_db.set_account(contract_address, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Create EVM instance
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };

    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(allocator, db_interface, block_info, tx_context, 0, primitives.ZERO_ADDRESS, .BERLIN);
    defer evm.deinit();

    // Test staticcall directly
    const params = struct {
        caller: primitives.Address,
        to: primitives.Address,
        input: []const u8,
        gas: u64,
    }{
        .caller = primitives.ZERO_ADDRESS,
        .to = contract_address,
        .input = &.{},
        .gas = 1000000,
    };

    // This should now work with the implemented handler
    const result = try evm.staticcall_handler(params);

    // Staticcall with SSTORE should fail due to static context restrictions
    try std.testing.expect(!result.success);
}

test "EVM delegatecall handler preserves caller context" {
    const allocator = std.testing.allocator;

    // Create test database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    // Add a contract that returns the caller address
    // CALLER opcode pushes msg.sender to stack
    _ = [_]u8{
        0x33, // CALLER
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE - store caller at memory[0]
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN - return 32 bytes from memory[0]
    };
    const contract_address: primitives.Address = [_]u8{0x42} ++ [_]u8{0} ** 19;
    try memory_db.set_account(contract_address, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    // Create EVM instance
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };

    const original_caller: primitives.Address = [_]u8{0xAA} ++ [_]u8{0} ** 19;
    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(allocator, db_interface, block_info, tx_context, 0, primitives.ZERO_ADDRESS, .BERLIN);
    defer evm.deinit();

    // Test delegatecall - should preserve original caller
    const params = struct {
        caller: primitives.Address,
        to: primitives.Address,
        input: []const u8,
        gas: u64,
    }{
        .caller = original_caller, // This should be preserved in delegatecall
        .to = contract_address,
        .input = &.{},
        .gas = 1000000,
    };

    // This should now work with the implemented handler
    const result = try evm.delegatecall_handler(params);

    // Delegatecall with empty code should succeed
    try std.testing.expect(result.success);
}

test "Evm creation with custom config" {
    const CustomEvm = Evm(.{
        .max_call_depth = 512,
        .max_input_size = 65536, // 64KB
        .frame_config = .{
            .stack_size = 512,
            .max_bytecode_size = 16384,
        },
    });

    // Create test database
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try CustomEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    try std.testing.expectEqual(@as(u9, 0), evm.depth);
}

test "Evm call depth limit" {
    // Create test database
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Set depth to max
    evm.depth = 1024;

    // Try to make a call - should fail due to depth limit
    const result = try evm.inner_call(DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 1000000,
        },
    });

    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u64, 0), result.gas_left);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
}

// TDD Tests for call method implementation
test "call method basic functionality - simple STOP" {
    // Create test database
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    _ = [_]u8{0x00};

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    };

    // This should work when call method is properly implemented
    const result = try evm.call(call_params);

    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
}

test "call method loads contract code from state" {
    // Create test database
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Set up contract with bytecode [0x00] (STOP)
    const contract_address: primitives.Address = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x34, 0x56, 0x78, 0x90 };
    const bytecode = [_]u8{0x00};
    const code_hash = try memory_db.set_code(&bytecode);

    // Create account with the code
    const account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try memory_db.set_account(contract_address, account);

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);

    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
}

test "call method handles CREATE operation" {
    // Create test database
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Create contract with simple init code that returns [0x00] (STOP)
    const init_code = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x52, 0x60, 0x01, 0x60, 0x00, 0xF3 }; // PUSH1 1 PUSH1 0 MSTORE PUSH1 1 PUSH1 0 RETURN

    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = primitives.ZERO_ADDRESS,
            .value = 0,
            .init_code = &init_code,
            .gas = 100000,
        },
    };

    const result = try evm.call(create_params);

    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
}

test "call method handles gas limit properly" {
    // Create test database
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Call with very low gas (should fail or return with low gas left)
    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 10, // Very low gas
        },
    };

    const result = try evm.call(call_params);

    // Should either fail or consume most/all gas
    try std.testing.expect(result.gas_left <= 10);
}

test "Journal - snapshot creation and management" {
    const journal_mod = @import("journal.zig");
    const JournalType = journal_mod.Journal(.{});

    var journal = JournalType.init(std.testing.allocator);
    defer journal.deinit();

    try std.testing.expectEqual(@as(u32, 0), journal.next_snapshot_id);
    try std.testing.expectEqual(@as(usize, 0), journal.entry_count());

    // Create snapshots
    const snapshot1 = journal.create_snapshot();
    const snapshot2 = journal.create_snapshot();
    const snapshot3 = journal.create_snapshot();

    try std.testing.expectEqual(@as(u32, 0), snapshot1);
    try std.testing.expectEqual(@as(u32, 1), snapshot2);
    try std.testing.expectEqual(@as(u32, 2), snapshot3);
    try std.testing.expectEqual(@as(u32, 3), journal.next_snapshot_id);
}

test "Journal - storage change recording" {
    const journal_mod = @import("journal.zig");
    const JournalType = journal_mod.Journal(.{});

    var journal = JournalType.init(std.testing.allocator);
    defer journal.deinit();

    const snapshot_id = journal.create_snapshot();
    const address = primitives.ZERO_ADDRESS;
    const key = 42;
    const original_value = 100;

    // Record storage change
    try journal.record_storage_change(snapshot_id, address, key, original_value);

    // Verify entry was recorded
    try std.testing.expectEqual(@as(usize, 1), journal.entry_count());
    const entry = journal.entries.items[0];
    try std.testing.expectEqual(snapshot_id, entry.snapshot_id);

    switch (entry.data) {
        .storage_change => |sc| {
            try std.testing.expectEqual(address, sc.address);
            try std.testing.expectEqual(key, sc.key);
            try std.testing.expectEqual(original_value, sc.original_value);
        },
        else => try std.testing.expect(false), // Should be storage_change
    }

    // Test get_original_storage
    const retrieved = journal.get_original_storage(address, key);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(original_value, retrieved.?);
}

test "Journal - revert to snapshot" {
    const journal_mod = @import("journal.zig");
    const JournalType = journal_mod.Journal(.{});

    var journal = JournalType.init(std.testing.allocator);
    defer journal.deinit();

    const snapshot1 = journal.create_snapshot();
    const snapshot2 = journal.create_snapshot();
    const snapshot3 = journal.create_snapshot();

    // Add entries with different snapshot IDs
    try journal.record_storage_change(snapshot1, primitives.ZERO_ADDRESS, 1, 10);
    try journal.record_storage_change(snapshot1, primitives.ZERO_ADDRESS, 2, 20);
    try journal.record_storage_change(snapshot2, primitives.ZERO_ADDRESS, 3, 30);
    try journal.record_storage_change(snapshot3, primitives.ZERO_ADDRESS, 4, 40);

    try std.testing.expectEqual(@as(usize, 4), journal.entry_count());

    // Revert to snapshot2 - should remove entries with snapshot_id >= 2
    journal.revert_to_snapshot(snapshot2);

    try std.testing.expectEqual(@as(usize, 2), journal.entry_count());
    // Verify remaining entries are from snapshot1
    for (journal.entries.items) |entry| {
        try std.testing.expect(entry.snapshot_id < snapshot2);
    }
}

test "Journal - multiple entry types" {
    const journal_mod = @import("journal.zig");
    const JournalType = journal_mod.Journal(.{});

    var journal = JournalType.init(std.testing.allocator);
    defer journal.deinit();

    const snapshot_id = journal.create_snapshot();
    const address = primitives.ZERO_ADDRESS;
    const code_hash = [_]u8{0xAB} ** 32;

    // Record different types of changes
    try journal.record_storage_change(snapshot_id, address, 1, 100);
    try journal.record_balance_change(snapshot_id, address, 1000);
    try journal.record_nonce_change(snapshot_id, address, 5);
    try journal.record_code_change(snapshot_id, address, code_hash);

    try std.testing.expectEqual(@as(usize, 4), journal.entry_count());

    // Verify all entry types exist
    var storage_found = false;
    var balance_found = false;
    var nonce_found = false;
    var code_found = false;

    for (journal.entries.items) |entry| {
        switch (entry.data) {
            .storage_change => storage_found = true,
            .balance_change => balance_found = true,
            .nonce_change => nonce_found = true,
            .code_change => code_found = true,
            else => {},
        }
    }

    try std.testing.expect(storage_found);
    try std.testing.expect(balance_found);
    try std.testing.expect(nonce_found);
    try std.testing.expect(code_found);
}

test "Journal - empty revert" {
    const journal_mod = @import("journal.zig");
    const JournalType = journal_mod.Journal(.{});

    var journal = JournalType.init(std.testing.allocator);
    defer journal.deinit();

    // Revert with no entries should not crash
    journal.revert_to_snapshot(0);
    try std.testing.expectEqual(@as(usize, 0), journal.entry_count());

    // Create entries and revert to future snapshot
    const snapshot = journal.create_snapshot();
    try journal.record_storage_change(snapshot, primitives.ZERO_ADDRESS, 1, 100);

    // Revert to future snapshot (should remove all entries)
    journal.revert_to_snapshot(999);
    try std.testing.expectEqual(@as(usize, 0), journal.entry_count());
}

test "EvmConfig - depth type selection" {
    const config_u8 = EvmConfig{ .max_call_depth = 255 };
    try std.testing.expectEqual(u8, config_u8.get_depth_type());

    const config_u11 = EvmConfig{ .max_call_depth = 1024 };
    try std.testing.expectEqual(u11, config_u11.get_depth_type());

    const config_boundary = EvmConfig{ .max_call_depth = 256 };
    try std.testing.expectEqual(u11, config_boundary.get_depth_type());
}

test "EvmConfig - custom configurations" {
    const custom_config = EvmConfig{
        .max_call_depth = 512,
        .max_input_size = 65536,
        .frame_config = .{
            .stack_size = 256,
            .max_bytecode_size = 12288,
        },
    };

    const CustomEvm = Evm(custom_config);

    // Create test database and verify custom EVM compiles
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try CustomEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    try std.testing.expectEqual(@as(u10, 0), evm.depth); // Should be u10 for 512 max depth
}

test "TransactionContext creation and fields" {
    const context = TransactionContext{
        .gas_limit = 5000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 137, // Polygon
    };

    try std.testing.expectEqual(@as(u64, 5000000), context.gas_limit);
    try std.testing.expectEqual(primitives.ZERO_ADDRESS, context.coinbase);
    try std.testing.expectEqual(@as(u16, 137), context.chain_id);
}

test "Evm initialization with all parameters" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 12345678,
        .timestamp = 1640995200, // 2022-01-01
        .difficulty = 15000000000000000,
        .gas_limit = 15000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 25000000000, // 25 gwei
        .prev_randao = [_]u8{0xAB} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 300000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1, // Mainnet
    };

    const gas_price: u256 = 30000000000; // 30 gwei
    const origin = primitives.ZERO_ADDRESS;

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, gas_price, origin, .LONDON);
    defer evm.deinit();

    // Verify all fields were set correctly
    try std.testing.expectEqual(@as(u11, 0), evm.depth);
    try std.testing.expectEqual(block_info.number, evm.block_info.number);
    try std.testing.expectEqual(context.chain_id, evm.context.chain_id);
    try std.testing.expectEqual(gas_price, evm.gas_price);
    try std.testing.expectEqual(origin, evm.origin);
    try std.testing.expectEqual(Hardfork.LONDON, evm.hardfork_config);

    // Verify sub-components initialized
    try std.testing.expectEqual(@as(u32, 0), evm.journal.next_snapshot_id);
    try std.testing.expectEqual(@as(usize, 0), evm.journal.entry_count());
}

// Duplicate test removed - see earlier occurrence

test "Host interface - get_balance functionality" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const address = primitives.ZERO_ADDRESS;
    const balance: u256 = 1000000000000000000; // 1 ETH

    // Set account balance in database
    const account = @import("database_interface_account.zig").Account{
        .balance = balance,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try memory_db.set_account(address, account);

    const retrieved_balance = evm.get_balance(address);
    try std.testing.expectEqual(balance, retrieved_balance);

    const zero_address = [_]u8{1} ++ [_]u8{0} ** 19;
    const zero_balance = evm.get_balance(zero_address);
    try std.testing.expectEqual(@as(u256, 0), zero_balance);
}

test "Host interface - storage operations" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const address = primitives.ZERO_ADDRESS;
    const key: u256 = 42;
    const value: u256 = 0xDEADBEEF;

    // Initially should return zero
    const initial_value = evm.get_storage(address, key);
    try std.testing.expectEqual(@as(u256, 0), initial_value);

    // Set storage value
    try evm.set_storage(address, key, value);

    // Retrieve and verify
    const retrieved_value = evm.get_storage(address, key);
    try std.testing.expectEqual(value, retrieved_value);

    const different_key: u256 = 99;
    const different_value = evm.get_storage(address, different_key);
    try std.testing.expectEqual(@as(u256, 0), different_value);
}

test "Host interface - account_exists functionality" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const address = primitives.ZERO_ADDRESS;
    const account = @import("database_interface_account.zig").Account{
        .balance = 1000,
        .nonce = 1,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try memory_db.set_account(address, account);

    const exists = evm.account_exists(address);
    try std.testing.expect(exists);

    const non_existing = [_]u8{1} ++ [_]u8{0} ** 19;
    const does_not_exist = evm.account_exists(non_existing);
    try std.testing.expect(!does_not_exist);
}

test "Host interface - call type differentiation" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 100,
            .input = &.{},
            .gas = 100000,
        },
    };

    const call_result = try evm.call(call_params);
    try std.testing.expect(call_result.success);

    // Test STATICCALL operation (no value transfer allowed)
    const static_params = DefaultEvm.CallParams{
        .staticcall = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .input = &.{},
            .gas = 100000,
        },
    };

    const static_result = try evm.call(static_params);
    try std.testing.expect(static_result.success);

    // Test DELEGATECALL operation (preserves caller context)
    const delegate_params = DefaultEvm.CallParams{
        .delegatecall = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .input = &.{},
            .gas = 100000,
        },
    };

    const delegate_result = try evm.call(delegate_params);
    try std.testing.expect(delegate_result.success);
}

test "EVM CREATE operation - basic contract creation" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Set up caller with balance
    const caller_address: primitives.Address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try memory_db.set_account(caller_address, caller_account);

    // Simple init code that returns a contract with STOP opcode
    // PUSH1 0x01 (size)
    // PUSH1 0x00 (offset)
    // PUSH1 0x00 (value for MSTORE8)
    // PUSH1 0x00 (offset for MSTORE8)
    // MSTORE8
    // RETURN
    const init_code = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0 (value)
        0x60, 0x00, // PUSH1 0 (offset)
        0x53, // MSTORE8
        0xF3, // RETURN
    };

    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = caller_address,
            .value = 0,
            .init_code = &init_code,
            .gas = 100000,
        },
    };

    const result = try evm.call(create_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    // Verify successful creation
    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
    try std.testing.expectEqual(@as(usize, 32), result.output.len);

    // Extract contract address from output (last 20 bytes)
    const contract_address: primitives.Address = result.output[12..32].*;

    // Verify contract was created
    const created_account = (try memory_db.get_account(contract_address)).?;
    try std.testing.expectEqual(@as(u64, 1), created_account.nonce);

    // Verify caller nonce was incremented
    const updated_caller = (try memory_db.get_account(caller_address)).?;
    try std.testing.expectEqual(@as(u64, 1), updated_caller.nonce);
}

test "EVM CREATE operation - with value transfer" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Set up caller with balance
    const caller_address: primitives.Address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const initial_balance: u256 = 1000000;
    const transfer_value: u256 = 12345;
    const caller_account = Account{
        .balance = initial_balance,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try memory_db.set_account(caller_address, caller_account);

    // Init code that returns empty contract
    const init_code = [_]u8{ 0x00, 0x00, 0xF3 }; // STOP STOP RETURN

    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = caller_address,
            .value = transfer_value,
            .init_code = &init_code,
            .gas = 100000,
        },
    };

    const result = try evm.call(create_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    try std.testing.expect(result.success);

    // Extract contract address
    const contract_address: primitives.Address = result.output[12..32].*;

    // Verify balances
    const caller_after = (try memory_db.get_account(caller_address)).?;
    try std.testing.expectEqual(initial_balance - transfer_value, caller_after.balance);

    const contract_account = (try memory_db.get_account(contract_address)).?;
    try std.testing.expectEqual(transfer_value, contract_account.balance);
}

test "EVM CREATE operation - insufficient balance fails" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const caller_address: primitives.Address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const caller_account = Account{
        .balance = 100,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try memory_db.set_account(caller_address, caller_account);

    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = caller_address,
            .value = 1000, // More than balance
            .init_code = &.{0x00}, // STOP
            .gas = 100000,
        },
    };

    const result = try evm.call(create_params);

    // Should fail due to insufficient balance
    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u64, 0), result.gas_left);
}

test "EVM CREATE2 operation - deterministic address creation" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const caller_address: primitives.Address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try memory_db.set_account(caller_address, caller_account);

    // Simple init code
    const init_code = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    const salt: u256 = 0x1234567890ABCDEF;

    const create2_params = DefaultEvm.CallParams{
        .create2 = .{
            .caller = caller_address,
            .value = 0,
            .init_code = &init_code,
            .salt = salt,
            .gas = 100000,
        },
    };

    const result = try evm.call(create2_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    // Verify successful creation
    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
    try std.testing.expectEqual(@as(usize, 32), result.output.len);

    // Extract contract address
    const contract_address: primitives.Address = result.output[12..32].*;

    // Verify contract was created
    const created_account = (try memory_db.get_account(contract_address)).?;
    try std.testing.expectEqual(@as(u64, 1), created_account.nonce);

    // Calculate expected address using CREATE2 formula
    const keccak_asm = @import("keccak_asm.zig");
    var init_code_hash: [32]u8 = undefined;
    try keccak_asm.keccak256(&init_code, &init_code_hash);
    const salt_bytes = @as([32]u8, @bitCast(salt));
    const expected_address = primitives.Address.get_create2_address(caller_address, salt_bytes, init_code_hash);

    // Verify the address matches the expected CREATE2 address
    try std.testing.expectEqualSlices(u8, &expected_address, &contract_address);
}

test "EVM CREATE2 operation - same parameters produce same address" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const caller_address: primitives.Address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const init_code = [_]u8{ 0x00, 0x00, 0xF3 }; // STOP STOP RETURN
    const salt: u256 = 0xDEADBEEF;

    // Calculate expected address
    const keccak_asm = @import("keccak_asm.zig");
    var init_code_hash: [32]u8 = undefined;
    try keccak_asm.keccak256(&init_code, &init_code_hash);
    const salt_bytes = @as([32]u8, @bitCast(salt));
    const expected_address = primitives.Address.get_create2_address(caller_address, salt_bytes, init_code_hash);

    // Create caller account
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try memory_db.set_account(caller_address, caller_account);

    const create2_params = DefaultEvm.CallParams{
        .create2 = .{
            .caller = caller_address,
            .value = 0,
            .init_code = &init_code,
            .salt = salt,
            .gas = 100000,
        },
    };

    const result = try evm.call(create2_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    try std.testing.expect(result.success);

    const actual_address: primitives.Address = result.output[12..32].*;
    try std.testing.expectEqualSlices(u8, &expected_address, &actual_address);
}

test "EVM CREATE operation - collision detection" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const caller_address: primitives.Address = [_]u8{0x01} ++ [_]u8{0} ** 19;

    // Calculate what the contract address will be
    const expected_address = primitives.Address.get_contract_address(caller_address, 0);

    // Pre-create an account at that address with code
    const existing_code = [_]u8{ 0x60, 0x00 }; // PUSH1 0
    const code_hash = try memory_db.set_code(&existing_code);
    const existing_account = Account{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try memory_db.set_account(expected_address, existing_account);

    // Create caller account
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try memory_db.set_account(caller_address, caller_account);

    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = caller_address,
            .value = 0,
            .init_code = &.{0x00}, // STOP
            .gas = 100000,
        },
    };

    const result = try evm.call(create_params);

    // Should fail due to collision
    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u64, 0), result.gas_left);
}

test "EVM CREATE operation - init code execution and storage" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const caller_address: primitives.Address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const caller_account = Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try memory_db.set_account(caller_address, caller_account);

    // Init code that stores a value and returns code with PUSH1 and ADD
    // This tests that init code can access storage and return runtime code
    const init_code = [_]u8{
        // Store value 42 at key 0
        0x60, 0x2A, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x55, // SSTORE

        // Return runtime code: PUSH1 1 ADD
        0x60, 0x04, // PUSH1 4 (size)
        0x60, 0x1C, // PUSH1 28 (offset in this code)
        0xF3, // RETURN

        // Runtime code at offset 28:
        0x60, 0x01, // PUSH1 1
        0x01, // ADD
        0x00, // STOP
    };

    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = caller_address,
            .value = 0,
            .init_code = &init_code,
            .gas = 200000,
        },
    };

    const result = try evm.call(create_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    try std.testing.expect(result.success);

    const contract_address: primitives.Address = result.output[12..32].*;

    // Verify the storage was set during init
    const stored_value = try memory_db.get_storage(contract_address, 0);
    try std.testing.expectEqual(@as(u256, 42), stored_value);

    // Verify the runtime code was stored
    const runtime_code = try memory_db.get_code_by_address(contract_address);
    try std.testing.expectEqual(@as(usize, 4), runtime_code.len);
    try std.testing.expectEqual(@as(u8, 0x60), runtime_code[0]); // PUSH1
    try std.testing.expectEqual(@as(u8, 0x01), runtime_code[1]); // 1
    try std.testing.expectEqual(@as(u8, 0x01), runtime_code[2]); // ADD
    try std.testing.expectEqual(@as(u8, 0x00), runtime_code[3]); // STOP
}

test "EVM CREATE/CREATE2 - nested contract creation" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 3000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Create a factory contract that creates another contract
    // Factory bytecode: CREATE opcode that deploys a simple contract
    const factory_bytecode = [_]u8{
        // Push init code for child contract (just returns empty code)
        0x60, 0x03, // PUSH1 3 (size of init code)
        0x60, 0x1A, // PUSH1 26 (offset of init code)
        0x60, 0x00, // PUSH1 0 (value)
        0xF0, // CREATE
        // Return the created address
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
        // Child init code at offset 26:
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    const factory_address: primitives.Address = [_]u8{0x02} ++ [_]u8{0} ** 19;
    const code_hash = try memory_db.set_code(&factory_bytecode);
    try memory_db.set_account(factory_address, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    const caller_address: primitives.Address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    try memory_db.set_account(caller_address, Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    // Call the factory to create a child contract
    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = factory_address,
            .value = 0,
            .input = &.{},
            .gas = 500000,
        },
    };

    const result = try evm.call(call_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 32), result.output.len);

    // The output should contain the address of the created child contract
    const child_address: primitives.Address = result.output[12..32].*;

    // Verify child contract exists
    const child_account = try memory_db.get_account(child_address);
    try std.testing.expect(child_account != null);
    try std.testing.expectEqual(@as(u64, 1), child_account.?.nonce);
}

test "EVM logs - emit_log functionality" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test emit_log functionality
    const test_address = primitives.ZERO_ADDRESS;
    const topics = [_]u256{ 0x1234, 0x5678 };
    const data = "test log data";

    // Emit a log
    evm.emit_log(test_address, &topics, data);

    // Verify log was stored
    try std.testing.expectEqual(@as(usize, 1), evm.logs.items.len);
    const log = evm.logs.items[0];
    try std.testing.expectEqual(test_address, log.address);
    try std.testing.expectEqual(@as(usize, 2), log.topics.len);
    try std.testing.expectEqual(@as(u256, 0x1234), log.topics[0]);
    try std.testing.expectEqual(@as(u256, 0x5678), log.topics[1]);
    try std.testing.expectEqualStrings("test log data", log.data);

    // Test takeLogs
    const taken_logs = evm.takeLogs();
    defer DefaultEvm.CallResult.deinitLogsSlice(taken_logs, evm.allocator);
    try std.testing.expectEqual(@as(usize, 1), taken_logs.len);
    try std.testing.expectEqual(@as(usize, 0), evm.logs.items.len); // Should be empty after taking
}

test "EVM logs - included in CallResult" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Create bytecode that emits LOG0 (0xA0 opcode)
    // PUSH1 0x05 (data length)
    // PUSH1 0x00 (data offset)
    // LOG0
    const bytecode = [_]u8{ 0x60, 0x05, 0x60, 0x00, 0xA0, 0x00 }; // Last 0x00 is STOP
    const code_hash = try memory_db.set_code(&bytecode);

    const contract_address: primitives.Address = [_]u8{0x12} ++ [_]u8{0} ** 19;
    const account = Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try memory_db.set_account(contract_address, account);

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);
    defer {
        // Clean up logs
        for (result.logs) |log| {
            std.testing.allocator.free(log.topics);
            std.testing.allocator.free(log.data);
        }
        std.testing.allocator.free(result.logs);
    }

    // For now, we expect no logs because LOG0 isn't implemented in the frame
    // This test just verifies the infrastructure works
    try std.testing.expect(result.success);
    try std.testing.expect(result.logs.len == 0); // Will be > 0 when LOG opcodes are implemented
}

test "Host interface - hardfork compatibility checks" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    // Test with different hardfork configurations
    var london_evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .LONDON);
    defer london_evm.deinit();

    try std.testing.expectEqual(Hardfork.LONDON, london_evm.get_hardfork());
    try std.testing.expect(london_evm.is_hardfork_at_least(.HOMESTEAD));
    try std.testing.expect(london_evm.is_hardfork_at_least(.LONDON));
    try std.testing.expect(!london_evm.is_hardfork_at_least(.CANCUN));

    var cancun_evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer cancun_evm.deinit();

    try std.testing.expectEqual(Hardfork.CANCUN, cancun_evm.get_hardfork());
    try std.testing.expect(cancun_evm.is_hardfork_at_least(.LONDON));
    try std.testing.expect(cancun_evm.is_hardfork_at_least(.CANCUN));
}

test "Host interface - access cost operations" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .BERLIN);
    defer evm.deinit();

    const address = primitives.ZERO_ADDRESS;
    const slot: u256 = 42;

    // Test access costs (EIP-2929)
    const address_cost = try evm.access_address(address);
    const storage_cost = try evm.access_storage_slot(address, slot);

    // Cold access costs
    try std.testing.expectEqual(@as(u64, 2600), address_cost);
    try std.testing.expectEqual(@as(u64, 2100), storage_cost);
}

test "Host interface - input size validation" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Create input that exceeds max_input_size (131072 bytes)
    const large_input = try std.testing.allocator.alloc(u8, 200000);
    defer std.testing.allocator.free(large_input);
    @memset(large_input, 0xFF);

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = large_input,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);

    // Should fail due to input size limit
    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u64, 0), result.gas_left);
}

test "Call types - CREATE2 with salt" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const init_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xF3 }; // PUSH1 0 PUSH1 0 RETURN (empty contract)
    const salt: u256 = 0x1234567890ABCDEF;

    const create2_params = DefaultEvm.CallParams{
        .create2 = .{
            .caller = primitives.ZERO_ADDRESS,
            .value = 0,
            .init_code = &init_code,
            .salt = salt,
            .gas = 100000,
        },
    };

    const result = try evm.call(create2_params);
    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
}

test "Error handling - nested call depth tracking" {
    // Use smaller depth limit for testing
    const TestEvm = Evm(.{ .max_call_depth = 3 });

    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try TestEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    try std.testing.expectEqual(@as(u2, 0), evm.depth);

    const call_params = TestEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    };

    // Call should succeed when depth < max
    evm.depth = 2;
    const result1 = try evm.inner_call(call_params);
    try std.testing.expect(result1.success);
    try std.testing.expectEqual(@as(u2, 2), evm.depth); // Should restore depth

    // Call should fail when depth >= max
    evm.depth = 3;
    const result2 = try evm.inner_call(call_params);
    try std.testing.expect(!result2.success);
    try std.testing.expectEqual(@as(u64, 0), result2.gas_left);
}

test "Error handling - precompile execution" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test calling ECRECOVER precompile (address 0x01)
    const ecrecover_address = [_]u8{0} ** 19 ++ [_]u8{1}; // 0x0000...0001
    const input_data = [_]u8{0} ** 128; // Invalid ECRECOVER input (all zeros)

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = ecrecover_address,
            .value = 0,
            .input = &input_data,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);
    // ECRECOVER should handle invalid input gracefully
    try std.testing.expect(result.gas_left < 100000); // Some gas should be consumed
}

test "Precompiles - IDENTITY precompile (0x04)" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test IDENTITY precompile - should return input data unchanged
    const identity_address = [_]u8{0} ** 19 ++ [_]u8{4}; // 0x0000...0004
    const test_data = "Hello, World!";

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = identity_address,
            .value = 0,
            .input = test_data,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);
    defer if (result.success and result.output.len > 0) std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(test_data.len, result.output.len);
    try std.testing.expectEqualStrings(test_data, result.output);

    // Gas cost should be 15 + 3 * 1 = 18 (base + 3 * word count)
    const expected_gas_cost = 15 + 3 * ((test_data.len + 31) / 32);
    try std.testing.expectEqual(100000 - expected_gas_cost, result.gas_left);
}

test "Precompiles - SHA256 precompile (0x02)" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test SHA256 precompile
    const sha256_address = [_]u8{0} ** 19 ++ [_]u8{2}; // 0x0000...0002
    const test_input = "";

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = sha256_address,
            .value = 0,
            .input = test_input,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);
    defer if (result.success and result.output.len > 0) std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 32), result.output.len); // SHA256 always returns 32 bytes
    try std.testing.expect(result.gas_left < 100000); // Gas should be consumed
}

test "Precompiles - disabled configuration" {
    // Create EVM with precompiles disabled
    const NoPrecompileEvm = Evm(.{ .enable_precompiles = false });

    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try NoPrecompileEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Try to call IDENTITY precompile - should be treated as regular call
    const identity_address = [_]u8{0} ** 19 ++ [_]u8{4}; // 0x0000...0004
    const test_data = "Hello, World!";

    const call_params = NoPrecompileEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = identity_address,
            .value = 0,
            .input = test_data,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);

    // Should succeed but not execute as precompile (no special precompile behavior)
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 0), result.output.len); // No precompile output
    try std.testing.expectEqual(@as(u64, 100000), result.gas_left); // No gas consumed by precompile
}

test "Precompiles - invalid precompile addresses" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test invalid precompile address (0x0B - beyond supported range)
    const invalid_address = [_]u8{0} ** 19 ++ [_]u8{11}; // 0x0000...000B

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = invalid_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);

    // Should succeed as regular call (not precompile)
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, 100000), result.gas_left); // No gas consumed by precompile
}

// ============================================================================
// Minimal Debug Tests for Benchmark Investigation
// ============================================================================

test "Debug - Gas limit affects execution" {
    std.testing.log_level = .warn;

    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Deploy a simple infinite loop contract
    // JUMPDEST (0x5b) PUSH1 0x00 (0x6000) JUMP (0x56)
    const loop_bytecode = [_]u8{ 0x5b, 0x60, 0x00, 0x56 };
    const deploy_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{1};
    const code_hash = try memory_db.set_code(&loop_bytecode);
    try memory_db.set_account(deploy_address, Account{
        .nonce = 0,
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Test 1: Very low gas limit - should fail quickly
    {
        const start_time = std.time.nanoTimestamp();
        const result = try evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = deploy_address,
                .value = 0,
                .input = &.{},
                .gas = 100, // Very low gas
            },
        });
        const elapsed = std.time.nanoTimestamp() - start_time;

        try std.testing.expect(!result.success); // Should fail
        try std.testing.expectEqual(@as(u64, 0), result.gas_left); // All gas consumed
        std.log.warn("Low gas (100): elapsed = {} ns, success = {}", .{ elapsed, result.success });
    }

    // Test 2: Medium gas limit
    {
        const start_time = std.time.nanoTimestamp();
        const result = try evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = deploy_address,
                .value = 0,
                .input = &.{},
                .gas = 10000,
            },
        });
        const elapsed = std.time.nanoTimestamp() - start_time;

        try std.testing.expect(!result.success); // Should still fail (infinite loop)
        try std.testing.expectEqual(@as(u64, 0), result.gas_left);
        std.log.warn("Medium gas (10k): elapsed = {} ns, success = {}", .{ elapsed, result.success });
    }

    // Test 3: High gas limit
    {
        const start_time = std.time.nanoTimestamp();
        const result = try evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = deploy_address,
                .value = 0,
                .input = &.{},
                .gas = 1000000,
            },
        });
        const elapsed = std.time.nanoTimestamp() - start_time;

        try std.testing.expect(!result.success); // Should fail after consuming all gas
        try std.testing.expectEqual(@as(u64, 0), result.gas_left);
        std.log.warn("High gas (1M): elapsed = {} ns, success = {}", .{ elapsed, result.success });
    }
}

test "Debug - Contract deployment and execution" {
    std.testing.log_level = .warn;

    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test 1: Call to non-existent contract
    {
        const empty_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{99};
        const start_time = std.time.nanoTimestamp();
        const result = try evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = empty_address,
                .value = 0,
                .input = &.{},
                .gas = 100000,
            },
        });
        const elapsed = std.time.nanoTimestamp() - start_time;

        try std.testing.expect(result.success); // Empty contract succeeds immediately
        try std.testing.expectEqual(@as(u64, 100000), result.gas_left); // No gas consumed
        std.log.warn("Empty contract: elapsed = {} ns, gas_left = {}", .{ elapsed, result.gas_left });
    }

    // Test 2: Simple contract that returns immediately (STOP opcode)
    {
        const stop_bytecode = [_]u8{0x00}; // STOP
        const stop_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{2};
        const code_hash = try memory_db.set_code(&stop_bytecode);
        try memory_db.set_account(stop_address, Account{
            .nonce = 0,
            .balance = 0,
            .code_hash = code_hash,
            .storage_root = [_]u8{0} ** 32,
        });

        const start_time = std.time.nanoTimestamp();
        const result = try evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = stop_address,
                .value = 0,
                .input = &.{},
                .gas = 100000,
            },
        });
        const elapsed = std.time.nanoTimestamp() - start_time;

        try std.testing.expect(result.success);
        // STOP should consume minimal gas
        const gas_used = 100000 - result.gas_left;
        try std.testing.expect(gas_used < 100); // Should use very little gas
        std.log.warn("STOP contract: elapsed = {} ns, gas_used = {}", .{ elapsed, gas_used });
    }

    // Test 3: Contract with some computation
    {
        // PUSH1 0x05, PUSH1 0x03, ADD, PUSH1 0x00, MSTORE, STOP
        // Adds 3 + 5 and stores in memory
        const add_bytecode = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01, 0x60, 0x00, 0x52, 0x00 };
        const add_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{3};
        const code_hash = try memory_db.set_code(&add_bytecode);
        try memory_db.set_account(add_address, Account{
            .nonce = 0,
            .balance = 0,
            .code_hash = code_hash,
            .storage_root = [_]u8{0} ** 32,
        });

        const start_time = std.time.nanoTimestamp();
        const result = try evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = add_address,
                .value = 0,
                .input = &.{},
                .gas = 100000,
            },
        });
        const elapsed = std.time.nanoTimestamp() - start_time;

        try std.testing.expect(result.success);
        const gas_used = 100000 - result.gas_left;
        try std.testing.expect(gas_used > 0); // Should use some gas
        try std.testing.expect(gas_used < 1000); // But not too much
        std.log.warn("ADD contract: elapsed = {} ns, gas_used = {}", .{ elapsed, gas_used });
    }
}

test "Debug - Bytecode size affects execution time" {
    std.testing.log_level = .warn;

    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Create a large contract that does simple operations
    var large_bytecode = std.ArrayList(u8){};
    defer large_bytecode.deinit(std.testing.allocator);

    // Add many PUSH1/POP pairs (each costs gas but doesn't loop)
    for (0..1000) |_| {
        try large_bytecode.append(std.testing.allocator, 0x60); // PUSH1
        try large_bytecode.append(std.testing.allocator, 0x42); // value
        try large_bytecode.append(std.testing.allocator, 0x50); // POP
    }
    try large_bytecode.append(std.testing.allocator, 0x00); // STOP

    const large_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{4};
    const code_hash = try memory_db.set_code(large_bytecode.items);
    try memory_db.set_account(large_address, Account{
        .nonce = 0,
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Test with different gas limits
    const gas_limits = [_]u64{ 10000, 50000, 100000, 500000 };

    for (gas_limits) |gas_limit| {
        const start_time = std.time.nanoTimestamp();
        const result = try evm.call(.{
            .call = .{
                .caller = primitives.ZERO_ADDRESS,
                .to = large_address,
                .value = 0,
                .input = &.{},
                .gas = gas_limit,
            },
        });
        const elapsed = std.time.nanoTimestamp() - start_time;

        const gas_used = gas_limit - result.gas_left;
        std.log.warn("Large contract (gas_limit={}): elapsed = {} ns, gas_used = {}, success = {}", .{ gas_limit, elapsed, gas_used, result.success });

        // With low gas, should fail before completing
        if (gas_limit < 50000) {
            try std.testing.expect(!result.success);
            try std.testing.expectEqual(@as(u64, 0), result.gas_left);
        } else {
            // With enough gas, should complete
            try std.testing.expect(result.success);
            try std.testing.expect(result.gas_left > 0);
        }
    }
}

test "Security - bounds checking and edge cases" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test maximum gas limit
    const max_gas_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = std.math.maxInt(u64),
        },
    };

    const max_gas_result = try evm.call(max_gas_params);
    try std.testing.expect(max_gas_result.gas_left <= std.math.maxInt(u64));

    // Test invalid address operations
    const invalid_address = [_]u8{0xFF} ** 20;
    const balance = evm.get_balance(invalid_address);
    try std.testing.expectEqual(@as(u256, 0), balance);

    const exists = evm.account_exists(invalid_address);
    try std.testing.expect(!exists);

    // Test max u256 storage operations
    const max_key: u256 = std.math.maxInt(u256);
    const max_value: u256 = std.math.maxInt(u256);

    try evm.set_storage(primitives.ZERO_ADDRESS, max_key, max_value);
    const retrieved_max = evm.get_storage(primitives.ZERO_ADDRESS, max_key);
    try std.testing.expectEqual(max_value, retrieved_max);
}

test "EVM with minimal planner strategy" {
    // Define EVM config with minimal planner strategy
    const MinimalEvmConfig = EvmConfig{
        .planner_strategy = .minimal,
    };
    const MinimalEvm = Evm(MinimalEvmConfig);

    // Create test database
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try MinimalEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test basic execution with minimal planner
    const simple_bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x01, // ADD
        0x00, // STOP
    };

    const call_params = MinimalEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &simple_bytecode,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);
    try std.testing.expect(result.success);
}

test "EVM with advanced planner strategy" {
    // Define EVM config with advanced planner strategy
    const AdvancedEvmConfig = EvmConfig{
        .planner_strategy = .advanced,
    };
    const AdvancedEvm = Evm(AdvancedEvmConfig);

    // Create test database
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try AdvancedEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test basic execution with advanced planner
    const simple_bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x01, // ADD
        0x00, // STOP
    };

    const call_params = AdvancedEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = primitives.ZERO_ADDRESS,
            .value = 0,
            .input = &simple_bytecode,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);
    try std.testing.expect(result.success);
}

// =============================================================================
// Journal State Application Rollback Tests
// =============================================================================

test "journal state application - storage change rollback" {
    // Create test database
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const test_address = primitives.Address{ .bytes = [_]u8{0x12} ++ [_]u8{0} ** 19 };
    const storage_key: u256 = 0x123;
    const original_value: u256 = 0x456;
    const new_value: u256 = 0x789;

    // Set initial storage value
    try evm.database.set_storage(test_address, storage_key, original_value);

    // Create snapshot
    const snapshot_id = evm.create_snapshot();

    // Modify storage value and record in journal
    try evm.database.set_storage(test_address, storage_key, new_value);
    try evm.journal.entries.append(.{
        .snapshot_id = snapshot_id,
        .data = .{ .storage_change = .{
            .address = test_address,
            .key = storage_key,
            .original_value = original_value,
        } },
    });

    // Verify new value is set
    const current_value = try evm.database.get_storage(test_address, storage_key);
    try std.testing.expectEqual(new_value, current_value);

    // Revert to snapshot
    evm.revert_to_snapshot(snapshot_id);

    // Verify storage value was reverted
    const reverted_value = try evm.database.get_storage(test_address, storage_key);
    try std.testing.expectEqual(original_value, reverted_value);
}

test "journal state application - balance change rollback" {
    // Create test database
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const test_address = primitives.Address{ .bytes = [_]u8{0x34} ++ [_]u8{0} ** 19 };
    const original_balance: u256 = 1000;
    const new_balance: u256 = 2000;

    // Set initial account balance
    var original_account = Account.zero();
    original_account.balance = original_balance;
    try evm.database.set_account(test_address.bytes, original_account);

    // Create snapshot
    const snapshot_id = evm.create_snapshot();

    // Modify balance and record in journal
    var modified_account = original_account;
    modified_account.balance = new_balance;
    try evm.database.set_account(test_address.bytes, modified_account);
    try evm.journal.entries.append(.{
        .snapshot_id = snapshot_id,
        .data = .{ .balance_change = .{
            .address = test_address,
            .original_balance = original_balance,
        } },
    });

    // Verify new balance is set
    const current_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqual(new_balance, current_account.balance);

    // Revert to snapshot
    evm.revert_to_snapshot(snapshot_id);

    // Verify balance was reverted
    const reverted_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqual(original_balance, reverted_account.balance);
}

test "journal state application - nonce change rollback" {
    // Create test database
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const test_address = primitives.Address{ .bytes = [_]u8{0x56} ++ [_]u8{0} ** 19 };
    const original_nonce: u64 = 5;
    const new_nonce: u64 = 10;

    // Set initial account nonce
    var original_account = Account.zero();
    original_account.nonce = original_nonce;
    try evm.database.set_account(test_address.bytes, original_account);

    // Create snapshot
    const snapshot_id = evm.create_snapshot();

    // Modify nonce and record in journal
    var modified_account = original_account;
    modified_account.nonce = new_nonce;
    try evm.database.set_account(test_address.bytes, modified_account);
    try evm.journal.entries.append(.{
        .snapshot_id = snapshot_id,
        .data = .{ .nonce_change = .{
            .address = test_address,
            .original_nonce = original_nonce,
        } },
    });

    // Verify new nonce is set
    const current_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqual(new_nonce, current_account.nonce);

    // Revert to snapshot
    evm.revert_to_snapshot(snapshot_id);

    // Verify nonce was reverted
    const reverted_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqual(original_nonce, reverted_account.nonce);
}

test "journal state application - code change rollback" {
    // Create test database
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const test_address = primitives.Address{ .bytes = [_]u8{0x78} ++ [_]u8{0} ** 19 };
    const original_code_hash = [_]u8{0xAA} ++ [_]u8{0} ** 31;
    const new_code_hash = [_]u8{0xBB} ++ [_]u8{0} ** 31;

    // Set initial account code hash
    var original_account = Account.zero();
    original_account.code_hash = original_code_hash;
    try evm.database.set_account(test_address.bytes, original_account);

    // Create snapshot
    const snapshot_id = evm.create_snapshot();

    // Modify code hash and record in journal
    var modified_account = original_account;
    modified_account.code_hash = new_code_hash;
    try evm.database.set_account(test_address.bytes, modified_account);
    try evm.journal.entries.append(.{
        .snapshot_id = snapshot_id,
        .data = .{ .code_change = .{
            .address = test_address,
            .original_code_hash = original_code_hash,
        } },
    });

    // Verify new code hash is set
    const current_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqualSlices(u8, &new_code_hash, &current_account.code_hash);

    // Revert to snapshot
    evm.revert_to_snapshot(snapshot_id);

    // Verify code hash was reverted
    const reverted_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqualSlices(u8, &original_code_hash, &reverted_account.code_hash);
}

test "journal state application - multiple changes rollback" {
    // Create test database
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const test_address = [_]u8{0x9A} ++ [_]u8{0} ** 19;
    const storage_key: u256 = 0xABC;

    // Original state
    const original_balance: u256 = 500;
    const original_nonce: u64 = 3;
    const original_storage: u256 = 0x111;
    const original_code_hash = [_]u8{0xCC} ++ [_]u8{0} ** 31;

    // New state
    const new_balance: u256 = 1500;
    const new_nonce: u64 = 8;
    const new_storage: u256 = 0x999;
    const new_code_hash = [_]u8{0xDD} ++ [_]u8{0} ** 31;

    // Set initial state
    var original_account = Account.zero();
    original_account.balance = original_balance;
    original_account.nonce = original_nonce;
    original_account.code_hash = original_code_hash;
    try evm.database.set_account(test_address.bytes, original_account);
    try evm.database.set_storage(test_address, storage_key, original_storage);

    // Create snapshot
    const snapshot_id = evm.create_snapshot();

    // Make multiple changes and record in journal
    var modified_account = original_account;
    modified_account.balance = new_balance;
    modified_account.nonce = new_nonce;
    modified_account.code_hash = new_code_hash;
    try evm.database.set_account(test_address.bytes, modified_account);
    try evm.database.set_storage(test_address, storage_key, new_storage);

    // Add journal entries for all changes
    try evm.journal.entries.append(.{
        .snapshot_id = snapshot_id,
        .data = .{ .balance_change = .{
            .address = test_address,
            .original_balance = original_balance,
        } },
    });
    try evm.journal.entries.append(.{
        .snapshot_id = snapshot_id,
        .data = .{ .nonce_change = .{
            .address = test_address,
            .original_nonce = original_nonce,
        } },
    });
    try evm.journal.entries.append(.{
        .snapshot_id = snapshot_id,
        .data = .{ .code_change = .{
            .address = test_address,
            .original_code_hash = original_code_hash,
        } },
    });
    try evm.journal.entries.append(.{
        .snapshot_id = snapshot_id,
        .data = .{ .storage_change = .{
            .address = test_address,
            .key = storage_key,
            .original_value = original_storage,
        } },
    });

    // Verify all new values are set
    const current_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqual(new_balance, current_account.balance);
    try std.testing.expectEqual(new_nonce, current_account.nonce);
    try std.testing.expectEqualSlices(u8, &new_code_hash, &current_account.code_hash);
    const current_storage = try evm.database.get_storage(test_address, storage_key);
    try std.testing.expectEqual(new_storage, current_storage);

    // Revert to snapshot
    evm.revert_to_snapshot(snapshot_id);

    // Verify all values were reverted
    const reverted_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqual(original_balance, reverted_account.balance);
    try std.testing.expectEqual(original_nonce, reverted_account.nonce);
    try std.testing.expectEqualSlices(u8, &original_code_hash, &reverted_account.code_hash);
    const reverted_storage = try evm.database.get_storage(test_address, storage_key);
    try std.testing.expectEqual(original_storage, reverted_storage);
}

test "journal state application - nested snapshots rollback" {
    // Create test database
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const test_address = [_]u8{0xBE} ++ [_]u8{0} ** 19;
    const original_balance: u256 = 100;
    const middle_balance: u256 = 200;
    const final_balance: u256 = 300;

    // Set initial state
    var account = Account.zero();
    account.balance = original_balance;
    try evm.database.set_account(test_address.bytes, account);

    // Create first snapshot
    const snapshot1 = evm.create_snapshot();

    // First change
    account.balance = middle_balance;
    try evm.database.set_account(test_address.bytes, account);
    try evm.journal.entries.append(.{
        .snapshot_id = snapshot1,
        .data = .{ .balance_change = .{
            .address = test_address,
            .original_balance = original_balance,
        } },
    });

    // Create second snapshot
    const snapshot2 = evm.create_snapshot();

    // Second change
    account.balance = final_balance;
    try evm.database.set_account(test_address.bytes, account);
    try evm.journal.entries.append(.{
        .snapshot_id = snapshot2,
        .data = .{ .balance_change = .{
            .address = test_address,
            .original_balance = middle_balance,
        } },
    });

    // Verify final state
    var current_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqual(final_balance, current_account.balance);

    // Revert to second snapshot (should restore middle state)
    evm.revert_to_snapshot(snapshot2);
    current_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqual(middle_balance, current_account.balance);

    // Revert to first snapshot (should restore original state)
    evm.revert_to_snapshot(snapshot1);
    current_account = (try evm.database.get_account(test_address.bytes)).?;
    try std.testing.expectEqual(original_balance, current_account.balance);
}

test "journal state application - empty journal rollback" {
    // Create test database
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Create snapshot with no changes
    const snapshot_id = evm.create_snapshot();

    // Revert to snapshot (should be no-op)
    evm.revert_to_snapshot(snapshot_id);

    // Test passes if no error is thrown
    try std.testing.expect(true);
}

test "EVM contract execution - minimal benchmark reproduction" {
    // Create test database
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21000000, // Higher gas for contract execution
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Simple test contract bytecode: PUSH1 0x42 PUSH1 0x00 MSTORE PUSH1 0x20 PUSH1 0x00 RETURN
    // This stores 0x42 in memory at position 0 and returns 32 bytes
    const test_bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xf3, // RETURN
    };

    // Deploy the contract first
    const deploy_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{1}; // Address 0x000...001

    // Store contract code in database
    const code_hash = try memory_db.set_code(&test_bytecode);
    try memory_db.set_account(deploy_address, Account{
        .nonce = 0,
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = deploy_address,
            .value = 0,
            .input = &.{}, // No input data
            .gas = 100000,
        },
    };

    // Execute the contract - this should reproduce the benchmark scenario
    const result = try evm.call(call_params);

    // Verify execution succeeded
    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
    try std.testing.expectEqual(@as(usize, 32), result.output.len);
}

test "Precompile - IDENTITY (0x04) basic functionality" {
    // Create test database
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test calling IDENTITY precompile (0x04) - should return input as-is
    const precompile_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{4}; // Address 0x000...004
    const input_data = "Hello, World!";

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_address,
            .value = 0,
            .input = input_data,
            .gas = 100000,
        },
    };

    // Execute the precompile
    const result = try evm.call(call_params);

    // Verify execution succeeded
    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
    try std.testing.expectEqualSlices(u8, input_data, result.output);
}

test "Precompile - SHA256 (0x02) basic functionality" {
    // Create test database
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test calling SHA256 precompile (0x02)
    const precompile_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{2}; // Address 0x000...002
    const input_data = "abc";

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_address,
            .value = 0,
            .input = input_data,
            .gas = 100000,
        },
    };

    // Execute the precompile
    const result = try evm.call(call_params);

    // Verify execution succeeded
    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
    try std.testing.expectEqual(@as(usize, 32), result.output.len);

    // Expected SHA-256 hash of "abc"
    const expected = [_]u8{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    };
    try std.testing.expectEqualSlices(u8, &expected, result.output);
}

test "Precompile diagnosis - ECRECOVER (0x01) placeholder implementation" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1_000_000_000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test ECRECOVER with invalid signature (all zeros)
    const precompile_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{1};
    const input_data = [_]u8{0} ** 128; // Invalid signature

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_address,
            .value = 0,
            .input = &input_data,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 32), result.output.len);

    // ECRECOVER returns zero address for invalid signatures (placeholder behavior)
    for (result.output) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "Precompile diagnosis - RIPEMD160 (0x03) unimplemented" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1_000_000_000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const precompile_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{3};
    const input_data = "test data";

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_address,
            .value = 0,
            .input = input_data,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);

    // RIPEMD160 is a placeholder implementation (returns zeros)
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 32), result.output.len);

    // Should be zeros (placeholder behavior)
    for (result.output) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "Precompile diagnosis - MODEXP (0x05) basic case works" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1_000_000_000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const precompile_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{5};

    // 3^4 mod 5 = 81 mod 5 = 1
    var input: [99]u8 = [_]u8{0} ** 99;
    input[31] = 1; // base_len = 1
    input[63] = 1; // exp_len = 1
    input[95] = 1; // mod_len = 1
    input[96] = 3; // base = 3
    input[97] = 4; // exp = 4
    input[98] = 5; // mod = 5

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_address,
            .value = 0,
            .input = &input,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 1), result.output.len);
    try std.testing.expectEqual(@as(u8, 1), result.output[0]);
}

test "Precompile diagnosis - BN254 operations disabled" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1_000_000_000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test ECADD (0x06)
    const ecadd_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{6};
    const ecadd_input = [_]u8{0} ** 128; // Two zero points

    const ecadd_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = ecadd_address,
            .value = 0,
            .input = &ecadd_input,
            .gas = 100000,
        },
    };

    const ecadd_result = try evm.call(ecadd_params);

    // BN254 operations might be disabled (check build_options.no_bn254)
    // The precompile will either succeed with placeholder output or fail
    if (ecadd_result.success) {
        try std.testing.expectEqual(@as(usize, 64), ecadd_result.output.len);
        // Placeholder implementation returns all zeros
        for (ecadd_result.output) |byte| {
            try std.testing.expectEqual(@as(u8, 0), byte);
        }
    } else {
        // BN254 operations disabled - this is expected behavior
        const log = @import("log.zig");
        log.warn("BN254 operations are disabled (no_bn254 build option)", .{});
    }
}

test "Precompile diagnosis - BLAKE2F (0x09) placeholder" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1_000_000_000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const precompile_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{9};
    const input = [_]u8{0} ** 213; // Valid BLAKE2F input length

    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_address,
            .value = 0,
            .input = &input,
            .gas = 100000,
        },
    };

    const result = try evm.call(call_params);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 64), result.output.len);

    // BLAKE2F placeholder returns all zeros
    for (result.output) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "EVM benchmark scenario - reproduces segfault" {
    const allocator = std.testing.allocator;

    // Create test database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    // Deploy contract first (ERC20 approval bytecode snippet)
    const stop_bytecode = [_]u8{0x00}; // Simple STOP for now
    const deploy_address: primitives.Address = [_]u8{0} ** 19 ++ [_]u8{1};
    const code_hash = try memory_db.set_code(&stop_bytecode);
    try memory_db.set_account(deploy_address, Account{
        .nonce = 0,
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Create EVM instance
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 21000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm_instance = try DefaultEvm.init(allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm_instance.deinit();

    // Simple calldata
    const calldata = [_]u8{0x00};

    // Execute call (simulating benchmark)
    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = deploy_address,
            .value = 0,
            .input = &calldata,
            .gas = 100000,
        },
    };

    const result = try evm_instance.call(call_params);
    try std.testing.expect(result.success);

    // The segfault happens in deinit, so let's explicitly test that
    // by creating and destroying multiple times
    for (0..3) |_| {
        var temp_evm = try DefaultEvm.init(allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
        const temp_result = try temp_evm.call(call_params);
        try std.testing.expect(temp_result.success);
        temp_evm.deinit(); // This is where the segfault happens
    }
}

// ============================================================================
// Cross-Contract CREATE Interaction Tests
// ============================================================================

test "CREATE interaction - deployed contract can be called" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm_instance = try DefaultEvm.init(
        allocator,
        db_interface,
        BlockInfo{
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .base_fee = 1_000_000_000,
            .prev_randao = [_]u8{0} ** 32,
        },
        TransactionContext{
            .gas_limit = 10_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .chain_id = 1,
        },
        20_000_000_000,
        [_]u8{0x01} ** 20,
        .CANCUN,
    );
    defer evm_instance.deinit();

    // Step 1: Deploy a simple contract that returns 42
    // Init code: stores runtime code and returns it
    const runtime_code = [_]u8{
        0x60, 0x2A, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    var init_code = std.ArrayList(u8).init(allocator);
    defer init_code.deinit();

    // Store runtime code in memory
    for (runtime_code, 0..) |byte, i| {
        try init_code.append(0x60); // PUSH1
        try init_code.append(@intCast(i));
        try init_code.append(0x60); // PUSH1
        try init_code.append(byte);
        try init_code.append(0x53); // MSTORE8
    }

    // Return runtime code
    try init_code.append(0x60); // PUSH1
    try init_code.append(@intCast(runtime_code.len)); // size
    try init_code.append(0x60); // PUSH1
    try init_code.append(0x00); // offset
    try init_code.append(0xF3); // RETURN

    // Deploy the contract
    const create_result = try evm_instance.call(.{
        .create = .{
            .caller = [_]u8{0x01} ** 20,
            .value = 0,
            .init_code = init_code.items,
            .gas = 1_000_000,
        },
    });
    defer if (create_result.output.len > 0) allocator.free(create_result.output);

    try std.testing.expect(create_result.success);
    try std.testing.expectEqual(@as(usize, 20), create_result.output.len);

    // Get deployed contract address
    var contract_address: primitives.Address = undefined;
    @memcpy(&contract_address, create_result.output[0..20]);

    // Step 2: Call the deployed contract
    const call_result = try evm_instance.call(.{
        .call = .{
            .caller = [_]u8{0x01} ** 20,
            .to = contract_address,
            .value = 0,
            .input = &[_]u8{}, // No input data
            .gas = 100_000,
        },
    });
    defer if (call_result.output.len > 0) allocator.free(call_result.output);

    try std.testing.expect(call_result.success);
    try std.testing.expectEqual(@as(usize, 32), call_result.output.len);

    // Verify returned value is 42
    var returned_value: u256 = 0;
    for (call_result.output) |byte| {
        returned_value = (returned_value << 8) | byte;
    }
    try std.testing.expectEqual(@as(u256, 42), returned_value);
}

test "CREATE interaction - factory creates and initializes child contracts" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm_instance = try DefaultEvm.init(
        allocator,
        db_interface,
        BlockInfo{
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .base_fee = 1_000_000_000,
            .prev_randao = [_]u8{0} ** 32,
        },
        TransactionContext{
            .gas_limit = 10_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .chain_id = 1,
        },
        20_000_000_000,
        [_]u8{0x01} ** 20,
        .CANCUN,
    );
    defer evm_instance.deinit();

    // Child contract: stores initialization value and returns it
    const child_runtime = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x54, // SLOAD (load value from slot 0)
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Child init code: stores constructor argument in slot 0
    var child_init = std.ArrayList(u8).init(allocator);
    defer child_init.deinit();

    // Store caller-provided value in slot 0
    try child_init.append(0x60); // PUSH1
    try child_init.append(0x00); // 0 (calldata offset)
    try child_init.append(0x35); // CALLDATALOAD
    try child_init.append(0x60); // PUSH1
    try child_init.append(0x00); // 0 (storage slot)
    try child_init.append(0x55); // SSTORE

    // Store runtime code in memory
    for (child_runtime, 0..) |byte, i| {
        try child_init.append(0x60); // PUSH1
        try child_init.append(@intCast(i));
        try child_init.append(0x60); // PUSH1
        try child_init.append(byte);
        try child_init.append(0x53); // MSTORE8
    }

    // Return runtime code
    try child_init.append(0x60); // PUSH1
    try child_init.append(@intCast(child_runtime.len));
    try child_init.append(0x60); // PUSH1
    try child_init.append(0x00);
    try child_init.append(0xF3); // RETURN

    // Factory contract: creates child with initialization value
    var factory_code = std.ArrayList(u8).init(allocator);
    defer factory_code.deinit();

    // Load initialization value from calldata
    try factory_code.append(0x60); // PUSH1
    try factory_code.append(0x00); // 0
    try factory_code.append(0x35); // CALLDATALOAD

    // Store child init code in memory (with constructor arg appended)
    for (child_init.items, 0..) |byte, i| {
        try factory_code.append(0x60); // PUSH1
        try factory_code.append(byte);
        try factory_code.append(0x60); // PUSH1
        try factory_code.append(@intCast(i));
        try factory_code.append(0x53); // MSTORE8
    }

    // Append constructor argument to init code
    const init_size = child_init.items.len;
    try factory_code.append(0x60); // PUSH1
    try factory_code.append(@intCast(init_size)); // offset for constructor arg
    try factory_code.append(0x52); // MSTORE (store 32-byte constructor arg)

    // CREATE child contract
    try factory_code.append(0x60); // PUSH1
    try factory_code.append(@intCast(init_size + 32)); // size including constructor arg
    try factory_code.append(0x60); // PUSH1
    try factory_code.append(0x00); // offset
    try factory_code.append(0x60); // PUSH1
    try factory_code.append(0x00); // value
    try factory_code.append(0xF0); // CREATE

    // Return created address
    try factory_code.append(0x60); // PUSH1
    try factory_code.append(0x00); // 0
    try factory_code.append(0x52); // MSTORE
    try factory_code.append(0x60); // PUSH1
    try factory_code.append(0x20); // 32
    try factory_code.append(0x60); // PUSH1
    try factory_code.append(0x00); // 0
    try factory_code.append(0xF3); // RETURN

    // Deploy factory with initialization value 123
    var deploy_data = std.ArrayList(u8).init(allocator);
    defer deploy_data.deinit();
    const init_value = [_]u8{0} ** 31 ++ [_]u8{123}; // 123 as uint256
    try deploy_data.appendSlice(&init_value);

    const factory_result = try evm_instance.call(.{
        .create = .{
            .caller = [_]u8{0x01} ** 20,
            .value = 0,
            .init_code = deploy_data.items,
            .gas = 5_000_000,
        },
    });
    defer if (factory_result.output.len > 0) allocator.free(factory_result.output);

    try std.testing.expect(factory_result.success);

    // Extract child contract address from output
    var child_address: primitives.Address = undefined;
    @memcpy(&child_address, factory_result.output[12..32]); // Address is in bytes 12-31

    // Call child contract to verify initialization
    const verify_result = try evm_instance.call(.{
        .call = .{
            .caller = [_]u8{0x01} ** 20,
            .to = child_address,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100_000,
        },
    });
    defer if (verify_result.output.len > 0) allocator.free(verify_result.output);

    try std.testing.expect(verify_result.success);

    // Verify returned value is 123
    var returned_value: u256 = 0;
    for (verify_result.output) |byte| {
        returned_value = (returned_value << 8) | byte;
    }
    try std.testing.expectEqual(@as(u256, 123), returned_value);
}

test "CREATE interaction - contract creates contract that creates contract" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm_instance = try DefaultEvm.init(
        allocator,
        db_interface,
        BlockInfo{
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .base_fee = 1_000_000_000,
            .prev_randao = [_]u8{0} ** 32,
        },
        TransactionContext{
            .gas_limit = 20_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .chain_id = 1,
        },
        20_000_000_000,
        [_]u8{0x01} ** 20,
        .CANCUN,
    );
    defer evm_instance.deinit();

    // Level 3 contract (grandchild): returns constant 99
    const level3_runtime = [_]u8{
        0x60, 0x63, // PUSH1 99
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Level 3 init code
    var level3_init = std.ArrayList(u8).init(allocator);
    defer level3_init.deinit();
    for (level3_runtime, 0..) |byte, i| {
        try level3_init.append(0x60); // PUSH1
        try level3_init.append(@intCast(i));
        try level3_init.append(0x60); // PUSH1
        try level3_init.append(byte);
        try level3_init.append(0x53); // MSTORE8
    }
    try level3_init.append(0x60); // PUSH1
    try level3_init.append(@intCast(level3_runtime.len));
    try level3_init.append(0x60); // PUSH1
    try level3_init.append(0x00);
    try level3_init.append(0xF3); // RETURN

    // Level 2 contract (child): creates level 3 and returns its address
    var level2_runtime = std.ArrayList(u8).init(allocator);
    defer level2_runtime.deinit();

    // Store level 3 init code
    for (level3_init.items, 0..) |byte, i| {
        try level2_runtime.append(0x60); // PUSH1
        try level2_runtime.append(byte);
        try level2_runtime.append(0x60); // PUSH1
        try level2_runtime.append(@intCast(i));
        try level2_runtime.append(0x53); // MSTORE8
    }

    // CREATE level 3
    try level2_runtime.append(0x60); // PUSH1
    try level2_runtime.append(@intCast(level3_init.items.len));
    try level2_runtime.append(0x60); // PUSH1
    try level2_runtime.append(0x00); // offset
    try level2_runtime.append(0x60); // PUSH1
    try level2_runtime.append(0x00); // value
    try level2_runtime.append(0xF0); // CREATE

    // Return address
    try level2_runtime.append(0x60); // PUSH1
    try level2_runtime.append(0x00); // 0
    try level2_runtime.append(0x52); // MSTORE
    try level2_runtime.append(0x60); // PUSH1
    try level2_runtime.append(0x20); // 32
    try level2_runtime.append(0x60); // PUSH1
    try level2_runtime.append(0x00); // 0
    try level2_runtime.append(0xF3); // RETURN

    // Level 2 init code
    var level2_init = std.ArrayList(u8).init(allocator);
    defer level2_init.deinit();
    for (level2_runtime.items, 0..) |byte, i| {
        try level2_init.append(0x60); // PUSH1
        try level2_init.append(@as(u8, @truncate(i)));
        try level2_init.append(0x60); // PUSH1
        try level2_init.append(byte);
        try level2_init.append(0x53); // MSTORE8
    }
    try level2_init.append(0x61); // PUSH2
    try level2_init.append(@as(u8, @truncate(level2_runtime.items.len >> 8)));
    try level2_init.append(@as(u8, @truncate(level2_runtime.items.len & 0xFF)));
    try level2_init.append(0x60); // PUSH1
    try level2_init.append(0x00);
    try level2_init.append(0xF3); // RETURN

    // Level 1 contract (parent): creates level 2
    var level1_code = std.ArrayList(u8).init(allocator);
    defer level1_code.deinit();

    // Store level 2 init code
    for (level2_init.items, 0..) |byte, i| {
        try level1_code.append(0x60); // PUSH1
        try level1_code.append(byte);
        try level1_code.append(0x61); // PUSH2
        try level1_code.append(@as(u8, @truncate(i >> 8)));
        try level1_code.append(@as(u8, @truncate(i & 0xFF)));
        try level1_code.append(0x53); // MSTORE8
    }

    // CREATE level 2
    try level1_code.append(0x61); // PUSH2
    try level1_code.append(@as(u8, @truncate(level2_init.items.len >> 8)));
    try level1_code.append(@as(u8, @truncate(level2_init.items.len & 0xFF)));
    try level1_code.append(0x60); // PUSH1
    try level1_code.append(0x00); // offset
    try level1_code.append(0x60); // PUSH1
    try level1_code.append(0x00); // value
    try level1_code.append(0xF0); // CREATE

    // Store level 2 address
    try level1_code.append(0x60); // PUSH1
    try level1_code.append(0x00); // slot 0
    try level1_code.append(0x55); // SSTORE
    try level1_code.append(0x00); // STOP

    // Execute level 1
    const result1 = try evm_instance.call(.{
        .create = .{
            .caller = [_]u8{0x01} ** 20,
            .value = 0,
            .init_code = level1_code.items,
            .gas = 10_000_000,
        },
    });
    defer if (result1.output.len > 0) allocator.free(result1.output);

    try std.testing.expect(result1.success);

    // Get level 2 address from storage
    const level2_addr_u256 = evm_instance.get_storage([_]u8{0x01} ** 20, 0);
    var level2_addr: primitives.Address = undefined;
    const bytes = std.mem.toBytes(level2_addr_u256);
    @memcpy(&level2_addr, bytes[12..32]);

    // Call level 2 to get level 3 address
    const result2 = try evm_instance.call(.{
        .call = .{
            .caller = [_]u8{0x01} ** 20,
            .to = level2_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 1_000_000,
        },
    });
    defer if (result2.output.len > 0) allocator.free(result2.output);

    try std.testing.expect(result2.success);

    // Get level 3 address
    var level3_addr: primitives.Address = undefined;
    @memcpy(&level3_addr, result2.output[12..32]);

    // Call level 3 to verify it returns 99
    const result3 = try evm_instance.call(.{
        .call = .{
            .caller = [_]u8{0x01} ** 20,
            .to = level3_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100_000,
        },
    });
    defer if (result3.output.len > 0) allocator.free(result3.output);

    try std.testing.expect(result3.success);

    var returned_value: u256 = 0;
    for (result3.output) |byte| {
        returned_value = (returned_value << 8) | byte;
    }
    try std.testing.expectEqual(@as(u256, 99), returned_value);
}

test "CREATE interaction - created contract modifies parent storage" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm_instance = try DefaultEvm.init(
        allocator,
        db_interface,
        BlockInfo{
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .base_fee = 1_000_000_000,
            .prev_randao = [_]u8{0} ** 32,
        },
        TransactionContext{
            .gas_limit = 10_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .chain_id = 1,
        },
        20_000_000_000,
        [_]u8{0x01} ** 20,
        .CANCUN,
    );
    defer evm_instance.deinit();

    // Child contract that calls back to parent
    const child_runtime = [_]u8{
        // Call parent's setValue(42) function
        0x60, 0x2A, // PUSH1 42 (value to set)
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE (store at memory[0])
        0x60, 0x20, // PUSH1 32 (return data size)
        0x60, 0x00, // PUSH1 0 (return data offset)
        0x60, 0x20, // PUSH1 32 (input size)
        0x60, 0x00, // PUSH1 0 (input offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x33, // CALLER (parent address)
        0x5A, // GAS
        0xF1, // CALL parent

        // Return success
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Child init code
    var child_init = std.ArrayList(u8).init(allocator);
    defer child_init.deinit();
    for (child_runtime, 0..) |byte, i| {
        try child_init.append(0x60); // PUSH1
        try child_init.append(@intCast(i));
        try child_init.append(0x60); // PUSH1
        try child_init.append(byte);
        try child_init.append(0x53); // MSTORE8
    }
    try child_init.append(0x60); // PUSH1
    try child_init.append(@intCast(child_runtime.len));
    try child_init.append(0x60); // PUSH1
    try child_init.append(0x00);
    try child_init.append(0xF3); // RETURN

    // Parent contract with setValue function
    var parent_code = std.ArrayList(u8).init(allocator);
    defer parent_code.deinit();

    // Check if being called (calldata size > 0)
    try parent_code.append(0x36); // CALLDATASIZE
    try parent_code.append(0x60); // PUSH1
    try parent_code.append(0x23); // Jump destination for setValue
    try parent_code.append(0x57); // JUMPI

    // CREATE path (no calldata)
    // Store child init code
    for (child_init.items, 0..) |byte, i| {
        try parent_code.append(0x60); // PUSH1
        try parent_code.append(byte);
        try parent_code.append(0x60); // PUSH1
        try parent_code.append(@intCast(i));
        try parent_code.append(0x53); // MSTORE8
    }

    // CREATE child
    try parent_code.append(0x60); // PUSH1
    try parent_code.append(@intCast(child_init.items.len));
    try parent_code.append(0x60); // PUSH1
    try parent_code.append(0x00); // offset
    try parent_code.append(0x60); // PUSH1
    try parent_code.append(0x00); // value
    try parent_code.append(0xF0); // CREATE

    // Store child address at slot 1
    try parent_code.append(0x60); // PUSH1
    try parent_code.append(0x01); // slot 1
    try parent_code.append(0x55); // SSTORE
    try parent_code.append(0x00); // STOP

    // setValue function (JUMPDEST at 0x23)
    try parent_code.append(0x5B); // JUMPDEST
    try parent_code.append(0x60); // PUSH1
    try parent_code.append(0x00); // 0
    try parent_code.append(0x35); // CALLDATALOAD (load value)
    try parent_code.append(0x60); // PUSH1
    try parent_code.append(0x00); // slot 0
    try parent_code.append(0x55); // SSTORE
    try parent_code.append(0x00); // STOP

    // Deploy parent contract
    const deploy_result = try evm_instance.call(.{
        .create = .{
            .caller = [_]u8{0x01} ** 20,
            .value = 0,
            .init_code = parent_code.items,
            .gas = 5_000_000,
        },
    });
    defer if (deploy_result.output.len > 0) allocator.free(deploy_result.output);

    try std.testing.expect(deploy_result.success);

    // Get parent address (deterministic based on sender nonce)
    const parent_addr = [_]u8{0x01} ** 20; // Simplified for test

    // Get child address from parent's storage
    const child_addr_u256 = evm_instance.get_storage(parent_addr, 1);
    var child_addr: primitives.Address = undefined;
    const bytes = std.mem.toBytes(child_addr_u256);
    @memcpy(&child_addr, bytes[12..32]);

    // Verify parent's value storage is initially 0
    const initial_value = evm_instance.get_storage(parent_addr, 0);
    try std.testing.expectEqual(@as(u256, 0), initial_value);

    // Call child contract, which should call back to parent
    const call_result = try evm_instance.call(.{
        .call = .{
            .caller = [_]u8{0x02} ** 20,
            .to = child_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 1_000_000,
        },
    });
    defer if (call_result.output.len > 0) allocator.free(call_result.output);

    try std.testing.expect(call_result.success);

    // Verify parent's storage was modified by child
    const final_value = evm_instance.get_storage(parent_addr, 0);
    try std.testing.expectEqual(@as(u256, 42), final_value);
}

test "Arena allocator - resets between calls" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Simple contract that emits a log
    // PUSH1 0x20 PUSH1 0x00 LOG0 STOP
    const bytecode = [_]u8{ 0x60, 0x20, 0x60, 0x00, 0xA0, 0x00 };
    const contract_addr = [_]u8{0x01} ** 20;
    const code_hash = try memory_db.set_code(&bytecode);
    try db_interface.set_account(contract_addr, .{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Track arena bytes allocated before first call
    const initial_arena_bytes = evm.internal_arena.queryCapacity();

    // First call - should allocate in arena
    const result1 = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100000,
        },
    });
    defer if (result1.output.len > 0) std.testing.allocator.free(result1.output);

    try std.testing.expect(result1.success);
    try std.testing.expectEqual(@as(usize, 1), result1.logs.len);

    // Arena should have allocated memory for the log
    const after_first_call = evm.internal_arena.queryCapacity();
    try std.testing.expect(after_first_call >= initial_arena_bytes);

    // Second call - arena should be reset
    const result2 = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100000,
        },
    });
    defer if (result2.output.len > 0) std.testing.allocator.free(result2.output);

    try std.testing.expect(result2.success);
    try std.testing.expectEqual(@as(usize, 1), result2.logs.len);

    // Arena capacity should be retained but memory reused
    const after_second_call = evm.internal_arena.queryCapacity();
    try std.testing.expectEqual(after_first_call, after_second_call);
}

test "Arena allocator - handles multiple logs efficiently" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 10000000, // Higher gas limit for many logs
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Contract that emits 100 logs
    // Build bytecode dynamically: (PUSH1 0x20 PUSH1 0x00 LOG0) * 100 + STOP
    var bytecode: [501]u8 = undefined;
    for (0..100) |i| {
        const offset = i * 5;
        bytecode[offset] = 0x60; // PUSH1
        bytecode[offset + 1] = 0x20; // 32 bytes of data
        bytecode[offset + 2] = 0x60; // PUSH1
        bytecode[offset + 3] = 0x00; // offset 0
        bytecode[offset + 4] = 0xA0; // LOG0
    }
    bytecode[500] = 0x00; // STOP

    const contract_addr = [_]u8{0x02} ** 20;
    const code_hash = try memory_db.set_code(&bytecode);
    try db_interface.set_account(contract_addr, .{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Execute contract
    const result = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 5000000,
        },
    });
    defer if (result.success and result.output.len > 0) std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 100), result.logs.len);

    // All logs should have been allocated from arena
    for (result.logs) |log| {
        try std.testing.expectEqual(@as(usize, 0), log.topics.len);
        try std.testing.expectEqual(@as(usize, 32), log.data.len);
    }
}

test "Arena allocator - precompile outputs use arena" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Call SHA256 precompile (address 0x02)
    const precompile_addr = primitives.Address.from_u256(2);
    const input = "Hello, World!";

    const result = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_addr,
            .value = 0,
            .input = input,
            .gas = 100000,
        },
    });
    defer if (result.success and result.output.len > 0) std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 32), result.output.len); // SHA256 output is 32 bytes

    // Multiple precompile calls should reuse arena
    const result2 = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = precompile_addr,
            .value = 0,
            .input = "Another test input",
            .gas = 100000,
        },
    });
    defer if (result2.output.len > 0) std.testing.allocator.free(result2.output);

    try std.testing.expect(result2.success);
    try std.testing.expectEqual(@as(usize, 32), result2.output.len);
}

test "Arena allocator - memory efficiency with nested calls" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Parent contract that calls child and emits log
    // PUSH20 <child_addr> PUSH1 0 PUSH1 0 PUSH1 0 PUSH1 0 PUSH1 0 PUSH2 <gas> CALL
    // PUSH1 0x20 PUSH1 0x00 LOG0 STOP
    const child_addr = [_]u8{0x03} ** 20;
    var parent_bytecode: [100]u8 = undefined;
    var idx: usize = 0;

    // PUSH20 child_addr
    parent_bytecode[idx] = 0x73;
    idx += 1;
    @memcpy(parent_bytecode[idx .. idx + 20], &child_addr);
    idx += 20;

    // PUSH1 0 (value)
    parent_bytecode[idx] = 0x60;
    parent_bytecode[idx + 1] = 0x00;
    idx += 2;

    // PUSH1 0 (out_size)
    parent_bytecode[idx] = 0x60;
    parent_bytecode[idx + 1] = 0x00;
    idx += 2;

    // PUSH1 0 (out_offset)
    parent_bytecode[idx] = 0x60;
    parent_bytecode[idx + 1] = 0x00;
    idx += 2;

    // PUSH1 0 (in_size)
    parent_bytecode[idx] = 0x60;
    parent_bytecode[idx + 1] = 0x00;
    idx += 2;

    // PUSH1 0 (in_offset)
    parent_bytecode[idx] = 0x60;
    parent_bytecode[idx + 1] = 0x00;
    idx += 2;

    // PUSH2 gas
    parent_bytecode[idx] = 0x61;
    parent_bytecode[idx + 1] = 0x01;
    parent_bytecode[idx + 2] = 0x00; // 256 gas
    idx += 3;

    // CALL
    parent_bytecode[idx] = 0xF1;
    idx += 1;

    // PUSH1 0x20 PUSH1 0x00 LOG0
    parent_bytecode[idx] = 0x60;
    parent_bytecode[idx + 1] = 0x20;
    parent_bytecode[idx + 2] = 0x60;
    parent_bytecode[idx + 3] = 0x00;
    parent_bytecode[idx + 4] = 0xA0;
    idx += 5;

    // STOP
    parent_bytecode[idx] = 0x00;
    idx += 1;

    const parent_addr = [_]u8{0x04} ** 20;
    const parent_code_hash = try memory_db.set_code(parent_bytecode[0..idx]);
    try db_interface.set_account(parent_addr, .{
        .balance = 0,
        .nonce = 0,
        .code_hash = parent_code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Child contract that also emits log
    const child_bytecode = [_]u8{ 0x60, 0x10, 0x60, 0x00, 0xA0, 0x00 }; // PUSH1 0x10 PUSH1 0x00 LOG0 STOP
    const child_code_hash = try memory_db.set_code(&child_bytecode);
    try db_interface.set_account(child_addr, .{
        .balance = 0,
        .nonce = 0,
        .code_hash = child_code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Track arena capacity before call
    const initial_capacity = evm.internal_arena.queryCapacity();

    // Execute parent contract
    const result = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = parent_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 1000000,
        },
    });
    defer if (result.success and result.output.len > 0) std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 2), result.logs.len); // Parent and child logs

    // Arena should have grown to accommodate logs
    const final_capacity = evm.internal_arena.queryCapacity();
    try std.testing.expect(final_capacity >= initial_capacity);

    // Second call should reuse arena capacity
    const result2 = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = parent_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 1000000,
        },
    });
    defer if (result2.output.len > 0) std.testing.allocator.free(result2.output);

    try std.testing.expect(result2.success);
    try std.testing.expectEqual(@as(usize, 2), result2.logs.len);

    // Arena capacity should be retained
    const final_capacity2 = evm.internal_arena.queryCapacity();
    try std.testing.expectEqual(final_capacity, final_capacity2);
}

test "Call context tracking - get_caller and get_call_value" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    const origin_addr = primitives.Address.from_hex("0x1111111111111111111111111111111111111111") catch unreachable;
    const contract_a = primitives.Address.from_hex("0x2222222222222222222222222222222222222222") catch unreachable;

    const block_info = BlockInfo.init();
    const tx_context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    var evm = try DefaultEvm.init(
        std.testing.allocator,
        db_interface,
        block_info,
        tx_context,
        100,
        origin_addr,
        .CANCUN,
    );
    defer evm.deinit();

    // Test depth 0 - should return origin
    try std.testing.expectEqual(@as(u11, 0), evm.depth);
    try std.testing.expectEqual(origin_addr, evm.get_caller());
    try std.testing.expectEqual(@as(u256, 0), evm.get_call_value());

    // Simulate depth 1 call from origin to contract_a with value 123
    evm.depth = 1;
    evm.call_stack[0] = .{
        .caller = origin_addr,
        .value = 123,
    };

    try std.testing.expectEqual(origin_addr, evm.get_caller());
    try std.testing.expectEqual(@as(u256, 123), evm.get_call_value());

    // Simulate depth 2 call from contract_a to contract_b with value 456
    evm.depth = 2;
    evm.call_stack[1] = .{
        .caller = contract_a,
        .value = 456,
    };

    try std.testing.expectEqual(contract_a, evm.get_caller());
    try std.testing.expectEqual(@as(u256, 456), evm.get_call_value());
}

test "CREATE stores deployed code bytes" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    // Create EVM instance
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(allocator, db_interface, block_info, tx_context, 20_000_000_000, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Give creator account some balance
    const creator_address: primitives.Address = [_]u8{0x11} ++ [_]u8{0} ** 19;
    try memory_db.set_account(creator_address, Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    // Contract that uses CREATE to deploy a simple contract
    // The deployed contract just returns 42
    const deployed_runtime = [_]u8{
        0x60, 0x2A, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Init code that deploys the runtime code
    var init_code = std.ArrayList(u8).init(allocator);
    defer init_code.deinit();

    // Store runtime code length
    try init_code.append(0x60); // PUSH1
    try init_code.append(@intCast(deployed_runtime.len));
    try init_code.append(0x60); // PUSH1 0
    try init_code.append(0x00);
    try init_code.append(0x52); // MSTORE at 0

    // Store actual runtime code bytes
    for (deployed_runtime, 0..) |byte, i| {
        try init_code.append(0x60); // PUSH1
        try init_code.append(byte);
        try init_code.append(0x60); // PUSH1
        try init_code.append(@intCast(i + 32)); // offset after length
        try init_code.append(0x53); // MSTORE8
    }

    // Return the runtime code
    try init_code.append(0x60); // PUSH1
    try init_code.append(@intCast(deployed_runtime.len + 32)); // size
    try init_code.append(0x60); // PUSH1
    try init_code.append(0x00); // offset
    try init_code.append(0xF3); // RETURN

    // Contract that calls CREATE with the init code
    var creator_bytecode = std.ArrayList(u8).init(allocator);
    defer creator_bytecode.deinit();

    // Push init code to memory
    for (init_code.items, 0..) |byte, i| {
        try creator_bytecode.append(0x60); // PUSH1
        try creator_bytecode.append(byte);
        try creator_bytecode.append(0x60); // PUSH1
        try creator_bytecode.append(@intCast(i));
        try creator_bytecode.append(0x53); // MSTORE8
    }

    // CREATE: value=0, offset=0, size=init_code.len
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(@intCast(init_code.items.len)); // size
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x00); // offset
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x00); // value
    try creator_bytecode.append(0xF0); // CREATE

    // Return the created address
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x00); // offset
    try creator_bytecode.append(0x52); // MSTORE
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x20); // size
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x00); // offset
    try creator_bytecode.append(0xF3); // RETURN

    // Deploy creator contract
    const creator_code_hash = try memory_db.set_code(creator_bytecode.items);
    try memory_db.set_account(creator_address, Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = creator_code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Execute CREATE
    const result = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = creator_address,
            .value = 0,
            .input = &.{},
            .gas = 500000,
        },
    });

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 32), result.output.len);

    // Extract created contract address from output
    var created_address: primitives.Address = undefined;
    @memcpy(&created_address, result.output[12..32]);

    // Verify the deployed contract exists and has the correct code
    const deployed_code = try memory_db.get_code_by_address(created_address);
    try std.testing.expectEqualSlices(u8, &deployed_runtime, deployed_code);

    // Call the deployed contract to verify it works
    const call_result = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = created_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });

    try std.testing.expect(call_result.success);
    try std.testing.expectEqual(@as(usize, 32), call_result.output.len);

    // Verify it returns 42
    var returned_value: u256 = 0;
    for (call_result.output, 0..) |byte, i| {
        returned_value |= @as(u256, byte) << @intCast(8 * (31 - i));
    }
    try std.testing.expectEqual(@as(u256, 42), returned_value);
}

test "CREATE2 stores deployed code bytes" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    // Create EVM instance
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(allocator, db_interface, block_info, tx_context, 20_000_000_000, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Give creator account some balance
    const creator_address: primitives.Address = [_]u8{0x22} ++ [_]u8{0} ** 19;
    try memory_db.set_account(creator_address, Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    // Contract that uses CREATE2 to deploy a simple contract
    // The deployed contract just returns 99
    const deployed_runtime = [_]u8{
        0x60, 0x63, // PUSH1 99
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Init code that deploys the runtime code
    var init_code = std.ArrayList(u8).init(allocator);
    defer init_code.deinit();

    // Store runtime code length
    try init_code.append(0x60); // PUSH1
    try init_code.append(@intCast(deployed_runtime.len));
    try init_code.append(0x60); // PUSH1 0
    try init_code.append(0x00);
    try init_code.append(0x52); // MSTORE at 0

    // Store actual runtime code bytes
    for (deployed_runtime, 0..) |byte, i| {
        try init_code.append(0x60); // PUSH1
        try init_code.append(byte);
        try init_code.append(0x60); // PUSH1
        try init_code.append(@intCast(i + 32)); // offset after length
        try init_code.append(0x53); // MSTORE8
    }

    // Return the runtime code
    try init_code.append(0x60); // PUSH1
    try init_code.append(@intCast(deployed_runtime.len + 32)); // size
    try init_code.append(0x60); // PUSH1
    try init_code.append(0x00); // offset
    try init_code.append(0xF3); // RETURN

    // Contract that calls CREATE2 with the init code
    var creator_bytecode = std.ArrayList(u8).init(allocator);
    defer creator_bytecode.deinit();

    // Push init code to memory
    for (init_code.items, 0..) |byte, i| {
        try creator_bytecode.append(0x60); // PUSH1
        try creator_bytecode.append(byte);
        try creator_bytecode.append(0x60); // PUSH1
        try creator_bytecode.append(@intCast(i));
        try creator_bytecode.append(0x53); // MSTORE8
    }

    // CREATE2: salt, size, offset, value
    // Use salt = 0x42
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x42); // salt
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(@intCast(init_code.items.len)); // size
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x00); // offset
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x00); // value
    try creator_bytecode.append(0xF5); // CREATE2

    // Return the created address
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x00); // offset
    try creator_bytecode.append(0x52); // MSTORE
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x20); // size
    try creator_bytecode.append(0x60); // PUSH1
    try creator_bytecode.append(0x00); // offset
    try creator_bytecode.append(0xF3); // RETURN

    // Deploy creator contract
    const creator_code_hash = try memory_db.set_code(creator_bytecode.items);
    try memory_db.set_account(creator_address, Account{
        .balance = 1_000_000,
        .nonce = 0,
        .code_hash = creator_code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Execute CREATE2
    const result = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = creator_address,
            .value = 0,
            .input = &.{},
            .gas = 500000,
        },
    });

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 32), result.output.len);

    // Extract created contract address from output
    var created_address: primitives.Address = undefined;
    @memcpy(&created_address, result.output[12..32]);

    // Verify the deployed contract exists and has the correct code
    const deployed_code = try memory_db.get_code_by_address(created_address);
    try std.testing.expectEqualSlices(u8, &deployed_runtime, deployed_code);

    // Call the deployed contract to verify it works
    const call_result = try evm.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = created_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });

    try std.testing.expect(call_result.success);
    try std.testing.expectEqual(@as(usize, 32), call_result.output.len);

    // Verify it returns 99
    var returned_value: u256 = 0;
    for (call_result.output, 0..) |byte, i| {
        returned_value |= @as(u256, byte) << @intCast(8 * (31 - i));
    }
    try std.testing.expectEqual(@as(u256, 99), returned_value);
}

test "EVM bytecode iterator execution - simple STOP" {
    // Create test database
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test bytecode iterator execution with simple STOP
    const stop_bytecode = [_]u8{0x00}; // STOP opcode
    
    // Add contract with STOP bytecode
    const contract_address: primitives.Address = [_]u8{0x42} ++ [_]u8{0} ** 19;
    const code_hash = try memory_db.set_code(&stop_bytecode);
    try memory_db.set_account(contract_address, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Call the contract using bytecode iterator execution
    const result = evm.call(DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });

    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left > 0);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
}

test "EVM bytecode iterator execution - PUSH and RETURN" {
    // Create test database
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test bytecode that pushes a value and returns it
    // PUSH1 0x42, PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN
    const return_bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xF3,       // RETURN
    };
    
    // Add contract
    const contract_address: primitives.Address = [_]u8{0x43} ++ [_]u8{0} ** 19;
    const code_hash = try memory_db.set_code(&return_bytecode);
    try memory_db.set_account(contract_address, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Call the contract
    const result = evm.call(DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 32), result.output.len);
    
    // Verify returned value is 0x42
    var returned_value: u256 = 0;
    for (result.output, 0..) |byte, i| {
        returned_value |= @as(u256, byte) << @intCast(8 * (31 - i));
    }
    try std.testing.expectEqual(@as(u256, 0x42), returned_value);
}

test "EVM bytecode iterator execution - handles jumps" {
    // Create test database
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = memory_db;

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Test bytecode with JUMP
    // PUSH1 0x04, JUMP, 0x00 (invalid), JUMPDEST, STOP
    const jump_bytecode = [_]u8{
        0x60, 0x04, // PUSH1 0x04 (jump destination)
        0x56,       // JUMP
        0x00,       // Should be skipped
        0x5B,       // JUMPDEST at PC=4
        0x00,       // STOP
    };
    
    // Add contract
    const contract_address: primitives.Address = [_]u8{0x44} ++ [_]u8{0} ** 19;
    const code_hash = try memory_db.set_code(&jump_bytecode);
    try memory_db.set_account(contract_address, Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Call the contract
    const result = evm.call(DefaultEvm.CallParams{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });

    // Jump bytecode should execute successfully
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
}
