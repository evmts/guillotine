//! RETURNDATACOPY with offset + size beyond 2^256 must halt exceptionally
//! (EIP-211 out-of-bounds read), never overflow or crash.
const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

const gas_limit: u64 = 1_000_000;
const contract = primitives.Address{ .bytes = [_]u8{0x42} ++ [_]u8{0} ** 19 };
const caller = primitives.Address{ .bytes = [_]u8{0x10} ++ [_]u8{0} ** 19 };

test "RETURNDATACOPY: offset + size overflowing u256 halts" {
    const allocator = std.testing.allocator;
    // PUSH1 100 (size); PUSH32 2^256-4 (offset); PUSH1 0 (dest); RETURNDATACOPY; STOP
    const code = [_]u8{ 0x60, 0x64, 0x7f } ++ [_]u8{0xff} ** 31 ++ [_]u8{ 0xfc, 0x60, 0x00, 0x3e, 0x00 };
    var db = evm.Database.init(allocator);
    defer db.deinit();
    const code_hash = try db.set_code(&code);
    try db.set_account(contract.bytes, evm.Account{ .balance = 0, .nonce = 0, .code_hash = code_hash, .storage_root = [_]u8{0} ** 32 });
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
    var vm = try CancunEvm.init(allocator, &db, block_info, context, 0, caller);
    defer vm.deinit();
    var result = vm.call(.{ .call = .{ .caller = caller, .to = contract, .value = 0, .input = &.{}, .gas = gas_limit } });
    defer result.deinit(allocator);
    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u64, 0), result.gas_left);
}
