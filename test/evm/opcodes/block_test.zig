const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

test {
    std.testing.log_level = .debug;
}

// Helper function to create test addresses
fn testAddress(value: u160) primitives.Address.Address {
    return primitives.Address.from_u256(@as(u256, value));
}

test "Block: BLOCKHASH operations" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Set up block context
    const tx_origin = testAddress(0x1111);
    const block_coinbase = testAddress(0xCCCC);
    const context = evm.Context.init_with_values(
        tx_origin, // tx_origin
        0, // gas_price
        1000, // block_number
        0, // block_timestamp
        block_coinbase, // block_coinbase
        0, // block_difficulty
        0, // block_gas_limit
        1, // chain_id
        0, // block_base_fee
        &[_]u256{}, // blob_hashes
        0, // blob_base_fee
    );
    vm.set_context(context);

    // Test 1: Get blockhash for recent block (should return a hash)
    {
        const bytecode = &[_]u8{
            0x61, 0x03, 0xE7, // PUSH2 999 (block number - 1 block ago)
            0x40, // BLOCKHASH
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
            // Should return a non-zero hash for recent blocks
            var all_zero = true;
            for (output) |byte| {
                if (byte != 0) {
                    all_zero = false;
                    break;
                }
            }
            try testing.expect(!all_zero);
        }
    }

    // Test 2: Block number too old (> 256 blocks ago)
    {
        const bytecode = &[_]u8{
            0x61, 0x02, 0xBC, // PUSH2 700 (more than 256 blocks ago)
            0x40, // BLOCKHASH
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
            // Should return 0 for old blocks
            var expected = [_]u8{0} ** 32;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }

    // Test 3: Future block number
    {
        const bytecode = &[_]u8{
            0x61, 0x03, 0xE9, // PUSH2 1001 (future block)
            0x40, // BLOCKHASH
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
            // Should return 0 for future blocks
            var expected = [_]u8{0} ** 32;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }
}

test "Block: COINBASE operations" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Set coinbase address
    const tx_origin = testAddress(0x1111);
    const block_coinbase = testAddress(0xCCCC);
    const context = evm.Context.init_with_values(
        tx_origin, // tx_origin
        0, // gas_price
        0, // block_number
        0, // block_timestamp
        block_coinbase, // block_coinbase
        0, // block_difficulty
        0, // block_gas_limit
        1, // chain_id
        0, // block_base_fee
        &[_]u256{}, // blob_hashes
        0, // blob_base_fee
    );
    vm.set_context(context);

    const bytecode = &[_]u8{
        0x41, // COINBASE
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
        // Check that the result is the coinbase address
        var expected = [_]u8{0} ** 32;
        const coinbase_bytes = @as([20]u8, block_coinbase);
        @memcpy(expected[12..32], &coinbase_bytes);
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

test "Block: TIMESTAMP operations" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Set block timestamp
    const tx_origin = testAddress(0x1111);
    const block_coinbase = testAddress(0x1111);
    const context = evm.Context.init_with_values(
        tx_origin, // tx_origin
        0, // gas_price
        0, // block_number
        1234567890, // block_timestamp
        block_coinbase, // block_coinbase
        0, // block_difficulty
        0, // block_gas_limit
        1, // chain_id
        0, // block_base_fee
        &[_]u256{}, // blob_hashes
        0, // blob_base_fee
    );
    vm.set_context(context);

    const bytecode = &[_]u8{
        0x42, // TIMESTAMP
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
        // Check that the result is 1234567890
        var expected = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &expected, 1234567890, .big);
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

test "Block: NUMBER operations" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Set block number
    const tx_origin = testAddress(0x1111);
    const block_coinbase = testAddress(0x1111);
    const context = evm.Context.init_with_values(
        tx_origin, // tx_origin
        0, // gas_price
        987654321, // block_number
        0, // block_timestamp
        block_coinbase, // block_coinbase
        0, // block_difficulty
        0, // block_gas_limit
        1, // chain_id
        0, // block_base_fee
        &[_]u256{}, // blob_hashes
        0, // blob_base_fee
    );
    vm.set_context(context);

    const bytecode = &[_]u8{
        0x43, // NUMBER
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
        // Check that the result is 987654321
        var expected = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &expected, 987654321, .big);
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

test "Block: DIFFICULTY/PREVRANDAO operations" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Set difficulty/prevrandao
    const tx_origin = testAddress(0x1111);
    const block_coinbase = testAddress(0x1111);
    const context = evm.Context.init_with_values(
        tx_origin, // tx_origin
        0, // gas_price
        0, // block_number
        0, // block_timestamp
        block_coinbase, // block_coinbase
        0x123456789ABCDEF0, // block_difficulty
        0, // block_gas_limit
        1, // chain_id
        0, // block_base_fee
        &[_]u256{}, // blob_hashes
        0, // blob_base_fee
    );
    vm.set_context(context);

    const bytecode = &[_]u8{
        0x44, // DIFFICULTY
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
        // Check that the result is 0x123456789ABCDEF0
        var expected = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &expected, 0x123456789ABCDEF0, .big);
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

test "Block: GASLIMIT operations" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Set gas limit
    const tx_origin = testAddress(0x1111);
    const block_coinbase = testAddress(0x1111);
    const context = evm.Context.init_with_values(
        tx_origin, // tx_origin
        0, // gas_price
        0, // block_number
        0, // block_timestamp
        block_coinbase, // block_coinbase
        0, // block_difficulty
        30_000_000, // block_gas_limit
        1, // chain_id
        0, // block_base_fee
        &[_]u256{}, // blob_hashes
        0, // blob_base_fee
    );
    vm.set_context(context);

    const bytecode = &[_]u8{
        0x45, // GASLIMIT
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
        // Check that the result is 30_000_000
        var expected = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &expected, 30_000_000, .big);
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

test "Block: BASEFEE operations (London)" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Set base fee
    const tx_origin = testAddress(0x1111);
    const block_coinbase = testAddress(0x1111);
    const context = evm.Context.init_with_values(
        tx_origin, // tx_origin
        0, // gas_price
        0, // block_number
        0, // block_timestamp
        block_coinbase, // block_coinbase
        0, // block_difficulty
        0, // block_gas_limit
        1, // chain_id
        1_000_000_000, // block_base_fee (1 gwei)
        &[_]u256{}, // blob_hashes
        0, // blob_base_fee
    );
    vm.set_context(context);

    const bytecode = &[_]u8{
        0x48, // BASEFEE
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
        // Check that the result is 1_000_000_000
        var expected = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &expected, 1_000_000_000, .big);
        try testing.expectEqualSlices(u8, &expected, output);
    }
}

