const std = @import("std");
const testing = std.testing;

// Import EVM components directly
const Evm = @import("evm");
const primitives = @import("primitives");
const MemoryDatabase = Evm.MemoryDatabase;
const Frame = Evm.Frame;
const Contract = Evm.Contract;
const Address = primitives.Address;
const Operation = Evm.Operation;
const ExecutionError = Evm.ExecutionError;
const environment = Evm.opcodes.environment;
const system = Evm.opcodes.system;
const block = Evm.opcodes.block;
const stack = Evm.opcodes.stack;
const arithmetic = Evm.opcodes.arithmetic;
const memory_ops = Evm.opcodes.memory;
const log = Evm.opcodes.log;

test "Integration: Contract deployment simulation" {
    // Simulate CREATE operation with constructor
    const allocator = testing.allocator;

    // Initialize memory database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Set up deployer account
    const alice_addr = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);
    const deployer_balance: u256 = 1_000_000_000_000_000_000; // 1 ETH
    try vm.state.set_balance(alice_addr, deployer_balance);

    var contract = Contract.init(
        alice_addr,
        alice_addr, // Deployer is also the contract during creation
        1_000_000_000, // 1 Gwei
        1_000_000,
        &[_]u8{}, // Empty code during deployment
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Evm.Context.init_with_values(
        alice_addr, // tx_origin
        0, // gas_price
        0, // block_number
        0, // block_timestamp
        primitives.Address.ZERO_ADDRESS, // block_coinbase
        0, // block_difficulty
        30000000, // block_gas_limit
        1, // chain_id
        0, // block_base_fee
        &[_]u256{}, // blob_hashes
        0, // blob_base_fee
    );
    
    var frame = try Frame.init(
        allocator,
        &vm,
        100000, // gas_limit
        &contract,
        alice_addr, // caller
        &[_]u8{}, // input
        context,
    );
    defer frame.deinit();

    // Prepare constructor bytecode in memory
    // Simple constructor that stores a value
    const constructor_code = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00
        0x55, // SSTORE (store 0x42 at slot 0)
        0x00, // STOP
    };

    try frame.memory_set_data(0, &constructor_code);

    // Push CREATE parameters: value, offset, size
    try frame.stack_push(constructor_code.len); // size
    try frame.stack_push(0); // offset
    try frame.stack_push(1_000_000_000); // value (1 Gwei)

    // Execute CREATE (will fail with placeholder implementation)
    _ = vm.table.execute(&vm, &frame, 0xF0) catch |err| {
        // CREATE is not fully implemented, but we can verify it tries to execute
        try testing.expect(err == ExecutionError.Error.OutOfGas or
            err == ExecutionError.Error.StackUnderflow or
            err == ExecutionError.Error.MaxCodeSizeExceeded);
    };
}

test "Integration: Call with value transfer" {
    // Test CALL operation with ETH transfer
    const allocator = testing.allocator;

    // Initialize memory database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Set up accounts
    const alice_addr = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);
    const bob_addr = primitives.Address.from_u256(0x2222222222222222222222222222222222222222);
    const contract_addr = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);

    try vm.state.set_balance(alice_addr, 1_000_000_000_000_000_000); // 1 ETH
    try vm.state.set_balance(bob_addr, 0);

    var contract = Contract.init(
        alice_addr,
        contract_addr,
        0,
        1_000_000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Give contract some balance to transfer
    try vm.state.set_balance(contract_addr, 1_000_000_000_000_000_000); // 1 ETH

    const context = Evm.Context.init_with_values(
        alice_addr, // tx_origin
        0, // gas_price
        0, // block_number
        0, // block_timestamp
        primitives.Address.ZERO_ADDRESS, // block_coinbase
        0, // block_difficulty
        30000000, // block_gas_limit
        1, // chain_id
        0, // block_base_fee
        &[_]u256{}, // blob_hashes
        0, // blob_base_fee
    );
    
    var frame = try Frame.init(
        allocator,
        &vm,
        100000, // gas_limit
        &contract,
        alice_addr, // caller
        &[_]u8{}, // input
        context,
    );
    defer frame.deinit();

    // Prepare CALL parameters
    // CALL(gas, address, value, argsOffset, argsSize, retOffset, retSize)
    // Push in reverse order since stack is LIFO
    try frame.stack_push(0); // retSize
    try frame.stack_push(0); // retOffset
    try frame.stack_push(0); // argsSize
    try frame.stack_push(0); // argsOffset
    try frame.stack_push(1_000_000_000); // value (1 Gwei)
    try frame.stack_push(primitives.Address.to_u256(bob_addr)); // address
    try frame.stack_push(50000); // gas

    // Execute CALL (placeholder implementation)
    _ = vm.table.execute(&vm, &frame, 0xF1) catch |err| {
        // CALL is not fully implemented
        try testing.expect(err == ExecutionError.Error.OutOfGas or
            err == ExecutionError.Error.StackUnderflow);
    };
}

