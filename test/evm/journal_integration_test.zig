const std = @import("std");
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const GasConstants = primitives.GasConstants;

test "CALL with successful execution commits state changes" {
    const allocator = std.testing.allocator;
    
    // Create a simple contract that stores a value
    // PUSH1 0x42  // value to store
    // PUSH1 0x00  // storage slot
    // SSTORE      // store value
    // STOP
    const store_contract_code = &[_]u8{ 
        0x60, 0x42,  // PUSH1 0x42
        0x60, 0x00,  // PUSH1 0x00
        0x55,        // SSTORE
        0x00,        // STOP
    };
    
    // Create the EVM instance
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Deploy the contract
    const contract_address = Address.from_u256(0x1234);
    try memory_db.set_code(contract_address, store_contract_code);
    try memory_db.set_balance(contract_address, 0);
    
    // Create call parameters
    const call_params = Evm.CallParams{ .call = .{
        .caller = Address.ZERO,
        .to = contract_address,
        .value = 0,
        .input = &.{},
        .gas = 100000,
    } };
    
    // Execute the call
    const result = try vm.call(call_params);
    
    // Verify the call succeeded
    try std.testing.expect(result.success);
    
    // Verify the storage was updated
    const stored_value = memory_db.get_storage(contract_address, 0) catch 0;
    try std.testing.expectEqual(@as(u256, 0x42), stored_value);
}

test "CALL with REVERT undoes state changes" {
    const allocator = std.testing.allocator;
    
    // Create a contract that modifies state then reverts
    // PUSH1 0x42  // value to store
    // PUSH1 0x00  // storage slot
    // SSTORE      // store value
    // PUSH1 0x00  // revert data size
    // PUSH1 0x00  // revert data offset
    // REVERT
    const revert_contract_code = &[_]u8{ 
        0x60, 0x42,  // PUSH1 0x42
        0x60, 0x00,  // PUSH1 0x00
        0x55,        // SSTORE
        0x60, 0x00,  // PUSH1 0x00
        0x60, 0x00,  // PUSH1 0x00
        0xFD,        // REVERT
    };
    
    // Create the EVM instance
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Deploy the contract with initial storage value
    const contract_address = Address.from_u256(0x1234);
    try memory_db.set_code(contract_address, revert_contract_code);
    try memory_db.set_balance(contract_address, 0);
    try memory_db.set_storage(contract_address, 0, 0x99); // Initial value
    
    // Create call parameters
    const call_params = Evm.CallParams{ .call = .{
        .caller = Address.ZERO,
        .to = contract_address,
        .value = 0,
        .input = &.{},
        .gas = 100000,
    } };
    
    // Execute the call
    const result = try vm.call(call_params);
    
    // Verify the call failed (reverted)
    try std.testing.expect(!result.success);
    
    // Verify the storage was NOT updated (reverted to initial value)
    const stored_value = memory_db.get_storage(contract_address, 0) catch 0;
    try std.testing.expectEqual(@as(u256, 0x99), stored_value);
}

