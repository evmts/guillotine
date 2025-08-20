const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const EVM = Evm.Evm;
const Address = Evm.Address;
const ExecutionError = Evm.ExecutionError;
const MemoryDatabase = Evm.MemoryDatabase;
const DatabaseInterface = Evm.DatabaseInterface;

// Helper function to create EVM with memory database
fn create_test_evm(allocator: std.mem.Allocator) !struct { evm: EVM, memory_db: *MemoryDatabase } {
    const memory_db = try allocator.create(MemoryDatabase);
    memory_db.* = MemoryDatabase.init(allocator);
    const db_interface = memory_db.to_database_interface();
    const evm = try EVM.init(allocator, db_interface, null, null, null, null);
    return .{ .evm = evm, .memory_db = memory_db };
}

fn destroy_test_evm(allocator: std.mem.Allocator, evm: *EVM, memory_db: *MemoryDatabase) void {
    evm.deinit();
    memory_db.deinit();
    allocator.destroy(memory_db);
}

test "Static call protection - validate_static_context" {
    const allocator = testing.allocator;
    const test_setup = try create_test_evm(allocator);
    var evm = test_setup.evm;
    defer destroy_test_evm(allocator, &evm, test_setup.memory_db);

    // Test 1: Normal context should allow modifications
    evm.read_only = false;
    try evm.validate_static_context(); // Should not error

    // Test 2: Static context should prevent modifications
    evm.read_only = true;
    const result = evm.validate_static_context();
    try testing.expectError(error.WriteProtection, result);
}

test "Static call protection - storage operations" {
    const allocator = testing.allocator;
    const test_setup = try create_test_evm(allocator);
    var evm = test_setup.evm;
    defer destroy_test_evm(allocator, &evm, test_setup.memory_db);

    const test_address = [_]u8{0x01} ** 20;
    const test_slot: u256 = 42;
    const test_value: u256 = 100;

    // Test 1: Normal context allows storage writes
    evm.read_only = false;
    try evm.set_storage_protected(test_address, test_slot, test_value);
    const stored_value = evm.state.get_storage(test_address, test_slot);
    try testing.expectEqual(test_value, stored_value);

    // Test 2: Static context prevents storage writes
    evm.read_only = true;
    const result = evm.set_storage_protected(test_address, test_slot, 200);
    try testing.expectError(error.WriteProtection, result);

    // Verify value didn't change
    const unchanged_value = evm.state.get_storage(test_address, test_slot);
    try testing.expectEqual(test_value, unchanged_value);
}

test "Static call protection - transient storage operations" {
    const allocator = testing.allocator;
    const test_setup = try create_test_evm(allocator);
    var evm = test_setup.evm;
    defer destroy_test_evm(allocator, &evm, test_setup.memory_db);

    const test_address = [_]u8{0x02} ** 20;
    const test_slot: u256 = 50;
    const test_value: u256 = 150;

    // Test 1: Normal context allows transient storage writes
    evm.read_only = false;
    try evm.set_transient_storage_protected(test_address, test_slot, test_value);
    const stored_value = evm.state.get_transient_storage(test_address, test_slot);
    try testing.expectEqual(test_value, stored_value);

    // Test 2: Static context prevents transient storage writes
    evm.read_only = true;
    const result = evm.set_transient_storage_protected(test_address, test_slot, 250);
    try testing.expectError(error.WriteProtection, result);
}

test "Static call protection - balance operations" {
    const allocator = testing.allocator;
    const test_setup = try create_test_evm(allocator);
    var evm = test_setup.evm;
    defer destroy_test_evm(allocator, &evm, test_setup.memory_db);

    const test_address = [_]u8{0x03} ** 20;
    const test_balance: u256 = 1000;

    // Test 1: Normal context allows balance updates
    evm.read_only = false;
    try evm.set_balance_protected(test_address, test_balance);
    const balance = evm.state.get_balance(test_address);
    try testing.expectEqual(test_balance, balance);

    // Test 2: Static context prevents balance updates
    evm.read_only = true;
    const result = evm.set_balance_protected(test_address, 2000);
    try testing.expectError(error.WriteProtection, result);
}

test "Static call protection - code operations" {
    const allocator = testing.allocator;
    const test_setup = try create_test_evm(allocator);
    var evm = test_setup.evm;
    defer destroy_test_evm(allocator, &evm, test_setup.memory_db);

    const test_address = [_]u8{0x04} ** 20;
    const test_code = [_]u8{ 0x60, 0x01, 0x60, 0x02 }; // PUSH1 1 PUSH1 2

    // Test 1: Normal context allows code updates
    evm.read_only = false;
    try evm.set_code_protected(test_address, &test_code);
    const code = evm.state.get_code(test_address);
    try testing.expectEqualSlices(u8, &test_code, code);

    // Test 2: Static context prevents code updates
    evm.read_only = true;
    const new_code = [_]u8{ 0x60, 0x03 }; // PUSH1 3
    const result = evm.set_code_protected(test_address, &new_code);
    try testing.expectError(error.WriteProtection, result);
}

