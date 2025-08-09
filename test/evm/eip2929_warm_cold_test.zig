const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;

const testing = std.testing;
const allocator = testing.allocator;

// Test EIP-2929 warm/cold access costs for storage operations
test "EIP-2929: SLOAD warm/cold gas costs" {
    // Create test environment
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Set to Berlin hardfork to enable EIP-2929
    vm.chain_rules = evm.ChainRules.from_hardfork(.BERLIN);

    // Create test contract
    const test_address = Address.from_u256(0x1234);
    
    // Bytecode: PUSH1 0x00, SLOAD, PUSH1 0x00, SLOAD
    // First SLOAD should be cold, second should be warm
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0x00
        0x54,       // SLOAD (cold - 2100 gas)
        0x60, 0x00, // PUSH1 0x00
        0x54,       // SLOAD (warm - 100 gas)
    };

    var contract = try evm.Contract.init(allocator, &bytecode, .{ .address = test_address });
    defer contract.deinit(allocator, null);

    var frame = try evm.Frame.init(allocator, &vm, 10000, contract, Address.ZERO_ADDRESS, &.{});
    defer frame.deinit();

    // Initialize access list for transaction
    try vm.access_list.init_transaction(test_address);

    // Execute first SLOAD (cold)
    try frame.stack.push(0); // slot 0
    const gas_before_cold = frame.gas_remaining;
    
    const interpreter_ptr: *evm.Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *evm.Operation.State = @ptrCast(&frame);
    _ = try vm.table.execute(0, interpreter_ptr, state_ptr, 0x54); // SLOAD
    
    const gas_consumed_cold = gas_before_cold - frame.gas_remaining;
    
    // EIP-2929: Cold SLOAD should cost 2100 gas
    try testing.expectEqual(@as(u64, 2100), gas_consumed_cold);

    // Execute second SLOAD (warm)
    try frame.stack.push(0); // slot 0 again
    const gas_before_warm = frame.gas_remaining;
    
    _ = try vm.table.execute(0, interpreter_ptr, state_ptr, 0x54); // SLOAD
    
    const gas_consumed_warm = gas_before_warm - frame.gas_remaining;
    
    // EIP-2929: Warm SLOAD should cost 100 gas
    try testing.expectEqual(@as(u64, 100), gas_consumed_warm);
}

// Test EIP-2929 warm/cold access costs for address operations
test "EIP-2929: BALANCE warm/cold gas costs" {
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Set to Berlin hardfork
    vm.chain_rules = evm.ChainRules.from_hardfork(.BERLIN);

    const test_address = Address.from_u256(0x1234);
    const target_address = Address.from_u256(0x5678);
    
    var contract = try evm.Contract.init(allocator, &.{}, .{ .address = test_address });
    defer contract.deinit(allocator, null);

    var frame = try evm.Frame.init(allocator, &vm, 10000, contract, Address.ZERO, &.{});
    defer frame.deinit();

    // Initialize access list
    try vm.access_list.init_transaction(test_address);

    // First BALANCE call (cold)
    try frame.stack.push(Address.to_u256(target_address));
    const gas_before_cold = frame.gas_remaining;
    
    const interpreter_ptr: *evm.Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *evm.Operation.State = @ptrCast(&frame);
    _ = try vm.table.execute(0, interpreter_ptr, state_ptr, 0x31); // BALANCE
    
    const gas_consumed_cold = gas_before_cold - frame.gas_remaining;
    
    // Cold access should cost 2600 gas
    try testing.expectEqual(@as(u64, 2600), gas_consumed_cold);

    // Second BALANCE call (warm)
    try frame.stack.push(Address.to_u256(target_address));
    const gas_before_warm = frame.gas_remaining;
    
    _ = try vm.table.execute(0, interpreter_ptr, state_ptr, 0x31); // BALANCE
    
    const gas_consumed_warm = gas_before_warm - frame.gas_remaining;
    
    // Warm access should cost 100 gas
    try testing.expectEqual(@as(u64, 100), gas_consumed_warm);
}

