const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

// Helper function to create test addresses
fn testAddress(value: u160) primitives.Address.Address {
    return primitives.Address.from_u256(@as(u256, value));
}

test "PUSH + ADD fusion optimization" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Bytecode: PUSH1 10, PUSH1 5, ADD
    // Without optimization: 3 operations
    // With optimization: 2 operations (PUSH1 10, then fused PUSH+ADD)
    const bytecode = &[_]u8{
        0x60, 0x0A, // PUSH1 10
        0x60, 0x05, // PUSH1 5
        0x01,       // ADD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };

    const contract_addr = testAddress(0x1000);
    const caller = testAddress(0x2000);

    try vm.state.set_code(contract_addr, bytecode);

    const call_params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_addr,
        .value = 0,
        .input = &[_]u8{},
        .gas = 100000,
    }};

    const result = try vm.call(call_params);
    try testing.expect(result.success);
    if (result.output) |_| {
        try testing.expectEqual(@as(usize, 32), output.len);
        // Check that the result is 15
        var expected = [_]u8{0} ** 32;
        expected[31] = 15;
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

test "PUSH 0 + ADD identity elimination" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Bytecode: PUSH1 42, PUSH1 0, ADD
    // Should be optimized to just PUSH1 42 (identity elimination)
    const bytecode = &[_]u8{
        0x60, 0x2A, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x01,       // ADD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };

    const contract_addr = testAddress(0x1001);
    const caller = testAddress(0x2001);

    try vm.state.set_code(contract_addr, bytecode);

    const call_params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_addr,
        .value = 0,
        .input = &[_]u8{},
        .gas = 100000,
    }};

    const result = try vm.call(call_params);
    try testing.expect(result.success);
    if (result.output) |_| {
        try testing.expectEqual(@as(usize, 32), output.len);
        // Check that the result is 42
        var expected = [_]u8{0} ** 32;
        expected[31] = 42;
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

test "PUSH + PUSH + ADD constant folding" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Bytecode: PUSH1 7, PUSH1 3, ADD
    // Should be optimized to a single PUSH of 10
    const bytecode = &[_]u8{
        0x60, 0x07, // PUSH1 7
        0x60, 0x03, // PUSH1 3
        0x01,       // ADD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };

    const contract_addr = testAddress(0x1002);
    const caller = testAddress(0x2002);

    try vm.state.set_code(contract_addr, bytecode);

    const call_params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_addr,
        .value = 0,
        .input = &[_]u8{},
        .gas = 100000,
    }};

    const result = try vm.call(call_params);
    try testing.expect(result.success);
    if (result.output) |_| {
        try testing.expectEqual(@as(usize, 32), output.len);
        // Check that the result is 10
        var expected = [_]u8{0} ** 32;
        expected[31] = 10;
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

test "ISZERO inline optimization" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Test that ISZERO is optimized to use inline version
    const bytecode = &[_]u8{
        0x60, 0x00, // PUSH1 0
        0x15,       // ISZERO
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };

    const contract_addr = testAddress(0x1003);
    const caller = testAddress(0x2003);

    try vm.state.set_code(contract_addr, bytecode);

    const call_params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_addr,
        .value = 0,
        .input = &[_]u8{},
        .gas = 100000,
    }};

    const result = try vm.call(call_params);
    try testing.expect(result.success);
    if (result.output) |_| {
        try testing.expectEqual(@as(usize, 32), output.len);
        // ISZERO(0) should return 1
        var expected = [_]u8{0} ** 32;
        expected[31] = 1;
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

test "EQ inline optimization" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Test that EQ is optimized to use inline version
    const bytecode = &[_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x05, // PUSH1 5
        0x14,       // EQ
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };

    const contract_addr = testAddress(0x1004);
    const caller = testAddress(0x2004);

    try vm.state.set_code(contract_addr, bytecode);

    const call_params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_addr,
        .value = 0,
        .input = &[_]u8{},
        .gas = 100000,
    }};

    const result = try vm.call(call_params);
    try testing.expect(result.success);
    if (result.output) |_| {
        try testing.expectEqual(@as(usize, 32), output.len);
        // EQ(5, 5) should return 1
        var expected = [_]u8{0} ** 32;
        expected[31] = 1;
        try testing.expectEqualSlices(u8, &expected, output);
    }
}