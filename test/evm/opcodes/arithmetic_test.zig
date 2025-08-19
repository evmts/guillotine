const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

// Helper function to create test addresses
fn testAddress(value: u160) primitives.Address.Address {
    return primitives.Address.from_u256(@as(u256, value));
}

test "Arithmetic: ADD basic operations" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Test 1: Simple addition (5 + 10 = 15)
    {
        const bytecode = &[_]u8{
            0x60, 0x05, // PUSH1 5
            0x60, 0x0A, // PUSH1 10
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
            // Check that the result is 15 (stored as big-endian u256)
            var expected = [_]u8{0} ** 32;
            expected[31] = 15;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }

    // Test 2: Addition with overflow (MAX_U256 + 1 = 0)
    {
        const bytecode = &[_]u8{
            0x7F, // PUSH32
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // MAX_U256
            0x60, 0x01, // PUSH1 1
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
            // Check that the result is 0 (overflow wraps)
            var expected = [_]u8{0} ** 32;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }
}

test "Arithmetic: SUB basic operations" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Test: Simple subtraction (100 - 58 = 42)
    {
        const bytecode = &[_]u8{
            0x60, 0x3A, // PUSH1 58
            0x60, 0x64, // PUSH1 100
            0x03,       // SUB
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
            var expected = [_]u8{0} ** 32;
            expected[31] = 42;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }
}

// Remaining tests commented out - will migrate them incrementally
// - MUL, DIV, MOD 
// - ADDMOD, MULMOD
// - EXP
// - Stack underflow errors
