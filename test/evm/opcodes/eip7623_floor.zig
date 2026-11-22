//! EIP-7623 calldata floor regressions.
//!
//! gas_used = max(21_000 + standard calldata + execution gas after refunds,
//!                21_000 + 10 * tokens_in_calldata)
//! The floor applies to every included Prague+ transaction, whether it succeeds,
//! reverts or halts exceptionally.
const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

const sender = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0x00} ** 19 };
const target = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0x00} ** 19 };
const sender_balance: u256 = 1_000_000_000;
const gas_price: u256 = 10;
const gas_limit: u64 = 30_000;

/// 100 non-zero bytes = 400 tokens.
///   standard calldata: 400 * 4  = 1_600
///   floor:             400 * 10 = 4_000
const calldata = [_]u8{0xff} ** 100;

const Outcome = struct { success: bool, gas_used: u64, sender_balance: u256 };

fn run(comptime hardfork: evm.Hardfork, code: []const u8) !Outcome {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    var sender_account = evm.Account.zero();
    sender_account.balance = sender_balance;
    try db.set_account(sender.bytes, sender_account);

    var target_account = evm.Account.zero();
    target_account.code_hash = try db.set_code(code);
    try db.set_account(target.bytes, target_account);

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
    const Vm = evm.Evm(.{ .eips = evm.Eips{ .hardfork = hardfork } });
    var vm = try Vm.init(allocator, &db, block_info, context, gas_price, sender);
    defer vm.deinit();

    var result = vm.call(.{ .call = .{
        .caller = sender,
        .to = target,
        .value = 0,
        .input = &calldata,
        .gas = gas_limit,
    } });
    defer result.deinit(allocator);

    const account = (try db.get_account(sender.bytes)) orelse return error.SenderMissing;
    return .{
        .success = result.success,
        .gas_used = gas_limit - result.gas_left,
        .sender_balance = account.balance,
    };
}

// PUSH1 0; PUSH1 0; REVERT: 6 execution gas.
const revert_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xfd };

test "EIP-7623: reverted Prague transaction pays the calldata floor" {
    // standard 21_000 + 1_600 + 6 = 22_606 < floor 25_000
    const outcome = try run(.PRAGUE, &revert_code);
    try std.testing.expect(!outcome.success);
    try std.testing.expectEqual(@as(u64, 25_000), outcome.gas_used);
    try std.testing.expectEqual(sender_balance - 25_000 * gas_price, outcome.sender_balance);
}

test "EIP-7623: reverted Cancun transaction is not floored" {
    // Pre-Prague: 21_000 + 100 non-zero bytes * 16 + 6 = 22_606
    const outcome = try run(.CANCUN, &revert_code);
    try std.testing.expect(!outcome.success);
    try std.testing.expectEqual(@as(u64, 22_606), outcome.gas_used);
    try std.testing.expectEqual(sender_balance - 22_606 * gas_price, outcome.sender_balance);
}

test "EIP-7623: successful Prague transaction below the floor pays the floor" {
    // STOP: 21_000 + 1_600 + 0 = 22_600 < floor 25_000
    const outcome = try run(.PRAGUE, &.{0x00});
    try std.testing.expect(outcome.success);
    try std.testing.expectEqual(@as(u64, 25_000), outcome.gas_used);
}

test "EIP-7623: Prague transaction above the floor pays its execution gas" {
    // PUSH1 0; SLOAD; PUSH1 1; SLOAD; STOP = 3 + 2_100 + 3 + 2_100 = 4_206 (two cold slots)
    // standard 21_000 + 1_600 + 4_206 = 26_806 > floor 25_000
    const outcome = try run(.PRAGUE, &.{ 0x60, 0x00, 0x54, 0x60, 0x01, 0x54, 0x00 });
    try std.testing.expect(outcome.success);
    try std.testing.expectEqual(@as(u64, 26_806), outcome.gas_used);
}
