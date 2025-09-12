//! Tests for LOG opcode topic order correctness
//! 
//! These tests verify that LOG opcodes maintain correct topic order when
//! emitting logs. Topics should be emitted in the same order they were pushed
//! to the stack, but the current implementation has a bug that reverses them.

const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

const Evm = evm.Evm;
const Database = evm.Database;
const CallParams = evm.CallParams;
const Address = primitives.Address.Address;
const BlockInfo = evm.BlockInfo;
const TransactionContext = evm.TransactionContext;

test "LOG2 topic order correctness" {
    const allocator = testing.allocator;
    
    // Create database
    var database = Database.init(allocator);
    defer database.deinit();
    
    // Create block info and transaction context
    const block_info = BlockInfo{
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
    const tx_context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    // Create caller account with balance
    const caller_address = Address.from_hex("0x1234567890123456789012345678901234567890") catch unreachable;
    const caller_account = evm.Account{
        .balance = 1_000_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
        .delegated_address = null,
    };
    try database.set_account(caller_address.bytes, caller_account);
    
    // Create contract address
    const contract_address = Address.from_hex("0xc0ffeebabedeadbeefcafebabe0123456789abcd") catch unreachable;
    
    // Create bytecode that emits LOG2 with two topics
    // Stack setup: PUSH1 0xBB, PUSH1 0xAA, PUSH1 0, PUSH1 0, LOG2
    // Expected log topics: [0xAA, 0xBB] (0xAA as topic0, 0xBB as topic1)
    const bytecode = [_]u8{
        0x60, 0xBB,  // PUSH1 0xBB (will become topic1 after LIFO pop)
        0x60, 0xAA,  // PUSH1 0xAA (will become topic0 after LIFO pop)
        0x60, 0x00,  // PUSH1 0 (data length)
        0x60, 0x00,  // PUSH1 0 (data offset)
        0xa2,        // LOG2
        0x00,        // STOP
    };
    
    // Set contract code
    const code_hash = try database.set_code(&bytecode);
    const contract_account = evm.Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .delegated_address = null,
    };
    try database.set_account(contract_address.bytes, contract_account);
    
    // Create EVM instance
    var evm_instance = try Evm(.{}).init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address,
        .CANCUN
    );
    defer evm_instance.deinit();
    
    // Execute the contract
    const call_params = CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 100_000,
        },
    };
    
    var result = evm_instance.call(call_params);
    defer result.deinit(allocator);
    
    // Verify execution succeeded
    try testing.expect(result.success);
    
    // Check emitted logs
    try testing.expectEqual(@as(usize, 1), result.logs.len);
    
    const log = result.logs[0];
    try testing.expectEqual(contract_address, log.address);
    try testing.expectEqual(@as(usize, 2), log.topics.len);
    
    // Verify correct topic order
    try testing.expectEqual(@as(u256, 0xAA), log.topics[0]); // topic0
    try testing.expectEqual(@as(u256, 0xBB), log.topics[1]); // topic1
}

test "LOG3 topic order correctness" {
    const allocator = testing.allocator;
    
    // Create database
    var database = Database.init(allocator);
    defer database.deinit();
    
    // Create block info and transaction context
    const block_info = BlockInfo{
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
    const tx_context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    // Create caller account
    const caller_address = Address.from_hex("0x1234567890123456789012345678901234567890") catch unreachable;
    const caller_account = evm.Account{
        .balance = 1_000_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
        .delegated_address = null,
    };
    try database.set_account(caller_address.bytes, caller_account);
    
    // Create contract address
    const contract_address = Address.from_hex("0xc0ffeebabedeadbeefcafebabe0123456789abcd") catch unreachable;
    
    // Create bytecode that emits LOG3 with three topics
    // Stack setup: PUSH1 0x33, PUSH1 0x22, PUSH1 0x11, PUSH1 0, PUSH1 0, LOG3
    // Expected log topics: [0x11, 0x22, 0x33]
    const bytecode = [_]u8{
        0x60, 0x33,  // PUSH1 0x33 (will become topic2 after LIFO pop)
        0x60, 0x22,  // PUSH1 0x22 (will become topic1 after LIFO pop)
        0x60, 0x11,  // PUSH1 0x11 (will become topic0 after LIFO pop)
        0x60, 0x00,  // PUSH1 0 (data length)
        0x60, 0x00,  // PUSH1 0 (data offset)
        0xa3,        // LOG3
        0x00,        // STOP
    };
    
    // Set contract code
    const code_hash = try database.set_code(&bytecode);
    const contract_account = evm.Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .delegated_address = null,
    };
    try database.set_account(contract_address.bytes, contract_account);
    
    // Create EVM instance
    var evm_instance = try Evm(.{}).init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address,
        .CANCUN
    );
    defer evm_instance.deinit();
    
    // Execute the contract
    const call_params = CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 100_000,
        },
    };
    
    var result = evm_instance.call(call_params);
    defer result.deinit(allocator);
    
    // Verify execution succeeded
    try testing.expect(result.success);
    
    // Check emitted logs
    try testing.expectEqual(@as(usize, 1), result.logs.len);
    
    const log = result.logs[0];
    try testing.expectEqual(contract_address, log.address);
    try testing.expectEqual(@as(usize, 3), log.topics.len);
    
    // Verify correct topic order
    try testing.expectEqual(@as(u256, 0x11), log.topics[0]); // topic0
    try testing.expectEqual(@as(u256, 0x22), log.topics[1]); // topic1
    try testing.expectEqual(@as(u256, 0x33), log.topics[2]); // topic2
}

