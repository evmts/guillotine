const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");
const common = @import("common.zig");

test "precompile availability persists through successor forks" {
    const address = primitives.Address.fromU256;
    inline for (.{ evm.Hardfork.BERLIN, evm.Hardfork.LONDON, evm.Hardfork.PRAGUE, evm.Hardfork.OSAKA }) |fork| {
        try std.testing.expect(evm.precompiles.isPrecompile(address(5), fork));
        try std.testing.expect(evm.precompiles.isPrecompile(address(9), fork));
        try std.testing.expect(!evm.precompiles.isPrecompile(address(0), fork));
        try std.testing.expect(!evm.precompiles.isPrecompile(address(0x14), fork));
    }
    try std.testing.expect(!evm.precompiles.isPrecompile(address(5), .HOMESTEAD));
    try std.testing.expect(!evm.precompiles.isPrecompile(address(0x0a), .LONDON));
    try std.testing.expect(evm.precompiles.isPrecompile(address(0x0a), .CANCUN));
    try std.testing.expect(!evm.precompiles.isPrecompile(address(0x0b), .CANCUN));
    try std.testing.expect(evm.precompiles.isPrecompile(address(0x0b), .OSAKA));
}

test "STATICCALL ModExp preserves Prague pricing and activates Osaka bounds" {
    const allocator = std.testing.allocator;
    inline for (.{ evm.Hardfork.PRAGUE, evm.Hardfork.OSAKA }) |fork| {
        inline for (.{ false, true }) |fusion| {
            const Engine = evm.Evm(.{ .eips = .{ .hardfork = fork }, .enable_fusion = fusion });
            try std.testing.expect(@typeInfo(@TypeOf(Engine.Frame.getEvm)).@"fn".return_type.? == *Engine);
            for ([_]u16{ 0, 1024, 1025 }) |base_length| {
                for ([_]u16{ 499, 500, 32768 }) |forwarded_gas| {
                    var database = evm.Database.init(allocator);
                    defer database.deinit();
                    const caller = primitives.Address.fromU256(0x100);
                    const contract = primitives.Address.fromU256(0x200);
                    // Store base_length in the length header, then STATICCALL 0x05.
                    // The empty exponent and modulus still exercise Osaka bounds.
                    var code = [_]u8{
                        0x61, 0,    0,    0x60, 0,    0x52,
                        0x60, 0,    0x60, 0,    0x60, 96,
                        0x60, 0,    0x60, 5,    0x61, 0,
                        0,    0xfa, 0x60, 0,    0x52, 0x60,
                        32,   0x60, 0,    0xf3,
                    };
                    std.mem.writeInt(u16, code[1..3], base_length, .big);
                    std.mem.writeInt(u16, code[17..19], forwarded_gas, .big);
                    const hash = try database.set_code(&code);
                    try database.set_account(contract.bytes, .{
                        .balance = 0,
                        .nonce = 0,
                        .code_hash = hash,
                        .storage_root = @as([32]u8, @splat(0)),
                    });
                    var engine = try Engine.init(allocator, &database, .{
                        .chain_id = 1,
                        .number = 24_000_000,
                        .timestamp = 1_764_798_551,
                        .difficulty = 0,
                        .gas_limit = 60_000_000,
                        .coinbase = primitives.ZERO_ADDRESS,
                        .base_fee = 0,
                        .prev_randao = @as([32]u8, @splat(0)),
                        .blob_base_fee = 1,
                        .blob_versioned_hashes = &.{},
                    }, .{ .gas_limit = 100_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, caller);
                    defer engine.deinit();
                    var result = engine.call(.{ .call = .{
                        .caller = caller,
                        .to = contract,
                        .value = 0,
                        .input = &.{},
                        .gas = 100_000,
                    } });
                    defer result.deinit(allocator);
                    const reference = try evm.MinimalEvm.initPtr(allocator);
                    defer reference.deinitPtr(allocator);
                    reference.setHardfork(fork);
                    const reference_result = try reference.execute(&code, 100_000, caller, contract, 0, &.{});
                    const accepted = if (base_length == 0)
                        fork == .PRAGUE or forwarded_gas >= 500
                    else
                        forwarded_gas == 32768 and (fork == .PRAGUE or base_length == 1024);
                    const expected_success: u8 = @intFromBool(accepted);
                    var expected = @as([32]u8, @splat(0));
                    expected[31] = expected_success;
                    try std.testing.expect(result.success);
                    try std.testing.expect(reference_result.success);
                    if (!std.mem.eql(u8, &expected, result.output) or !std.mem.eql(u8, &expected, reference_result.output)) {
                        std.debug.print("ModExp fork={s} fusion={} base={d} gas={d} expected={d} engine={x} reference={x}\n", .{ @tagName(fork), fusion, base_length, forwarded_gas, expected_success, result.output, reference_result.output });
                    }
                    try std.testing.expectEqualSlices(u8, &expected, result.output);
                    try std.testing.expectEqualSlices(u8, &expected, reference_result.output);
                    try std.testing.expectEqual(result.gas_left, reference_result.gas_left);
                    const modexp_gas: u64 = if (!accepted) forwarded_gas else if (base_length == 0) (if (fork == .PRAGUE) 200 else 500) else if (fork == .OSAKA) 32768 else if (base_length == 1024) 5461 else 5547;
                    // 21,000 intrinsic + 148 bytecode gas (including 100 warm
                    // STATICCALL and expansion to three words), then ModExp.
                    try std.testing.expectEqual(@as(u64, 100_000 - 21_000 - 148) - modexp_gas, result.gas_left);
                }
            }
        }
    }
}

test "opcode 0xfa differential test" {
    const allocator = std.testing.allocator;

    // Build bytecode for this opcode
    const bytecode = try common.build_bytecode(allocator, 0xfa);
    defer allocator.free(bytecode);

    // Setup Guillotine EVM
    var database = evm.Database.init(allocator);
    defer database.deinit();

    const caller_address = primitives.Address{ .bytes = [_]u8{0x10} ++ @as([18]u8, @splat(0)) ++ [_]u8{0x01} };
    const contract_address = primitives.Address{ .bytes = [_]u8{0x20} ++ @as([18]u8, @splat(0)) ++ [_]u8{0x02} };

    // Set the bytecode on the contract account
    const code_hash = try database.set_code(bytecode);

    try database.set_account(contract_address.bytes, .{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
    });

    // Set up caller as EOA with balance
    try database.set_account(caller_address.bytes, .{
        .balance = std.math.maxInt(u256),
        .nonce = 0,
        .code_hash = @as([32]u8, @splat(0)), // Empty code hash for EOA
        .storage_root = @as([32]u8, @splat(0)),
    });

    const block_info = evm.BlockInfo{
        .chain_id = 1,
        .number = 20_000_000,
        .timestamp = 1_800_000_000,
        .difficulty = 0,
        .gas_limit = 1_000_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 7,
        .prev_randao = @as([32]u8, @splat(0)),
        .blob_base_fee = 1000000000,
        .blob_versioned_hashes = &.{},
    };

    const tx_context = evm.TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var guillotine_evm = try evm.Evm(.{}).init(allocator, &database, block_info, tx_context, 0, caller_address);
    defer guillotine_evm.deinit();

    // Execute with Guillotine using call
    const call_params = evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = &.{}, // Empty input - code is on the account
            .gas = 1_000_000,
        },
    };

    var guillotine_result = guillotine_evm.call(call_params);
    defer guillotine_result.deinit(allocator);
}
