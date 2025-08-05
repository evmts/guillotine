const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const MemoryDatabase = Evm.MemoryDatabase;
const Frame = Evm.Frame;
const Contract = Evm.Contract;
const Context = Evm.Context;
// Using raw opcode values directly

// Integration tests for memory and storage operations

test "Integration: Memory operations with arithmetic" {
    const allocator = testing.allocator;

    // Initialize database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const zero_address = primitives.Address.ZERO_ADDRESS;

    var contract = Contract.init(
        zero_address, // caller
        zero_address, // addr
        0, // value
        0, // gas
        &[_]u8{}, // code
        [_]u8{0} ** 32, // code_hash
        &[_]u8{}, // input
        false, // is_static
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame = try Frame.init(
        allocator,
        &vm,
        10000, // gas_limit
        &contract,
        zero_address, // caller
        &.{}, // input
        vm.context
    );
    defer frame.deinit();

    // Store result of arithmetic operation in memory
    // Calculate 10 + 20 = 30, store at offset 0
    try frame.stack_push(10);
    try frame.stack_push(20);

    // Execute ADD opcode
    _ = try vm.table.execute(&vm, &frame, 0x01);

    // Store result in memory
    try frame.stack_push(0); // offset
    _ = try vm.table.execute(&vm, &frame, 0x52);

    // Load from memory and verify
    try frame.stack_push(0); // offset
    _ = try vm.table.execute(&vm, &frame, 0x51);

    const loaded_value = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 30), loaded_value);

    // Check memory size
    _ = try vm.table.execute(&vm, &frame, 0x59);
    const memory_size = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 32), memory_size);
}

test "Integration: Storage with conditional updates" {
    const allocator = testing.allocator;

    // Initialize database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const zero_address = primitives.Address.ZERO_ADDRESS;

    var contract = Contract.init(
        zero_address, // caller
        zero_address, // addr
        0, // value
        0, // gas
        &[_]u8{}, // code
        [_]u8{0} ** 32, // code_hash
        &[_]u8{}, // input
        false, // is_static
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame = try Frame.init(
        allocator,
        &vm,
        10000, // gas_limit
        &contract,
        zero_address, // caller
        &.{}, // input
        vm.context
    );
    defer frame.deinit();

    // Set initial storage value
    const slot: u256 = 42;
    const initial_value: u256 = 100;
    try vm.state.set_storage(zero_address, slot, initial_value);

    // Load value, add 50, store back if result > 120
    try frame.stack_push(slot);

    _ = try vm.table.execute(&vm, &frame, 0x54);

    const loaded_value = try frame.stack_pop();
    try testing.expectEqual(initial_value, loaded_value);

    // Add 50
    try frame.stack_push(loaded_value);
    try frame.stack_push(50);
    _ = try vm.table.execute(&vm, &frame, 0x01);

    const sum = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 150), sum);

    // Compare sum > 120
    // We want to check if 150 > 120 = true
    // GT computes top > second, so we need 150 on top
    try frame.stack_push(120); // Stack: [120]
    try frame.stack_push(sum); // Stack: [120, 150]
    _ = try vm.table.execute(&vm, &frame, 0x11); // GT: 150 > 120 = 1

    const comparison_result = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 1), comparison_result);

    // Push sum back for storage
    try frame.stack_push(sum);

    // Since condition is true, store the value
    // Stack has the value (150), need to store it
    try frame.stack_push(slot);
    _ = try vm.table.execute(&vm, &frame, 0x55);

    // Verify storage was updated
    const updated_value = vm.state.get_storage(zero_address, slot);
    try testing.expectEqual(@as(u256, 150), updated_value);
}

test "Integration: Memory copy operations" {
    const allocator = testing.allocator;

    // Initialize database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const zero_address = primitives.Address.ZERO_ADDRESS;

    var contract = Contract.init(
        zero_address, // caller
        zero_address, // addr
        0, // value
        0, // gas
        &[_]u8{}, // code
        [_]u8{0} ** 32, // code_hash
        &[_]u8{}, // input
        false, // is_static
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame = try Frame.init(
        allocator,
        &vm,
        10000, // gas_limit
        &contract,
        zero_address, // caller
        &.{}, // input
        vm.context
    );
    defer frame.deinit();

    // Store some data in memory
    const data1: u256 = 0xDEADBEEF;
    const data2: u256 = 0xCAFEBABE;

    try frame.stack_push(data1);
    try frame.stack_push(0); // offset
    _ = try vm.table.execute(&vm, &frame, 0x52);

    try frame.stack_push(data2);
    try frame.stack_push(32); // offset
    _ = try vm.table.execute(&vm, &frame, 0x52);

    // Copy 32 bytes from offset 0 to offset 64
    // MCOPY expects [dst, src, length] from top to bottom
    // So we push in reverse order: length, src, dst
    try frame.stack_push(32); // size (will be on top)
    try frame.stack_push(0); // src (will be in middle)
    try frame.stack_push(64); // dst (will be on bottom)
    _ = try vm.table.execute(&vm, &frame, 0x5E);

    // Verify copy
    try frame.stack_push(64); // offset
    _ = try vm.table.execute(&vm, &frame, 0x51);

    const copied_value = try frame.stack_pop();
    try testing.expectEqual(data1, copied_value);

    // Check memory size expanded
    _ = try vm.table.execute(&vm, &frame, 0x59);

    const memory_size = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 96), memory_size);
}

