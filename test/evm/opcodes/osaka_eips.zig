//! Prague/Osaka EIP surface through the public `evm` API.
//! Runs in `zig build test-opcodes` (imported by all_opcodes.zig).
const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

const cap = evm.eips.TX_GAS_LIMIT_CAP;

const TxOutcome = struct { success: bool, gas_left: u64, nonce: u64, balance: u256 };

fn runPlainTransfer(comptime hardfork: evm.Hardfork, gas: u64) !TxOutcome {
    const allocator = std.testing.allocator;
    var database = evm.Database.init(allocator);
    defer database.deinit();
    const sender = primitives.Address.fromU256(0x1000);
    const target = primitives.Address.fromU256(0x2000);
    var sender_account = evm.Account.zero();
    sender_account.balance = 1_000_000_000_000;
    try database.set_account(sender.bytes, sender_account);

    var engine = try evm.Evm(.{ .eips = .{ .hardfork = hardfork } }).init(allocator, &database, .{
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
    }, .{ .gas_limit = gas, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 1, sender);
    defer engine.deinit();

    var result = engine.call(.{ .call = .{ .caller = sender, .to = target, .value = 0, .input = &.{}, .gas = gas } });
    defer result.deinit(allocator);
    const account = (try database.get_account(sender.bytes)).?;
    return .{ .success = result.success, .gas_left = result.gas_left, .nonce = account.nonce, .balance = account.balance };
}

test "EIP-7825: Osaka rejects a transaction with gas 16_777_217 before nonce increment" {
    const outcome = try runPlainTransfer(.OSAKA, cap + 1);
    try std.testing.expect(!outcome.success);
    try std.testing.expectEqual(@as(u64, 0), outcome.gas_left);
    try std.testing.expectEqual(@as(u64, 0), outcome.nonce);
    try std.testing.expectEqual(@as(u256, 1_000_000_000_000), outcome.balance);
}

test "EIP-7825: Osaka accepts a transaction with gas exactly 16_777_216" {
    const outcome = try runPlainTransfer(.OSAKA, cap);
    try std.testing.expect(outcome.success);
    try std.testing.expectEqual(cap - 21_000, outcome.gas_left);
    try std.testing.expectEqual(@as(u64, 1), outcome.nonce);
}

test "EIP-7825: Prague accepts a transaction with gas 16_777_217" {
    const outcome = try runPlainTransfer(.PRAGUE, cap + 1);
    try std.testing.expect(outcome.success);
    try std.testing.expectEqual(cap + 1 - 21_000, outcome.gas_left);
    try std.testing.expectEqual(@as(u64, 1), outcome.nonce);
}

test "EIP-7825: Amsterdam keeps the cap and the default hardfork is Osaka" {
    const outcome = try runPlainTransfer(.AMSTERDAM, cap + 1);
    try std.testing.expect(!outcome.success);
    try std.testing.expectEqual(@as(u64, 0), outcome.nonce);
    try std.testing.expectEqual(evm.Hardfork.OSAKA, evm.Hardfork.DEFAULT);
    try std.testing.expectEqual(evm.Hardfork.OSAKA, (evm.EvmConfig{}).eips.hardfork);
}
