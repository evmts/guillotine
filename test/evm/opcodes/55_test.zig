const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");
const common = @import("common.zig");

test "opcode 0x55 differential test" {
    const allocator = std.testing.allocator;
    
    // Build bytecode for this opcode
    const bytecode = try common.build_bytecode(allocator, 0x55);
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

test "sstore helper regression - fork pricing and signed refunds" {
    const cases = [_]struct { fork: evm.Hardfork, current: u256, new: u256, original: u256, gas: u64, refund: i64 }{
        .{ .fork = .PETERSBURG, .current = 0, .new = 0, .original = 0, .gas = 5000, .refund = 0 },
        .{ .fork = .ISTANBUL, .current = 0, .new = 0, .original = 0, .gas = 800, .refund = 0 },
        .{ .fork = .BERLIN, .current = 1, .new = 0, .original = 1, .gas = 2900, .refund = 15000 },
        .{ .fork = .BERLIN, .current = 0, .new = 1, .original = 1, .gas = 100, .refund = -12200 },
        .{ .fork = .LONDON, .current = 0, .new = 1, .original = 1, .gas = 100, .refund = -2000 },
    };
    for (cases) |case| {
        const cost = (evm.Eips{ .hardfork = case.fork }).sstore_gas_cost(case.current, case.new, case.original, false);
        try std.testing.expectEqual(case.gas, cost.gas);
        try std.testing.expectEqual(case.refund, cost.refund);
    }
}