test "Integration: Transient storage with arithmetic" {
    const allocator = testing.allocator;

    // Initialize database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const zero_address = primitives.Address.ZERO_ADDRESS;

    var contract = Contract.init(
        zero_address, // caller
        zero_address, // addr
        0, // value
        0, // gas
        &[_]u8{}, // code
        [_]u8{0} ** 32, // code_hash
        &[_]u8{}, // input
        false, // is_static
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame = try Frame.init(
        allocator,
        &vm,
        10000, // gas_limit
        &contract,
        zero_address, // caller
        &.{}, // input
        vm.context
    );
    defer frame.deinit();

    const slot: u256 = 123;

    // Store initial value in transient storage
    try frame.stack_push(1000);
    try frame.stack_push(slot);
    _ = try vm.table.execute(&vm, &frame, 0x5D);

    // Load, double it, store back
    try frame.stack_push(slot);
    _ = try vm.table.execute(&vm, &frame, 0x5C);

    const loaded_value = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 1000), loaded_value);

    // Double the value
    try frame.stack_push(loaded_value);
    _ = try vm.table.execute(&vm, &frame, 0x80);
    _ = try vm.table.execute(&vm, &frame, 0x01);

    const doubled = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 2000), doubled);

    // Store back
    try frame.stack_push(doubled);
    try frame.stack_push(slot);
    _ = try vm.table.execute(&vm, &frame, 0x5D);

    // Verify
    try frame.stack_push(slot);
    _ = try vm.table.execute(&vm, &frame, 0x5C);

    const final_value = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 2000), final_value);
}

test "Integration: MSTORE8 with bitwise operations" {
    const allocator = testing.allocator;

    // Initialize database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const zero_address = primitives.Address.ZERO_ADDRESS;

    var contract = Contract.init(
        zero_address, // caller
        zero_address, // addr
        0, // value
        0, // gas
        &[_]u8{}, // code
        [_]u8{0} ** 32, // code_hash
        &[_]u8{}, // input
        false, // is_static
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame = try Frame.init(
        allocator,
        &vm,
        10000, // gas_limit
        &contract,
        zero_address, // caller
        &.{}, // input
        vm.context
    );
    defer frame.deinit();

    // Store individual bytes to build a word
    var offset: u256 = 0;
    const bytes = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };

    for (bytes) |byte| {
        try frame.stack_push(byte);
        try frame.stack_push(offset);
        _ = try vm.table.execute(&vm, &frame, 0x53);
        offset += 1;
    }

    // Load the full word
    try frame.stack_push(0);
    _ = try vm.table.execute(&vm, &frame, 0x51);

    // The result should be 0xDEADBEEF0000...
    const result = try frame.stack_pop();
    const expected = @as(u256, 0xDEADBEEF) << (28 * 8); // Shift to most significant bytes
    try testing.expectEqual(expected, result);
}

test "Integration: Storage slot calculation" {
    const allocator = testing.allocator;

    // Initialize database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const zero_address = primitives.Address.ZERO_ADDRESS;

    var contract = Contract.init(
        zero_address, // caller
        zero_address, // addr
        0, // value
        0, // gas
        &[_]u8{}, // code
        [_]u8{0} ** 32, // code_hash
        &[_]u8{}, // input
        false, // is_static
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame = try Frame.init(
        allocator,
        &vm,
        30000, // gas_limit
        &contract,
        zero_address, // caller
        &.{}, // input
        vm.context
    );
    defer frame.deinit();

    // Simulate array access: array[index] where base slot = 5
    const base_slot: u256 = 5;
    const index: u256 = 3;

    // Calculate slot: keccak256(base_slot) + index
    // For this test, we'll use a simpler calculation: base_slot * 1000 + index
    try frame.stack_push(base_slot);
    try frame.stack_push(1000);
    _ = try vm.table.execute(&vm, &frame, 0x02);

    try frame.stack_push(index);
    _ = try vm.table.execute(&vm, &frame, 0x01);

    const calculated_slot = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 5003), calculated_slot);

    // Store value at calculated slot
    const value: u256 = 999;
    try frame.stack_push(value);
    try frame.stack_push(calculated_slot);
    _ = try vm.table.execute(&vm, &frame, 0x55);

    // Load and verify
    try frame.stack_push(calculated_slot);
    _ = try vm.table.execute(&vm, &frame, 0x54);

    const loaded_value = try frame.stack_pop();
    try testing.expectEqual(value, loaded_value);
}

