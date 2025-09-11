const std = @import("std");
const evm = @import("evm");
const testing = std.testing;
const primitives = @import("primitives");
const Address = primitives.Address;

test "SELFDESTRUCT records should be tracked in CallResult" {
    const allocator = testing.allocator;
    
    // Set up addresses
    const contract_addr = Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
    const beneficiary = Address.fromHex("0xabcdefabcdefabcdefabcdefabcdefabcdefabcd") catch unreachable;
    const caller_address = Address.fromHex("0x1111111111111111111111111111111111111111") catch unreachable;

    // Create EVM database
    var database = evm.Database.init(allocator);
    defer database.deinit();
    
    // Create block info and transaction context
    const block_info = evm.BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1_000_000_000,
        .prev_randao = [_]u8{0} ** 32,
        .chain_id = 1,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };

    // Create transaction context
    const tx_context = evm.TransactionContext{
        .gas_limit = 100_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    
    // Create EVM instance with LONDON hardfork (pre-EIP-6780)
    var evm_instance = try evm.Evm(.{}).init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address,
        .LONDON
    );
    defer evm_instance.deinit();
    
    // Create bytecode: PUSH20 beneficiary, SELFDESTRUCT
    const bytecode = [_]u8{0x73} ++ beneficiary.bytes ++ [_]u8{0xff};
    
    // Store bytecode and get code hash
    const code_hash = try database.set_code(&bytecode);
    
    // Deploy contract with balance and the bytecode
    try database.set_account(contract_addr.bytes, .{
        .balance = 1000,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Verify the code was stored
    const retrieved_code = try database.get_code_by_address(contract_addr.bytes);
    try testing.expect(retrieved_code.len == bytecode.len);

    // Create caller account with balance
    const caller_account = evm.Account{
        .balance = 1_000_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
        .delegated_address = null,
    };
    try database.set_account(caller_address.bytes, caller_account);
    
    // Execute call to trigger SELFDESTRUCT
    const call_params = evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100_000,
        },
    };
    
    const result = evm_instance.call(call_params);
    defer if (result.selfdestructs.len > 0) allocator.free(result.selfdestructs);
    
    // Verify the call succeeded
    try testing.expect(result.success);
    
    // Verify SELFDESTRUCT records are properly tracked:
    try testing.expect(result.selfdestructs.len == 1);
    try testing.expect(std.mem.eql(u8, &result.selfdestructs[0].contract.bytes, &contract_addr.bytes));
    try testing.expect(std.mem.eql(u8, &result.selfdestructs[0].beneficiary.bytes, &beneficiary.bytes));
}

test "SELFDESTRUCT multiple contracts in single call" {
    const allocator = testing.allocator;
    
    // Set up addresses
    const contract1_addr = Address.fromHex("0x1111111111111111111111111111111111111111") catch unreachable;
    const contract2_addr = Address.fromHex("0x2222222222222222222222222222222222222222") catch unreachable;
    const beneficiary1 = Address.fromHex("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") catch unreachable;
    const beneficiary2 = Address.fromHex("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") catch unreachable;
    const caller_address = Address.fromHex("0x9999999999999999999999999999999999999999") catch unreachable;

    // Create EVM database
    var database = evm.Database.init(allocator);
    defer database.deinit();

    // Create block info and transaction context
    const block_info = evm.BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1_000_000_000,
        .prev_randao = [_]u8{0} ** 32,
        .chain_id = 1,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };
    const tx_context = evm.TransactionContext{
        .gas_limit = 100_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    // Create EVM instance with LONDON hardfork (pre-EIP-6780)
    var evm_instance = try evm.Evm(.{}).init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address,
        .LONDON
    );
    defer evm_instance.deinit();
    
    // Create bytecode for contract1: PUSH20 beneficiary1, SELFDESTRUCT
    const bytecode1 = [_]u8{0x73} ++ beneficiary1.bytes ++ [_]u8{0xff};
    
    // Create bytecode for contract2: PUSH20 beneficiary2, SELFDESTRUCT  
    const bytecode2 = [_]u8{0x73} ++ beneficiary2.bytes ++ [_]u8{0xff};
    
    // Store bytecode and get code hashes
    const code_hash1 = try database.set_code(&bytecode1);
    const code_hash2 = try database.set_code(&bytecode2);

    // Create caller account with balance
    const caller_account = evm.Account{
        .balance = 1_000_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
        .delegated_address = null,
    };
    try database.set_account(caller_address.bytes, caller_account);
    
    // Deploy both contracts
    try database.set_account(contract1_addr.bytes, .{
        .balance = 500,
        .nonce = 0,
        .code_hash = code_hash1,
        .storage_root = [_]u8{0} ** 32,
    });
    
    try database.set_account(contract2_addr.bytes, .{
        .balance = 750,
        .nonce = 0, 
        .code_hash = code_hash2,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Execute first SELFDESTRUCT
    const call_params1 = evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract1_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100_000,
        },
    };
    
    var result1 = evm_instance.call(call_params1);
    defer if (result1.selfdestructs.len > 0) allocator.free(result1.selfdestructs);

    // Execute second SELFDESTRUCT
    const call_params2 = evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract2_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100_000,
        },
    };
    
    var result2 = evm_instance.call(call_params2);
    defer if (result2.selfdestructs.len > 0) allocator.free(result2.selfdestructs);

    // Both calls should succeed
    try testing.expect(result1.success);
    try testing.expect(result2.success);
    
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

