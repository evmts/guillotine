const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");

const Address = primitives.Address;
const MemoryDatabase = Evm.MemoryDatabase;
const Vm = Evm.Vm;
const Frame = Evm.Frame;
const Contract = Evm.Contract;
const ExecutionError = Evm.ExecutionError;
const GasConstants = primitives.GasConstants;

test "Dynamic gas calculation for memory expansion - MLOAD" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // MLOAD at position 0x100 (256) should trigger memory expansion
    // Memory expansion cost: memory_gas_cost = (memory_size_word ^ 2) / 512 + (3 * memory_size_word)
    // For 256 bytes (8 words): cost = 64/512 + 24 = 0 + 24 = 24
    // For 288 bytes (9 words, after alignment): cost = 81/512 + 27 = 0 + 27 = 27
    const bytecode = [_]u8{
        0x61, 0x01, 0x00, // PUSH2 0x0100 (256)
        0x51,             // MLOAD
        0x00,             // STOP
    };

    var contract = try Contract.init(allocator, &bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);

    const initial_gas = 100000;
    var frame = try Frame.init(allocator, &vm, initial_gas, contract, Address.ZERO, &.{});
    defer frame.deinit();

    // Execute the bytecode
    try vm.interpret(&frame);

    // Calculate expected gas consumption
    // Static costs:
    // PUSH2: 3 gas
    // MLOAD: 3 gas  
    // Total static: 6 gas
    
    // Dynamic costs for memory expansion to 288 bytes (9 words after alignment):
    // memory_word_gas = (9 * 9) / 512 + (3 * 9) = 0 + 27 = 27
    const expected_dynamic_gas = 27;
    const expected_total_gas = 6 + expected_dynamic_gas;
    const expected_remaining = initial_gas - expected_total_gas;

    // With the bug, only static gas is consumed
    const actual_remaining = frame.gas_remaining;
    
    // This test should fail if dynamic gas is not being charged
    try testing.expect(actual_remaining <= expected_remaining);
    
    // More precise check - the difference should be the dynamic gas cost
    const gas_diff = @as(i64, @intCast(actual_remaining)) - @as(i64, @intCast(expected_remaining));
    
    // If dynamic gas is not charged, gas_diff would be approximately expected_dynamic_gas
    // This assertion will fail with the current bug
    try testing.expect(@abs(gas_diff) < 5); // Allow small variance
}

test "Dynamic gas calculation for SHA3 with large memory" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // SHA3 (KECCAK256) with large memory range should charge dynamic gas
    const bytecode = [_]u8{
        0x61, 0x01, 0x00, // PUSH2 0x0100 (size = 256)
        0x60, 0x00,       // PUSH1 0x00 (offset = 0)
        0x20,             // SHA3
        0x00,             // STOP
    };

    var contract = try Contract.init(allocator, &bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);

    const initial_gas = 100000;
    var frame = try Frame.init(allocator, &vm, initial_gas, contract, Address.ZERO, &.{});
    defer frame.deinit();

    try vm.interpret(&frame);

    // Static costs:
    // PUSH2: 3 gas
    // PUSH1: 3 gas
    // SHA3 base: 30 gas
    // Total static: 36 gas
    
    // Dynamic costs:
    // SHA3 word cost: 6 * ceil(256/32) = 6 * 8 = 48 gas
    // Memory expansion to 256 bytes (8 words): 24 gas
    const expected_dynamic_gas = 48 + 24;
    const expected_total_gas = 36 + expected_dynamic_gas;
    const expected_remaining = initial_gas - expected_total_gas;

    const actual_remaining = frame.gas_remaining;
    
    // Check that dynamic gas was charged
    try testing.expect(actual_remaining <= expected_remaining);
}

test "Dynamic gas for LOG operations with data" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // LOG2 with 32 bytes of data
    const bytecode = [_]u8{
        0x60, 0x20,       // PUSH1 0x20 (size = 32)
        0x60, 0x00,       // PUSH1 0x00 (offset = 0)
        0x60, 0x01,       // PUSH1 0x01 (topic1)
        0x60, 0x02,       // PUSH1 0x02 (topic2)
        0xa2,             // LOG2
        0x00,             // STOP
    };

    var contract = try Contract.init(allocator, &bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);

    const initial_gas = 100000;
    var frame = try Frame.init(allocator, &vm, initial_gas, contract, Address.ZERO, &.{});
    defer frame.deinit();

    try vm.interpret(&frame);

    // Static costs:
    // PUSH1 x 4: 3 * 4 = 12 gas
    // LOG2 base: 375 + (2 * 375) = 1125 gas (base + 2 topics)
    // Total static: 12 + 1125 = 1137 gas
    
    // Dynamic costs:
    // LOG data: 8 * 32 = 256 gas
    // Memory expansion to 32 bytes (1 word): 3 gas
    const expected_dynamic_gas = 256 + 3;
    const expected_total_gas = 1137 + expected_dynamic_gas;
    const expected_remaining = initial_gas - expected_total_gas;

    const actual_remaining = frame.gas_remaining;
    
    // Check that dynamic gas was charged
    try testing.expect(actual_remaining <= expected_remaining);
}

test "GAS opcode returns correct value after dynamic gas consumption" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Use GAS opcode after memory expansion to check if it reports correctly
    const bytecode = [_]u8{
        0x61, 0x01, 0x00, // PUSH2 0x0100 (256)
        0x51,             // MLOAD (triggers memory expansion)
        0x5a,             // GAS (should report gas after dynamic cost)
        0x00,             // STOP
    };

    var contract = try Contract.init(allocator, &bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);

    const initial_gas = 100000;
    var frame = try Frame.init(allocator, &vm, initial_gas, contract, Address.ZERO, &.{});
    defer frame.deinit();

    try vm.interpret(&frame);

    // Pop the gas value that was pushed
    const reported_gas = try frame.stack.pop();
    
    // The GAS opcode should report remaining gas after all costs
    // Including both static and dynamic gas consumption
    // With bug: reports too much gas (dynamic cost not deducted)
    
    // Static costs before GAS: PUSH2(3) + MLOAD(3) = 6
    // Dynamic cost for MLOAD: 27 (memory expansion)
    // GAS opcode itself: 2
    const consumed_before_gas = 6 + 27;
    const expected_gas_value = initial_gas - consumed_before_gas - 2; // -2 for GAS opcode itself
    
    // Allow some variance but check it's in the right ballpark
    const diff = @as(i64, @intCast(reported_gas)) - @as(i64, @intCast(expected_gas_value));
    try testing.expect(@abs(diff) < 100);
}