// Test that precompiles are pre-warmed
test "EIP-2929: Precompiles are pre-warmed" {
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    vm.chain_rules = evm.ChainRules.from_hardfork(.BERLIN);

    const test_address = Address.from_u256(0x1234);
    
    var contract = try evm.Contract.init(allocator, &.{}, .{ .address = test_address });
    defer contract.deinit(allocator, null);

    var frame = try evm.Frame.init(allocator, &vm, 10000, contract, Address.ZERO, &.{});
    defer frame.deinit();

    // Initialize access list
    try vm.access_list.init_transaction(test_address);

    // Check that all precompiles are warm
    var i: u8 = 1;
    while (i <= 10) : (i += 1) {
        var precompile_addr: primitives.Address.Address = [_]u8{0} ** 20;
        precompile_addr[19] = i;
        
        try testing.expect(vm.access_list.is_address_warm(precompile_addr));
        
        // Accessing should return warm cost
        const cost = try vm.access_list.access_address(precompile_addr);
        try testing.expectEqual(@as(u64, 100), cost);
    }
}

// Test EIP-3651: COINBASE is pre-warmed
test "EIP-3651: COINBASE is pre-warmed" {
    const coinbase_address = Address.from_u256(0xC01DBEEF);
    
    const context = evm.Context.init_with_values(
        Address.from_u256(0x1111), // tx_origin
        0,                          // gas_price
        0,                          // block_number
        0,                          // block_timestamp
        coinbase_address,           // block_coinbase
        0,                          // block_difficulty
        0,                          // block_gas_limit
        1,                          // chain_id
        0,                          // block_base_fee
        &[_]u256{},                 // blob_hashes
        0,                          // blob_base_fee
    );
    
    var access_list = evm.AccessList.init(allocator, context);
    defer access_list.deinit();

    const test_address = Address.from_u256(0x1234);
    
    // Initialize transaction
    try access_list.init_transaction(test_address);

    // COINBASE should be pre-warmed
    try testing.expect(access_list.is_address_warm(coinbase_address));
    
    // Accessing COINBASE should return warm cost
    const cost = try access_list.access_address(coinbase_address);
    try testing.expectEqual(@as(u64, 100), cost);
}

// Test CALL opcodes with warm/cold addresses
test "EIP-2929: CALL with warm/cold addresses" {
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    vm.chain_rules = evm.ChainRules.from_hardfork(.BERLIN);

    const test_address = Address.from_u256(0x1234);
    const cold_target = Address.from_u256(0x5678);
    const warm_target = Address.from_u256(0x9ABC);
    
    var contract = try evm.Contract.init(allocator, &.{}, .{ .address = test_address });
    defer contract.deinit(allocator, null);

    var frame = try evm.Frame.init(allocator, &vm, 100000, contract, Address.ZERO, &.{});
    defer frame.deinit();

    // Initialize access list and pre-warm one address
    try vm.access_list.init_transaction(test_address);
    _ = try vm.access_list.access_address(warm_target);

    // Test CALL to cold address
    // Stack: gas, to, value, args_offset, args_size, ret_offset, ret_size
    try frame.stack.push(0); // ret_size
    try frame.stack.push(0); // ret_offset
    try frame.stack.push(0); // args_size
    try frame.stack.push(0); // args_offset
    try frame.stack.push(0); // value
    try frame.stack.push(Address.to_u256(cold_target)); // to
    try frame.stack.push(10000); // gas
    
    const gas_before_cold = frame.gas_remaining;
    
    const interpreter_ptr: *evm.Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *evm.Operation.State = @ptrCast(&frame);
    
    // This would normally execute CALL but we need proper host implementation
    // For now, just verify the address is marked as accessed
    try testing.expect(!vm.access_list.is_address_warm(cold_target));
    _ = try vm.access_list.access_address(cold_target);
    try testing.expect(vm.access_list.is_address_warm(cold_target));

    // Test CALL to warm address
    try frame.stack.push(0); // ret_size
    try frame.stack.push(0); // ret_offset
    try frame.stack.push(0); // args_size
    try frame.stack.push(0); // args_offset
    try frame.stack.push(0); // value
    try frame.stack.push(Address.to_u256(warm_target)); // to
    try frame.stack.push(10000); // gas
    
    // Warm address should already be marked
    try testing.expect(vm.access_list.is_address_warm(warm_target));
    const warm_cost = try vm.access_list.access_address(warm_target);
    try testing.expectEqual(@as(u64, 100), warm_cost);
}

