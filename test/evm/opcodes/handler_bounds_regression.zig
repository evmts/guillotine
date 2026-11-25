const std = @import("std");
const evm = @import("evm");
const testing = std.testing;
const primitives = @import("voltaire");
const Address = primitives.Address;

// Regression tests for opcode operand handling found by the EEST state tests
// (stMemoryTest/buffer, stMemoryTest/buffer_src_offset, eip1052_extcodehash) and for
// SSTORE journaling across reverted calls. Each test runs real bytecode through the EVM.

test "LOG2 with a length that wraps offset plus length halts the frame" {
    const allocator = testing.allocator;

    const contract_address = Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
    const caller_address = Address.fromHex("0x1111111111111111111111111111111111111111") catch unreachable;

    var database = evm.Database.init(allocator);
    defer database.deinit();

    const block_info = evm.BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = @as([32]u8, @splat(0)),
        .chain_id = 1,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };
    const tx_context = evm.TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var vm = try evm.Evm(.{}).init(allocator, &database, block_info, tx_context, 0, caller_address);
    defer vm.deinit();

    try database.set_account(caller_address.bytes, .{
        .balance = 1_000_000_000,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    });

    // PUSH1 2, PUSH1 1, PUSH8 0xffffffffffffffff (length), PUSH1 5 (offset), LOG2, STOP
    const bytecode = [_]u8{ 0x60, 0x02, 0x60, 0x01, 0x67, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x60, 0x05, 0xa2, 0x00 };
    const code_hash = try database.set_code(&bytecode);
    try database.set_account(contract_address.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
    });

    var result = vm.call(evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = &[_]u8{},
            .gas = 500_000,
        },
    });
    defer result.deinit(allocator);

    try testing.expect(!result.success);
    try testing.expectEqual(@as(usize, 0), result.logs.len);
}

test "LOG0 without data ignores its offset" {
    const allocator = testing.allocator;

    const contract_address = Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
    const caller_address = Address.fromHex("0x1111111111111111111111111111111111111111") catch unreachable;

    var database = evm.Database.init(allocator);
    defer database.deinit();

    const block_info = evm.BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = @as([32]u8, @splat(0)),
        .chain_id = 1,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };
    const tx_context = evm.TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var vm = try evm.Evm(.{}).init(allocator, &database, block_info, tx_context, 0, caller_address);
    defer vm.deinit();

    try database.set_account(caller_address.bytes, .{
        .balance = 1_000_000_000,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    });

    // PUSH1 0 (length), PUSH32 0xff..ff (offset), LOG0, STOP
    const bytecode = [_]u8{ 0x60, 0x00, 0x7f } ++ @as([32]u8, @splat(0xff)) ++ [_]u8{ 0xa0, 0x00 };
    const code_hash = try database.set_code(&bytecode);
    try database.set_account(contract_address.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
    });

    var result = vm.call(evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = &[_]u8{},
            .gas = 500_000,
        },
    });
    defer result.deinit(allocator);

    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 1), result.logs.len);
    try testing.expectEqual(@as(usize, 0), result.logs[0].data.len);
}

test "CODECOPY of zero bytes ignores its destination offset" {
    const allocator = testing.allocator;

    const contract_address = Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
    const caller_address = Address.fromHex("0x1111111111111111111111111111111111111111") catch unreachable;

    var database = evm.Database.init(allocator);
    defer database.deinit();

    const block_info = evm.BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = @as([32]u8, @splat(0)),
        .chain_id = 1,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };
    const tx_context = evm.TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var vm = try evm.Evm(.{}).init(allocator, &database, block_info, tx_context, 0, caller_address);
    defer vm.deinit();

    try database.set_account(caller_address.bytes, .{
        .balance = 1_000_000_000,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    });

    // PUSH1 0 (length), PUSH1 0 (offset), PUSH32 0xff..ff (dest), CODECOPY, PUSH1 1, PUSH1 0, SSTORE, STOP
    const bytecode = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x7f } ++ @as([32]u8, @splat(0xff)) ++ [_]u8{ 0x39, 0x60, 0x01, 0x60, 0x00, 0x55, 0x00 };
    const code_hash = try database.set_code(&bytecode);
    try database.set_account(contract_address.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
    });

    var result = vm.call(evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = &[_]u8{},
            .gas = 500_000,
        },
    });
    defer result.deinit(allocator);

    try testing.expect(result.success);
    try testing.expectEqual(@as(u256, 1), try database.get_storage(contract_address.bytes, 0));
}

