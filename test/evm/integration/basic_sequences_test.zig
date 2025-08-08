const std = @import("std");
const testing = std.testing;

// Import EVM components directly
const evm = @import("evm");
const primitives = @import("primitives");
const CallParams = evm.Host.CallParams;
const CallResult = evm.CallResult;
// Updated to new API - migration in progress, tests not run yet
const MemoryDatabase = evm.MemoryDatabase;
const Frame = evm.Frame;
const Contract = evm.Contract;
const Address = primitives.Address;
const Operation = evm.Operation;
const ExecutionError = evm.ExecutionError;
const opcodes = evm.opcodes;

// Test basic arithmetic sequences
test "Integration: arithmetic calculation sequence" {
    const allocator = testing.allocator;

    // Initialize memory database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer vm.deinit();

    // Create a test contract
    const contract_addr = Address.from_u256(0x3333333333333333333333333333333333333333);
    const caller_addr = Address.from_u256(0x1111111111111111111111111111111111111111);

    var contract = Contract.init(
        caller_addr,
        contract_addr,
        0,
        1_000_000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Simulate: (5 + 3) * 2 - 1 = 15

    // Push values
    try frame.stack.append(5);
    try frame.stack.append(3);

    // Execute opcodes through jump table
    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = &frame;

    // ADD: 5 + 3 = 8
    _ = try vm.table.execute(0, interpreter, state, 0x01);
    const add_result = frame.stack.peek_n(0) catch unreachable;
    try testing.expectEqual(@as(u256, 8), add_result);

    // Push 2 and multiply
    try frame.stack.append(2);
    _ = try vm.table.execute(0, interpreter, state, 0x02);
    const mul_result = frame.stack.peek_n(0) catch unreachable;
    try testing.expectEqual(@as(u256, 16), mul_result);

    // Push 1 and subtract
    try frame.stack.append(1);
    _ = try vm.table.execute(0, interpreter, state, 0x03);

    // Final result
    const final_result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 15), final_result);
    try testing.expectEqual(@as(usize, 0), frame.stack.size);
}