test "LOG4 topic order with Transfer event" {
    const allocator = testing.allocator;
    
    // Create database
    var database = Database.init(allocator);
    defer database.deinit();
    
    // Create block info and transaction context
    const block_info = BlockInfo{
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
    const tx_context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    // Create caller account
    const caller_address = Address.from_hex("0x1234567890123456789012345678901234567890") catch unreachable;
    const caller_account = evm.Account{
        .balance = 1_000_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
        .delegated_address = null,
    };
    try database.set_account(caller_address.bytes, caller_account);
    
    // Create contract address
    const contract_address = Address.from_hex("0xc0ffeebabedeadbeefcafebabe0123456789abcd") catch unreachable;
    
    // Simulate a Transfer event: Transfer(address indexed from, address indexed to, uint256 value)
    // Expected topic order:
    // topics[0] = Transfer event signature hash (first pushed)
    // topics[1] = from address (second pushed)  
    // topics[2] = to address (third pushed)
    // topics[3] = extra topic (fourth pushed)
    // data = value in memory (not indexed)
    
    // Create bytecode with LOG4 and data in memory
    const bytecode = [_]u8{
        // Store value (100) in memory at position 0
        0x60, 0x64,  // PUSH1 100 (value)
        0x60, 0x00,  // PUSH1 0 (memory position)
        0x52,        // MSTORE
        
        // Push topics in reverse order (due to LIFO stack)
        0x60, 0xCC,  // PUSH1 0xCC (will become topic3 after LIFO pop)
        0x60, 0xBB,  // PUSH1 0xBB (will become topic2 after LIFO pop)
        0x60, 0xAA,  // PUSH1 0xAA (will become topic1 after LIFO pop)
        
        0x7f, 0xdd, 0xf2, 0x52, 0xad, 0x1b, 0xe2, 0xc8, 0x9b, // PUSH32 Transfer signature (topic0)
        0x69, 0xc2, 0xb0, 0x68, 0xfc, 0x37, 0x8d, 0xaa,
        0x95, 0x2b, 0xa7, 0xf1, 0x63, 0xc4, 0xa1, 0x16,
        0x28, 0xf5, 0x5a, 0x4d, 0xf5, 0x23, 0xb3, 0xef,
        
        0x60, 0x20,  // PUSH1 32 (data length - the value)
        0x60, 0x00,  // PUSH1 0 (data offset)
        0xa4,        // LOG4
        0x00,        // STOP
    };
    
    // Set contract code
    const code_hash = try database.set_code(&bytecode);
    const contract_account = evm.Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .delegated_address = null,
    };
    try database.set_account(contract_address.bytes, contract_account);
    
    // Create EVM instance
    var evm_instance = try Evm(.{}).init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address,
        .CANCUN
    );
    defer evm_instance.deinit();
    
    // Execute the contract
    const call_params = CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 100_000,
        },
    };
    
    var result = evm_instance.call(call_params);
    defer result.deinit(allocator);
    
    // Verify execution succeeded
    try testing.expect(result.success);
    
    // Check emitted logs
    try testing.expectEqual(@as(usize, 1), result.logs.len);
    
    const log = result.logs[0];
    try testing.expectEqual(contract_address, log.address);
    try testing.expectEqual(@as(usize, 4), log.topics.len);
    
    // Verify correct topic order
    const expected_sig: u256 = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;
    try testing.expectEqual(expected_sig, log.topics[0]); // Transfer event signature (topic0)
    try testing.expectEqual(@as(u256, 0xAA), log.topics[1]); // From address (topic1)
    try testing.expectEqual(@as(u256, 0xBB), log.topics[2]); // To address (topic2)
    try testing.expectEqual(@as(u256, 0xCC), log.topics[3]); // Extra topic (topic3)
}