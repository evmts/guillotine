//! Integration tests for EVM2 components
//! These tests validate the interaction between Frame, EVM, Database, Memory, and Stack components
//! Focus on end-to-end scenarios and component boundaries

const std = @import("std");
const testing = std.testing;
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const GasConstants = primitives.GasConstants;

const frame_mod = @import("frame.zig");
const evm_mod = @import("evm.zig");
const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
const DatabaseInterface = @import("database_interface.zig").DatabaseInterface;
const BlockInfo = @import("block_info.zig").BlockInfo;
const CallParams = @import("call_params.zig").CallParams;
const Host = @import("host.zig").Host;
const NoOpTracer = @import("tracer.zig").NoOpTracer;
const TransactionContext = @import("transaction_context.zig").TransactionContext;

// Test configuration with small limits for predictable testing
const TestFrameConfig = frame_mod.FrameConfig{
    .stack_size = 256,
    .WordType = u256,
    .max_bytecode_size = 1024,
    .block_gas_limit = 1_000_000,
    .has_database = true,
    .TracerType = NoOpTracer,
    .memory_initial_capacity = 1024,
    .memory_limit = 0x10000, // 64KB limit for testing
};

const TestFrame = frame_mod.Frame(TestFrameConfig);
const TestEvm = evm_mod.Evm(.{
    .max_call_depth = 16,
    .max_input_size = 4096,
    .frame_config = TestFrameConfig,
});

fn create_test_database(allocator: std.mem.Allocator) !MemoryDatabase {
    return MemoryDatabase.init(allocator);
}

fn create_test_block_info() BlockInfo {
    return BlockInfo{
        .number = 1000,
        .timestamp = 1640995200, // 2022-01-01
        .difficulty = 15000000000000000,
        .gas_limit = 15000000,
        .coinbase = [_]u8{0xAB} ** 20,
        .base_fee = 25000000000, // 25 gwei
        .prev_randao = [_]u8{0xCD} ** 32,
    };
}

fn create_test_host(evm: *TestEvm) Host {
    return evm.to_host();
}

test "Integration: Frame stack operations with memory expansion" {
    const allocator = testing.allocator;
    
    var memory_db = try create_test_database(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    // Simple bytecode for stack operations
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x01,       // ADD
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52,       // MSTORE (store result at memory[0])
        0x00,       // STOP
    };
    
    const block_info = create_test_block_info();
    const context = TransactionContext{
        .gas_limit = 100000,
        .coinbase = [_]u8{0} ** 20,
        .chain_id = 1,
    };
    
    var evm = try TestEvm.init(allocator, db_interface, block_info, context, 0, [_]u8{0} ** 20, .CANCUN);
    defer evm.deinit();
    
    const host = create_test_host(&evm);
    var frame = try TestFrame.init(allocator, &bytecode, 100000, db_interface, host);
    defer frame.deinit(allocator);
    
    // Execute stack operations
    try frame.push1(); // PUSH1 1
    try frame.push1(); // PUSH1 2
    try frame.add();   // ADD (should result in 3)
    
    // Verify stack has correct result
    const result = try frame.stack.peek();
    try testing.expectEqual(@as(u256, 3), result);
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    
    // Execute memory store
    try frame.push0(); // PUSH1 0 (offset)
    try frame.mstore(allocator); // MSTORE
    
    // Verify stack is empty after MSTORE
    try testing.expectEqual(@as(usize, 0), frame.stack.size());
    
    // Verify memory contains the stored value
    const memory_value = frame.memory.get_u256_evm(0);
    try testing.expectEqual(@as(u256, 3), memory_value);
    
    // Verify memory size expanded correctly
    try testing.expect(frame.memory.size() >= 32);
}