test "CODECOPY reads zeros from a source offset beyond the code" {
    const allocator = testing.allocator;

    const contract_address = Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
    const caller_address = Address.fromHex("0x1111111111111111111111111111111111111111") catch unreachable;

    var database = evm.Database.init(allocator);
    defer database.deinit();

    const block_info = evm.BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = @as([32]u8, @splat(0)),
        .chain_id = 1,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };
    const tx_context = evm.TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var vm = try evm.Evm(.{}).init(allocator, &database, block_info, tx_context, 0, caller_address);
    defer vm.deinit();

    try database.set_account(caller_address.bytes, .{
        .balance = 1_000_000_000,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    });

    // PUSH1 0xaa, PUSH1 0, MSTORE, PUSH1 32 (length), PUSH32 0xff..ff (offset), PUSH1 0 (dest), CODECOPY, PUSH1 0, MLOAD, PUSH1 1, ADD, PUSH1 0, SSTORE, STOP
    const bytecode = [_]u8{ 0x60, 0xaa, 0x60, 0x00, 0x52, 0x60, 0x20, 0x7f } ++ @as([32]u8, @splat(0xff)) ++ [_]u8{ 0x60, 0x00, 0x39, 0x60, 0x00, 0x51, 0x60, 0x01, 0x01, 0x60, 0x00, 0x55, 0x00 };
    const code_hash = try database.set_code(&bytecode);
    try database.set_account(contract_address.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
    });

    var result = vm.call(evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = &[_]u8{},
            .gas = 500_000,
        },
    });
    defer result.deinit(allocator);

    try testing.expect(result.success);
    // The copy overwrote 0xaa with zeros, so slot 0 holds 0 + 1.
    try testing.expectEqual(@as(u256, 1), try database.get_storage(contract_address.bytes, 0));
}

test "KECCAK256 of zero bytes ignores its offset" {
    const allocator = testing.allocator;

    const contract_address = Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
    const caller_address = Address.fromHex("0x1111111111111111111111111111111111111111") catch unreachable;

    var database = evm.Database.init(allocator);
    defer database.deinit();

    const block_info = evm.BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = @as([32]u8, @splat(0)),
        .chain_id = 1,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };
    const tx_context = evm.TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var vm = try evm.Evm(.{}).init(allocator, &database, block_info, tx_context, 0, caller_address);
    defer vm.deinit();

    try database.set_account(caller_address.bytes, .{
        .balance = 1_000_000_000,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    });

    // PUSH1 0 (size), PUSH32 0xff..ff (offset), KECCAK256, PUSH1 0, SSTORE, STOP
    const bytecode = [_]u8{ 0x60, 0x00, 0x7f } ++ @as([32]u8, @splat(0xff)) ++ [_]u8{ 0x20, 0x60, 0x00, 0x55, 0x00 };
    const code_hash = try database.set_code(&bytecode);
    try database.set_account(contract_address.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
    });

    var result = vm.call(evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = &[_]u8{},
            .gas = 500_000,
        },
    });
    defer result.deinit(allocator);

    try testing.expect(result.success);
    try testing.expectEqual(
        @as(u256, 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470),
        try database.get_storage(contract_address.bytes, 0),
    );
}

test "EXTCODEHASH of an existing but empty account is zero" {
    const allocator = testing.allocator;

    const contract_address = Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
    const caller_address = Address.fromHex("0x1111111111111111111111111111111111111111") catch unreachable;

    var database = evm.Database.init(allocator);
    defer database.deinit();

    const block_info = evm.BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = @as([32]u8, @splat(0)),
        .chain_id = 1,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };
    const tx_context = evm.TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var vm = try evm.Evm(.{}).init(allocator, &database, block_info, tx_context, 0, caller_address);
    defer vm.deinit();

    try database.set_account(caller_address.bytes, .{
        .balance = 1_000_000_000,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    });

    // An account that exists in the state but has no nonce, balance or code (EIP-161 empty).
    try database.set_account((@as([20]u8, @splat(0xee))), .{
        .balance = 0,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    });

    // PUSH1 7, PUSH1 0, SSTORE, PUSH20 empty_address, EXTCODEHASH, PUSH1 0, SSTORE, STOP
    const bytecode = [_]u8{ 0x60, 0x07, 0x60, 0x00, 0x55, 0x73 } ++ @as([20]u8, @splat(0xee)) ++ [_]u8{ 0x3f, 0x60, 0x00, 0x55, 0x00 };
    const code_hash = try database.set_code(&bytecode);
    try database.set_account(contract_address.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
    });

    var result = vm.call(evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = &[_]u8{},
            .gas = 500_000,
        },
    });
    defer result.deinit(allocator);

    try testing.expect(result.success);
    // The hash overwrote the 7 stored first, so slot 0 is 0 only if EXTCODEHASH pushed 0.
    try testing.expectEqual(@as(u256, 0), try database.get_storage(contract_address.bytes, 0));
}

