const std = @import("std");
const evm_mod = @import("evm.zig");
const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
const DatabaseInterface = @import("database_interface.zig").DatabaseInterface;
const BlockInfo = @import("block_info.zig").DefaultBlockInfo;
const TransactionContext = @import("transaction_context.zig").TransactionContext;
const Account = @import("database_interface_account.zig").Account;
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const ZERO_ADDRESS = primitives.ZERO_ADDRESS;

test "CREATE uses IR interpreter for init code" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try evm_mod.DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    // Set up caller
    const caller_address: Address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    try memory_db.set_account(caller_address, Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    // Init code that uses storage operations (which IR interpreter now supports)
    const init_code = [_]u8{
        // Store value 42 at key 0
        0x60, 0x2A, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE
        
        // Return runtime code
        0x60, 0x01, // PUSH1 1 (size)
        0x60, 0x0F, // PUSH1 15 (offset)
        0xF3,       // RETURN
        
        // Runtime code at offset 15:
        0x00,       // STOP
    };

    const create_params = evm_mod.DefaultEvm.CallParams{
        .create = .{
            .caller = caller_address,
            .value = 0,
            .init_code = &init_code,
            .gas = 200000,
        },
    };

    const result = try evm.call(create_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    // Verify success
    try std.testing.expect(result.success);
    
    const contract_address: Address = result.output[12..32].*;
    
    // Verify storage was set (proving IR interpreter executed SSTORE)
    const stored_value = try memory_db.get_storage(contract_address, 0);
    try std.testing.expectEqual(@as(u256, 42), stored_value);
}

test "CREATE2 uses IR interpreter for init code" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try evm_mod.DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const caller_address: Address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    try memory_db.set_account(caller_address, Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    // Init code with arithmetic operations (which IR interpreter now supports)
    const init_code = [_]u8{
        // Calculate 10 + 5 and store at key 0
        0x60, 0x0A, // PUSH1 10
        0x60, 0x05, // PUSH1 5
        0x01,       // ADD
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE
        
        // Return empty code
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };

    const salt: u256 = 0xDEADBEEF;

    const create2_params = evm_mod.DefaultEvm.CallParams{
        .create2 = .{
            .caller = caller_address,
            .value = 0,
            .init_code = &init_code,
            .salt = salt,
            .gas = 200000,
        },
    };

    const result = try evm.call(create2_params);
    defer if (result.output.len > 0) evm.allocator.free(result.output);

    try std.testing.expect(result.success);
    
    const contract_address: Address = result.output[12..32].*;
    
    // Verify arithmetic was performed (proving IR interpreter executed ADD)
    const stored_value = try memory_db.get_storage(contract_address, 0);
    try std.testing.expectEqual(@as(u256, 15), stored_value);
}

test "IR interpreter handles complex init code with jumps" {
    var memory_db = MemoryDatabase.init(std.testing.allocator);
    defer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);

    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try evm_mod.DefaultEvm.init(std.testing.allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();

    const caller_address: Address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    try memory_db.set_account(caller_address, Account{
        .balance = 1000000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    // Init code with conditional jump
    const init_code = [_]u8{
        // Push 1 (true condition)
        0x60, 0x01, // PUSH1 1
        // Push jump destination
        0x60, 0x0A, // PUSH1 10
        // Jump if true
        0x57,       // JUMPI
        
        // This should be skipped
        0x60, 0xFF, // PUSH1 255
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE
        
        // Jump destination (offset 10)
        0x5B,       // JUMPDEST
        // Store 42 at key 0
        0x60, 0x2A, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE
        
        // Return empty
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };

    const create_params = evm_mod.DefaultEvm.CallParams{
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
    
    const contract_address: Address = result.output[12..32].*;
    
    // Verify jump worked correctly - should store 42, not 255
    const stored_value = try memory_db.get_storage(contract_address, 0);
    try std.testing.expectEqual(@as(u256, 42), stored_value);
}