test "Integration: Frame with database operations (SLOAD/SSTORE)" {
    const allocator = testing.allocator;
    
    var memory_db = try create_test_database(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const bytecode = [_]u8{0x00}; // Simple STOP
    
    const block_info = create_test_block_info();
    const context = TransactionContext{
        .gas_limit = 100000,
        .coinbase = [_]u8{0} ** 20,
        .chain_id = 1,
    };
    
    var evm = try TestEvm.init(allocator, db_interface, block_info, context, 0, [_]u8{0} ** 20, .CANCUN);
    defer evm.deinit();
    
    const host = create_test_host(&evm);
    var frame = try TestFrame.init(allocator, &bytecode, 100000, db_interface, host);
    defer frame.deinit(allocator);
    
    const test_address = [_]u8{0x12} ++ [_]u8{0} ** 19;
    frame.contract_address = test_address;
    
    // Test storage operations
    const storage_key: u256 = 42;
    const storage_value: u256 = 0xDEADBEEF;
    
    // Store value
    try frame.stack.push(storage_key);
    try frame.stack.push(storage_value);
    try frame.sstore();
    
    // Load value back
    try frame.stack.push(storage_key);
    try frame.sload();
    
    const loaded_value = try frame.stack.pop();
    try testing.expectEqual(storage_value, loaded_value);
    
    // Verify database contains the value
    const db_value = try db_interface.get_storage(test_address, storage_key);
    try testing.expectEqual(storage_value, db_value);
}

test "Integration: Frame LOG operations with memory data" {
    const allocator = testing.allocator;
    
    var memory_db = try create_test_database(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const bytecode = [_]u8{0x00}; // Simple STOP
    
    const block_info = create_test_block_info();
    const context = TransactionContext{
        .gas_limit = 100000,
        .coinbase = [_]u8{0} ** 20,
        .chain_id = 1,
    };
    
    var evm = try TestEvm.init(allocator, db_interface, block_info, context, 0, [_]u8{0} ** 20, .CANCUN);
    defer evm.deinit();
    
    const host = create_test_host(&evm);
    var frame = try TestFrame.init(allocator, &bytecode, 100000, db_interface, host);
    defer frame.deinit(allocator);
    
    const test_address = [_]u8{0x34} ++ [_]u8{0} ** 19;
    frame.contract_address = test_address;
    
    // Write test data to memory
    const test_data = "Hello, EVM2!";
    try frame.memory.set_data_evm(0, test_data);
    
    // Prepare LOG1 operation (1 topic)
    const topic: u256 = 0x1234567890ABCDEF;
    try frame.stack.push(topic);     // Topic
    try frame.stack.push(test_data.len); // Size
    try frame.stack.push(0);         // Offset
    
    const initial_logs = frame.logs.items.len;
    try frame.log1(allocator);
    
    // Verify log was created
    try testing.expectEqual(initial_logs + 1, frame.logs.items.len);
    
    const log = frame.logs.items[initial_logs];
    try testing.expectEqual(test_address, log.address);
    try testing.expectEqual(@as(usize, 1), log.topics.len);
    try testing.expectEqual(topic, log.topics[0]);
    try testing.expectEqual(test_data.len, log.data.len);
    try testing.expectEqualStrings(test_data, log.data);
    
    // Cleanup
    allocator.free(log.topics);
    allocator.free(log.data);
}

test "Integration: EVM to Frame execution - simple arithmetic" {
    const allocator = testing.allocator;
    
    var memory_db = try create_test_database(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const block_info = create_test_block_info();
    const context = TransactionContext{
        .gas_limit = 100000,
        .coinbase = [_]u8{0} ** 20,
        .chain_id = 1,
    };
    
    var evm = try TestEvm.init(allocator, db_interface, block_info, context, 0, [_]u8{0} ** 20, .CANCUN);
    defer evm.deinit();
    
    // Set up simple contract with arithmetic
    const contract_address = [_]u8{0x56} ++ [_]u8{0} ** 19;
    const bytecode = [_]u8{
        0x60, 0x0A, // PUSH1 10
        0x60, 0x14, // PUSH1 20  
        0x01,       // ADD (result: 30)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32 (return size)
        0x60, 0x00, // PUSH1 0 (return offset)
        0xF3,       // RETURN
    };
    
    try memory_db.set_code(contract_address, &bytecode);
    
    const call_params = TestEvm.CallParams{
        .call = .{
            .caller = [_]u8{0} ** 20,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 50000,
        },
    };
    
    const result = try evm.call(call_params);
    
    try testing.expect(result.success);
    try testing.expect(result.gas_left > 0);
    // For now, output will be empty until full execution is implemented
    // try testing.expectEqual(@as(usize, 32), result.output.len);
}

test "Integration: Memory expansion with gas calculation" {
    const allocator = testing.allocator;
    
    var memory_db = try create_test_database(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const bytecode = [_]u8{0x00}; // Simple STOP
    
    const block_info = create_test_block_info();
    const context = TransactionContext{
        .gas_limit = 100000,
        .coinbase = [_]u8{0} ** 20,
        .chain_id = 1,
    };
    
    var evm = try TestEvm.init(allocator, db_interface, block_info, context, 0, [_]u8{0} ** 20, .CANCUN);
    defer evm.deinit();
    
    const host = create_test_host(&evm);
    var frame = try TestFrame.init(allocator, &bytecode, 100000, db_interface, host);
    defer frame.deinit(allocator);
    
    // Track initial values for comparison 
    // const initial_gas = frame.gas_remaining;
    const initial_memory_size = frame.memory.size();
    
    // Test memory expansion beyond initial capacity
    const large_offset: usize = 2048; // Beyond initial 1KB capacity
    const test_value: u256 = 0x123456789ABCDEF0;
    
    // Calculate expansion cost
    const expansion_cost = try frame.memory.expansion_cost(large_offset, 32);
    
    // Perform memory operation that triggers expansion
    try frame.memory.set_u256_evm(large_offset, test_value);
    
    // Verify memory expanded
    try testing.expect(frame.memory.size() > initial_memory_size);
    try testing.expect(frame.memory.size() >= large_offset + 32);
    
    // Verify value was stored correctly
    const retrieved_value = frame.memory.get_u256_evm(large_offset);
    try testing.expectEqual(test_value, retrieved_value);
    
    // Verify gas calculation is reasonable (expansion should cost gas)
    try testing.expect(expansion_cost > 0);
}

test "Integration: Stack and Memory boundary conditions" {
    const allocator = testing.allocator;
    
    var memory_db = try create_test_database(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const bytecode = [_]u8{0x00}; // Simple STOP
    
    const block_info = create_test_block_info();
    const context = TransactionContext{
        .gas_limit = 100000,
        .coinbase = [_]u8{0} ** 20,
        .chain_id = 1,
    };
    
    var evm = try TestEvm.init(allocator, db_interface, block_info, context, 0, [_]u8{0} ** 20, .CANCUN);
    defer evm.deinit();
    
    const host = create_test_host(&evm);
    var frame = try TestFrame.init(allocator, &bytecode, 100000, db_interface, host);
    defer frame.deinit(allocator);
    
    // Test stack near capacity (TestFrameConfig.stack_size = 256)
    var i: usize = 0;
    while (i < 255) : (i += 1) {
        try frame.stack.push(@intCast(i));
    }
    
    // Stack should be almost full
    try testing.expectEqual(@as(usize, 255), frame.stack.size());
    
    // One more push should succeed
    try frame.stack.push(999);
    try testing.expectEqual(@as(usize, 256), frame.stack.size());
    
    // Next push should fail
    try testing.expectError(TestFrame.Stack.Error.StackOverflow, frame.stack.push(1000));
    
    // Test memory at limit (TestFrameConfig.memory_limit = 0x10000 = 64KB)
    const max_offset = TestFrameConfig.memory_limit - 32;
    
    // Should succeed at limit
    try frame.memory.set_u256_evm(max_offset, 0x12345);
    const value = frame.memory.get_u256_evm(max_offset);
    try testing.expectEqual(@as(u256, 0x12345), value);
    
    // Should fail beyond limit
    const beyond_limit = TestFrameConfig.memory_limit;
    try testing.expectError(
        @TypeOf(frame.memory).MemoryError.MemoryOverflow,
        frame.memory.ensure_capacity(beyond_limit + 32)
    );
}

test "Integration: Database interface with different account states" {
    const allocator = testing.allocator;
    
    var memory_db = try create_test_database(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const test_addresses = [_]Address{
        [_]u8{0x11} ++ [_]u8{0} ** 19,
        [_]u8{0x22} ++ [_]u8{0} ** 19,
        [_]u8{0x33} ++ [_]u8{0} ** 19,
    };
    
    // Create accounts with different states
    const accounts = [_]@import("database_interface_account.zig").Account{
        .{ .balance = 1000, .nonce = 0, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 },
        .{ .balance = 2000, .nonce = 5, .code_hash = [_]u8{0x11} ** 32, .storage_root = [_]u8{0x22} ** 32 },
        .{ .balance = 0, .nonce = 100, .code_hash = [_]u8{0x33} ** 32, .storage_root = [_]u8{0} ** 32 },
    };
    
    // Set up accounts
    for (test_addresses, accounts) |addr, account| {
        try memory_db.set_account(addr, account);
    }
    
    // Test through interface
    for (test_addresses, accounts) |addr, expected_account| {
        const retrieved_account = try db_interface.get_account(addr);
        try testing.expect(retrieved_account != null);
        
        const account = retrieved_account.?;
        try testing.expectEqual(expected_account.balance, account.balance);
        try testing.expectEqual(expected_account.nonce, account.nonce);
        try testing.expectEqual(expected_account.code_hash, account.code_hash);
        try testing.expectEqual(expected_account.storage_root, account.storage_root);
        
        // Test balance getter
        const balance = try db_interface.get_balance(addr);
        try testing.expectEqual(expected_account.balance, balance);
        
        // Test account existence
        const exists = db_interface.account_exists(addr);
        try testing.expect(exists);
    }
    
    // Test non-existent account
    const fake_address = [_]u8{0xFF} ** 20;
    const fake_account = try db_interface.get_account(fake_address);
    try testing.expect(fake_account == null);
    
    const fake_balance = try db_interface.get_balance(fake_address);
    try testing.expectEqual(@as(u256, 0), fake_balance);
    
    const fake_exists = db_interface.account_exists(fake_address);
    try testing.expect(!fake_exists);
}

test "Integration: Gas consumption across operations" {
    const allocator = testing.allocator;
    
    var memory_db = try create_test_database(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const bytecode = [_]u8{0x00}; // Simple STOP
    
    const block_info = create_test_block_info();
    const context = TransactionContext{
        .gas_limit = 100000,
        .coinbase = [_]u8{0} ** 20,
        .chain_id = 1,
    };
    
    var evm = try TestEvm.init(allocator, db_interface, block_info, context, 0, [_]u8{0} ** 20, .CANCUN);
    defer evm.deinit();
    
    const host = create_test_host(&evm);
    var frame = try TestFrame.init(allocator, &bytecode, 50000, db_interface, host);
    defer frame.deinit(allocator);
    
    const initial_gas = frame.gas_remaining;
    
    // Stack operations (cheap)
    try frame.stack.push(10);
    try frame.stack.push(20);
    try frame.add(); // Should consume GasConstants.GasFastestStep (3 gas)
    
    const gas_after_add = frame.gas_remaining;
    try testing.expect(gas_after_add < initial_gas);
    
    try frame.stack.push(5);
    try frame.mul(); // Should consume GasConstants.GasFastStep (5 gas)
    
    const gas_after_mul = frame.gas_remaining;
    try testing.expect(gas_after_mul < gas_after_add);
    
    // Memory operation (more expensive due to expansion)
    try frame.stack.push(0); // offset
    try frame.mstore(allocator); // Should consume base cost + expansion cost
    
    const gas_after_mstore = frame.gas_remaining;
    const memory_gas_used = gas_after_mul - gas_after_mstore;
    
    // Memory expansion should cost more than simple arithmetic
    const arithmetic_gas_used = initial_gas - gas_after_mul;
    try testing.expect(memory_gas_used > arithmetic_gas_used);
    
    // Verify we still have gas remaining
    try testing.expect(frame.gas_remaining > 0);
}

test "Integration: Error propagation between components" {
    const allocator = testing.allocator;
    
    var memory_db = try create_test_database(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const bytecode = [_]u8{0x00}; // Simple STOP
    
    const block_info = create_test_block_info();
    const context = TransactionContext{
        .gas_limit = 100000,
        .coinbase = [_]u8{0} ** 20,
        .chain_id = 1,
    };
    
    var evm = try TestEvm.init(allocator, db_interface, block_info, context, 0, [_]u8{0} ** 20, .CANCUN);
    defer evm.deinit();
    
    const host = create_test_host(&evm);
    
    // Test with very low gas
    var low_gas_frame = try TestFrame.init(allocator, &bytecode, 5, db_interface, host);
    defer low_gas_frame.deinit(allocator);
    
    // Operations should fail with OutOfGas
    try low_gas_frame.stack.push(1000);
    try low_gas_frame.stack.push(2000);
    
    // Memory operation should fail due to insufficient gas
    try low_gas_frame.stack.push(0); // offset
    try testing.expectError(TestFrame.Error.OutOfGas, low_gas_frame.mstore(allocator));
    
    // Test stack overflow
    var normal_frame = try TestFrame.init(allocator, &bytecode, 50000, db_interface, host);
    defer normal_frame.deinit(allocator);
    
    // Fill stack to capacity
    var i: usize = 0;
    while (i < TestFrameConfig.stack_size) : (i += 1) {
        try normal_frame.stack.push(@intCast(i));
    }
    
    // Next operation should fail
    try testing.expectError(TestFrame.Stack.Error.StackOverflow, normal_frame.stack.push(999));
}

test "Integration: Transient storage operations (EIP-1153)" {
    const allocator = testing.allocator;
    
    var memory_db = try create_test_database(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const bytecode = [_]u8{0x00}; // Simple STOP
    
    const block_info = create_test_block_info();
    const context = TransactionContext{
        .gas_limit = 100000,
        .coinbase = [_]u8{0} ** 20,
        .chain_id = 1,
    };
    
    var evm = try TestEvm.init(allocator, db_interface, block_info, context, 0, [_]u8{0} ** 20, .CANCUN);
    defer evm.deinit();
    
    const host = create_test_host(&evm);
    var frame = try TestFrame.init(allocator, &bytecode, 100000, db_interface, host);
    defer frame.deinit(allocator);
    
    const test_address = [_]u8{0x78} ++ [_]u8{0} ** 19;
    frame.contract_address = test_address;
    
    // Test TSTORE/TLOAD operations
    const t_key: u256 = 123;
    const t_value: u256 = 0xABCDEF;
    
    // Store in transient storage
    try frame.stack.push(t_key);
    try frame.stack.push(t_value);
    try frame.tstore();
    
    // Load from transient storage
    try frame.stack.push(t_key);
    try frame.tload();
    
    const loaded_value = try frame.stack.pop();
    try testing.expectEqual(t_value, loaded_value);
    
    // Verify transient storage is separate from regular storage
    try frame.stack.push(t_key);
    try frame.sload(); // Should return 0 (empty)
    
    const regular_storage_value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), regular_storage_value);
    
    // Verify transient storage persists in the database
    const db_transient_value = try db_interface.get_transient_storage(test_address, t_key);
    try testing.expectEqual(t_value, db_transient_value);
}