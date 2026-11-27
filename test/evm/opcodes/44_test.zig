const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");
const common = @import("common.zig");

test "opcode 0x44 differential test" {
    const allocator = std.testing.allocator;
    
    // Build bytecode for this opcode
    const bytecode = try common.build_bytecode(allocator, 0x44);
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
        .allow_gas_price_below_base_fee = true,
    };
    
    var guillotine_evm = try evm.Evm(.{
    }).init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address

    );
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

test "PREVRANDAO fork transition with distinct difficulty and traced randomness" {
    const allocator = std.testing.allocator;
    const randao = [32]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32 };
    inline for (.{ .LONDON, .MERGE, .CANCUN }) |fork| {
        var database = evm.Database.init(allocator);
        defer database.deinit();
        const caller = primitives.Address{ .bytes = @splat(0x10) };
        const contract = primitives.Address{ .bytes = @splat(0x20) };
        const hash = try database.set_code(&.{ 0x44, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 });
        try database.set_account(contract.bytes, .{
            .balance = 0,
            .nonce = 1,
            .code_hash = hash,
            .storage_root = @splat(0),
        });
        var vm = try evm.Evm(.{
            .eips = .{ .hardfork = fork },
            .enable_fusion = false,
            .tracer_config = .{ .enabled = true, .enable_validation = true },
        }).init(allocator, &database, .{
            .gas_limit = 30_000_000,
            .coinbase = primitives.ZERO_ADDRESS,
            .number = 1,
            .timestamp = 1,
            .difficulty = 0x20000,
            .base_fee = 0,
            .prev_randao = randao,
        }, .{ .gas_limit = 1_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, caller);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = caller, .to = contract, .value = 0, .input = &.{}, .gas = 1_000_000 } });
        defer result.deinit(allocator);
        try std.testing.expect(result.success);
        try std.testing.expect(vm.tracer.minimal_evm != null);
        var expected = randao;
        if (fork == .LONDON) {
            expected = @splat(0);
            expected[29] = 2;
        }
        try std.testing.expectEqualSlices(u8, &expected, result.output);
    }
}
