const std = @import("std");
const guillotine_evm = @import("evm");
const testing = std.testing;

test "simple PUSH32 execution" {
    const allocator = testing.allocator;
    
    // Simple PUSH32 bytecode that pushes -8
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xf8, // -8
        0x00, // STOP
    };
    
    // Create EVM and run
    var db = try allocator.create(guillotine_evm.Database);
    defer allocator.destroy(db);
    db.* = guillotine_evm.Database.init(allocator);
    defer db.deinit();
    
    const address = [_]u8{0} ** 20;
    const caller_address = [_]u8{1} ** 20;
    
    const tx_context = guillotine_evm.TransactionContext{
        .gas_limit = 1_000_000,
        .origin = caller_address,
        .gas_price = 0,
        .block_info = .{
            .basefee = 0,
            .coinbase = address,
            .prevrandao = [_]u8{0} ** 32,
            .gas_limit = 30_000_000,
            .number = 0,
            .timestamp = 0,
            .excess_blob_gas = 0,
            .blob_basefee = 0,
        },
        .blob_hashes = &[_][32]u8{},
    };
    
    const evm = try guillotine_evm.Evm(.{}).init(allocator, db, tx_context);
    defer evm.deinit();
    
    const call_params = guillotine_evm.CallParams{
        .code_address = address,
        .msg_sender = caller_address,
        .contract_address = address,
        .value = 0,
        .calldata = &[_]u8{},
        .gas_limit = 100_000,
        .is_static = false,
    };
    
    // Deploy the bytecode to the database
    var account = guillotine_evm.Database.Account{
        .balance = 0,
        .nonce = 0,
        .code = try allocator.dupe(u8, &bytecode),
        .code_hash = undefined,
    };
    
    // Calculate code hash
    const keccak = @import("crypto").Keccak256;
    var hasher = keccak.init(.{});
    hasher.update(&bytecode);
    hasher.final(&account.code_hash);
    
    try db.set_account(address, account);
    
    // Execute the bytecode
    const result = try evm.call(call_params);
    
    // Check result - after PUSH32 and STOP, we should have success
    try testing.expect(result.status == .success);
    std.debug.print("\nPUSH32 test result: success={}, gas_used={}, output_len={}\n", .{
        result.status == .success,
        result.gas_used,
        result.output.len,
    });
}

test "PUSH32 + PUSH1 + SDIV execution" {
    const allocator = testing.allocator;
    
    // PUSH32 (-8) + PUSH1 (3) + SDIV bytecode
    const bytecode = [_]u8{
        0x7f, // PUSH32
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xf8, // -8
        0x60, 0x03, // PUSH1 3
        0x05,       // SDIV
        0x00,       // STOP
    };
    
    // Create EVM and run
    var db = try allocator.create(guillotine_evm.Database);
    defer allocator.destroy(db);
    db.* = guillotine_evm.Database.init(allocator);
    defer db.deinit();
    
    const address = [_]u8{0} ** 20;
    const caller_address = [_]u8{1} ** 20;
    
    const tx_context = guillotine_evm.TransactionContext{
        .gas_limit = 1_000_000,
        .origin = caller_address,
        .gas_price = 0,
        .block_info = .{
            .basefee = 0,
            .coinbase = address,
            .prevrandao = [_]u8{0} ** 32,
            .gas_limit = 30_000_000,
            .number = 0,
            .timestamp = 0,
            .excess_blob_gas = 0,
            .blob_basefee = 0,
        },
        .blob_hashes = &[_][32]u8{},
    };
    
    const evm = try guillotine_evm.Evm(.{}).init(allocator, db, tx_context);
    defer evm.deinit();
    
    const call_params = guillotine_evm.CallParams{
        .code_address = address,
        .msg_sender = caller_address,
        .contract_address = address,
        .value = 0,
        .calldata = &[_]u8{},
        .gas_limit = 100_000,
        .is_static = false,
    };
    
    // Deploy the bytecode to the database
    var account = guillotine_evm.Database.Account{
        .balance = 0,
        .nonce = 0,
        .code = try allocator.dupe(u8, &bytecode),
        .code_hash = undefined,
    };
    
    // Calculate code hash
    const keccak = @import("crypto").Keccak256;
    var hasher = keccak.init(.{});
    hasher.update(&bytecode);
    hasher.final(&account.code_hash);
    
    try db.set_account(address, account);
    
    // Execute the bytecode
    const result = try evm.call(call_params);
    
    // Check result - after PUSH32, PUSH1, SDIV and STOP
    std.debug.print("\nSDIV test result: success={}, error={s}, gas_used={}, output_len={}\n", .{
        result.status == .success,
        @tagName(result.status),
        result.gas_used,
        result.output.len,
    });
    
    try testing.expect(result.status == .success);
}