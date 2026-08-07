const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

const Address = primitives.Address.Address;
const blob = primitives.Blob;
const Eips = evm.Eips;

test "blob gas pricing and excess accumulation across hardforks" {
    const cancun = Eips{ .hardfork = .CANCUN };
    const prague = Eips{ .hardfork = .PRAGUE };
    const osaka = Eips{ .hardfork = .OSAKA };

    try std.testing.expectEqual(@as(u64, 1), cancun.blob_gas_price(0));
    try std.testing.expect(cancun.blob_gas_price(100 * blob.BLOB_GAS_PER_BLOB) > cancun.blob_gas_price(blob.BLOB_GAS_PER_BLOB));
    try std.testing.expect(cancun.blob_gas_price(100 * blob.BLOB_GAS_PER_BLOB) > prague.blob_gas_price(100 * blob.BLOB_GAS_PER_BLOB));
    try std.testing.expectEqual(prague.target_blob_gas(), osaka.target_blob_gas());
    try std.testing.expectEqual(prague.max_blob_gas(), osaka.max_blob_gas());

    var excess = cancun.excess_blob_gas(0, cancun.target_blob_gas());
    try std.testing.expectEqual(@as(u64, 0), excess);
    excess = cancun.excess_blob_gas(excess, cancun.target_blob_gas() + blob.BLOB_GAS_PER_BLOB);
    try std.testing.expectEqual(blob.BLOB_GAS_PER_BLOB, excess);
    excess = cancun.excess_blob_gas(excess, cancun.target_blob_gas() - blob.BLOB_GAS_PER_BLOB);
    try std.testing.expectEqual(@as(u64, 0), excess);

    const max_blobs = cancun.max_blob_gas() / blob.BLOB_GAS_PER_BLOB;
    for (1..max_blobs + 1) |count| {
        try std.testing.expectEqual(
            @as(u256, count * blob.BLOB_GAS_PER_BLOB * 7),
            cancun.blob_gas_cost(7, count),
        );
    }
}

test "blob transaction validation table" {
    const cancun = Eips{ .hardfork = .CANCUN };
    const prague = Eips{ .hardfork = .PRAGUE };
    const to = Address{ .bytes = [_]u8{0x22} ** 20 };
    const valid_hash = [_]u8{blob.BLOB_COMMITMENT_VERSION_KZG} ++ [_]u8{0x44} ** 31;
    const invalid_hash = [_]u8{0x02} ++ [_]u8{0x44} ** 31;
    const cancun_max = cancun.max_blob_gas() / blob.BLOB_GAS_PER_BLOB;
    const prague_max = prague.max_blob_gas() / blob.BLOB_GAS_PER_BLOB;
    var too_many: [10][32]u8 = [_][32]u8{valid_hash} ** 10;

    try std.testing.expectError(error.NoBlobs, cancun.validate_blob_gas(true, &.{}, 1, 1, to));
    try std.testing.expectError(error.TooManyBlobs, cancun.validate_blob_gas(true, too_many[0 .. cancun_max + 1], 1, 1, to));
    try std.testing.expectError(error.MaxFeePerBlobGasTooLow, cancun.validate_blob_gas(true, &.{valid_hash}, 1, 2, to));
    try std.testing.expectError(error.InvalidVersionedHash, cancun.validate_blob_gas(true, &.{invalid_hash}, 1, 1, to));
    try std.testing.expectError(error.BlobContractCreation, cancun.validate_blob_gas(true, &.{valid_hash}, 1, 1, null));
    try std.testing.expectError(error.TooManyBlobs, prague.validate_blob_gas(true, too_many[0 .. prague_max + 1], 1, 1, to));
    try cancun.validate_blob_gas(false, &.{}, 0, 1, null);
}

test "blob fee settlement burns blob fee when execution gas price is zero" {
    const allocator = std.testing.allocator;
    const DefaultEvm = evm.Evm(.{});
    const origin = Address{ .bytes = [_]u8{0x11} ** 20 };
    const recipient = Address{ .bytes = [_]u8{0x22} ** 20 };
    const coinbase = Address{ .bytes = [_]u8{0x33} ** 20 };
    const versioned_hash = [_]u8{blob.BLOB_COMMITMENT_VERSION_KZG} ++ [_]u8{0x55} ** 31;
    const blob_base_fee: u256 = 2;
    const required = @as(u256, blob.BLOB_GAS_PER_BLOB) * blob_base_fee;

    var database = evm.Database.init(allocator);
    defer database.deinit();
    try database.set_account(origin.bytes, .{
        .balance = required,
        .nonce = 0,
        .code_hash = primitives.EMPTY_CODE_HASH,
        .storage_root = [_]u8{0} ** 32,
    });
    try database.set_account(recipient.bytes, evm.Account.zero());

    const block_info = evm.BlockInfo{
        .number = 20_000_000,
        .timestamp = 1_710_338_135,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = coinbase,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = blob_base_fee,
    };
    const tx_context = evm.TransactionContext{
        .gas_limit = 100_000,
        .coinbase = coinbase,
        .chain_id = 1,
        .blob_versioned_hashes = &.{versioned_hash},
        .is_blob_transaction = true,
        .max_fee_per_gas = 0,
        .max_fee_per_blob_gas = blob_base_fee,
    };
    var instance = try DefaultEvm.init(allocator, &database, block_info, tx_context, 0, origin);
    defer instance.deinit();

    var result = instance.call(.{ .call = .{
        .caller = origin,
        .to = recipient,
        .value = 0,
        .input = &.{},
        .gas = 100_000,
    } });
    defer result.deinit(allocator);

    const sender = (try database.get_account(origin.bytes)).?;
    const miner = (try database.get_account(coinbase.bytes)) orelse evm.Account.zero();
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u256, 0), sender.balance);
    try std.testing.expectEqual(@as(u64, 1), sender.nonce);
    try std.testing.expectEqual(@as(u256, 0), miner.balance);
}