// WORKING ON THIS: Fixing memory expansion tracking expectations
test "Integration: Memory expansion tracking" {
    const allocator = testing.allocator;

    // Initialize database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const zero_address = primitives.Address.ZERO_ADDRESS;

    var contract = Contract.init(
        zero_address, // caller
        zero_address, // addr
        0, // value
        0, // gas
        &[_]u8{}, // code
        [_]u8{0} ** 32, // code_hash
        &[_]u8{}, // input
        false, // is_static
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame = try Frame.init(
        allocator,
        &vm,
        10000, // gas_limit
        &contract,
        zero_address, // caller
        &.{}, // input
        vm.context
    );
    defer frame.deinit();

    // Track memory size as we expand
    _ = try vm.table.execute(&vm, &frame, 0x59);
    const initial_size = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0), initial_size);

    // Store at offset 0
    frame.stack_clear();
    try frame.stack_push(42);
    try frame.stack_push(0);
    _ = try vm.table.execute(&vm, &frame, 0x52);

    _ = try vm.table.execute(&vm, &frame, 0x59);
    const size_after_first = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 32), size_after_first);

    // Store at offset 100 (forces expansion)
    frame.stack_clear();
    try frame.stack_push(99);
    try frame.stack_push(100);
    _ = try vm.table.execute(&vm, &frame, 0x52);

    _ = try vm.table.execute(&vm, &frame, 0x59);
    const size_after_second = try frame.stack_pop();
    // Memory expands in 32-byte words. Offset 100 + 32 bytes = 132 bytes needed
    // 132 bytes = 4.125 words, rounds up to 5 words = 160 bytes
    try testing.expectEqual(@as(u256, 160), size_after_second);

    // Store single byte at offset 200
    frame.stack_clear();
    try frame.stack_push(0xFF);
    try frame.stack_push(200);
    _ = try vm.table.execute(&vm, &frame, 0x53);

    _ = try vm.table.execute(&vm, &frame, 0x59);
    const size_after_third = try frame.stack_pop();
    // MSTORE8 at offset 200 needs byte 200, which requires 201 bytes
    // 201 bytes = 6.28125 words, rounds up to 7 words = 224 bytes
    try testing.expectEqual(@as(u256, 224), size_after_third);
}

test "Integration: Cold/warm storage access patterns" {
    const allocator = testing.allocator;

    // Initialize database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var vm = try builder.build();
    defer vm.deinit();

    // Create contract
    const zero_address = primitives.Address.ZERO_ADDRESS;

    var contract = Contract.init(
        zero_address, // caller
        zero_address, // addr
        0, // value
        0, // gas
        &[_]u8{}, // code
        [_]u8{0} ** 32, // code_hash
        &[_]u8{}, // input
        false, // is_static
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame = try Frame.init(
        allocator,
        &vm,
        10000, // gas_limit
        &contract,
        zero_address, // caller
        &.{}, // input
        vm.context
    );
    defer frame.deinit();

    const slot: u256 = 777;

    // First access - cold (should cost 2100 gas)
    const gas_before_cold = frame.gas_remaining;
    try frame.stack_push(slot);
    _ = try vm.table.execute(&vm, &frame, 0x54);
    const gas_after_cold = frame.gas_remaining;
    const cold_gas_used = gas_before_cold - gas_after_cold;
    try testing.expectEqual(@as(u64, 2100), cold_gas_used);

    // Second access - warm (should cost 100 gas)
    frame.stack_clear();
    const gas_before_warm = frame.gas_remaining;
    try frame.stack_push(slot);
    _ = try vm.table.execute(&vm, &frame, 0x54);
    const gas_after_warm = frame.gas_remaining;
    const warm_gas_used = gas_before_warm - gas_after_warm;
    try testing.expectEqual(@as(u64, 100), warm_gas_used);
}