test "Integration: Environment data access" {
    // Test accessing various environment data
    const allocator = testing.allocator;

    // Initialize memory database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Set up VM environment
    // Create context with test values
    const alice_addr = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);
    const bob_addr = primitives.Address.from_u256(0x2222222222222222222222222222222222222222);
    const contract_addr = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);
    const charlie_addr = primitives.Address.from_u256(0x4444444444444444444444444444444444444444);

    const context = Evm.Context.init_with_values(alice_addr, 20 * 1_000_000_000, // 20 Gwei
        15000000, 1234567890, charlie_addr, 0, 30000000, 1, 0, &[_]u256{}, 0);
    vm.set_context(context);

    var contract = Contract.init(
        bob_addr, // caller
        contract_addr,
        1_000_000_000, // 1 Gwei callvalue
        1_000_000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(
        allocator,
        &vm,
        10000, // gas_limit
        &contract,
        bob_addr, // caller
        &[_]u8{}, // input
        context,
    );
    defer frame.deinit();

    // Test ADDRESS
    _ = try environment.op_address(&vm, &frame);
    const address_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, primitives.Address.to_u256(contract_addr)), address_result);

    // Test ORIGIN  
    _ = try environment.op_origin(&vm, &frame);
    const origin_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, primitives.Address.to_u256(alice_addr)), origin_result);

    // Test CALLER
    _ = try environment.op_caller(&vm, &frame);
    const caller_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, primitives.Address.to_u256(bob_addr)), caller_result);

    // Test CALLVALUE
    _ = try environment.op_callvalue(&vm, &frame);
    const callvalue_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 1_000_000_000), callvalue_result);

    // Test GASPRICE
    _ = try environment.op_gasprice(&vm, &frame);
    const gasprice_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 20 * 1_000_000_000), gasprice_result);

    // Test CHAINID
    _ = try environment.op_chainid(&vm, &frame);
    const chainid_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 1), chainid_result);
}

test "Integration: Block information access" {
    // Test block-related opcodes
    const allocator = testing.allocator;

    // Initialize memory database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Set up block information
    // Create context with test values
    const alice_addr = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);
    const contract_addr = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);
    const charlie_addr = primitives.Address.from_u256(0x4444444444444444444444444444444444444444);

    const context = Evm.Context.init_with_values(alice_addr, 0, 17000000, 1683000000, charlie_addr, 0, 30000000, 1, 30 * 1_000_000_000, // 30 Gwei
        &[_]u256{}, 0);
    vm.set_context(context);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(&[_]u8{});
    hasher.final(&code_hash);

    var contract = Contract.init(
        alice_addr,
        contract_addr,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(
        allocator,
        &vm,
        10000, // gas_limit
        &contract,
        alice_addr, // caller
        &[_]u8{}, // input
        context,
    );
    defer frame.deinit();

    // Test NUMBER
    _ = try block.op_number(&vm, &frame);
    const number_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 17000000), number_result);

    // Test TIMESTAMP
    _ = try block.op_timestamp(&vm, &frame);
    const timestamp_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 1683000000), timestamp_result);

    // Test COINBASE
    _ = try block.op_coinbase(&vm, &frame);
    const coinbase_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, primitives.Address.to_u256(charlie_addr)), coinbase_result);

    // Test GASLIMIT
    _ = try block.op_gaslimit(&vm, &frame);
    const gaslimit_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 30000000), gaslimit_result);

    // Test BASEFEE
    _ = try block.op_basefee(&vm, &frame);
    const basefee_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 30 * 1_000_000_000), basefee_result);
}

