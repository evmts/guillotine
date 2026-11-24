//! EIP-214: SSTORE and TSTORE inside a STATICCALL frame must halt exceptionally.
//! Contract A STATICCALLs contract B, which writes storage, then A stores the
//! call's success flag in slot 0. The call must fail and B's state must not change.
const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

const gas_limit: u64 = 1_000_000;

const caller_addr = primitives.Address{ .bytes = [_]u8{0x10} ++ [_]u8{0} ** 19 };
const a_addr = primitives.Address{ .bytes = [_]u8{0xaa} ++ [_]u8{0} ** 19 };
const b_addr = primitives.Address{ .bytes = [_]u8{0xbb} ++ [_]u8{0} ** 19 };

// PUSH1 0 x4 (ret/args), PUSH20 B, PUSH2 0xffff, STATICCALL, PUSH1 0, SSTORE, STOP
const a_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x73 } ++ b_addr.bytes ++ [_]u8{ 0x61, 0xff, 0xff, 0xfa, 0x60, 0x00, 0x55, 0x00 };

fn runStaticWrite(b_code: []const u8) !void {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();
    const a_hash = try db.set_code(&a_code);
    try db.set_account(a_addr.bytes, evm.Account{ .balance = 0, .nonce = 0, .code_hash = a_hash, .storage_root = [_]u8{0} ** 32 });
    const b_hash = try db.set_code(b_code);
    try db.set_account(b_addr.bytes, evm.Account{ .balance = 0, .nonce = 0, .code_hash = b_hash, .storage_root = [_]u8{0} ** 32 });
    try db.set_storage(a_addr.bytes, 0, 7);
    try db.set_storage(b_addr.bytes, 1, 1);

    const block_info = evm.BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    const context = evm.TransactionContext{ .gas_limit = gas_limit, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 };
    const CancunEvm = evm.Evm(.{ .eips = evm.Eips{ .hardfork = .CANCUN } });
    var vm = try CancunEvm.init(allocator, &db, block_info, context, 0, caller_addr);
    defer vm.deinit();
    var result = vm.call(.{ .call = .{ .caller = caller_addr, .to = a_addr, .value = 0, .input = &.{}, .gas = gas_limit } });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(a_addr.bytes, 0));
    try std.testing.expectEqual(@as(u256, 1), try db.get_storage(b_addr.bytes, 1));
}

test "static: SSTORE inside STATICCALL fails the call" {
    // PUSH1 0, PUSH1 1, SSTORE, STOP
    try runStaticWrite(&.{ 0x60, 0x00, 0x60, 0x01, 0x55, 0x00 });
}

test "static: TSTORE inside STATICCALL fails the call" {
    // PUSH1 1, PUSH1 1, TSTORE, STOP
    try runStaticWrite(&.{ 0x60, 0x01, 0x60, 0x01, 0x5d, 0x00 });
}
