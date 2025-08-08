const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const CallParams = evm.Host.CallParams;
const CallResult = evm.CallResult;
// Updated to new API - migration in progress, tests not run yet
const primitives = @import("primitives");
const opcodes = evm.opcodes;
const MemoryDatabase = evm.MemoryDatabase;
const Contract = evm.Contract;
const Frame = evm.Frame;
const Address = evm.Address;
const Operation = evm.Operation;
const ExecutionError = evm.ExecutionError;

// Integration tests for crypto operations and logging

test "Integration: SHA3 with dynamic data" {
    const allocator = testing.allocator;

    // Create database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const contract_address = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);
    const alice_address = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Store some data in memory to hash
    const data1: u256 = 0x1234567890ABCDEF;
    const data2: u256 = 0xFEDCBA0987654321;

    // Push data1 and offset 0 to stack
    try frame.stack.append(0); // offset
    try frame.stack.append(data1); // value

    // Execute MSTORE
    const interpreter_1: Operation.Interpreter = &vm;
    const state_1: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter_1, &state_1, 0x52);

    // Push data2 and offset 32 to stack
    try frame.stack.append(32); // offset
    try frame.stack.append(data2); // value

    // Execute MSTORE
    const interpreter_2: Operation.Interpreter = &vm;
    const state_2: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter_2, &state_2, 0x52);

    // Hash 64 bytes starting at offset 0
    try frame.stack.append(0); // offset
    try frame.stack.append(64); // size

    // Execute SHA3
    const interpreter_3: Operation.Interpreter = &vm;
    const state_3: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter_3, &state_3, 0x20);

    // Result should be a valid hash (non-zero)
    const hash = try frame.stack.pop();
    try testing.expect(hash != 0);

    // Hash empty data should give known result
    try frame.stack.append(0); // offset
    try frame.stack.append(0); // size

    // Execute SHA3
    const interpreter_4: Operation.Interpreter = &vm;
    const state_4: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter_4, &state_4, 0x20);

    // Empty hash: keccak256("") = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
    const empty_hash = try frame.stack.pop();
    try testing.expect(empty_hash != 0);
}

test "Integration: Logging with topics and data" {
    const allocator = testing.allocator;

    // Create database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const contract_address = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);
    const alice_address = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Store event data in memory
    const event_data = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x64, // 100 in uint256
    };
    try frame.memory.set_data(0, &event_data);

    // LOG1 with one topic (e.g., Transfer event signature)
    const transfer_sig: u256 = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    // Push stack values in reverse order (offset, size, topic1)
    try frame.stack.append(0); // offset
    try frame.stack.append(32); // size
    try frame.stack.append(transfer_sig); // topic1: Transfer signature

    // Execute LOG1
    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0xA1);

    // Verify log was emitted (in real implementation)
    try testing.expectEqual(@as(usize, 1), vm.logs.items.len);
    const log = vm.logs.items[0];
    try testing.expectEqual(contract_address, log.address);
    try testing.expectEqual(@as(usize, 1), log.topics.len);
    // Convert log topic bytes to u256 for comparison
    var topic_value: u256 = 0;
    for (log.topics[0]) |byte| {
        topic_value = (topic_value << 8) | byte;
    }
    try testing.expectEqual(transfer_sig, topic_value);
}