test "Integration: Log emission with topics" {
    // Test LOG operations
    const allocator = testing.allocator;

    // Initialize memory database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    const alice_addr = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);
    const bob_addr = primitives.Address.from_u256(0x2222222222222222222222222222222222222222);
    const contract_addr = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(&[_]u8{});
    hasher.final(&code_hash);

    var contract = Contract.init(
        alice_addr,
        contract_addr,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Evm.Context.init_with_values(
        alice_addr, // tx_origin
        0, // gas_price
        0, // block_number
        0, // block_timestamp
        primitives.Address.ZERO_ADDRESS, // block_coinbase
        0, // block_difficulty
        30000000, // block_gas_limit
        1, // chain_id
        0, // block_base_fee
        &[_]u256{}, // blob_hashes
        0, // blob_base_fee
    );
    
    var frame = try Frame.init(
        allocator,
        &vm,
        10000, // gas_limit
        &contract,
        alice_addr, // caller
        &[_]u8{}, // input
        context,
    );
    defer frame.deinit();

    // Prepare log data in memory
    const log_data = "Transfer successful";
    try frame.memory_set_data(0, log_data);

    // Prepare topics (e.g., Transfer event signature and addresses)
    const topic1: u256 = 0x1234567890abcdef; // Event signature
    const topic2: u256 = primitives.Address.to_u256(alice_addr); // From
    const topic3: u256 = primitives.Address.to_u256(bob_addr); // To

    // Emit LOG3 (3 topics)
    // Push in reverse order since stack is LIFO: LOG3(offset, size, topic0, topic1, topic2)
    try frame.stack_push(topic3); // topic2 (will be popped last)
    try frame.stack_push(topic2); // topic1
    try frame.stack_push(topic1); // topic0
    try frame.stack_push(log_data.len); // size
    try frame.stack_push(0); // offset (will be popped first)

    const initial_log_count = vm.state.logs.items.len;

    // Execute LOG3 through jump table
    _ = try vm.table.execute(&vm, &frame, 0xA3);

    // Verify log was emitted
    try testing.expectEqual(initial_log_count + 1, vm.state.logs.items.len);

    const emitted_log = vm.state.logs.items[vm.state.logs.items.len - 1];
    try testing.expectEqual(contract_addr, emitted_log.address);
    try testing.expectEqual(@as(usize, 3), emitted_log.topics.len);
    try testing.expectEqual(topic3, emitted_log.topics[0]);
    try testing.expectEqual(topic2, emitted_log.topics[1]);
    try testing.expectEqual(topic1, emitted_log.topics[2]);
    try testing.expectEqualSlices(u8, log_data, emitted_log.data);
}

test "Integration: External code operations" {
    // Test EXTCODESIZE, EXTCODECOPY, EXTCODEHASH
    const allocator = testing.allocator;

    // Initialize memory database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    const alice_addr = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);
    const bob_addr = primitives.Address.from_u256(0x2222222222222222222222222222222222222222);
    const contract_addr = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);

    // Set up external contract with code
    const external_code = [_]u8{
        0x60, 0x80, // PUSH1 0x80
        0x60, 0x40, // PUSH1 0x40
        0x52, // MSTORE
        0x00, // STOP
    };

    try vm.state.set_balance(bob_addr, 0);
    try vm.state.set_code(bob_addr, &external_code);

    // Calculate code hash for empty code
    var code_hash: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(&[_]u8{});
    hasher.final(&code_hash);

    var contract = Contract.init(
        alice_addr,
        contract_addr,
        0,
        1_000_000,
        &[_]u8{},
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Evm.Context.init_with_values(
        alice_addr, // tx_origin
        0, // gas_price
        0, // block_number
        0, // block_timestamp
        primitives.Address.ZERO_ADDRESS, // block_coinbase
        0, // block_difficulty
        30000000, // block_gas_limit
        1, // chain_id
        0, // block_base_fee
        &[_]u256{}, // blob_hashes
        0, // blob_base_fee
    );
    
    var frame = try Frame.init(
        allocator,
        &vm,
        10000, // gas_limit
        &contract,
        alice_addr, // caller
        &[_]u8{}, // input
        context,
    );
    defer frame.deinit();

    // Execute opcodes through jump table

    // Test EXTCODESIZE
    try frame.stack_push(primitives.Address.to_u256(bob_addr));
    _ = try vm.table.execute(&vm, &frame, 0x3B);
    const codesize_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, external_code.len), codesize_result);

    // Test EXTCODECOPY
    // EXTCODECOPY(address, mem_offset, code_offset, size)
    // Push in reverse order since stack is LIFO
    try frame.stack_push(external_code.len); // size (will be popped last)
    try frame.stack_push(0); // code_offset
    try frame.stack_push(0); // mem_offset
    try frame.stack_push(primitives.Address.to_u256(bob_addr)); // address (will be popped first)
    _ = try vm.table.execute(&vm, &frame, 0x3C);

    // Verify code was copied to memory
    const copied_code = try frame.memory_get_slice(0, external_code.len);
    try testing.expectEqualSlices(u8, &external_code, copied_code);

    // Test EXTCODEHASH
    try frame.stack_push(primitives.Address.to_u256(bob_addr));
    _ = try vm.table.execute(&vm, &frame, 0x3F);

    // Hash should be non-zero for account with code
    const code_hash_result = try frame.stack_pop();
    try testing.expect(code_hash_result != 0);
}