test "EXTCODEHASH of an account with only a balance is the empty code hash" {
    const allocator = testing.allocator;

    const contract_address = Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
    const caller_address = Address.fromHex("0x1111111111111111111111111111111111111111") catch unreachable;

    var database = evm.Database.init(allocator);
    defer database.deinit();

    const block_info = evm.BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = @as([32]u8, @splat(0)),
        .chain_id = 1,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };
    const tx_context = evm.TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var vm = try evm.Evm(.{}).init(allocator, &database, block_info, tx_context, 0, caller_address);
    defer vm.deinit();

    try database.set_account(caller_address.bytes, .{
        .balance = 1_000_000_000,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    });

    try database.set_account((@as([20]u8, @splat(0xee))), .{
        .balance = 1,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    });

    // PUSH20 funded_address, EXTCODEHASH, PUSH1 0, SSTORE, STOP
    const bytecode = [_]u8{ 0x73 } ++ @as([20]u8, @splat(0xee)) ++ [_]u8{ 0x3f, 0x60, 0x00, 0x55, 0x00 };
    const code_hash = try database.set_code(&bytecode);
    try database.set_account(contract_address.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
    });

    var result = vm.call(evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = &[_]u8{},
            .gas = 500_000,
        },
    });
    defer result.deinit(allocator);

    try testing.expect(result.success);
    try testing.expectEqual(
        @as(u256, 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470),
        try database.get_storage(contract_address.bytes, 0),
    );
}

test "SSTORE in a reverted call is undone when the caller wrote the slot first" {
    const allocator = testing.allocator;

    const contract_address = Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
    const caller_address = Address.fromHex("0x1111111111111111111111111111111111111111") catch unreachable;

    var database = evm.Database.init(allocator);
    defer database.deinit();

    const block_info = evm.BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = @as([32]u8, @splat(0)),
        .chain_id = 1,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };
    const tx_context = evm.TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var vm = try evm.Evm(.{}).init(allocator, &database, block_info, tx_context, 0, caller_address);
    defer vm.deinit();

    try database.set_account(caller_address.bytes, .{
        .balance = 1_000_000_000,
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    });

    // CALLDATASIZE, PUSH1 0x19, JUMPI, PUSH1 1, PUSH1 0, SSTORE, PUSH1 0, PUSH1 0, PUSH1 1, PUSH1 0, PUSH1 0, ADDRESS, PUSH2 0xffff, CALL, STOP, JUMPDEST, PUSH1 2, PUSH1 0, SSTORE, INVALID
    // Without calldata the contract stores 1 in slot 0 and calls itself with one byte of
    // calldata; that inner call stores 2 in slot 0 and then halts on INVALID.
    const bytecode = [_]u8{ 0x36, 0x60, 0x19, 0x57, 0x60, 0x01, 0x60, 0x00, 0x55, 0x60, 0x00, 0x60, 0x00, 0x60, 0x01, 0x60, 0x00, 0x60, 0x00, 0x30, 0x61, 0xff, 0xff, 0xf1, 0x00, 0x5b, 0x60, 0x02, 0x60, 0x00, 0x55, 0xfe };
    const code_hash = try database.set_code(&bytecode);
    try database.set_account(contract_address.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
    });

    var result = vm.call(evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = &[_]u8{},
            .gas = 500_000,
        },
    });
    defer result.deinit(allocator);

    try testing.expect(result.success);
    try testing.expectEqual(@as(u256, 1), try database.get_storage(contract_address.bytes, 0));
}