// Test stack manipulation sequences
test "Integration: stack manipulation with DUP and SWAP" {
    const allocator = testing.allocator;

    // Initialize memory database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer vm.deinit();

    // Create a test contract
    const contract_addr = Address.from_u256(0x3333333333333333333333333333333333333333);
    const caller_addr = Address.from_u256(0x1111111111111111111111111111111111111111);

    var contract = Contract.init(
        caller_addr,
        contract_addr,
        0,
        1_000_000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Push initial values
    try frame.stack.append(10);
    try frame.stack.append(20);
    try frame.stack.append(30);

    // Stack: [10, 20, 30] (top is 30)

    // Execute opcodes through jump table
    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = &frame;

    // DUP2 - duplicate second item
    _ = try vm.table.execute(0, interpreter, state, 0x81);

    // Stack: [10, 20, 30, 20]
    try testing.expectEqual(@as(u256, 20), frame.stack.peek_n(0) catch unreachable);
    try testing.expectEqual(@as(u256, 30), frame.stack.peek_n(1) catch unreachable);

    // SWAP1 - swap top two
    _ = try vm.table.execute(0, interpreter, state, 0x90);

    // Stack: [10, 20, 20, 30]
    try testing.expectEqual(@as(u256, 30), frame.stack.peek_n(0) catch unreachable);
    try testing.expectEqual(@as(u256, 20), frame.stack.peek_n(1) catch unreachable);

    // ADD top two
    _ = try vm.table.execute(0, interpreter, state, 0x01);

    // Stack: [10, 20, 50]
    try testing.expectEqual(@as(u256, 50), frame.stack.peek_n(0) catch unreachable);

    // Clean up
    _ = try frame.stack.pop();
    _ = try frame.stack.pop();
    _ = try frame.stack.pop();
}

// Test memory and storage interaction
test "Integration: memory to storage workflow" {
    const allocator = testing.allocator;

    // Initialize memory database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer vm.deinit();

    // Create a test contract
    const contract_addr = Address.from_u256(0x3333333333333333333333333333333333333333);
    const caller_addr = Address.from_u256(0x1111111111111111111111111111111111111111);

    var contract = Contract.init(
        caller_addr,
        contract_addr,
        0,
        1_000_000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Execute opcodes through jump table
    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = &frame;

    // Store value in memory
    const test_value: u256 = 0x123456789ABCDEF;
    try frame.stack.append(32); // offset
    try frame.stack.append(test_value);

    _ = try vm.table.execute(0, interpreter, state, 0x52);

    // Load from memory
    try frame.stack.append(32); // offset
    _ = try vm.table.execute(0, interpreter, state, 0x51);

    // Store in storage slot 5 - SSTORE expects [value, key] with key on top
    try frame.stack.append(5); // slot (key)
    _ = try vm.table.execute(0, interpreter, state, 0x55);

    // Load from storage
    try frame.stack.append(5); // slot
    _ = try vm.table.execute(0, interpreter, state, 0x54);

    // Verify value
    const result = try frame.stack.pop();
    try testing.expectEqual(test_value, result);
}

// Test conditional logic with JUMPI
test "Integration: conditional branching" {
    const allocator = testing.allocator;

    // Initialize memory database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer vm.deinit();

    // Create a test contract with code
    const contract_addr = Address.from_u256(0x3333333333333333333333333333333333333333);
    const caller_addr = Address.from_u256(0x1111111111111111111111111111111111111111);

    // Set up contract code with jump destinations
    var code: [50]u8 = undefined;
    @memset(&code, 0x00); // Fill with STOP
    code[10] = 0x5B; // JUMPDEST at 10
    code[20] = 0x5B; // JUMPDEST at 20

    // Set code in state
    try vm.state.set_code(contract_addr, &code);

    // Calculate code hash
    var code_hash: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(&code);
    hasher.final(&code_hash);

    var contract = Contract.init(
        caller_addr,
        contract_addr,
        0,
        1_000_000,
        &code,
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Execute opcodes through jump table
    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = &frame;

    // Test 1: Jump taken (condition true)
    try frame.stack.append(100);
    try frame.stack.append(200);

    // Check if 100 < 200 (true)
    _ = try vm.table.execute(0, interpreter, state, 0x10);

    // JUMPI to 10 if true
    const condition1 = try frame.stack.pop();
    try frame.stack.append(10); // destination
    try frame.stack.append(condition1); // condition on top

    const result1 = try vm.table.execute(0, interpreter, state, 0x57);
    try testing.expectEqual(@as(?usize, 10), result1.jump_dest);

    // Test 2: Jump not taken (condition false)
    frame.pc = 0; // Reset PC
    try frame.stack.append(200);
    try frame.stack.append(100);

    // Check if 200 < 100 (false)
    _ = try vm.table.execute(0, interpreter, state, 0x10);

    // JUMPI to 20 if true (won't jump)
    const condition2 = try frame.stack.pop();
    try frame.stack.append(20); // destination
    try frame.stack.append(condition2); // condition on top

    const result2 = try vm.table.execute(0, interpreter, state, 0x57);
    try testing.expectEqual(@as(?usize, null), result2.jump_dest);
}

// Test hash calculation and comparison
test "Integration: hash and compare workflow" {
    const allocator = testing.allocator;

    // Initialize memory database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer vm.deinit();

    // Create a test contract
    const contract_addr = Address.from_u256(0x3333333333333333333333333333333333333333);
    const caller_addr = Address.from_u256(0x1111111111111111111111111111111111111111);

    var contract = Contract.init(
        caller_addr,
        contract_addr,
        0,
        1_000_000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Execute opcodes through jump table
    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = &frame;

    // Write data to memory
    const data1 = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const data2 = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const data3 = [_]u8{ 0x05, 0x06, 0x07, 0x08 };

    // Write first data
    try frame.memory.set_data(0, &data1);

    // Hash first data
    try frame.stack.append(0); // offset
    try frame.stack.append(4); // length
    _ = try vm.table.execute(0, interpreter, state, 0x20);

    const hash1 = frame.stack.peek_n(0) catch unreachable;

    // Write second data (same as first)
    try frame.memory.set_data(100, &data2);

    // Hash second data
    try frame.stack.append(100); // offset
    try frame.stack.append(4); // length
    _ = try vm.table.execute(0, interpreter, state, 0x20);

    // Compare hashes (should be equal)
    _ = try vm.table.execute(0, interpreter, state, 0x14);
    const eq_result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), eq_result);

    // Write third data (different)
    try frame.memory.set_data(200, &data3);

    // Hash third data
    try frame.stack.append(hash1); // Push first hash back
    try frame.stack.append(200); // offset
    try frame.stack.append(4); // length
    _ = try vm.table.execute(0, interpreter, state, 0x20);

    // Compare hashes (should be different)
    _ = try vm.table.execute(0, interpreter, state, 0x14);
    const neq_result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), neq_result);
}