test "Nested CALL with inner REVERT preserves outer state" {
    const allocator = std.testing.allocator;
    
    // Contract A: Stores a value then calls contract B
    // PUSH1 0x11  // value to store
    // PUSH1 0x00  // storage slot
    // SSTORE      // store value in A
    // ... then CALL to B ...
    // STOP
    
    // Contract B: Stores a value then reverts
    // PUSH1 0x22  // value to store
    // PUSH1 0x00  // storage slot
    // SSTORE      // store value in B
    // REVERT
    
    const contract_a_code = &[_]u8{
        0x60, 0x11,  // PUSH1 0x11
        0x60, 0x00,  // PUSH1 0x00
        0x55,        // SSTORE
        // CALL to contract B
        0x60, 0x00,  // PUSH1 0x00 (ret size)
        0x60, 0x00,  // PUSH1 0x00 (ret offset)
        0x60, 0x00,  // PUSH1 0x00 (args size)
        0x60, 0x00,  // PUSH1 0x00 (args offset)
        0x60, 0x00,  // PUSH1 0x00 (value)
        0x61, 0x56, 0x78, // PUSH2 0x5678 (contract B address)
        0x5A,        // GAS
        0xF1,        // CALL
        0x50,        // POP (ignore result)
        0x00,        // STOP
    };
    
    const contract_b_code = &[_]u8{
        0x60, 0x22,  // PUSH1 0x22
        0x60, 0x00,  // PUSH1 0x00
        0x55,        // SSTORE
        0x60, 0x00,  // PUSH1 0x00
        0x60, 0x00,  // PUSH1 0x00
        0xFD,        // REVERT
    };
    
    // Create the EVM instance
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Deploy both contracts
    const contract_a_address = Address.from_u256(0x1234);
    const contract_b_address = Address.from_u256(0x5678);
    
    try memory_db.set_code(contract_a_address, contract_a_code);
    try memory_db.set_code(contract_b_address, contract_b_code);
    try memory_db.set_balance(contract_a_address, 0);
    try memory_db.set_balance(contract_b_address, 0);
    
    // Set initial storage values
    try memory_db.set_storage(contract_a_address, 0, 0xAA);
    try memory_db.set_storage(contract_b_address, 0, 0xBB);
    
    // Create call parameters for calling contract A
    const call_params = Evm.CallParams{ .call = .{
        .caller = Address.ZERO,
        .to = contract_a_address,
        .value = 0,
        .input = &.{},
        .gas = 200000,
    } };
    
    // Execute the call
    const result = try vm.call(call_params);
    
    // Verify the outer call succeeded
    try std.testing.expect(result.success);
    
    // Verify contract A's storage was updated
    const a_storage = memory_db.get_storage(contract_a_address, 0) catch 0;
    try std.testing.expectEqual(@as(u256, 0x11), a_storage);
    
    // Verify contract B's storage was NOT updated (reverted)
    const b_storage = memory_db.get_storage(contract_b_address, 0) catch 0;
    try std.testing.expectEqual(@as(u256, 0xBB), b_storage);
}

test "CREATE with successful deployment tracks created contract" {
    const allocator = std.testing.allocator;
    
    // Contract that creates a new contract
    // The init code just returns empty code
    const creator_code = &[_]u8{
        // Push init code to memory
        0x60, 0x00,  // PUSH1 0x00 (return empty code)
        0x60, 0x00,  // PUSH1 0x00 (offset)
        0x52,        // MSTORE8
        // CREATE
        0x60, 0x01,  // PUSH1 0x01 (size)
        0x60, 0x00,  // PUSH1 0x00 (offset)
        0x60, 0x00,  // PUSH1 0x00 (value)
        0xF0,        // CREATE
        0x00,        // STOP
    };
    
    // Create the EVM instance
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Deploy the creator contract
    const creator_address = Address.from_u256(0x1234);
    try memory_db.set_code(creator_address, creator_code);
    try memory_db.set_balance(creator_address, 0);
    
    // Create call parameters
    const call_params = Evm.CallParams{ .call = .{
        .caller = Address.ZERO,
        .to = creator_address,
        .value = 0,
        .input = &.{},
        .gas = 200000,
    } };
    
    // Execute the call
    const result = try vm.call(call_params);
    
    // Verify the call succeeded
    try std.testing.expect(result.success);
    
    // Verify a contract was created (check created_contracts tracker)
    try std.testing.expect(vm.created_contracts.count() > 0);
}

test "CREATE with failed deployment reverts state" {
    const allocator = std.testing.allocator;
    
    // Contract that attempts CREATE but the init code reverts
    // The init code will REVERT
    const creator_code = &[_]u8{
        // Push init code to memory (REVERT opcode)
        0x60, 0xFD,  // PUSH1 0xFD (REVERT opcode)
        0x60, 0x00,  // PUSH1 0x00 (offset)
        0x52,        // MSTORE8
        // CREATE
        0x60, 0x01,  // PUSH1 0x01 (size)
        0x60, 0x00,  // PUSH1 0x00 (offset)
        0x60, 0x00,  // PUSH1 0x00 (value)
        0xF0,        // CREATE
        0x00,        // STOP
    };
    
    // Create the EVM instance
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Deploy the creator contract
    const creator_address = Address.from_u256(0x1234);
    try memory_db.set_code(creator_address, creator_code);
    try memory_db.set_balance(creator_address, 1000);
    
    // Create call parameters
    const call_params = Evm.CallParams{ .call = .{
        .caller = Address.ZERO,
        .to = creator_address,
        .value = 0,
        .input = &.{},
        .gas = 200000,
    } };
    
    // Execute the call
    const result = try vm.call(call_params);
    
    // The outer call should succeed even though CREATE failed
    try std.testing.expect(result.success);
    
    // Verify no contract was created
    try std.testing.expectEqual(@as(u32, 0), vm.created_contracts.count());
    
    // Verify balance wasn't transferred (CREATE failed)
    const creator_balance = memory_db.get_balance(creator_address) catch 0;
    try std.testing.expectEqual(@as(u256, 1000), creator_balance);
}