test "Static call protection - log operations" {
    const allocator = testing.allocator;
    const test_setup = try create_test_evm(allocator);
    var evm = test_setup.evm;
    defer destroy_test_evm(allocator, &evm, test_setup.memory_db);

    const test_address = [_]u8{0x05} ** 20;
    const topics = [_]u256{ 0x123, 0x456 };
    const data = [_]u8{ 0x01, 0x02, 0x03 };

    // Test 1: Normal context allows log emission
    evm.read_only = false;
    try evm.emit_log_protected(test_address, &topics, &data);
    try testing.expectEqual(@as(usize, 1), evm.state.logs.items.len);

    // Test 2: Static context prevents log emission
    evm.read_only = true;
    const result = evm.emit_log_protected(test_address, &topics, &data);
    try testing.expectError(error.WriteProtection, result);

    // Verify no new log was added
    try testing.expectEqual(@as(usize, 1), evm.state.logs.items.len);
}

test "Static call protection - contract creation" {
    const allocator = testing.allocator;
    const test_setup = try create_test_evm(allocator);
    var evm = test_setup.evm;
    defer destroy_test_evm(allocator, &evm, test_setup.memory_db);

    const creator = [_]u8{0x06} ** 20;
    const value: u256 = 1000;
    const init_code = [_]u8{ 0x60, 0x00 }; // PUSH1 0
    const gas: u64 = 100000;

    // Test 1: Normal context allows contract creation
    evm.read_only = false;
    _ = try evm.create_contract_protected(creator, value, &init_code, gas);

    // Test 2: Static context prevents contract creation
    evm.read_only = true;
    const result = evm.create_contract_protected(creator, value, &init_code, gas);
    try testing.expectError(error.WriteProtection, result);
}

test "Static call protection - CREATE2 contract creation" {
    const allocator = testing.allocator;
    const test_setup = try create_test_evm(allocator);
    var evm = test_setup.evm;
    defer destroy_test_evm(allocator, &evm, test_setup.memory_db);

    const creator = [_]u8{0x07} ** 20;
    const value: u256 = 1000;
    const init_code = [_]u8{ 0x60, 0x00 }; // PUSH1 0
    const salt: u256 = 0xdeadbeef;
    const gas: u64 = 100000;

    // Test 1: Normal context allows CREATE2
    evm.read_only = false;
    _ = try evm.create2_contract_protected(creator, value, &init_code, salt, gas);

    // Test 2: Static context prevents CREATE2
    evm.read_only = true;
    const result = evm.create2_contract_protected(creator, value, &init_code, salt, gas);
    try testing.expectError(error.WriteProtection, result);
}

test "Static call protection - value transfer validation" {
    const allocator = testing.allocator;
    const test_setup = try create_test_evm(allocator);
    var evm = test_setup.evm;
    defer destroy_test_evm(allocator, &evm, test_setup.memory_db);

    // Test 1: Normal context allows value transfers
    evm.read_only = false;
    try evm.validate_value_transfer(1000); // Should not error

    // Test 2: Static context allows zero value
    evm.read_only = true;
    try evm.validate_value_transfer(0); // Should not error

    // Test 3: Static context prevents non-zero value transfers
    evm.read_only = true;
    const result = evm.validate_value_transfer(1);
    try testing.expectError(error.WriteProtection, result);
}

test "Static call protection - selfdestruct" {
    const allocator = testing.allocator;
    const test_setup = try create_test_evm(allocator);
    var evm = test_setup.evm;
    defer destroy_test_evm(allocator, &evm, test_setup.memory_db);

    const contract = [_]u8{0x08} ** 20;
    const beneficiary = [_]u8{0x09} ** 20;

    // Test 1: Normal context allows selfdestruct
    evm.read_only = false;
    try evm.selfdestruct_protected(contract, beneficiary);

    // Test 2: Static context prevents selfdestruct
    evm.read_only = true;
    const result = evm.selfdestruct_protected(contract, beneficiary);
    try testing.expectError(error.WriteProtection, result);
}

test "Static call protection - comprehensive scenario" {
    const allocator = testing.allocator;
    const test_setup = try create_test_evm(allocator);
    var evm = test_setup.evm;
    defer destroy_test_evm(allocator, &evm, test_setup.memory_db);

    const test_address = [_]u8{0x0A} ** 20;

    // Set up initial state in normal context
    evm.read_only = false;
    try evm.set_balance_protected(test_address, 5000);
    try evm.set_storage_protected(test_address, 1, 100);

    // Switch to static context
    evm.read_only = true;

    // Verify reads still work
    const balance = evm.state.get_balance(test_address);
    try testing.expectEqual(@as(u256, 5000), balance);

    const storage_value = evm.state.get_storage(test_address, 1);
    try testing.expectEqual(@as(u256, 100), storage_value);

    // Verify all writes fail
    try testing.expectError(error.WriteProtection, evm.set_balance_protected(test_address, 6000));
    try testing.expectError(error.WriteProtection, evm.set_storage_protected(test_address, 1, 200));
    try testing.expectError(error.WriteProtection, evm.set_transient_storage_protected(test_address, 1, 300));
    try testing.expectError(error.WriteProtection, evm.emit_log_protected(test_address, &[_]u256{}, &[_]u8{}));
    try testing.expectError(error.WriteProtection, evm.create_contract_protected(test_address, 0, &[_]u8{}, 0));
    try testing.expectError(error.WriteProtection, evm.selfdestruct_protected(test_address, test_address));

    // Verify state unchanged
    const final_balance = evm.state.get_balance(test_address);
    try testing.expectEqual(@as(u256, 5000), final_balance);

    const final_storage = evm.state.get_storage(test_address, 1);
    try testing.expectEqual(@as(u256, 100), final_storage);
}