// Test call data handling
test "Integration: call data processing" {
    const allocator = testing.allocator;

    // Initialize memory database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer vm.deinit();

    // Create a test contract
    const contract_addr = Address.from_u256(0x3333333333333333333333333333333333333333);
    const caller_addr = Address.from_u256(0x1111111111111111111111111111111111111111);

    // Set up call data (function selector + parameters)
    const call_data = [_]u8{
        0xa9, 0x05, 0x9c, 0xbb, // transfer(address,uint256) selector
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x12, 0x34, 0x56, 0x78,
        0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78, // address
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xe8, // amount (1000)
    };

    var contract = Contract.init(
        caller_addr,
        contract_addr,
        0,
        1_000_000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &call_data,
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .withInput(&call_data)
        .build();
    defer frame.deinit();

    // Execute opcodes through jump table
    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = &frame;

    // Get call data size
    _ = try vm.table.execute(0, interpreter, state, 0x36);
    const size_result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, call_data.len), size_result);

    // Load function selector (first 4 bytes)
    try frame.stack.append(0); // offset
    _ = try vm.table.execute(0, interpreter, state, 0x35);

    // Extract selector by shifting right
    try frame.stack.append(224); // 256 - 32 = 224 bits
    _ = try vm.table.execute(0, interpreter, state, 0x1C);

    const selector = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0xa9059cbb), selector);

    // Load first parameter (address)
    try frame.stack.append(4); // offset past selector
    _ = try vm.table.execute(0, interpreter, state, 0x35);

    const param1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0x123456789abcdef01234567800000000000000000000000000000000), param1);

    // Load second parameter (amount)
    try frame.stack.append(36); // offset to second parameter
    _ = try vm.table.execute(0, interpreter, state, 0x35);

    const param2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1000), param2);
}