test "blob fee settlement credits only priority fee and burns base fees" {
    const allocator = std.testing.allocator;
    const DefaultEvm = evm.Evm(.{});
    const origin = Address{ .bytes = [_]u8{0x41} ** 20 };
    const recipient = Address{ .bytes = [_]u8{0x42} ** 20 };
    const coinbase = Address{ .bytes = [_]u8{0x43} ** 20 };
    const versioned_hash = [_]u8{blob.BLOB_COMMITMENT_VERSION_KZG} ++ [_]u8{0x66} ** 31;
    const initial_sender: u256 = 10_000_000;
    const initial_coinbase: u256 = 100;
    const gas_price: u256 = 7;
    const base_fee: u256 = 5;
    const blob_base_fee: u256 = 2;

    var database = evm.Database.init(allocator);
    defer database.deinit();
    try database.set_account(origin.bytes, .{ .balance = initial_sender, .nonce = 0, .code_hash = primitives.EMPTY_CODE_HASH, .storage_root = [_]u8{0} ** 32 });
    try database.set_account(coinbase.bytes, .{ .balance = initial_coinbase, .nonce = 0, .code_hash = primitives.EMPTY_CODE_HASH, .storage_root = [_]u8{0} ** 32 });
    try database.set_account(recipient.bytes, evm.Account.zero());

    const block_info = evm.BlockInfo{
        .number = 20_000_000,
        .timestamp = 1_710_338_135,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = coinbase,
        .base_fee = base_fee,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = blob_base_fee,
    };
    const tx_context = evm.TransactionContext{
        .gas_limit = 100_000,
        .coinbase = coinbase,
        .chain_id = 1,
        .blob_versioned_hashes = &.{versioned_hash},
        .is_blob_transaction = true,
        .max_fee_per_gas = 10,
        .max_fee_per_blob_gas = 3,
    };
    var instance = try DefaultEvm.init(allocator, &database, block_info, tx_context, gas_price, origin);
    defer instance.deinit();

    var result = instance.call(.{ .call = .{ .caller = origin, .to = recipient, .value = 0, .input = &.{}, .gas = 100_000 } });
    defer result.deinit(allocator);
    const gas_used: u256 = 100_000 - result.gas_left;
    const execution_fee = gas_price * gas_used;
    const blob_fee = @as(u256, blob.BLOB_GAS_PER_BLOB) * blob_base_fee;
    const priority_fee = (gas_price - base_fee) * gas_used;
    const sender = (try database.get_account(origin.bytes)).?;
    const miner = (try database.get_account(coinbase.bytes)).?;
    const recipient_account = (try database.get_account(recipient.bytes)) orelse evm.Account.zero();
    try std.testing.expect(result.success);

    try std.testing.expectEqual(initial_sender - execution_fee - blob_fee, sender.balance);
    try std.testing.expectEqual(initial_coinbase + priority_fee, miner.balance);
    const initial_supply = initial_sender + initial_coinbase;
    const final_supply = sender.balance + miner.balance + recipient_account.balance;
    try std.testing.expectEqual(base_fee * gas_used + blob_fee, initial_supply - final_supply);
}

test "upfront balance check rejects required minus one without nonce bump" {
    const allocator = std.testing.allocator;
    const DefaultEvm = evm.Evm(.{});
    const origin = Address{ .bytes = [_]u8{0x71} ** 20 };
    const recipient = Address{ .bytes = [_]u8{0x72} ** 20 };
    const coinbase = Address{ .bytes = [_]u8{0x73} ** 20 };
    const versioned_hash = [_]u8{blob.BLOB_COMMITMENT_VERSION_KZG} ++ [_]u8{0x77} ** 31;
    const required: u256 = 100_000 + blob.BLOB_GAS_PER_BLOB;

    var database = evm.Database.init(allocator);
    defer database.deinit();
    try database.set_account(origin.bytes, .{ .balance = required - 1, .nonce = 0, .code_hash = primitives.EMPTY_CODE_HASH, .storage_root = [_]u8{0} ** 32 });
    try database.set_account(recipient.bytes, evm.Account.zero());

    const block_info = evm.BlockInfo{ .number = 20_000_000, .timestamp = 1_710_338_135, .difficulty = 0, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = [_]u8{0} ** 32, .blob_base_fee = 1 };
    const tx_context = evm.TransactionContext{ .gas_limit = 100_000, .coinbase = coinbase, .chain_id = 1, .blob_versioned_hashes = &.{versioned_hash}, .is_blob_transaction = true, .max_fee_per_gas = 1, .max_fee_per_blob_gas = 1 };
    var instance = try DefaultEvm.init(allocator, &database, block_info, tx_context, 1, origin);
    defer instance.deinit();

    var rejected = instance.call(.{ .call = .{ .caller = origin, .to = recipient, .value = 0, .input = &.{}, .gas = 100_000 } });
    defer rejected.deinit(allocator);
    try std.testing.expect(!rejected.success);
    var sender = (try database.get_account(origin.bytes)).?;
    try std.testing.expectEqual(@as(u64, 0), sender.nonce);
    try std.testing.expectEqual(required - 1, sender.balance);

    sender.balance = required;
    try database.set_account(origin.bytes, sender);
    var accepted = instance.call(.{ .call = .{ .caller = origin, .to = recipient, .value = 0, .input = &.{}, .gas = 100_000 } });
    defer accepted.deinit(allocator);
    sender = (try database.get_account(origin.bytes)).?;
    try std.testing.expect(accepted.success);
    try std.testing.expectEqual(@as(u64, 1), sender.nonce);
}
