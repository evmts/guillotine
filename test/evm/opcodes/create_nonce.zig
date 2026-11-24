//! CREATE address derivation and sender nonce accounting (execution-specs
//! `process_transaction` + `generic_create`):
//! - a CREATE transaction deploys to address(sender, nonce) where nonce is the value
//!   before the transaction, and leaves the sender at nonce + 1;
//! - an opcode CREATE uses the creator's current nonce and increments it by one;
//! - that increment survives a colliding creation.
const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

const gas_limit: u64 = 1_000_000;
// Widely published vector: this sender's first two contracts land at these addresses.
const sender = primitives.Address{ .bytes = [_]u8{ 0x6a, 0xc7, 0xea, 0x33, 0xf8, 0x83, 0x1e, 0xa9, 0xdc, 0xc5, 0x33, 0x93, 0xaa, 0xa8, 0x8b, 0x25, 0xa7, 0x85, 0xdb, 0xf0 } };
const first_contract = primitives.Address{ .bytes = [_]u8{ 0xcd, 0x23, 0x4a, 0x47, 0x1b, 0x72, 0xba, 0x2f, 0x1c, 0xcf, 0x0a, 0x70, 0xfc, 0xab, 0xa6, 0x48, 0xa5, 0xee, 0xcd, 0x8d } };
const second_contract = primitives.Address{ .bytes = [_]u8{ 0x34, 0x3c, 0x43, 0xa3, 0x7d, 0x37, 0xdf, 0xf0, 0x8a, 0xe8, 0xc4, 0xa1, 0x15, 0x44, 0xc7, 0x18, 0xab, 0xb4, 0xfc, 0xf8 } };
const factory = primitives.Address{ .bytes = [_]u8{0x42} ++ [_]u8{0} ** 19 };

// Init code that deploys the 1-byte runtime 0x00:
// PUSH1 0; PUSH1 0; MSTORE8; PUSH1 1; PUSH1 0; RETURN
const init_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 };

// Factory: CREATE an empty contract (value 0, offset 0, size 0) and return its address.
// PUSH0 (size) PUSH0 (offset) PUSH0 (value) CREATE; PUSH0 MSTORE; PUSH1 0x20 PUSH0 RETURN
const factory_code = [_]u8{ 0x5f, 0x5f, 0x5f, 0xf0, 0x5f, 0x52, 0x60, 0x20, 0x5f, 0xf3 };

const block_info = evm.BlockInfo{
    .chain_id = 1,
    .number = 1,
    .timestamp = 1000,
    .difficulty = 0,
    .gas_limit = 30_000_000,
    .coinbase = primitives.ZERO_ADDRESS,
    .base_fee = 0,
    .prev_randao = [_]u8{0} ** 32,
};
const context = evm.TransactionContext{
    .gas_limit = gas_limit,
    .coinbase = primitives.ZERO_ADDRESS,
    .chain_id = 1,
};
const PragueEvm = evm.Evm(.{ .eips = evm.Eips{ .hardfork = .PRAGUE } });

fn fundSender(db: *evm.Database, nonce: u64) !void {
    try db.set_account(sender.bytes, evm.Account{
        .balance = 1_000_000_000_000_000_000,
        .nonce = nonce,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });
}

fn deployFactory(db: *evm.Database) !void {
    const code_hash = try db.set_code(&factory_code);
    try db.set_account(factory.bytes, evm.Account{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });
}

test "CREATE tx: fresh sender deploys to address(sender, 0) and ends at nonce 1" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();
    try fundSender(&db, 0);
    var vm = try PragueEvm.init(allocator, &db, block_info, context, 0, sender);
    defer vm.deinit();

    var result = vm.call(.{ .create = .{ .caller = sender, .value = 0, .init_code = &init_code, .gas = gas_limit } });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(first_contract, result.created_address.?);
    try std.testing.expectEqual(@as(u64, 1), (try db.get_account(sender.bytes)).?.nonce);
    const created = (try db.get_account(first_contract.bytes)).?;
    try std.testing.expectEqual(@as(u64, 1), created.nonce);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x00}, try db.get_code(created.code_hash));
    // 53000 intrinsic + 124 calldata (7 nonzero * 16 + 3 zero * 4) + 2 initcode word
    // + 18 execution (4 PUSH1, MSTORE8 with one memory word) + 200 code deposit.
    // CreateGas must not be charged a second time.
    try std.testing.expectEqual(@as(u64, 53_344), gas_limit - result.gas_left);
}