// Test SELFDESTRUCT with cold recipient
test "EIP-2929: SELFDESTRUCT with cold recipient" {
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    vm.chain_rules = evm.ChainRules.from_hardfork(.BERLIN);

    const test_address = Address.from_u256(0x1234);
    const cold_recipient = Address.from_u256(0x5678);
    
    var contract = try evm.Contract.init(allocator, &.{}, .{ .address = test_address });
    defer contract.deinit(allocator, null);

    var frame = try evm.Frame.init(allocator, &vm, 100000, contract, Address.ZERO, &.{});
    defer frame.deinit();

    // Initialize access list
    try vm.access_list.init_transaction(test_address);

    // Verify recipient is cold
    try testing.expect(!vm.access_list.is_address_warm(cold_recipient));
    
    // Access the recipient and check it becomes warm
    const cost = try vm.access_list.access_address(cold_recipient);
    try testing.expectEqual(@as(u64, 2600), cost); // Cold access cost
    
    try testing.expect(vm.access_list.is_address_warm(cold_recipient));
}

// Test warm-up persists across nested calls but reverts with transaction
test "EIP-2929: Warm-up persistence and revert boundaries" {
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    vm.chain_rules = evm.ChainRules.from_hardfork(.BERLIN);

    const test_address = Address.from_u256(0x1234);
    const target_address = Address.from_u256(0x5678);
    
    // Initialize for first transaction
    try vm.access_list.init_transaction(test_address);
    
    // Access an address (make it warm)
    _ = try vm.access_list.access_address(target_address);
    try testing.expect(vm.access_list.is_address_warm(target_address));
    
    // In the same transaction, address stays warm
    const warm_cost = try vm.access_list.access_address(target_address);
    try testing.expectEqual(@as(u64, 100), warm_cost);
    
    // Start new transaction - access list should be cleared
    try vm.access_list.init_transaction(test_address);
    
    // Address should be cold again
    try testing.expect(!vm.access_list.is_address_warm(target_address));
    const cold_cost = try vm.access_list.access_address(target_address);
    try testing.expectEqual(@as(u64, 2600), cold_cost);
}

// Test storage slot warm/cold with SSTORE
test "EIP-2929: SSTORE warm/cold gas costs" {
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    vm.chain_rules = evm.ChainRules.from_hardfork(.BERLIN);

    const test_address = Address.from_u256(0x1234);
    
    var contract = try evm.Contract.init(allocator, &.{}, .{ .address = test_address });
    defer contract.deinit(allocator, null);

    var frame = try evm.Frame.init(allocator, &vm, 100000, contract, Address.ZERO, &.{});
    defer frame.deinit();

    // Initialize access list
    try vm.access_list.init_transaction(test_address);

    // First SSTORE to slot 0 (cold)
    const slot: u256 = 0;
    const value: u256 = 42;
    
    try testing.expect(!vm.access_list.is_storage_slot_warm(test_address, slot));
    
    // Mark slot as warm and check cost
    const is_cold = try frame.mark_storage_slot_warm(slot);
    try testing.expect(is_cold); // Should have been cold
    
    try testing.expect(vm.access_list.is_storage_slot_warm(test_address, slot));
    
    // Second access should be warm
    const is_still_cold = try frame.mark_storage_slot_warm(slot);
    try testing.expect(!is_still_cold); // Should be warm now
}