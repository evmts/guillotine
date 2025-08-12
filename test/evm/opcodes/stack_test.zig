const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

test {
    std.testing.log_level = .warn;
}

// Helper function to create test addresses
fn testAddress(value: u160) primitives.Address.Address {
    return primitives.Address.from_u256(@as(u256, value));
}

test "Stack: PUSH0 operation" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const bytecode = &[_]u8{
        0x5F, // PUSH0
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
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
    } };

    const result = try vm.call(call_params);
    defer if (result.output) |output| allocator.free(output);

    try testing.expect(result.success);
    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 32), output.len);
        // Check that the result is 0
        var expected = [_]u8{0} ** 32;
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

test "Stack: PUSH1 operation" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const bytecode = &[_]u8{
        0x60, 0xAB, // PUSH1 0xAB
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
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
    } };

    const result = try vm.call(call_params);
    defer if (result.output) |output| allocator.free(output);

    try testing.expect(result.success);
    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 32), output.len);
        // Check that the result is 0xAB
        var expected = [_]u8{0} ** 32;
        expected[31] = 0xAB;
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

test "Stack: PUSH2 operation" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const bytecode = &[_]u8{
        0x61, 0x12, 0x34, // PUSH2 0x1234
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
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
    } };

    const result = try vm.call(call_params);
    defer if (result.output) |output| allocator.free(output);

    try testing.expect(result.success);
    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 32), output.len);
        // Check that the result is 0x1234
        var expected = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &expected, 0x1234, .big);
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

test "Stack: PUSH32 operation" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const bytecode = &[_]u8{
        0x7F, // PUSH32
        0x01,
        0x02,
        0x03,
        0x04,
        0x05,
        0x06,
        0x07,
        0x08,
        0x09,
        0x0A,
        0x0B,
        0x0C,
        0x0D,
        0x0E,
        0x0F,
        0x10,
        0x11,
        0x12,
        0x13,
        0x14,
        0x15,
        0x16,
        0x17,
        0x18,
        0x19,
        0x1A,
        0x1B,
        0x1C,
        0x1D,
        0x1E,
        0x1F,
        0x20,
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
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
    } };

    const result = try vm.call(call_params);
    defer if (result.output) |output| allocator.free(output);

    try testing.expect(result.success);
    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 32), output.len);
        // Check that the result matches the 32 bytes pushed
        const expected = [_]u8{
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
            0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
            0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20,
        };
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

test "Stack: POP operation" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const bytecode = &[_]u8{
        0x60, 0x42, // PUSH1 0x42 (first value)
        0x60, 0x99, // PUSH1 0x99 (second value)
        0x50, // POP (remove 0x99)
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
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
    } };

    const result = try vm.call(call_params);
    defer if (result.output) |output| allocator.free(output);

    try testing.expect(result.success);
    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 32), output.len);
        // Should return 0x42 (0x99 was popped)
        var expected = [_]u8{0} ** 32;
        expected[31] = 0x42;
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

test "Stack: DUP1 operation" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const bytecode = &[_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x80, // DUP1 (duplicate top item)
        0x01, // ADD (0x42 + 0x42 = 0x84)
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    const contract_addr = testAddress(0x1005);
    const caller = testAddress(0x2005);

    try vm.state.set_code(contract_addr, bytecode);

    const call_params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_addr,
        .value = 0,
        .input = &[_]u8{},
        .gas = 100000,
    } };

    const result = try vm.call(call_params);
    defer if (result.output) |output| allocator.free(output);

    try testing.expect(result.success);
    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 32), output.len);
        // Should return 0x84 (0x42 + 0x42)
        var expected = [_]u8{0} ** 32;
        expected[31] = 0x84;
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

test "Stack: DUP16 operation" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Build bytecode that pushes 16 values and then duplicates the 16th
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();

    // Push values 1 through 16
    var i: u8 = 1;
    while (i <= 16) : (i += 1) {
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(i);
    }

    try bytecode.append(0x8F); // DUP16 (duplicate the 16th item from top, which is value 1)

    // Store the result
    try bytecode.append(0x60); // PUSH1
    try bytecode.append(0x00);
    try bytecode.append(0x52); // MSTORE
    try bytecode.append(0x60); // PUSH1
    try bytecode.append(0x20);
    try bytecode.append(0x60); // PUSH1
    try bytecode.append(0x00);
    try bytecode.append(0xF3); // RETURN

    const contract_addr = testAddress(0x1006);
    const caller = testAddress(0x2006);

    try vm.state.set_code(contract_addr, bytecode.items);

    const call_params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_addr,
        .value = 0,
        .input = &[_]u8{},
        .gas = 100000,
    } };

    const result = try vm.call(call_params);
    defer if (result.output) |output| allocator.free(output);

    try testing.expect(result.success);
    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 32), output.len);
        // Should return 1 (the 16th item from top)
        var expected = [_]u8{0} ** 32;
        expected[31] = 1;
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