test "EIP-6780: SELFDESTRUCT only destroys contracts created in same transaction (CANCUN)" {
    const allocator = testing.allocator;
    
    // Set up addresses
    const contract_addr = Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
    const beneficiary = Address.fromHex("0xabcdefabcdefabcdefabcdefabcdefabcdefabcd") catch unreachable;
    const caller_address = Address.fromHex("0x1111111111111111111111111111111111111111") catch unreachable;

    // Create EVM database
    var database = evm.Database.init(allocator);
    defer database.deinit();
    
    // Create block info and transaction context
    const block_info = evm.BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1_000_000_000,
        .prev_randao = [_]u8{0} ** 32,
        .chain_id = 1,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };
    const tx_context = evm.TransactionContext{
        .gas_limit = 100_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    // Create EVM instance with CANCUN hardfork (EIP-6780 enabled)
    var evm_instance = try evm.Evm(.{}).init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address,
        .CANCUN
    );
    defer evm_instance.deinit();
    
    // Create bytecode: PUSH20 beneficiary, SELFDESTRUCT
    const bytecode = [_]u8{0x73} ++ beneficiary.bytes ++ [_]u8{0xff};
    
    // Store bytecode and get code hash
    const code_hash = try database.set_code(&bytecode);
    
    // Deploy contract with balance (pre-existing contract, NOT created in transaction)
    try database.set_account(contract_addr.bytes, .{
        .balance = 1000,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    // Create caller account with balance
    const caller_account = evm.Account{
        .balance = 1_000_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
        .delegated_address = null,
    };
    try database.set_account(caller_address.bytes, caller_account);
    
    // Execute call to trigger SELFDESTRUCT
    const call_params = evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_addr,
            .value = 0,
            .input = &[_]u8{},
            .gas = 100_000,
        },
    };
    
    const result = evm_instance.call(call_params);
    defer if (result.selfdestructs.len > 0) allocator.free(result.selfdestructs);
    
    // Verify the call succeeded
    try testing.expect(result.success);
    
    // With EIP-6780 (CANCUN), pre-existing contracts are NOT marked for destruction
    // Only the balance is transferred
    try testing.expectEqual(@as(usize, 0), result.selfdestructs.len);
    
    // Verify balance was transferred
    const contract_account = try database.get_account(contract_addr.bytes);
    const beneficiary_account = try database.get_account(beneficiary.bytes);
    try testing.expect(contract_account.?.balance == 0);
    try testing.expect(beneficiary_account.?.balance == 1000);
    
    // Verify contract still exists (code not deleted)
    const code = try database.get_code_by_address(contract_addr.bytes);
    try testing.expect(code.len > 0);
}