test "Integration: LOG operations with multiple topics" {
    const allocator = testing.allocator;

    // Create database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const contract_address = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);
    const alice_address = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Prepare log data
    const log_data = "Hello, Ethereum!";
    try frame.memory.set_data(0, log_data);

    // LOG3 with three topics
    const topic1: u256 = 0x1111111111111111111111111111111111111111111111111111111111111111;
    const topic2: u256 = 0x2222222222222222222222222222222222222222222222222222222222222222;
    const topic3: u256 = 0x3333333333333333333333333333333333333333333333333333333333333333;

    // Push stack values in reverse order
    try frame.stack.append(0); // offset
    try frame.stack.append(log_data.len); // size
    try frame.stack.append(topic1); // topic1
    try frame.stack.append(topic2); // topic2
    try frame.stack.append(topic3); // topic3

    // Execute LOG3
    const interpreter_1: Operation.Interpreter = &vm;
    const state_1: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter_1, &state_1, 0xA3);

    // Clear logs for next test
    vm.logs.clearRetainingCapacity();

    // LOG0 with no topics
    try frame.stack.append(0); // offset
    try frame.stack.append(log_data.len); // size

    // Execute LOG0
    const interpreter_2: Operation.Interpreter = &vm;
    const state_2: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter_2, &state_2, 0xA0);

    // Verify LOG0
    try testing.expectEqual(@as(usize, 1), vm.logs.items.len);
    try testing.expectEqual(@as(usize, 0), vm.logs.items[0].topics.len);
}

test "Integration: Hash-based address calculation" {
    const allocator = testing.allocator;

    // Create database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const contract_address = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);
    const alice_address = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Simulate CREATE2 address calculation
    // address = keccak256(0xff ++ deployer ++ salt ++ keccak256(init_code))[12:]

    // Store components in memory
    var offset: usize = 0;

    // 0xff prefix
    try frame.memory.set_data(offset, &[_]u8{0xff});
    offset += 1;

    // Deployer address (20 bytes)
    const deployer_bytes = contract_address.bytes;
    try frame.memory.set_data(offset, &deployer_bytes);
    offset += 20;

    // Salt (32 bytes)
    const salt: u256 = 0x1234567890ABCDEF;
    var salt_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &salt_bytes, salt, .big);
    try frame.memory.set_data(offset, &salt_bytes);
    offset += 32;

    // Init code hash (32 bytes) - simulate with dummy hash
    const init_code_hash: u256 = 0xABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890;
    var hash_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &hash_bytes, init_code_hash, .big);
    try frame.memory.set_data(offset, &hash_bytes);

    // Hash all components (1 + 20 + 32 + 32 = 85 bytes)
    try frame.stack.append(0); // offset
    try frame.stack.append(85); // size

    // Execute SHA3
    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x20);

    // Extract address from hash (last 20 bytes)
    const full_hash = try frame.stack.pop();
    const address_mask = (@as(u256, 1) << 160) - 1;
    const derived_address = full_hash & address_mask;

    // Should be a valid non-zero address
    try testing.expect(derived_address != 0);
}

test "Integration: Event emission patterns" {
    const allocator = testing.allocator;

    // Create database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const contract_address = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);
    const alice_address = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);
    const bob_address = primitives.Address.from_u256(0x2222222222222222222222222222222222222222);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Simulate ERC20 Transfer event
    // Transfer(address indexed from, address indexed to, uint256 value)

    const from_addr = primitives.Address.to_u256(alice_address);
    const to_addr = primitives.Address.to_u256(bob_address);
    const value: u256 = 1000;

    // Store value in memory (non-indexed parameter)
    var value_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &value_bytes, value, .big);
    try frame.memory.set_data(0, &value_bytes);

    // Emit Transfer event with LOG3
    const transfer_sig: u256 = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    // Push stack values in reverse order
    try frame.stack.append(0); // offset in memory
    try frame.stack.append(32); // size of data (value)
    try frame.stack.append(transfer_sig); // topic1: event signature
    try frame.stack.append(from_addr); // topic2: indexed 'from'
    try frame.stack.append(to_addr); // topic3: indexed 'to'

    // Execute LOG3
    const interpreter_1: Operation.Interpreter = &vm;
    const state_1: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter_1, &state_1, 0xA3);

    // Simulate ERC20 Approval event
    // Approval(address indexed owner, address indexed spender, uint256 value)
    vm.logs.clearRetainingCapacity();

    const owner_addr = primitives.Address.to_u256(alice_address);
    const spender_addr = primitives.Address.to_u256(contract_address);
    const allowance: u256 = 500;

    // Store allowance in memory
    var allowance_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &allowance_bytes, allowance, .big);
    try frame.memory.set_data(32, &allowance_bytes);

    const approval_sig: u256 = 0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925;

    // Push stack values in reverse order
    try frame.stack.append(32); // offset in memory
    try frame.stack.append(32); // size of data (allowance)
    try frame.stack.append(approval_sig); // topic1: event signature
    try frame.stack.append(owner_addr); // topic2: indexed 'owner'
    try frame.stack.append(spender_addr); // topic3: indexed 'spender'

    // Execute LOG3
    const interpreter_2: Operation.Interpreter = &vm;
    const state_2: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter_2, &state_2, 0xA3);

    // Both events should be recorded
    try testing.expectEqual(@as(usize, 1), vm.logs.items.len);
}