test "DELEGATECALL preserves caller context" {
    const allocator = std.testing.allocator;
    
    // Contract A: Delegate calls to contract B
    // Contract B: Stores msg.sender in storage
    
    const contract_a_code = &[_]u8{
        // DELEGATECALL to contract B
        0x60, 0x00,  // PUSH1 0x00 (ret size)
        0x60, 0x00,  // PUSH1 0x00 (ret offset)
        0x60, 0x00,  // PUSH1 0x00 (args size)
        0x60, 0x00,  // PUSH1 0x00 (args offset)
        0x61, 0x56, 0x78, // PUSH2 0x5678 (contract B address)
        0x5A,        // GAS
        0xF4,        // DELEGATECALL
        0x50,        // POP (ignore result)
        0x00,        // STOP
    };
    
    const contract_b_code = &[_]u8{
        0x33,        // CALLER (gets msg.sender)
        0x60, 0x00,  // PUSH1 0x00 (storage slot)
        0x55,        // SSTORE (store caller)
        0x00,        // STOP
    };
    
    // Create the EVM instance
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Deploy both contracts
    const contract_a_address = Address.from_u256(0x1234);
    const contract_b_address = Address.from_u256(0x5678);
    const original_caller = Address.from_u256(0x9999);
    
    try memory_db.set_code(contract_a_address, contract_a_code);
    try memory_db.set_code(contract_b_address, contract_b_code);
    
    // Create call parameters
    const call_params = Evm.CallParams{ .call = .{
        .caller = original_caller,
        .to = contract_a_address,
        .value = 0,
        .input = &.{},
        .gas = 200000,
    } };
    
    // Execute the call
    const result = try vm.call(call_params);
    
    // Verify the call succeeded
    try std.testing.expect(result.success);
    
    // Verify that storage was written to contract A (not B) with original caller
    const stored_caller = memory_db.get_storage(contract_a_address, 0) catch 0;
    try std.testing.expectEqual(primitives.Address.to_u256(original_caller), stored_caller);
    
    // Verify contract B's storage is empty (DELEGATECALL uses A's storage)
    const b_storage = memory_db.get_storage(contract_b_address, 0) catch 0;
    try std.testing.expectEqual(@as(u256, 0), b_storage);
}

test "STATICCALL prevents state modifications" {
    const allocator = std.testing.allocator;
    
    // Contract that tries to modify state (should fail in static context)
    const state_modifier_code = &[_]u8{
        0x60, 0x42,  // PUSH1 0x42
        0x60, 0x00,  // PUSH1 0x00
        0x55,        // SSTORE (should fail in static context)
        0x00,        // STOP
    };
    
    // Contract that makes a STATICCALL
    const static_caller_code = &[_]u8{
        // STATICCALL to state modifier
        0x60, 0x00,  // PUSH1 0x00 (ret size)
        0x60, 0x00,  // PUSH1 0x00 (ret offset)
        0x60, 0x00,  // PUSH1 0x00 (args size)
        0x60, 0x00,  // PUSH1 0x00 (args offset)
        0x61, 0x56, 0x78, // PUSH2 0x5678 (target address)
        0x5A,        // GAS
        0xFA,        // STATICCALL
        // Check result and store it
        0x60, 0x00,  // PUSH1 0x00 (storage slot)
        0x55,        // SSTORE (store call result)
        0x00,        // STOP
    };
    
    // Create the EVM instance
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Deploy both contracts
    const caller_address = Address.from_u256(0x1234);
    const target_address = Address.from_u256(0x5678);
    
    try memory_db.set_code(caller_address, static_caller_code);
    try memory_db.set_code(target_address, state_modifier_code);
    
    // Create call parameters
    const call_params = Evm.CallParams{ .call = .{
        .caller = Address.ZERO,
        .to = caller_address,
        .value = 0,
        .input = &.{},
        .gas = 200000,
    } };
    
    // Execute the call
    const result = try vm.call(call_params);
    
    // The outer call should succeed
    try std.testing.expect(result.success);
    
    // The STATICCALL result should be 0 (failed due to state modification attempt)
    const call_result = memory_db.get_storage(caller_address, 0) catch 0;
    try std.testing.expectEqual(@as(u256, 0), call_result);
    
    // Target contract's storage should be unchanged
    const target_storage = memory_db.get_storage(target_address, 0) catch 0;
    try std.testing.expectEqual(@as(u256, 0), target_storage);
}