// Test gas consumption across operations
test "Integration: gas tracking through operations" {
    const allocator = testing.allocator;

    // Initialize memory database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer vm.deinit();

    // Create a test contract
    const contract_addr = Address.from_u256(0x3333333333333333333333333333333333333333);
    const caller_addr = Address.from_u256(0x1111111111111111111111111111111111111111);

    var contract = Contract.init(
        caller_addr,
        contract_addr,
        0,
        1_000_000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Execute opcodes through jump table
    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = &frame;

    // Memory operation (expansion cost)
    try frame.stack.append(1000); // Large offset causes expansion
    try frame.stack.append(0x123456);

    const gas_before_mstore = frame.gas_remaining;
    _ = try vm.table.execute(0, interpreter, state, 0x52);

    const mstore_gas = gas_before_mstore - frame.gas_remaining;
    try testing.expect(mstore_gas > 0); // Should consume gas for memory expansion

    // SHA3 operation
    try frame.stack.append(1000); // offset
    try frame.stack.append(32); // length

    const gas_before_sha3 = frame.gas_remaining;
    _ = try vm.table.execute(0, interpreter, state, 0x20);

    const sha3_gas = gas_before_sha3 - frame.gas_remaining;
    try testing.expect(sha3_gas >= 30 + 6); // Base cost + 1 word

    // Storage operation (cold access) - SSTORE expects [value, key] with key on top
    const hash_result = try frame.stack.pop(); // Pop SHA3 result
    try frame.stack.append(hash_result); // value
    try frame.stack.append(100); // slot (key)

    const gas_before_sstore = frame.gas_remaining;
    _ = try vm.table.execute(0, interpreter, state, 0x55);

    const sstore_gas = gas_before_sstore - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 2100), sstore_gas); // Cold storage access

    // Verify total gas consumed
    const total_gas_used = 10000 - frame.gas_remaining;
    try testing.expect(total_gas_used == mstore_gas + sha3_gas + sstore_gas);
}

// Test error propagation through sequences
test "Integration: error handling in sequences" {
    const allocator = testing.allocator;

    // Initialize memory database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer vm.deinit();

    // Create a test contract
    const contract_addr = Address.from_u256(0x3333333333333333333333333333333333333333);
    const caller_addr = Address.from_u256(0x1111111111111111111111111111111111111111);

    var contract = Contract.init(
        caller_addr,
        contract_addr,
        0,
        1_000_000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100)
        .build();
    defer frame.deinit();

    // Execute opcodes through jump table
    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = &frame;

    // Try sequence that will run out of gas
    try frame.stack.append(1000000); // Large value
    try frame.stack.append(1000000); // Large value

    // This should succeed
    _ = try vm.table.execute(0, interpreter, state, 0x01);

    // Try expensive operation - SHA3 with large data
    try frame.stack.append(0); // offset
    try frame.stack.append(10000); // Large length

    // Should fail with out of gas
    const result = vm.table.execute(0, interpreter, state, 0x20);
    try testing.expectError(ExecutionError.Error.OutOfGas, result);

    // Stack should still be valid
    try testing.expectEqual(@as(usize, 3), frame.stack.size); // Result from ADD + 2 values for SHA3
}

// Test transient storage workflow (EIP-1153)
test "Integration: transient storage usage" {
    const allocator = testing.allocator;

    // Initialize memory database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer vm.deinit();

    // Create a test contract
    const contract_addr = Address.from_u256(0x3333333333333333333333333333333333333333);
    const caller_addr = Address.from_u256(0x1111111111111111111111111111111111111111);

    var contract = Contract.init(
        caller_addr,
        contract_addr,
        0,
        1_000_000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    // Execute opcodes through jump table
    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = &frame;

    // Store in both regular and transient storage
    const test_value: u256 = 0xDEADBEEF;
    const slot: u256 = 42;

    // Store in regular storage - SSTORE expects [value, key] with key on top
    try frame.stack.append(test_value);
    try frame.stack.append(slot);
    _ = try vm.table.execute(0, interpreter, state, 0x55);

    // Store different value in transient storage - TSTORE expects [value, key] with key on top
    const transient_value: u256 = 0xCAFEBABE;
    try frame.stack.append(transient_value);
    try frame.stack.append(slot);
    _ = try vm.table.execute(0, interpreter, state, 0x5D);

    // Load from regular storage
    try frame.stack.append(slot);
    _ = try vm.table.execute(0, interpreter, state, 0x54);
    const regular_result = try frame.stack.pop();
    try testing.expectEqual(test_value, regular_result);

    // Load from transient storage
    try frame.stack.append(slot);
    _ = try vm.table.execute(0, interpreter, state, 0x5C);
    const transient_result = try frame.stack.pop();
    try testing.expectEqual(transient_value, transient_result);

    // Verify they are independent
    try testing.expect(regular_result != transient_result);
}
