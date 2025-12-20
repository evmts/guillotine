const std = @import("std");
const testing = std.testing;
const evm_module = @import("evm");
const primitives = @import("voltaire");

test "logs are properly aggregated in CallResult" {
    const allocator = testing.allocator;
    
    // Create a simple database
    var db = evm_module.Database.init(allocator);
    defer db.deinit();
    
    // Create test contract that emits a log
    // Bytecode: PUSH1 0x00 PUSH1 0x00 LOG0 STOP
    // This emits an empty log with no topics
    const log_bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0x00 (offset)
        0x60, 0x00, // PUSH1 0x00 (length)  
        0xA0,       // LOG0
        0x00,       // STOP
    };
    
    const contract_address = primitives.Address{ .bytes = [_]u8{0x42} ++ [_]u8{0} ** 19 };
    const code_hash = try db.set_code(&log_bytecode);
    try db.set_account(contract_address.bytes, evm_module.Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Create EVM instance
    const block_info = evm_module.BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    
    const tx_context = evm_module.TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm = try evm_module.Evm(.{}).init(
        allocator, 
        &db, 
        block_info, 
        tx_context, 
        0, 
        primitives.Address.ZERO_ADDRESS, 
        .BERLIN
    );
    defer evm.deinit();
    
    // Call the contract
    const call_params = evm_module.CallParams{
        .call = .{
            .caller = primitives.Address.ZERO_ADDRESS,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    };
    
    const result = evm.call(call_params);
    defer {
        // Clean up the result's allocated memory
        var mutable_result = result;
        mutable_result.deinit(allocator);
    }
    
    // Verify the call succeeded
    try testing.expect(result.success);
    
    // Verify we got exactly one log
    try testing.expectEqual(@as(usize, 1), result.logs.len);
    
    // Verify the log came from the correct contract
    const log_entry = result.logs[0];
    try testing.expectEqual(contract_address, log_entry.address);
    
    // Verify it's a LOG0 (no topics)
    try testing.expectEqual(@as(usize, 0), log_entry.topics.len);
    
    // Verify empty data
    try testing.expectEqual(@as(usize, 0), log_entry.data.len);
}

test "nested call logs are properly aggregated" {
    const allocator = testing.allocator;
    
    // Create a database
    var db = evm_module.Database.init(allocator);
    defer db.deinit();
    
    // Create contract A that emits LOG0 then calls contract B
    // Contract A bytecode:
    // PUSH1 0x00 PUSH1 0x00 LOG0  // Emit log from A
    // PUSH1 0x00 PUSH1 0x00 PUSH1 0x00 PUSH1 0x00 PUSH1 0x00 PUSH20 <address_b> PUSH2 0x1000 CALL
    // STOP
    const contract_a_address = primitives.Address{ .bytes = [_]u8{0xAA} ++ [_]u8{0} ** 19 };
    const contract_b_address = primitives.Address{ .bytes = [_]u8{0xBB} ++ [_]u8{0} ** 19 };
    
    var contract_a_bytecode = std.ArrayList(u8).init(allocator);
    defer contract_a_bytecode.deinit();
    
    // Emit LOG0 from contract A
    try contract_a_bytecode.appendSlice(&[_]u8{
        0x60, 0x00, // PUSH1 0x00 (offset)
        0x60, 0x00, // PUSH1 0x00 (length)
        0xA0,       // LOG0
    });
    
    // Call contract B
    try contract_a_bytecode.appendSlice(&[_]u8{
        0x60, 0x00, // PUSH1 0x00 (output size)
        0x60, 0x00, // PUSH1 0x00 (output offset)
        0x60, 0x00, // PUSH1 0x00 (input size)
        0x60, 0x00, // PUSH1 0x00 (input offset)
        0x60, 0x00, // PUSH1 0x00 (value)
        0x73,       // PUSH20 (address)
    });
    try contract_a_bytecode.appendSlice(&contract_b_address.bytes);
    try contract_a_bytecode.appendSlice(&[_]u8{
        0x61, 0x10, 0x00, // PUSH2 0x1000 (gas)
        0xF1,             // CALL
        0x50,             // POP (discard result)
        0x00,             // STOP
    });
    
    // Contract B just emits a LOG1
    const contract_b_bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0x00 (offset)
        0x60, 0x00, // PUSH1 0x00 (length)
        0x60, 0x42, // PUSH1 0x42 (topic)
        0xA1,       // LOG1
        0x00,       // STOP
    };
    
    // Store both contracts
    const code_hash_a = try db.set_code(contract_a_bytecode.items);
    try db.set_account(contract_a_address.bytes, evm_module.Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash_a,
        .storage_root = [_]u8{0} ** 32,
    });
    
    const code_hash_b = try db.set_code(&contract_b_bytecode);
    try db.set_account(contract_b_address.bytes, evm_module.Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash_b,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Create EVM instance
    const block_info = evm_module.BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    
    const tx_context = evm_module.TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm = try evm_module.Evm(.{}).init(
        allocator, 
        &db, 
        block_info, 
        tx_context, 
        0, 
        primitives.Address.ZERO_ADDRESS, 
        .BERLIN
    );
    defer evm.deinit();
    
    // Call contract A (which will call contract B)
    const call_params = evm_module.CallParams{
        .call = .{
            .caller = primitives.Address.ZERO_ADDRESS,
            .to = contract_a_address,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    };
    
    const result = evm.call(call_params);
    defer {
        // Clean up the result's allocated memory
        var mutable_result = result;
        mutable_result.deinit(allocator);
    }
    
    // Verify the call succeeded
    try testing.expect(result.success);
    
    // We should have 2 logs total: one from A, one from B
    try testing.expectEqual(@as(usize, 2), result.logs.len);
    
    // First log should be from contract A (LOG0)
    try testing.expectEqual(contract_a_address, result.logs[0].address);
    try testing.expectEqual(@as(usize, 0), result.logs[0].topics.len);
    
    // Second log should be from contract B (LOG1 with topic 0x42)
    try testing.expectEqual(contract_b_address, result.logs[1].address);
    try testing.expectEqual(@as(usize, 1), result.logs[1].topics.len);
    try testing.expectEqual(@as(u256, 0x42), result.logs[1].topics[0]);
}