test "Block: BLOBHASH operations (Cancun)" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Set up blob hashes
    const blob_hashes = [_]u256{
        0x1111111111111111111111111111111111111111111111111111111111111111,
        0x2222222222222222222222222222222222222222222222222222222222222222,
        0x3333333333333333333333333333333333333333333333333333333333333333,
    };
    const tx_origin = testAddress(0x1111);
    const block_coinbase = testAddress(0x1111);
    const context = evm.Context.init_with_values(
        tx_origin, // tx_origin
        0, // gas_price
        0, // block_number
        0, // block_timestamp
        block_coinbase, // block_coinbase
        0, // block_difficulty
        0, // block_gas_limit
        1, // chain_id
        0, // block_base_fee
        &blob_hashes, // blob_hashes
        0, // blob_base_fee
    );
    vm.set_context(context);

    // Test 1: Get first blob hash
    {
        const bytecode = &[_]u8{
            0x60, 0x00, // PUSH1 0
            0x49, // BLOBHASH
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
            // Check that the result is first blob hash
            var expected = [_]u8{0} ** 32;
            std.mem.writeInt(u256, &expected, 0x1111111111111111111111111111111111111111111111111111111111111111, .big);
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }

    // Test 2: Get second blob hash
    {
        const bytecode = &[_]u8{
            0x60, 0x01, // PUSH1 1
            0x49, // BLOBHASH
            0x60, 0x00, // PUSH1 0
            0x52, // MSTORE
            0x60, 0x20, // PUSH1 32
            0x60, 0x00, // PUSH1 0
            0xF3, // RETURN
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

        try testing.expect(result.success);
        if (result.output) |output| {
            try testing.expectEqual(@as(usize, 32), output.len);
            // Check that the result is second blob hash
            var expected = [_]u8{0} ** 32;
            std.mem.writeInt(u256, &expected, 0x2222222222222222222222222222222222222222222222222222222222222222, .big);
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }

    // Test 3: Out of bounds index
    {
        const bytecode = &[_]u8{
            0x60, 0x03, // PUSH1 3 (out of bounds)
            0x49, // BLOBHASH
            0x60, 0x00, // PUSH1 0
            0x52, // MSTORE
            0x60, 0x20, // PUSH1 32
            0x60, 0x00, // PUSH1 0
            0xF3, // RETURN
        };

        const contract_addr = testAddress(0x100B);
        const caller = testAddress(0x200B);

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
            // Should return 0 for out of bounds
            var expected = [_]u8{0} ** 32;
            try testing.expectEqualSlices(u8, &expected, output);
        }
    }
}

test "Block: BLOBBASEFEE operations (Cancun)" {
    const allocator = testing.allocator;

    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Set blob base fee
    const tx_origin = testAddress(0x1111);
    const block_coinbase = testAddress(0x1111);
    const context = evm.Context.init_with_values(
        tx_origin, // tx_origin
        0, // gas_price
        0, // block_number
        0, // block_timestamp
        block_coinbase, // block_coinbase
        0, // block_difficulty
        0, // block_gas_limit
        1, // chain_id
        0, // block_base_fee
        &[_]u256{}, // blob_hashes
        100_000_000, // blob_base_fee (0.1 gwei)
    );
    vm.set_context(context);

    const bytecode = &[_]u8{
        0x4A, // BLOBBASEFEE
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    const contract_addr = testAddress(0x100C);
    const caller = testAddress(0x200C);

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
        // Check that the result is 100_000_000
        var expected = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &expected, 100_000_000, .big);
        try testing.expectEqualSlices(u8, &expected, output);
    }
}