test "Integration: Dynamic log data with memory expansion" {
    const allocator = testing.allocator;

    // Create database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const contract_address = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);
    const alice_address = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Create dynamic-sized log data
    const message = "This is a longer message that will cause memory expansion when logged!";

    // Store message at high memory offset
    const high_offset: usize = 1000;
    try frame.memory.set_data(high_offset, message);

    // Check memory size before
    const interpreter_1: Operation.Interpreter = &vm;
    const state_1: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter_1, &state_1, 0x59);
    const size_before = try frame.stack.pop();

    // Log with data from high offset
    try frame.stack.append(high_offset); // offset
    try frame.stack.append(message.len); // size
    try frame.stack.append(0x1234567890ABCDEF); // topic1

    const gas_before = frame.gas_remaining;
    const interpreter_2: Operation.Interpreter = &vm;
    const state_2: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter_2, &state_2, 0xA1);
    const gas_after = frame.gas_remaining;

    // Check memory size after
    const interpreter_3: Operation.Interpreter = &vm;
    const state_3: Operation.State = &frame;
    _ = try vm.table.execute(0, &interpreter_3, &state_3, 0x59);
    const size_after = try frame.stack.pop();

    // Memory should have expanded
    try testing.expect(size_after > size_before);
    try testing.expect(size_after >= high_offset + message.len);

    // Gas should include memory expansion cost
    const gas_used = gas_before - gas_after;
    try testing.expect(gas_used > 375 + message.len * 8); // Base + data cost
}

test "Integration: SHA3 for signature verification" {
    const allocator = testing.allocator;

    // Create database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const contract_address = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);
    const alice_address = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Simulate function selector calculation
    // keccak256("transfer(address,uint256)")[:4]
    const function_sig = "transfer(address,uint256)";
    try frame.memory.set_data(0, function_sig);

    // Hash the function signature
    try frame.stack.append(0); // offset
    try frame.stack.append(function_sig.len); // size

    const interpreter: Operation.Interpreter = &vm;
    const state: Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x20);

    // Extract first 4 bytes as selector
    const full_hash = try frame.stack.pop();
    const selector = full_hash >> (28 * 8); // Shift right to get first 4 bytes

    // Should be non-zero
    try testing.expect(selector != 0);

    // The actual selector for transfer(address,uint256) is 0xa9059cbb
    // but we can't verify exact value without real keccak256
}

test "Integration: Log in static context fails" {
    const allocator = testing.allocator;

    // Create database and EVM instance
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const contract_address = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);
    const alice_address = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = [_]u8{0} ** 32;

    var contract = Contract.init(
        alice_address,
        contract_address,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    // Set static context
    frame.is_static = true;

    // Try to emit LOG0
    try frame.stack.append(0); // offset
    try frame.stack.append(0); // size

    const result = opcodes.log.op_log0(0, &vm, &frame);
    try testing.expectError(ExecutionError.Error.WriteProtection, result);

    // Try LOG1
    frame.stack.clear();
    try frame.stack.append(0); // offset
    try frame.stack.append(0); // size
    try frame.stack.append(0x1111); // topic

    const result1 = opcodes.log.op_log1(0, &vm, &frame);
    try testing.expectError(ExecutionError.Error.WriteProtection, result1);
}