test "CREATE tx: consecutive deployments use nonces 0 then 1" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();
    try fundSender(&db, 0);
    var vm = try PragueEvm.init(allocator, &db, block_info, context, 0, sender);
    defer vm.deinit();

    var first = vm.call(.{ .create = .{ .caller = sender, .value = 0, .init_code = &init_code, .gas = gas_limit } });
    defer first.deinit(allocator);
    var second = vm.call(.{ .create = .{ .caller = sender, .value = 0, .init_code = &init_code, .gas = gas_limit } });
    defer second.deinit(allocator);

    try std.testing.expect(first.success and second.success);
    try std.testing.expectEqual(first_contract, first.created_address.?);
    try std.testing.expectEqual(second_contract, second.created_address.?);
    try std.testing.expectEqual(@as(u64, 2), (try db.get_account(sender.bytes)).?.nonce);
}

test "CREATE tx: failing init code still consumes the sender nonce" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();
    try fundSender(&db, 0);
    var vm = try PragueEvm.init(allocator, &db, block_info, context, 0, sender);
    defer vm.deinit();

    const reverting = [_]u8{ 0x5f, 0x5f, 0xfd }; // PUSH0 PUSH0 REVERT
    var failed = vm.call(.{ .create = .{ .caller = sender, .value = 0, .init_code = &reverting, .gas = gas_limit } });
    defer failed.deinit(allocator);
    try std.testing.expect(!failed.success);
    try std.testing.expectEqual(@as(u64, 1), (try db.get_account(sender.bytes)).?.nonce);

    var next = vm.call(.{ .create = .{ .caller = sender, .value = 0, .init_code = &init_code, .gas = gas_limit } });
    defer next.deinit(allocator);
    try std.testing.expect(next.success);
    try std.testing.expectEqual(second_contract, next.created_address.?);
}

test "CREATE opcode: uses the creator's current nonce and increments it once" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();
    try fundSender(&db, 0);
    try deployFactory(&db);
    var vm = try PragueEvm.init(allocator, &db, block_info, context, 0, sender);
    defer vm.deinit();

    var result = vm.call(.{ .call = .{ .caller = sender, .to = factory, .value = 0, .input = &.{}, .gas = gas_limit } });
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
    const expected = try primitives.Address.getContractAddress(allocator, factory, 1);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 12 ++ expected.bytes), result.output);
    try std.testing.expectEqual(@as(u64, 2), (try db.get_account(factory.bytes)).?.nonce);
    try std.testing.expectEqual(@as(u64, 1), (try db.get_account(sender.bytes)).?.nonce);
}

test "CREATE opcode: a colliding creation pushes 0 but keeps the nonce increment" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();
    try fundSender(&db, 0);
    try deployFactory(&db);
    const occupied = try primitives.Address.getContractAddress(allocator, factory, 1);
    try db.set_account(occupied.bytes, evm.Account{
        .balance = 0,
        .nonce = 1,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });
    var vm = try PragueEvm.init(allocator, &db, block_info, context, 0, sender);
    defer vm.deinit();

    var result = vm.call(.{ .call = .{ .caller = sender, .to = factory, .value = 0, .input = &.{}, .gas = gas_limit } });
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), result.output);
    try std.testing.expectEqual(@as(u64, 2), (try db.get_account(factory.bytes)).?.nonce);
}

test "CREATE tx: target with only nonempty storage collides (EIP-7610)" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();
    try fundSender(&db, 0);
    try db.set_account(first_contract.bytes, evm.Account{
        .balance = 10,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });
    try db.set_storage(first_contract.bytes, 1, 1);
    var vm = try PragueEvm.init(allocator, &db, block_info, context, 0, sender);
    defer vm.deinit();

    var result = vm.call(.{ .create = .{ .caller = sender, .value = 0, .init_code = &init_code, .gas = gas_limit } });
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u64, 1), (try db.get_account(sender.bytes)).?.nonce);
    const target = (try db.get_account(first_contract.bytes)).?;
    try std.testing.expectEqual(@as(u64, 0), target.nonce);
    try std.testing.expectEqual(@as(u256, 10), target.balance);
    try std.testing.expectEqual(@as(u256, 1), try db.get_storage(first_contract.bytes, 1));
}

test "CREATE opcode: unpayable CreateGas halts the frame out of gas" {
    // execution-specs charges GAS_CREATE in the opcode, so the caller frame halts and the
    // whole call reverts instead of CREATE pushing 0. Factory gets 10_000 gas < 32_000.
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();
    try fundSender(&db, 0);
    try deployFactory(&db);
    var vm = try PragueEvm.init(allocator, &db, block_info, context, 0, sender);
    defer vm.deinit();

    var result = vm.call(.{ .call = .{ .caller = sender, .to = factory, .value = 0, .input = &.{}, .gas = 31_000 } });
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u64, 0), result.gas_left);
    try std.testing.expectEqual(@as(u64, 1), (try db.get_account(factory.bytes)).?.nonce);
}
