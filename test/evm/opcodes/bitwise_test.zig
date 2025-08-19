const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

// Helper function to create test addresses
fn testAddress(value: u160) primitives.Address.Address {
    return primitives.Address.from_u256(@as(u256, value));
}

test "Bitwise: AND basic operations" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Test 1: Simple AND (0xFF00 & 0xF0F0 = 0xF000)
    {
        const bytecode = &[_]u8{
            0x61, 0xF0, 0xF0, // PUSH2 0xF0F0
            0x61, 0xFF, 0x00, // PUSH2 0xFF00
            0x16,             // AND
            0x60, 0x00,       // PUSH1 0
            0x52,             // MSTORE
            0x60, 0x20,       // PUSH1 32
            0x60, 0x00,       // PUSH1 0
            0xF3,             // RETURN
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
            // Check that the result is 0xF000
            var expected = [_]u8{0} ** 32;
            expected[30] = 0xF0;
            expected[31] = 0x00;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }

    // Test 2: AND with zero (0xFFFF & 0 = 0)
    {
        const bytecode = &[_]u8{
            0x61, 0xFF, 0xFF, // PUSH2 0xFFFF
            0x60, 0x00,       // PUSH1 0
            0x16,             // AND
            0x60, 0x00,       // PUSH1 0
            0x52,             // MSTORE
            0x60, 0x20,       // PUSH1 32
            0x60, 0x00,       // PUSH1 0
            0xF3,             // RETURN
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
            // Check that the result is 0
            var expected = [_]u8{0} ** 32;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }
}

test "Bitwise: OR basic operations" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Test: Simple OR (0xFF00 | 0x00FF = 0xFFFF)
    {
        const bytecode = &[_]u8{
            0x61, 0x00, 0xFF, // PUSH2 0x00FF
            0x61, 0xFF, 0x00, // PUSH2 0xFF00
            0x17,             // OR
            0x60, 0x00,       // PUSH1 0
            0x52,             // MSTORE
            0x60, 0x20,       // PUSH1 32
            0x60, 0x00,       // PUSH1 0
            0xF3,             // RETURN
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
            // Check that the result is 0xFFFF
            var expected = [_]u8{0} ** 32;
            expected[30] = 0xFF;
            expected[31] = 0xFF;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }
}

test "Bitwise: XOR basic operations" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Test: XOR with same value gives 0 (0xABCD ^ 0xABCD = 0)
    {
        const bytecode = &[_]u8{
            0x61, 0xAB, 0xCD, // PUSH2 0xABCD
            0x61, 0xAB, 0xCD, // PUSH2 0xABCD
            0x18,             // XOR
            0x60, 0x00,       // PUSH1 0
            0x52,             // MSTORE
            0x60, 0x20,       // PUSH1 32
            0x60, 0x00,       // PUSH1 0
            0xF3,             // RETURN
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
            // Check that the result is 0
            var expected = [_]u8{0} ** 32;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }
}

test "Bitwise: NOT operations" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Test: NOT of 0 gives all 1s
    {
        const bytecode = &[_]u8{
            0x60, 0x00, // PUSH1 0
            0x19,       // NOT
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
            // Check that the result is all 1s
            var expected = [_]u8{0xFF} ** 32;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }
}

test "Bitwise: BYTE operation" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Test: Get byte 31 (rightmost) from 0x..ABCD
    {
        const bytecode = &[_]u8{
            0x61, 0xAB, 0xCD, // PUSH2 0xABCD
            0x60, 0x1F,       // PUSH1 31 (get rightmost byte)
            0x1A,             // BYTE
            0x60, 0x00,       // PUSH1 0
            0x52,             // MSTORE
            0x60, 0x20,       // PUSH1 32
            0x60, 0x00,       // PUSH1 0
            0xF3,             // RETURN
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
        }};

        const result = try vm.call(call_params);
        try testing.expect(result.success);
        if (result.output) |_| {
            try testing.expectEqual(@as(usize, 32), output.len);
            // Check that the result is 0xCD
            var expected = [_]u8{0} ** 32;
            expected[31] = 0xCD;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }
}

test "Bitwise: SHL (shift left)" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Test: 1 << 4 = 16
    {
        const bytecode = &[_]u8{
            0x60, 0x01, // PUSH1 1
            0x60, 0x04, // PUSH1 4
            0x1B,       // SHL
            0x60, 0x00, // PUSH1 0
            0x52,       // MSTORE
            0x60, 0x20, // PUSH1 32
            0x60, 0x00, // PUSH1 0
            0xF3,       // RETURN
        };

        const contract_addr = testAddress(0x1006);
        const caller = testAddress(0x2006);

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
            // Check that the result is 16
            var expected = [_]u8{0} ** 32;
            expected[31] = 16;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }
}

test "Bitwise: SHR (shift right)" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Test: 16 >> 4 = 1
    {
        const bytecode = &[_]u8{
            0x60, 0x10, // PUSH1 16
            0x60, 0x04, // PUSH1 4
            0x1C,       // SHR
            0x60, 0x00, // PUSH1 0
            0x52,       // MSTORE
            0x60, 0x20, // PUSH1 32
            0x60, 0x00, // PUSH1 0
            0xF3,       // RETURN
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
        }};

        const result = try vm.call(call_params);
        try testing.expect(result.success);
        if (result.output) |_| {
            try testing.expectEqual(@as(usize, 32), output.len);
            // Check that the result is 1
            var expected = [_]u8{0} ** 32;
            expected[31] = 1;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }
}