test "Stack: SWAP1 operation" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const bytecode = &[_]u8{
        0x60, 0x11, // PUSH1 0x11
        0x60, 0x22, // PUSH1 0x22
        0x90, // SWAP1 (swap top two items)
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    const contract_addr = testAddress(0x1007);
    const caller = testAddress(0x2007);

    try vm.state.set_code(contract_addr, bytecode);

    const call_params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_addr,
        .value = 0,
        .input = &[_]u8{},
        .gas = 100000,
    } };

    const result = try vm.call(call_params);
    defer if (result.output) |output| allocator.free(output);

    try testing.expect(result.success);
    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 32), output.len);
        // After SWAP1, top should be 0x11 (was second)
        var expected = [_]u8{0} ** 32;
        expected[31] = 0x11;
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

test "Stack: SWAP16 operation" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Build bytecode that pushes 17 values and then swaps 1st with 17th
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();

    // Push values 1 through 17
    var i: u8 = 1;
    while (i <= 17) : (i += 1) {
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(i);
    }

    try bytecode.append(0x9F); // SWAP16 (swap top with 17th from top)

    // Store the result (top of stack after swap)
    try bytecode.append(0x60); // PUSH1
    try bytecode.append(0x00);
    try bytecode.append(0x52); // MSTORE
    try bytecode.append(0x60); // PUSH1
    try bytecode.append(0x20);
    try bytecode.append(0x60); // PUSH1
    try bytecode.append(0x00);
    try bytecode.append(0xF3); // RETURN

    const contract_addr = testAddress(0x1008);
    const caller = testAddress(0x2008);

    try vm.state.set_code(contract_addr, bytecode.items);

    const call_params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_addr,
        .value = 0,
        .input = &[_]u8{},
        .gas = 100000,
    } };

    const result = try vm.call(call_params);
    defer if (result.output) |output| allocator.free(output);

    try testing.expect(result.success);
    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 32), output.len);
        // After SWAP16, top should be 1 (was 17th from top)
        var expected = [_]u8{0} ** 32;
        expected[31] = 1;
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

test "Stack: Complex stack manipulation" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Complex sequence: push, dup, swap, pop
    const bytecode = &[_]u8{
        0x60, 0x10, // PUSH1 0x10
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x30, // PUSH1 0x30  Stack: [0x10, 0x20, 0x30]
        0x81, // DUP2        Stack: [0x10, 0x20, 0x30, 0x20]
        0x91, // SWAP2       Stack: [0x10, 0x20, 0x20, 0x30]
        0x50, // POP         Stack: [0x10, 0x20, 0x20]
        0x01, // ADD         Stack: [0x10, 0x40]
        0x01, // ADD         Stack: [0x50]
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    const contract_addr = testAddress(0x1009);
    const caller = testAddress(0x2009);

    try vm.state.set_code(contract_addr, bytecode);

    const call_params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_addr,
        .value = 0,
        .input = &[_]u8{},
        .gas = 100000,
    } };

    const result = try vm.call(call_params);
    defer if (result.output) |output| allocator.free(output);

    try testing.expect(result.success);
    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 32), output.len);
        // Result should be 0x50 (0x10 + 0x20 + 0x20)
        var expected = [_]u8{0} ** 32;
        expected[31] = 0x50;
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

test "Stack: PUSH with insufficient bytes should fail" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // PUSH2 with only 1 byte of data (should fail)
    const bytecode = &[_]u8{
        0x61, 0x12, // PUSH2 but missing second byte
    };

    const contract_addr = testAddress(0x100A);
    const caller = testAddress(0x200A);

    try vm.state.set_code(contract_addr, bytecode);

    const call_params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_addr,
        .value = 0,
        .input = &[_]u8{},
        .gas = 100000,
    } };

    const result = try vm.call(call_params);
    defer if (result.output) |output| allocator.free(output);

    // Execution should fail due to invalid push
    try testing.expect(!result.success);
}
