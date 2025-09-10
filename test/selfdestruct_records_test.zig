const std = @import("std");
const guillotine_evm = @import("evm");
const testing = std.testing;
const primitives = @import("primitives");
const Address = primitives.Address;

test "SELFDESTRUCT records should be tracked in CallResult" {
    const allocator = testing.allocator;
    
    // Create EVM database
    var db = try allocator.create(guillotine_evm.Database);
    defer allocator.destroy(db);
    db.* = guillotine_evm.Database.init(allocator);
    defer db.deinit();
    
    // Set up addresses
    const contract_addr = Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
    const beneficiary = Address.fromHex("0xabcdefabcdefabcdefabcdefabcdefabcdefabcd") catch unreachable;
    const caller_address = Address.fromHex("0x1111111111111111111111111111111111111111") catch unreachable;
    
    // Create bytecode: PUSH20 beneficiary, SELFDESTRUCT
    const bytecode = [_]u8{0x73} ++ beneficiary.bytes ++ [_]u8{0xff};
    
    // Store bytecode and get code hash
    const code_hash = try db.set_code(&bytecode);
    
    // Deploy contract with balance and the bytecode
    try db.set_account(contract_addr.bytes, .{
        .balance = 1000,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Set up transaction context
    const tx_context = guillotine_evm.TransactionContext{
        .gas_limit = 1_000_000,
        .origin = caller_address,
        .gas_price = 0,
        .block_info = .{
            .basefee = 0,
            .coinbase = caller_address,
            .prevrandao = [_]u8{0} ** 32,
            .gas_limit = 30_000_000,
            .number = 1,
            .timestamp = 1000,
            .excess_blob_gas = 0,
            .blob_basefee = 0,
        },
        .blob_hashes = &[_][32]u8{},
    };
    
    // Initialize EVM
    const evm = try guillotine_evm.Evm(.{}).init(allocator, db, tx_context);
    defer evm.deinit();
    
    // Execute call to trigger SELFDESTRUCT
    const call_params = guillotine_evm.CallParams{
        .code_address = contract_addr.bytes,
        .msg_sender = caller_address.bytes,
        .contract_address = contract_addr.bytes,
        .value = 0,
        .calldata = &[_]u8{},
        .gas_limit = 100_000,
        .is_static = false,
    };
    
    var result = try evm.call(call_params);
    defer result.deinit(allocator);
    
    // Verify the call succeeded
    try testing.expect(result.status == .success);
    
    // This is the main assertion that should demonstrate the issue
    // Currently this will fail because selfdestructs is always empty
    // After fixing, it should pass
    std.debug.print("\nSELFDESTRUCT test result: success={}, selfdestructs_len={}\n", .{
        result.status == .success,
        result.selfdestructs.len,
    });
    
    // The fix should make these assertions pass:
    try testing.expect(result.selfdestructs.len == 1);
    try testing.expect(std.mem.eql(u8, &result.selfdestructs[0].contract.bytes, &contract_addr.bytes));
    try testing.expect(std.mem.eql(u8, &result.selfdestructs[0].beneficiary.bytes, &beneficiary.bytes));
}

test "SELFDESTRUCT multiple contracts in single call" {
    const allocator = testing.allocator;
    
    // Create EVM database
    var db = try allocator.create(guillotine_evm.Database);
    defer allocator.destroy(db);
    db.* = guillotine_evm.Database.init(allocator);
    defer db.deinit();
    
    // Set up addresses
    const contract1_addr = Address.fromHex("0x1111111111111111111111111111111111111111") catch unreachable;
    const contract2_addr = Address.fromHex("0x2222222222222222222222222222222222222222") catch unreachable;
    const beneficiary1 = Address.fromHex("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") catch unreachable;
    const beneficiary2 = Address.fromHex("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") catch unreachable;
    const caller_address = Address.fromHex("0x9999999999999999999999999999999999999999") catch unreachable;
    
    // Create bytecode for contract1: PUSH20 beneficiary1, SELFDESTRUCT
    const bytecode1 = [_]u8{0x73} ++ beneficiary1.bytes ++ [_]u8{0xff};
    
    // Create bytecode for contract2: PUSH20 beneficiary2, SELFDESTRUCT  
    const bytecode2 = [_]u8{0x73} ++ beneficiary2.bytes ++ [_]u8{0xff};
    
    // Store bytecode and get code hashes
    const code_hash1 = try db.set_code(&bytecode1);
    const code_hash2 = try db.set_code(&bytecode2);
    
    // Deploy both contracts
    try db.set_account(contract1_addr.bytes, .{
        .balance = 500,
        .nonce = 0,
        .code_hash = code_hash1,
        .storage_root = [_]u8{0} ** 32,
    });
    
    try db.set_account(contract2_addr.bytes, .{
        .balance = 750,
        .nonce = 0, 
        .code_hash = code_hash2,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Set up transaction context
    const tx_context = guillotine_evm.TransactionContext{
        .gas_limit = 1_000_000,
        .origin = caller_address,
        .gas_price = 0,
        .block_info = .{
            .basefee = 0,
            .coinbase = caller_address,
            .prevrandao = [_]u8{0} ** 32,
            .gas_limit = 30_000_000,
            .number = 1,
            .timestamp = 1000,
            .excess_blob_gas = 0,
            .blob_basefee = 0,
        },
        .blob_hashes = &[_][32]u8{},
    };
    
    // Initialize EVM
    const evm = try guillotine_evm.Evm(.{}).init(allocator, db, tx_context);
    defer evm.deinit();
    
    // Execute first SELFDESTRUCT
    const call_params1 = guillotine_evm.CallParams{
        .code_address = contract1_addr.bytes,
        .msg_sender = caller_address.bytes,
        .contract_address = contract1_addr.bytes,
        .value = 0,
        .calldata = &[_]u8{},
        .gas_limit = 100_000,
        .is_static = false,
    };
    
    var result1 = try evm.call(call_params1);
    defer result1.deinit(allocator);
    
    // Execute second SELFDESTRUCT
    const call_params2 = guillotine_evm.CallParams{
        .code_address = contract2_addr.bytes,
        .msg_sender = caller_address.bytes,
        .contract_address = contract2_addr.bytes,
        .value = 0,
        .calldata = &[_]u8{},
        .gas_limit = 100_000,
        .is_static = false,
    };
    
    var result2 = try evm.call(call_params2);
    defer result2.deinit(allocator);
    
    // Both calls should succeed
    try testing.expect(result1.status == .success);
    try testing.expect(result2.status == .success);
    
    std.debug.print("\nMultiple SELFDESTRUCT test: result1_selfdestructs={}, result2_selfdestructs={}\n", .{
        result1.selfdestructs.len,
        result2.selfdestructs.len,
    });
    
    // Each result should have exactly one self-destruct record
    try testing.expect(result1.selfdestructs.len == 1);
    try testing.expect(result2.selfdestructs.len == 1);
    
    // Verify the first call's self-destruct record
    try testing.expect(std.mem.eql(u8, &result1.selfdestructs[0].contract.bytes, &contract1_addr.bytes));
    try testing.expect(std.mem.eql(u8, &result1.selfdestructs[0].beneficiary.bytes, &beneficiary1.bytes));
    
    // Verify the second call's self-destruct record  
    try testing.expect(std.mem.eql(u8, &result2.selfdestructs[0].contract.bytes, &contract2_addr.bytes));
    try testing.expect(std.mem.eql(u8, &result2.selfdestructs[0].beneficiary.bytes, &beneficiary2.bytes));
}