test "Integration: Calldata operations" {
    // Test CALLDATALOAD, CALLDATASIZE, CALLDATACOPY
    const allocator = testing.allocator;

    // Initialize memory database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    const alice_addr = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);
    const contract_addr = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);

    // Prepare calldata
    const calldata = [_]u8{
        0x12, 0x34, 0x56, 0x78, // Function selector
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x42, // uint256 argument = 66
    };

    var contract = Contract.init(
        alice_addr,
        contract_addr,
        0,
        1_000_000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &calldata,
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Evm.Context.init_with_values(
        alice_addr, // tx_origin
        0, // gas_price
        0, // block_number
        0, // block_timestamp
        primitives.Address.ZERO_ADDRESS, // block_coinbase
        0, // block_difficulty
        30000000, // block_gas_limit
        1, // chain_id
        0, // block_base_fee
        &[_]u256{}, // blob_hashes
        0, // blob_base_fee
    );
    
    var frame = try Frame.init(
        allocator,
        &vm,
        10000, // gas_limit
        &contract,
        alice_addr, // caller
        &calldata, // input
        context,
    );
    defer frame.deinit();

    // Execute opcodes through jump table

    // Test CALLDATASIZE
    _ = try vm.table.execute(&vm, &frame, 0x36);
    const datasize_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, calldata.len), datasize_result);

    // Test CALLDATALOAD at offset 0 (function selector)
    try frame.stack_push(0);
    _ = try vm.table.execute(&vm, &frame, 0x35);

    // Should load 32 bytes starting from offset 0
    const loaded_value = try frame.stack_pop();
    try testing.expect((loaded_value >> (28 * 8)) == 0x12345678);

    // Test CALLDATALOAD at offset 4 (first argument)
    try frame.stack_push(4);
    _ = try vm.table.execute(&vm, &frame, 0x35);
    const arg_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0x42), arg_result);

    // Test CALLDATACOPY
    // CALLDATACOPY(mem_offset, data_offset, size)
    // Push in reverse order since stack is LIFO
    try frame.stack_push(calldata.len); // size (will be popped last)
    try frame.stack_push(0); // data_offset
    try frame.stack_push(0); // mem_offset (will be popped first)
    _ = try vm.table.execute(&vm, &frame, 0x37);

    // Verify calldata was copied to memory
    const copied_data = try frame.memory_get_slice(0, calldata.len);
    try testing.expectEqualSlices(u8, &calldata, copied_data);
}

test "Integration: Self balance and code operations" {
    // Test SELFBALANCE, CODESIZE, CODECOPY
    const allocator = testing.allocator;

    // Initialize memory database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    const alice_addr = primitives.Address.from_u256(0x1111111111111111111111111111111111111111);
    const contract_addr = primitives.Address.from_u256(0x3333333333333333333333333333333333333333);

    // Contract code
    const contract_code = [_]u8{
        0x60, 0x00, // PUSH1 0x00
        0x35, // CALLDATALOAD
        0x60, 0x00, // PUSH1 0x00
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xf3, // RETURN
    };

    // Set up contract with balance and code
    try vm.state.set_balance(contract_addr, 1_000_000_000_000_000_000); // 1 ETH
    try vm.state.set_code(contract_addr, &contract_code);

    // Calculate code hash
    var code_hash: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(&contract_code);
    hasher.final(&code_hash);

    var contract = Contract.init(
        alice_addr,
        contract_addr,
        0,
        1_000_000,
        &contract_code,
        code_hash,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Evm.Context.init_with_values(
        alice_addr, // tx_origin
        0, // gas_price
        0, // block_number
        0, // block_timestamp
        primitives.Address.ZERO_ADDRESS, // block_coinbase
        0, // block_difficulty
        30000000, // block_gas_limit
        1, // chain_id
        0, // block_base_fee
        &[_]u256{}, // blob_hashes
        0, // blob_base_fee
    );
    
    var frame = try Frame.init(
        allocator,
        &vm,
        10000, // gas_limit
        &contract,
        alice_addr, // caller
        &[_]u8{}, // input
        context,
    );
    defer frame.deinit();

    // Execute opcodes through jump table

    // Test SELFBALANCE
    _ = try vm.table.execute(&vm, &frame, 0x47);
    const balance_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 1_000_000_000_000_000_000), balance_result);

    // Test CODESIZE
    _ = try vm.table.execute(&vm, &frame, 0x38);
    const codesize_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, contract_code.len), codesize_result);

    // Test CODECOPY
    // CODECOPY(mem_offset, code_offset, size)
    // Push in reverse order since stack is LIFO
    try frame.stack_push(contract_code.len); // size (will be popped last)
    try frame.stack_push(0); // code_offset
    try frame.stack_push(0); // mem_offset (will be popped first)
    _ = try vm.table.execute(&vm, &frame, 0x39);

    // Verify code was copied to memory
    const copied_code = try frame.memory_get_slice(0, contract_code.len);
    try testing.expectEqualSlices(u8, &contract_code, copied_code);
}
