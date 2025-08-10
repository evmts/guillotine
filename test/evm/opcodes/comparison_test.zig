const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

// Helper function to create test addresses
fn testAddress(value: u160) primitives.Address.Address {
    return primitives.Address.from_u256(@as(u256, value));
}

test "Comparison: LT (less than) operations" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Test 1: 5 < 10 = true
    {
        const bytecode = &[_]u8{
            0x60, 0x0A, // PUSH1 10
            0x60, 0x05, // PUSH1 5
            0x10, // LT
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
            // Check that the result is 1 (true)
            var expected = [_]u8{0} ** 32;
            expected[31] = 1;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }

    // Test 2: 10 < 5 = false
    {
        const bytecode = &[_]u8{
            0x60, 0x05, // PUSH1 5
            0x60, 0x0A, // PUSH1 10
            0x10, // LT
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
            // Check that the result is 0 (false)
            var expected = [_]u8{0} ** 32;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }

    // Test 3: 42 < 42 = false
    {
        const bytecode = &[_]u8{
            0x60, 0x2A, // PUSH1 42
            0x60, 0x2A, // PUSH1 42
            0x10, // LT
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
            // Check that the result is 0 (false)
            var expected = [_]u8{0} ** 32;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }
}

test "Comparison: GT (greater than) operations" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Test: 10 > 5 = true
    {
        const bytecode = &[_]u8{
            0x60, 0x05, // PUSH1 5
            0x60, 0x0A, // PUSH1 10
            0x11, // GT
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
            // Check that the result is 1 (true)
            var expected = [_]u8{0} ** 32;
            expected[31] = 1;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }
}

test "Comparison: EQ (equal) operations" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Test 1: 42 == 42 = true
    {
        const bytecode = &[_]u8{
            0x60, 0x2A, // PUSH1 42
            0x60, 0x2A, // PUSH1 42
            0x14, // EQ
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
            // Check that the result is 1 (true)
            var expected = [_]u8{0} ** 32;
            expected[31] = 1;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }

    // Test 2: 10 == 5 = false
    {
        const bytecode = &[_]u8{
            0x60, 0x05, // PUSH1 5
            0x60, 0x0A, // PUSH1 10
            0x14, // EQ
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
            // Check that the result is 0 (false)
            var expected = [_]u8{0} ** 32;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }
}

test "Comparison: ISZERO operations" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Test 1: ISZERO(0) = true
    {
        const bytecode = &[_]u8{
            0x60, 0x00, // PUSH1 0
            0x15, // ISZERO
            0x60, 0x00, // PUSH1 0
            0x52, // MSTORE
            0x60, 0x20, // PUSH1 32
            0x60, 0x00, // PUSH1 0
            0xF3, // RETURN
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
        } };

        const result = try vm.call(call_params);
        defer if (result.output) |output| allocator.free(output);

        try testing.expect(result.success);
        if (result.output) |output| {
            try testing.expectEqual(@as(usize, 32), output.len);
            // Check that the result is 1 (true)
            var expected = [_]u8{0} ** 32;
            expected[31] = 1;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }

    // Test 2: ISZERO(42) = false
    {
        const bytecode = &[_]u8{
            0x60, 0x2A, // PUSH1 42
            0x15, // ISZERO
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
            // Check that the result is 0 (false)
            var expected = [_]u8{0} ** 32;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }
}

test "Comparison: SLT (signed less than) operations" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Test: -1 < 1 = true (in two's complement, -1 is 0xFF...FF)
    {
        const bytecode = &[_]u8{
            0x60, 0x01, // PUSH1 1
            0x7F, // PUSH32
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // -1 in two's complement
            0x12, // SLT
            0x60, 0x00, // PUSH1 0
            0x52, // MSTORE
            0x60, 0x20, // PUSH1 32
            0x60, 0x00, // PUSH1 0
            0xF3, // RETURN
        };

        const contract_addr = testAddress(0x1008);
        const caller = testAddress(0x2008);

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
            // Check that the result is 1 (true)
            var expected = [_]u8{0} ** 32;
            expected[31] = 1;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }
}

test "Comparison: SGT (signed greater than) operations" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Test: 1 > -1 = true
    {
        const bytecode = &[_]u8{
            0x7F, // PUSH32
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF,
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // -1 in two's complement
            0x60, 0x01, // PUSH1 1
            0x13, // SGT
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
            // Check that the result is 1 (true)
            var expected = [_]u8{0} ** 32;
            expected[31] = 1;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }
}
